// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import {IERC20} from "../interfaces/IERC20.sol";

import {IRewardTracker} from "../interfaces/IRewardTracker.sol";
import {IVester} from "../interfaces/IVester.sol";

contract Reader {
    function getDepositBalances(
        address _account,
        address[] memory _depositTokens,
        address[] memory _rewardTrackers
    ) public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](_rewardTrackers.length);

        for (uint256 i = 0; i < _rewardTrackers.length; i++) {
            IRewardTracker rewardTracker = IRewardTracker(_rewardTrackers[i]);
            amounts[i] = rewardTracker.depositBalances(_account, _depositTokens[i]);
        }
        return amounts;
    }

    function getStakingInfo(address _account, address[] memory _rewardTrackers) public view returns (uint256[] memory) {
        uint256 propsLength = 5;

        uint256[] memory amounts = new uint256[](_rewardTrackers.length * propsLength);
        for (uint256 i = 0; i < _rewardTrackers.length; i++) {
            IRewardTracker rewardTracker = IRewardTracker(_rewardTrackers[i]);
            amounts[i * propsLength] = rewardTracker.claimable(_account);
            amounts[i * propsLength + 1] = rewardTracker.tokensPerInterval();
            amounts[i * propsLength + 2] = rewardTracker.averageStakedAmounts(_account);
            amounts[i * propsLength + 3] = rewardTracker.cumulativeRewards(_account);
            amounts[i * propsLength + 4] = IERC20(_rewardTrackers[i]).totalSupply();
        }
        return amounts;
    }

    function getVestingInfo(address _account, address[] memory _vesters) public view returns (uint256[] memory) {
        uint256 propsLength = 12;
        uint256[] memory amounts = new uint256[](_vesters.length * propsLength);

        for (uint256 i = 0; i < _vesters.length; i++) {
            IVester vester = IVester(_vesters[i]);
            IRewardTracker rewardTracker = IRewardTracker(vester.rewardTracker());
            amounts[i * propsLength] = vester.pairAmounts(_account);
            amounts[i * propsLength + 1] = vester.getVestedAmount(_account);
            amounts[i * propsLength + 2] = IERC20(_vesters[i]).balanceOf(_account);
            amounts[i * propsLength + 3] = vester.claimedAmounts(_account);
            amounts[i * propsLength + 4] = vester.claimable(_account);
            amounts[i * propsLength + 5] = vester.getMaxVestableAmount(_account);
            amounts[i * propsLength + 6] = vester.getCombinedAverageStakedAmount(_account);
            amounts[i * propsLength + 7] = rewardTracker.cumulativeRewards(_account);
            amounts[i * propsLength + 8] = vester.transferredCumulativeRewards(_account);
            amounts[i * propsLength + 9] = vester.bonusRewards(_account);
            amounts[i * propsLength + 10] = rewardTracker.averageStakedAmounts(_account);
            amounts[i * propsLength + 11] = vester.transferredAverageStakedAmounts(_account);
        }

        return amounts;
    }

    function getTokenBalancesWithSupplies(
        address _account,
        address[] memory _tokens
    ) public view returns (uint256[] memory) {
        uint256 propsLength = 2;
        uint256[] memory balances = new uint256[](_tokens.length * propsLength);

        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                balances[i * propsLength] = _account.balance;
                balances[i * propsLength + 1] = 0;
                continue;
            }
            balances[i * propsLength] = IERC20(token).balanceOf(_account);
            balances[i * propsLength + 1] = IERC20(token).totalSupply();
        }

        return balances;
    }

    function getTokenSupply(IERC20 _token, address[] memory _excludedAccounts) public view returns (uint256) {
        uint256 supply = _token.totalSupply();
        for (uint256 i = 0; i < _excludedAccounts.length; i++) {
            address account = _excludedAccounts[i];
            uint256 balance = _token.balanceOf(account);
            supply = supply - balance;
        }
        return supply;
    }
}
