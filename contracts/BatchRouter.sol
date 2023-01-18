// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "./libraries/MerkleProof.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {IRewardTracker} from "./interfaces/IRewardTracker.sol";
import {IRouter} from "./interfaces/IRouter.sol";

contract BatchRouter is Initializable, UUPSUpgradeable {
    bool public executed;
    bool public isPublicSale;
    bool public isWhitelistSale;
    bool public lastExecutionStatus; //false - deposit , true - withdraw

    address public gov;

    address public want;
    address public nGlp;
    address public fnGlp;
    address public router;
    address public esNeu;
    
    uint256 constant PRECISION = 1e30;
    uint256 public executionFee;
    uint256 public depositLimit; // want decimals

    uint256 public currentDepositRound;
    uint256 public currentWithdrawRound;

    uint256 public cumulativeWantReward;
    uint256 public cumulativeEsNeuReward;

    uint256 public cumulativeWantRewardPerToken;
    uint256 public cumulativeEsNeuRewardPerToken;

    uint256 public totalSnGlpReceivedAmount;
    uint256 public totalWantReceivedAmount;

    uint256 public whitelistCapPerAccount;

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

    mapping(address => bool) public isHandler;

    address public feeNeuGlpTracker;
    address public stakedNeuGlpTracker;

    uint256 public pendingDealAmount;
    bytes32 public merkleRoot;

    event ReserveDeposit(address indexed account, uint256 amount, uint256 round);
    event ReserveWithdraw(address indexed account, uint256 amount, uint256 round);
    event CancelDeposit(address indexed account, uint256 amount, uint256 round);
    event CancelWithdraw(address indexed account, uint256 amount, uint256 round);
    event ClaimWant(address indexed account, uint256 round, uint256 balance, uint256 claimAmount);
    event ClaimStakedNeuGlp(
        address indexed account, 
        uint256 round, 
        uint256 balance, 
        uint256 claimAmount, 
        uint256 esNeuClaimable, 
        uint256 wantClaimable
    );
    event ExecuteBatchPositions(bool isWithdraw, uint256 amountIn);
    event ConfirmAndDealGlpDeposit(uint256 amountOut, uint256 round);
    event ConfirmAndDealGlpWithdraw(uint256 amountOut, uint256 round);
    event UpdateReward(
        uint256 esNeuAmount, 
        uint256 wantAmount, 
        uint256 cumulativeEsNeuRewardPerToken, 
        uint256 cumulativeWantRewardPerToken
    );
    event SetGov(address gov);
    event SetRouter(address router);
    event SetTrackers(address feeNeuGlpTracker, address stakedNeuGlpTracker);
    event SetExecutionFee(uint256 executionFee);
    event SetDepositLimit(uint256 limit);
    event SetHandler(address handler, bool isActive);
    event SetSale(bool isPublicSale, bool isWhitelistSale);
    event SetWhitelistCapPerAccount(uint256 amount);

    modifier onlyGov() {
        _onlyGov();
        _;
    }

    modifier onlyHandlerAndAbove() {
        _onlyHandlerAndAbove();
        _;
    }

    function initialize(address _want, address _nGlp, address _esNeu) public initializer {
        want =_want;
        nGlp = _nGlp;
        esNeu = _esNeu;

        gov = msg.sender;
        executionFee = 0.0001 ether;
        currentDepositRound = 1;
        currentWithdrawRound = 1;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyGov {}

    function _onlyGov() internal view {
        require(msg.sender == gov, "BatchRouter: not authorized");
    }

    function _onlyHandlerAndAbove() internal view {
        require(msg.sender == gov || isHandler[msg.sender], "BatchRouter: forbidden");
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        require(_handler != address(0), "BatchRouter: invalid address");
        isHandler[_handler] = _isActive;
        emit SetHandler(_handler, _isActive);
    }

    function approveToken(address _token, address _spender) external onlyGov {
        IERC20(_token).approve(_spender, type(uint256).max);
    }

    function whitlelistReserveDeposit(bytes32[] calldata _merkleProf, uint256 _amount) public {
        require(!executed, "BatchRouter: batch under execution");
        require(isWhitelistSale, "BatchRouter: sale is closed");
        require(_verify(_merkleProf, msg.sender), "BatchRouter: invalid proof");
        if (wantBalances[msg.sender] > 0) {
            _claimStakedNeuGlp();
        }

        IERC20(want).transferFrom(msg.sender, address(this), _amount);
        totalWantPerRound[currentDepositRound] += _amount;
        require(totalWantPerRound[currentDepositRound] <= depositLimit, "BatchRouter: exceeded deposit limit");
        wantBalances[msg.sender] += _amount;
        require(whitelistCapPerAccount >= wantBalances[msg.sender], "BatchRouter: exceeded whitelist limit");

        if (depositRound[msg.sender] == 0) {
            depositRound[msg.sender] = currentDepositRound;
        }

        emit ReserveDeposit(msg.sender, _amount, depositRound[msg.sender]);

    }

    function reserveDeposit(uint256 _amount) external {
        require(!executed, "BatchRouter: batch under execution");
        require(isPublicSale, "BatchRouter: sale is closed");
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

        emit ReserveDeposit(msg.sender, _amount, depositRound[msg.sender]);
    }

    function reserveWithdraw(uint256 _amount) external {
        require(!executed, "BatchRouter: batch under execution");
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

        emit ReserveWithdraw(msg.sender, _amount, withdrawRound[msg.sender]);
    }

    function cancelDeposit(uint256 _amount) external {
        require(!executed, "BatchRouter: batch under execution");
        require(currentDepositRound == depositRound[msg.sender], "BatchRouter : batch already exectued");
        wantBalances[msg.sender] -= _amount;
        totalWantPerRound[currentDepositRound] -= _amount;

        IERC20(want).transfer(msg.sender, _amount);
        if (wantBalances[msg.sender] == 0) {
            depositRound[msg.sender] = 0;
        }

        emit CancelDeposit(msg.sender, _amount, currentDepositRound);
    }

    function cancelWithdraw(uint256 _amount) external {
        require(!executed, "BatchRouter: batch under execution");
        require(currentWithdrawRound == withdrawRound[msg.sender], "BatchRouter : batch already exectued");
        snGlpBalances[msg.sender] -= _amount;
        totalSnGlpPerRound[currentWithdrawRound] -= _amount;
        
        IRewardTracker(feeNeuGlpTracker).stakeForAccount(address(this), msg.sender, nGlp, _amount);
        IRewardTracker(stakedNeuGlpTracker).stakeForAccount(msg.sender, msg.sender, feeNeuGlpTracker, _amount);
        
        if (snGlpBalances[msg.sender] == 0) {
            withdrawRound[msg.sender] = 0;
        }

        emit CancelWithdraw(msg.sender, _amount, currentWithdrawRound);
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

        emit ClaimWant(msg.sender, round, balance, claimAmount);
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

        emit ClaimStakedNeuGlp(msg.sender, round, balance, claimAmount, esNeuClaimable, wantClaimable);
    }

    function executeBatchPositions(bool _isWithdraw, bytes[] calldata _params, uint256 _dealAmount) external payable onlyHandlerAndAbove {
        require(msg.value >= executionFee * 2, "BatchRouter: not enough execution Fee");
        uint256 amountIn = _isWithdraw ? totalSnGlpPerRound[currentWithdrawRound] : totalWantPerRound[currentDepositRound];
        IRouter(router).executePositionsBeforeDealGlp{value: msg.value}(amountIn, _params, _isWithdraw);

        pendingDealAmount = _dealAmount;
        lastExecutionStatus = _isWithdraw;

        executed = true; 

        emit ExecuteBatchPositions(_isWithdraw, amountIn);
    }

    function confirmAndDealGlp() external onlyHandlerAndAbove {
        require(executed, "BatchRouter: executes positions first");
        if (!lastExecutionStatus) {
            uint256 amountOut = IRouter(router).confirmAndBuy(pendingDealAmount, address(this));

            _updateRewards();

            totalSnGlpReceivedPerRound[currentDepositRound] = amountOut;

            cumulativeEsNeuRewardPerRound[currentDepositRound] = cumulativeEsNeuRewardPerToken;
            cumulativeWantRewardPerRound[currentDepositRound] = cumulativeWantRewardPerToken;

            totalSnGlpReceivedAmount += amountOut;
            currentDepositRound += 1;
            
            pendingDealAmount = 0;
            emit ConfirmAndDealGlpDeposit(amountOut, currentDepositRound - 1);
        } else {
            uint256 amountOut = IRouter(router).confirmAndSell(pendingDealAmount, address(this));
            totalWantReceivedPerRound[currentWithdrawRound] = amountOut;
            totalWantReceivedAmount += amountOut;
            currentWithdrawRound += 1;

            pendingDealAmount = 0;
            emit ConfirmAndDealGlpWithdraw(amountOut, currentWithdrawRound - 1);
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

        emit UpdateReward(esNeuAmount, wantAmount, cumulativeEsNeuRewardPerToken, cumulativeWantRewardPerToken);
    }

    function setRouter(address _router) external onlyGov {
        require(_router != address(0), "BatchRouter: invalid address");
        router = _router;
        emit SetRouter(_router);
    }

    function setDepositLimit(uint256 _limit) external onlyGov {
        depositLimit = _limit;
        emit SetDepositLimit(_limit);
    }

    function setTrackers(address _feeNeuGlpTracker, address _stakedNeuGlpTracker) external onlyGov {
        require(_feeNeuGlpTracker != address(0) && _stakedNeuGlpTracker != address(0), "BatchRouter: invalid address");
        feeNeuGlpTracker = _feeNeuGlpTracker;
        stakedNeuGlpTracker = _stakedNeuGlpTracker;
        emit SetTrackers(_feeNeuGlpTracker, _stakedNeuGlpTracker);
    }

    function setExecutionFee(uint256 _executionFee) external onlyGov {
        executionFee = _executionFee;
        emit SetExecutionFee(_executionFee);
    }

    function setWhitelistCapPerAccount(uint256 _amount) external onlyGov {
        whitelistCapPerAccount = _amount;
        emit SetWhitelistCapPerAccount(_amount);
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

    function setMerkleRoot(bytes32 _merkleRoot) external onlyGov {
        merkleRoot =  _merkleRoot;
    }

    function setSale(bool _isPublicSale, bool _isWhitelistSale) external onlyGov {
        isPublicSale = _isPublicSale;
        isWhitelistSale = _isWhitelistSale;
        emit SetSale(_isPublicSale, _isWhitelistSale);
    }

    function _verify(bytes32[] calldata _merkleProof, address _sender) private view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(_sender));
        return MerkleProof.verify(_merkleProof, merkleRoot, leaf);
    }

}