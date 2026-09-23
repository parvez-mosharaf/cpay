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
  5. payment surfaces keep accessible controls and QR ownership guards
  6. admin release gates stay server-backed and audited
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
        for m in re.finditer(r"create or replace function (?:public\.)?(\w+)\s*\(([^)]*)\)", sql, re.S)
    }

    for path in sorted(glob.glob("public/*.html")):
        with open(path, encoding="utf-8") as fh:
            src = fh.read()
        ok = True
        for m in re.finditer(r"rpc\('(\w+(?:\.\w+)?)'(?:,\s*\{(.*?)\})?\)", src, re.S):
            name, args = m.group(1), m.group(2) or ""
            lookup = name.split('.')[-1]
            if lookup not in defs:
                failures.append(f"{path}: rpc('{name}') has no SQL definition")
                ok = False
                continue
            if extra := set(re.findall(r"(p_\w+)\s*:", args)) - defs[lookup]:
                failures.append(
                    f"{path}: rpc('{name}') passes {sorted(extra)}; "
                    f"the function accepts {sorted(defs[lookup])}"
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


def check_payment_accessibility_and_qr() -> None:
    """Catch regressions in the two public payment surfaces.

    This is intentionally a static gate: the actual invoice and Supabase
    staging flow still needs a browser/payment test. It prevents a future
    markup cleanup from removing the keyboard/screen-reader contract or the
    on-chain address ownership boundary.
    """
    pages = {
        "public/404.html": [
            'id="amountDisplay"',
            'role="status" aria-live="polite"',
            'id="quickToggle" aria-expanded="false"',
            'id="classicInput"',
            'aria-label="Payment amount"',
            'id="payBtn" type="button"',
            'data-key="1" aria-label=',
            'data-key="back" aria-label="Backspace"',
        ],
        "public/invoice-cpay-v2.html": [
            'id="qrLink" class="qr-link-button" type="button"',
            'id="qrcode"',
            'id="timerPill" role="timer"',
            'id="copyBtn" class="pill-btn btn-copy" type="button"',
            'id="payBtn" class="pill-btn btn-pay" type="button"',
            'id="modalCloseBtn" type="button" aria-label=',
        ],
    }
    for rel, needles in pages.items():
        try:
            with open(rel, encoding="utf-8") as fh:
                src = fh.read()
        except OSError:
            failures.append(f"{rel}: file missing")
            continue
        missing = [needle for needle in needles if needle not in src]
        if missing:
            failures.append(f"{rel}: accessibility contract missing {missing}")
        else:
            print(f"ok   {rel} (payment accessibility)")

    qr = "supabase/migrations/0068_onchain_address_book.sql"
    try:
        with open(qr, encoding="utf-8") as fh:
            src = fh.read().lower()
    except OSError:
        failures.append(f"{qr}: file missing")
        return
    guards = [
        "alter table onchain_addresses enable row level security",
        "using (user_id = auth.uid() or is_admin())",
        "drop policy if exists \"onchain owner insert\"",
        "drop policy if exists \"onchain owner update\"",
        "drop policy if exists \"onchain owner delete\"",
        "and (user_id = auth.uid() or is_admin())",
        "on conflict (user_id, address)",
        "cpay_valid_onchain_address",
    ]
    missing = [guard for guard in guards if guard not in src]
    if missing:
        failures.append(f"{qr}: QR ownership/validation guard missing {missing}")
    else:
        print(f"ok   {qr} (QR ownership guards)")


def check_admin_release_gates() -> None:
    """Keep the staging sign-off ledger connected to guarded RPCs."""
    migration = "supabase/migrations/0080_ops_release_gates.sql"
    page = "public/admin.html"
    try:
        with open(migration, encoding="utf-8") as fh:
            sql = fh.read()
        with open(page, encoding="utf-8") as fh:
            admin = fh.read()
    except OSError as exc:
        failures.append(f"release-gates: {exc}")
        return
    sql_needles = [
        "create table if not exists ops_release_gates",
        "alter table ops_release_gates enable row level security",
        "create or replace function admin_ops_release_gates()",
        "create or replace function admin_set_ops_release_gate(",
        "perform record_audit(",
        "grant execute on function public.admin_ops_release_gates() to authenticated",
        "grant execute on function public.admin_set_ops_release_gate(text, boolean, text)",
    ]
    page_needles = [
        'id="opsGateSummary"',
        'id="opsGateList"',
        "admin_ops_release_gates",
        "admin_set_ops_release_gate",
        "Staging sign-off ledger",
    ]
    missing = [needle for needle in sql_needles if needle not in sql]
    missing += [needle for needle in page_needles if needle not in admin]
    if missing:
        failures.append(f"release-gates: missing {missing}")
    else:
        print("ok   admin release gates (server-backed and audited)")


def check_direct_upload_contract() -> None:
    """Keep the direct-upload command and safety boundary intact."""
    try:
        with open("package.json", encoding="utf-8") as fh:
            package = fh.read()
        with open("scripts/prepare-direct-upload.mjs", encoding="utf-8") as fh:
            uploader = fh.read()
        with open("docs/DIRECT-UPLOAD.md", encoding="utf-8") as fh:
            docs = fh.read()
    except OSError as exc:
        failures.append(f"direct-upload: {exc}")
        return
    needles = [
        '"prepare:upload": "node scripts/prepare-direct-upload.mjs"',
        "const outputDir = path.join(root, \"dist\")",
        "BTCPAY_API_KEY|WEBHOOK_SECRET",
        "Deploy Supabase migrations and Edge Functions separately.",
        "0001` through `0080`",
    ]
    missing = [needle for needle in needles if needle not in package + uploader + docs]
    if missing:
        failures.append(f"direct-upload: missing {missing}")
    else:
        print("ok   direct-upload bundle guard")


check_js_syntax()
check_dom_references()
check_rpc_signatures()
check_reserved_slug_lists()
check_payment_accessibility_and_qr()
check_admin_release_gates()
check_direct_upload_contract()

if failures:
    print("\n".join(f"FAIL {f}" for f in failures), file=sys.stderr)
    sys.exit(1)
print("\nAll frontend checks passed.")
