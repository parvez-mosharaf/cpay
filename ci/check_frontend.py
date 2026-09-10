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


check_js_syntax()
check_dom_references()
check_rpc_signatures()

if failures:
    print("\n".join(f"FAIL {f}" for f in failures), file=sys.stderr)
    sys.exit(1)
print("\nAll frontend checks passed.")
