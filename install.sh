#!/usr/bin/env bash
# monochrome-macos-rice installer.
# Usage: ./install.sh [--update] [--rebuild]
#   --update   git pull --ff-only this checkout first, list the new commits, then install
#   --rebuild  ignore the build stamps and rebuild every component
# Safe to run again: unchanged files and components are skipped, changed files
# are backed up as <file>.bak-<timestamp> before they are replaced.
set -Eeuo pipefail

usage() {
    cat <<'EOF'
Usage: ./install.sh [--update] [--rebuild]
  --update    git pull --ff-only this checkout, list the new commits, then install
  --rebuild   ignore the build stamps and rebuild every component
  -h, --help  show this help
EOF
}
UPDATE=0
REBUILD=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --update)  UPDATE=1 ;;
        --rebuild) REBUILD=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BIN_DIR="$HOME/bin"
APP_DIR="$HOME/Applications"
# Marks what this script installed, so a later run replaces its own builds
# without backing them up, but still backs up anything that was there before.
STATE_DIR="$HOME/.local/state/monochrome-macos-rice"
# Full output of every long build or install goes here, one file per run.
LOG_DIR="$STATE_DIR/logs"
# One <name>.stamp per built component: the inputs of its last successful build.
BUILD_STAMP_DIR="$STATE_DIR/build"
START_TIME="$(date +%s)"

CRANBERRY_URL="https://github.com/emreekici3/cranberry.git"
CRANBERRY_REV="42b5ed9"
AMT_URL="https://github.com/sebasreateguib/AppleMusicTUI.git"
# git options for clones: fail after a minute of stalled transfer instead of hanging.
GIT_NET=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60)
AMT_REV="eb796cc"
SYSVIZ_URL="https://github.com/orioshavfx/sysviz.git"
SYSVIZ_TAG="v0.2.0"
WALLPICKER_URL="https://github.com/orioshavfx/Wallpicker.git"
WALLPICKER_REV="5b54e5ea0b4726e6420e64f1d38cebbb61dcda93"
FISHER_URL="https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish"
BREW_INSTALL_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"

# Steps are the top-level `step "..."` lines of this file; count them for "[n/N]".
STEP_TOTAL="$(grep -c '^step "' "${BASH_SOURCE[0]}" || true)"
STEP_NO=0
step() {
    STEP_NO=$((STEP_NO + 1))
    printf '\n==> [%s/%s] %s\n' "$STEP_NO" "$STEP_TOTAL" "$*"
}
info() { printf '    %s\n' "$*"; }
warn() { printf '    warning: %s\n' "$*" >&2; }
die()  { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# fmt_secs N: 125 -> 2m05s
fmt_secs() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }

# run "what" command args...: runs the command, exits with a message naming it on failure.
run() {
    local what="$1"; shift
    "$@" || die "$what failed (command: $*)"
}

# run_long "what" command args...: for builds and installs that take minutes.
# The output goes to a log file instead of the screen. Every 10 seconds a line
# shows the elapsed time and the newest line of output, so a slow step is
# visibly alive. After 2 minutes without new output it warns, because the step
# may be waiting for input. On failure it prints the end of the log and returns 1;
# callers write `run_long ... || exit 1`.
run_long() {
    local what="$1"; shift
    local slug log start pid rc secs last size prev=0 idle=0 ticks=0
    slug="$(tr -cs 'A-Za-z0-9' '-' <<<"$what")"
    mkdir -p "$LOG_DIR" || { warn "cannot create $LOG_DIR"; return 1; }
    log="$LOG_DIR/$slug-$STAMP.log"
    start="$(date +%s)"
    info "started: $what (full log: $log)"
    "$@" >"$log" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        ticks=$((ticks + 1))
        [ $((ticks % 10)) -eq 0 ] || continue
        size="$(wc -c <"$log" | tr -d ' ')"
        if [ "$size" = "$prev" ]; then idle=$((idle + 10)); else idle=0; fi
        prev="$size"
        last="$(tail -n 1 "$log" 2>/dev/null | tr -d '\r\033' | cut -c1-100)"
        info "$(fmt_secs $(( $(date +%s) - start ))) $what: still running${last:+ (last line: $last)}"
        if [ "$idle" -eq 120 ]; then
            warn "$what: no new output for 2 minutes. It may be downloading a large file, compiling, or waiting for input. Log: $log"
        fi
    done
    if wait "$pid"; then rc=0; else rc=$?; fi
    secs=$(( $(date +%s) - start ))
    if [ "$rc" -eq 0 ]; then
        info "$what: done in $(fmt_secs "$secs")"
        return 0
    fi
    printf '\n    last lines of %s:\n' "$log" >&2
    tail -n 30 "$log" | tr -d '\r\033' | sed 's/^/    | /' >&2
    printf '\nerror: %s failed after %s (exit %s). Full log: %s\n' "$what" "$(fmt_secs "$secs")" "$rc" "$log" >&2
    return 1
}

# fetch_source "what" ARCHIVE_URL GIT_URL REV DEST: unpacks the pinned revision
# into DEST. It downloads the tarball with curl, which has connect and total
# timeouts (git has no connect timeout, and a clone once hung for minutes with
# no output). If that fails, it falls back to git clone.
fetch_source() {
    local what="$1" archive="$2" git_url="$3" rev="$4" dest="$5"
    local tgz="$WORK/$(basename "$dest").tar.gz"
    mkdir -p "$dest" || return 1
    if run_long "downloading $what" curl -fL --connect-timeout 20 --max-time 600 --retry 2 -o "$tgz" "$archive" \
        && tar -xzf "$tgz" -C "$dest" --strip-components=1; then
        return 0
    fi
    warn "downloading $what failed; falling back to git clone"
    rm -rf "$dest"
    run_long "cloning $what" env GIT_TERMINAL_PROMPT=0 git "${GIT_NET[@]}" clone --quiet "$git_url" "$dest" || return 1
    run "checking out $what $rev" git -C "$dest" -c advice.detachedHead=false checkout --quiet "$rev"
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found; $2"
}

# --update: fast-forward this checkout from GitHub, then start the updated
# install.sh over (bash keeps running the old copy of a file it has open).
if [ "$UPDATE" -eq 1 ]; then
    printf '\n==> %s\n' "Updating from GitHub"
    need git "it comes with the Xcode Command Line Tools."
    git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || die "--update: $REPO_DIR is not a git checkout. Get the rice with git clone to use --update."
    old_head="$(git -C "$REPO_DIR" rev-parse HEAD)" || die "--update: git rev-parse HEAD failed in $REPO_DIR"
    if ! env GIT_TERMINAL_PROMPT=0 git "${GIT_NET[@]}" -C "$REPO_DIR" pull --ff-only; then
        die "--update: git pull --ff-only failed (see above). Local commits or changes may clash with GitHub; nothing was installed."
    fi
    new_head="$(git -C "$REPO_DIR" rev-parse HEAD)" || die "--update: git rev-parse HEAD failed in $REPO_DIR"
    if [ "$old_head" = "$new_head" ]; then
        info "already up to date at $(git -C "$REPO_DIR" rev-parse --short HEAD)"
    else
        info "new commits:"
        git -C "$REPO_DIR" log --oneline "$old_head..$new_head" | sed 's/^/      /' \
            || warn "could not list the new commits"
        info "restarting the installer from the updated checkout"
        if [ "$REBUILD" -eq 1 ]; then
            exec bash "$REPO_DIR/install.sh" --rebuild
        else
            exec bash "$REPO_DIR/install.sh"
        fi
    fi
fi

# Any other command that fails still stops the script with a message.
trap 'die "line $LINENO: \"$BASH_COMMAND\" failed"' ERR

WORK="$(mktemp -d "${TMPDIR:-/tmp}/monochrome-rice.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A free backup name next to $1: never overwrites an earlier backup.
backup_name() {
    local base="$1.bak-$STAMP" name n=1
    name="$base"
    while [ -e "$name" ] || [ -L "$name" ]; do
        name="$base-$n"
        n=$((n + 1))
    done
    printf '%s\n' "$name"
}

# install_file SRC DST: copies a config file, backing up a different DST first.
install_file() {
    local src="$1" dst="$2" bak
    run "creating $(dirname "$dst")" mkdir -p "$(dirname "$dst")"
    if [ -d "$dst" ] && [ ! -L "$dst" ]; then
        die "$dst is a directory; expected a file. Move it away and run again."
    fi
    if [ -e "$dst" ]; then
        if cmp -s "$src" "$dst"; then
            info "unchanged  $dst"
            return 0
        fi
        bak="$(backup_name "$dst")"
        run "backing up $dst" cp -p "$dst" "$bak"
        info "backup     $bak"
    fi
    run "copying $src to $dst" cp "$src" "$dst"
    if [ -x "$src" ]; then
        run "making $dst executable" chmod 755 "$dst"
    fi
    info "installed  $dst"
}

# install_binary SRC NAME: puts a built binary at ~/bin/NAME through a temp
# name and mv, so a running copy is never overwritten in place. A binary that
# was there before and was not installed by this script is backed up first.
install_binary() {
    local src="$1" name="$2" dst="$BIN_DIR/$2" tmp bak
    run "creating $BIN_DIR" mkdir -p "$BIN_DIR" "$STATE_DIR"
    # An identical binary stays as it is: replacing it would reset permissions
    # macOS ties to the file (cberry's Accessibility grant).
    if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
        info "unchanged: $name"
        return 0
    fi
    if [ -e "$dst" ] && [ ! -e "$STATE_DIR/$name.installed" ]; then
        bak="$(backup_name "$dst")"
        run "backing up $dst" cp -p "$dst" "$bak"
        info "backup     $bak"
    fi
    tmp="$BIN_DIR/.$name.new.$$"
    run "copying $name" cp "$src" "$tmp"
    run "chmod $name" chmod 755 "$tmp"
    run "moving $name into place" mv -f "$tmp" "$dst"
    run "recording $name" touch "$STATE_DIR/$name.installed"
    info "installed  $dst"
}

# Build stamps. A component is skipped when $BUILD_STAMP_DIR/<name>.stamp holds
# the same key as now and its installed file exists; --rebuild ignores stamps.

# patch_hash PATCH...: one sha256 over the named files in patches/.
patch_hash() {
    local p
    for p in "$@"; do
        [ -f "$REPO_DIR/patches/$p" ] || return 1
    done
    (cd "$REPO_DIR/patches" && shasum -a 256 -- "$@") | shasum -a 256 | cut -d' ' -f1
}

# source_key DIR: the git tree hash of DIR (relative to the repo) when it has no
# uncommitted or untracked changes, otherwise a sha256 of its files' contents.
source_key() {
    local dir="$1" changes tree
    if command -v git >/dev/null 2>&1 \
        && changes="$(git -C "$REPO_DIR" status --porcelain -- "$dir" 2>/dev/null)" \
        && [ -z "$changes" ] \
        && tree="$(git -C "$REPO_DIR" rev-parse "HEAD:$dir" 2>/dev/null)"; then
        printf 'git-tree:%s\n' "$tree"
        return 0
    fi
    [ -d "$REPO_DIR/$dir" ] || return 1
    tree="$(cd "$REPO_DIR" \
        && find "$dir" -type f ! -name '.DS_Store' ! -path '*/.build/*' ! -path '*/.swiftpm/*' -print0 \
        | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)" || return 1
    printf 'content:%s\n' "$tree"
}

# stamp_current NAME KEY INSTALLED: true when NAME can be skipped.
stamp_current() {
    local file="$BUILD_STAMP_DIR/$1.stamp" key="$2" installed="$3" old
    [ "$REBUILD" -eq 0 ] || return 1
    [ -e "$installed" ] || return 1
    [ -f "$file" ] || return 1
    old="$(cat "$file" 2>/dev/null)" || return 1
    [ "$old" = "$key" ]
}

# clear_stamp NAME: before a build, so a failed build leaves no stamp behind.
clear_stamp() {
    run "removing the build stamp of $1" rm -f "$BUILD_STAMP_DIR/$1.stamp"
}

# write_stamp NAME KEY: after a successful build and install.
write_stamp() {
    local file="$BUILD_STAMP_DIR/$1.stamp"
    run "creating $BUILD_STAMP_DIR" mkdir -p "$BUILD_STAMP_DIR"
    printf '%s\n' "$2" >"$file.tmp.$$" || die "writing $file failed"
    run "recording the build stamp of $1" mv -f "$file.tmp.$$" "$file"
}

# ---------------------------------------------------------------------------
step "Checking the system"
[ "$(uname -s)" = "Darwin" ] || die "this rice is for macOS only (uname -s says $(uname -s))."
[ "$(id -u)" -ne 0 ] || die "do not run this script as root or with sudo."
MACOS_VERSION="$(sw_vers -productVersion)" || die "sw_vers failed"
info "macOS $MACOS_VERSION ($(uname -m))"
IFS=. read -r mac_major mac_minor _ <<<"$MACOS_VERSION.0.0"
SYSVIZ_SUPPORTED=1
if [ "$mac_major" -lt 14 ] || { [ "$mac_major" -eq 14 ] && [ "$mac_minor" -lt 2 ]; }; then
    SYSVIZ_SUPPORTED=0
    warn "sysviz needs macOS 14.2 or newer (Core Audio process tap); it will be skipped."
fi

# ---------------------------------------------------------------------------
step "Xcode Command Line Tools"
if ! xcode-select -p >/dev/null 2>&1; then
    info "Not installed. Starting the Command Line Tools installer..."
    xcode-select --install || true
    info "Finish the installer window, then run ./install.sh again."
    exit 1
fi
info "found at $(xcode-select -p)"

# ---------------------------------------------------------------------------
step "Homebrew"
find_brew() {
    local b
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
        if [ -x "$b" ]; then printf '%s\n' "$b"; return 0; fi
    done
    command -v brew 2>/dev/null
}
BREW="$(find_brew || true)"
if [ -z "$BREW" ]; then
    info "Homebrew not found. Running the official installer from https://brew.sh:"
    info "/bin/bash -c \"\$(curl -fsSL $BREW_INSTALL_URL)\""
    brew_installer="$(curl -fsSL "$BREW_INSTALL_URL")" || die "downloading the Homebrew installer failed"
    /bin/bash -c "$brew_installer" || die "the Homebrew installer failed"
    BREW="$(find_brew)" || die "Homebrew was installed, but brew is not in /opt/homebrew or /usr/local"
fi
eval "$("$BREW" shellenv)" || die "loading brew shellenv failed"
info "using $BREW"
# kitty starts `fish` by name and takes PATH from the login shell (zsh), so
# make sure zsh login shells know about Homebrew too.
ZPROFILE="$HOME/.zprofile"
if ! grep -qs 'brew shellenv' "$ZPROFILE"; then
    if [ -e "$ZPROFILE" ]; then
        zbak="$(backup_name "$ZPROFILE")"
        run "backing up $ZPROFILE" cp -p "$ZPROFILE" "$zbak"
        info "backup     $zbak"
    fi
    # shellcheck disable=SC2016  # $(...) is meant to be written literally
    printf '\n# Homebrew (added by monochrome-macos-rice)\neval "$(%s shellenv)"\n' "$BREW" >>"$ZPROFILE" \
        || die "adding brew shellenv to $ZPROFILE failed"
    info "added brew shellenv to $ZPROFILE"
fi

# ---------------------------------------------------------------------------
step "Homebrew packages (Brewfile)"
run_long "brew bundle" brew bundle --file="$REPO_DIR/Brewfile" || exit 1

# ---------------------------------------------------------------------------
step "fish plugins (fisher)"
PLUGINS_FILE="$REPO_DIR/configs/fish/fish_plugins"
if [ -f "$PLUGINS_FILE" ]; then
    need fish "it should have been installed by brew bundle."
    if ! fish -c 'type -q fisher' >/dev/null 2>&1; then
        info "fetching fisher from GitHub: $FISHER_URL"
        run_long "installing fisher" fish -c "curl -fsSL $FISHER_URL | source && fisher install jorgebucaran/fisher" || exit 1
    fi
    installed_plugins="$(fish -c 'fisher list' 2>/dev/null || true)"
    while IFS= read -r plugin || [ -n "$plugin" ]; do
        plugin="${plugin%%#*}"
        plugin="$(printf '%s' "$plugin" | tr -d '[:space:]')"
        [ -n "$plugin" ] || continue
        if grep -qxF "$plugin" <<<"$installed_plugins"; then
            info "already installed  $plugin"
        else
            run_long "fisher install $plugin" fish -c "fisher install $plugin" || exit 1
        fi
    done <"$PLUGINS_FILE"
else
    info "no configs/fish/fish_plugins, skipping"
fi

# ---------------------------------------------------------------------------
step "Building cberry (cranberry window manager, patched for non-Latin layouts)"
cberry_patches="$(patch_hash cranberry-latin-layout.patch cranberry-split-by-size.patch)" \
    || die "hashing patches/cranberry-*.patch failed"
cberry_key="rev=$CRANBERRY_REV patches=sha256:$cberry_patches"
if stamp_current cberry "$cberry_key" "$BIN_DIR/cberry"; then
    info "unchanged, skipped: cberry"
else
    clear_stamp cberry
    need git "it comes with the Xcode Command Line Tools."
    need cargo "it should have been installed by brew bundle (rust)."
    src="$WORK/cranberry"
    fetch_source "cranberry" "https://github.com/emreekici3/cranberry/archive/$CRANBERRY_REV.tar.gz" "$CRANBERRY_URL" "$CRANBERRY_REV" "$src" || exit 1
    run "applying patches/cranberry-latin-layout.patch" git -C "$src" apply "$REPO_DIR/patches/cranberry-latin-layout.patch"
    run "applying patches/cranberry-split-by-size.patch" git -C "$src" apply "$REPO_DIR/patches/cranberry-split-by-size.patch"
    run_long "cargo build of cberry" cargo build --release --manifest-path "$src/Cargo.toml" || exit 1
    # Signed before install_binary, so an identical build compares equal to the
    # installed file and is left alone instead of being re-signed in place.
    run "codesign cberry" codesign --force --sign - "$src/target/release/cberry"
    install_binary "$src/target/release/cberry" cberry
    write_stamp cberry "$cberry_key"
fi

# ---------------------------------------------------------------------------
step "Building AppleMusicTUI (musicplayer, monochrome + lyrics patch)"
amt_patches="$(patch_hash applemusictui.patch)" || die "hashing patches/applemusictui.patch failed"
amt_key="rev=$AMT_REV patches=sha256:$amt_patches"
if stamp_current musicplayer "$amt_key" "$BIN_DIR/musicplayer"; then
    info "unchanged, skipped: musicplayer"
else
    clear_stamp musicplayer
    need go "it should have been installed by brew bundle."
    src="$WORK/AppleMusicTUI"
    fetch_source "AppleMusicTUI" "https://github.com/sebasreateguib/AppleMusicTUI/archive/$AMT_REV.tar.gz" "$AMT_URL" "$AMT_REV" "$src" || exit 1
    run "applying patches/applemusictui.patch" git -C "$src" apply "$REPO_DIR/patches/applemusictui.patch"
    run_long "go build of AppleMusicTUI" go -C "$src" build -o "$WORK/musicplayer" . || exit 1
    install_binary "$WORK/musicplayer" musicplayer
    write_stamp musicplayer "$amt_key"
fi

# ---------------------------------------------------------------------------
step "Building sysviz $SYSVIZ_TAG"
# No patches apply to sysviz; the key is the pinned tag alone.
sysviz_key="rev=$SYSVIZ_TAG patches=none"
if [ "$SYSVIZ_SUPPORTED" -eq 1 ] && stamp_current sysviz "$sysviz_key" "$BIN_DIR/sysviz"; then
    info "unchanged, skipped: sysviz"
elif [ "$SYSVIZ_SUPPORTED" -eq 1 ]; then
    clear_stamp sysviz
    need swift "it comes with the Xcode Command Line Tools."
    src="$WORK/sysviz"
    fetch_source "sysviz" "https://github.com/orioshavfx/sysviz/archive/refs/tags/$SYSVIZ_TAG.tar.gz" "$SYSVIZ_URL" "$SYSVIZ_TAG" "$src" || exit 1
    run_long "swift build of sysviz" swift build -c release --package-path "$src" || exit 1
    sysviz_bin="$(cd "$src" && swift build -c release --show-bin-path)/sysviz" || die "swift build --show-bin-path failed"
    install_binary "$sysviz_bin" sysviz
    write_stamp sysviz "$sysviz_key"
else
    warn "skipped: macOS $MACOS_VERSION is older than 14.2."
fi

# ---------------------------------------------------------------------------
step "Building rice-settings.app"
# Shown on the Overview page of rice-settings: the commit of this checkout and the build time.
build_commit="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
build_date="$(date '+%Y-%m-%d %H:%M')"
APP="$APP_DIR/rice-settings.app"
rs_src_key="$(source_key rice-settings)" || die "hashing the rice-settings sources failed"
# The commit is part of the key: Overview shows it, so a new commit rebuilds the app even if its sources did not change.
rs_key="$rs_src_key commit=$build_commit"
if stamp_current rice-settings "$rs_key" "$APP/Contents/MacOS/rice-settings"; then
    info "unchanged, skipped: rice-settings"
else
    clear_stamp rice-settings
    need swift "it comes with the Xcode Command Line Tools."
    src="$WORK/rice-settings"
    run "copying rice-settings sources" cp -R "$REPO_DIR/rice-settings" "$src"
    run_long "swift build of rice-settings" swift build -c release --package-path "$src" || exit 1
    rs_bin="$(cd "$src" && swift build -c release --show-bin-path)/rice-settings" || die "swift build --show-bin-path failed"
    NEW_APP="$WORK/rice-settings.app"
    run "creating the app bundle" mkdir -p "$NEW_APP/Contents/MacOS"
    run "copying the rice-settings binary" cp "$rs_bin" "$NEW_APP/Contents/MacOS/rice-settings"
    cat >"$NEW_APP/Contents/Info.plist" <<PLIST || die "writing Info.plist failed"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>rice-settings</string>
  <key>CFBundleDisplayName</key><string>Rice Settings</string>
  <key>CFBundleIdentifier</key><string>com.oriosha.rice-settings</string>
  <key>CFBundleExecutable</key><string>rice-settings</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>RiceBuildCommit</key><string>$build_commit</string>
  <key>RiceBuildDate</key><string>$build_date</string>
</dict>
</plist>
PLIST
    run "codesign rice-settings.app" codesign --force --sign - "$NEW_APP"
    run "creating $APP_DIR" mkdir -p "$APP_DIR" "$STATE_DIR"
    if [ -e "$APP" ]; then
        if [ -e "$STATE_DIR/rice-settings.app.installed" ]; then
            run "removing the previous build of rice-settings.app" rm -rf "$APP"
        else
            app_bak="$(backup_name "$APP")"
            run "backing up $APP" mv "$APP" "$app_bak"
            info "backup     $app_bak"
        fi
    fi
    run "moving rice-settings.app into place" mv "$NEW_APP" "$APP"
    run "recording rice-settings.app" touch "$STATE_DIR/rice-settings.app.installed"
    info "installed  $APP"
    write_stamp rice-settings "$rs_key"
fi

# ---------------------------------------------------------------------------
step "Building wallpicker"
# Not fatal: without it only opt+w does nothing, the rest of the rice works.
# The source is its own repository (orioshavfx/Wallpicker), pinned to WALLPICKER_REV like cberry.
wp_key="rev=$WALLPICKER_REV"
if stamp_current wallpicker "$wp_key" "$BIN_DIR/wallpicker"; then
    info "unchanged, skipped: wallpicker"
else
    clear_stamp wallpicker
    src="$WORK/wallpicker"
    if fetch_source "wallpicker" "https://github.com/orioshavfx/Wallpicker/archive/$WALLPICKER_REV.tar.gz" \
            "$WALLPICKER_URL" "$WALLPICKER_REV" "$src" \
        && run_long "swift build of wallpicker" swift build -c release --package-path "$src"; then
        if wp_bin="$(cd "$src" && swift build -c release --show-bin-path)/wallpicker" \
            && install_binary "$wp_bin" wallpicker; then
            write_stamp wallpicker "$wp_key"
        else
            warn "wallpicker was built but could not be installed; opt+w will do nothing."
        fi
    else
        warn "wallpicker did not build or could not be fetched; opt+w will do nothing. Re-run the installer after fixing it."
    fi
fi

# ---------------------------------------------------------------------------
step "Installing configs"
while IFS= read -r -d '' file; do
    rel="${file#"$REPO_DIR/configs/"}"
    top="${rel%%/*}"
    rest="${rel#*/}"
    case "$top" in
        kitty)         target="$HOME/.config/kitty/$rest" ;;
        fish)          target="$HOME/.config/fish/$rest" ;;
        cranberry)     target="$HOME/.config/cranberry/$rest" ;;
        fastfetch)     target="$HOME/.config/fastfetch/$rest" ;;
        sysviz)        target="$HOME/.config/sysviz/$rest" ;;
        rice-settings) target="$HOME/.config/rice-settings/$rest" ;;
        bin)           target="$HOME/bin/$rest" ;;
        *) die "configs/$rel: no target known for configs/$top" ;;
    esac
    install_file "$file" "$target"
done < <(find "$REPO_DIR/configs" -type f ! -name '.DS_Store' -print0)
# The `setup --build` fish function rebuilds the app from ~/bin/rice-settings.
while IFS= read -r -d '' file; do
    rel="${file#"$REPO_DIR/rice-settings/"}"
    install_file "$file" "$HOME/bin/rice-settings/$rel"
done < <(find "$REPO_DIR/rice-settings" -type f ! -name '.DS_Store' ! -path '*/.build/*' ! -path '*/.swiftpm/*' -print0)
# `setup --build` reads this file, so a rebuild keeps the commit this install was made from.
run "recording the build commit" sh -c 'printf "%s\n" "$1" >"$2"' sh "$build_commit" "$HOME/bin/rice-settings/BUILD_COMMIT"

# ---------------------------------------------------------------------------
step "cberry service"
# Unload a service that may still point at an older binary, then load ours.
run "cberry stop" "$BIN_DIR/cberry" stop
run "cberry install" "$BIN_DIR/cberry" install
run "cberry start" "$BIN_DIR/cberry" start
info "cberry doctor says:"
if ! "$BIN_DIR/cberry" doctor; then
    warn "cberry doctor lists something to fix (expected until cberry has Accessibility permission)."
fi

# ---------------------------------------------------------------------------
# Clear the console so the closing summary is the only thing on screen.
# Only on a real terminal; piped or logged runs keep their full output.
if [[ -t 1 ]]; then
    printf '\033[H\033[2J\033[3J'
fi
step "Done. Still to do by hand"
# Open Rice Settings now that cberry runs, so its floating rule places the window.
open "$APP" 2>/dev/null && info "opened $APP" || warn "could not open $APP; open it from ~/Applications"
info "total time: $(fmt_secs $(( $(date +%s) - START_TIME )))"
cat <<EOF
    1. Grant Accessibility to cberry: System Settings > Privacy & Security >
       Accessibility, add $BIN_DIR/cberry (press + and Cmd+Shift+G to type the path),
       then run: $BIN_DIR/cberry restart
       If this script rebuilt cberry (a new cberry revision or patch), the binary
       changed: remove cberry from that list, add it again and restart it.
    2. Reassign the macOS "Hide Others" shortcut (Cmd+Opt+H clashes with the
       cberry resize binds): System Settings > Keyboard > Keyboard Shortcuts >
       App Shortcuts > All Applications, menu title "Hide Others", Ctrl+Shift+Cmd+H.
    3. Open kitty (a new fish shell).
    4. Press Opt+U, or type \`setup\`, to open Rice Settings.
EOF
