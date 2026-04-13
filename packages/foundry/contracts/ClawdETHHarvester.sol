// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IClawdSwap } from "./interfaces/IExternal.sol";
import { ClawdETHVault } from "./ClawdETHVault.sol";
import { ClawdETHRewards } from "./ClawdETHRewards.sol";

/// @title ClawdETHHarvester
/// @notice Pulls yield out of the vault as WETH, swaps to CLAWD via an external router,
/// then splits the CLAWD: `burnBps` to the dead address, remainder streamed to stakers.
contract ClawdETHHarvester is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_BURN_BPS = 8000; // 80%
    uint256 public constant MIN_BURN_BPS = 2000; // 20%
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ClawdETHVault public immutable vault;
    ClawdETHRewards public immutable rewards;
    IERC20 public immutable weth;
    IERC20 public immutable clawd;

    IClawdSwap public swapper;
    address public keeper;
    uint256 public burnBps;
    uint256 public totalBurned;
    uint256 public totalDistributed;

    event Harvested(uint256 wethYield, uint256 clawdBought, uint256 burned, uint256 distributed);
    event BurnBpsUpdated(uint256 burnBps);
    event KeeperUpdated(address indexed keeper);
    event SwapperUpdated(address indexed swapper);

    error NotKeeper();
    error ZeroAddress();
    error InvalidBps();

    constructor(
        ClawdETHVault vault_,
        ClawdETHRewards rewards_,
        IERC20 weth_,
        IERC20 clawd_,
        IClawdSwap swapper_,
        address keeper_,
        uint256 burnBps_,
        address owner_
    ) Ownable(owner_) {
        if (
            address(vault_) == address(0) || address(rewards_) == address(0) || address(weth_) == address(0)
                || address(clawd_) == address(0) || address(swapper_) == address(0) || keeper_ == address(0)
                || owner_ == address(0)
        ) revert ZeroAddress();
        if (burnBps_ < MIN_BURN_BPS || burnBps_ > MAX_BURN_BPS) revert InvalidBps();
        vault = vault_;
        rewards = rewards_;
        weth = weth_;
        clawd = clawd_;
        swapper = swapper_;
        keeper = keeper_;
        burnBps = burnBps_;
    }

    // -------- admin ---------------------------------------------------------

    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert ZeroAddress();
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }

    function setSwapper(IClawdSwap newSwapper) external onlyOwner {
        if (address(newSwapper) == address(0)) revert ZeroAddress();
        swapper = newSwapper;
        emit SwapperUpdated(address(newSwapper));
    }

    function setBurnBps(uint256 newBps) external onlyOwner {
        if (newBps < MIN_BURN_BPS || newBps > MAX_BURN_BPS) revert InvalidBps();
        burnBps = newBps;
        emit BurnBpsUpdated(newBps);
    }

    // -------- harvest -------------------------------------------------------

    /// @notice Known issue: no token-rescue function exists on this contract. Any WETH or CLAWD stuck mid-harvest (e.g. partial swapper failure, stray transfer) would be permanently trapped. Acceptable because the harvester only holds tokens transiently within a single harvest transaction.
    /// @notice Known issue: no minimum yield enforced before harvesting. The keeper (CLIENT) can harvest dust amounts, wasting gas. Not exploitable by third parties since only the keeper can call this function.
    /// @notice Harvest yield and split the bought CLAWD. Keeper-only.
    /// @param minWethOut slippage guard on the wstETH->WETH unwrap inside the vault.
    /// @param minClawdOut slippage guard on the WETH->CLAWD swap. Keeper computes off-chain.
    function harvest(uint256 minWethOut, uint256 minClawdOut) external nonReentrant {
        if (msg.sender != keeper) revert NotKeeper();

        uint256 wethYield = vault.harvest(minWethOut);

        weth.forceApprove(address(swapper), wethYield);
        uint256 clawdOut = swapper.swapWETHForCLAWD(wethYield, minClawdOut);

        uint256 toBurn = (clawdOut * burnBps) / 10_000;
        uint256 toDistribute = clawdOut - toBurn;

        if (toBurn > 0) {
            clawd.safeTransfer(DEAD, toBurn);
            totalBurned += toBurn;
        }
        if (toDistribute > 0) {
            clawd.forceApprove(address(rewards), toDistribute);
            rewards.notifyRewardAmount(toDistribute);
            totalDistributed += toDistribute;
        }

        emit Harvested(wethYield, clawdOut, toBurn, toDistribute);
    }
}
