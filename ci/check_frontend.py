#!/usr/bin/env python3
"""
Static checks on the public pages.

Kept as a real file rather than a heredoc inside the workflow: an
indented heredoc terminator inside a shell loop does not terminate,
which is exactly how the first version of this job broke.

Checks, in order of how often each has actually caught something here:
  1. <script> blocks parse as JavaScript
  2. every getElementById / el() target exists in the markup
  3. every inline on* handler is a defined function
  4. every rpc() call names a real function and passes real parameters
"""
import glob
import re
import subprocess
import sys
import tempfile
import os

failures: list[str] = []


def check_js_syntax() -> None:
    for path in sorted(glob.glob("public/*.html")):
        with open(path, encoding="utf-8") as fh:
            blocks = re.findall(r"<script>(.*?)</script>", fh.read(), re.S)
        if not blocks:
            continue
        # Joined with a separator so one file is one node invocation.
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as fh:
            fh.write("\n;\n".join(blocks))
            tmp = fh.name
        proc = subprocess.run(["node", "--check", tmp], capture_output=True, text=True)
        os.unlink(tmp)
        if proc.returncode:
            first = next((l for l in proc.stderr.splitlines() if l.strip()), "syntax error")
            failures.append(f"{path}: JavaScript syntax — {first.strip()}")
        else:
            print(f"ok   {path} (js)")

    for path in sorted(glob.glob("public/*.js")):
        proc = subprocess.run(["node", "--check", path], capture_output=True, text=True)
        if proc.returncode:
            failures.append(f"{path}: JavaScript syntax")
        else:
            print(f"ok   {path} (js)")


def check_dom_references() -> None:
    for path in sorted(glob.glob("public/*.html")):
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        ids = set(re.findall(r'id="([\w-]+)"', src))
        used = set(re.findall(r"getElementById\('([\w-]+)'\)", src)) | set(
            re.findall(r"(?<![\w.])el\('([\w-]+)'\)", src)
        )
        handlers = set(re.findall(r'on(?:click|change|input|submit)="(\w+)\(', src))
        defined = set(re.findall(r"(?:async )?function (\w+)\(", src))

        for missing in sorted(used - ids):
            failures.append(f"{path}: references #{missing}, which is not in the markup")
        for undef in sorted(handlers - defined):
            failures.append(f"{path}: on-handler {undef}() is not defined")
        if not (used - ids) and not (handlers - defined):
            print(f"ok   {path} (dom)")


def check_rpc_signatures() -> None:
    sql = "\n".join(
        open(f, encoding="utf-8").read()
        for f in sorted(glob.glob("supabase/migrations/*.sql"))
    )
    defs: dict[str, set[str]] = {
        m.group(1): set(re.findall(r"\b(p_\w+)\s", m.group(2)))
        for m in re.finditer(r"create or replace function (\w+)\s*\(([^)]*)\)", sql, re.S)
    }

    for path in sorted(glob.glob("public/*.html")):
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        ok = True
        for m in re.finditer(r"rpc\('(\w+)'(?:,\s*\{(.*?)\})?\)", src, re.S):
            name, args = m.group(1), m.group(2) or ""
            if name not in defs:
                failures.append(f"{path}: rpc('{name}') has no SQL definition")
                ok = False
                continue
            if extra := set(re.findall(r"(p_\w+)\s*:", args)) - defs[name]:
                failures.append(
                    f"{path}: rpc('{name}') passes {sorted(extra)}; "
                    f"the function accepts {sorted(defs[name])}"
                )
                ok = False
        if ok:
            print(f"ok   {path} (rpc)")


def check_reserved_slug_lists() -> None:
    """The reserved-slug list lives in four places and has already drifted.

    validate_link_slug() in the migrations is authoritative — it is the
    only copy that can actually refuse an insert. The other three exist
    so the UI and the Worker agree with it, and the failure mode when
    they disagree is silent: a name the database would reject still
    looks available while typing it, or the Worker serves a real app
    page as if it were someone's payment link.

    At the time this was written the DB and 404.html carried 18 entries,
    the Worker 11 and dashboard.html 10.
    """
    sql = "\n".join(
        open(f, encoding="utf-8").read()
        for f in sorted(glob.glob("supabase/migrations/*.sql"))
    )
    bodies = re.findall(
        r"create or replace function validate_link_slug.*?\$\$;", sql, re.S | re.I
    )
    if not bodies:
        failures.append("validate_link_slug() not found in migrations")
        return
    # The function's only quoted literals are the reserved names and its
    # regex, which contains no single-quoted words of this shape.
    canonical = set(re.findall(r"'([a-z0-9-]+)'", bodies[-1]))

    sources = {
        "public/404.html": r"RESERVED\s*=\s*(?:new Set\()?\[(.*?)\]",
        "public/dashboard.html": r"RESERVED\s*=\s*(?:new Set\()?\[(.*?)\]",
        "worker/og-preview-worker.js": r"RESERVED\s*=\s*new Set\(\[(.*?)\]",
    }
    for rel, pattern in sources.items():
        if not os.path.exists(rel):
            failures.append(f"{rel}: file missing")
            continue
        with open(rel, encoding="utf-8") as fh:
            m = re.search(pattern, fh.read(), re.S)
        if not m:
            failures.append(f"{rel}: no RESERVED list found")
            continue
        found = set(re.findall(r"""['"]([a-z0-9-]+)['"]""", m.group(1)))
        missing = sorted(canonical - found)
        if missing:
            failures.append(
                f"{rel}: reserved-slug list is missing {missing} — the database "
                f"would reject these but this copy would not"
            )
        else:
            print(f"ok   {rel} (reserved slugs)")


check_js_syntax()
check_dom_references()
check_rpc_signatures()
check_reserved_slug_lists()

if failures:
    print("\n".join(f"FAIL {f}" for f in failures), file=sys.stderr)
    sys.exit(1)
print("\nAll frontend checks passed.")
