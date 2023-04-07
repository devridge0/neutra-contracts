// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "@openzeppelin/contracts/security/Pausable.sol";

import { IRewardTracker} from "./interfaces/IRewardTracker.sol";
import { IStrategyVault } from "./interfaces/IStrategyVault.sol";
import { IERC20 } from "./interfaces/IERC20.sol";
import { IMintable } from "./interfaces/IMintable.sol";
import { Governable } from "./libraries/Governable.sol";
import { IGmxHelper } from "./interfaces/IGmxHelper.sol";
import { IVault } from "./interfaces/gmx/IVault.sol";
import { IStakedGlp } from "./interfaces/gmx/IStakedGlp.sol";
import { IRewardRouter } from "./interfaces/gmx/IRewardRouter.sol";

struct InitialConfig {
    address fsGlp;
    address nGlp;
    address fnGlp;
    address snGlp;
    address gmxVault;
    address stakedGlp;
    address glpRewardRouter;
    address glpManager;

    address strategyVault;
    address gmxHelper;

    address want;
    address wbtc;
    address weth;
}


contract RouterV2 is Governable, Pausable {
    struct PendingStatus {
        address recipient;
        bool isProgress;
        uint256 totalValueBefore; // 30 decimals
        uint256 totalSupplyBefore; // 18 decimals
        bool fisrtCallbackExecuted;
        bool withdrawGlp;
        uint256 longValueBefore;
        uint256 wbtcCollateralBefore;
        uint256 wethCollateralBefore;
    }

    struct PositionParams {
        uint256 size;
        uint256 collateral;
        uint256 avgPrice;
    }

    struct ProfitParams {
        bool hasProfit;
        uint256 pnl;
    }

    uint256 constant MINIMUM_WITHDRAWL = 1e16;
    uint256 constant MAX_BPS = 10_000;

    address public fsGlp;
    address public snGlp;
    address public fnGlp;
    address public nGlp;
    address public gmxVault;
    address public stakedGlp;
    address public glpRewardRouter;

    address public want;
    address public wbtc;
    address public weth;

    address public strategyVault;
    address public gmxHelper;

    // callback
    address public executionCallbackTarget;
    address public repayCallbackTarget;

    // GMX fee
    uint256 public executionFee = 0.0001 ether;
    uint256 public marginFeeBasisPoints = 10;

    uint256 public targetLeverage = 55_000;

    uint256 public cumulativeMintAmount;
    uint256 public cumulativeBurnAmount;

    bytes32 public curWbtcRequestKey;
    bytes32 public curWethRequestKey;

    bool public isExecutionFailed;

    mapping(address => uint256) public shortBuffers;

    PendingStatus public pendingStatus;

    event InstantDeposit(address account, uint256 amount);
    event InstantDepositGlp(address account, uint256 amount);
    event InstantWithdraw(address account, uint256 amount);
    event FirstCallback(address recipient, bool isIncrease);
    event SecondCallback(address recipient, bool isIncrease);
    event ExecutionFailed(address recipient, bool fisrtCallbackExecuted, bool isIncrease, bool isRepay);
    event SetCallbackTargets(address executionCallbackTarget, address repayCallbackTarget);
    event SetExecutionFee(uint256 executionFee);
    event SetTargetLeverage(uint256 taregtLeverage);
    event SetMarginFeeBasisPoints(uint256 bps);
    event SetShortBuffers(uint256 wbtcBuffer, uint256 wethBuffer);
    event SetGmxHelper(address helper);

    modifier initialValidate() {
        _initialValidate();
        _;
    }

    constructor(InitialConfig memory _config) {
        fsGlp = _config.fsGlp;
        snGlp = _config.snGlp;
        fnGlp = _config.fnGlp;
        nGlp = _config.nGlp;
        gmxVault = _config.gmxVault;
        glpRewardRouter = _config.glpRewardRouter;
        stakedGlp = _config.stakedGlp;

        want = _config.want;

        wbtc = _config.wbtc;
        weth = _config.weth;

        strategyVault = _config.strategyVault;
        gmxHelper = _config.gmxHelper;

        IERC20(want).approve(_config.glpManager, type(uint256).max);
        IERC20(want).approve(strategyVault, type(uint256).max);
        IStakedGlp(stakedGlp).approve(strategyVault, type(uint256).max);
    }

    /**
     * @notice
     *  deposit `_amount` of `want` and issue `snGlp` as a share
     *  This function should not be executed while a deposit or withdrawal is in progress
     * @param _amount the quantity of tokens to deposit
     */
    function instantDeposit(uint256 _amount) external payable whenNotPaused initialValidate {
        require(msg.value >= executionFee * 2, "not enough execution fee");
        
        IStrategyVault(strategyVault).harvest();

        _checkLastFundingTime();
        _setPendingStatus(true);

        (uint256 glpAmountIn, uint256 wbtcAmountIn, uint256 wethAmountIn) = getDepositParams(_amount);
        require(glpAmountIn > 0);

        IERC20(want).transferFrom(msg.sender, strategyVault, _amount);

        uint256 amountOut = IStrategyVault(strategyVault).buyGlp(glpAmountIn);

        _mintNeutraGlp(0x0);

        // calculate the sizeDelta based on the amountOut
        // to ensure the exact amount of fsGlp received is considered
        (uint256 wbtcSizeDelta, uint256 wethSizeDelta) = IGmxHelper(gmxHelper).getTokenAumsPerAmount(amountOut, false);

        _validateMaxGlobalShortSize(wbtcSizeDelta, wethSizeDelta);

        (bytes32 wbtcRequestKey, bytes32 wethRequestkey) = IStrategyVault(strategyVault).increaseShortPositionsWithCallback{value: executionFee * 2}(
            wbtcAmountIn,
            wbtcSizeDelta,
            wethAmountIn,
            wethSizeDelta,
            executionCallbackTarget
        );

        curWbtcRequestKey = wbtcRequestKey;
        curWethRequestKey = wethRequestkey;

        emit InstantDeposit(msg.sender, _amount);
    }

    /**
     * @notice
     *  deposit `_amount` of `glp` and issue `snGlp` as a share
     *  This function should not be executed while a deposit or withdrawal is in progress
     * @param _amount the quantity of tokens to deposit
     */
    function instantDepositGlp(uint256 _amount) external payable whenNotPaused initialValidate {
        require(msg.value >= executionFee * 2, "not enough execution fee");

        IStrategyVault(strategyVault).harvest();

        _checkLastFundingTime();
        _setPendingStatus(true);

        IStakedGlp(stakedGlp).transferFrom(msg.sender, address(this), _amount);

        uint256 valueInUsdg = IGmxHelper(gmxHelper).getLongValueInUsdg(_amount);
        uint256 redemptionAmount = IGmxHelper(gmxHelper).getRedemptionAmount(want, valueInUsdg);
        require(redemptionAmount > 0);
        
        (, uint256 wbtcAmountIn, uint256 wethAmountIn) = getDepositParams(redemptionAmount);

        uint256 unstakeGlpAmount = _amount * (wbtcAmountIn + wethAmountIn) / redemptionAmount;
        
        uint256 amountOut = IStrategyVault(strategyVault).sellGlp(unstakeGlpAmount, address(this));

        uint256 wbtcAmountInAfterFee = amountOut * wbtcAmountIn / (wbtcAmountIn + wethAmountIn);
        uint256 wethAmountInAfterFee = amountOut - wbtcAmountInAfterFee;

        (uint256 wbtcSizeDelta, uint256 wethSizeDelta) = IGmxHelper(gmxHelper).getTokenAumsPerAmount(_amount - unstakeGlpAmount, false);

        _validateMaxGlobalShortSize(wbtcSizeDelta, wethSizeDelta);

        IStakedGlp(stakedGlp).transfer(strategyVault, _amount - unstakeGlpAmount);

        _mintNeutraGlp(0x0);

        (bytes32 wbtcRequestKey, bytes32 wethRequestkey) = IStrategyVault(strategyVault).increaseShortPositionsWithCallback{value: executionFee * 2}(
            wbtcAmountInAfterFee,
            wbtcSizeDelta,
            wethAmountInAfterFee,
            wethSizeDelta,
            executionCallbackTarget
        );

        curWbtcRequestKey = wbtcRequestKey;
        curWethRequestKey = wethRequestkey;

        emit InstantDepositGlp(msg.sender, _amount);
    }

    /**
     * @notice
     *  burn `_amount` of share and redeem `token`
     *  This function should not be executed while a deposit or withdrawal is in progress
     * @param _amount the quantity of snGlp to redeem for `tokens`
     * @param _isStaked determines whether input is `snGlp` or `nGlp`
     * @param _withdrawGlp determines wheter output is `fsGlp` or `want`
     */
    function instantWithdraw(uint256 _amount, bool _isStaked, bool _withdrawGlp) external payable whenNotPaused initialValidate {
        require(msg.value >= executionFee * 4, "not enough execution fee");
        require(_amount >= MINIMUM_WITHDRAWL, "insufficient _amount");

        // should harvest first in order to withdraw managementFee before withdraw action
        IStrategyVault(strategyVault).harvest();

        _checkLastFundingTime();
        _setPendingStatus(false);

        if (_isStaked) {
            IRewardTracker(snGlp).unstakeForAccount(msg.sender, fnGlp, _amount, msg.sender);
            IRewardTracker(fnGlp).unstakeForAccount(msg.sender, nGlp, _amount, address(this));
        }

        uint256 totalSupply = IERC20(nGlp).totalSupply();

        (uint256 wbtcSizeDelta, uint256 wbtcCollateralDelta, bool shouldRepayWbtc) = getWithdrawParams(_amount, totalSupply, wbtc);
        (uint256 wethSizeDelta, uint256 wethCollateralDelta, bool shouldRepayWeth) = getWithdrawParams(_amount, totalSupply, weth);

        if (shouldRepayWbtc || shouldRepayWeth){
            _validatePositionQueue();
        }

        uint256 totalBalance = IERC20(fsGlp).balanceOf(strategyVault);
        uint256 unstakeGlpAmount = totalBalance * _amount / totalSupply;

        if (_withdrawGlp) {
            _validateMaxGlpAmountIn(wbtcCollateralDelta + wethCollateralDelta);
            IStakedGlp(stakedGlp).transferFrom(strategyVault, address(this), unstakeGlpAmount);
            pendingStatus.withdrawGlp = true;
        } else {
            IStrategyVault(strategyVault).sellGlp(unstakeGlpAmount, address(this));
        }

        _burnNeutraGlp();

        if (shouldRepayWbtc) {
            IStrategyVault(strategyVault).instantRepayFundingFee{value: executionFee}(wbtc, repayCallbackTarget);
        }

        if (shouldRepayWeth) {
            IStrategyVault(strategyVault).instantRepayFundingFee{value: executionFee}(weth, repayCallbackTarget);
        }

        (bytes32 wbtcRequestKey, bytes32 wethRequestkey) = IStrategyVault(strategyVault).decreaseShortPositionsWithCallback{value: executionFee * 2}(
            wbtcCollateralDelta, 
            wbtcSizeDelta, 
            wethCollateralDelta, 
            wethSizeDelta,
            shouldRepayWbtc,
            shouldRepayWeth, 
            address(this), 
            executionCallbackTarget
        );

        curWbtcRequestKey = wbtcRequestKey;
        curWethRequestKey = wethRequestkey;

        payable(msg.sender).transfer(address(this).balance);

        emit InstantWithdraw(msg.sender, _amount);
    }

    /**
     * @notice
     *  deposit/withdraw function only requests for creating positions
     *  actual positions are executed by the keeper of GMX
     *  two positions are always executed (BTC, ETH)
     *  this function is executed when the first asset of a position is successfully executed
     * @param _isIncrease determines whether it is an `increase` or `decrease` position
     * @param _requestKey a unique 256-bit hash by concatenating and hashing account and index from GMX
     */
    function firstCallback(bool _isIncrease, bytes32 _requestKey) public {
        require(msg.sender == executionCallbackTarget, "invalid msg.sender");
        
        if (_isIncrease) {
            _mintNeutraGlp(_requestKey);
        } else {
            _burnNeutraGlp();
        }

        pendingStatus.fisrtCallbackExecuted = true;
        emit FirstCallback(pendingStatus.recipient, _isIncrease);
    }

    /**
     * @notice
     *  deposit/withdraw function only requests for creating positions
     *  actual positions are executed by the keeper of GMX
     *  two positions are always executed (BTC, ETH)
     *  this function is executed when the second asset of a position is successfully executed
     * @param _isIncrease determines whether it is an `increase` or `decrease` position
     * @param _requestKey a unique 256-bit hash by concatenating and hashing account and index from GMX
     */
    function secondCallback(bool _isIncrease, bytes32 _requestKey) public {
        require(msg.sender == executionCallbackTarget, "invalid msg.sender");
        IStrategyVault _vault = IStrategyVault(strategyVault);

        _vault.confirmCallback();

        address recipient = pendingStatus.recipient;

        if (_isIncrease) {
            _mintNeutraGlp(_requestKey);

            IRewardTracker(fnGlp).stakeForAccount(address(this), recipient, nGlp, cumulativeMintAmount);
            IRewardTracker(snGlp).stakeForAccount(recipient, recipient, fnGlp, cumulativeMintAmount);

            cumulativeMintAmount = 0;
        } else {
            uint256 remainingAmount = IERC20(nGlp).balanceOf(address(this));
            IMintable(nGlp).burn(address(this), remainingAmount);

            uint256 balance = IERC20(want).balanceOf(address(this));

            if(pendingStatus.withdrawGlp) {
                IRewardRouter(glpRewardRouter).mintAndStakeGlp(want, balance, 0, 0);
                IStakedGlp(stakedGlp).transfer(recipient, IERC20(fsGlp).balanceOf(address(this)));
                pendingStatus.withdrawGlp = false;
            } else {
                IERC20(want).transfer(recipient, balance);
            }
            
            cumulativeBurnAmount = 0;
        }

        _clearPendingStatus(_isIncrease);

        emit SecondCallback(recipient, _isIncrease);
    }

    function getDepositParams(uint256 _amount) public view returns (uint256, uint256, uint256) {
        uint256 glpAmountIn; // want decimals
        uint256 wbtcAmountIn; // want decimals
        uint256 wethAmountIn; // want decimals

        IGmxHelper _gmxHelper = IGmxHelper(gmxHelper);
        uint256 totalAum = _gmxHelper.getAum(false);

        address[] memory tokens = new address[](2);
        tokens[0] = wbtc;
        tokens[1] = weth;
        uint256[] memory aums = _gmxHelper.getTokenAums(tokens, false);

        uint256 wbtcRatio = (aums[0] * MAX_BPS) / totalAum;
        uint256 wethRatio = (aums[1] * MAX_BPS) / totalAum;


        glpAmountIn = _amount * targetLeverage / (wbtcRatio + wethRatio + targetLeverage);

        uint256 remainingAmount = _amount - glpAmountIn;
        wbtcAmountIn = remainingAmount * wbtcRatio / (wbtcRatio + wethRatio);
        wethAmountIn = remainingAmount - wbtcAmountIn;
        
        return (glpAmountIn, wbtcAmountIn, wethAmountIn);
    }

    function getWithdrawParams(uint256 _amount, uint256 _totalSupply, address _indexToken) public view returns (uint256, uint256, bool) {        
        PositionParams memory positionParam = getPositionParams(strategyVault, _indexToken);
        ProfitParams memory profitParam = getProfitParams(_indexToken, positionParam.size, positionParam.avgPrice);

        uint256 sizeDelta = positionParam.size * _amount / _totalSupply;

        // compare sum of positionFee and fudningFee with the value of usdOut
        // to determine the fees will be deducted from position.collateral or usdOut
        uint256 usdOut = profitParam.hasProfit ? sizeDelta * profitParam.pnl / positionParam.size : 0;
        uint256 positionFee = sizeDelta * marginFeeBasisPoints / MAX_BPS;
        uint256 fundingFee = IGmxHelper(gmxHelper).getFundingFee(strategyVault, _indexToken);

        if(!profitParam.hasProfit) {
            uint256 collateralDelta = (positionParam.collateral - profitParam.pnl) * _amount / _totalSupply;
            bool shouldRepay = fundingFee + positionFee > usdOut + collateralDelta;
            return (sizeDelta, collateralDelta, shouldRepay);
        }

        uint256 collateralDelta = positionParam.collateral * _amount / _totalSupply;
        bool shouldRepay = fundingFee + positionFee > usdOut + collateralDelta;
        return (sizeDelta, collateralDelta, shouldRepay);
    }

    function getPositionParams(address _account, address _indexToken) public view returns (PositionParams memory) {
        IGmxHelper _gmxHelper = IGmxHelper(gmxHelper);
        (uint256 size, uint256 collateral, uint256 avgPrice,,,,,) = _gmxHelper.getPosition(_account, _indexToken);
        return PositionParams(size, collateral, avgPrice);
    }

    function getProfitParams(address _indexToken, uint256 _size, uint256 _avgPrice) public view returns (ProfitParams memory) {
        IGmxHelper _gmxHelper = IGmxHelper(gmxHelper);
        (bool hasProfit, uint256 pnl) = _gmxHelper.getDelta(_indexToken, _size, _avgPrice);
        return ProfitParams(hasProfit, pnl);    
    }

    function _mintNeutraGlp(bytes32 _key) internal {
        IGmxHelper _gmxHelper = IGmxHelper(gmxHelper);

        uint256 increasedValue;
        uint256 mintAmount;

        if(_key == 0x0) {
            uint256 currentValue = _gmxHelper.getLongValue(IERC20(fsGlp).balanceOf(strategyVault));
            increasedValue = currentValue - pendingStatus.longValueBefore;

            mintAmount = increasedValue * pendingStatus.totalSupplyBefore / pendingStatus.totalValueBefore;

            IMintable(nGlp).mint(address(this), mintAmount);
            cumulativeMintAmount = mintAmount;
            return;
        }

        if (_key == curWbtcRequestKey) {
            (,uint256 collateral,,,,,,) = _gmxHelper.getPosition(strategyVault, wbtc);
            increasedValue = collateral - pendingStatus.wbtcCollateralBefore;
            
            mintAmount = increasedValue * pendingStatus.totalSupplyBefore / pendingStatus.totalValueBefore;

            IMintable(nGlp).mint(address(this), mintAmount);
            cumulativeMintAmount += mintAmount;
            return;
        }

        if (_key == curWethRequestKey) {
            (,uint256 collateral,,,,,,) = _gmxHelper.getPosition(strategyVault, weth);
            increasedValue = collateral - pendingStatus.wethCollateralBefore;

            mintAmount = increasedValue * pendingStatus.totalSupplyBefore / pendingStatus.totalValueBefore;

            IMintable(nGlp).mint(address(this), mintAmount);
            cumulativeMintAmount += mintAmount;
            return;
        } 
    }

    function _burnNeutraGlp() internal {
        uint256 totalValue = IStrategyVault(strategyVault).totalValue();
        uint256 totalValueBefore = pendingStatus.totalValueBefore;
        uint256 decreasedValue = totalValueBefore < totalValue ? 0 : totalValueBefore - totalValue;
        uint256 burnAmount = decreasedValue * pendingStatus.totalSupplyBefore / totalValueBefore;

        IMintable(nGlp).burn(address(this), burnAmount - cumulativeBurnAmount);

        cumulativeBurnAmount = burnAmount;
    }

    function _checkLastFundingTime() internal {
        uint256 lastFundingTime = IGmxHelper(gmxHelper).getLastFundingTime();
        if (lastFundingTime + 3600 <= block.timestamp) {
            IVault(gmxVault).updateCumulativeFundingRate(want);
        }
    }

    function _validateMaxGlobalShortSize(uint256 _wbtcSizeDelta, uint256 _wethSizeDelta) internal {
        IGmxHelper _gmxHelper = IGmxHelper(gmxHelper);

        uint256 wbtcAvailableSize = _gmxHelper.getAvailableShortSize(wbtc);
        require(wbtcAvailableSize > _wbtcSizeDelta + shortBuffers[wbtc], "OI limit passed");

        uint256 wethAvailableSize = _gmxHelper.getAvailableShortSize(weth);
        require(wethAvailableSize > _wethSizeDelta + shortBuffers[weth], "OI limit passed");
    }

    function _validateMaxGlpAmountIn(uint256 _collateralDelta) internal {
        uint256 amount = IStrategyVault(strategyVault).usdToTokenMax(want, _collateralDelta, true);
        uint256 usdgAmount = IGmxHelper(gmxHelper).adjustDecimalsToUsdg(amount, want);
        uint256 availableUsdgAmount = IGmxHelper(gmxHelper).getAvailableGlpAmountIn(want);
        require(availableUsdgAmount > usdgAmount, "max usdgAmount exceeded");
    }

    // GMX keeper keeps track of queue of pending increase and decrease orders. 
    // for each order type it executes at most N orders per transaction. 
    // meaning if there are more than N increase orders to execute and your order is N + 1
    // then it will be executed after first N decrease orders
    // if both queues are empty (or increase queue is empty)
    // increase positions should be always executed first
    function _validatePositionQueue() internal {
        (
            uint256 increasePositionRequestKeysStart, 
            uint256 increasePositionRequestKeysLength,,
        ) = IGmxHelper(gmxHelper).getRequestQueueLengths();

        require(increasePositionRequestKeysStart >= increasePositionRequestKeysLength, "queue is not empty");
    }

    function _setPendingStatus(bool _isIncrease) internal {
        IGmxHelper _gmxHelper = IGmxHelper(gmxHelper);
        pendingStatus.isProgress = true;
        pendingStatus.recipient = msg.sender;
        pendingStatus.totalValueBefore = IStrategyVault(strategyVault).totalValue();
        pendingStatus.totalSupplyBefore = IERC20(nGlp).totalSupply();

        if (_isIncrease) {
            pendingStatus.longValueBefore = _gmxHelper.getLongValue(IERC20(fsGlp).balanceOf(strategyVault));
            (,uint256 wbtcCollateral,,,,,,) = _gmxHelper.getPosition(strategyVault, wbtc);
            (,uint256 wethCollateral,,,,,,) = _gmxHelper.getPosition(strategyVault, weth);
            pendingStatus.wbtcCollateralBefore = wbtcCollateral;
            pendingStatus.wethCollateralBefore = wethCollateral;
        }
    }

    function _clearPendingStatus(bool _isIncrease) internal {
        pendingStatus.isProgress = false;
        pendingStatus.recipient = address(0);
        pendingStatus.fisrtCallbackExecuted = false;
        pendingStatus.totalValueBefore = 0;
        pendingStatus.totalSupplyBefore = 0;

        if (_isIncrease) {
            pendingStatus.longValueBefore = 0;
            pendingStatus.wbtcCollateralBefore = 0;
            pendingStatus.wethCollateralBefore = 0;
        }
    }

    function _initialValidate() internal {
        require(!pendingStatus.isProgress, "in the middle of progress");
        require(block.timestamp % 3600 <= 3480, "try a bit later");
    }

    function failCallback(bool _isIncrease) external {
        require(msg.sender == executionCallbackTarget || msg.sender == repayCallbackTarget, "invalid msg.sender");

        isExecutionFailed = true;

        bool isRepay;
        if (msg.sender == repayCallbackTarget) {
            isRepay = true;
        }

        emit ExecutionFailed(pendingStatus.recipient, pendingStatus.fisrtCallbackExecuted, _isIncrease, isRepay);
    }

    function handleFailure(uint256 _wantAmount, uint256 _glpAmount) external onlyGov {
        require(isExecutionFailed, "execution not failed");

        if (_wantAmount > 0) {
            uint256 balance = IERC20(want).balanceOf(strategyVault);
            uint256 feeReserves = IStrategyVault(strategyVault).feeReserves();
            require(_wantAmount <= balance - feeReserves, "exceeded transferableAmouont"); 

            IERC20(want).transferFrom(strategyVault, pendingStatus.recipient, _wantAmount);
        }

        if (_glpAmount > 0) {
            IStakedGlp(stakedGlp).transferFrom(strategyVault, pendingStatus.recipient, _glpAmount);
        }

        bool isIncrease;
        if (cumulativeBurnAmount == 0) {
            isIncrease = true;
        }

        _clearPendingStatus(isIncrease);

        isExecutionFailed = false;
    }

    function setCallbackTargets(address _executionCallbackTarget, address _repayCallbackTarget) external onlyGov {
        executionCallbackTarget = _executionCallbackTarget;
        repayCallbackTarget = _repayCallbackTarget;
        emit SetCallbackTargets(_executionCallbackTarget, _repayCallbackTarget);
    }

    function setExecutionFee(uint256 _fee) external onlyGov {
        executionFee = _fee;
        emit SetExecutionFee(_fee);
    }

    function setTargetLeverage(uint256 _lev) external onlyGov {
        targetLeverage = _lev;
        emit SetTargetLeverage(_lev);
    }

    function setMarginFeeBasisPoints(uint256 _bps) external onlyGov {
        marginFeeBasisPoints = _bps;
        emit SetMarginFeeBasisPoints(_bps);
    }

    function setShortBuffers(uint256 _wbtcBuffer, uint256 _wethBuffer) external onlyGov {
        shortBuffers[wbtc] = _wbtcBuffer;
        shortBuffers[weth] = _wethBuffer;
        emit SetShortBuffers(_wbtcBuffer, _wethBuffer);
    }

    function setGmxHelper(address _helper) external onlyGov {
        gmxHelper = _helper;
        emit SetGmxHelper(_helper);
    }

    function pause() external onlyGov {
        _pause();
    }

    function unpause() external onlyGov {
        _unpause();
    }
}