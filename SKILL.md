---
name: cashout
description: 'Sell Base USDC for fiat with one call: cashout({ mode: "fast" | "best" }) from @usdctofiat/offramp. Use when a user wants a non-custodial cash-out from a real Base wallet into Venmo, Cash App, Revolut, PayPal, Zelle, Monzo or Chime. Fast is 0% spread; Best is Delegate pricing at 10 bps. Require an explicit mode.'
---

# USDCtoFiat cash-out

Use `@usdctofiat/offramp` to call `cashout({ mode: "fast" | "best" })` with a real viem `WalletClient` on Base (`chain_id: 8453`). Require the user to choose a mode.

> **Payment-policy boundary:** SDK support proves technical compatibility, not permission from a payment provider. Wise currently prohibits receiving P2P crypto-sale payments. PayPal may require preapproval for cryptocurrency-related payments. Read the provider's current first-party policy before offering a route.

## Fast or Best

| Mode   | Fee                                 | Pricing                    |
| ------ | ----------------------------------- | -------------------------- |
| `fast` | 0% spread / 0 bps                   | Live oracle route (TOFIAT) |
| `best` | Delegate manager fee 10 bps on USDC | Delegate rate-manager path |

```ts
import { cashout } from "@usdctofiat/offramp";
import type { WalletClient } from "viem";

export async function sellUsdc(signer: WalletClient) {
  return cashout({
    mode: "fast",
    signer,
    amount: "100",
    currency: "EUR",
    platform: "revolut",
    payee: "alice",
  });
}
```

```ts
const fast = await cashout({ ...input, mode: "fast" });
const best = await cashout({ ...input, mode: "best" });
```

Strings and numbers are human USDC amounts. A `bigint` is exact six-decimal base units. The helper is production-only and requires an explicit mode.

Persist `depositId` immediately. Fast `depositId` is the composite resume key for `createOfframp().watch()`. Best `depositId` is the numeric EscrowV2 id for `deposits()` / `close()`.

## createOfframp()

Attribution is configured by `@usdctofiat/offramp`.

```ts
import { createOfframp } from "@usdctofiat/offramp";

export async function watchCashout(depositId: string) {
  const client = createOfframp();
  for await (const order of client.watch(depositId)) {
    if (!order.isInFlight) return order;
  }
}
```

## Install

```bash
npm install @usdctofiat/offramp
```

```ts
import { OFFRAMP_DEVELOPER_RESOURCES, getOfframpDeveloperResources } from "@usdctofiat/offramp";

OFFRAMP_DEVELOPER_RESOURCES.delegation.required; // false
OFFRAMP_DEVELOPER_RESOURCES.delegation.feeRateBps; // 10
```

## Errors

Managed-path errors extend `OfframpError` with a typed `code`:

| Code                              | Meaning                                  | Recovery                                                       |
| --------------------------------- | ---------------------------------------- | -------------------------------------------------------------- |
| `VALIDATION`                      | Bad input                                | Fix the input                                                  |
| `APPROVAL_FAILED`                 | USDC approve reverted or wallet rejected | Retry or top up gas                                            |
| `REGISTRATION_FAILED`             | Curator rejected the maker               | Surface the `cause`                                            |
| `EXTENSION_REGISTRATION_REQUIRED` | Route needs an extension handshake       | `usePeerExtensionRegistration(platform)` or `peerExtensionSdk` |
| `DEPOSIT_FAILED`                  | Escrow create reverted                   | Check USDC balance, nonce, chain                               |
| `CONFIRMATION_FAILED`             | Post-deposit confirmation missed         | Call `cashout()` again; it resumes                             |
| `DELEGATION_FAILED`               | `setRateManager` failed                  | Call again; Best resumes from delegation                       |
| `USER_CANCELLED`                  | Wallet rejected a prompt                 | Do not retry automatically                                     |
| `UNSUPPORTED`                     | Non-Base chain or missing client         | Switch network / pass a Base `WalletClient`                    |

Progress callback via `onProgress: (p) => void` with `step` values: `approving`, `registering`, `depositing`, `confirming`, `delegating`, `restricting`, `resuming`, `done`.

## Rules

- Call `cashout({ mode: "fast" | "best" })` on a real Base wallet and require an explicit mode.
- Never log `walletClient` or private keys.
- Do not invent a sandbox. Production Base only.
- Read platform identifier rules from `PLATFORMS`; do not copy a stale list.
- Do not offer Wise while its published P2P crypto-sale prohibition applies.
- Pass `otcTaker` only when the order should be restricted to one buyer.
