// SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

interface IBonusDistributor {
    function rewardToken() external view returns (address);

    function tokensPerInterval() external view returns (uint256);

    function pendingRewards() external view returns (uint256);

    function distribute() external returns (uint256);
}
