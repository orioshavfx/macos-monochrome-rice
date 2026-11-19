#!/usr/bin/env bash
# monochrome-macos-rice installer.
# Usage: ./install.sh   (safe to run again: unchanged files are skipped,
# changed ones are backed up as <file>.bak-<timestamp> before they are replaced)
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
BIN_DIR="$HOME/bin"
APP_DIR="$HOME/Applications"
# Marks what this script installed, so a later run replaces its own builds
# without backing them up, but still backs up anything that was there before.
STATE_DIR="$HOME/.local/state/monochrome-macos-rice"
# Full output of every long build or install goes here, one file per run.
LOG_DIR="$STATE_DIR/logs"
START_TIME="$(date +%s)"

CRANBERRY_URL="https://github.com/emreekici3/cranberry.git"
CRANBERRY_REV="42b5ed9"
AMT_URL="https://github.com/sebasreateguib/AppleMusicTUI.git"
AMT_REV="eb796cc"
SYSVIZ_URL="https://github.com/orioshavfx/sysviz.git"
SYSVIZ_TAG="v0.2.0"
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

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 not found; $2"
}

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
need git "it comes with the Xcode Command Line Tools."
need cargo "it should have been installed by brew bundle (rust)."
src="$WORK/cranberry"
run "cloning $CRANBERRY_URL" git clone --quiet "$CRANBERRY_URL" "$src"
run "checking out cranberry $CRANBERRY_REV" git -C "$src" -c advice.detachedHead=false checkout --quiet "$CRANBERRY_REV"
run "applying patches/cranberry-latin-layout.patch" git -C "$src" apply "$REPO_DIR/patches/cranberry-latin-layout.patch"
run_long "cargo build of cberry" cargo build --release --manifest-path "$src/Cargo.toml" || exit 1
install_binary "$src/target/release/cberry" cberry
run "codesign cberry" codesign --force --sign - "$BIN_DIR/cberry"

# ---------------------------------------------------------------------------
step "Building AppleMusicTUI (musicplayer, monochrome + lyrics patch)"
need go "it should have been installed by brew bundle."
src="$WORK/AppleMusicTUI"
run "cloning $AMT_URL" git clone --quiet "$AMT_URL" "$src"
run "checking out AppleMusicTUI $AMT_REV" git -C "$src" -c advice.detachedHead=false checkout --quiet "$AMT_REV"
run "applying patches/applemusictui.patch" git -C "$src" apply "$REPO_DIR/patches/applemusictui.patch"
run_long "go build of AppleMusicTUI" go -C "$src" build -o "$WORK/musicplayer" . || exit 1
install_binary "$WORK/musicplayer" musicplayer

# ---------------------------------------------------------------------------
step "Building sysviz $SYSVIZ_TAG"
if [ "$SYSVIZ_SUPPORTED" -eq 1 ]; then
    need swift "it comes with the Xcode Command Line Tools."
    src="$WORK/sysviz"
    run "cloning $SYSVIZ_URL" git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$SYSVIZ_TAG" "$SYSVIZ_URL" "$src"
    run_long "swift build of sysviz" swift build -c release --package-path "$src" || exit 1
    sysviz_bin="$(cd "$src" && swift build -c release --show-bin-path)/sysviz" || die "swift build --show-bin-path failed"
    install_binary "$sysviz_bin" sysviz
else
    warn "skipped: macOS $MACOS_VERSION is older than 14.2."
fi

# ---------------------------------------------------------------------------
step "Building rice-settings.app"
need swift "it comes with the Xcode Command Line Tools."
src="$WORK/rice-settings"
run "copying rice-settings sources" cp -R "$REPO_DIR/rice-settings" "$src"
run_long "swift build of rice-settings" swift build -c release --package-path "$src" || exit 1
rs_bin="$(cd "$src" && swift build -c release --show-bin-path)/rice-settings" || die "swift build --show-bin-path failed"
APP="$APP_DIR/rice-settings.app"
NEW_APP="$WORK/rice-settings.app"
run "creating the app bundle" mkdir -p "$NEW_APP/Contents/MacOS"
run "copying the rice-settings binary" cp "$rs_bin" "$NEW_APP/Contents/MacOS/rice-settings"
cat >"$NEW_APP/Contents/Info.plist" <<'PLIST' || die "writing Info.plist failed"
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
step "Done. Still to do by hand"
info "total time: $(fmt_secs $(( $(date +%s) - START_TIME )))"
cat <<EOF
    1. Grant Accessibility to cberry: System Settings > Privacy & Security >
       Accessibility, add $BIN_DIR/cberry (press + and Cmd+Shift+G to type the path),
       then run: $BIN_DIR/cberry restart
       After every re-run of this script the binary is rebuilt: remove cberry
       from that list, add it again and restart it.
    2. Reassign the macOS "Hide Others" shortcut (Cmd+Opt+H clashes with the
       cberry resize binds): System Settings > Keyboard > Keyboard Shortcuts >
       App Shortcuts > All Applications, menu title "Hide Others", Ctrl+Shift+Cmd+H.
    3. Open kitty (a new fish shell).
    4. Press Opt+U, or type \`setup\`, to open Rice Settings.
EOF
