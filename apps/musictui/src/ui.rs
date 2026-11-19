//! Drawing. Monochrome: everything is white, the accent colour from the config
//! is used for the selection and the progress bar.

use ratatui::{
    prelude::*,
    widgets::{Block, Borders, Gauge, List, ListItem, Paragraph},
};

use crate::app::{App, Focus};
use crate::config::KeyMap;
use crate::cover::PixelCover;
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
    // Tall enough for the pixel cover next to the text.
    let [now_area, lower] =
        Layout::vertical([Constraint::Length(12), Constraint::Min(0)]).areas(right);

    // The queue panel appears under the track list only while something is queued.
    let (main_lower, queue_area) = if app.queue.is_empty() {
        (lower, None)
    } else {
        let height = app.queue.len().min(6) as u16 + 2;
        let [m, q] =
            Layout::vertical([Constraint::Min(0), Constraint::Length(height)]).areas(lower);
        (m, Some(q))
    };

    draw_playlists(frame, app, left);
    draw_now_playing(frame, app, now_area);
    draw_tracks(frame, app, main_lower);
    if let Some(q) = queue_area {
        draw_queue(frame, app, q);
    }
    draw_footer(frame, app, footer);
}

fn draw_queue(frame: &mut Frame, app: &App, area: Rect) {
    let title = format!("Queue ({})", app.queue.len());
    let items: Vec<ListItem> = app
        .queue
        .iter()
        .enumerate()
        .map(|(i, q)| {
            ListItem::new(format!(
                "{:>2}. {:<40} {:<24} {}",
                i + 1,
                truncate(&q.title, 40),
                truncate(&q.artist, 24),
                fmt_time(q.duration)
            ))
        })
        .collect();
    frame.render_widget(List::new(items).block(block(&title, app)), area);
}

fn draw_fullscreen(frame: &mut Frame, app: &App, area: Rect) {
    let [_, centre, _] = Layout::horizontal([
        Constraint::Percentage(15),
        Constraint::Percentage(70),
        Constraint::Percentage(15),
    ])
    .areas(area);
    // With artwork the cover fills the space above the track info.
    let (cover_area, info, footer) = if app.cover.is_some() {
        let [c, i, f] = Layout::vertical([
            Constraint::Min(0),
            Constraint::Length(10),
            Constraint::Length(2),
        ])
        .areas(centre);
        (Some(c), i, f)
    } else {
        let [_, i, _, f] = Layout::vertical([
            Constraint::Percentage(20),
            Constraint::Length(10),
            Constraint::Min(0),
            Constraint::Length(2),
        ])
        .areas(centre);
        (None, i, f)
    };

    if let (Some(area), Some(img)) = (cover_area, app.cover.as_ref()) {
        frame.render_widget(PixelCover { img }, area);
    }
    draw_now_playing(frame, app, info);
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

/// Splits `area` into a cover column and the text area. Without artwork the
/// text gets the whole area.
fn with_cover(app: &App, area: Rect) -> (Option<Rect>, Rect) {
    if app.cover.is_none() {
        return (None, area);
    }
    let cover_w = (area.height * 2).min(area.width / 2);
    let [cover, _, text] = Layout::horizontal([
        Constraint::Length(cover_w),
        Constraint::Length(2),
        Constraint::Min(0),
    ])
    .areas(area);
    (Some(cover), text)
}

fn draw_now_playing(frame: &mut Frame, app: &App, area: Rect) {
    let now_block = block("Now playing", app);
    let inner = now_block.inner(area);
    frame.render_widget(now_block, area);

    let (cover_area, text_area) = with_cover(app, inner);
    if let (Some(cover_area), Some(img)) = (cover_area, app.cover.as_ref()) {
        frame.render_widget(PixelCover { img }, cover_area);
    }

    let Some(now) = app.now.as_ref() else {
        frame.render_widget(
            Paragraph::new("Nothing is playing. Pick a playlist and press Enter.")
                .alignment(Alignment::Center),
            text_area,
        );
        return;
    };

    // Six text rows, centred vertically in the available height.
    let [_, title, artist, _, gauge, times, controls, _] = Layout::vertical([
        Constraint::Min(0),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Length(1),
        Constraint::Min(0),
    ])
    .areas(text_area);

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
        "{} play/pause · {} next · {} prev · {} shuffle · {} repeat · {}/{} volume · {}/{} seek · {} {}",
        k(keys.play_pause),
        k(keys.next),
        k(keys.previous),
        k(keys.shuffle),
        k(keys.repeat),
        k(keys.volume_up),
        k(keys.volume_down),
        k(keys.seek_back),
        k(keys.seek_forward),
        if fullscreen { "exit fullscreen" } else { "fullscreen" },
        k(keys.fullscreen),
    );
    if fullscreen {
        format!("{transport} · {} quit", k(keys.quit))
    } else {
        format!(
            "{transport} · {} switch · {}/{} move · {} play · {} queue · {} clear queue · {} quit",
            k(keys.focus_next),
            k(keys.up),
            k(keys.down),
            k(keys.select),
            k(keys.queue_add),
            k(keys.queue_clear),
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

#[cfg(test)]
mod render_tests {
    use super::*;
    use crate::app::{App, QueueItem};
    use crate::config::{Config, Keys};
    use ratatui::{backend::TestBackend, Terminal};

    fn item(n: usize) -> QueueItem {
        QueueItem {
            playlist: "P".into(),
            index: n,
            title: format!("Song {n}"),
            artist: "Band".into(),
            duration: 200.0,
        }
    }

    fn render(app: &App, w: u16, h: u16) -> String {
        let mut term = Terminal::new(TestBackend::new(w, h)).unwrap();
        term.draw(|f| draw(f, app)).unwrap();
        let buf = term.backend().buffer().clone();
        buf.content().iter().map(|c| c.symbol()).collect()
    }

    fn app_with(queue: Vec<QueueItem>) -> App {
        let cfg = Config::default();
        let keys = KeyMap::from_config(&Keys::default()).unwrap();
        let mut app = App::new(&cfg, keys, ratatui::style::Color::White);
        app.queue = queue;
        app
    }

    #[test]
    fn draws_without_queue() {
        let text = render(&app_with(vec![]), 100, 30);
        assert!(text.contains("Playlists"));
        assert!(!text.contains("Queue ("));
    }

    #[test]
    fn draws_queue_panel_with_items() {
        let text = render(&app_with(vec![item(1), item(2)]), 100, 30);
        assert!(text.contains("Queue (2)"));
        assert!(text.contains("Song 2"));
    }

    #[test]
    fn long_queue_is_capped_and_small_terminal_does_not_panic() {
        let many: Vec<QueueItem> = (1..=20).map(item).collect();
        let _ = render(&app_with(many.clone()), 100, 30);
        let _ = render(&app_with(many), 40, 10);
    }

    fn with_cover_art(mut app: App) -> App {
        app.cover = Some(image::RgbImage::from_pixel(
            4,
            4,
            image::Rgb([200, 120, 40]),
        ));
        app
    }

    #[test]
    fn draws_pixel_cover_when_artwork_is_loaded() {
        let text = render(&with_cover_art(app_with(vec![])), 100, 30);
        assert!(text.contains('▀'));
    }

    #[test]
    fn fullscreen_with_cover_and_small_terminal_does_not_panic() {
        let mut app = with_cover_art(app_with(vec![]));
        app.fullscreen = true;
        let _ = render(&app, 100, 30);
        let _ = render(&app, 20, 8);
    }
}
