// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import {IERC20} from "../interfaces/IERC20.sol";
import {IMintable} from "../interfaces/IMintable.sol";
import {IRewardTracker} from "../interfaces/IRewardTracker.sol";
import {IVester} from "../interfaces/IVester.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {Governable} from "../libraries/Governable.sol";

contract RewardRouter is ReentrancyGuard, Governable {
    bool public isInitialized;

    address public weth;

    address public neu;
    address public esNeu;
    address public bnNeu;

    address public neuGlp;

    address public stakedNeuTracker;
    address public bonusNeuTracker;
    address public feeNeuTracker;

    address public stakedNeuGlpTracker;
    address public feeNeuGlpTracker;

    address public neuVester;
    address public neuGlpVester;

    mapping(address => address) public pendingReceivers;

    event StakeNeu(address account, address token, uint256 amount);
    event UnstakeNeu(address account, address token, uint256 amount);

    event StakeNeuGlp(address account, uint256 amount);
    event UnstakeNeuGlp(address account, uint256 amount);

    receive() external payable {
        require(msg.sender == weth, "Router: invalid sender");
    }

    function initialize(
        address _weth,
        address _neu,
        address _esNeu,
        address _bnNeu,
        address _neuGlp,
        address _stakedNeuTracker,
        address _bonusNeuTracker,
        address _feeNeuTracker,
        address _feeNeuGlpTracker,
        address _stakedNeuGlpTracker,
        address _neuVester,
        address _neuGlpVester
    ) external onlyGov {
        require(!isInitialized, "RewardRouter: already initialized");
        isInitialized = true;

        weth = _weth;

        neu = _neu;
        esNeu = _esNeu;
        bnNeu = _bnNeu;

        neuGlp = _neuGlp;

        stakedNeuTracker = _stakedNeuTracker;
        bonusNeuTracker = _bonusNeuTracker;
        feeNeuTracker = _feeNeuTracker;

        feeNeuGlpTracker = _feeNeuGlpTracker;
        stakedNeuGlpTracker = _stakedNeuGlpTracker;

        neuVester = _neuVester;
        neuGlpVester = _neuGlpVester;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).transfer(_account, _amount);
    }

    function batchStakeNeuForAccount(
        address[] memory _accounts,
        uint256[] memory _amounts
    ) external nonReentrant onlyGov {
        address _neu = neu;

        for (uint256 i = 0; i < _accounts.length; i++) {
            _stakeNeu(msg.sender, _accounts[i], _neu, _amounts[i]);
        }
    }

    function stakeNeuForAccount(address _account, uint256 _amount) external nonReentrant onlyGov {
        _stakeNeu(msg.sender, _account, neu, _amount);
    }

    function stakeNeu(uint256 _amount) external nonReentrant {
        _stakeNeu(msg.sender, msg.sender, neu, _amount);
    }

    function stakeEsNeu(uint256 _amount) external nonReentrant {
        _stakeNeu(msg.sender, msg.sender, esNeu, _amount);
    }

    function unstakeNeu(uint256 _amount) external nonReentrant {
        _unstakeNeu(msg.sender, neu, _amount, true);
    }

    function unstakeEsNeu(uint256 _amount) external nonReentrant {
        _unstakeNeu(msg.sender, esNeu, _amount, true);
    }

    function claimNGlp() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeNeuGlpTracker).claimForAccount(account, account);
        IRewardTracker(stakedNeuGlpTracker).claimForAccount(account, account);
    }

    function claim() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeNeuTracker).claimForAccount(account, account);

        IRewardTracker(stakedNeuTracker).claimForAccount(account, account);
        IRewardTracker(stakedNeuGlpTracker).claimForAccount(account, account);
    }

    function claimEsNeu() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(stakedNeuTracker).claimForAccount(account, account);
        IRewardTracker(stakedNeuGlpTracker).claimForAccount(account, account);
    }

    function claimFees() external nonReentrant {
        address account = msg.sender;

        IRewardTracker(feeNeuTracker).claimForAccount(account, account);
    }

    function compound() external nonReentrant {
        _compound(msg.sender);
    }

    function compoundForAccount(address _account) external nonReentrant onlyGov {
        _compound(_account);
    }

    function handleRewards(
        bool _shouldClaimNeu,
        bool _shouldStakeNeu,
        bool _shouldClaimEsNeu,
        bool _shouldStakeEsNeu,
        bool _shouldStakeMultiplierPoints,
        bool _shouldClaimFee
    ) external nonReentrant {
        address account = msg.sender;

        uint256 neuAmount = 0;
        if (_shouldClaimNeu) {
            uint256 neuAmount0 = IVester(neuVester).claimForAccount(account, account);
            uint256 neuAmount1 = IVester(neuGlpVester).claimForAccount(account, account);

            neuAmount = neuAmount0 + neuAmount1;
        }

        if (_shouldStakeNeu && neuAmount > 0) {
            _stakeNeu(account, account, neu, neuAmount);
        }

        uint256 esNeuAmount = 0;

        if (_shouldClaimEsNeu) {
            esNeuAmount = IRewardTracker(stakedNeuTracker).claimForAccount(account, account);
        }

        if (_shouldStakeEsNeu && esNeuAmount > 0) {
            _stakeNeu(account, account, esNeu, esNeuAmount);
        }

        if (_shouldStakeMultiplierPoints) {
            uint256 bnNeuAmount = IRewardTracker(bonusNeuTracker).claimForAccount(account, account);

            if (bnNeuAmount > 0) {
                IRewardTracker(feeNeuTracker).stakeForAccount(account, account, bnNeu, bnNeuAmount);
            }
        }

        if (_shouldClaimFee) {
                IRewardTracker(feeNeuTracker).claimForAccount(account, account);
        }
    }

    function batchCompoundForAccounts(address[] memory _accounts) external nonReentrant onlyGov {
        for (uint256 i = 0; i < _accounts.length; i++) {
            _compound(_accounts[i]);
        }
    }

    function signalTransfer(address _receiver) external nonReentrant {
        require(IERC20(neuVester).balanceOf(msg.sender) == 0, "RewardRouter: sender has vested tokens");
        require(IERC20(neuGlpVester).balanceOf(msg.sender) == 0, "RewardRouter: sender has vested tokens");

        _validateReceiver(_receiver);
        pendingReceivers[msg.sender] = _receiver;
    }

    function acceptTransfer(address _sender) external nonReentrant {
        require(IERC20(neuVester).balanceOf(_sender) == 0, "RewardRouter: sender has vested tokens");
        require(IERC20(neuGlpVester).balanceOf(_sender) == 0, "RewardRouter: sender has vested tokens");

        address receiver = msg.sender;

        require(pendingReceivers[_sender] == receiver, "RewardRouter: transfer not signalled");
        delete pendingReceivers[_sender];

        _validateReceiver(receiver);
        _compound(_sender);

        uint256 stakedNeu = IRewardTracker(stakedNeuTracker).depositBalances(_sender, neu);
        if (stakedNeu > 0) {
            _unstakeNeu(_sender, neu, stakedNeu, false);
            _stakeNeu(_sender, receiver, neu, stakedNeu);
        }

        uint256 stakedEsNeu = IRewardTracker(stakedNeuTracker).depositBalances(_sender, esNeu);
        if (stakedEsNeu > 0) {
            _unstakeNeu(_sender, esNeu, stakedEsNeu, false);
            _stakeNeu(_sender, receiver, esNeu, stakedEsNeu);
        }

        uint256 stakedBnNeu = IRewardTracker(feeNeuTracker).depositBalances(_sender, bnNeu);
        if (stakedBnNeu > 0) {
            IRewardTracker(feeNeuTracker).unstakeForAccount(_sender, bnNeu, stakedBnNeu, _sender);
            IRewardTracker(feeNeuTracker).stakeForAccount(_sender, receiver, bnNeu, stakedBnNeu);
        }

        uint256 esNeuBalance = IERC20(esNeu).balanceOf(_sender);
        if (esNeuBalance > 0) {
            IERC20(esNeu).transferFrom(_sender, receiver, esNeuBalance);
        }

        uint256 neuGlpAmount = IRewardTracker(feeNeuGlpTracker).depositBalances(_sender, neuGlp);

        if (neuGlpAmount > 0) {
            IRewardTracker(stakedNeuGlpTracker).unstakeForAccount(_sender, feeNeuGlpTracker, neuGlpAmount, _sender);
            IRewardTracker(feeNeuGlpTracker).unstakeForAccount(_sender, neuGlp, neuGlpAmount, _sender);

            IRewardTracker(feeNeuGlpTracker).stakeForAccount(_sender, receiver, neuGlp, neuGlpAmount);
            IRewardTracker(stakedNeuGlpTracker).stakeForAccount(receiver, receiver, feeNeuGlpTracker, neuGlpAmount);
        }

        IVester(neuVester).transferStakeValues(_sender, receiver);
        IVester(neuGlpVester).transferStakeValues(_sender, receiver);
    }

    function _validateReceiver(address _receiver) private view {
        require(
            IRewardTracker(stakedNeuTracker).averageStakedAmounts(_receiver) == 0,
            "RewardRouter: stakedNeuTracker.averageStakedAmounts > 0"
        );
        require(
            IRewardTracker(stakedNeuTracker).cumulativeRewards(_receiver) == 0,
            "RewardRouter: stakedNeuTracker.cumulativeRewards > 0"
        );

        require(
            IRewardTracker(bonusNeuTracker).averageStakedAmounts(_receiver) == 0,
            "RewardRouter: bonusNeuTracker.averageStakedAmounts > 0"
        );
        require(
            IRewardTracker(bonusNeuTracker).cumulativeRewards(_receiver) == 0,
            "RewardRouter: bonusNeuTracker.cumulativeRewards > 0"
        );

        require(
            IRewardTracker(feeNeuTracker).averageStakedAmounts(_receiver) == 0,
            "RewardRouter: feeNeuTracker.averageStakedAmounts > 0"
        );
        require(
            IRewardTracker(feeNeuTracker).cumulativeRewards(_receiver) == 0,
            "RewardRouter: feeNeuTracker.cumulativeRewards > 0"
        );

        require(
            IVester(neuVester).transferredAverageStakedAmounts(_receiver) == 0,
            "RewardRouter: neuVester.transferredAverageStakedAmounts > 0"
        );
        require(
            IVester(neuVester).transferredCumulativeRewards(_receiver) == 0,
            "RewardRouter: neuVester.transferredCumulativeRewards > 0"
        );

        require(
            IRewardTracker(stakedNeuGlpTracker).averageStakedAmounts(_receiver) == 0,
            "RewardRouter: stakedNeuGlpTracker.averageStakedAmounts > 0"
        );
        require(
            IRewardTracker(stakedNeuGlpTracker).cumulativeRewards(_receiver) == 0,
            "RewardRouter: stakedNeuGlpTracker.cumulativeRewards > 0"
        );

        require(
            IRewardTracker(feeNeuGlpTracker).averageStakedAmounts(_receiver) == 0,
            "RewardRouter: feeNeuGlpTracker.averageStakedAmounts > 0"
        );
        require(
            IRewardTracker(feeNeuGlpTracker).cumulativeRewards(_receiver) == 0,
            "RewardRouter: feeNeuGlpTracker.cumulativeRewards > 0"
        );

        require(
            IVester(neuGlpVester).transferredAverageStakedAmounts(_receiver) == 0,
            "RewardRouter: neuGlpVester.transferredAverageStakedAmounts > 0"
        );
        require(
            IVester(neuGlpVester).transferredCumulativeRewards(_receiver) == 0,
            "RewardRouter: neuGlpVester.transferredCumulativeRewards > 0"
        );

        require(IERC20(neuVester).balanceOf(_receiver) == 0, "RewardRouter: neuVester.balance > 0");
        require(IERC20(neuGlpVester).balanceOf(_receiver) == 0, "RewardRouter: neuGlpVester.balance > 0");
    }

    function _compound(address _account) private {
        _compoundNeu(_account);
        _compoundNeuGlp(_account);
    }

    function _compoundNeu(address _account) private {
        uint256 esNeuAmount = IRewardTracker(stakedNeuTracker).claimForAccount(_account, _account);

        if (esNeuAmount > 0) {
            _stakeNeu(_account, _account, esNeu, esNeuAmount);
        }

        uint256 bnNeuAmount = IRewardTracker(bonusNeuTracker).claimForAccount(_account, _account);

        if (bnNeuAmount > 0) {
            IRewardTracker(feeNeuTracker).stakeForAccount(_account, _account, bnNeu, bnNeuAmount);
        }
    }

    function _compoundNeuGlp(address _account) private {
        uint256 esNeuAmount = IRewardTracker(stakedNeuGlpTracker).claimForAccount(_account, _account);

        if (esNeuAmount > 0) {
            _stakeNeu(_account, _account, esNeu, esNeuAmount);
        }
    }

    function _stakeNeu(address _fundingAccount, address _account, address _token, uint256 _amount) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        IRewardTracker(stakedNeuTracker).stakeForAccount(_fundingAccount, _account, _token, _amount);
        IRewardTracker(bonusNeuTracker).stakeForAccount(_account, _account, stakedNeuTracker, _amount);
        IRewardTracker(feeNeuTracker).stakeForAccount(_account, _account, bonusNeuTracker, _amount);

        emit StakeNeu(_account, _token, _amount);
    }

    function _unstakeNeu(address _account, address _token, uint256 _amount, bool _shouldReduceBnNeu) private {
        require(_amount > 0, "RewardRouter: invalid _amount");

        uint256 balance = IRewardTracker(stakedNeuTracker).stakedAmounts(_account);

        IRewardTracker(feeNeuTracker).unstakeForAccount(_account, bonusNeuTracker, _amount, _account);
        IRewardTracker(bonusNeuTracker).unstakeForAccount(_account, stakedNeuTracker, _amount, _account);
        IRewardTracker(stakedNeuTracker).unstakeForAccount(_account, _token, _amount, _account);

        if (_shouldReduceBnNeu) {
            uint256 bnNeuAmount = IRewardTracker(bonusNeuTracker).claimForAccount(_account, _account);

            if (bnNeuAmount > 0) {
                IRewardTracker(feeNeuTracker).stakeForAccount(_account, _account, bnNeu, bnNeuAmount);
            }

            uint256 stakedBnNeu = IRewardTracker(feeNeuTracker).depositBalances(_account, bnNeu);

            if (stakedBnNeu > 0) {
                uint256 reductionAmount = stakedBnNeu * _amount / balance;

                IRewardTracker(feeNeuTracker).unstakeForAccount(_account, bnNeu, reductionAmount, _account);
                IMintable(bnNeu).burn(_account, reductionAmount);
            }
        }

        emit UnstakeNeu(_account, _token, _amount);
    }
}
