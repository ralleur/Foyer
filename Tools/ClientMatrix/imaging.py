#!/usr/bin/env python3
"""Image helpers for the client test matrix (needs Pillow).

  imaging.py label  OUT.png WIDTH HEIGHT TEXT     transparent overlay with a large label (burned into test clips)
  imaging.py poster OUT.jpg TEXT [SUBTITLE]        600x900 poster with the row id
  imaging.py pgs    OUT.sup WIDTH HEIGHT LANG      PGS (HDMI/Blu-ray) subtitle stream with a few timed cues

ffmpeg has no PGS encoder, so `pgs` writes the segments (PCS/WDS/PDS/ODS/END) itself.
"""
import struct
import sys

from PIL import Image, ImageDraw, ImageFont

FONTS = ["/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Arial.ttf"]


def font(size):
    for path in FONTS:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


def label(out, width, height, text):
    img = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    f = font(max(24, height // 14))
    box = draw.textbbox((0, 0), text, font=f)
    w, h = box[2] - box[0], box[3] - box[1]
    x, y = (width - w) // 2, height // 12
    draw.rectangle((x - 30, y - 20, x + w + 30, y + h + 30), fill=(0, 0, 0, 170))
    draw.text((x, y), text, font=f, fill=(255, 255, 255, 255))
    img.save(out)


def poster(out, text, subtitle=""):
    img = Image.new("RGB", (600, 900), (28, 36, 52))
    draw = ImageDraw.Draw(img)
    draw.text((40, 320), text, font=font(120), fill=(240, 240, 240))
    if subtitle:
        y = 480
        for line in subtitle.split("|"):
            draw.text((40, y), line, font=font(40), fill=(180, 200, 230))
            y += 56
    img.save(out, quality=90)


# --- PGS ------------------------------------------------------------------------------------

def _segment(kind, pts, payload):
    return b"PG" + struct.pack(">IIBH", pts, 0, kind, len(payload)) + payload


def _rle(bitmap, width, height):
    """PGS run-length encoding of palette indices (row-major list)."""
    out = bytearray()
    for row in range(height):
        line = bitmap[row * width:(row + 1) * width]
        i = 0
        while i < width:
            color = line[i]
            run = 1
            while i + run < width and line[i + run] == color and run < 16383:
                run += 1
            if color == 0:
                if run < 64:
                    out += bytes([0, run])
                else:
                    out += bytes([0, 0x40 | (run >> 8), run & 0xFF])
            elif run < 3:
                out += bytes([color]) * run
            elif run < 64:
                out += bytes([0, 0x80 | run, color])
            else:
                out += bytes([0, 0xC0 | (run >> 8), run & 0xFF, color])
            i += run
        out += b"\x00\x00"
    return bytes(out)


def _text_bitmap(text, size):
    f = font(size)
    probe = ImageDraw.Draw(Image.new("L", (1, 1)))
    box = probe.textbbox((0, 0), text, font=f, stroke_width=4)
    w, h = box[2] - box[0] + 16, box[3] - box[1] + 16
    fill = Image.new("L", (w, h), 0)
    ImageDraw.Draw(fill).text((8 - box[0], 8 - box[1]), text, font=f, fill=255)
    stroke = Image.new("L", (w, h), 0)
    ImageDraw.Draw(stroke).text((8 - box[0], 8 - box[1]), text, font=f, fill=255, stroke_width=4, stroke_fill=255)
    fp, sp = fill.load(), stroke.load()
    # palette: 0 transparent, 1 white text, 2 black outline
    return [1 if fp[x, y] > 110 else (2 if sp[x, y] > 110 else 0) for y in range(h) for x in range(w)], w, h


def pgs(out, width, height, lang):
    cues = [
        (1.0, 4.0, f"[{lang} PGS] Bitmap-Untertitel eins"),
        (5.0, 9.0, f"[{lang} PGS] Zweiter Bitmap-Untertitel"),
        (20.0, 25.0, f"[{lang} PGS] Nach dem Seek: 20 s"),
        (40.0, 45.0, f"[{lang} PGS] Bei 40 s"),
    ]
    palette = struct.pack(">BB", 0, 0) + bytes([0, 16, 128, 128, 0, 1, 235, 128, 128, 255, 2, 16, 128, 128, 255])
    data = bytearray()
    number = 0
    for start, end, text in cues:
        bitmap, w, h = _text_bitmap(text, height // 18)
        x, y = (width - w) // 2, height - h - height // 12
        rle = _rle(bitmap, w, h)
        pts_on, pts_off = int(start * 90000), int(end * 90000)
        pcs = struct.pack(">HHBHBBBB", width, height, 0x10, number, 0x80, 0, 0, 1) + struct.pack(">HBBHH", 0, 0, 0, x, y)
        wds = struct.pack(">BBHHHH", 1, 0, x, y, w, h)
        length = len(rle) + 4
        ods = struct.pack(">HBB", 0, 0, 0xC0) + length.to_bytes(3, "big") + struct.pack(">HH", w, h) + rle
        data += _segment(0x16, pts_on, pcs) + _segment(0x17, pts_on, wds) + _segment(0x14, pts_on, palette)
        data += _segment(0x15, pts_on, ods) + _segment(0x80, pts_on, b"")
        number += 1
        clear = struct.pack(">HHBHBBBB", width, height, 0x10, number, 0x00, 0, 0, 0)
        data += _segment(0x16, pts_off, clear) + _segment(0x17, pts_off, wds) + _segment(0x80, pts_off, b"")
        number += 1
    with open(out, "wb") as fh:
        fh.write(data)


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "label":
        label(args[0], int(args[1]), int(args[2]), args[3])
    elif cmd == "poster":
        poster(args[0], args[1], args[2] if len(args) > 2 else "")
    elif cmd == "pgs":
        pgs(args[0], int(args[1]), int(args[2]), args[3])
    else:
        sys.exit(f"unknown command {cmd}")
