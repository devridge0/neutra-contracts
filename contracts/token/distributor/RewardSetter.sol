// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import {Governable} from "../../libraries/Governable.sol";

import {IERC20} from "../../interfaces/IERC20.sol";
import {IRewardDistributor} from "../../interfaces/IRewardDistributor.sol";
import {IRewardTracker} from "../../interfaces/IRewardTracker.sol";

contract RewardSetter is Governable {
    address public distributionToken;
    address public rewardDistributor;

    uint256 public distributionPeriod = 1 weeks;

    event DistributeAndSet(address distributionToken, uint256 distributionAmount, uint256 tokensPerInterval);

    constructor(
        address _distributionToken,
        address _rewardDistributor
    ){
        distributionToken = _distributionToken;
        rewardDistributor = _rewardDistributor;
    }

    function setDistributeToken (address _distributionToken) public onlyGov {
        require(_distributionToken != address(0), "RewardSetter: Token address can not be zero");

        distributionToken = _distributionToken;
    }

    function setDistributionPeriod (uint256 _distributionPeriod) public onlyGov {
        require(uint256(_distributionPeriod) != uint256(0), "RewardSetter: Distribution period can not be zero");

        distributionPeriod = _distributionPeriod;
    }

    function setRewardDistributor (address _rewardDistributor) public onlyGov {
        require(_rewardDistributor != address(0), "RewardSetter: Reward distributor address can not be zero");

        rewardDistributor = _rewardDistributor;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) public onlyGov {
        IERC20(_token).transfer(_account, _amount);
    }

    function distributeAndSet(uint256 amount) public onlyGov {
        uint256 distributeAmount;

        if(IERC20(distributionToken).balanceOf(address(rewardDistributor)) < IRewardDistributor(rewardDistributor).pendingRewards()){
            distributeAmount = amount;
        }else{
            distributeAmount = IERC20(distributionToken).balanceOf(address(rewardDistributor)) - IRewardDistributor(rewardDistributor).pendingRewards() + amount;
        }

        uint256 tokensPerInterval = amount / distributionPeriod;

        IRewardDistributor(rewardDistributor).setTokensPerInterval(tokensPerInterval);

        IERC20(distributionToken).transferFrom(msg.sender, address(this), amount);

        IERC20(distributionToken).transfer(address(rewardDistributor), amount);
        
        emit DistributeAndSet(distributionToken, amount, tokensPerInterval);
    }
}