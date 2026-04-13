# Audit Report — Cycle 1

## MUST FIX

- [x] **[HIGH]** Withdraw reverts due to rounding once yield accrues — `packages/foundry/contracts/ClawdETHVault.sol:124-127` — `_withdraw` computes `wstNeeded = gateway.wethToWstETH(assets)` (integer-divides down), then calls `gateway.unwrap(wstNeeded, assets)` and requires `wethOut >= assets`. Whenever the wstETH/WETH rate is > 1.0 (i.e. any accrued yield — the entire point of the product), `wethToWstETH` rounds the wstETH quote down, the unwrap returns strictly less than `assets`, and the `"slippage"` require reverts. Result: **users cannot withdraw any principal after the first tick of yield**, silently bricking the vault's core UX. Fix by either (a) bumping `wstNeeded` by 1 wei / a small rounding buffer, (b) redeeming a shares-proportional slice of `wstETH` and accepting whatever WETH comes out, or (c) having the vault request an explicit "unwrap to at-least `assets` WETH" primitive. No existing test exercises withdraw with a non-unit rate, which is why this regression slipped through — add that test alongside the fix.

- [x] **[HIGH]** No test coverage for withdraw-after-yield path — `packages/foundry/test/ClawdETH.t.sol` — every withdraw test runs at `rateBps = 10_000` (no yield). The one scenario users will actually hit in production — withdraw while the wstETH position is appreciating — is completely untested. Combined with the rounding bug above, critical path is unverified. Add a `testWithdrawAfterYield` that calls `gateway.setRateBps(11_000)` before withdrawing.

## KNOWN ISSUES

- **[LOW]** `ClawdETHRewards.recoverERC20` can drain reward token — `packages/foundry/contracts/ClawdETHRewards.sol:154-157` — owner (CLIENT) can sweep any token that isn't the staking token, including the rewards token (CLAWD). This lets the owner rug accrued-but-unclaimed rewards. Standard Synthetix pattern, acceptable given CLIENT is trusted, but note: a stricter implementation would also block `rewardsToken` or subtract unclaimed earnings.

- **[LOW]** `ClawdETHHarvester` has no token-rescue function — `packages/foundry/contracts/ClawdETHHarvester.sol` — any WETH or CLAWD stuck mid-harvest (e.g. swapper partial-failure, stray transfer) is permanently trapped. Acceptable because the harvester only holds tokens transiently inside the single `harvest` tx.

- **[LOW]** `ClawdETHVault.setGateway` can migrate gateway without moving the wstETH position — `ClawdETHVault.sol:58-63` — only checks `wstETH()` match; if the new gateway can't honor the previously-wrapped wstETH, funds could be bricked. Owner-only (CLIENT) via Ownable2Step, so trust-gated, but note as centralization risk.

- **[LOW]** `notifyRewardAmount` rate math can extend an existing stream with rounding dust — `ClawdETHRewards.sol:132-151` — standard Synthetix pattern; rate is re-leveled based on the contract's current balance so dust never exceeds funding. Acceptable.

- **[LOW]** `ClawdETHRewards` does not call `updateReward` inside `setRewardsDuration` — `ClawdETHRewards.sol:124-129` — it's guarded by `periodFinish <= block.timestamp` so the only state it affects is the *next* period's rate, which is fine.

- **[LOW]** Harvester does not enforce a minimum yield to harvest — `ClawdETHHarvester.sol:93` — keeper can grief-ish themselves by harvesting dust, wasting gas. Keeper-only (CLIENT), so not exploitable by third parties.

- **[INFO]** Vault `receive()` is open — `ClawdETHVault.sol:162-164` — accepts any ETH sender; stray ETH gets stuck (no recover). Low blast radius since no flow relies on ETH balance.

- **[INFO]** `DeployScript` uses `Ownable(owner_)` directly on the Harvester constructor rather than a two-step transfer — `packages/foundry/script/Deploy.s.sol:39-41` — CLIENT becomes owner immediately without needing to `acceptOwnership()`. Not a bug (constructor is the one safe place to hand ownership directly), but asymmetric with the Vault/Rewards flow which *does* require `acceptOwnership()`. CLIENT must remember to call `acceptOwnership()` on Vault + Rewards or roles stay with the deployer.

- **[INFO]** Privileged-role handoff is script-correct but unverified on-chain — `packages/foundry/script/Deploy.s.sol` — no `packages/foundry/deployments/` directory exists, so no live deployment to verify. Deploy script sets Harvester owner/keeper = CLIENT (`0x34aA3F359A9D614239015126635CE7732c18fDF3`) and initiates Ownable2Step transfer of Vault + Rewards to CLIENT. CLIENT must `acceptOwnership()` on Vault and Rewards post-deploy to finalize.

- **[INFO]** `DEFAULT_ALCHEMY_API_KEY` is hardcoded in `scaffold.config.ts:16` as a fallback — this is the shared SE-2 default key, not a project secret. Should still be overridden via `NEXT_PUBLIC_ALCHEMY_API_KEY` in production env.

- **[INFO]** `DEFAULT_WALLET_CONNECT_PROJECT_ID` hardcoded fallback — `scaffold.config.ts:40` — shared SE-2 default; override via env in production.

- **[LOW]** Frontend four-state button flow not implemented — `packages/nextjs/app/page.tsx` — Deposit / Withdraw / Stake / Claim action buttons just disable when `!address` instead of rotating through `Connect Wallet → Switch Network → Approve → Action`. There's no "switch network" CTA at all if the user is on the wrong chain. Header has a connect button, so basic connectivity isn't broken, but per the QA skill's "big obvious button" rule this is sub-par.

- **[LOW]** Double-approval race not guarded — `packages/nextjs/app/page.tsx:315-334` — Stake panel uses only `isPending` (aka `approving`) to disable the Approve button. There's no `approveCooldown` covering the window between tx-hash-returned and tx-confirmed, so a double-click during that gap can fire a second approval. QA skill explicitly calls this out.

- **[LOW]** No USD conversion shown on input amounts — `packages/nextjs/app/page.tsx` (Deposit / Withdraw / Stake panels) — ETH and clawdETH amounts are shown without their `~$X` equivalent. QA skill flags this. Acceptable to ship but a UX polish.

- **[LOW]** Raw `<input type="number">` used instead of `EtherInput` — `packages/nextjs/app/page.tsx:206-214,265-273,364-372` — loses the ETH/USD toggle and doesn't match the SE-2 component vocabulary the QA skill expects. Functional; cosmetic.

- **[INFO]** `<html>` tag has no explicit `lang` — `packages/nextjs/app/layout.tsx:15` — minor a11y nit.

- **[INFO]** Production deploy path intentionally reverts until real gateway/swapper ship — `packages/foundry/script/Deploy.s.sol:60-64` — by design; flagged so reviewers know the Base mainnet path is not wired yet.

- **[INFO]** `.env` is present at repo root but gitignored — not inspected for secrets per handling rules; ensure no secrets leak into committed files.

## Summary
- Must Fix: 2 items
- Known Issues: 16 items
- Audit frameworks followed: contract audit (ethskills), QA audit (ethskills)
