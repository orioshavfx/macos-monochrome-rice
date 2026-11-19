//! musictui: a terminal front-end for Music.app on macOS.
//! Configuration lives in `~/.config/musictui/config.toml`; see `configs/musictui/config.toml`.

mod app;
mod config;
mod music;
mod ui;

use std::time::Duration;

use anyhow::Result;
use crossterm::event::{self, Event, KeyEventKind};

use app::App;
use config::{Config, KeyMap};

fn main() -> Result<()> {
    if std::env::args().any(|a| a == "-h" || a == "--help") {
        println!(
            "musictui: terminal player for Music.app (macOS). Edit ~/.config/musictui/config.toml."
        );
        return Ok(());
    }

    // Validate the config before taking over the terminal, so errors are readable.
    let cfg = Config::load()?;
    let accent = cfg.accent_color()?;
    let keys = KeyMap::from_config(&cfg.keys)?;
    let poll = Duration::from_millis(cfg.view.poll_ms.max(100));

    let mut app = App::new(&cfg, keys, accent);
    app.start();

    let mut terminal = ratatui::init();
    let result = run(&mut terminal, &mut app, poll);
    ratatui::restore();
    result
}

fn run(terminal: &mut ratatui::DefaultTerminal, app: &mut App, poll: Duration) -> Result<()> {
    while !app.quit {
        app.flush_pending();
        terminal.draw(|frame| ui::draw(frame, app))?;
        if event::poll(poll)? {
            if let Event::Key(key) = event::read()? {
                // Only react to key presses; some terminals also report releases.
                if key.kind == KeyEventKind::Press {
                    app.handle_key(key);
                }
            }
        } else {
            app.tick();
        }
    }
    Ok(())
}
