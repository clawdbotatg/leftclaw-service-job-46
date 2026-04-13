// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ClawdETHRewards
/// @notice Synthetix StakingRewards-style distributor. Stake clawdETH shares, earn CLAWD.
/// Only the configured rewardsNotifier (the Harvester) can start a new reward period.
contract ClawdETHRewards is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardsToken;

    address public rewardsNotifier;
    uint256 public rewardsDuration = 7 days;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;

    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardAdded(uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event NotifierUpdated(address indexed notifier);

    error NotNotifier();
    error ZeroAmount();
    error ZeroAddress();
    error RewardTooHigh();
    error CannotRecoverStake();

    constructor(IERC20 stakingToken_, IERC20 rewardsToken_, address owner_)
        Ownable(owner_)
    {
        if (
            address(stakingToken_) == address(0) || address(rewardsToken_) == address(0) || owner_ == address(0)
        ) revert ZeroAddress();
        stakingToken = stakingToken_;
        rewardsToken = rewardsToken_;
    }

    // -------- views ---------------------------------------------------------

    function totalSupply() external view returns (uint256) { return _totalSupply; }
    function balanceOf(address account) external view returns (uint256) { return _balances[account]; }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) return rewardPerTokenStored;
        return rewardPerTokenStored
            + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate * 1e18) / _totalSupply;
    }

    function earned(address account) public view returns (uint256) {
        return (_balances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18
            + rewards[account];
    }

    // -------- mutations -----------------------------------------------------

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        _totalSupply += amount;
        _balances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        _totalSupply -= amount;
        _balances[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function getReward() public nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function exit() external {
        withdraw(_balances[msg.sender]);
        getReward();
    }

    // -------- admin ---------------------------------------------------------

    function setRewardsNotifier(address notifier) external onlyOwner {
        if (notifier == address(0)) revert ZeroAddress();
        rewardsNotifier = notifier;
        emit NotifierUpdated(notifier);
    }

    function setRewardsDuration(uint256 duration) external onlyOwner {
        require(block.timestamp >= periodFinish, "period active");
        require(duration > 0, "zero duration");
        rewardsDuration = duration;
        emit RewardsDurationUpdated(duration);
    }

    /// @notice Called by the harvester after a buyback. Transfers CLAWD in + starts a new stream.
    function notifyRewardAmount(uint256 reward) external updateReward(address(0)) {
        if (msg.sender != rewardsNotifier) revert NotNotifier();
        rewardsToken.safeTransferFrom(msg.sender, address(this), reward);

        if (block.timestamp >= periodFinish) {
            rewardRate = reward / rewardsDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / rewardsDuration;
        }

        // Guard against rounding errors starving the distribution.
        uint256 balance = rewardsToken.balanceOf(address(this));
        if (rewardRate > balance / rewardsDuration) revert RewardTooHigh();

        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
        emit RewardAdded(reward);
    }

    /// @notice Rescue non-staking tokens accidentally sent to the contract.
    function recoverERC20(IERC20 token, uint256 amount) external onlyOwner {
        if (address(token) == address(stakingToken)) revert CannotRecoverStake();
        token.safeTransfer(owner(), amount);
    }
}
