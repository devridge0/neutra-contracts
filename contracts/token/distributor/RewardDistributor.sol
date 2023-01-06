// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import {IERC20} from "../../interfaces/IERC20.sol";
import {Governable} from "../../libraries/Governable.sol";
import {IRewardDistributor} from "../../interfaces/IRewardDistributor.sol";
import {IRewardTracker} from "../../interfaces/IRewardTracker.sol";

contract RewardDistributor is IRewardDistributor, Governable {
    address public rewardToken;
    uint256 public tokensPerInterval;
    uint256 public lastDistributionTime;
    address public rewardTracker;

    address public admin;

    event Distribute(uint256 amount);
    event TokensPerIntervalChange(uint256 amount);

    constructor(address _rewardToken, address _rewardTracker) {
        rewardToken = _rewardToken;
        rewardTracker = _rewardTracker;
    }

    function updateLastDistributionTime() external onlyGov {
        lastDistributionTime = block.timestamp;
    }

    function setTokensPerInterval(uint256 _amount) external onlyGov {
        require(lastDistributionTime != 0, "RewardDistributor: invalid lastDistributionTime");
        IRewardTracker(rewardTracker).updateRewards();
        tokensPerInterval = _amount;
        emit TokensPerIntervalChange(_amount);
    }

    function pendingRewards() public view returns (uint256) {
        if (block.timestamp == lastDistributionTime) {
            return 0;
        }

        uint256 timeDiff = block.timestamp - lastDistributionTime;
        return tokensPerInterval * timeDiff;
    }

    function distribute() external returns (uint256) {
        require(msg.sender == rewardTracker, "RewardDistributor: invalid msg.sender");
        uint256 amount = pendingRewards();
        if (amount == 0) {
            return 0;
        }
        IERC20(rewardToken).transfer(msg.sender, amount);
        emit Distribute(amount);
        return amount;
    }
}
