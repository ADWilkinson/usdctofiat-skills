#!/usr/bin/env bash
# Network-allowed check: SKILL.md's documented SDK surface vs the pinned tarball,
# and first-party README URLs still resolve. Stdlib Python only (urllib, tarfile,
# json). Does not replace scripts/check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from __future__ import annotations

import base64
import difflib
import hashlib
import io
import json
import re
import ssl
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

errors: list[str] = []

ROOT = Path(".")
README = ROOT / "README.md"
SKILL = ROOT / "skills/cashout/SKILL.md"
# README lists third-party registries that bot-wall or checkpoint a GET
# (npmjs.com, cursor.directory). Those are not this check. First-party
# product and this-repo GitHub URLs are: a 404 there is a dead consumer link.
README_LIVE_HOSTS = {"usdctofiat.xyz", "www.usdctofiat.xyz"}
README_GITHUB_PREFIX = "https://github.com/ADWilkinson/usdctofiat-skills"
README_URL_RE = re.compile(r"https://[^\s)\]>`'\"]+")
REGISTRY = "https://registry.npmjs.org/@usdctofiat/offramp"
PACKAGE = "@usdctofiat/offramp"
# PACKAGE re-exports its cash-out amount floors from this dependency rather
# than declaring them, so their values are not in PACKAGE's own tarball.
BOUNDS_PACKAGE = "@zkp2p/cash"
BOUNDS_REGISTRY = "https://registry.npmjs.org/@zkp2p/cash"
UA = "usdctofiat-skills-verify-surface (+https://github.com/ADWilkinson/usdctofiat-skills)"
PIN_RE = re.compile(r"^npm install @usdctofiat/offramp@(\d+\.\d+\.\d+)$", re.M)
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
IDENT = r"[A-Za-z_][A-Za-z0-9_]*"
USDC_DECIMALS = 6

# Backticked capitalised identifiers in SKILL.md prose are read as claimed root
# exports of PACKAGE. That inference is deliberately broad: OfframpError,
# PLATFORMS and peerExtensionSdk are documented in prose and imported in no
# example, so narrowing the scan to import statements would drop three of the
# seven symbols it verifies.
#
# The cost is that an ordinary domain noun is indistinguishable from a bogus
# export claim. This set is the escape hatch. Add a term only when it names
# something outside PACKAGE for good -- a currency, a chain, a contract, a
# payment platform. Never add a symbol to turn a red build green when the doc
# is what drifted; main() fails if an entry here is really a root export.
PROSE_NON_SDK = {
    # Currencies and token symbols.
    "EUR",
    "GBP",
    "USD",
    "USDC",
    # Chains and on-chain contracts.
    "Base",
    "ERC20",
    "EscrowV2",
    # Payment platforms the skill can pay out to.
    "Chime",
    "Monzo",
    "PayPal",
    "Revolut",
    "Venmo",
    "Zelle",
}
TS_SKIP = {
    "string",
    "number",
    "bigint",
    "boolean",
    "true",
    "false",
    "null",
    "undefined",
    "any",
    "unknown",
    "never",
    "void",
    "object",
    "symbol",
    "readonly",
    "extends",
    "infer",
    "keyof",
    "typeof",
    "in",
    "as",
    "is",
    "asserts",
    "unique",
    "const",
    "export",
    "import",
    "type",
    "interface",
    "declare",
    "from",
    "function",
    "class",
    "enum",
    "namespace",
    "module",
    "public",
    "private",
    "protected",
    "static",
    "abstract",
    "implements",
    "new",
    "this",
    "super",
    "Promise",
    "Array",
    "Record",
    "Partial",
    "Required",
    "Readonly",
    "Pick",
    "Omit",
    "Extract",
    "Exclude",
    "NonNullable",
    "ReturnType",
    "Parameters",
    "Awaited",
    "Map",
    "Set",
    "Date",
    "Error",
}


def err(msg: str) -> None:
    errors.append(msg)


def fail_exit() -> None:
    print("\n".join(errors))
    print(f"{len(errors)} problem(s)")
    sys.exit(1)


def load_skill() -> str:
    if not SKILL.is_file():
        err(f"{SKILL}: missing")
        fail_exit()
    return SKILL.read_text(encoding="utf-8")


def parse_pin(text: str) -> str:
    pins = PIN_RE.findall(text)
    if not pins:
        err(f"{SKILL}: missing pinned npm install {PACKAGE}@<version>")
        fail_exit()
    unique = set(pins)
    if len(unique) != 1:
        err(f"{SKILL}: conflicting SDK pins {sorted(unique)}")
        fail_exit()
    return next(iter(unique))


def http_get(url: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    try:
        with urllib.request.urlopen(
            req, timeout=timeout, context=ssl.create_default_context()
        ) as resp:
            return resp.read()
    except urllib.error.HTTPError as exc:
        err(f"{PACKAGE}: HTTP {exc.code} fetching {url}")
        fail_exit()
    except urllib.error.URLError as exc:
        err(f"{PACKAGE}: network error fetching {url}: {exc.reason}")
        fail_exit()
    except TimeoutError:
        err(f"{PACKAGE}: timed out fetching {url}")
        fail_exit()
    return b""


def readme_http_urls(text: str) -> list[str]:
    urls: list[str] = []
    seen: set[str] = set()
    for raw in README_URL_RE.findall(text):
        url = raw.rstrip(".,;:")
        if url in seen:
            continue
        seen.add(url)
        urls.append(url)
    return urls


def is_readme_live_url(url: str) -> bool:
    host = (urllib.parse.urlparse(url).hostname or "").lower()
    if host in README_LIVE_HOSTS:
        return True
    return url.startswith(README_GITHUB_PREFIX)


def http_status(url: str, timeout: int = 20) -> int | None:
    req = urllib.request.Request(
        url, headers={"User-Agent": UA, "Accept": "*/*"}
    )
    try:
        with urllib.request.urlopen(
            req, timeout=timeout, context=ssl.create_default_context()
        ) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except urllib.error.URLError as exc:
        err(f"README.md: network error fetching {url}: {exc.reason}")
        return None
    except TimeoutError:
        err(f"README.md: timed out fetching {url}")
        return None


def verify_readme_live_urls(text: str) -> int:
    """HEAD-equivalent GET of first-party README URLs. Returns how many were checked."""
    live = [url for url in readme_http_urls(text) if is_readme_live_url(url)]
    if not live:
        err(
            "README.md: no usdctofiat.xyz or this-repo GitHub URL to verify; "
            "the live-link check cannot go silent"
        )
        return 0
    for url in live:
        status = http_status(url)
        if status is None:
            continue
        if status != 200:
            err(f"README.md: {url} returned HTTP {status}")
    return len(live)


def strip_comments(src: str) -> str:
    out: list[str] = []
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if ch in "'\"`":
            quote = ch
            out.append(ch)
            i += 1
            while i < n:
                cur = src[i]
                out.append(cur)
                if cur == "\\" and i + 1 < n:
                    out.append(src[i + 1])
                    i += 2
                    continue
                if cur == quote:
                    i += 1
                    break
                i += 1
            continue
        if ch == "/" and nxt == "/":
            i += 2
            while i < n and src[i] != "\n":
                i += 1
            continue
        if ch == "/" and nxt == "*":
            i += 2
            while i + 1 < n and not (src[i] == "*" and src[i + 1] == "/"):
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def strip_strings(src: str) -> str:
    return re.sub(
        r"`(?:\\.|[^`\\])*`|'(?:\\.|[^'\\])*'|\"(?:\\.|[^\"\\])*\"", " ", src
    )


def parse_export_items(body: str) -> list[tuple[str, str]]:
    items: list[tuple[str, str]] = []
    for raw in body.split(","):
        part = re.sub(r"\s+", " ", raw).strip()
        if not part:
            continue
        m = re.fullmatch(rf"(?:type\s+)?({IDENT})(?:\s+as\s+({IDENT}))?", part)
        if not m:
            continue
        orig = m.group(1)
        public = m.group(2) or orig
        items.append((orig, public))
    return items


def parse_export_clauses(text: str) -> list[tuple[list[tuple[str, str]], str | None]]:
    clauses: list[tuple[list[tuple[str, str]], str | None]] = []
    i = 0
    while True:
        m = re.search(r"export\s+(?:type\s+)?\{", text[i:])
        if not m:
            break
        start = i + m.end()
        depth = 1
        j = start
        while j < len(text) and depth:
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
            j += 1
        body = text[start : j - 1]
        rest = text[j:].lstrip()
        from_path = None
        fm = re.match(r"from\s+['\"]([^'\"]+)['\"]", rest)
        if fm:
            from_path = fm.group(1)
        clauses.append((parse_export_items(body), from_path))
        i = j
    return clauses


def named_root_exports(entry_text: str) -> set[str]:
    names: set[str] = set()
    for items, _from in parse_export_clauses(entry_text):
        for _orig, public in items:
            names.add(public)
    return names


def resolve_dts(base: Path, spec: str) -> Path | None:
    if not spec.startswith("."):
        return None
    raw = (base.parent / spec)
    stem = raw.name
    if raw.suffix in {".js", ".cjs", ".mjs"}:
        stem = raw.stem
    candidates = [
        raw.parent / f"{stem}.d.ts",
        raw.parent / f"{stem}.d.cts",
        raw.with_suffix(".d.ts"),
        raw.with_suffix(".d.cts"),
        Path(str(raw) + ".d.ts"),
        Path(str(raw) + ".d.cts"),
    ]
    for cand in candidates:
        if cand.is_file():
            return cand
    return None


def slice_until_semi(text: str, start: int) -> str:
    depth_curly = depth_paren = depth_brack = 0
    i = start
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth_curly += 1
        elif ch == "}":
            depth_curly -= 1
        elif ch == "(":
            depth_paren += 1
        elif ch == ")":
            depth_paren -= 1
        elif ch == "[":
            depth_brack += 1
        elif ch == "]":
            depth_brack -= 1
        elif (
            ch == ";"
            and depth_curly <= 0
            and depth_paren <= 0
            and depth_brack <= 0
        ):
            return text[start:i]
        i += 1
    return text[start:]


def slice_brace_block(text: str, start: int) -> str:
    i = text.find("{", start)
    if i < 0:
        return slice_until_semi(text, start)
    depth = 1
    j = i + 1
    while j < len(text) and depth:
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
        j += 1
    return text[start:j]


def find_decl(text: str, name: str) -> tuple[str, str] | None:
    escaped = re.escape(name)
    patterns = [
        ("interface", re.compile(rf"\binterface\s+{escaped}(?:\s*<[^;{{>]*>)?\s*\{{")),
        ("type", re.compile(rf"\btype\s+{escaped}\s*=")),
        ("const", re.compile(rf"\bdeclare\s+const\s+{escaped}\b")),
        ("function", re.compile(rf"\bdeclare\s+function\s+{escaped}\s*[<(]")),
        ("class", re.compile(rf"\b(?:declare\s+)?class\s+{escaped}\b")),
    ]
    best: tuple[int, str, str] | None = None
    for kind, pat in patterns:
        m = pat.search(text)
        if not m:
            continue
        if kind in {"interface", "class"}:
            body = slice_brace_block(text, m.start())
        else:
            body = slice_until_semi(text, m.start())
        if best is None or m.start() < best[0]:
            best = (m.start(), kind, body)
    if best is None:
        return None
    return best[1], best[2]


class DtsBundle:
    def __init__(self, entry: Path) -> None:
        self.entry = entry
        self._cache: dict[Path, str] = {}

    def text(self, path: Path) -> str:
        resolved = path.resolve()
        if resolved not in self._cache:
            self._cache[resolved] = strip_comments(resolved.read_text(encoding="utf-8"))
        return self._cache[resolved]

    def resolve(self, public_name: str, pin: str) -> tuple[Path, str, str] | None:
        seen: set[tuple[Path, str]] = set()

        def walk(path: Path, name: str) -> tuple[Path, str, str] | None:
            key = (path.resolve(), name)
            if key in seen:
                return None
            seen.add(key)
            text = self.text(path)
            for items, from_path in parse_export_clauses(text):
                for orig, public in items:
                    if public != name:
                        continue
                    if from_path is None:
                        decl = find_decl(text, orig)
                        if decl is None:
                            return None
                        return path, orig, decl[1]
                    target = resolve_dts(path, from_path)
                    if target is None:
                        return None
                    found = walk(target, orig)
                    if found:
                        return found
                    target_text = self.text(target)
                    decl = find_decl(target_text, orig)
                    if decl is None:
                        return None
                    return target, orig, decl[1]
            decl = find_decl(text, name)
            if decl is None:
                return None
            return path, name, decl[1]

        found = walk(self.entry, public_name)
        if found is None:
            err(
                f"{self.entry.name}: cannot resolve {public_name} in {PACKAGE}@{pin}"
            )
        return found


def normalize_rail(name: str) -> str:
    """Canonicalize a rail the way the SDK's own platform gate does."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def frontmatter_description(skill: str) -> str:
    m = re.match(r"---\n(.*?)\n---\n", skill, re.S)
    if not m:
        err(f"{SKILL}: missing YAML frontmatter")
        return ""
    d = re.search(r"^description:\s*(.+)$", m.group(1), re.M)
    if not d:
        err(f"{SKILL}: frontmatter has no description")
        return ""
    return d.group(1).strip()


def documented_rails(skill: str) -> dict[str, bool]:
    """Return {rail display name: offerable} from the rails table."""
    rails: dict[str, bool] = {}
    in_table = False
    for line in skill.splitlines():
        if line.startswith("|") and re.search(
            r"\|\s*Rail\s*\|\s*Offer\s*\|", line, re.I
        ):
            in_table = True
            continue
        if not in_table:
            continue
        if not line.startswith("|"):
            break
        if re.match(r"^\|\s*-+", line):
            continue
        cols = [c.strip() for c in line.split("|")]
        if len(cols) < 3:
            continue
        name, offer = cols[1], cols[2].lower()
        if offer not in {"yes", "no"}:
            err(f"{SKILL}: rail {name!r} has Offer {cols[2]!r}; write yes or no")
            continue
        rails[name] = offer == "yes"
    if not rails:
        err(f"{SKILL}: no rails table rows found")
    return rails


def documented_bounds(skill: str) -> dict[str, tuple[int, str]]:
    """Return {constant: (base units, USDC cell)} from the amounts table."""
    bounds: dict[str, tuple[int, str]] = {}
    in_table = False
    for line in skill.splitlines():
        if line.startswith("|") and re.search(
            r"\|\s*Bound\s*\|\s*Base units\s*\|\s*USDC\s*\|", line, re.I
        ):
            in_table = True
            continue
        if not in_table:
            continue
        if not line.startswith("|"):
            break
        if re.match(r"^\|\s*-+", line):
            continue
        cols = [c.strip() for c in line.split("|")]
        if len(cols) < 4:
            continue
        name = re.fullmatch(rf"`({IDENT})`", cols[1])
        units = re.fullmatch(r"`(\d+)n`", cols[2])
        if not name:
            err(f"{SKILL}: amounts table row {cols[1]!r} is not a backticked constant")
            continue
        if not units:
            err(
                f"{SKILL}: amounts bound {name.group(1)!r} has Base units {cols[2]!r}; "
                "write a backticked bigint literal such as `10000n`"
            )
            continue
        bounds[name.group(1)] = (int(units.group(1)), cols[3])
    if not bounds:
        err(f"{SKILL}: no amounts table rows found")
    return bounds


def documented_delegation(skill: str) -> dict[str, str]:
    """Return {delegation field: asserted value} from the Install example.

    The Install block reads each field and states its value in a trailing
    comment, so the comment is the claim: `...delegation.feeRateBps; // 10`.
    """
    found = re.findall(
        rf"OFFRAMP_DEVELOPER_RESOURCES\.delegation\.({IDENT})\s*;\s*//\s*(\S+)",
        skill,
    )
    fields = {name: value for name, value in found}
    if not fields:
        err(f"{SKILL}: no annotated OFFRAMP_DEVELOPER_RESOURCES.delegation reads found")
    return fields


def documented_best_fee_bps(skill: str) -> int | None:
    """Return the Best-mode fee in bps from the Fast/Best table."""
    for line in skill.splitlines():
        if not line.startswith("|") or "`best`" not in line:
            continue
        m = re.search(r"(\d+)\s*bps", line)
        if not m:
            err(f"{SKILL}: Fast/Best table has no '<n> bps' fee for `best`")
            return None
        return int(m.group(1))
    err(f"{SKILL}: Fast/Best table has no `best` row")
    return None


def documented_fast_fee_bps(skill: str) -> int | None:
    """Return the Fast-mode spread in bps from the Fast/Best table.

    The Fast fee cell states one price twice -- `0% spread / 0 bps` -- so both
    readings are parsed and a disagreement between them is itself an error.
    """
    for line in skill.splitlines():
        if not line.startswith("|") or "`fast`" not in line:
            continue
        m = re.search(r"(\d+)\s*bps", line)
        if not m:
            err(f"{SKILL}: Fast/Best table has no '<n> bps' fee for `fast`")
            return None
        bps = int(m.group(1))
        pct = re.search(r"(\d+(?:\.\d+)?)\s*%", line)
        if pct is not None and round(float(pct.group(1)) * 100) != bps:
            err(
                f"{SKILL}: Fast/Best table prices Fast at {pct.group(1)}% and "
                f"{bps} bps, which are not the same spread"
            )
            return None
        return bps
    err(f"{SKILL}: Fast/Best table has no `fast` row")
    return None


def documented_fill_ranges(skill: str) -> dict[str, tuple[str, str]]:
    """Return {mode: (per-order min cell, per-order max cell)} as raw cells.

    Cells are USDC and each is one of `amount`, a bare number, or
    `min(amount, <n>)`. They are kept as text here so the SDK comparison can
    say which of the three shapes the runtime actually builds.
    """
    ranges: dict[str, tuple[str, str]] = {}
    in_table = False
    for line in skill.splitlines():
        if line.startswith("|") and re.search(
            r"\|\s*Mode\s*\|\s*Per-order min\s*\|\s*Per-order max\s*\|", line, re.I
        ):
            in_table = True
            continue
        if not in_table:
            continue
        if not line.startswith("|"):
            break
        if re.match(r"^\|\s*-+", line):
            continue
        cols = [c.strip() for c in line.split("|")]
        if len(cols) < 4:
            continue
        mode = re.fullmatch(r"`([a-z]+)`", cols[1])
        if not mode:
            err(f"{SKILL}: fill-range row {cols[1]!r} is not a backticked mode")
            continue
        cells: list[str] = []
        for cell in (cols[2], cols[3]):
            m = re.fullmatch(r"`([^`]+)`", cell)
            if not m:
                err(
                    f"{SKILL}: fill-range cell {cell!r} for mode "
                    f"{mode.group(1)!r} is not a backticked bound"
                )
                cells = []
                break
            cells.append(m.group(1).strip())
        if len(cells) == 2:
            ranges[mode.group(1)] = (cells[0], cells[1])
    if not ranges:
        err(f"{SKILL}: no per-order fill-range table rows found")
    return ranges


def capped_bound(cell: str) -> int | None:
    """USDC ceiling a `min(amount, <n>)` cell claims, or None for another shape."""
    m = re.fullmatch(r"min\(\s*amount\s*,\s*(\d+)\s*\)", cell)
    return int(m.group(1)) if m else None


def documented_error_codes(skill: str) -> set[str]:
    codes: set[str] = set()
    in_table = False
    for line in skill.splitlines():
        if line.startswith("|") and re.search(r"\|\s*Code\s*\|", line, re.I):
            in_table = True
            continue
        if not in_table:
            continue
        if not line.startswith("|"):
            in_table = False
            continue
        if re.match(r"^\|\s*-+", line):
            continue
        cols = [c.strip() for c in line.split("|")]
        if len(cols) < 2:
            continue
        m = re.fullmatch(rf"`({IDENT})`", cols[1])
        if m:
            codes.add(m.group(1))
    if not codes:
        err(f"{SKILL}: no error-table codes found")
    return codes


def documented_steps(skill: str) -> set[str]:
    m = re.search(r"`step` values:\s*(.+)", skill)
    if not m:
        err(f"{SKILL}: missing onProgress step values")
        return set()
    steps = set(re.findall(r"`([a-z][a-z0-9_]*)`", m.group(1)))
    if not steps:
        err(f"{SKILL}: onProgress step values list is empty")
    return steps


def import_names(inner: str) -> set[str]:
    names: set[str] = set()
    for part in inner.split(","):
        token = re.sub(r"\s+", " ", part).strip()
        if not token:
            continue
        if token.startswith("type "):
            token = token[5:].strip()
        if " as " in token:
            token = token.split(" as ", 1)[0].strip()
        if re.fullmatch(IDENT, token):
            names.add(token)
    return names


def documented_root_exports(
    skill: str, error_codes: set[str]
) -> tuple[set[str], set[str]]:
    """Return (imported, prose) claimed root exports of PACKAGE.

    The two are kept apart so a failure can say which one to fix: an import is
    an unambiguous claim, prose is an inference PROSE_NON_SDK can wave off.
    """
    imports: set[str] = set()
    other_imports: set[str] = set()
    for inner, pkg in re.findall(
        r'import\s+(?:type\s+)?\{([^}]+)\}\s+from\s+"([^"]+)"', skill
    ):
        imported = import_names(inner)
        if pkg == PACKAGE:
            imports |= imported
        else:
            other_imports |= imported
    prose: set[str] = set()
    stripped = re.sub(r"```.*?```", " ", skill, flags=re.S)
    for ident in re.findall(rf"`({IDENT})`", stripped):
        if ident in error_codes or ident in other_imports:
            continue
        # Prose only. An `import { X } from PACKAGE` above says X is an export
        # outright, so the allowlist must not excuse it.
        if ident in PROSE_NON_SDK:
            continue
        if ident == "peerExtensionSdk" or ident[0].isupper():
            prose.add(ident)
    if not (imports | prose):
        err(f"{SKILL}: no documented root SDK exports found")
    return imports, prose


def object_keys(src: str) -> list[str]:
    keys: list[str] = []
    depth = 0
    expect_key = False
    i = 0
    n = len(src)
    while i < n:
        ch = src[i]
        if ch in "'\"`":
            quote = ch
            i += 1
            while i < n:
                if src[i] == "\\" and i + 1 < n:
                    i += 2
                    continue
                if src[i] == quote:
                    i += 1
                    break
                i += 1
            continue
        if ch in "{[":
            depth += 1
            if depth == 1:
                expect_key = True
            i += 1
            continue
        if ch in "}]":
            depth -= 1
            i += 1
            continue
        if depth != 1:
            i += 1
            continue
        if ch == ",":
            expect_key = True
            i += 1
            continue
        if not expect_key:
            i += 1
            continue
        if src.startswith("...", i):
            i += 3
            while i < n and (src[i].isalnum() or src[i] == "_"):
                i += 1
            expect_key = False
            continue
        m = re.match(rf"({IDENT})\s*:", src[i:])
        if m:
            keys.append(m.group(1))
            i += m.end()
            expect_key = False
            continue
        m = re.match(rf"({IDENT})\s*(?=,|}})", src[i:])
        if m:
            keys.append(m.group(1))
            i += m.end()
            expect_key = False
            continue
        i += 1
    return keys


def fenced_spans(skill: str) -> list[tuple[int, int]]:
    return [(m.start(), m.end()) for m in re.finditer(r"```.*?```", skill, re.S)]


def cashout_example_keys(skill: str) -> set[str]:
    keys: set[str] = set()
    fences = fenced_spans(skill)
    examples = 0
    i = 0
    while True:
        m = re.search(r"\bcashout\s*\(", skill[i:])
        if not m:
            break
        call_at = i + m.start()
        start = i + m.end()
        depth = 1
        j = start
        while j < len(skill) and depth:
            if skill[j] == "(":
                depth += 1
            elif skill[j] == ")":
                depth -= 1
            j += 1
        args = skill[start : j - 1].strip()
        i = j
        if not args.startswith("{"):
            continue
        found = object_keys(args)
        keys.update(found)
        # Only fenced code is an example an agent copies. The frontmatter and prose
        # also spell cashout({ mode: ... }), which would satisfy 'mode' for free.
        if not any(lo <= call_at < hi for lo, hi in fences):
            continue
        examples += 1
        if "mode" not in found:
            line = skill.count("\n", 0, call_at) + 1
            err(
                f"{SKILL}:{line}: cashout() example omits the required 'mode' argument"
            )
    if not keys:
        err(f"{SKILL}: no cashout({{ ... }}) example keys found")
    if not examples:
        err(f"{SKILL}: no fenced cashout({{ ... }}) example found")
    return keys


def const_object_keys(decl: str) -> set[str]:
    keys = set(re.findall(rf"readonly\s+({IDENT})\s*:", decl))
    if keys:
        return keys
    return set(re.findall(rf"(?:^|[{{,])\s*({IDENT})\s*:", decl))


def union_string_literals(decl: str) -> set[str]:
    return set(re.findall(r'"([^"]+)"', decl))


def delegation_literals(decl: str, text: str) -> dict[str, str] | None:
    """Return {field: literal} for the delegation block of a resources decl.

    Fields are declared either as an inline literal type (`required: false`) or
    as `typeof SOME_CONST`, where the const is declared beside the interface in
    the same file. An alias whose const carries a type but no initializer -- as
    the address constants do -- has no literal to compare and is left out.
    """
    m = re.search(r"\bdelegation\s*:\s*\{", decl)
    if not m:
        return None
    block = slice_brace_block(decl, m.start())
    out: dict[str, str] = {}
    for name, raw in re.findall(rf"({IDENT})\s*:\s*([^;{{}}]+);", block):
        value = raw.strip()
        alias = re.fullmatch(rf"typeof\s+({IDENT})", value)
        if not alias:
            out[name] = value
            continue
        const = re.search(
            rf"\bdeclare\s+const\s+{re.escape(alias.group(1))}\s*(?::[^=;]+)?=\s*([^;]+);",
            text,
        )
        if const:
            out[name] = const.group(1).strip()
    return out


def property_keys(decl: str) -> set[str]:
    keys: set[str] = set()
    for m in re.finditer(
        rf"(?:^|[,{{;])\s*(?:readonly\s+)?({IDENT})\s*\??\s*:", decl
    ):
        keys.add(m.group(1))
    return keys


def collect_input_keys(bundle: DtsBundle, path: Path, name: str) -> set[str]:
    seen: set[str] = set()
    keys: set[str] = set()

    def walk(file_path: Path, ident: str) -> None:
        if ident in seen or ident in TS_SKIP:
            return
        seen.add(ident)
        text = bundle.text(file_path)
        decl = find_decl(text, ident)
        if decl is None:
            for items, from_path in parse_export_clauses(text):
                for orig, public in items:
                    if public != ident or from_path is None:
                        continue
                    target = resolve_dts(file_path, from_path)
                    if target is not None:
                        walk(target, orig)
                        return
            return
        body = decl[1]
        keys.update(property_keys(body))
        for ref in IDENT_RE.findall(strip_strings(body)):
            if ref == ident or ref in TS_SKIP or ref in keys:
                continue
            if find_decl(text, ref) is not None:
                walk(file_path, ref)

    walk(path, name)
    return keys


def verify_integrity(
    blob: bytes, integrity: str, pin: str, pkg: str = PACKAGE
) -> None:
    if "-" not in integrity:
        err(f"{pkg}@{pin}: packument dist.integrity is malformed")
        fail_exit()
    algo, b64 = integrity.split("-", 1)
    try:
        digest = hashlib.new(algo, blob).digest()
    except ValueError:
        err(f"{pkg}@{pin}: unsupported integrity algorithm {algo}")
        fail_exit()
        return
    actual = base64.b64encode(digest).decode("ascii")
    if actual != b64:
        err(f"{pkg}@{pin}: tarball integrity mismatch")
        fail_exit()


def safe_extract(tar: tarfile.TarFile, dest: Path, pkg: str = PACKAGE) -> None:
    dest = dest.resolve()
    for member in tar.getmembers():
        target = (dest / member.name).resolve()
        if dest != target and dest not in target.parents:
            err(f"{pkg}: tarball member escapes extract dir: {member.name}")
            fail_exit()
    kwargs = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
    tar.extractall(dest, **kwargs)


def subpath_entries(pkg_root: Path) -> dict[str, Path]:
    """Map each non-root export specifier to its type-declaration entry."""
    meta = json.loads((pkg_root / "package.json").read_text(encoding="utf-8"))
    exports = meta.get("exports")
    out: dict[str, Path] = {}
    if not isinstance(exports, dict):
        return out
    for sub, val in exports.items():
        if sub == "." or not sub.startswith("./") or not isinstance(val, dict):
            continue
        types = None
        imp = val.get("import")
        if isinstance(imp, dict) and isinstance(imp.get("types"), str):
            types = imp["types"]
        elif isinstance(val.get("types"), str):
            types = val["types"]
        if not types:
            continue
        path = pkg_root / types
        if path.is_file():
            out[f"{PACKAGE}/{sub[2:]}"] = path
    return out


def prose_call_identifiers(skill: str) -> set[str]:
    """Leading identifier of every backticked prose span.

    documented_root_exports() only sees a span that is *entirely* an identifier,
    so a documented call such as `usePeerExtensionRegistration(platform)` is
    invisible to it -- the trailing argument list breaks the full match. This
    scan is deliberately looser and keeps the leading identifier of any span;
    main() then discards every candidate that is not really exported by PACKAGE,
    which is what stops ordinary prose words from being read as export claims.
    """
    stripped = re.sub(r"```.*?```", " ", skill, flags=re.S)
    names: set[str] = set()
    for span in re.findall(r"`([^`]+)`", stripped):
        m = re.match(rf"^({IDENT})", span)
        if m:
            names.add(m.group(1))
    return names


def bounds_dependency_pin(pkg_root: Path, pin: str) -> str | None:
    """Version of BOUNDS_PACKAGE that PACKAGE@pin declares a dependency on."""
    meta = json.loads((pkg_root / "package.json").read_text(encoding="utf-8"))
    spec = (meta.get("dependencies") or {}).get(BOUNDS_PACKAGE)
    if not isinstance(spec, str):
        err(
            f"{PACKAGE}@{pin}: no {BOUNDS_PACKAGE} dependency, so the amounts "
            "table cannot be verified; drop the table or repoint this check"
        )
        return None
    exact = spec.lstrip("=v")
    if re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", exact):
        return exact
    ranged = spec.lstrip("^~=v")
    if re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", ranged):
        # A range resolves at install time to something this script cannot see.
        # Checking its floor is weaker than checking the installed version, so
        # say so rather than reporting a stronger result than was measured.
        print(
            f"notice: {PACKAGE}@{pin} depends on {BOUNDS_PACKAGE}{spec}; "
            f"amounts verified against {ranged}, not the resolved version"
        )
        return ranged
    err(f"{PACKAGE}@{pin}: cannot read a version from {BOUNDS_PACKAGE} spec {spec!r}")
    return None


_dependency_blobs: dict[str, bytes | None] = {}


def dependency_blob(dep_pin: str) -> bytes | None:
    """Integrity-checked BOUNDS_PACKAGE tarball, fetched at most once per run."""
    if dep_pin in _dependency_blobs:
        return _dependency_blobs[dep_pin]
    blob: bytes | None = None
    packument = json.loads(http_get(BOUNDS_REGISTRY).decode("utf-8"))
    versions = packument.get("versions") or {}
    if dep_pin not in versions:
        err(f"{BOUNDS_PACKAGE}@{dep_pin} is not a published version")
    else:
        dist = versions[dep_pin].get("dist") or {}
        tarball_url = dist.get("tarball")
        if not tarball_url:
            err(f"{BOUNDS_PACKAGE}@{dep_pin}: packument is missing dist.tarball")
        else:
            blob = http_get(tarball_url)
            integrity = dist.get("integrity")
            if integrity:
                verify_integrity(blob, integrity, dep_pin, BOUNDS_PACKAGE)
    _dependency_blobs[dep_pin] = blob
    return blob


def dependency_bigint_consts(names: list[str], dep_pin: str) -> dict[str, int]:
    """Declared value of each `declare const NAME = <n>n` in BOUNDS_PACKAGE."""
    blob = dependency_blob(dep_pin)
    if blob is None:
        return {}
    found: dict[str, int] = {}
    with tempfile.TemporaryDirectory(prefix="usdctofiat-bounds-") as tmp:
        dest = Path(tmp)
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
            safe_extract(tar, dest, BOUNDS_PACKAGE)
        root = dest / "package"
        if not root.is_dir():
            err(f"{BOUNDS_PACKAGE}@{dep_pin}: tarball missing package/ directory")
            return {}
        sources = sorted(root.rglob("*.d.ts")) + sorted(root.rglob("*.d.cts"))
        for name in names:
            pat = re.compile(rf"\bdeclare\s+const\s+{re.escape(name)}\s*=\s*(\d+)n\b")
            for src in sources:
                m = pat.search(strip_comments(src.read_text(encoding="utf-8")))
                if m:
                    found[name] = int(m.group(1))
                    break
    return found


# The per-order range is built from constants neither package exports or
# documents, so these names are read straight out of the shipped bundles.
# A repin that renames one fails this check rather than silently passing: the
# claim is unprovable at that point, and a wrong ceiling is the difference
# between a cash-out that clears once and one that waits on several buyers.
BEST_MIN_CONST = "MIN_ORDER_USDC"
BEST_MAX_CONST = "MAX_ORDER_USDC"
FAST_MIN_CONST = "DEFAULT_MIN_ORDER_FLOOR"
FAST_RANGE_FN = "buildIntentAmountRange"


def runtime_sources(root: Path) -> dict[str, str]:
    """Comment-stripped ESM bundles shipped under the package's dist/."""
    dist = root / "dist"
    if not dist.is_dir():
        return {}
    return {
        src.name: strip_comments(src.read_text(encoding="utf-8"))
        for src in sorted(dist.glob("*.js"))
    }


def js_number_const(sources: dict[str, str], name: str, label: str) -> int | None:
    """Single literal value of `var NAME = <n>[n];` across the bundles."""
    pat = re.compile(rf"\b(?:var|let|const)\s+{re.escape(name)}\s*=\s*(\d+)n?\s*;")
    values = {int(m.group(1)) for src in sources.values() for m in pat.finditer(src)}
    if not values:
        err(f"{label}: {name} is not declared as a number literal in dist/*.js")
        return None
    if len(values) > 1:
        err(f"{label}: {name} has conflicting literals {sorted(values)} in dist/*.js")
        return None
    return next(iter(values))


def best_fill_range(
    sources: dict[str, str], label: str
) -> tuple[int | None, int | None]:
    """(per-order min USDC, per-order ceiling USDC) built by the Best deposit.

    Reading the constants alone would prove only that they exist. This resolves
    the `intentAmountRange` literal the deposit is actually created with and
    walks back to the locals it is assigned from, so a constant left declared
    but unwired fails instead of confirming the table.
    """
    hits = [
        (name, m)
        for name, src in sources.items()
        for m in re.finditer(r"\bintentAmountRange\s*:\s*\{", src)
    ]
    if not hits:
        err(f"{label}: no intentAmountRange object literal in dist/*.js")
        return None, None
    if len(hits) > 1:
        err(
            f"{label}: {len(hits)} intentAmountRange literals in dist/*.js; the "
            "fill-range table claims one range per mode and cannot say which"
        )
        return None, None
    name, m = hits[0]
    src = sources[name]
    block = slice_brace_block(src, m.start())
    out: list[int | None] = []
    for field, const, capped in (
        ("min", BEST_MIN_CONST, False),
        ("max", BEST_MAX_CONST, True),
    ):
        ref = re.search(rf"\b{field}\s*:\s*({IDENT})\b", block)
        if not ref:
            err(f"{name}: intentAmountRange has no {field} local ({label})")
            out.append(None)
            continue
        local = ref.group(1)
        decl = re.search(
            rf"\b(?:const|let|var)\s+{re.escape(local)}\s*=\s*([^;]+);", src
        )
        if not decl:
            err(
                f"{name}: intentAmountRange {field} local {local!r} has no "
                f"declaration ({label})"
            )
            out.append(None)
            continue
        expr = decl.group(1)
        if const not in expr:
            err(
                f"{name}: intentAmountRange {field} is built from {expr.strip()!r}, "
                f"which does not read {const} ({label})"
            )
            out.append(None)
            continue
        if capped and not re.search(rf"Math\.min\([^;]*\b{re.escape(const)}\b", expr):
            err(
                f"{name}: intentAmountRange max reads {const} without a Math.min "
                f"ceiling ({label}); the table claims min(amount, <n>)"
            )
            out.append(None)
            continue
        out.append(js_number_const(sources, const, label))
    return out[0], out[1]


def fast_fill_range(
    sources: dict[str, str], label: str
) -> tuple[int | None, str | None]:
    """(per-order min USDC, max shape) the Fast route's range builder writes."""
    hits = [
        (name, m)
        for name, src in sources.items()
        for m in re.finditer(
            rf"\bfunction\s+{FAST_RANGE_FN}\s*\(\s*({IDENT})\s*\)", src
        )
    ]
    if not hits:
        err(f"{label}: {FAST_RANGE_FN}() is not defined in dist/*.js")
        return None, None
    if len(hits) > 1:
        # Same reason the Best reader refuses two range literals: with more than
        # one definition there is no single range the `fast` row can name.
        err(
            f"{label}: {len(hits)} {FAST_RANGE_FN}() definitions in dist/*.js; "
            "the fill-range table cannot say which builds the Fast range"
        )
        return None, None
    name, m = hits[0]
    src = sources[name]
    if not re.search(rf"intentAmountRange\s*(?:=|\?\?)[^;]*\b{FAST_RANGE_FN}\s*\(", src):
        err(
            f"{name}: {FAST_RANGE_FN}() is defined but never builds an "
            f"intentAmountRange ({label})"
        )
        return None, None
    param = m.group(1)
    body = slice_brace_block(src, m.end())
    ret = re.search(r"\breturn\s*\{", body)
    if not ret:
        err(f"{name}: {FAST_RANGE_FN}() returns no object literal ({label})")
        return None, None
    returned = slice_brace_block(body, ret.start())
    max_at = re.search(r"\bmax\s*:", returned)
    if not max_at:
        err(f"{name}: {FAST_RANGE_FN}() return has no max field ({label})")
        return None, None
    # Slice to the matching separator rather than the first comma, so a nested
    # call such as Math.min(amount, CAP) is reported whole instead of clipped.
    depth = 0
    end = max_at.end()
    while end < len(returned):
        ch = returned[end]
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                break
            depth -= 1
        elif ch == "," and depth == 0:
            break
        end += 1
    raw = returned[max_at.end() : end].strip()
    shape = "amount" if raw == param else raw
    if FAST_MIN_CONST not in body:
        err(
            f"{name}: {FAST_RANGE_FN}() does not read {FAST_MIN_CONST} ({label}); "
            "the table claims a per-order minimum"
        )
        return None, shape
    units = js_number_const(sources, FAST_MIN_CONST, label)
    if units is None:
        return None, shape
    if units % 10**USDC_DECIMALS:
        err(
            f"{label}: {FAST_MIN_CONST} is {units}n base units, which is not a "
            "whole number of USDC; the fill-range table states whole USDC"
        )
        return None, shape
    return units // 10**USDC_DECIMALS, shape


def entry_dts(pkg_root: Path, pin: str) -> Path:
    meta_path = pkg_root / "package.json"
    if not meta_path.is_file():
        err(f"{PACKAGE}@{pin}: package.json missing from tarball")
        fail_exit()
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    candidates: list[str] = []
    types = meta.get("types") or meta.get("typings")
    if isinstance(types, str):
        candidates.append(types)
    exports = meta.get("exports")
    if isinstance(exports, dict):
        root_export = exports.get(".")
        if isinstance(root_export, dict):
            imp = root_export.get("import")
            if isinstance(imp, dict) and isinstance(imp.get("types"), str):
                candidates.append(imp["types"])
            if isinstance(root_export.get("types"), str):
                candidates.append(root_export["types"])
    candidates.append("./dist/index.d.ts")
    for rel in candidates:
        path = (pkg_root / rel)
        if path.is_file():
            return path
    err(f"{PACKAGE}@{pin}: no type-declaration entry file in tarball")
    fail_exit()
    return pkg_root


def main() -> None:
    skill = load_skill()
    pin = parse_pin(skill)
    packument = json.loads(http_get(REGISTRY).decode("utf-8"))
    versions = packument.get("versions") or {}
    if pin not in versions:
        err(f"{SKILL}: pin {pin} is not a published {PACKAGE} version")
        fail_exit()
    dist = versions[pin].get("dist") or {}
    tarball_url = dist.get("tarball")
    integrity = dist.get("integrity")
    if not tarball_url:
        err(f"{PACKAGE}@{pin}: packument is missing dist.tarball")
        fail_exit()
    blob = http_get(tarball_url)
    if integrity:
        verify_integrity(blob, integrity, pin)

    with tempfile.TemporaryDirectory(prefix="usdctofiat-surface-") as tmp:
        dest = Path(tmp)
        with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
            safe_extract(tar, dest)
        pkg_root = dest / "package"
        if not pkg_root.is_dir():
            err(f"{PACKAGE}@{pin}: tarball missing package/ directory")
            fail_exit()
        entry = entry_dts(pkg_root, pin)
        bundle = DtsBundle(entry)
        entry_text = bundle.text(entry)
        root_names = named_root_exports(entry_text)

        error_codes_doc = documented_error_codes(skill)
        steps_doc = documented_steps(skill)
        imported_doc, prose_doc = documented_root_exports(skill, error_codes_doc)
        root_doc = imported_doc | prose_doc
        example_keys = cashout_example_keys(skill)

        for name in sorted(PROSE_NON_SDK & root_names):
            err(
                f"scripts/verify-surface.sh: PROSE_NON_SDK lists {name!r}, which is a "
                f"root export of {PACKAGE}@{pin}; drop it so the prose scan checks it"
            )

        for name in sorted(root_doc):
            if name not in root_names:
                near = difflib.get_close_matches(
                    name, sorted(root_names), n=1, cutoff=0.8
                )
                if near:
                    fix = f"did you mean {near[0]!r}?"
                elif name in imported_doc:
                    fix = "drop it from the import, or repin to a version exporting it"
                else:
                    fix = (
                        "correct the doc, or add it to PROSE_NON_SDK in "
                        "scripts/verify-surface.sh if it names something outside the SDK"
                    )
                err(
                    f"{SKILL}: documented export {name!r} is not a root export of "
                    f"{PACKAGE}@{pin}; {fix}"
                )

        # A symbol the SDK ships only from a subpath is unusable via the root
        # import the Install section documents. Naming the specifier is the
        # minimum that keeps a copied example resolvable.
        subpaths = subpath_entries(pkg_root)
        subpath_names = {
            spec: named_root_exports(bundle.text(path))
            for spec, path in subpaths.items()
        }
        for name in sorted(prose_call_identifiers(skill)):
            if name in root_names:
                continue
            homes = sorted(s for s, v in subpath_names.items() if name in v)
            if not homes:
                continue
            if any(spec in skill for spec in homes):
                continue
            err(
                f"{SKILL}: {name!r} is exported from {' / '.join(homes)}, not the "
                f"{PACKAGE}@{pin} root; name that subpath where the doc uses it"
            )

        codes_resolved = bundle.resolve("OFFRAMP_ERROR_CODES", pin)
        sdk_code_count = 0
        if codes_resolved is not None:
            path, _orig, decl = codes_resolved
            sdk_codes = const_object_keys(decl)
            sdk_code_count = len(sdk_codes)
            if not sdk_codes:
                err(
                    f"{path.name}: OFFRAMP_ERROR_CODES keys could not be parsed in {PACKAGE}@{pin}"
                )
            for code in sorted(sdk_codes - error_codes_doc):
                err(
                    f"{SKILL}: error table is missing {code!r} from {path.name} ({PACKAGE}@{pin})"
                )
            for code in sorted(error_codes_doc - sdk_codes):
                err(
                    f"{SKILL}: error table has {code!r} which is not in {path.name} ({PACKAGE}@{pin})"
                )
        else:
            err(
                f"{SKILL}: OFFRAMP_ERROR_CODES is not a root export of {PACKAGE}@{pin}"
            )

        step_resolved = bundle.resolve("OfframpStep", pin)
        sdk_step_count = 0
        if step_resolved is not None:
            path, _orig, decl = step_resolved
            sdk_steps = union_string_literals(decl)
            sdk_step_count = len(sdk_steps)
            if not sdk_steps:
                err(
                    f"{path.name}: OfframpStep union could not be parsed in {PACKAGE}@{pin}"
                )
            for step in sorted(sdk_steps - steps_doc):
                err(
                    f"{SKILL}: onProgress steps missing {step!r} from {path.name} ({PACKAGE}@{pin})"
                )
            for step in sorted(steps_doc - sdk_steps):
                err(
                    f"{SKILL}: onProgress steps has {step!r} which is not in {path.name} ({PACKAGE}@{pin})"
                )
        else:
            err(f"{SKILL}: OfframpStep is not a root export of {PACKAGE}@{pin}")

        input_resolved = bundle.resolve("OfframpCashoutInput", pin)
        sdk_key_count = 0
        if input_resolved is not None:
            path, orig, _decl = input_resolved
            sdk_keys = collect_input_keys(bundle, path, orig)
            sdk_key_count = len(sdk_keys)
            if "mode" not in sdk_keys:
                err(
                    f"{path.name}: OfframpCashoutInput has no 'mode' field in {PACKAGE}@{pin}"
                )
            if not sdk_keys:
                err(
                    f"{path.name}: OfframpCashoutInput fields could not be parsed in {PACKAGE}@{pin}"
                )
            for key in sorted(example_keys):
                if key not in sdk_keys:
                    err(
                        f"{SKILL}: cashout() argument key {key!r} is not an OfframpCashoutInput field in {path.name} ({PACKAGE}@{pin})"
                    )
        else:
            err(
                f"{SKILL}: OfframpCashoutInput is not a root export of {PACKAGE}@{pin}"
            )

        # The rails table is the skill's routing surface, and nothing else here
        # checks it. Unverified, it named eight rails against a nine-rail SDK
        # from at least 8.0.2 through 9.0.0, silently dropping mercadopago.
        rails_doc = documented_rails(skill)
        sdk_rail_count = 0
        platforms_resolved = bundle.resolve("PLATFORMS", pin)
        if platforms_resolved is not None:
            path, _orig, decl = platforms_resolved
            sdk_rails = {normalize_rail(k) for k in const_object_keys(decl)}
            sdk_rail_count = len(sdk_rails)
            doc_rails = {normalize_rail(n): n for n in rails_doc}
            if not sdk_rails:
                err(f"{path.name}: PLATFORMS keys could not be parsed in {PACKAGE}@{pin}")
            for rail in sorted(sdk_rails - set(doc_rails)):
                err(
                    f"{SKILL}: rails table is missing the {rail!r} rail from "
                    f"{path.name} ({PACKAGE}@{pin})"
                )
            for rail in sorted(set(doc_rails) - sdk_rails):
                err(
                    f"{SKILL}: rails table has {doc_rails[rail]!r} which is not a "
                    f"PLATFORMS rail in {PACKAGE}@{pin}"
                )
        else:
            err(f"{SKILL}: PLATFORMS is not a root export of {PACKAGE}@{pin}")

        # One-way on purpose. Offering a rail the SDK rejects before the deposit
        # transaction is the failure that costs a user a wallet prompt; refusing
        # one the SDK allows is a deliberate policy call the Why column carries.
        disabled_resolved = bundle.resolve("OFFRAMP_DISABLED_PAYMENT_PLATFORMS", pin)
        if disabled_resolved is not None:
            path, _orig, decl = disabled_resolved
            sdk_disabled = {normalize_rail(v) for v in union_string_literals(decl)}
            if not sdk_disabled and "[]" not in re.sub(r"\s+", "", decl):
                err(
                    f"{path.name}: OFFRAMP_DISABLED_PAYMENT_PLATFORMS entries could "
                    f"not be parsed in {PACKAGE}@{pin}"
                )
            for rail in sorted(sdk_disabled):
                named = next(
                    (n for n in rails_doc if normalize_rail(n) == rail), None
                )
                if named is not None and rails_doc[named]:
                    err(
                        f"{SKILL}: rails table offers {named!r}, which "
                        f"{PACKAGE}@{pin} disables via "
                        f"OFFRAMP_DISABLED_PAYMENT_PLATFORMS"
                    )
        else:
            err(
                f"{SKILL}: OFFRAMP_DISABLED_PAYMENT_PLATFORMS is not a root export "
                f"of {PACKAGE}@{pin}"
            )

        # The root-export scan proves only that these names exist. Their values
        # live in the SDK's own dependency, so nothing else here would notice a
        # floor going stale, and a wrong floor is advice that creates a deposit
        # which can never fill.
        bounds_doc = documented_bounds(skill)
        sdk_bound_count = 0
        dep_pin = bounds_dependency_pin(pkg_root, pin) if bounds_doc else None
        if bounds_doc and dep_pin:
            sdk_bounds = dependency_bigint_consts(sorted(bounds_doc), dep_pin)
            sdk_bound_count = len(sdk_bounds)
            for name, (units, usdc_cell) in sorted(bounds_doc.items()):
                actual = sdk_bounds.get(name)
                if actual is None:
                    err(
                        f"{SKILL}: amounts table documents {name!r}, which "
                        f"{BOUNDS_PACKAGE}@{dep_pin} does not declare as a bigint "
                        "constant"
                    )
                    continue
                if actual != units:
                    err(
                        f"{SKILL}: amounts table has {name} = {units}n; "
                        f"{BOUNDS_PACKAGE}@{dep_pin} declares {actual}n"
                    )
                    continue
                try:
                    stated = float(usdc_cell)
                except ValueError:
                    err(
                        f"{SKILL}: amounts table USDC cell {usdc_cell!r} for "
                        f"{name} is not a number"
                    )
                    continue
                if round(stated * 10**USDC_DECIMALS) != actual:
                    err(
                        f"{SKILL}: amounts table says {name} is {usdc_cell} USDC, "
                        f"but {actual}n base units is "
                        f"{actual / 10**USDC_DECIMALS:g} USDC"
                    )

        # The floors above bound the deposit; this bounds a single fill of it.
        # Best writes its own intentAmountRange and caps one order, so a Best
        # cash-out above that ceiling needs several buyers however healthy the
        # rail is -- and an agent that quotes a single fill has promised a wait
        # it cannot deliver. Nothing rejects the amount, so only reading the
        # ranges the two routes actually build catches a moved ceiling.
        ranges_doc = documented_fill_ranges(skill)
        offramp_label = f"{PACKAGE}@{pin}"
        best_min, best_cap = best_fill_range(runtime_sources(pkg_root), offramp_label)
        best_doc = ranges_doc.get("best")
        if best_doc is None:
            err(f"{SKILL}: fill-range table has no `best` row")
        else:
            doc_min, doc_max = best_doc
            if best_min is not None and doc_min != str(best_min):
                err(
                    f"{SKILL}: fill-range table gives Best a per-order min of "
                    f"{doc_min!r}; {offramp_label} builds it from "
                    f"{BEST_MIN_CONST} = {best_min}"
                )
            doc_cap = capped_bound(doc_max)
            if doc_cap is None:
                err(
                    f"{SKILL}: fill-range table gives Best a per-order max of "
                    f"{doc_max!r}; {offramp_label} caps it, so write "
                    "min(amount, <n>)"
                )
            elif best_cap is not None and doc_cap != best_cap:
                err(
                    f"{SKILL}: fill-range table caps a Best order at {doc_cap} "
                    f"USDC; {offramp_label} declares {BEST_MAX_CONST} = {best_cap}"
                )

        fast_doc = ranges_doc.get("fast")
        if fast_doc is None:
            err(f"{SKILL}: fill-range table has no `fast` row")
        elif dep_pin:
            fast_label = f"{BOUNDS_PACKAGE}@{dep_pin}"
            blob = dependency_blob(dep_pin)
            if blob is not None:
                with tempfile.TemporaryDirectory(prefix="usdctofiat-fast-") as tmp:
                    dest = Path(tmp)
                    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
                        safe_extract(tar, dest, BOUNDS_PACKAGE)
                    fast_min, fast_shape = fast_fill_range(
                        runtime_sources(dest / "package"), fast_label
                    )
                doc_min, doc_max = fast_doc
                if fast_min is not None and capped_bound(doc_min) != fast_min:
                    err(
                        f"{SKILL}: fill-range table gives Fast a per-order min of "
                        f"{doc_min!r}; {fast_label} floors it at {fast_min} USDC, "
                        f"so write min(amount, {fast_min})"
                    )
                if fast_shape is not None and fast_shape != "amount":
                    err(
                        f"{SKILL}: fill-range table gives Fast no ceiling; "
                        f"{fast_label} builds max from {fast_shape!r}"
                    )
                elif fast_shape == "amount" and doc_max != "amount":
                    err(
                        f"{SKILL}: fill-range table gives Fast a per-order max of "
                        f"{doc_max!r}; {fast_label} writes the whole amount, so "
                        "write amount"
                    )
        else:
            err(
                f"{SKILL}: fill-range table states a Fast per-order range, but no "
                f"{BOUNDS_PACKAGE} pin was resolved to verify it against"
            )

        # Delegation values are quoted twice: the Fast/Best table prices Best
        # from feeRateBps, and the Install example asserts each field inline.
        # The root-export scan proves only that OFFRAMP_DEVELOPER_RESOURCES
        # exists, so a repin that moved the fee or flipped `required` would
        # leave both claims stale -- and a wrong fee misprices every Best
        # cash-out the skill quotes.
        delegation_doc = documented_delegation(skill)
        best_bps_doc = documented_best_fee_bps(skill)
        resources_resolved = bundle.resolve("OfframpDeveloperResources", pin)
        if resources_resolved is not None:
            path, _orig, decl = resources_resolved
            literals = delegation_literals(decl, bundle.text(path))
            if literals is None:
                err(
                    f"{path.name}: OfframpDeveloperResources has no delegation block "
                    f"in {PACKAGE}@{pin}"
                )
            else:
                for name, claimed in sorted(delegation_doc.items()):
                    actual = literals.get(name)
                    if actual is None:
                        err(
                            f"{SKILL}: Install example reads delegation.{name}, which "
                            f"{path.name} ({PACKAGE}@{pin}) does not declare as a "
                            "literal value"
                        )
                    elif actual != claimed:
                        err(
                            f"{SKILL}: Install example says delegation.{name} is "
                            f"{claimed}; {path.name} ({PACKAGE}@{pin}) declares {actual}"
                        )
                fee = literals.get("feeRateBps")
                if (
                    best_bps_doc is not None
                    and fee is not None
                    and fee != str(best_bps_doc)
                ):
                    err(
                        f"{SKILL}: Fast/Best table prices Best at {best_bps_doc} bps; "
                        f"{path.name} ({PACKAGE}@{pin}) declares feeRateBps {fee}"
                    )

        # Fast is the mode every example passes and the default an agent quotes,
        # yet its price was the one number in the Fast/Best table nothing read.
        # The SDK pins the spread as a literal type on the capabilities pricing
        # block, so a repin that started charging would leave the skill
        # advertising a free cash-out that the SDK no longer gives.
        fast_bps_doc = documented_fast_fee_bps(skill)
        sdk_fast_bps: int | None = None
        capabilities_resolved = bundle.resolve("OfframpCashCapabilities", pin)
        if capabilities_resolved is not None:
            path, _orig, decl = capabilities_resolved
            m = re.search(r"\bpricing\s*:\s*\{", decl)
            if not m:
                err(
                    f"{path.name}: OfframpCashCapabilities has no pricing block in "
                    f"{PACKAGE}@{pin}"
                )
            else:
                block = slice_brace_block(decl, m.start())
                spread = re.search(r"\bspreadBps\s*:\s*(\d+)\s*;", block)
                if spread is None:
                    err(
                        f"{path.name}: pricing.spreadBps is not a literal in "
                        f"{PACKAGE}@{pin}; the Fast/Best table cannot claim a "
                        "fixed spread the SDK no longer fixes"
                    )
                else:
                    sdk_fast_bps = int(spread.group(1))
                    if fast_bps_doc is not None and sdk_fast_bps != fast_bps_doc:
                        err(
                            f"{SKILL}: Fast/Best table prices Fast at "
                            f"{fast_bps_doc} bps; {path.name} ({PACKAGE}@{pin}) "
                            f"declares pricing.spreadBps {sdk_fast_bps}"
                        )
        else:
            err(
                f"{SKILL}: OfframpCashCapabilities is not a root export of "
                f"{PACKAGE}@{pin}"
            )

        # The description is what an agent matches a user's request against, so a
        # rail absent from it is unreachable however the body reads.
        description = normalize_rail(frontmatter_description(skill))
        if description:
            for name in sorted(n for n, offerable in rails_doc.items() if offerable):
                if normalize_rail(name) not in description:
                    err(
                        f"{SKILL}: frontmatter description does not name the "
                        f"offerable rail {name!r}"
                    )

        # First-party README URLs are consumer entry points. A 404 there is a
        # dead published link, unlike third-party listings this repo does not
        # operate.
        readme_text = README.read_text(encoding="utf-8") if README.is_file() else ""
        if not readme_text:
            err(f"{README}: missing")
            readme_live_count = 0
        else:
            readme_live_count = verify_readme_live_urls(readme_text)

        latest = (packument.get("dist-tags") or {}).get("latest")
        if errors:
            fail_exit()

        print(
            f"ok: {PACKAGE}@{pin}; {len(root_doc)} root exports; "
            f"{len(subpaths)} subpaths; {sdk_code_count} error codes; "
            f"{sdk_step_count} steps; {sdk_key_count} cashout keys; "
            f"{sdk_rail_count} rails; {sdk_bound_count} amount bounds; "
            f"{len(delegation_doc)} delegation values; "
            f"fast spread {sdk_fast_bps} bps; "
            f"best order cap {best_cap} USDC; "
            f"{readme_live_count} live README urls"
        )
        if latest and latest != pin:
            print(f"notice: pin {pin} lags registry latest {latest}")
        elif latest == pin:
            print(f"ok: pin {pin} matches registry latest")
        else:
            print("notice: registry latest dist-tag missing from packument")


if __name__ == "__main__":
    main()
PY
