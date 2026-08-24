#!/usr/bin/env bash
# Required check: installable SKILL.md copies must match, YAML must parse, installers stay pinned.
# Stdlib Python only; no network.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import re
import sys
from pathlib import Path

errors: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


ROOT = Path(".")
ROOT_SKILL = ROOT / "SKILL.md"
NESTED_SKILL = ROOT / "skills/cashout/SKILL.md"
README = ROOT / "README.md"
PIN_RE = re.compile(r"^npm install @usdctofiat/offramp@(\d+\.\d+\.\d+)$", re.M)
UNPINNED_SDK_RE = re.compile(r"^npm install @usdctofiat/offramp\s*$", re.M)
SKILLS_PIN_RE = re.compile(r"skills@(\d+\.\d+\.\d+)")
UNPINNED_NPX_RE = re.compile(r"\bnpx skills\b")


def load(path: Path) -> str:
    if not path.is_file():
        err(f"{path}: missing")
        return ""
    return path.read_text(encoding="utf-8")


def parse_quoted(raw: str, path: str, key: str) -> str | None:
    if len(raw) < 2:
        err(f"{path}: {key} must be a quoted YAML scalar")
        return None
    quote = raw[0]
    if quote not in "'\"" or raw[-1] != quote:
        err(f"{path}: {key} must be a quoted YAML scalar")
        return None
    inner = raw[1:-1]
    if quote == "'":
        if "'" in inner.replace("''", ""):
            err(f"{path}: {key} has an unescaped single quote")
            return None
        return inner.replace("''", "'")
    out: list[str] = []
    i = 0
    while i < len(inner):
        ch = inner[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        if i + 1 >= len(inner):
            err(f"{path}: {key} has a dangling escape")
            return None
        nxt = inner[i + 1]
        escapes = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}
        if nxt not in escapes:
            err(f"{path}: {key} has an unsupported escape \\{nxt}")
            return None
        out.append(escapes[nxt])
        i += 2
    return "".join(out)


def parse_frontmatter(path: Path, text: str) -> dict[str, str]:
    if not text.startswith("---\n"):
        err(f"{path}: missing YAML frontmatter")
        return {}
    end = text.find("\n---\n", 4)
    if end < 0:
        err(f"{path}: unterminated YAML frontmatter")
        return {}
    data: dict[str, str] = {}
    for i, line in enumerate(text[4:end].splitlines(), start=1):
        if not line.strip():
            continue
        match = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if not match:
            err(f"{path}: invalid frontmatter line {i}: {line!r}")
            continue
        key, raw = match.group(1), match.group(2).strip()
        if key == "description":
            value = parse_quoted(raw, str(path), key)
            if value is None:
                continue
            if len(value) > 1024:
                err(f"{path}: description is {len(value)} chars (limit 1024)")
            data[key] = value
            continue
        if raw.startswith(("'", '"')):
            value = parse_quoted(raw, str(path), key)
            if value is None:
                continue
            data[key] = value
            continue
        if re.search(r"[:{}[\]]", raw):
            err(
                f"{path}: {key} is unquoted YAML and contains flow-mapping characters"
            )
            continue
        data[key] = raw
    return data


def sdk_pin(path: Path, text: str) -> str | None:
    pins = PIN_RE.findall(text)
    if UNPINNED_SDK_RE.search(text):
        err(f"{path}: unpinned npm install @usdctofiat/offramp")
    if not pins:
        err(f"{path}: missing pinned npm install @usdctofiat/offramp@<version>")
        return None
    unique = set(pins)
    if len(unique) != 1:
        err(f"{path}: conflicting SDK pins {sorted(unique)}")
        return None
    return next(iter(unique))


root_text = load(ROOT_SKILL)
nested_text = load(NESTED_SKILL)
readme_text = load(README)

if root_text and nested_text and root_text != nested_text:
    err("SKILL.md and skills/cashout/SKILL.md must be identical")

if nested_text:
    fm = parse_frontmatter(NESTED_SKILL, nested_text)
    name = fm.get("name")
    if name != "cashout":
        err(f"{NESTED_SKILL}: name {name!r} must be 'cashout'")
    if not fm.get("description"):
        err(f"{NESTED_SKILL}: missing description")

if root_text:
    parse_frontmatter(ROOT_SKILL, root_text)

skill_pin = sdk_pin(NESTED_SKILL, nested_text) if nested_text else None
if root_text:
    sdk_pin(ROOT_SKILL, root_text)

if readme_text:
    if UNPINNED_NPX_RE.search(readme_text):
        err("README.md: unpinned npx skills installer")
    if not SKILLS_PIN_RE.search(readme_text):
        err("README.md: missing pinned skills@<version>")
    readme_pin = sdk_pin(README, readme_text)
    if skill_pin and readme_pin and skill_pin != readme_pin:
        err(
            f"README.md SDK pin @{readme_pin} does not match SKILL.md pin @{skill_pin}"
        )

if errors:
    print("\n".join(errors))
    print(f"{len(errors)} problem(s)")
    sys.exit(1)

print(
    f"ok: SKILL.md copies identical; SDK pin @usdctofiat/offramp@{skill_pin}; "
    "YAML frontmatter quoted; README installer pinned"
)
PY
