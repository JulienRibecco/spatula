#!/usr/bin/env python3
"""Render the README orbit from real Lua samples. Requires Pillow; no browser."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

from PIL import Image, ImageDraw, ImageFont
from package import ROOT, build

WIDTH, HEIGHT, SCALE = 1120, 440, 2
FPS, SECONDS, SAMPLES = 25, 4, 1600
PAPER = (246, 243, 235)
INK = (39, 47, 45)
MUTED = (117, 119, 109)
ACCENT = (166, 72, 47)


def font(size, kind="mono"):
    candidates = {
        "serif": ["/System/Library/Fonts/Supplemental/Georgia.ttf",
                  "/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf"],
        "italic": ["/System/Library/Fonts/Supplemental/Georgia Italic.ttf",
                   "/usr/share/fonts/truetype/dejavu/DejaVuSerif-Italic.ttf"],
        "mono": ["/System/Library/Fonts/Supplemental/Courier New.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"],
    }
    for candidate in candidates[kind]:
        if Path(candidate).is_file():
            return ImageFont.truetype(candidate, round(size * SCALE))
    raise RuntimeError("Install Georgia/Courier New or DejaVu Serif/Mono fonts")


def mix(a, b, amount):
    return tuple(round(x + (y - x) * amount) for x, y in zip(a, b))


def sample_recipe(lua):
    with tempfile.TemporaryDirectory(prefix="spatula-render-") as directory:
        project = Path(directory)
        archive, _ = build(project / "spatula.zip")
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(project)
        shutil.copy2(ROOT / "examples/orbit.lua", project / "orbit.lua")
        script = project / "sample.lua"
        script.write_text('''local orbit = dofile("orbit.lua")
local count, period = tonumber(arg[1]), tonumber(arg[2])
for i = 0, count do
    local x, y = orbit(i * period / count, {})
    assert(x == x and y == y and math.abs(x) < 1000 and math.abs(y) < 1000)
    io.write(string.format("%.12g,%.12g\\n", x, y))
end
''')
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("LUA_PATH", "LUA_CPATH", "LUA_INIT"))}
        result = subprocess.run([lua, str(script), str(SAMPLES), str(SECONDS)],
                                cwd=project, env=env, text=True, capture_output=True, check=True)
        points = [tuple(map(float, row.split(","))) for row in result.stdout.splitlines()]
        assert len(points) == SAMPLES + 1
        assert math.dist(points[0], points[-1]) < 1e-7, "Recipe must loop seamlessly"
        return points[:-1]


def render(points):
    base = Image.new("RGB", (WIDTH * SCALE, HEIGHT * SCALE), PAPER)
    draw = ImageDraw.Draw(base)

    def text(x, y, value, size=11, color=MUTED, kind="mono"):
        draw.text((x * SCALE, y * SCALE), value, font=font(size, kind), fill=color)

    def line(coords, fill, width=1):
        draw.line([(x * SCALE, y * SCALE) for x, y in coords], fill=fill, width=round(width * SCALE))

    for x in range(574, WIDTH - 25, 22):
        for y in range(72, HEIGHT - 35, 22):
            draw.ellipse((x * SCALE, y * SCALE, x * SCALE + 2, y * SCALE + 2), fill=(220, 219, 209))
    text(42, 34, "S P A T U L A   /   M O T I O N   S T U D Y   0 1", 10)
    line([(42, 68), (1078, 68)], (214, 214, 203))
    text(42, 108, "Small functions.", 42, INK, "serif")
    text(42, 161, "Complex motion.", 42, ACCENT, "italic")
    text(45, 239, "A circle, a changing radius, a rotation.", 12, INK)
    text(45, 261, "Every point comes from the Lua recipe below.", 11)
    line([(45, 324), (492, 324)], (214, 214, 203))
    for x, label in [(45, "01 / CIRCLE"), (207, "02 / SCALE"), (366, "03 / ROTATE")]:
        text(x, 343, label, 10)
    text(45, 388, "f(t, ctx)  ->  x, y", 11, INK)
    text(888, 401, "4 SECOND LOOP / LUA", 10)

    cx, cy = 821, 232

    def position(index, lane):
        x, y = points[index % SAMPLES]
        scale = 0.64 + lane * 0.12
        return ((cx + x * scale) * SCALE, (cy + y * scale) * SCALE)

    for lane in range(6):
        track = [position(i, lane) for i in range(0, SAMPLES, 4)]
        draw.line(track + track[:1], fill=(222, 221, 210), width=SCALE)
    line([(cx - 5, cy), (cx + 5, cy)], (181, 185, 173))
    line([(cx, cy - 5), (cx, cy + 5)], (181, 185, 173))
    frames = []
    for frame in range(FPS * SECONDS):
        image = base.copy()
        brush = ImageDraw.Draw(image)
        for lane in range(6):
            head = round(frame * SAMPLES / (FPS * SECONDS) + lane * SAMPLES / 9)
            color = ACCENT if lane in (1, 4, 5) else INK
            trail = SAMPLES // 5
            for step in range(0, trail, 4):
                index = head - trail + step
                amount = (step / trail) ** 0.7 * 0.85
                brush.line([position(index, lane), position(index + 4, lane)],
                           fill=mix(PAPER, color, amount), width=2 * SCALE)
            x, y = position(head, lane)
            r = 3.5 * SCALE
            brush.ellipse((x - r, y - r, x + r, y + r), fill=color)
            r = 1.1 * SCALE
            brush.ellipse((x - r, y - r, x + r, y + r), fill=PAPER)
        frames.append(image.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS))
    return frames


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default="lua")
    parser.add_argument("--output", type=Path, default=ROOT / "docs/assets")
    args = parser.parse_args()
    lua = shutil.which(args.lua)
    if not lua:
        parser.error("Lua executable not found: " + args.lua)
    points = sample_recipe(str(Path(lua).resolve()))
    frames = render(points)
    args.output.mkdir(parents=True, exist_ok=True)
    # One shared palette keeps the paper and typography stable between frames.
    palette = frames[0].quantize(colors=128, method=Image.Quantize.MEDIANCUT)
    indexed = [frame.quantize(palette=palette, dither=Image.Dither.NONE) for frame in frames]
    indexed[0].save(args.output / "orbit.gif", save_all=True, append_images=indexed[1:],
                    duration=1000 // FPS, loop=0, optimize=True, disposal=1)
    frames[0].save(args.output / "orbit.png", optimize=True)
    recipe_hash = hashlib.sha256((ROOT / "examples/orbit.lua").read_bytes()).hexdigest()
    (args.output / "orbit.json").write_text(json.dumps({
        "recipe": "examples/orbit.lua", "sha256": recipe_hash,
        "width": WIDTH, "height": HEIGHT, "frames": len(frames), "fps": FPS,
        "seconds": SECONDS, "position_samples": SAMPLES,
        "renderer": "tools/render_readme.py",
    }, indent=2) + "\n")
    # Verify the saved animation, including timing, loop, and distinct frames.
    with Image.open(args.output / "orbit.gif") as gif:
        assert gif.size == (WIDTH, HEIGHT) and gif.n_frames == FPS * SECONDS
        assert gif.info["loop"] == 0
        duration, unique = 0, set()
        for i in range(gif.n_frames):
            gif.seek(i)
            duration += gif.info["duration"]
            unique.add(hashlib.sha256(gif.convert("RGB").tobytes()).digest())
        assert duration == SECONDS * 1000 and len(unique) == len(frames)
    print("Rendered %d Lua-driven frames: %s" % (len(frames), args.output / "orbit.gif"))


if __name__ == "__main__":
    main()
