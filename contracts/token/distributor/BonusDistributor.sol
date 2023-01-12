// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import {IERC20} from "../../interfaces/IERC20.sol";
import {Governable} from "../../libraries/Governable.sol";
import {IBonusDistributor} from "../../interfaces/IBonusDistributor.sol";
import {IRewardTracker} from "../../interfaces/IRewardTracker.sol";

contract BonusDistributor is IBonusDistributor, Governable {
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant BONUS_DURATION = 365 days;

    uint256 public bonusMultiplierBasisPoints;

    address public override rewardToken;
    uint256 public lastDistributionTime;
    address public rewardTracker;

    mapping(address => bool) public isHandler;

    event Distribute(uint256 amount);
    event BonusMultiplierChange(uint256 amount);

    constructor(address _rewardToken, address _rewardTracker) {
        rewardToken = _rewardToken;
        rewardTracker = _rewardTracker;
        isHandler[msg.sender] = true;
    }

    modifier onlyHandler() {
        _onlyHandler();
        _;
    }
    
    function _onlyHandler() internal view {
        require(isHandler[msg.sender], "BonusDistributor: not handler");
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function setHandlers(address[] memory _handler, bool[] memory _isActive) external onlyGov {
        for(uint256 i = 0; i < _handler.length; i++){
            isHandler[_handler[i]] = _isActive[i];
        }
    }

    function updateLastDistributionTime() external onlyHandler {
        lastDistributionTime = block.timestamp;
    }

    function setBonusMultiplier(uint256 _bonusMultiplierBasisPoints) external onlyHandler {
        require(lastDistributionTime != 0, "BonusDistributor: invalid lastDistributionTime");
        IRewardTracker(rewardTracker).updateRewards();
        bonusMultiplierBasisPoints = _bonusMultiplierBasisPoints;
        emit BonusMultiplierChange(_bonusMultiplierBasisPoints);
    }

    function tokensPerInterval() public view returns (uint256) {
        uint256 supply = IERC20(rewardTracker).totalSupply();
        return supply * bonusMultiplierBasisPoints / BASIS_POINTS_DIVISOR / BONUS_DURATION;
    }

    function pendingRewards() public view override returns (uint256) {
        if (block.timestamp == lastDistributionTime) {
            return 0;
        }

        uint256 supply = IERC20(rewardTracker).totalSupply();
        uint256 timeDiff = block.timestamp - lastDistributionTime;

        return timeDiff * supply * bonusMultiplierBasisPoints / BASIS_POINTS_DIVISOR / BONUS_DURATION;
    }

    function distribute() external override returns (uint256) {
        require(msg.sender == rewardTracker, "BonusDistributor: invalid msg.sender");
        uint256 amount = pendingRewards();
        if (amount == 0) { return 0; }

        lastDistributionTime = block.timestamp;

        uint256 balance = IERC20(rewardToken).balanceOf(address(this));

        if (amount > balance) { amount = balance; }

        IERC20(rewardToken).transfer(msg.sender, amount);

        emit Distribute(amount);

        return amount;
    }
}
