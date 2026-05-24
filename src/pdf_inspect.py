#!/usr/bin/env python3
"""Inspect a PDF: report metadata, extract text, render pages without text to PNG.

Usage:
    uv run python src/pdf_inspect.py <pdf-path>

For each page, prints text content if a text layer exists. If a page has no
extractable text, renders it to PNG under output/pdf-renders/<stem>/ so it can
be opened or shared for visual review.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pymupdf


def inspect(pdf_path: Path, render_dpi: int = 150, render_all: bool = False) -> int:
    if not pdf_path.is_file():
        print(f"error: not a file: {pdf_path}", file=sys.stderr)
        return 2

    doc = pymupdf.open(pdf_path)
    print(f"=== {pdf_path.name}")
    print(f"pages: {doc.page_count}")
    if doc.metadata:
        for key, value in doc.metadata.items():
            if value:
                print(f"meta.{key}: {value}")

    render_dir = Path("output") / "pdf-renders" / pdf_path.stem
    rendered: list[Path] = []

    for index, page in enumerate(doc, start=1):
        text = page.get_text("text").strip()
        rect = page.rect
        print(
            f"\n--- page {index}  ({rect.width:.0f} x {rect.height:.0f} pts, "
            f"text chars: {len(text)}) ---"
        )
        if text:
            print(text)
            if not render_all:
                continue
            print("(--render-all: also rendering this page to PNG)")
        else:
            print("(no extractable text layer — rendering to PNG)")
        render_dir.mkdir(parents=True, exist_ok=True)
        out = render_dir / f"page-{index:02d}.png"
        scale = render_dpi / 72
        pix = page.get_pixmap(matrix=pymupdf.Matrix(scale, scale), alpha=False)
        pix.save(out)
        print(f"rendered -> {out}")
        rendered.append(out)

    if rendered:
        print(f"\nRendered {len(rendered)} page(s) to: {render_dir}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Inspect a PDF: metadata, text, optional page renders."
    )
    parser.add_argument("pdf", type=Path, help="Path to a PDF file.")
    parser.add_argument(
        "--dpi",
        type=int,
        default=150,
        help="Render DPI for image-only pages (default: 150).",
    )
    parser.add_argument(
        "--render-all",
        action="store_true",
        help="Render every page to PNG, even when a text layer is present.",
    )
    args = parser.parse_args()
    return inspect(args.pdf, render_dpi=args.dpi, render_all=args.render_all)


if __name__ == "__main__":
    raise SystemExit(main())
