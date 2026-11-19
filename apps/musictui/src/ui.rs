//! Drawing. Monochrome: everything is white, the accent colour from the config
//! is used for the selection and the progress bar.

use ratatui::{
    prelude::*,
    widgets::{Block, Borders, Gauge, List, ListItem, Paragraph, Wrap},
};

use crate::app::{App, Focus};
use crate::config::KeyMap;
use crate::music::{NowPlaying, PlayerState, Repeat};

pub fn draw(frame: &mut Frame, app: &App) {
    let area = frame.area();
    if app.fullscreen {
        draw_fullscreen(frame, app, area);
    } else {
        draw_normal(frame, app, area);
    }
}

fn draw_normal(frame: &mut Frame, app: &App, area: Rect) {
    let [main, footer] = Layout::vertical([Constraint::Min(0), Constraint::Length(2)]).areas(area);
    let [left, right] =
        Layout::horizontal([Constraint::Length(28), Constraint::Min(0)]).areas(main);
    let [now_area, lower] =
        Layout::vertical([Constraint::Length(9), Constraint::Min(0)]).areas(right);

    draw_playlists(frame, app, left);
    draw_now_playing(frame, app, now_area);
    if app.lyrics_on {
        draw_lyrics(frame, app, lower);
    } else {
        draw_tracks(frame, app, lower);
    }
    draw_footer(frame, app, footer);
}

fn draw_fullscreen(frame: &mut Frame, app: &App, area: Rect) {
    let [_, centre, _] = Layout::horizontal([
        Constraint::Percentage(15),
        Constraint::Percentage(70),
        Constraint::Percentage(15),
    ])
    .areas(area);
    let [_, info, lyrics, footer] = Layout::vertical([
        Constraint::Percentage(20),
        Constraint::Length(10),
        Constraint::Min(0),
        Constraint::Length(2),
    ])
    .areas(centre);

    draw_now_playing(frame, app, info);
    if app.lyrics_on {
        draw_lyrics(frame, app, lyrics);
    }
    draw_footer(frame, app, footer);
}

fn block<'a>(title: &'a str, app: &App) -> Block<'a> {
    Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(app.accent))
        .title(Span::styled(title, Style::default().fg(app.accent).bold()))
}

fn draw_playlists(frame: &mut Frame, app: &App, area: Rect) {
    let items: Vec<ListItem> = app
        .playlists
        .iter()
        .map(|p| ListItem::new(p.as_str()))
        .collect();
    let list = List::new(items)
        .block(block("Playlists", app))
        .highlight_style(highlight(app, app.focus == Focus::Playlists))
        .highlight_symbol("> ");
    let mut state = app.playlist_state.clone();
    frame.render_stateful_widget(list, area, &mut state);
}

fn draw_tracks(frame: &mut Frame, app: &App, area: Rect) {
    let title = app.tracks_of.as_deref().unwrap_or("Tracks");
    let items: Vec<ListItem> = app
        .tracks
        .iter()
        .map(|t| {
            ListItem::new(format!(
                "{:<40} {:<24} {}",
                truncate(&t.title, 40),
                truncate(&t.artist, 24),
                fmt_time(t.duration)
            ))
        })
        .collect();
    let list = List::new(items)
        .block(block(title, app))
        .highlight_style(highlight(app, app.focus == Focus::Tracks))
        .highlight_symbol("> ");
    let mut state = app.track_state.clone();
    frame.render_stateful_widget(list, area, &mut state);
}

fn draw_lyrics(frame: &mut Frame, app: &App, area: Rect) {
    let text = app
        .lyrics
        .clone()
        .unwrap_or_else(|| "Lyrics are not loaded.".into());
    let p = Paragraph::new(text)
        .block(block("Lyrics", app))
        .wrap(Wrap { trim: false })
        .alignment(Alignment::Center);
    frame.render_widget(p, area);
}

fn draw_now_playing(frame: &mut Frame, app: &App, area: Rect) {
    let inner_block = block("Now playing", app);
    let inner = inner_block.inner(area);
    frame.render_widget(inner_block, area);

    let Some(now) = app.now.as_ref() else {
        frame.render_widget(
            Paragraph::new("Nothing is playing. Pick a playlist and press Enter.")
                .alignment(Alignment::Center),
            inner,
        );
        return;
    };

    let [title, artist, _, gauge, times, controls] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
    ])
    .areas(inner);

    let state_glyph = match now.state {
        PlayerState::Playing => "▶",
        PlayerState::Paused => "❚❚",
        _ => "■",
    };
    frame.render_widget(
        Paragraph::new(format!("{state_glyph}  {}", now.title))
            .style(Style::default().bold())
            .alignment(Alignment::Center),
        title,
    );
    frame.render_widget(
        Paragraph::new(join_nonempty(&[&now.artist, &now.album], " · "))
            .alignment(Alignment::Center),
        artist,
    );

    let ratio = if now.duration > 0.0 {
        (now.position / now.duration).clamp(0.0, 1.0)
    } else {
        0.0
    };
    frame.render_widget(
        Gauge::default()
            .gauge_style(Style::default().fg(app.accent))
            .ratio(ratio)
            .label(""),
        gauge,
    );
    frame.render_widget(
        Paragraph::new(format!(
            "{} / {}",
            fmt_time(now.position),
            fmt_time(now.duration)
        ))
        .alignment(Alignment::Center),
        times,
    );
    frame.render_widget(
        Paragraph::new(controls_line(now)).alignment(Alignment::Center),
        controls,
    );
}

fn controls_line(now: &NowPlaying) -> String {
    format!(
        "shuffle {}   repeat {}   volume {}",
        on_off(now.shuffle),
        repeat_label(&now.repeat),
        now.volume
    )
}

fn draw_footer(frame: &mut Frame, app: &App, area: Rect) {
    let help = help_line(&app.keys, app.fullscreen);
    let mut lines = vec![Line::from(Span::styled(help, Style::default().dim()))];
    if let Some(msg) = &app.status {
        lines.push(Line::from(Span::styled(
            truncate(msg, area.width as usize),
            Style::default().fg(app.accent),
        )));
    }
    frame.render_widget(Paragraph::new(lines), area);
}

fn highlight(app: &App, focused: bool) -> Style {
    if focused {
        Style::default().fg(Color::Black).bg(app.accent).bold()
    } else {
        Style::default().fg(app.accent)
    }
}

/// Human-readable key help, built from the configured keys.
pub fn help_line(keys: &KeyMap, fullscreen: bool) -> String {
    let k = |s: crate::config::KeySpec| key_label(s);
    let transport = format!(
        "{} play/pause · {} next · {} prev · {} shuffle · {} repeat · {}/{} volume · {}/{} seek · {} lyrics · {} {}",
        k(keys.play_pause),
        k(keys.next),
        k(keys.previous),
        k(keys.shuffle),
        k(keys.repeat),
        k(keys.volume_up),
        k(keys.volume_down),
        k(keys.seek_back),
        k(keys.seek_forward),
        k(keys.lyrics),
        if fullscreen { "exit fullscreen" } else { "fullscreen" },
        k(keys.fullscreen),
    );
    if fullscreen {
        format!("{transport} · {} quit", k(keys.quit))
    } else {
        format!(
            "{transport} · {} switch · {}/{} move · {} play · {} quit",
            k(keys.focus_next),
            k(keys.up),
            k(keys.down),
            k(keys.select),
            k(keys.quit),
        )
    }
}

fn key_label(spec: crate::config::KeySpec) -> String {
    use crate::config::KeySpec::*;
    match spec {
        Char(c) => c.to_string(),
        Space => "space".into(),
        Enter => "enter".into(),
        Tab => "tab".into(),
        Left => "←".into(),
        Right => "→".into(),
        Up => "↑".into(),
        Down => "↓".into(),
        Esc => "esc".into(),
    }
}

fn repeat_label(r: &Repeat) -> &'static str {
    match r {
        Repeat::Off => "off",
        Repeat::One => "one",
        Repeat::All => "all",
    }
}

fn on_off(b: bool) -> &'static str {
    if b {
        "on"
    } else {
        "off"
    }
}

/// `m:ss` for a duration in seconds.
pub fn fmt_time(seconds: f64) -> String {
    let total = seconds.max(0.0).round() as u64;
    format!("{}:{:02}", total / 60, total % 60)
}

fn join_nonempty(parts: &[&str], sep: &str) -> String {
    parts
        .iter()
        .filter(|s| !s.is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join(sep)
}

/// Shorten to `max` characters, adding an ellipsis when cut.
fn truncate(s: &str, max: usize) -> String {
    if max == 0 {
        return String::new();
    }
    if s.chars().count() <= max {
        return s.to_string();
    }
    let mut out: String = s.chars().take(max.saturating_sub(1)).collect();
    out.push('…');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn time_formatting() {
        assert_eq!(fmt_time(0.0), "0:00");
        assert_eq!(fmt_time(65.4), "1:05");
        assert_eq!(fmt_time(3599.6), "60:00");
        assert_eq!(fmt_time(-3.0), "0:00");
    }

    #[test]
    fn truncate_is_char_safe() {
        assert_eq!(truncate("привет мир", 6), "приве…");
        assert_eq!(truncate("abc", 10), "abc");
        assert_eq!(truncate("abc", 0), "");
    }

    #[test]
    fn join_skips_empty_parts() {
        assert_eq!(join_nonempty(&["A", "", "B"], " · "), "A · B");
    }

    #[test]
    fn help_line_uses_configured_keys() {
        let keys = KeyMap::from_config(&crate::config::Keys::default()).unwrap();
        let line = help_line(&keys, true);
        assert!(line.contains("space play/pause"));
        assert!(line.contains("exit fullscreen"));
    }
}
