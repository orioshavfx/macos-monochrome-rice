//! User configuration, read from `~/.config/musictui/config.toml`.
//! Every field has a default, so a missing file or a partial file both work.

use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use ratatui::style::Color;
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize, Default)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub view: View,
    pub keys: Keys,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct View {
    /// Accent colour as `#rrggbb`. Monochrome by default.
    pub accent: String,
    /// How often the player state is refreshed, in milliseconds.
    pub poll_ms: u64,
    /// Start in fullscreen (now playing only) mode.
    pub start_fullscreen: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Keys {
    pub play_pause: String,
    pub next: String,
    pub previous: String,
    pub shuffle: String,
    pub repeat: String,
    pub volume_up: String,
    pub volume_down: String,
    pub seek_forward: String,
    pub seek_back: String,
    pub fullscreen: String,
    pub queue_add: String,
    pub queue_clear: String,
    pub focus_next: String,
    pub up: String,
    pub down: String,
    pub select: String,
    pub quit: String,
}

impl Default for View {
    fn default() -> Self {
        Self {
            accent: "#ffffff".into(),
            poll_ms: 1000,
            start_fullscreen: false,
        }
    }
}

impl Default for Keys {
    fn default() -> Self {
        Self {
            play_pause: "space".into(),
            next: "n".into(),
            previous: "p".into(),
            shuffle: "s".into(),
            repeat: "r".into(),
            volume_up: "+".into(),
            volume_down: "-".into(),
            seek_forward: "right".into(),
            seek_back: "left".into(),
            fullscreen: "f".into(),
            queue_add: "a".into(),
            queue_clear: "c".into(),
            focus_next: "tab".into(),
            up: "k".into(),
            down: "j".into(),
            select: "enter".into(),
            quit: "q".into(),
        }
    }
}

impl Config {
    /// Path of the config file: `$XDG_CONFIG_HOME/musictui/config.toml`,
    /// falling back to `~/.config/musictui/config.toml`.
    pub fn default_path() -> Option<PathBuf> {
        let base = std::env::var_os("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
        Some(base.join("musictui").join("config.toml"))
    }

    /// Load the config. A missing file yields the defaults; a broken file is an error,
    /// so the user sees what is wrong instead of silently getting defaults.
    pub fn load() -> Result<Self> {
        let Some(path) = Self::default_path() else {
            return Ok(Self::default());
        };
        if !path.exists() {
            return Ok(Self::default());
        }
        let text = std::fs::read_to_string(&path)
            .with_context(|| format!("reading {}", path.display()))?;
        toml::from_str(&text).with_context(|| format!("parsing {}", path.display()))
    }

    /// Accent colour from `view.accent`.
    pub fn accent_color(&self) -> Result<Color> {
        parse_hex_color(&self.view.accent)
    }
}

/// Parse `#rrggbb` (the leading `#` is optional).
pub fn parse_hex_color(s: &str) -> Result<Color> {
    let hex = s.trim().trim_start_matches('#');
    if hex.len() != 6 || !hex.chars().all(|c| c.is_ascii_hexdigit()) {
        bail!("invalid colour {s:?}, expected #rrggbb");
    }
    let r = u8::from_str_radix(&hex[0..2], 16)?;
    let g = u8::from_str_radix(&hex[2..4], 16)?;
    let b = u8::from_str_radix(&hex[4..6], 16)?;
    Ok(Color::Rgb(r, g, b))
}

/// A key as written in the config file: a single character or a named key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeySpec {
    Char(char),
    Space,
    Enter,
    Tab,
    Left,
    Right,
    Up,
    Down,
    Esc,
}

impl KeySpec {
    pub fn parse(s: &str) -> Result<Self> {
        let lower = s.trim().to_ascii_lowercase();
        Ok(match lower.as_str() {
            "space" => Self::Space,
            "enter" | "return" => Self::Enter,
            "tab" => Self::Tab,
            "left" => Self::Left,
            "right" => Self::Right,
            "up" => Self::Up,
            "down" => Self::Down,
            "esc" | "escape" => Self::Esc,
            _ => {
                let mut chars = s.trim().chars();
                match (chars.next(), chars.next()) {
                    (Some(c), None) => Self::Char(c),
                    _ => bail!("unknown key {s:?}"),
                }
            }
        })
    }
}

/// Keys resolved from the config, ready for matching against crossterm events.
#[derive(Debug, Clone)]
pub struct KeyMap {
    pub play_pause: KeySpec,
    pub next: KeySpec,
    pub previous: KeySpec,
    pub shuffle: KeySpec,
    pub repeat: KeySpec,
    pub volume_up: KeySpec,
    pub volume_down: KeySpec,
    pub seek_forward: KeySpec,
    pub seek_back: KeySpec,
    pub fullscreen: KeySpec,
    pub queue_add: KeySpec,
    pub queue_clear: KeySpec,
    pub focus_next: KeySpec,
    pub up: KeySpec,
    pub down: KeySpec,
    pub select: KeySpec,
    pub quit: KeySpec,
}

impl KeyMap {
    pub fn from_config(keys: &Keys) -> Result<Self> {
        let p = |name: &str, v: &str| -> Result<KeySpec> {
            KeySpec::parse(v).with_context(|| format!("keys.{name}"))
        };
        Ok(Self {
            play_pause: p("play_pause", &keys.play_pause)?,
            next: p("next", &keys.next)?,
            previous: p("previous", &keys.previous)?,
            shuffle: p("shuffle", &keys.shuffle)?,
            repeat: p("repeat", &keys.repeat)?,
            volume_up: p("volume_up", &keys.volume_up)?,
            volume_down: p("volume_down", &keys.volume_down)?,
            seek_forward: p("seek_forward", &keys.seek_forward)?,
            seek_back: p("seek_back", &keys.seek_back)?,
            fullscreen: p("fullscreen", &keys.fullscreen)?,
            queue_add: p("queue_add", &keys.queue_add)?,
            queue_clear: p("queue_clear", &keys.queue_clear)?,
            focus_next: p("focus_next", &keys.focus_next)?,
            up: p("up", &keys.up)?,
            down: p("down", &keys.down)?,
            select: p("select", &keys.select)?,
            quit: p("quit", &keys.quit)?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_file_gives_defaults() {
        let c: Config = toml::from_str("").unwrap();
        assert_eq!(c.view.accent, "#ffffff");
        assert_eq!(c.keys.play_pause, "space");
        assert_eq!(c.view.poll_ms, 1000);
    }

    #[test]
    fn partial_file_overrides_only_given_keys() {
        let c: Config =
            toml::from_str("[keys]\nquit = \"x\"\n[view]\nstart_fullscreen = true\n").unwrap();
        assert_eq!(c.keys.quit, "x");
        assert_eq!(c.keys.next, "n");
        assert!(c.view.start_fullscreen);
    }

    #[test]
    fn unknown_field_is_rejected() {
        assert!(toml::from_str::<Config>("[view]\nnonsense = 1\n").is_err());
    }

    #[test]
    fn hex_colour_parsing() {
        assert_eq!(
            parse_hex_color("#ffffff").unwrap(),
            Color::Rgb(255, 255, 255)
        );
        assert_eq!(
            parse_hex_color("102030").unwrap(),
            Color::Rgb(0x10, 0x20, 0x30)
        );
        assert!(parse_hex_color("#fff").is_err());
        assert!(parse_hex_color("#gggggg").is_err());
    }

    #[test]
    fn key_specs() {
        assert_eq!(KeySpec::parse("space").unwrap(), KeySpec::Space);
        assert_eq!(KeySpec::parse("Enter").unwrap(), KeySpec::Enter);
        assert_eq!(KeySpec::parse("k").unwrap(), KeySpec::Char('k'));
        assert_eq!(KeySpec::parse("+").unwrap(), KeySpec::Char('+'));
        assert!(KeySpec::parse("ctrl-x").is_err());
    }

    #[test]
    fn shipped_example_config_is_valid() {
        // The example copied to ~/.config by install.sh must always load with this code.
        let text = include_str!("../../../configs/musictui/config.toml");
        let c: Config = toml::from_str(text).expect("example config parses");
        KeyMap::from_config(&c.keys).expect("example keys resolve");
        c.accent_color().expect("example accent is valid");
        assert_eq!(c.keys.quit, "q");
    }

    #[test]
    fn default_keymap_resolves() {
        assert!(KeyMap::from_config(&Keys::default()).is_ok());
    }
}
