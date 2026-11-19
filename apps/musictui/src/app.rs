//! Application state and key handling. Independent of the terminal, so the
//! behaviour can be tested without drawing anything.

use std::path::Path;
use std::time::{Duration, Instant};

use crossterm::event::{KeyCode, KeyEvent};
use image::RgbImage;
use ratatui::{style::Color, widgets::ListState};

use crate::config::{Config, KeyMap, KeySpec};
use crate::cover;
use crate::music::{self, NowPlaying, PlayerState, Repeat, TrackRow};

/// Work file for the artwork conversion (sips writes PNG here).
const COVER_PNG: &str = "/tmp/musictui-cover.png";
const VOLUME_STEP: u8 = 5;
const SEEK_STEP: f64 = 5.0;
/// The queue takes over this many seconds before the current track ends.
const ADVANCE_WINDOW: f64 = 1.5;
/// Minimum time between two queue advances, so one track is never skipped twice.
const ADVANCE_COOLDOWN: Duration = Duration::from_secs(3);
/// The track list is loaded once the playlist cursor has rested this long.
const TRACK_DEBOUNCE: Duration = Duration::from_millis(250);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    Playlists,
    Tracks,
}

/// A track waiting in musictui's own queue. Music.app's "Up Next" is not
/// reachable through AppleScript, so the queue lives here.
#[derive(Debug, Clone, PartialEq)]
pub struct QueueItem {
    /// Playlist the track was picked from.
    pub playlist: String,
    /// 1-based position of the track in that playlist.
    pub index: usize,
    pub title: String,
    pub artist: String,
    pub duration: f64,
}

pub struct App {
    pub accent: Color,
    pub keys: KeyMap,

    pub now: Option<NowPlaying>,
    /// Artwork of the current track as greyscale pixels, drawn as a pixel cover.
    pub cover: Option<RgbImage>,
    /// Title of the track `cover` belongs to, to reload it when the track changes.
    cover_title: Option<String>,

    pub fullscreen: bool,
    pub focus: Focus,

    pub playlists: Vec<String>,
    pub playlist_state: ListState,
    /// Name of the playlist whose tracks are shown in `tracks`.
    pub tracks_of: Option<String>,
    pub tracks: Vec<TrackRow>,
    pub track_state: ListState,
    /// When the playlist cursor last moved; the track list loads after a pause.
    tracks_pending: Option<Instant>,

    pub queue: Vec<QueueItem>,
    last_advance: Option<Instant>,
    last_playlist_try: Option<Instant>,

    /// Last error or hint, shown in the footer.
    pub status: Option<String>,
    pub quit: bool,
}

fn key_matches(spec: KeySpec, key: &KeyEvent) -> bool {
    match spec {
        KeySpec::Char(c) => key.code == KeyCode::Char(c),
        KeySpec::Space => key.code == KeyCode::Char(' '),
        KeySpec::Enter => key.code == KeyCode::Enter,
        KeySpec::Tab => key.code == KeyCode::Tab,
        KeySpec::Left => key.code == KeyCode::Left,
        KeySpec::Right => key.code == KeyCode::Right,
        KeySpec::Up => key.code == KeyCode::Up,
        KeySpec::Down => key.code == KeyCode::Down,
        KeySpec::Esc => key.code == KeyCode::Esc,
    }
}

/// Move a list selection by `delta`, clamped to the list bounds.
fn step(state: &mut ListState, len: usize, delta: isize) {
    if len == 0 {
        state.select(None);
        return;
    }
    let cur = state.selected().unwrap_or(0) as isize;
    let next = (cur + delta).clamp(0, len as isize - 1) as usize;
    state.select(Some(next));
}

impl App {
    pub fn new(cfg: &Config, keys: KeyMap, accent: Color) -> Self {
        Self {
            accent,
            keys,
            now: None,
            cover: None,
            cover_title: None,
            fullscreen: cfg.view.start_fullscreen,
            focus: Focus::Playlists,
            playlists: Vec::new(),
            playlist_state: ListState::default(),
            tracks_of: None,
            tracks: Vec::new(),
            track_state: ListState::default(),
            tracks_pending: None,
            queue: Vec::new(),
            last_advance: None,
            last_playlist_try: None,
            status: None,
            quit: false,
        }
    }

    /// Load everything once at start-up.
    pub fn start(&mut self) {
        self.refresh_playlists();
        self.refresh_now();
    }

    fn report<T>(&mut self, result: anyhow::Result<T>) -> Option<T> {
        match result {
            Ok(v) => Some(v),
            Err(e) => {
                self.status = Some(format!("{e:#}"));
                None
            }
        }
    }

    /// Read the player state. Returns `false` if Music.app could not be read,
    /// so callers do not act on stale or missing data.
    pub fn refresh_now(&mut self) -> bool {
        let fetched = match self.report(music::now_playing()) {
            Some(now) => {
                self.now = now;
                true
            }
            None => false,
        };
        // Load the artwork again only when the track changes.
        if fetched {
            let title = self.now.as_ref().map(|n| n.title.clone());
            if title != self.cover_title {
                self.refresh_cover();
            }
        }
        fetched
    }

    pub fn refresh_playlists(&mut self) {
        if let Some(list) = self.report(music::playlists()) {
            self.playlists = list;
            self.status = None;
            if self.playlists.is_empty() {
                self.playlist_state.select(None);
            } else if self.playlist_state.selected().is_none() {
                self.playlist_state.select(Some(0));
            }
        }
        self.load_selected_playlist_tracks();
    }

    /// Load the artwork of the current track. Tracks without artwork get no cover.
    fn refresh_cover(&mut self) {
        self.cover_title = self.now.as_ref().map(|n| n.title.clone());
        self.cover = None;
        if self.now.is_none() {
            return;
        }
        let has_art = self.report(music::fetch_cover()).unwrap_or(false);
        if has_art {
            self.cover = self.report(cover::load(
                Path::new(music::RAW_COVER_PATH),
                Path::new(COVER_PNG),
            ));
        }
    }

    /// Show the tracks of the playlist under the cursor.
    fn load_selected_playlist_tracks(&mut self) {
        let Some(i) = self.playlist_state.selected() else {
            self.tracks.clear();
            self.tracks_of = None;
            self.track_state.select(None);
            return;
        };
        let name = self.playlists[i].clone();
        if self.tracks_of.as_deref() == Some(name.as_str()) {
            return;
        }
        if let Some(rows) = self.report(music::playlist_tracks(&name)) {
            self.tracks = rows;
            self.tracks_of = Some(name);
            self.track_state.select(if self.tracks.is_empty() {
                None
            } else {
                Some(0)
            });
        }
    }

    /// Load the track list once the playlist cursor has been still for a moment.
    /// Called from the main loop on every iteration; cheap when nothing is pending.
    pub fn flush_pending(&mut self) {
        if let Some(since) = self.tracks_pending {
            if since.elapsed() >= TRACK_DEBOUNCE {
                self.tracks_pending = None;
                self.load_selected_playlist_tracks();
            }
        }
    }

    /// Periodic refresh. Also starts the next queued track when the current one is ending.
    pub fn tick(&mut self) {
        // Retry the playlist list while it is empty, e.g. after a failed start-up read.
        if self.playlists.is_empty()
            && self
                .last_playlist_try
                .is_none_or(|t| t.elapsed() >= Duration::from_secs(5))
        {
            self.last_playlist_try = Some(Instant::now());
            self.refresh_playlists();
        }
        if !self.refresh_now() || self.queue.is_empty() {
            return;
        }
        let ending = match &self.now {
            None => true,
            Some(n) => match n.state {
                PlayerState::Playing => {
                    n.duration > 0.0 && n.duration - n.position <= ADVANCE_WINDOW
                }
                PlayerState::Stopped => true,
                _ => false,
            },
        };
        if ending && self.cooldown_passed() {
            self.play_queue_front();
        }
    }

    fn cooldown_passed(&self) -> bool {
        self.last_advance
            .is_none_or(|t| t.elapsed() >= ADVANCE_COOLDOWN)
    }

    /// Remove the first queued track and play it.
    fn play_queue_front(&mut self) {
        if self.queue.is_empty() {
            return;
        }
        let item = self.queue.remove(0);
        self.last_advance = Some(Instant::now());
        self.act(music::play_track(&item.playlist, item.index));
    }

    /// Run a command against Music.app and refresh the state afterwards.
    fn act(&mut self, result: anyhow::Result<()>) {
        if self.report(result).is_some() {
            self.status = None;
            self.refresh_now();
        }
    }

    /// Put the selected track at the end of the queue.
    fn enqueue_selected(&mut self) {
        if self.focus != Focus::Tracks {
            self.status = Some("Press Tab to pick a track, then a to queue it.".into());
            return;
        }
        let (Some(i), Some(name)) = (self.track_state.selected(), self.tracks_of.clone()) else {
            return;
        };
        let row = &self.tracks[i];
        self.queue.push(QueueItem {
            playlist: name,
            index: i + 1,
            title: row.title.clone(),
            artist: row.artist.clone(),
            duration: row.duration,
        });
        self.status = Some(format!(
            "Queued: {} (queue: {})",
            row.title,
            self.queue.len()
        ));
    }

    fn clear_queue(&mut self) {
        let n = self.queue.len();
        self.queue.clear();
        self.status = Some(format!("Queue cleared ({n} removed)"));
    }

    pub fn handle_key(&mut self, key: KeyEvent) {
        let k = self.keys.clone();
        let m = |spec: KeySpec| key_matches(spec, &key);

        if m(k.quit) {
            self.quit = true;
        } else if m(k.fullscreen) {
            self.fullscreen = !self.fullscreen;
        } else if m(k.play_pause) {
            self.act(music::play_pause());
        } else if m(k.next) {
            // With a queue, "next" plays the queue; otherwise Music.app decides.
            if self.queue.is_empty() {
                self.act(music::next_track());
            } else {
                self.play_queue_front();
            }
        } else if m(k.previous) {
            self.act(music::previous_track());
        } else if m(k.shuffle) {
            let on = self.now.as_ref().map(|n| n.shuffle).unwrap_or(false);
            self.act(music::set_shuffle(!on));
        } else if m(k.repeat) {
            let next = self
                .now
                .as_ref()
                .map(|n| n.repeat.next())
                .unwrap_or(Repeat::All);
            self.act(music::set_repeat(&next));
        } else if m(k.volume_up) {
            let v = self.now.as_ref().map(|n| n.volume).unwrap_or(50);
            self.act(music::set_volume(v.saturating_add(VOLUME_STEP).min(100)));
        } else if m(k.volume_down) {
            let v = self.now.as_ref().map(|n| n.volume).unwrap_or(50);
            self.act(music::set_volume(v.saturating_sub(VOLUME_STEP)));
        } else if m(k.seek_forward) {
            if let Some(n) = self.now.clone() {
                self.act(music::set_position(n.position + SEEK_STEP));
            }
        } else if m(k.seek_back) {
            if let Some(n) = self.now.clone() {
                self.act(music::set_position(n.position - SEEK_STEP));
            }
        } else if self.fullscreen {
            // In fullscreen only the transport keys above apply.
        } else if m(k.queue_add) {
            self.enqueue_selected();
        } else if m(k.queue_clear) {
            self.clear_queue();
        } else if m(k.focus_next) {
            self.focus = match self.focus {
                Focus::Playlists => Focus::Tracks,
                Focus::Tracks => Focus::Playlists,
            };
            if self.focus == Focus::Tracks {
                self.tracks_pending = None;
                self.load_selected_playlist_tracks();
            }
        } else if m(k.up) {
            self.move_selection(-1);
        } else if m(k.down) {
            self.move_selection(1);
        } else if m(k.select) {
            self.select();
        }
    }

    fn move_selection(&mut self, delta: isize) {
        match self.focus {
            Focus::Playlists => {
                let len = self.playlists.len();
                step(&mut self.playlist_state, len, delta);
                self.tracks_pending = Some(Instant::now());
            }
            Focus::Tracks => {
                let len = self.tracks.len();
                step(&mut self.track_state, len, delta);
            }
        }
    }

    /// Enter: play the selected playlist, or the selected track of the shown playlist.
    fn select(&mut self) {
        match self.focus {
            Focus::Playlists => {
                if let Some(i) = self.playlist_state.selected() {
                    let name = self.playlists[i].clone();
                    self.act(music::play_playlist(&name));
                }
            }
            Focus::Tracks => {
                if let (Some(i), Some(name)) = (self.track_state.selected(), self.tracks_of.clone())
                {
                    self.act(music::play_track(&name, i + 1));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Keys;
    use crossterm::event::{KeyEventKind, KeyEventState, KeyModifiers};

    fn app() -> App {
        let cfg = Config::default();
        let keys = KeyMap::from_config(&Keys::default()).unwrap();
        let mut a = App::new(&cfg, keys, Color::White);
        // Pretend the playlists are loaded so navigation can be tested without osascript.
        a.playlists = vec!["A".into(), "B".into(), "C".into()];
        a.playlist_state.select(Some(0));
        a
    }

    /// An app with one playlist "A" showing three tracks, focus on the track list.
    fn app_with_tracks() -> App {
        let mut a = app();
        a.tracks_of = Some("A".into());
        a.tracks = (1..=3)
            .map(|n| TrackRow {
                title: format!("Track {n}"),
                artist: "Artist".into(),
                duration: 100.0,
            })
            .collect();
        a.track_state.select(Some(1));
        a.focus = Focus::Tracks;
        a
    }

    fn press(c: KeyCode) -> KeyEvent {
        KeyEvent {
            code: c,
            modifiers: KeyModifiers::NONE,
            kind: KeyEventKind::Press,
            state: KeyEventState::NONE,
        }
    }

    fn queued(title: &str) -> QueueItem {
        QueueItem {
            playlist: "A".into(),
            index: 1,
            title: title.into(),
            artist: "x".into(),
            duration: 10.0,
        }
    }

    #[test]
    fn q_quits() {
        let mut a = app();
        a.handle_key(press(KeyCode::Char('q')));
        assert!(a.quit);
    }

    #[test]
    fn f_toggles_fullscreen() {
        let mut a = app();
        assert!(!a.fullscreen);
        a.handle_key(press(KeyCode::Char('f')));
        assert!(a.fullscreen);
        a.handle_key(press(KeyCode::Char('f')));
        assert!(!a.fullscreen);
    }

    #[test]
    fn navigation_is_clamped() {
        let mut a = app();
        a.playlist_state.select(Some(0));
        a.handle_key(press(KeyCode::Char('k')));
        assert_eq!(a.playlist_state.selected(), Some(0));
        a.handle_key(press(KeyCode::Char('j')));
        a.handle_key(press(KeyCode::Char('j')));
        a.handle_key(press(KeyCode::Char('j')));
        assert_eq!(a.playlist_state.selected(), Some(2));
    }

    #[test]
    fn tab_switches_focus() {
        let mut a = app();
        assert_eq!(a.focus, Focus::Playlists);
        a.handle_key(press(KeyCode::Tab));
        assert_eq!(a.focus, Focus::Tracks);
    }

    #[test]
    fn step_handles_empty_list() {
        let mut s = ListState::default();
        step(&mut s, 0, 1);
        assert_eq!(s.selected(), None);
    }

    #[test]
    fn a_queues_selected_track_with_its_position() {
        let mut a = app_with_tracks();
        a.handle_key(press(KeyCode::Char('a')));
        assert_eq!(a.queue.len(), 1);
        assert_eq!(a.queue[0].playlist, "A");
        assert_eq!(a.queue[0].index, 2);
        assert_eq!(a.queue[0].title, "Track 2");
    }

    #[test]
    fn a_needs_track_focus() {
        let mut a = app_with_tracks();
        a.focus = Focus::Playlists;
        a.handle_key(press(KeyCode::Char('a')));
        assert!(a.queue.is_empty());
        assert!(a.status.is_some());
    }

    #[test]
    fn c_clears_queue() {
        let mut a = app_with_tracks();
        a.queue = vec![queued("1"), queued("2")];
        a.handle_key(press(KeyCode::Char('c')));
        assert!(a.queue.is_empty());
    }

    #[test]
    fn failed_refresh_does_not_touch_the_queue() {
        // On Linux there is no osascript, so refresh fails. The queue must stay intact.
        let mut a = app_with_tracks();
        a.queue = vec![queued("1"), queued("2")];
        a.tick();
        assert_eq!(a.queue.len(), 2);
    }

    #[test]
    fn moving_playlist_cursor_defers_track_loading() {
        let mut a = app();
        a.focus = Focus::Playlists;
        a.handle_key(press(KeyCode::Char('j')));
        assert!(a.tracks_pending.is_some());
        a.tracks_pending = Some(Instant::now() - Duration::from_secs(1));
        a.flush_pending();
        assert!(a.tracks_pending.is_none());
    }

    #[test]
    fn cooldown_blocks_repeat_advances() {
        let mut a = app();
        assert!(a.cooldown_passed());
        a.last_advance = Some(Instant::now());
        assert!(!a.cooldown_passed());
    }
}
