# Build Plan — Job #46

## Client
0x34aA3F359A9D614239015126635CE7732c18fDF3

## Spec
// --- build-plan.md ---
# Build Plan: clawdETH — ETH Liquid Staking with CLAWD Yield Redirection

## Overview
clawdETH is an ERC4626 vault on Base where users deposit ETH or stETH/wstETH. Deposits are wrapped into wstETH (Lido) under the hood. Yield from the stETH position is periodically harvested, swapped to CLAWD via Uniswap, then split between burning and distribution to clawdETH holders. This gives conservative users ETH-denominated CLAWD exposure while creating persistent buy pressure and deflation for the CLAWD token.

## Smart Contracts

### 1. ClawdETHVault (ERC4626)
Core vault contract. Accounting denominated in WETH.

**Deposits:**
- `deposit(uint256 assets, address receiver)` — accepts WETH, wraps to wstETH via Lido's wstETH contract
- `depositETH(address receiver)` — payable, wraps ETH → WETH → wstETH
- `depositStETH(uint256 amount, address receiver)` — accepts stETH, wraps to wstETH
- `depositWstETH(uint256 amount, address receiver)` — accepts wstETH directly (no wrap needed)
- All paths normalize to wstETH internally. Share price tracks 1:1 with deposited ETH value (yield is redirected, not compounded into share price)

**Withdrawals:**
- `withdraw` / `redeem` — standard ERC4626. Unwraps wstETH → stETH → user receives stETH (or WETH via swap, configurable)
- Consider a withdrawal queue if Lido unstaking delays apply on Base (if using bridged wstETH, this is just a swap back)

**Key Storage:**
```solidity
IERC20 public immutable wstETH;
IERC20 public immutable stETH;  
IERC20 public immutable WETH;
IERC20 public immutable CLAWD;
address public rewardsDistributor;
address public harvester; // permissioned or keeper
uint256 public burnBps;   // e.g., 5000 = 50% burned
uint256 public totalWstETHDeposited; // tracks principal vs yield
```

**Accounting Note:**
wstETH is a non-rebasing wrapper — its value in stETH grows over time. The yield = `currentWstETHValue - depositedETHValue`. The vault tracks deposited principal in ETH-equivalent terms. On harvest, the delta (yield accrued) is unwrapped and sent to the harvester/swap module.

**Events:**
```solidity
event Deposited(address indexed user, uint256 ethAmount, uint256 sharesReceived);
event Withdrawn(address indexed user, uint256 sharesRedeemed, uint256 ethReturned);
event YieldHarvested(uint256 wstETHAmount, uint256 ethYield);
event CLAWDBurned(uint256 amount);
event CLAWDDistributed(uint256 amount);
```

### 2. ClawdETHHarvester
Separates yield harvesting + swap logic from vault. This is the module that touches Uniswap.

**Core Flow:**
1. `harvest()` — callable by keeper or permissioned address
   - Calls vault to release accrued yield (wstETH delta above principal)
   - Unwraps wstETH → WETH (via wstETH.unwrap → stETH, then swap stETH→WETH, or if bridged wstETH on Base, swap wstETH→WETH directly on Uniswap)
   - Swaps WETH → CLAWD via Uniswap V3 pool (0xCD55...FAc3) using SwapRouter02
   - Splits CLAWD: `burnBps` to burn address (address(0xdead) or CLAWD.burn() if available), remainder to RewardsDistributor

**Swap Protection:**
- `maxSlippageBps` parameter (e.g., 300 = 3%)
- TWAP oracle check against the V3 pool: read `observe()` for 30-min TWAP, reject if spot deviates >5% from TWAP (anti-sandwich)
- `minCLAWDOut` calculated off-chain by keeper and passed as param for additional safety
- Harvest frequency: design for weekly or when yield exceeds a threshold (e.g., 0.1 ETH) to ensure swap size is meaningful relative to pool depth

**Access Control:**
- Ownable2Step for admin functions (update burn ratio, slippage params)
- Harvester role: either a whitelisted keeper address or Chainlink Automation

### 3. ClawdETHRewards (Synthetix StakingRewards pattern)
Distributes CLAWD rewards to clawdETH holders proportionally.

**Design:** Fork of Synthetix `StakingRewards` — battle-tested, simple, gas-efficient.
- Staking token = clawdETH (vault shares)
- Reward token = CLAWD
- Users stake their clawdETH into this contract to earn CLAWD rewards
- Alternative: make clawdETH vault itself track rewards (saves users a separate staking tx), but adds complexity to the vault. Recommend separate contract for V1 simplicity.

**Key Functions:**
- `stake(uint256 amount)` — deposit clawdETH shares
- `withdraw(uint256 amount)` — withdraw clawdETH shares  
- `getReward()` — claim accrued CLAWD
- `notifyRewardAmount(uint256 reward)` — called by Harvester after swap, starts new reward period

**Storage:**
```solidity
uint256 public rewardRate;
uint256 public periodFinish;
uint256 public rewardPerTokenStored;
mapping(address => uint256) public userRewardPerTokenPaid;
mapping(address => uint256) public rewards;
```

## Frontend

### Pages

**Landing / Dashboard:**
- Total TVL in vault (ETH terms)
- Current APY estimate (stETH yield → CLAWD terms, show both ETH-equivalent and CLAWD amount)
- Total CLAWD burned to date (counter, fetched from events)
- Total CLAWD distributed to date
- User position: clawdETH balance, staked amount, claimable CLAWD rewards

**Deposit Page:**
- Four input modes: ETH, WETH, stETH, wstETH — tab selector
- Amount input with MAX button
- Preview: "You deposit X ETH → receive Y clawdETH"
- Approval flow for ERC20 inputs (WETH/stETH/wstETH): Approve → Deposit → Done
- ETH mode: single tx (no approve needed)

**Withdraw Page:**
- Input clawdETH amount to redeem
- Preview: "You redeem X clawdETH → receive Y stETH/WETH"
- If staked in RewardsDistributor: unstake first, then redeem (or combine in a router contract)

**Rewards Page:**
- Claimable CLAWD amount
- Claim button
- Historical rewards (from events via The Graph)

**Analytics:**
- Harvest history: each harvest tx showing yield captured, CLAWD bought, amount burned, amount distributed
- CLAWD burn chart over time
- Pool depth indicator for CLAWD/WETH (read from Uniswap pool)

### Wallet Flow
- RainbowKit connect → detect chain (must be Base) → auto-prompt chain switch if wrong
- Mobile: WalletConnect deep link support via SE2 defaults

## Integrations

**Lido (wstETH on Base):**
- wstETH is bridged to Base. Users can hold wstETH on Base already.
- For ETH/WETH deposits: swap WETH → wstETH via Uniswap on Base (there are wstETH/WETH pools on Base) rather than bridging to mainnet for native Lido staking. This keeps everything on Base in a single tx.
- For stETH deposits: wrap stETH → wstETH if on mainnet, or swap on Base if bridged stETH exists. Recommend accepting only wstETH + WETH + ETH on Base for V1 simplicity. stETH acceptance can come in V2.

**Uniswap V3 (CLAWD buybacks):**
- Use the V3 pool at 0xCD55381a53da35Ab1D7Bc5e3fE5F76cac976FAc3
- SwapRouter02 on Base: exactInputSingle for WETH → CLAWD
- Pool TWAP via pool.observe() for manipulation resistance

**Uniswap V3 (wstETH/WETH swap for deposits):**
- Existing wstETH/WETH pool on Base for deposit wrapping
- Same SwapRouter02, exactInputSingle

**Chainlink (optional but recommended):**
- ETH/USD price feed on Base for displaying USD values
- Chainlink Automation for triggering harvest() on schedule (weekly) or threshold

**The Graph:**
- Subgraph indexing: Deposited, Withdrawn, YieldHarvested, CLAWDBurned, CLAWDDistributed events
- Powers analytics dashboard and historical rewards view

**Pendle Finance (future integration path):**
- clawdETH could be listed as a yield-bearing asset on Pendle
- Users could split clawdETH into PT (principal) + YT (yield = future CLAWD rewards)
- This is a V2 consideration — requires Pendle team coordination and their factory listing process
- Architecture note: keeping clawdETH as a standard ERC4626 vault makes Pendle integration straightforward since Pendle natively supports ERC4626

## Security Notes

**Vault Inflation Attack:**
- ERC4626 virtual shares: deploy with dead shares (deposit a small amount at construction) or use OpenZeppelin's ERC4626 which includes virtual offset. Critical for first-depositor attack prevention.

**Yield Accounting Manipulation:**
- wstETH exchange rate is controlled by Lido — trusted external dependency. Monitor for wstETH depeg scenarios.
- Never use spot pool price for yield calculation. Use wstETH.stEthPerToken() from Lido's contract for canonical exchange rate.

**Harvest Sandwich Protection:**
- TWAP check (30-min window) before executing swap. Revert if spot price deviates >5% from TWAP.
- Keeper passes `minAmountOut` calculated off-chain as additional guardrail.
- Consider private mempools (Flashbots Protect on Base) for harvest transactions.

**Access Control:**
- Vault: Ownable2Step. Owner can update harvester address, burn ratio (with bounds — e.g., 20-80% burn). Cannot touch user deposits.
- Harvester: only whitelisted address can call harvest(). Owner can update swap params.
- RewardsDistributor: only Harvester can call notifyRewardAmount().
- **Walkaway Test:** If team disappears, users can always withdraw their wstETH. Rewards stop distributing but no funds are locked. Harvest just stops — no loss of principal. Passes the test.

**Reentrancy:**
- ReentrancyGuard on all vault deposit/withdraw functions and harvest.
- CEI pattern throughout.

**wstETH Bridge Risk:**
- wstETH on Base is a bridged asset. Bridge security is an external dependency. Document this risk clearly for users.

**Decimal Handling:**
- WETH: 18 decimals. wstETH: 18 decimals. CLAWD: verify decimals() from contract, never hardcode.

## Recommended Stack
- **Framework:** Scaffold-ETH 2 (Next.js + wagmi + viem + RainbowKit)
- **Contracts:** Solidity 0.8.24+ with Foundry (forge test with Base mainnet fork for integration tests against real wstETH/Uniswap state)
- **Chain:** Base
- **Key Dependencies:** OpenZeppelin ERC4626, OpenZeppelin Ownable2Step, OpenZeppelin ReentrancyGuard, Synthetix StakingRewards (fork/adapt)
- **External Protocols:** Lido wstETH (Base), Uniswap V3 SwapRouter02 (Base), Chainlink Automation (Base)
- **Indexing:** The Graph subgraph for event history
- **Hosting:** BGIPFS for static frontend, Vercel if API routes needed for APY calculations
- **RPC:** Alchemy (Base)
- **Testing:** Foundry fork tests against Base mainnet (real wstETH rates, real Uniswap pool liquidity). Fuzz tests on deposit/withdraw/harvest edge cases.

See consultation plan for full scope and requirements.

## Deploy
- Chain: Base (8453)
- RPC: Alchemy (ALCHEMY_API_KEY in .env)
- Deployer: 0x7a8b288AB00F5b469D45A82D4e08198F6Eec651C (DEPLOYER_PRIVATE_KEY in .env)
- All owner/admin/treasury roles transfer to client: 0x34aA3F359A9D614239015126635CE7732c18fDF3
