"""Convert the Ordo mark into firmware-native formats."""
import io
from functools import cache
from pathlib import Path
import subprocess
import sys
import tempfile


MARK = Path(__file__).resolve().parents[2] / "assets/branding/ordo-mark.svg"
LOGO_MAGIC = b"m1n1_logo_256128"


@cache
def raster():
    if sys.platform == "darwin":
        with tempfile.TemporaryDirectory() as folder:
            png = Path(folder) / "mark.png"
            subprocess.run(["sips", "-s", "format", "png", MARK, "--out", png],
                           check=True, stdout=subprocess.DEVNULL)
            return png.read_bytes()
    return subprocess.check_output(["rsvg-convert", str(MARK)])


def pixels(size):
    from PIL import Image
    with Image.open(io.BytesIO(raster())) as source:
        return source.convert("RGBA").resize((size, size), Image.Resampling.LANCZOS)


def m1n1_logo():
    # The m1n1 framebuffer blitter reads RGB and ignores the alpha byte.
    return LOGO_MAGIC + b"".join(flatten(size).convert("RGBA").tobytes() for size in (256, 128))


def flatten(size):
    from PIL import Image
    logo = pixels(size)
    canvas = Image.new("RGB", logo.size)
    canvas.paste(logo, mask=logo.getchannel("A"))
    return canvas


def splash():
    canvas = flatten(256)
    stream = io.BytesIO()
    canvas.save(stream, format="BMP")
    return stream.getvalue()
