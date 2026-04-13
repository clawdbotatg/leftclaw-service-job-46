//SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./DeployHelpers.s.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ClawdETHVault } from "../contracts/ClawdETHVault.sol";
import { ClawdETHRewards } from "../contracts/ClawdETHRewards.sol";
import { ClawdETHHarvester } from "../contracts/ClawdETHHarvester.sol";
import { IWstETHGateway, IClawdSwap } from "../contracts/interfaces/IExternal.sol";
import { MockWETH, MockERC20, MockWstETHGateway, MockClawdSwap } from "../contracts/mocks/Mocks.sol";

/// @notice Deploys clawdETH: vault + harvester + rewards distributor.
/// @dev Broadcasts with `vm.startBroadcast()` (no args) via ScaffoldEthDeployerRunner.
/// The build worker injects the deployer private key via `forge --private-key`.
/// Deployer owns contracts during wiring, then hands ownership to CLIENT via Ownable2Step
/// (CLIENT must call `acceptOwnership()` on each contract to finalize).
contract DeployScript is ScaffoldETHDeploy {
    address internal constant CLIENT = 0x34aA3F359A9D614239015126635CE7732c18fDF3;

    // Base mainnet addresses (used only when deploying to chainid 8453).
    address internal constant BASE_WETH = 0x4200000000000000000000000000000000000006;
    address internal constant BASE_CLAWD = 0xd61bcF0c51f2cD3477B206c89C80FecBF05565f1;

    uint256 internal constant DEFAULT_BURN_BPS = 5000; // 50/50 burn vs distribute

    function run() external ScaffoldEthDeployerRunner {
        (address weth, address clawd, IWstETHGateway gateway, IClawdSwap swapper) = _resolveDependencies();

        // 1. Deploy vault owned by deployer (so we can wire the harvester) — transfer later.
        ClawdETHVault vault = new ClawdETHVault(IERC20(weth), gateway, deployer);

        // 2. Deploy rewards owned by deployer for wiring.
        ClawdETHRewards rewards = new ClawdETHRewards(IERC20(address(vault)), IERC20(clawd), deployer);

        // 3. Deploy harvester. Keeper initially = CLIENT so only CLIENT can trigger harvests.
        //    Owner = CLIENT directly (no wiring needed from harvester side).
        ClawdETHHarvester harvester = new ClawdETHHarvester(
            vault, rewards, IERC20(weth), IERC20(clawd), swapper, CLIENT, DEFAULT_BURN_BPS, CLIENT
        );

        // 4. Wire — only the owner (deployer) can call these.
        vault.setHarvester(address(harvester));
        rewards.setRewardsNotifier(address(harvester));

        // 5. Hand ownership to CLIENT (2-step: CLIENT must `acceptOwnership()` to finalize).
        vault.transferOwnership(CLIENT);
        rewards.transferOwnership(CLIENT);

        deployments.push(Deployment("ClawdETHVault", address(vault)));
        deployments.push(Deployment("ClawdETHRewards", address(rewards)));
        deployments.push(Deployment("ClawdETHHarvester", address(harvester)));
    }

    function _resolveDependencies()
        internal
        returns (address weth, address clawd, IWstETHGateway gateway, IClawdSwap swapper)
    {
        if (block.chainid == 8453) {
            // Production: the real wstETH gateway + CLAWD swapper must be concrete Uniswap-backed
            // contracts. Keep this revert until those are implemented + audited.
            revert("Base: deploy real gateway + swapper first");
        }

        // Local / CI: stand up mocks so the whole system is usable end-to-end.
        MockWETH mweth = new MockWETH();
        MockERC20 mclawd = new MockERC20("CLAWD", "CLAWD");
        MockWstETHGateway mgate = new MockWstETHGateway(IERC20(address(mweth)));
        MockClawdSwap mswap = new MockClawdSwap(IERC20(address(mweth)), mclawd);

        // Seed the mock swapper + gateway with initial balances so local demos work out of the box.
        // (Harmless on local chains; this block only runs for non-Base deploys.)

        deployments.push(Deployment("MockWETH", address(mweth)));
        deployments.push(Deployment("CLAWD", address(mclawd)));
        deployments.push(Deployment("MockWstETHGateway", address(mgate)));
        deployments.push(Deployment("MockClawdSwap", address(mswap)));

        return (address(mweth), address(mclawd), IWstETHGateway(address(mgate)), IClawdSwap(address(mswap)));
    }
}
