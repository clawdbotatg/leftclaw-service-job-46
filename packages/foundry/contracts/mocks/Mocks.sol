// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IWETH, IWstETHGateway, IClawdSwap } from "../interfaces/IExternal.sol";

/// @dev Test-only mocks. NOT deployed to production.

contract MockWETH is ERC20, IWETH {
    constructor() ERC20("Wrapped Ether", "WETH") { }

    function deposit() external payable override {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external override {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{ value: amount }("");
        require(ok, "ETH send failed");
    }

    function transfer(address to, uint256 amount) public override(ERC20, IWETH) returns (bool) {
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override(ERC20, IWETH) returns (bool) {
        return super.transferFrom(from, to, amount);
    }

    function approve(address spender, uint256 amount) public override(ERC20, IWETH) returns (bool) {
        return super.approve(spender, amount);
    }

    function balanceOf(address a) public view override(ERC20, IWETH) returns (uint256) {
        return super.balanceOf(a);
    }
}

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock WETH<->wstETH gateway. Maintains a pricePerShare-like rate to simulate yield:
/// wstETH->WETH = amount * rateBps / 10000. Tests bump `rateBps` to fabricate yield.
contract MockWstETHGateway is IWstETHGateway {
    using SafeERC20 for IERC20;

    IERC20 public immutable weth;
    MockERC20 public immutable wst;
    uint256 public rateBps = 10_000; // 1.0 WETH per wstETH initially

    constructor(IERC20 weth_) {
        weth = weth_;
        wst = new MockERC20("Mock wstETH", "wstETH");
    }

    function setRateBps(uint256 b) external {
        rateBps = b;
    }

    function wstETH() external view override returns (address) {
        return address(wst);
    }

    function wethToWstETH(uint256 w) public view override returns (uint256) {
        return (w * 10_000) / rateBps;
    }

    function wstETHToWETH(uint256 s) public view override returns (uint256) {
        return (s * rateBps) / 10_000;
    }

    function wrap(uint256 wethAmount) external override returns (uint256 wstReceived) {
        weth.safeTransferFrom(msg.sender, address(this), wethAmount);
        wstReceived = wethToWstETH(wethAmount);
        wst.mint(msg.sender, wstReceived);
    }

    function unwrap(uint256 wstAmount, uint256 minWethOut) external override returns (uint256 wethReceived) {
        IERC20(address(wst)).safeTransferFrom(msg.sender, address(this), wstAmount);
        // Burn the escrowed wst by moving it to dead; avoids needing burn on MockERC20.
        IERC20(address(wst)).safeTransfer(address(0xdead), wstAmount);
        wethReceived = wstETHToWETH(wstAmount);
        require(wethReceived >= minWethOut, "slippage");
        // Mint WETH to cover — pretend the swap pool gave us WETH.
        // For the test gateway, we fund ourselves from held WETH + wst->weth magic.
        uint256 bal = weth.balanceOf(address(this));
        if (bal < wethReceived) {
            // Pull from a pre-funded buffer via MockWETH deposit (msg.value 0 would fail).
            // Expectation: tests pre-fund the gateway with extra WETH to cover yield payouts.
            revert("gateway under-funded");
        }
        weth.safeTransfer(msg.sender, wethReceived);
    }
}

/// @notice Mock swapper: WETH -> CLAWD at a fixed rate set by tests.
contract MockClawdSwap is IClawdSwap {
    using SafeERC20 for IERC20;

    IERC20 public immutable weth;
    MockERC20 public immutable clawd;
    uint256 public clawdPerWeth = 1000 * 1e18; // 1 WETH = 1000 CLAWD by default

    constructor(IERC20 weth_, MockERC20 clawd_) {
        weth = weth_;
        clawd = clawd_;
    }

    function setRate(uint256 r) external {
        clawdPerWeth = r;
    }

    function swapWETHForCLAWD(uint256 wethAmount, uint256 minClawdOut)
        external
        override
        returns (uint256 clawdReceived)
    {
        weth.safeTransferFrom(msg.sender, address(this), wethAmount);
        clawdReceived = (wethAmount * clawdPerWeth) / 1e18;
        require(clawdReceived >= minClawdOut, "slippage");
        clawd.mint(msg.sender, clawdReceived);
    }
}
