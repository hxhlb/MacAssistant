#!/usr/bin/env python3
"""把心形图标做成带 squircle 透明边的 PNG，并按 iconset 尺寸缩放。

源图是不透明 RGB。旧系统 Launchpad 不会再套一层圆角遮罩，白色四角就会露成方块。
这里用超椭圆遮罩写出 alpha，iconutil / 访达在 macOS 13–15 上也能裁出圆角。
"""
from __future__ import annotations

import argparse
import struct
import sys
import zlib
from pathlib import Path


PNG_SIG = b"\x89PNG\r\n\x1a\n"
SQUIRCLE_N = 5.0


def paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png(path: Path) -> tuple[int, int, int, list[bytearray]]:
    data = path.read_bytes()
    if data[:8] != PNG_SIG:
        raise SystemExit(f"{path} 不是 PNG")
    pos = 8
    ihdr = None
    idat = b""
    while pos + 8 <= len(data):
        length, ctype = struct.unpack(">I4s", data[pos : pos + 8])
        chunk = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if ctype == b"IHDR":
            ihdr = chunk
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
    if ihdr is None:
        raise SystemExit(f"{path} 缺少 IHDR")
    width, height, bit, color, comp, filt, inter = struct.unpack(">IIBBBBB", ihdr)
    if bit != 8 or color not in (2, 6) or inter != 0:
        raise SystemExit(f"{path} 只支持 8-bit RGB/RGBA 非交错 PNG")
    raw = zlib.decompress(idat)
    bpp = 3 if color == 2 else 4
    stride = width * bpp
    rows: list[bytearray] = []
    i = 0
    prev = bytearray(stride)
    for _ in range(height):
        ftype = raw[i]
        i += 1
        row = bytearray(raw[i : i + stride])
        i += stride
        if ftype == 1:
            for x in range(stride):
                row[x] = (row[x] + (row[x - bpp] if x >= bpp else 0)) & 255
        elif ftype == 2:
            for x in range(stride):
                row[x] = (row[x] + prev[x]) & 255
        elif ftype == 3:
            for x in range(stride):
                left = row[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + ((left + prev[x]) // 2)) & 255
        elif ftype == 4:
            for x in range(stride):
                a = row[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + paeth(a, b, c)) & 255
        elif ftype != 0:
            raise SystemExit(f"{path} 不支持的 PNG filter {ftype}")
        rows.append(row)
        prev = row
    return width, height, color, rows


def write_png(path: Path, width: int, height: int, rows: list[bytes]) -> None:
    raw = b"".join(b"\x00" + row for row in rows)
    compressed = zlib.compress(raw, 9)

    def chunk(ctype: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + ctype
            + payload
            + struct.pack(">I", zlib.crc32(ctype + payload) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    path.write_bytes(PNG_SIG + chunk(b"IHDR", ihdr) + chunk(b"IDAT", compressed) + chunk(b"IEND", b""))


def coverage(x: int, y: int, size: int) -> float:
    acc = 0
    for dy in (0.125, 0.375, 0.625, 0.875):
        for dx in (0.125, 0.375, 0.625, 0.875):
            nx = ((x + dx) / size) * 2 - 1
            ny = ((y + dy) / size) * 2 - 1
            if abs(nx) ** SQUIRCLE_N + abs(ny) ** SQUIRCLE_N <= 1:
                acc += 1
    return acc / 16


def sample_pixel(
    rows: list[bytearray], color: int, width: int, height: int, x: float, y: float
) -> tuple[int, int, int, int]:
    sx = min(width - 1, max(0, int(round(x * (width - 1)))))
    sy = min(height - 1, max(0, int(round(y * (height - 1)))))
    bpp = 3 if color == 2 else 4
    row = rows[sy]
    o = sx * bpp
    alpha = row[o + 3] if color == 6 else 255
    return row[o], row[o + 1], row[o + 2], alpha


def render_rgba(rows: list[bytearray], color: int, src_w: int, src_h: int, size: int) -> list[bytes]:
    apply_mask = color != 6
    out: list[bytes] = []
    for y in range(size):
        row = bytearray(size * 4)
        fy = y / max(1, size - 1)
        for x in range(size):
            r, g, b, src_a = sample_pixel(rows, color, src_w, src_h, x / max(1, size - 1), fy)
            alpha = src_a
            if apply_mask:
                alpha = int(round(coverage(x, y, size) * 255))
            o = x * 4
            row[o : o + 4] = bytes((r, g, b, alpha))
        out.append(bytes(row))
    return out


def inspect(path: Path) -> int:
    width, height, color, rows = read_png(path)
    bpp = 3 if color == 2 else 4
    corners = []
    for x, y in ((0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)):
        row = rows[y]
        o = x * bpp
        if color == 6:
            corners.append(row[o + 3])
        else:
            corners.append(255)
    print(f"{path}: {width}x{height} color={color} corner_alpha={corners}")
    if color != 6:
        print("缺少 alpha 通道", file=sys.stderr)
        return 1
    if any(alpha > 8 for alpha in corners):
        print("四角不是透明的", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--out", type=Path, help="写出 1024×1024 带透明边的 PNG")
    parser.add_argument("--iconset", type=Path, help="写出 AppIcon.iconset 目录")
    parser.add_argument("--inspect", action="store_true")
    args = parser.parse_args()
    if args.inspect:
        return inspect(args.source)

    width, height, color, rows = read_png(args.source)
    if args.out:
        write_png(args.out, 1024, 1024, render_rgba(rows, color, width, height, 1024))
    if args.iconset:
        args.iconset.mkdir(parents=True, exist_ok=True)
        for size in (16, 32, 128, 256, 512):
            for scale, suffix in ((1, ""), (2, "@2x")):
                pixels = size * scale
                name = f"icon_{size}x{size}{suffix}.png"
                write_png(
                    args.iconset / name,
                    pixels,
                    pixels,
                    render_rgba(rows, color, width, height, pixels),
                )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
