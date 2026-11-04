#!/usr/bin/env bash
# Checks the skill against the pinned @zkp2p/cash package: exports, error codes, rails, floors.
# Reads only the npm registry. Signs nothing and creates nothing.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN="$(sed -nE 's/^npm install @zkp2p\/cash@([0-9]+\.[0-9]+\.[0-9]+) viem$/\1/p' "$ROOT/SKILL.md" | head -1)"
[ -n "$PIN" ] || { echo "SKILL.md: missing @zkp2p/cash pin"; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
printf '{"private":true,"type":"module"}\n' > package.json
npm install --silent --no-audit --no-fund "@zkp2p/cash@$PIN" viem
cat > verify.mjs <<'JS'
import { readFileSync, readdirSync } from "node:fs";
import { createCashClient, MIN_CASHOUT_AMOUNT, RECOMMENDED_MIN_CASHOUT_AMOUNT } from "@zkp2p/cash";

const skill = readFileSync(process.argv[2], "utf8");
const dist = "node_modules/@zkp2p/cash/dist";
const types = readdirSync(dist)
  .filter((name) => name.endsWith(".d.ts"))
  .map((name) => readFileSync(`${dist}/${name}`, "utf8"))
  .join("\n");
const errors = [];

const client = createCashClient({ environment: "production", referralCode: "TOFIAT" });
for (const verb of ["cashout", "estimate", "capabilities", "prepare", "finalizePreparedCashout", "prepareAccessPolicy", "order", "orders", "watch", "withdraw"]) {
  if (typeof client[verb] !== "function") errors.push(`client.${verb} is not a function`);
}

for (const name of ["usdc", "createCashClient", "MIN_CASHOUT_AMOUNT", "RECOMMENDED_MIN_CASHOUT_AMOUNT", "CashError"]) {
  if (!new RegExp(`\\b${name}\\b`).test(types)) errors.push(`${name} is not in the package types`);
}
if (MIN_CASHOUT_AMOUNT !== 10000n) errors.push(`MIN_CASHOUT_AMOUNT is ${MIN_CASHOUT_AMOUNT}`);
if (RECOMMENDED_MIN_CASHOUT_AMOUNT !== 1000000n) errors.push(`RECOMMENDED_MIN_CASHOUT_AMOUNT is ${RECOMMENDED_MIN_CASHOUT_AMOUNT}`);

const codes = types.match(/type CashErrorCode =([^;]+);/)?.[1] ?? "";
for (const [, code] of skill.matchAll(/^\| `([A-Z_]+)`\s+\|/gm)) {
  if (code.endsWith("_AMOUNT")) continue;
  if (!codes.includes(`'${code}'`)) errors.push(`error code ${code} is not in CashErrorCode`);
}

const states = types.match(/type CashOrderState =([^;]+);/)?.[1] ?? "";
for (const state of ["awaiting-buyer", "matched", "delivering", "delivered", "returned"]) {
  if (!states.includes(`'${state}'`)) errors.push(`order state ${state} is not in CashOrderState`);
}

const documented = [...skill.matchAll(/^\| [^|]+\| `([a-z]+)`\s+\| (?:yes|no)\s+\|/gm)].map((m) => m[1]).sort();
const offered = (await client.capabilities()).platforms.map((p) => p.platform ?? p.id).sort();
if (documented.join() !== offered.join()) {
  errors.push(`rail table ${documented} does not match capabilities() ${offered}`);
}

if (errors.length) {
  console.error(errors.join("\n"));
  process.exit(1);
}
console.log(`ok: @zkp2p/cash surface matches; ${offered.length} rails`);
JS
node verify.mjs "$ROOT/SKILL.md"
