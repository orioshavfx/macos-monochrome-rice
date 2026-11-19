//! Application state and key handling. Independent of the terminal, so the
//! behaviour can be tested without drawing anything.

use crossterm::event::{KeyCode, KeyEvent};
use ratatui::{style::Color, widgets::ListState};

use crate::config::{Config, KeyMap, KeySpec};
use crate::music::{self, NowPlaying, Repeat, TrackRow};

const VOLUME_STEP: u8 = 5;
const SEEK_STEP: f64 = 5.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    Playlists,
    Tracks,
}

pub struct App {
    pub accent: Color,
    pub keys: KeyMap,

    pub now: Option<NowPlaying>,
    pub lyrics: Option<String>,
    pub lyrics_on: bool,
    /// Title of the track the lyrics were loaded for, to reload them on change.
    lyrics_title: Option<String>,

    pub fullscreen: bool,
    pub focus: Focus,

    pub playlists: Vec<String>,
    pub playlist_state: ListState,
    /// Name of the playlist whose tracks are shown in `tracks`.
    pub tracks_of: Option<String>,
    pub tracks: Vec<TrackRow>,
    pub track_state: ListState,

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
            lyrics: None,
            lyrics_on: cfg.view.show_lyrics,
            lyrics_title: None,
            fullscreen: cfg.view.start_fullscreen,
            focus: Focus::Playlists,
            playlists: Vec::new(),
            playlist_state: ListState::default(),
            tracks_of: None,
            tracks: Vec::new(),
            track_state: ListState::default(),
            status: None,
            quit: false,
        }
    }

    /// Load everything once at start-up.
    pub fn start(&mut self) {
        self.refresh_playlists();
        self.refresh_now();
        if self.lyrics_on {
            self.refresh_lyrics();
        }
    }

    fn report<T>(&mut self, result: anyhow::Result<T>) -> Option<T> {
        match result {
            Ok(v) => {
                self.status = None;
                Some(v)
            }
            Err(e) => {
                self.status = Some(format!("{e:#}"));
                None
            }
        }
    }

    pub fn refresh_now(&mut self) {
        if let Some(now) = self.report(music::now_playing()) {
            self.now = now;
        }
        // Reload lyrics when the track changes.
        if self.lyrics_on {
            let title = self.now.as_ref().map(|n| n.title.clone());
            if title != self.lyrics_title {
                self.refresh_lyrics();
            }
        }
    }

    pub fn refresh_playlists(&mut self) {
        if let Some(list) = self.report(music::playlists()) {
            self.playlists = list;
            if self.playlists.is_empty() {
                self.playlist_state.select(None);
            } else if self.playlist_state.selected().is_none() {
                self.playlist_state.select(Some(0));
            }
        }
        self.load_selected_playlist_tracks();
    }

    fn refresh_lyrics(&mut self) {
        self.lyrics_title = self.now.as_ref().map(|n| n.title.clone());
        self.lyrics = self.report(music::current_lyrics()).map(|s| {
            if s.trim().is_empty() {
                "No lyrics for this track (Music.app returns lyrics only for local tracks).".into()
            } else {
                s
            }
        });
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

    /// Periodic refresh of the player state.
    pub fn tick(&mut self) {
        self.refresh_now();
    }

    /// Run a command against Music.app and refresh the state afterwards.
    fn act(&mut self, result: anyhow::Result<()>) {
        if self.report(result).is_some() {
            self.refresh_now();
        }
    }

    pub fn handle_key(&mut self, key: KeyEvent) {
        let k = self.keys.clone();
        let m = |spec: KeySpec| key_matches(spec, &key);

        if m(k.quit) {
            self.quit = true;
        } else if m(k.fullscreen) {
            self.fullscreen = !self.fullscreen;
        } else if m(k.lyrics) {
            self.lyrics_on = !self.lyrics_on;
            if self.lyrics_on {
                self.refresh_lyrics();
            }
        } else if m(k.play_pause) {
            self.act(music::play_pause());
        } else if m(k.next) {
            self.act(music::next_track());
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
        } else if m(k.focus_next) {
            self.focus = match self.focus {
                Focus::Playlists => Focus::Tracks,
                Focus::Tracks => Focus::Playlists,
            };
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
                self.load_selected_playlist_tracks();
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

    fn press(c: KeyCode) -> KeyEvent {
        KeyEvent {
            code: c,
            modifiers: KeyModifiers::NONE,
            kind: KeyEventKind::Press,
            state: KeyEventState::NONE,
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
}
