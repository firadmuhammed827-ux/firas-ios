"""Generate deterministic iOS bitmap assets from the repository's canonical Firas mark."""

from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
APP_ICON_DIR = ROOT / "FirasAI" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"


def render_icon(filename: str, background: str, accent: str, deep: str) -> None:
    scale = 64
    canvas_size = 1024
    image = Image.new("RGB", (canvas_size * 4, canvas_size * 4), background)
    draw = ImageDraw.Draw(image)

    def polygon(points: list[tuple[float, float]], color: str) -> None:
        draw.polygon([(x * scale, y * scale) for x, y in points], fill=color)

    polygon([(18, 10), (24.5, 10), (24.5, 54), (18, 54)], accent)
    polygon([(24.5, 10), (50, 10), (45, 18.5), (24.5, 18.5)], accent)
    polygon([(24.5, 27), (42, 27), (37.5, 35.5), (24.5, 35.5)], deep)

    image = image.resize((canvas_size, canvas_size), Image.Resampling.LANCZOS)
    APP_ICON_DIR.mkdir(parents=True, exist_ok=True)
    image.save(APP_ICON_DIR / filename, optimize=True)


def main() -> None:
    render_icon("AppIcon-1024.png", "#14201D", "#57AE9C", "#2F6F62")
    render_icon("AppIcon-Dark-1024.png", "#050807", "#6BC0AE", "#397F70")
    render_icon("AppIcon-Tinted-1024.png", "#161616", "#F1F1EC", "#A9AAA5")


if __name__ == "__main__":
    main()
