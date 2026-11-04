# USDCtoFiat agent skills

Installable Agent Skills for [USDCtoFiat](https://usdctofiat.xyz), using Peer's [`@zkp2p/cash`](https://www.npmjs.com/package/@zkp2p/cash) with referral code `TOFIAT`.

![USDCtoFiat](https://usdctofiat.xyz/og-image-galleon.png)

```bash
npm exec --package=skills@1.5.23 -- skills add ADWilkinson/usdctofiat-skills
# or a single skill
npm exec --package=skills@1.5.23 -- skills add ADWilkinson/usdctofiat-skills --skill cashout
npm install @zkp2p/cash@0.7.3 viem
```

The skill covers the Fast route. For Best, where Delegate manages the rate, use https://usdctofiat.xyz/sell?speed=best.

`@usdctofiat/offramp` is deprecated. Earlier versions of this skill taught it; move to `@zkp2p/cash` with `referralCode: "TOFIAT"`.

- App: https://usdctofiat.xyz
- Docs: https://usdctofiat.xyz/usdc-to-fiat/
- skills.sh: https://www.skills.sh/adwilkinson/usdctofiat-skills/cashout
- cursor.directory: https://cursor.directory/plugins/usdctofiat
- Cash-out skill: https://github.com/ADWilkinson/usdctofiat-skills/tree/main/skills/cashout
