// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import {Governable} from "./libraries/Governable.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IRewardTracker} from "./interfaces/IRewardTracker.sol";
import {IRouter} from "./interfaces/IRouter.sol";

contract BatchRouter is Governable {
    bool public executed;

    address public want;
    address public nGlp;
    address public fnGlp;
    address public router;
    address public esNeu;
    
    uint256 constant PRECISION = 1e30;
    uint256 public executionFee = 0.0001 ether;
    uint256 public depositLimit; // want decimals

    uint256 public currentDepositRound = 1;
    uint256 public currentWithdrawRound = 1;

    uint256 public cumulativeWantReward;
    uint256 public cumulativeEsNeuReward;

    uint256 public cumulativeWantRewardPerToken;
    uint256 public cumulativeEsNeuRewardPerToken;

    uint256 public totalSnGlpReceivedAmount;
    uint256 public totalWantReceivedAmount;

    mapping (address => uint256) public wantBalances;
    mapping (address => uint256) public snGlpBalances;
    mapping (uint256 => uint256) public totalWantPerRound;
    mapping (uint256 => uint256) public totalSnGlpPerRound;
    mapping (uint256 => uint256) public totalWantReceivedPerRound;
    mapping (uint256 => uint256) public totalSnGlpReceivedPerRound;

    mapping (uint256 => uint256) public cumulativeEsNeuRewardPerRound;
    mapping (uint256 => uint256) public cumulativeWantRewardPerRound;

    mapping (address => uint256) public depositRound;
    mapping (address => uint256) public withdrawRound;

    address public feeNeuGlpTracker;
    address public stakedNeuGlpTracker;

    event UpdateDepositLimit(uint256 depositLimit);

    constructor(address _want, address _nGlp, address _esNeu) {
        want =_want;
        nGlp = _nGlp;
        esNeu = _esNeu;
    }

    function approveToken(address _token, address _spender) external onlyGov {
        IERC20(_token).approve(_spender, type(uint256).max);
    } 

    function reserveDeposit(uint256 _amount) external {
        require(!executed, "batchRouter: batch under execution");
        if (wantBalances[msg.sender] > 0) {
            _claimStakedNeuGlp();
        }

        IERC20(want).transferFrom(msg.sender, address(this), _amount);
        totalWantPerRound[currentDepositRound] += _amount;
        require(totalWantPerRound[currentDepositRound] <= depositLimit, "BatchRouter: exceeded deposit limit");
        wantBalances[msg.sender] += _amount;

        if (depositRound[msg.sender] == 0) {
            depositRound[msg.sender] = currentDepositRound;
        }
    }

    function reserveWithdraw(uint256 _amount) external {
        require(!executed, "batchRouter: batch under execution");
        if (snGlpBalances[msg.sender] > 0) {
            _claimWant();
        }

        IRewardTracker(stakedNeuGlpTracker).unstakeForAccount(msg.sender, feeNeuGlpTracker, _amount, msg.sender);
        IRewardTracker(feeNeuGlpTracker).unstakeForAccount(msg.sender, nGlp, _amount, address(this));

        totalSnGlpPerRound[currentWithdrawRound] += _amount;
        snGlpBalances[msg.sender] += _amount;
        
        if (withdrawRound[msg.sender] == 0) {
            withdrawRound[msg.sender] = currentWithdrawRound;
        }
    }

    function cancelDeposit(uint256 _amount) external {
        require(!executed, "batchRouter: batch under execution");
        require(currentDepositRound == depositRound[msg.sender], "BatchRouter : batch already exectued");
        wantBalances[msg.sender] -= _amount;
        totalWantPerRound[currentDepositRound] -= _amount;
        IERC20(want).transfer(msg.sender, _amount);
        if (wantBalances[msg.sender] == 0) {
            depositRound[msg.sender] = 0;
        }
    }

    function cancelWithdraw(uint256 _amount) external {
        require(!executed, "batchRouter: batch under execution");
        require(currentWithdrawRound == withdrawRound[msg.sender], "BatchRouter : batch already exectued");
        snGlpBalances[msg.sender] -= _amount;
        totalSnGlpPerRound[currentWithdrawRound] -= _amount;

        IRewardTracker(feeNeuGlpTracker).stakeForAccount(address(this), msg.sender, nGlp, _amount);
        IRewardTracker(stakedNeuGlpTracker).stakeForAccount(msg.sender, msg.sender, feeNeuGlpTracker, _amount);
        
        if (snGlpBalances[msg.sender] == 0) {
            withdrawRound[msg.sender] = 0;
        }
    }

    function claimWant() external {
        _claimWant();
    }

    function claimStakedNeuGlp() external {
        _claimStakedNeuGlp();
    }

    function claim() external {
        _claimWant();
        _claimStakedNeuGlp();
    }

    function _claimWant() internal {
        uint256 round = withdrawRound[msg.sender];
        uint256 balance = snGlpBalances[msg.sender];
        if (balance == 0) {
            return;
        }
        uint256 totalBalance = totalSnGlpPerRound[round];
        uint256 totalReceived = totalWantReceivedPerRound[round];

        uint256 claimAmount = totalReceived * balance / totalBalance;

        if (claimAmount == 0) {
            return;
        }

        IERC20(want).transfer(msg.sender, claimAmount);

        totalSnGlpPerRound[round] -= balance;
        totalWantReceivedPerRound[round] -= claimAmount;
        totalWantReceivedAmount -= claimAmount;

        snGlpBalances[msg.sender] = 0;
        withdrawRound[msg.sender] = 0;
    }

    function _claimStakedNeuGlp() internal {
        uint256 round = depositRound[msg.sender];

        uint256 balance = wantBalances[msg.sender];
        if (balance == 0) {
            return;
        }

        uint256 claimAmount = totalSnGlpReceivedPerRound[round] * balance / totalWantPerRound[round];
        if (claimAmount == 0) {
            return;
        }

        _updateRewards();

        uint256 esNeuClaimable = claimAmount * (cumulativeEsNeuRewardPerToken - cumulativeEsNeuRewardPerRound[round]) / PRECISION;
        uint256 wantClaimable = claimAmount * (cumulativeWantRewardPerToken - cumulativeWantRewardPerRound[round]) / PRECISION;

        IERC20(esNeu).transfer(msg.sender, esNeuClaimable);
        IERC20(want).transfer(msg.sender, wantClaimable);

        IRewardTracker(stakedNeuGlpTracker).unstakeForAccount(address(this), feeNeuGlpTracker, claimAmount, address(this));
        IRewardTracker(feeNeuGlpTracker).unstakeForAccount(address(this), nGlp, claimAmount, address(this));

        IRewardTracker(feeNeuGlpTracker).stakeForAccount(address(this), msg.sender, nGlp, claimAmount);
        IRewardTracker(stakedNeuGlpTracker).stakeForAccount(msg.sender, msg.sender, feeNeuGlpTracker, claimAmount);

        totalSnGlpReceivedAmount -= claimAmount;
        totalSnGlpReceivedPerRound[round] -= claimAmount;
        totalWantPerRound[round] -= balance;

        wantBalances[msg.sender] = 0;
        depositRound[msg.sender] = 0;
    }

    function executeBatchPositions(bool _isWithdraw, bytes[] calldata _params) external payable onlyGov {
        require(msg.value >= executionFee * 2, "BatchRouter: not enougt execution Fee");
        uint256 amountIn = _isWithdraw ? totalSnGlpPerRound[currentWithdrawRound] : totalWantPerRound[currentDepositRound];
        IRouter(router).executePositionsBeforeDealGlp{value: msg.value}(amountIn, _params, _isWithdraw);
        executed = true; 
    }

    function confirmAndDealGlp(uint256 _amount, bool _isWithdraw) external onlyGov {
        require(executed, "BatchRouter: executes positions first");
        if (!_isWithdraw) {
            uint256 amountOut = IRouter(router).confirmAndBuy(_amount, address(this));

            _updateRewards();

            totalSnGlpReceivedPerRound[currentDepositRound] = amountOut;

            cumulativeEsNeuRewardPerRound[currentDepositRound] = cumulativeEsNeuRewardPerToken;
            cumulativeWantRewardPerRound[currentDepositRound] = cumulativeWantRewardPerToken;

            totalSnGlpReceivedAmount += amountOut;
            currentDepositRound += 1;
        } else {
            uint256 amountOut = IRouter(router).confirmAndSell(_amount, address(this));
            totalWantReceivedPerRound[currentWithdrawRound] = amountOut;
            totalWantReceivedAmount += amountOut;
            currentWithdrawRound += 1;
        }
        executed = false;
    }

    function _updateRewards() internal {
        uint256 esNeuAmount = IRewardTracker(stakedNeuGlpTracker).claimForAccount(address(this), address(this));
        uint256 wantAmount = IRewardTracker(feeNeuGlpTracker).claimForAccount(address(this), address(this));

        uint256 totalSupply = totalSnGlpReceivedAmount;

        if (totalSupply > 0) {
            cumulativeEsNeuRewardPerToken += esNeuAmount * PRECISION / totalSupply;
            cumulativeWantRewardPerToken += wantAmount * PRECISION / totalSupply;
        }
    }

    function setRouter(address _router) external onlyGov {
        router = _router;
    }

    function setDepositLimit(uint256 _limit) external onlyGov {
        depositLimit = _limit;
        emit UpdateDepositLimit(_limit);
    }

    function setTrackers(address _feeNeuGlpTracker, address _stakedNeuGlpTracker) external onlyGov {
        feeNeuGlpTracker = _feeNeuGlpTracker;
        stakedNeuGlpTracker = _stakedNeuGlpTracker;
    }

    function setExecutionFee(uint256 _executionFee) external onlyGov {
        executionFee = _executionFee;
    }

    function claimableWant(address _account) public view returns (uint256) {
        uint256 round = withdrawRound[_account];

        uint256 balance = snGlpBalances[_account];
        if (balance == 0) {
            return 0;
        }
        uint256 totalBalance = totalSnGlpPerRound[round];
        uint256 totalReceived = totalWantReceivedPerRound[round];

        return totalReceived * balance / totalBalance;

    }

    function claimableSnGlp(address _account) public view returns (uint256) {
        uint256 round = depositRound[_account];

        uint256 balance = wantBalances[_account];
        if (balance == 0) {
            return 0;
        }
        uint256 totalBalance = totalWantPerRound[round];
        uint256 totalReceived = totalSnGlpReceivedPerRound[round];

        return totalReceived * balance / totalBalance;
    }

    function pendingRewards(address _account) public view returns (uint256, uint256) {
        uint256 snGlpClaimable = claimableSnGlp(_account);

        if (snGlpClaimable == 0) {
            return (0, 0);
        }
        
        uint256 wantAmount = IRewardTracker(feeNeuGlpTracker).claimable(address(this));
        uint256 esNeuAmount = IRewardTracker(stakedNeuGlpTracker).claimable(address(this));

        uint256 wantCumulativeReward = cumulativeWantReward + wantAmount;
        uint256 esNeuCumulativeReward = cumulativeEsNeuReward + esNeuAmount;

        uint256 wantClaimable = wantCumulativeReward * snGlpClaimable / totalSnGlpReceivedAmount;
        uint256 esNeuClaimable = esNeuCumulativeReward * snGlpClaimable / totalSnGlpReceivedAmount;

        return (wantClaimable, esNeuClaimable);
    }

}