//! Talks to Music.app through `osascript`. Only playback, playlists and the
//! now-playing state are used: there is no catalogue search.
//!
//! Replies that carry several fields use the ASCII unit separator (0x1f)
//! between fields, which does not occur in track or playlist names.

use std::process::Command;

use anyhow::{bail, Context, Result};

const SEP: char = '\u{1f}';
const RS: char = '\u{1e}';
/// Where `fetch_cover` writes the raw artwork bytes (any format Music.app uses).
pub const RAW_COVER_PATH: &str = "/tmp/musictui-cover.bin";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlayerState {
    Playing,
    Paused,
    Stopped,
    Other(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Repeat {
    Off,
    One,
    All,
}

impl Repeat {
    /// The next mode in the cycle off -> all -> one -> off.
    pub fn next(&self) -> Self {
        match self {
            Repeat::Off => Repeat::All,
            Repeat::All => Repeat::One,
            Repeat::One => Repeat::Off,
        }
    }

    fn as_applescript(&self) -> &'static str {
        match self {
            Repeat::Off => "off",
            Repeat::One => "one",
            Repeat::All => "all",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct NowPlaying {
    pub state: PlayerState,
    pub title: String,
    pub artist: String,
    pub album: String,
    /// Track length in seconds.
    pub duration: f64,
    /// Playback position in seconds.
    pub position: f64,
    /// Volume, 0 to 100.
    pub volume: u8,
    pub shuffle: bool,
    pub repeat: Repeat,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TrackRow {
    pub title: String,
    pub artist: String,
    pub duration: f64,
}

/// Run an AppleScript snippet and return its trimmed stdout.
fn run(script: &str) -> Result<String> {
    let out = Command::new("osascript")
        .arg("-e")
        .arg(script)
        .output()
        .context("failed to start osascript (this app needs macOS)")?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        bail!("osascript: {}", err.trim());
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

/// Escape a value for use inside an AppleScript double-quoted string.
pub fn escape(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn parse_state(s: &str) -> PlayerState {
    match s {
        "playing" => PlayerState::Playing,
        "paused" => PlayerState::Paused,
        "stopped" => PlayerState::Stopped,
        other => PlayerState::Other(other.to_string()),
    }
}

fn parse_repeat(s: &str) -> Repeat {
    match s {
        "one" => Repeat::One,
        "all" => Repeat::All,
        _ => Repeat::Off,
    }
}

fn parse_f64(s: &str) -> f64 {
    s.trim().replace(',', ".").parse().unwrap_or(0.0)
}

/// Parse the reply of `NOW_PLAYING_SCRIPT`. Returns `None` when nothing is loaded.
pub fn parse_now_playing(reply: &str) -> Option<NowPlaying> {
    if reply.is_empty() || reply == "stopped" {
        return None;
    }
    let f: Vec<&str> = reply.split(SEP).collect();
    if f.len() < 9 {
        return None;
    }
    let state = parse_state(f[0]);
    if state == PlayerState::Stopped {
        return None;
    }
    Some(NowPlaying {
        state,
        title: f[1].to_string(),
        artist: f[2].to_string(),
        album: f[3].to_string(),
        duration: parse_f64(f[4]),
        position: parse_f64(f[5]),
        volume: parse_f64(f[6]).round().clamp(0.0, 100.0) as u8,
        shuffle: f[7] == "true",
        repeat: parse_repeat(f[8]),
    })
}

/// Split a SEP-joined list. An empty reply means an empty list.
fn split_items(reply: &str) -> Vec<&str> {
    if reply.is_empty() {
        Vec::new()
    } else {
        reply.split(SEP).collect()
    }
}

/// Parse the reply of `playlist_tracks`: three SEP-joined blocks (titles,
/// artists, durations) separated by RS.
pub fn parse_track_blocks(reply: &str) -> Vec<TrackRow> {
    let blocks: Vec<&str> = reply.split(RS).collect();
    if blocks.len() < 3 {
        return Vec::new();
    }
    let titles = split_items(blocks[0]);
    let artists = split_items(blocks[1]);
    let durations = split_items(blocks[2]);
    titles
        .iter()
        .enumerate()
        .map(|(i, title)| TrackRow {
            title: title.to_string(),
            artist: artists.get(i).copied().unwrap_or("").to_string(),
            duration: durations.get(i).map(|d| parse_f64(d)).unwrap_or(0.0),
        })
        .collect()
}

const NOW_PLAYING_SCRIPT: &str = r#"
tell application "Music"
    if player state is stopped then return "stopped"
    set sep to (ASCII character 31)
    set t to current track
    return (player state as string) & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & ((duration of t) as string) & sep & ((player position) as string) & sep & ((sound volume) as string) & sep & ((shuffle enabled) as string) & sep & (song repeat as string)
end tell
"#;

/// Everything the UI needs from the player, one AppleScript call per refresh.
pub fn now_playing() -> Result<Option<NowPlaying>> {
    let reply = run(NOW_PLAYING_SCRIPT)?;
    Ok(parse_now_playing(&reply))
}

/// Names of all user playlists, in the order Music.app shows them.
pub fn playlists() -> Result<Vec<String>> {
    let script = r#"
set sep to (ASCII character 31)
set out to ""
tell application "Music"
    repeat with p in user playlists
        set out to out & (name of p) & sep
    end repeat
end tell
return out
"#;
    let reply = run(script)?;
    Ok(split_items(&reply).into_iter().map(String::from).collect())
}

/// Tracks of a playlist. Titles, artists and durations come as three bulk lists.
/// Each value is read with its own `tell` expression: assigning variables inside
/// a `tell` block makes AppleScript treat them as properties of Music.
pub fn playlist_tracks(playlist: &str) -> Result<Vec<TrackRow>> {
    let script = format!(
        r#"
set sep to (ASCII character 31)
set rs to (ASCII character 30)
set AppleScript's text item delimiters to sep
set titles to (tell application "Music" to name of tracks of user playlist "{0}") as text
set artists to (tell application "Music" to artist of tracks of user playlist "{0}") as text
set durations to (tell application "Music" to duration of tracks of user playlist "{0}") as text
set AppleScript's text item delimiters to ""
return titles & rs & artists & rs & durations
"#,
        escape(playlist)
    );
    let reply = run(&script)?;
    Ok(parse_track_blocks(&reply))
}

/// Write the current track's artwork to `RAW_COVER_PATH`. Returns `false` when
/// the track has no artwork.
pub fn fetch_cover() -> Result<bool> {
    let script = format!(
        r#"
set artCount to (tell application "Music" to count of artworks of current track)
if artCount is 0 then return "none"
set artData to (tell application "Music" to raw data of artwork 1 of current track)
set fh to open for access (POSIX file "{}") with write permission
set eof of fh to 0
write artData to fh
close access fh
return "ok"
"#,
        RAW_COVER_PATH
    );
    Ok(run(&script)? == "ok")
}

pub fn play_playlist(playlist: &str) -> Result<()> {
    run(&format!(
        r#"tell application "Music" to play user playlist "{}""#,
        escape(playlist)
    ))
    .map(|_| ())
}

/// Play track number `index` (1-based) of a playlist.
pub fn play_track(playlist: &str, index: usize) -> Result<()> {
    run(&format!(
        r#"tell application "Music" to play track {} of user playlist "{}""#,
        index,
        escape(playlist)
    ))
    .map(|_| ())
}

pub fn play_pause() -> Result<()> {
    run(r#"tell application "Music" to playpause"#).map(|_| ())
}

pub fn next_track() -> Result<()> {
    run(r#"tell application "Music" to next track"#).map(|_| ())
}

pub fn previous_track() -> Result<()> {
    run(r#"tell application "Music" to previous track"#).map(|_| ())
}

pub fn set_shuffle(on: bool) -> Result<()> {
    run(&format!(
        r#"tell application "Music" to set shuffle enabled to {}"#,
        if on { "true" } else { "false" }
    ))
    .map(|_| ())
}

pub fn set_repeat(mode: &Repeat) -> Result<()> {
    run(&format!(
        r#"tell application "Music" to set song repeat to {}"#,
        mode.as_applescript()
    ))
    .map(|_| ())
}

pub fn set_volume(volume: u8) -> Result<()> {
    run(&format!(
        r#"tell application "Music" to set sound volume to {}"#,
        volume.min(100)
    ))
    .map(|_| ())
}

/// Move the playback position, in seconds.
pub fn set_position(seconds: f64) -> Result<()> {
    run(&format!(
        r#"tell application "Music" to set player position to {:.1}"#,
        seconds.max(0.0)
    ))
    .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reply(state: &str, title: &str) -> String {
        [
            state, title, "Artist", "Album", "215.5", "12.25", "70.0", "true", "all",
        ]
        .join(&SEP.to_string())
    }

    #[test]
    fn parses_playing_track() {
        let np = parse_now_playing(&reply("playing", "Song")).unwrap();
        assert_eq!(np.state, PlayerState::Playing);
        assert_eq!(np.title, "Song");
        assert_eq!(np.duration, 215.5);
        assert_eq!(np.position, 12.25);
        assert_eq!(np.volume, 70);
        assert!(np.shuffle);
        assert_eq!(np.repeat, Repeat::All);
    }

    #[test]
    fn stopped_or_empty_is_none() {
        assert!(parse_now_playing("stopped").is_none());
        assert!(parse_now_playing("").is_none());
        assert!(parse_now_playing(&reply("stopped", "x")).is_none());
    }

    #[test]
    fn comma_decimal_separator_is_accepted() {
        let np = parse_now_playing(
            &["paused", "t", "a", "b", "3,5", "1,0", "50", "false", "off"].join(&SEP.to_string()),
        )
        .unwrap();
        assert_eq!(np.duration, 3.5);
        assert_eq!(np.repeat, Repeat::Off);
    }

    #[test]
    fn repeat_cycles_through_all_modes() {
        assert_eq!(Repeat::Off.next(), Repeat::All);
        assert_eq!(Repeat::All.next(), Repeat::One);
        assert_eq!(Repeat::One.next(), Repeat::Off);
    }

    #[test]
    fn parses_track_blocks() {
        let titles = ["A", "B"].join(&SEP.to_string());
        let artists = ["x", "y"].join(&SEP.to_string());
        let durations = ["180", "200.5"].join(&SEP.to_string());
        let reply = [titles, artists, durations].join(&RS.to_string());
        let rows = parse_track_blocks(&reply);
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[1].title, "B");
        assert_eq!(rows[1].artist, "y");
        assert_eq!(rows[1].duration, 200.5);
    }

    #[test]
    fn empty_playlist_gives_no_rows() {
        assert!(parse_track_blocks(&format!("{RS}{RS}")).is_empty());
        assert!(parse_track_blocks("").is_empty());
    }

    #[test]
    fn splits_playlist_names() {
        assert_eq!(split_items(""), Vec::<&str>::new());
        assert_eq!(
            split_items(&["One", "Two"].join(&SEP.to_string())),
            vec!["One", "Two"]
        );
    }

    #[test]
    fn escapes_quotes_and_backslashes() {
        assert_eq!(escape(r#"My "Mix" \ 1"#), r#"My \"Mix\" \\ 1"#);
    }
}
