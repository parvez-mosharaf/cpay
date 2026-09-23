#!/usr/bin/env python3
"""Patch CPAY Supabase migrations so a fresh GitHub Actions apply does not die.

Run from the repository root (the folder that contains supabase/migrations):

    python3 fix_ci_sql.py

What it changes, and only that:
1. DROP FUNCTION before every CREATE OR REPLACE of get_public_store / get_invoice_public.
   Postgres cannot change a function's return columns with CREATE OR REPLACE.
2. RAISE messages that contain a lone % and no matching argument.
   plpgsql treats % as a placeholder, so "0-90%" crashes with
   "too few parameters specified for RAISE".
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

FUNC = re.compile(
    r"(?im)^(?P<indent>[ \t]*)create\s+or\s+replace\s+function\s+"
    r"(?:public\.)?(?P<name>get_public_store|get_invoice_public)\s*\((?P<args>[^)]*)\)"
)


def arg_types(args: str) -> str:
    types: list[str] = []
    for raw in args.split(","):
        part = raw.strip()
        if not part:
            continue
        low = part.lower()
        if "uuid" in low:
            types.append("uuid")
        elif "text" in low:
            types.append("text")
        elif "numeric" in low:
            types.append("numeric")
        elif "boolean" in low or low.endswith(" bool"):
            types.append("boolean")
        elif "jsonb" in low:
            types.append("jsonb")
        else:
            types.append(part.split()[-1])
    return ", ".join(types)


def insert_drops(sql: str) -> str:
    lines = sql.splitlines(keepends=True)
    text_lines = [ln.rstrip("\n") for ln in lines]
    inserts: list[tuple[int, str]] = []
    # Rebuild a string with the same newlines so match positions map to lines.
    joined = "".join(lines)
    # Map character offset -> line index
    offsets = [0]
    for ln in lines:
        offsets.append(offsets[-1] + len(ln))

    def line_of(pos: int) -> int:
        for i in range(len(offsets) - 1):
            if offsets[i] <= pos < offsets[i + 1]:
                return i
        return len(lines) - 1

    for match in FUNC.finditer(joined):
        name = match.group("name")
        types = arg_types(match.group("args"))
        line = line_of(match.start())
        window = "\n".join(text_lines[max(0, line - 25) : line]).lower()
        if f"drop function if exists" in window and name.lower() in window:
            continue
        indent = match.group("indent")
        drop = (
            f"{indent}drop function if exists public.{name}({types});\n"
        )
        inserts.append((line, drop))

    if not inserts:
        return sql
    for line, drop in reversed(inserts):
        lines.insert(line, drop)
    return "".join(lines)


def placeholders(fmt: str) -> int:
    count = 0
    i = 0
    while i < len(fmt):
        if fmt[i] == "%":
            if i + 1 < len(fmt) and fmt[i + 1] == "%":
                i += 2
                continue
            count += 1
        i += 1
    return count


def strip_extra_percents(fmt: str, extra: int) -> str:
    """Turn unmatched single % into the word percent, from the right."""
    if extra <= 0:
        return fmt
    chars = list(fmt)
    i = len(chars) - 1
    while i >= 0 and extra > 0:
        if chars[i] == "%":
            prev_escaped = i > 0 and chars[i - 1] == "%"
            # A % that is the second half of %% is literal. A % that starts %% is literal.
            nxt_escaped = i + 1 < len(chars) and chars[i + 1] == "%"
            if not prev_escaped and not nxt_escaped:
                chars[i : i + 1] = list(" percent")
                extra -= 1
        i -= 1
    return "".join(chars)


def split_sql_string(stmt: str, start: int) -> tuple[str, int] | None:
    """Read a single-quoted SQL literal starting at start. Returns (inner, end_index)."""
    if start >= len(stmt) or stmt[start] != "'":
        return None
    i = start + 1
    body: list[str] = []
    while i < len(stmt):
        if stmt[i] == "'":
            if i + 1 < len(stmt) and stmt[i + 1] == "'":
                body.append("'")
                i += 2
                continue
            return "".join(body), i
        body.append(stmt[i])
        i += 1
    return None


def fix_raise_statement(stmt: str) -> str:
    low = stmt.lower()
    key = "raise exception"
    at = low.find(key)
    if at < 0:
        return stmt
    rest = stmt[at + len(key) :]
    q = rest.find("'")
    if q < 0:
        return stmt
    parsed = split_sql_string(rest, q)
    if not parsed:
        return stmt
    inner, end = parsed
    after = rest[end + 1 :]
    # Arguments are a comma-separated list before the semicolon, outside strings.
    args = 0
    depth = 0
    in_str = False
    k = 0
    saw_comma = False
    while k < len(after):
        ch = after[k]
        if in_str:
            if ch == "'" and k + 1 < len(after) and after[k + 1] == "'":
                k += 2
                continue
            if ch == "'":
                in_str = False
            k += 1
            continue
        if ch == "'":
            in_str = True
            k += 1
            continue
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        elif ch == "," and depth == 0:
            args += 1
            saw_comma = True
        elif ch == ";" and depth == 0:
            break
        k += 1
    # A comma means there is at least one format argument. `args` counts commas,
    # which equals the number of format args when the list is non-empty.
    needed = placeholders(inner)
    extra = needed - (args if saw_comma else 0)
    if extra <= 0:
        return stmt
    fixed = strip_extra_percents(inner, extra)
    if fixed == inner:
        return stmt
    escaped = fixed.replace("'", "''")
    return stmt[: at + len(key)] + rest[:q] + "'" + escaped + "'" + rest[end + 1 :]


def fix_raises(sql: str) -> str:
    out: list[str] = []
    i = 0
    low = sql.lower()
    key = "raise exception"
    while True:
        j = low.find(key, i)
        if j < 0:
            out.append(sql[i:])
            break
        out.append(sql[i:j])
        end = sql.find(";", j)
        if end < 0:
            out.append(sql[j:])
            break
        stmt = sql[j : end + 1]
        out.append(fix_raise_statement(stmt))
        i = end + 1
        low = sql.lower()
    return "".join(out)


def migrations_dir(start: Path) -> Path | None:
    candidates = [
        start / "supabase" / "migrations",
        start / "artifacts" / "cpay" / "supabase" / "migrations",
        start,
    ]
    for path in candidates:
        if path.is_dir() and any(path.glob("*.sql")):
            return path
    return None


def main() -> int:
    start = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path.cwd()
    folder = migrations_dir(start)
    if folder is None:
        print("supabase/migrations folder not found. Run this inside the cpay repo.")
        return 1
    changed = 0
    for path in sorted(folder.glob("*.sql")):
        original = path.read_text(encoding="utf-8")
        updated = fix_raises(insert_drops(original))
        if updated != original:
            path.write_text(updated, encoding="utf-8")
            changed += 1
            print("patched", path.name)
    if changed == 0:
        print("No changes. Either it is already patched, or this is not the migrations folder.")
    else:
        print(f"Done. {changed} file(s) patched in {folder}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
