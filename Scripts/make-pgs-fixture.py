#!/usr/bin/env python3
"""Writes a tiny synthetic PGS (Blu-ray bitmap subtitle) track and muxes it with a test-pattern video.

    Scripts/make-pgs-fixture.py VelaTests/Fixtures/pgs-sample.mkv

Two white bars on a 1920x1080 canvas: 1.0-3.0 s and 4.0-6.0 s. No third-party content, so the file can
live in the repository. Needs ffmpeg (libx264) for the mux.
"""
import struct, subprocess, sys, tempfile, os

def segment(pts_90k, kind, payload):
    return b"PG" + struct.pack(">IIBH", pts_90k, pts_90k, kind, len(payload)) + payload

def display_set(t, comp, show, canvas=(1920, 1080), rect=(760, 900, 400, 60)):
    pts = int(t * 90000); x, y, w, h = rect
    if show:
        pcs = struct.pack(">HHBHBBBB", canvas[0], canvas[1], 0x10, comp, 0x80, 0x00, 0, 1) + struct.pack(">HBBHH", 0, 0, 0x00, x, y)
    else:
        pcs = struct.pack(">HHBHBBBB", canvas[0], canvas[1], 0x10, comp, 0x00, 0x00, 0, 0)
    out = segment(pts, 0x16, pcs)
    out += segment(pts, 0x17, struct.pack(">BBHHHH", 1, 0, x, y, w, h))
    if show:
        # palette: 0 transparent, 1 opaque white (Y 235, Cr 128, Cb 128)
        out += segment(pts, 0x14, struct.pack(">BB", 0, 0) + bytes([0, 16, 128, 128, 0]) + bytes([1, 235, 128, 128, 255]))
        line = bytes([0x00, 0xC0 | (w >> 8), w & 0xFF, 1, 0x00, 0x00])  # run of w pixels of colour 1, end of line
        rle = line * h
        ods = struct.pack(">HBB", 0, 0, 0xC0) + struct.pack(">I", 4 + len(rle))[1:] + struct.pack(">HH", w, h) + rle
        out += segment(pts, 0x15, ods)
    out += segment(pts, 0x80, b"")
    return out

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "VelaTests/Fixtures/pgs-sample.mkv"
    # an empty display set at 0 keeps the stream start at 0 so ffmpeg does not shift the timestamps when muxing
    sup = b"".join([display_set(0.0, 0, False), display_set(1.0, 1, True), display_set(3.0, 2, False), display_set(4.0, 3, True), display_set(6.0, 4, False)])
    with tempfile.TemporaryDirectory() as tmp:
        sup_path = os.path.join(tmp, "fixture.sup")
        open(sup_path, "wb").write(sup)
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=320x180:rate=10:duration=7", "-i", sup_path,
                        "-map", "0:v", "-map", "1:s", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "45", "-pix_fmt", "yuv420p",
                        "-c:s", "copy", "-metadata:s:s:0", "language=ger", "-t", "7", out], check=True)
    print(f"wrote {out} ({os.path.getsize(out)} bytes)")

if __name__ == "__main__":
    main()
