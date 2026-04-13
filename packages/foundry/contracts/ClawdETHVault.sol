// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC4626, IERC20, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import { IWETH, IWstETHGateway } from "./interfaces/IExternal.sol";

/// @title ClawdETHVault
/// @notice ERC4626 vault denominated in WETH. User deposits are wrapped into a wstETH position
/// through an external gateway. Share price is intentionally pinned to 1:1 with principal WETH;
/// stETH yield is *not* compounded into shares — it is periodically released to the harvester,
/// swapped to CLAWD and distributed (see ClawdETHHarvester + ClawdETHRewards).
contract ClawdETHVault is ERC4626, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IWstETHGateway public gateway;
    IERC20 public immutable wstETH;
    address public harvester;

    /// @notice Principal in WETH terms. Equals sum of deposits minus sum of withdrawals.
    /// `totalAssets()` returns this value so share price stays pegged at 1 WETH / share.
    uint256 public principal;

    event Deposited(address indexed user, address indexed receiver, uint256 ethAmount, uint256 sharesReceived);
    event Withdrawn(address indexed owner, address indexed receiver, uint256 sharesRedeemed, uint256 ethReturned);
    event YieldHarvested(uint256 wstETHAmount, uint256 ethYield);
    event HarvesterUpdated(address indexed harvester);
    event GatewayUpdated(address indexed gateway);

    error NotHarvester();
    error ZeroAddress();
    error NoYield();

    constructor(
        IERC20 weth,
        IWstETHGateway gateway_,
        address owner_
    ) ERC20("clawdETH", "clawdETH") ERC4626(weth) Ownable(owner_) {
        if (address(gateway_) == address(0) || address(weth) == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        gateway = gateway_;
        wstETH = IERC20(gateway_.wstETH());
    }

    // -------- admin ---------------------------------------------------------

    function setHarvester(address newHarvester) external onlyOwner {
        if (newHarvester == address(0)) revert ZeroAddress();
        harvester = newHarvester;
        emit HarvesterUpdated(newHarvester);
    }

    /// @notice Known issue: setGateway migrates the gateway address but does not move the existing wstETH position. If the new gateway cannot honor the previously-wrapped wstETH, user funds could be bricked. Owner-only via Ownable2Step (centralization risk accepted).
    function setGateway(IWstETHGateway newGateway) external onlyOwner {
        if (address(newGateway) == address(0)) revert ZeroAddress();
        require(address(newGateway.wstETH()) == address(wstETH), "wstETH mismatch");
        gateway = newGateway;
        emit GatewayUpdated(address(newGateway));
    }

    // -------- deposits ------------------------------------------------------

    /// @notice Deposit ETH directly; wrapped to WETH then funneled through standard ERC4626 flow.
    function depositETH(address receiver) external payable nonReentrant returns (uint256 shares) {
        require(msg.value > 0, "zero deposit");
        IWETH(asset()).deposit{ value: msg.value }();

        shares = previewDeposit(msg.value);
        _depositAlreadyFunded(msg.sender, receiver, msg.value, shares);
    }

    /// @dev Shared path for ETH deposits — vault already holds the WETH, so we skip the transferFrom.
    function _depositAlreadyFunded(address caller, address receiver, uint256 assets, uint256 shares) internal {
        principal += assets;
        IERC20(asset()).forceApprove(address(gateway), assets);
        gateway.wrap(assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
        emit Deposited(caller, receiver, assets, shares);
    }

    // -------- ERC4626 overrides --------------------------------------------

    /// @dev Share price is pegged to WETH principal — yield leaves the vault via `harvest`.
    function totalAssets() public view override returns (uint256) {
        return principal;
    }

    /// @dev Virtual-shares decimals offset for first-depositor / inflation attack resistance.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        SafeERC20.safeTransferFrom(IERC20(asset()), caller, address(this), assets);
        principal += assets;
        IERC20(asset()).forceApprove(address(gateway), assets);
        gateway.wrap(assets);
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets, shares);
        emit Deposited(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        if (caller != owner_) {
            _spendAllowance(owner_, caller, shares);
        }
        _burn(owner_, shares);
        principal -= assets;

        // Compute wstETH needed to cover `assets` WETH. wethToWstETH truncates (rounds down),
        // so if the rounded-down quote underdelivers, bump by 1 wei of wstETH. Without this bump
        // the unwrap reverts on the minWethOut check whenever the rate exceeds 1.0 (i.e. any yield).
        uint256 wstNeeded = gateway.wethToWstETH(assets);
        if (gateway.wstETHToWETH(wstNeeded) < assets) wstNeeded += 1;
        IERC20(wstETH).forceApprove(address(gateway), wstNeeded);
        uint256 wethOut = gateway.unwrap(wstNeeded, assets);
        require(wethOut >= assets, "slippage");

        SafeERC20.safeTransfer(IERC20(asset()), receiver, assets);
        emit Withdraw(caller, receiver, owner_, assets, shares);
        emit Withdrawn(owner_, receiver, shares, assets);
    }

    // -------- harvest -------------------------------------------------------

    /// @notice Returns how much WETH worth of yield has accrued above principal.
    function pendingYield() public view returns (uint256) {
        uint256 positionValue = gateway.wstETHToWETH(wstETH.balanceOf(address(this)));
        if (positionValue <= principal) return 0;
        return positionValue - principal;
    }

    /// @notice Pulls accrued yield out as WETH and forwards to the harvester.
    /// Only the configured harvester may call this.
    /// @dev Unwraps exactly the wstETH *above* what's needed to back `principal`, which dodges
    /// the round-trip rounding problem of converting yield WETH -> wstETH -> WETH.
    function harvest(uint256 minWethOut) external nonReentrant returns (uint256 wethYield) {
        if (msg.sender != harvester) revert NotHarvester();

        uint256 wstBalance = wstETH.balanceOf(address(this));
        uint256 wstForPrincipal = gateway.wethToWstETH(principal);
        if (wstBalance <= wstForPrincipal) revert NoYield();
        uint256 wstYield = wstBalance - wstForPrincipal;

        IERC20(wstETH).forceApprove(address(gateway), wstYield);
        wethYield = gateway.unwrap(wstYield, minWethOut);

        SafeERC20.safeTransfer(IERC20(asset()), harvester, wethYield);
        emit YieldHarvested(wstYield, wethYield);
    }

    /// @notice Known issue: receive() is open to any ETH sender. Stray ETH sent here has no recovery path and will be permanently stuck. Low blast radius — no protocol flow depends on the ETH balance.
    receive() external payable {
        // Only accept ETH from WETH unwraps (none currently expected, but keep open for gateway flex).
    }
}
