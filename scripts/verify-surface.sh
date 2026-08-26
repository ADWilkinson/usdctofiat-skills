#!/usr/bin/env bash
# Network-allowed check: SKILL.md's documented SDK surface vs the pinned tarball.
# Stdlib Python only (urllib, tarfile, json). Does not replace scripts/check.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
from __future__ import annotations

import base64
import hashlib
import io
import json
import re
import ssl
import sys
import tarfile
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

errors: list[str] = []

ROOT = Path(".")
SKILL = ROOT / "skills/cashout/SKILL.md"
REGISTRY = "https://registry.npmjs.org/@usdctofiat/offramp"
PACKAGE = "@usdctofiat/offramp"
UA = "usdctofiat-skills-verify-surface (+https://github.com/ADWilkinson/usdctofiat-skills)"
PIN_RE = re.compile(r"^npm install @usdctofiat/offramp@(\d+\.\d+\.\d+)$", re.M)
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
IDENT = r"[A-Za-z_][A-Za-z0-9_]*"
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


def documented_root_exports(skill: str, error_codes: set[str]) -> set[str]:
    names: set[str] = set()
    other_imports: set[str] = set()
    for inner, pkg in re.findall(
        r'import\s+(?:type\s+)?\{([^}]+)\}\s+from\s+"([^"]+)"', skill
    ):
        imported = import_names(inner)
        if pkg == PACKAGE:
            names |= imported
        else:
            other_imports |= imported
    stripped = re.sub(r"```.*?```", " ", skill, flags=re.S)
    for ident in re.findall(rf"`({IDENT})`", stripped):
        if ident in error_codes or ident in other_imports:
            continue
        if ident == "peerExtensionSdk" or ident[0].isupper():
            names.add(ident)
    if not names:
        err(f"{SKILL}: no documented root SDK exports found")
    return names


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


def verify_integrity(blob: bytes, integrity: str, pin: str) -> None:
    if "-" not in integrity:
        err(f"{PACKAGE}@{pin}: packument dist.integrity is malformed")
        fail_exit()
    algo, b64 = integrity.split("-", 1)
    try:
        digest = hashlib.new(algo, blob).digest()
    except ValueError:
        err(f"{PACKAGE}@{pin}: unsupported integrity algorithm {algo}")
        fail_exit()
        return
    actual = base64.b64encode(digest).decode("ascii")
    if actual != b64:
        err(f"{PACKAGE}@{pin}: tarball integrity mismatch")
        fail_exit()


def safe_extract(tar: tarfile.TarFile, dest: Path) -> None:
    dest = dest.resolve()
    for member in tar.getmembers():
        target = (dest / member.name).resolve()
        if dest != target and dest not in target.parents:
            err(f"{PACKAGE}: tarball member escapes extract dir: {member.name}")
            fail_exit()
    kwargs = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
    tar.extractall(dest, **kwargs)


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
        root_doc = documented_root_exports(skill, error_codes_doc)
        example_keys = cashout_example_keys(skill)

        for name in sorted(root_doc):
            if name not in root_names:
                err(
                    f"{SKILL}: documented export {name!r} is not a root export of {PACKAGE}@{pin}"
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

        latest = (packument.get("dist-tags") or {}).get("latest")
        if errors:
            fail_exit()

        print(
            f"ok: {PACKAGE}@{pin}; {len(root_doc)} root exports; "
            f"{sdk_code_count} error codes; {sdk_step_count} steps; "
            f"{sdk_key_count} cashout keys"
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
