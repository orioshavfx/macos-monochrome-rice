//! Pixel cover art. The artwork keeps its colours and is drawn with half-block
//! characters: each terminal cell shows two pixels, the upper one as the character's
//! foreground and the lower one as its background. The result is square.

use std::path::Path;
use std::process::Command;

use anyhow::{bail, Context, Result};
use image::{imageops::FilterType, RgbImage};
use ratatui::{buffer::Buffer, layout::Rect, style::Color, widgets::Widget};

/// Side of the stored cover in pixels. Large enough for the full-screen view.
pub const SOURCE_SIZE: u32 = 128;

/// Decode the raw artwork (any format Music.app stores) into an RGB square.
/// `sips` ships with macOS and converts it to PNG first, so only PNG has to be decoded.
pub fn load(raw: &Path, work_png: &Path) -> Result<RgbImage> {
    let out = Command::new("sips")
        .args(["-s", "format", "png"])
        .arg(raw)
        .arg("--out")
        .arg(work_png)
        .output()
        .context("failed to run sips")?;
    if !out.status.success() {
        bail!(
            "sips could not convert the artwork: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    let img = image::open(work_png).context("decoding cover image")?;
    Ok(img
        .resize_exact(SOURCE_SIZE, SOURCE_SIZE, FilterType::Triangle)
        .to_rgb8())
}

/// Colour of the source pixel at column `gx`, row `gy` of a grid that is
/// `cols` pixels wide and `grid_h` pixels high.
fn sample(img: &RgbImage, gx: u32, gy: u32, cols: u32, grid_h: u32) -> Color {
    let x = (gx * img.width() / cols).min(img.width() - 1);
    let y = (gy * img.height() / grid_h).min(img.height() - 1);
    let [r, g, b] = img.get_pixel(x, y).0;
    Color::Rgb(r, g, b)
}

/// Widget that draws the cover as large as the area allows, centred, square in pixels.
pub struct PixelCover<'a> {
    pub img: &'a RgbImage,
}

/// Size in terminal cells of a square cover that fits `area`: `(cols, rows)`.
/// Cells are about twice as tall as they are wide, so `cols = 2 * rows` is square.
pub fn fit(area: Rect) -> (u16, u16) {
    let rows = area.height.min(area.width / 2);
    (rows * 2, rows)
}

impl Widget for PixelCover<'_> {
    fn render(self, area: Rect, buf: &mut Buffer) {
        let (cols, rows) = fit(area);
        if cols == 0 || rows == 0 {
            return;
        }
        let x0 = area.x + (area.width - cols) / 2;
        let y0 = area.y + (area.height - rows) / 2;
        let grid_h = rows as u32 * 2;
        for cy in 0..rows {
            for cx in 0..cols {
                let top = sample(self.img, cx as u32, cy as u32 * 2, cols as u32, grid_h);
                let bottom = sample(self.img, cx as u32, cy as u32 * 2 + 1, cols as u32, grid_h);
                let cell = &mut buf[(x0 + cx, y0 + cy)];
                cell.set_char('▀');
                cell.set_fg(top);
                cell.set_bg(bottom);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use image::Rgb;

    /// 2x2 image: top row red, bottom row blue.
    fn two_by_two() -> RgbImage {
        let mut img = RgbImage::new(2, 2);
        img.put_pixel(0, 0, Rgb([255, 0, 0]));
        img.put_pixel(1, 0, Rgb([255, 0, 0]));
        img.put_pixel(0, 1, Rgb([0, 0, 255]));
        img.put_pixel(1, 1, Rgb([0, 0, 255]));
        img
    }

    #[test]
    fn fit_is_square_in_pixels() {
        assert_eq!(fit(Rect::new(0, 0, 80, 10)), (20, 10));
        assert_eq!(fit(Rect::new(0, 0, 10, 40)), (10, 5));
        assert_eq!(fit(Rect::new(0, 0, 0, 0)), (0, 0));
    }

    #[test]
    fn sampling_picks_the_right_pixel() {
        let img = two_by_two();
        // Grid 2 columns x 4 rows: rows 0-1 come from the red top row.
        assert_eq!(sample(&img, 0, 0, 2, 4), Color::Rgb(255, 0, 0));
        assert_eq!(sample(&img, 1, 1, 2, 4), Color::Rgb(255, 0, 0));
        assert_eq!(sample(&img, 0, 3, 2, 4), Color::Rgb(0, 0, 255));
    }

    #[test]
    fn renders_half_blocks_with_colours_kept() {
        let img = two_by_two();
        let area = Rect::new(0, 0, 4, 1);
        let mut buf = Buffer::empty(area);
        PixelCover { img: &img }.render(area, &mut buf);
        let cell = &buf[(1, 0)];
        assert_eq!(cell.symbol(), "▀");
        assert_eq!(cell.fg, Color::Rgb(255, 0, 0));
        assert_eq!(cell.bg, Color::Rgb(0, 0, 255));
    }
}
