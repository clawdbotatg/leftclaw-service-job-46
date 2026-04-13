// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256) external;
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice Abstracts the WETH<->wstETH yield-bearing position.
/// Real deployment plugs a Lido-aware adapter (swap WETH<>wstETH on Uniswap on Base).
/// `previewDeposit` and `previewWithdraw` quote the WETH<->wstETH conversion at the spot rate.
interface IWstETHGateway {
    /// @notice Pulls `wethAmount` WETH from caller and returns wstETH to caller.
    function wrap(uint256 wethAmount) external returns (uint256 wstReceived);

    /// @notice Pulls `wstAmount` wstETH from caller, returns at least `minWethOut` WETH.
    function unwrap(uint256 wstAmount, uint256 minWethOut) external returns (uint256 wethReceived);

    /// @notice Quotes wstETH->WETH conversion at current rate (no slippage).
    function wstETHToWETH(uint256 wstAmount) external view returns (uint256 wethAmount);

    /// @notice Quotes WETH->wstETH conversion at current rate.
    function wethToWstETH(uint256 wethAmount) external view returns (uint256 wstAmount);

    function wstETH() external view returns (address);
}

/// @notice Minimal swap interface (WETH -> CLAWD). Matches Uniswap V3 SwapRouter02
/// `exactInputSingle` shape from the caller's perspective.
interface IClawdSwap {
    function swapWETHForCLAWD(uint256 wethAmount, uint256 minClawdOut) external returns (uint256 clawdReceived);
}
