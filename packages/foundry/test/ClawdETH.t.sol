// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ClawdETHVault } from "../contracts/ClawdETHVault.sol";
import { ClawdETHRewards } from "../contracts/ClawdETHRewards.sol";
import { ClawdETHHarvester } from "../contracts/ClawdETHHarvester.sol";
import { IWstETHGateway, IClawdSwap } from "../contracts/interfaces/IExternal.sol";
import { MockWETH, MockERC20, MockWstETHGateway, MockClawdSwap } from "../contracts/mocks/Mocks.sol";

contract ClawdETHTest is Test {
    address internal owner = address(0xABCD);
    address internal keeper = address(0xBEEF);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    MockWETH internal weth;
    MockERC20 internal clawd;
    MockWstETHGateway internal gateway;
    MockClawdSwap internal swapper;

    ClawdETHVault internal vault;
    ClawdETHRewards internal rewards;
    ClawdETHHarvester internal harvester;

    function setUp() public {
        weth = new MockWETH();
        clawd = new MockERC20("CLAWD", "CLAWD");
        gateway = new MockWstETHGateway(IERC20(address(weth)));
        swapper = new MockClawdSwap(IERC20(address(weth)), clawd);

        vault = new ClawdETHVault(IERC20(address(weth)), IWstETHGateway(address(gateway)), owner);
        rewards = new ClawdETHRewards(IERC20(address(vault)), IERC20(address(clawd)), owner);
        harvester = new ClawdETHHarvester(
            vault, rewards, IERC20(address(weth)), IERC20(address(clawd)), IClawdSwap(address(swapper)), keeper, 5000, owner
        );

        vm.startPrank(owner);
        vault.setHarvester(address(harvester));
        rewards.setRewardsNotifier(address(harvester));
        vm.stopPrank();

        // Fund users.
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ------------------------------------------------------------------------
    // Deposits
    // ------------------------------------------------------------------------

    function testDepositETHMintsSharesOneToOne() public {
        vm.prank(alice);
        uint256 shares = vault.depositETH{ value: 10 ether }(alice);
        // 1:1 price in asset terms after accounting for the 1e6 virtual-shares offset.
        assertEq(vault.convertToAssets(shares), 10 ether);
        assertEq(vault.totalAssets(), 10 ether);
        assertEq(vault.principal(), 10 ether);
    }

    function testDepositWETH() public {
        vm.startPrank(alice);
        weth.deposit{ value: 5 ether }();
        weth.approve(address(vault), 5 ether);
        uint256 shares = vault.deposit(5 ether, alice);
        vm.stopPrank();

        assertEq(vault.convertToAssets(shares), 5 ether);
    }

    function testSharePricePinnedToPrincipalOnYield() public {
        vm.prank(alice);
        uint256 shares = vault.depositETH{ value: 10 ether }(alice);
        uint256 preYield = vault.convertToAssets(shares);

        // Simulate 10% wstETH appreciation — yield is NOT reflected in share price.
        gateway.setRateBps(11_000);

        assertEq(vault.convertToAssets(shares), preYield, "share price pinned");
        assertEq(vault.totalAssets(), 10 ether);
    }

    function testWithdraw() public {
        vm.prank(alice);
        vault.depositETH{ value: 10 ether }(alice);

        vm.prank(alice);
        vault.withdraw(4 ether, alice, alice);
        assertEq(weth.balanceOf(alice), 4 ether);
        assertEq(vault.principal(), 6 ether);
    }

    function testWithdrawAllDrainsPosition() public {
        vm.prank(alice);
        vault.depositETH{ value: 3 ether }(alice);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.totalAssets(), 0);
    }

    function testDepositRevertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(bytes("zero deposit"));
        vault.depositETH{ value: 0 }(alice);
    }

    // ------------------------------------------------------------------------
    // Harvest
    // ------------------------------------------------------------------------

    function _fundGatewayWithYield(uint256 extraWeth) internal {
        // Give gateway extra WETH so unwrap() at a higher rate can pay out.
        vm.deal(address(this), extraWeth);
        weth.deposit{ value: extraWeth }();
        weth.transfer(address(gateway), extraWeth);
    }

    function testHarvestFlow() public {
        // Alice deposits 10 ETH.
        vm.prank(alice);
        vault.depositETH{ value: 10 ether }(alice);

        // 10% appreciation -> 1 ETH yield. Pre-fund gateway to honor the unwrap.
        gateway.setRateBps(11_000);
        _fundGatewayWithYield(1 ether);

        assertEq(vault.pendingYield(), 1 ether);

        // Keeper harvests. 1 WETH -> 1000 CLAWD. 50% burn, 50% distribute.
        vm.prank(keeper);
        harvester.harvest(1 ether, 900 ether);

        assertEq(clawd.balanceOf(harvester.DEAD()), 500 ether, "burned CLAWD");
        assertEq(clawd.balanceOf(address(rewards)), 500 ether, "distributed CLAWD");
        assertEq(harvester.totalBurned(), 500 ether);
        assertEq(harvester.totalDistributed(), 500 ether);
    }

    function testHarvestOnlyKeeper() public {
        vm.prank(alice);
        vault.depositETH{ value: 10 ether }(alice);
        gateway.setRateBps(11_000);
        _fundGatewayWithYield(1 ether);

        vm.prank(alice);
        vm.expectRevert(ClawdETHHarvester.NotKeeper.selector);
        harvester.harvest(1 ether, 0);
    }

    function testVaultHarvestOnlyByHarvester() public {
        vm.prank(alice);
        vault.depositETH{ value: 10 ether }(alice);
        gateway.setRateBps(11_000);
        _fundGatewayWithYield(1 ether);

        vm.prank(alice);
        vm.expectRevert(ClawdETHVault.NotHarvester.selector);
        vault.harvest(0);
    }

    function testHarvestRevertsWithNoYield() public {
        vm.prank(alice);
        vault.depositETH{ value: 10 ether }(alice);
        vm.prank(keeper);
        vm.expectRevert(ClawdETHVault.NoYield.selector);
        harvester.harvest(0, 0);
    }

    // ------------------------------------------------------------------------
    // Rewards staking
    // ------------------------------------------------------------------------

    function testStakeAndEarnAfterHarvest() public {
        // Alice deposits & stakes shares.
        vm.startPrank(alice);
        vault.depositETH{ value: 10 ether }(alice);
        vault.approve(address(rewards), 10 ether);
        rewards.stake(10 ether);
        vm.stopPrank();

        // Generate yield + harvest.
        gateway.setRateBps(11_000);
        _fundGatewayWithYield(1 ether);
        vm.prank(keeper);
        harvester.harvest(1 ether, 0);

        // Fast forward to end of reward period.
        vm.warp(block.timestamp + 7 days + 1);
        uint256 earnedBefore = rewards.earned(alice);
        assertGt(earnedBefore, 0, "alice earned something");

        vm.prank(alice);
        rewards.getReward();
        assertApproxEqAbs(clawd.balanceOf(alice), 500 ether, 1e15, "alice got ~500 CLAWD");
    }

    function testNotifyRewardOnlyByHarvester() public {
        vm.prank(alice);
        vm.expectRevert(ClawdETHRewards.NotNotifier.selector);
        rewards.notifyRewardAmount(1 ether);
    }

    // ------------------------------------------------------------------------
    // Access control
    // ------------------------------------------------------------------------

    function testBurnBpsBoundsEnforced() public {
        vm.prank(owner);
        vm.expectRevert(ClawdETHHarvester.InvalidBps.selector);
        harvester.setBurnBps(9000);

        vm.prank(owner);
        vm.expectRevert(ClawdETHHarvester.InvalidBps.selector);
        harvester.setBurnBps(1000);

        vm.prank(owner);
        harvester.setBurnBps(4000);
        assertEq(harvester.burnBps(), 4000);
    }

    function testOwnable2StepTransfer() public {
        address newOwner = address(0xC0FFEE);
        vm.prank(owner);
        vault.transferOwnership(newOwner);
        // pending, not yet owner
        assertEq(vault.owner(), owner);
        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
    }
}
