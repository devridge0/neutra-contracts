// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import {IERC20} from "../interfaces/IERC20.sol";
import {IMintable} from "../interfaces/IMintable.sol";
import {Governable} from "../libraries/Governable.sol";
import {IRewardTracker} from "../interfaces/IRewardTracker.sol";
import {IVester} from "../interfaces/IVester.sol";

contract Vester is IVester, IERC20, ReentrancyGuard, Governable {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    uint256 public vestingDuration;

    address public esToken;

    address public pairToken;

    address public claimableToken;

    address public rewardTracker;

    uint256 public totalSupply;
    uint256 public pairSupply;

    bool public hasMaxVestableAmount;

    mapping(address => uint256) public balances;

    mapping(address => uint256) public pairAmounts;

    mapping(address => uint256) public cumulativeClaimAmounts;

    mapping(address => uint256) public claimedAmounts;

    mapping(address => uint256) public lastVestingTimes;

    mapping(address => uint256) public transferredAverageStakedAmounts;
    mapping(address => uint256) public transferredCumulativeRewards;

    mapping(address => uint256) public cumulativeRewardDeductions;

    mapping(address => uint256) public bonusRewards;

    mapping(address => bool) public isHandler;

    event Claim(address receiver, uint256 amount);
    event Deposit(address account, uint256 amount);
    event Withdraw(address account, uint256 claimedAmount, uint256 balance);
    event PairTransfer(address indexed from, address indexed to, uint256 value);

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _vestingDuration,
        address _esToken,
        address _pairToken,
        address _claimableToken,
        address _rewardTracker
    ) {
        name = _name;
        symbol = _symbol;

        vestingDuration = _vestingDuration;

        esToken = _esToken;
        pairToken = _pairToken;
        claimableToken = _claimableToken;

        rewardTracker = _rewardTracker;

        if (rewardTracker != address(0)) {
            hasMaxVestableAmount = true;
        }
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function setHandlers(address[] memory _handler, bool[] memory _isActive) external onlyGov {
        for (uint256 i = 0; i < _handler.length; i++) {
            isHandler[_handler[i]] = _isActive[i];
        }
    }

    function setHasMaxVestableAmount(bool _hasMaxVestableAmount) external onlyGov {
        hasMaxVestableAmount = _hasMaxVestableAmount;
    }

    function deposit(uint256 _amount) external nonReentrant {
        _deposit(msg.sender, _amount);
    }

    function depositForAccount(address _account, uint256 _amount) external nonReentrant {
        _validateHandler();
        _deposit(_account, _amount);
    }

    function claim() external nonReentrant returns (uint256) {
        return _claim(msg.sender, msg.sender);
    }

    function claimForAccount(address _account, address _receiver) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _claim(_account, _receiver);
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).transfer(_account, _amount);
    }

    function withdraw() external nonReentrant {
        address account = msg.sender;
        address _receiver = account;

        _claim(account, _receiver);

        uint256 claimedAmount = cumulativeClaimAmounts[account];

        uint256 balance = balances[account];

        uint256 totalVested = balance + claimedAmount;

        require(totalVested > 0, "Vester: vested amount is zero");

        if (hasPairToken()) {
            uint256 pairAmount = pairAmounts[account];

            _burnPair(account, pairAmount);

            IERC20(pairToken).transfer(_receiver, pairAmount);
        }

        IERC20(esToken).transfer(_receiver, balance);

        _burn(account, balance);

        delete cumulativeClaimAmounts[account];
        delete claimedAmounts[account];
        delete lastVestingTimes[account];

        emit Withdraw(account, claimedAmount, balance);
    }

    function transferStakeValues(address _sender, address _receiver) external override nonReentrant {
        _validateHandler();

        transferredAverageStakedAmounts[_receiver] = getCombinedAverageStakedAmount(_sender);
        transferredAverageStakedAmounts[_sender] = 0;

        uint256 transferredCumulativeReward = transferredCumulativeRewards[_sender];
        uint256 cumulativeReward = IRewardTracker(rewardTracker).cumulativeRewards(_sender);
        transferredCumulativeRewards[_receiver] = transferredCumulativeReward + cumulativeReward;

        cumulativeRewardDeductions[_sender] = cumulativeReward;
        transferredCumulativeRewards[_sender] = 0;

        bonusRewards[_receiver] = bonusRewards[_sender];
        bonusRewards[_sender] = 0;
    }

    function setTransferredAverageStakedAmounts(address _account, uint256 _amount) external override nonReentrant {
        _validateHandler();
        transferredAverageStakedAmounts[_account] = _amount;
    }

    function setTransferredCumulativeRewards(address _account, uint256 _amount) external override nonReentrant {
        _validateHandler();
        transferredCumulativeRewards[_account] = _amount;
    }

    function setCumulativeRewardDeductions(address _account, uint256 _amount) external override nonReentrant {
        _validateHandler();
        cumulativeRewardDeductions[_account] = _amount;
    }

    function setBonusRewards(address _account, uint256 _amount) external override nonReentrant {
        _validateHandler();
        bonusRewards[_account] = _amount;
    }

    function claimable(address _account) public view override returns (uint256) {
        uint256 amount = cumulativeClaimAmounts[_account] - claimedAmounts[_account];

        uint256 nextClaimable = _getNextClaimableAmount(_account);

        return amount + nextClaimable;
    }

    function getMaxVestableAmount(address _account) public view override returns (uint256) {
        if (!hasRewardTracker()) {
            return 0;
        }

        uint256 transferredCumulativeReward = transferredCumulativeRewards[_account];
        uint256 bonusReward = bonusRewards[_account];
        uint256 cumulativeReward = IRewardTracker(rewardTracker).cumulativeRewards(_account);

        uint256 maxVestableAmount = cumulativeReward + transferredCumulativeReward + bonusReward;

        uint256 cumulativeRewardDeduction = cumulativeRewardDeductions[_account];

        if (maxVestableAmount < cumulativeRewardDeduction) {
            return 0;
        }

        return maxVestableAmount - cumulativeRewardDeduction;
    }

    function getCombinedAverageStakedAmount(address _account) public view override returns (uint256) {
        uint256 cumulativeReward = IRewardTracker(rewardTracker).cumulativeRewards(_account);
        uint256 transferredCumulativeReward = transferredCumulativeRewards[_account];

        uint256 totalCumulativeReward = cumulativeReward + transferredCumulativeReward;

        if (totalCumulativeReward == 0) {
            return 0;
        }

        uint256 averageStakedAmount = IRewardTracker(rewardTracker).averageStakedAmounts(_account);
        uint256 transferredAverageStakedAmount = transferredAverageStakedAmounts[_account];

        return
            ((averageStakedAmount * cumulativeReward) / totalCumulativeReward) +
            ((transferredAverageStakedAmount * transferredCumulativeReward) / totalCumulativeReward);
    }

    function getPairAmount(address _account, uint256 _esAmount) public view returns (uint256) {
        if (!hasRewardTracker()) {
            return 0;
        }

        uint256 combinedAverageStakedAmount = getCombinedAverageStakedAmount(_account);

        if (combinedAverageStakedAmount == 0) {
            return 0;
        }

        uint256 maxVestableAmount = getMaxVestableAmount(_account);

        if (maxVestableAmount == 0) {
            return 0;
        }

        return (_esAmount * combinedAverageStakedAmount) / maxVestableAmount;
    }

    function hasRewardTracker() public view returns (bool) {
        return rewardTracker != address(0);
    }

    function hasPairToken() public view returns (bool) {
        return pairToken != address(0);
    }

    function getTotalVested(address _account) public view returns (uint256) {
        return balances[_account] + cumulativeClaimAmounts[_account];
    }

    function balanceOf(address _account) public view override returns (uint256) {
        return balances[_account];
    }

    // empty implementation, tokens are non-transferrable
    function transfer(address /* recipient */, uint256 /* amount */) public override returns (bool) {
        revert("Vester: non-transferrable");
    }

    // empty implementation, tokens are non-transferrable
    function allowance(address /* owner */, address /* spender */) public view virtual override returns (uint256) {
        return 0;
    }

    // empty implementation, tokens are non-transferrable
    function approve(address /* spender */, uint256 /* amount */) public virtual override returns (bool) {
        revert("Vester: non-transferrable");
    }

    // empty implementation, tokens are non-transferrable
    function transferFrom(
        address /* sender */,
        address /* recipient */,
        uint256 /* amount */
    ) public virtual override returns (bool) {
        revert("Vester: non-transferrable");
    }

    function getVestedAmount(address _account) public view override returns (uint256) {
        uint256 balance = balances[_account];

        uint256 cumulativeClaimAmount = cumulativeClaimAmounts[_account];

        return balance + cumulativeClaimAmount;
    }

    function _mint(address _account, uint256 _amount) private {
        require(_account != address(0), "Vester: mint to the zero address");

        totalSupply = totalSupply + _amount;
        balances[_account] = balances[_account] + _amount;

        emit Transfer(address(0), _account, _amount);
    }

    function _mintPair(address _account, uint256 _amount) private {
        require(_account != address(0), "Vester: mint to the zero address");

        pairSupply = pairSupply + _amount;
        pairAmounts[_account] = pairAmounts[_account] + _amount;

        emit PairTransfer(address(0), _account, _amount);
    }

    function _burn(address _account, uint256 _amount) private {
        require(_account != address(0), "Vester: burn from the zero address");

        balances[_account] = balances[_account] - _amount;

        totalSupply = totalSupply - _amount;

        emit Transfer(_account, address(0), _amount);
    }

    function _burnPair(address _account, uint256 _amount) private {
        require(_account != address(0), "Vester: burn from the zero address");

        pairAmounts[_account] = pairAmounts[_account] - _amount;
        pairSupply = pairSupply - _amount;

        emit PairTransfer(_account, address(0), _amount);
    }

    function _deposit(address _account, uint256 _amount) private {
        require(_amount > 0, "Vester: invalid _amount");

        _updateVesting(_account);

        IERC20(esToken).transferFrom(_account, address(this), _amount);

        _mint(_account, _amount);

        if (hasPairToken()) {
            uint256 pairAmount = pairAmounts[_account];

            uint256 nextPairAmount = getPairAmount(_account, balances[_account]);

            if (nextPairAmount > pairAmount) {
                uint256 pairAmountDiff = nextPairAmount - pairAmount;
                IERC20(pairToken).transferFrom(_account, address(this), pairAmountDiff);
                _mintPair(_account, pairAmountDiff);
            }
        }

        if (hasMaxVestableAmount) {
            uint256 maxAmount = getMaxVestableAmount(_account);

            require(getTotalVested(_account) <= maxAmount, "Vester: max vestable amount exceeded");
        }

        emit Deposit(_account, _amount);
    }

    function _updateVesting(address _account) private {
        uint256 amount = _getNextClaimableAmount(_account);

        lastVestingTimes[_account] = block.timestamp;

        if (amount == 0) {
            return;
        }

        _burn(_account, amount);

        cumulativeClaimAmounts[_account] = cumulativeClaimAmounts[_account] + amount;

        IMintable(esToken).burn(address(this), amount);
    }

    function _getNextClaimableAmount(address _account) private view returns (uint256) {
        uint256 timeDiff = block.timestamp - lastVestingTimes[_account];

        uint256 balance = balances[_account];

        if (balance == 0) {
            return 0;
        }

        uint256 vestedAmount = getVestedAmount(_account);

        uint256 claimableAmount = (vestedAmount * timeDiff) / vestingDuration;

        if (claimableAmount < balance) {
            return claimableAmount;
        }

        return balance;
    }

    function _claim(address _account, address _receiver) private returns (uint256) {
        _updateVesting(_account);

        uint256 amount = claimable(_account);

        claimedAmounts[_account] = claimedAmounts[_account] + amount;

        IERC20(claimableToken).transfer(_receiver, amount);

        emit Claim(_account, amount);
        return amount;
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "Vester: forbidden");
    }
}
