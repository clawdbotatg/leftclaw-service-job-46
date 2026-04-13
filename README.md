# 🏗 Scaffold-ETH 2

<h4 align="center">
  <a href="https://docs.scaffoldeth.io">Documentation</a> |
  <a href="https://scaffoldeth.io">Website</a>
</h4>

🧪 An open-source, up-to-date toolkit for building decentralized applications (dapps) on the Ethereum blockchain. It's designed to make it easier for developers to create and deploy smart contracts and build user interfaces that interact with those contracts.

> [!NOTE]
> 🤖 Scaffold-ETH 2 is AI-ready! It has everything agents need to build on Ethereum. Check `.agents/`, `.claude/`, `.opencode` or `.cursor/` for more info.

⚙️ Built using NextJS, RainbowKit, Foundry, Wagmi, Viem, and Typescript.

- ✅ **Contract Hot Reload**: Your frontend auto-adapts to your smart contract as you edit it.
- 🪝 **[Custom hooks](https://docs.scaffoldeth.io/hooks/)**: Collection of React hooks wrapper around [wagmi](https://wagmi.sh/) to simplify interactions with smart contracts with typescript autocompletion.
- 🧱 [**Components**](https://docs.scaffoldeth.io/components/): Collection of common web3 components to quickly build your frontend.
- 🔥 **Burner Wallet & Local Faucet**: Quickly test your application with a burner wallet and local faucet.
- 🔐 **Integration with Wallet Providers**: Connect to different wallet providers and interact with the Ethereum network.

![Debug Contracts tab](https://github.com/scaffold-eth/scaffold-eth-2/assets/55535804/b237af0c-5027-4849-a5c1-2e31495cccb1)

## Requirements

Before you begin, you need to install the following tools:

- [Node (>= v20.18.3)](https://nodejs.org/en/download/)
- Yarn ([v1](https://classic.yarnpkg.com/en/docs/install/) or [v2+](https://yarnpkg.com/getting-started/install))
- [Git](https://git-scm.com/downloads)

## Quickstart

To get started with Scaffold-ETH 2, follow the steps below:

1. Install dependencies if it was skipped in CLI:

```
cd my-dapp-example
yarn install
```

2. Run a local network in the first terminal:

```
yarn chain
```

This command starts a local Ethereum network using Foundry. The network runs on your local machine and can be used for testing and development. You can customize the network configuration in `packages/foundry/foundry.toml`.

3. On a second terminal, deploy the test contract:

```
yarn deploy
```

This command deploys a test smart contract to the local network. The contract is located in `packages/foundry/contracts` and can be modified to suit your needs. The `yarn deploy` command uses the deploy script located in `packages/foundry/script` to deploy the contract to the network. You can also customize the deploy script.

4. On a third terminal, start your NextJS app:

```
yarn start
```

Visit your app on: `http://localhost:3000`. You can interact with your smart contract using the `Debug Contracts` page. You can tweak the app config in `packages/nextjs/scaffold.config.ts`.

Run smart contract test with `yarn foundry:test`

- Edit your smart contracts in `packages/foundry/contracts`
- Edit your frontend homepage at `packages/nextjs/app/page.tsx`. For guidance on [routing](https://nextjs.org/docs/app/building-your-application/routing/defining-routes) and configuring [pages/layouts](https://nextjs.org/docs/app/building-your-application/routing/pages-and-layouts) checkout the Next.js documentation.
- Edit your deployment scripts in `packages/foundry/script`


## Documentation

Visit our [docs](https://docs.scaffoldeth.io) to learn how to start building with Scaffold-ETH 2.

To know more about its features, check out our [website](https://scaffoldeth.io).

## Known Issues

The following items are accepted as-is and will not be fixed in the current release. See `AUDIT_REPORT.md` for full context.

- **[LOW]** `ClawdETHRewards.recoverERC20` can sweep the rewards token (CLAWD), draining accrued-but-unclaimed rewards. Acceptable given the owner (CLIENT) is trusted (standard Synthetix pattern).
- **[LOW]** `ClawdETHHarvester` has no token-rescue function. Tokens stuck mid-harvest are permanently trapped. Acceptable because the harvester only holds tokens transiently within a single transaction.
- **[LOW]** `ClawdETHVault.setGateway` can migrate the gateway without moving the wstETH position. If the new gateway cannot honor the existing wstETH, funds could be bricked. Owner-only via Ownable2Step (centralization risk accepted).
- **[LOW]** `notifyRewardAmount` rate math can extend a stream with rounding dust (standard Synthetix pattern; rate is re-leveled against actual balance so dust never exceeds funding).
- **[LOW]** `ClawdETHRewards.setRewardsDuration` does not call `updateReward` internally. Safe because the function is guarded by `periodFinish <= block.timestamp`.
- **[LOW]** Harvester does not enforce a minimum yield before harvesting. Keeper (CLIENT) can harvest dust amounts, wasting gas. Not exploitable by third parties.
- **[INFO]** `ClawdETHVault.receive()` is open to any ETH sender. Stray ETH has no recovery path. Low blast radius.
- **[INFO]** `DeployScript` assigns Harvester ownership directly in the constructor rather than via a two-step transfer. Asymmetric with Vault + Rewards which require `acceptOwnership()`. CLIENT must call `acceptOwnership()` on Vault and Rewards post-deploy.
- **[INFO]** Privileged-role handoff is script-correct but must be completed on-chain. CLIENT must call `acceptOwnership()` on `ClawdETHVault` and `ClawdETHRewards` after deployment.
- **[INFO]** `DEFAULT_ALCHEMY_API_KEY` in `scaffold.config.ts` is the shared SE-2 fallback key. Override via `NEXT_PUBLIC_ALCHEMY_API_KEY` in production.
- **[INFO]** `DEFAULT_WALLET_CONNECT_PROJECT_ID` in `scaffold.config.ts` is the shared SE-2 fallback. Override via `NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID` in production.
- **[LOW]** Frontend action buttons disable on `!address` rather than rotating through a Connect → Switch Network → Action flow. No "switch network" CTA exists if the user is on the wrong chain.
- **[LOW]** Double-approval race in Stake panel: Approve button is only disabled while the tx is pending, not during the confirmation window.
- **[LOW]** No USD conversion shown alongside ETH/clawdETH input amounts.
- **[LOW]** Raw `<input type="number">` is used instead of the SE-2 `EtherInput` component.
- **[INFO]** `<html>` tag in `layout.tsx` has no explicit `lang` attribute (minor a11y nit).
- **[INFO]** Base mainnet deploy path intentionally reverts until real gateway/swapper contracts are implemented and audited.

## Contributing to Scaffold-ETH 2

We welcome contributions to Scaffold-ETH 2!

Please see [CONTRIBUTING.MD](https://github.com/scaffold-eth/scaffold-eth-2/blob/main/CONTRIBUTING.md) for more information and guidelines for contributing to Scaffold-ETH 2.