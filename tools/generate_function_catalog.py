#!/usr/bin/env python3
"""Render the JSON-formatted Rducks function catalog to Markdown."""
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "inst" / "function_catalog" / "functions.json"
OUT = ROOT / "inst" / "function_catalog" / "functions.md"


def main() -> None:
    items = json.loads(CATALOG.read_text())
    lines = ["# Rducks Function Catalog", ""]
    for item in items:
        lines.append(f"## `{item['name']}`")
        lines.append("")
        lines.append(f"- Kind: `{item['kind']}`")
        lines.append(f"- Category: `{item['category']}`")
        lines.append(f"- Signature: `{item['signature']}`")
        lines.append(f"- Returns: `{item['returns']}`")
        lines.append("")
        lines.append(item["description"])
        lines.append("")
    OUT.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
