// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {IMintable} from "./interfaces/IMintable.sol";
import {IGlpManager} from "./interfaces/gmx/IGlpManager.sol";
import {IPositionRouter} from "./interfaces/gmx/IPositionRouter.sol";
import {IRewardRouter} from "./interfaces/gmx/IRewardRouter.sol";
import {IReferralStorage} from "./interfaces/gmx/IReferralStorage.sol";
import {IGmxHelper} from "./interfaces/IGmxHelper.sol";
import {IRouter} from "./interfaces/gmx/IRouter.sol";

struct InitialConfig {
    address glpManager;
    address positionRouter;
    address rewardRouter;
    address glpRewardRouter;
    address router;
    address referralStorage;
    address fsGlp;
    address gmx;
    address sGmx;

    address want;
    address wbtc;
    address weth;
    address nGlp;
}

struct ConfirmList {
    //for withdraw
    bool hasDecrease;

    //for rebalance
    uint256 beforeWantBalance;
}

struct PendingPositionFeeInfo {
    uint256 fundingRate; // wbtc and weth should have the same fundingRate  
    uint256 wbtcFundingFee;
    uint256 wethFundingFee;
}

contract StrategyVault is Initializable, UUPSUpgradeable {
    uint256 constant SECS_PER_YEAR = 31_536_000;
    uint256 constant MAX_BPS = 10_000;
    uint256 constant PRECISION = 1e30;
    uint256 constant MAX_MANAGEMENT_FEE = 500_000_000;
    uint256 constant MANAGEMENT_FEE_BPS = 10_000_000_000;

    bool public confirmed;
    bool public initialDeposit;
    bool public exited;
    
    bytes32 public referralCode;

    uint256 public executionFee;

    uint256 public lastCollect; // block.timestamp of last collect
    uint256 public managementFee; 

    uint256 public insuranceFund;
    uint256 public feeReserves;
    uint256 public prepaidGmxFee;

    // gmx 
    uint256 public marginFeeBasisPoints;

    // fundingFee can be unpaid if requests position before funding rate increases 
    // and then position gets executed after funding rate increases 
    mapping(address => uint256) public unpaidFundingFee;

    ConfirmList public confirmList;
    PendingPositionFeeInfo public pendingPositionFeeInfo;

    address public gov;
    // deposit token
    address public want;
    address public wbtc;
    address public weth;
    address public nGlp;
    address public gmxHelper;
    address public management;

    // GMX interfaces
    address public glpManager;
    address public positionRouter;
    address public rewardRouter;
    address public glpRewardRouter;
    address public gmxRouter;
    address public referralStorage;
    address public fsGlp;
    address public callbackTarget;

    mapping(address => bool) public routers;
    mapping(address => bool) public keepers;

    uint256 pendingShortValue;

    event RebalanceActions(uint256 timestamp, bool isBuy, bool hasWbtcIncrease, bool hasWbtcDecrease, bool hasWethIncrease, bool hasWethDecrease);
    event BuyNeuGlp(uint256 amountIn, uint256 amountOut, uint256 value);
    event SellNeuGlp(uint256 amountIn, uint256 amountOut, address recipient);
    event ConfirmRebalance(bool hasDebt, uint256 delta, uint256 prepaidGmxFee);
    event Harvest(uint256 amountOut, uint256 feeReserves);
    event CollectManagementFee(uint256 alpha, uint256 lastCollect);
    event RepayFundingFee(uint256 wbtcFundingFee, uint256 wethFundingFee, uint256 prepaidGmxFee);
    event DepositInsuranceFund(uint256 amount, uint256 insuranceFund);
    event BuyGlp(uint256 amount);
    event SellGlp(uint256 amount, address recipient);
    event IncreaseShortPosition(address _indexToken, uint256 _amountIn, uint256 _sizeDelta);
    event DecreaseShortPosition(address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, address _recipient);
    event RepayUnpaidFundingFee(uint256 unpaidFundingFeeWbtc, uint256 unpaidFundingFeeWeth);
    event WithdrawFees(uint256 amount, address receiver);
    event WithdrawInsuranceFund(uint256 amount, address receiver);
    event Settle(uint256 amountIn, uint256 amountOut, address recipient);
    event SetGov(address gov);
    event SetGmxHelper(address helper);
    event SetKeeper(address keeper, bool isActive);
    event SetWant(address want);
    event SetExecutionFee(uint256 fee);
    event SetCallbackTarget(address callbackTarget);
    event SetRouter(address router, bool isActive);
    event SetManagement(address management, uint256 fee);
    event WithdrawEth(uint256 amount);
    event ConfirmFundingRates(uint256 lastUpdatedFundingRate, uint256 wbtcFundingRate, uint256 wethFundingRate);
    event AdjustPrepaidGmxFee(uint256 adjustAmount, uint256 prepaidGmxFee);
    event ConfirmFundingFees(uint256 wbtcFundingFee, uint256 pendingPositionFeeInfo, uint256 prepaidGmxFee);

    modifier onlyGov() {
        _onlyGov();
        _;
    }

    modifier onlyKeepersAndAbove() {
        _onlyKeepersAndAbove();
        _;
    }

    modifier onlyRouter() {
        _onlyRouter();
        _;
    }

    function initialize(InitialConfig memory _config) public initializer {
        glpManager = _config.glpManager;
        positionRouter = _config.positionRouter;
        rewardRouter = _config.rewardRouter;
        glpRewardRouter = _config.glpRewardRouter;
        gmxRouter = _config.router;
        referralStorage = _config.referralStorage;
        fsGlp = _config.fsGlp;

        want = _config.want;
        wbtc = _config.wbtc;
        weth = _config.weth;
        nGlp = _config.nGlp;
        gov = msg.sender;
        executionFee = 100000000000000;
        marginFeeBasisPoints = 10;
        confirmed = true;

        IERC20(want).approve(glpManager, type(uint256).max);
        IERC20(want).approve(gmxRouter, type(uint256).max);
        IRouter(gmxRouter).approvePlugin(positionRouter);
        IERC20(_config.gmx).approve(_config.sGmx, type(uint256).max);
        IERC20(weth).approve(gmxRouter, type(uint256).max);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyGov {}

    function _onlyGov() internal view {
        require(msg.sender == gov, "StrategyVault: not authorized");
    }

    function _onlyKeepersAndAbove() internal view {
        require(keepers[msg.sender] || routers[msg.sender] || msg.sender == gov, "StrategyVault: not keepers");
    }

    function _onlyRouter() internal view {
        require(routers[msg.sender], "StrategyVault: not router");
    }

    /// @dev rebalance init function
    function minimiseDeltaWithBuyGlp(bytes4[] calldata _selectors, bytes[] calldata _params) external payable onlyKeepersAndAbove {
        require(confirmed, "StrategyVault: not confirmed yet");
        require(!exited, "StrategyVault: strategy already exited");
        uint256 length = _selectors.length;
        require(msg.value >= executionFee * (length - 1), "StrategyVault: not enough execution fee");
        IGmxHelper _gmxHelper = IGmxHelper(gmxHelper);
        
        _updatePendingPositionFundingRate();

        _harvest();
        
        bool hasWbtcIncrease;
        bool hasWbtcDecrease;
        bool hasWethIncrease;
        bool hasWethDecrease;
        // save current balance of want to track debt cost after rebalance; 
        confirmList.beforeWantBalance = IERC20(want).balanceOf(address(this));

        for(uint256 i=0; i<length; i++) {
            bytes4 selector = _selectors[i];
            bytes memory param = _params[i];
            if (i == 0) {
                require(selector == this.buyGlp.selector, "StrategyVault: should buy glp first");
                
                uint256 amount = abi.decode(param, (uint256));
                if (amount == 0) { continue; }
                
                buyGlp(amount);
                continue;
            } 
            
            if (i == 1 || i == 2) {
                require(selector == this.increaseShortPosition.selector, "StrategyVault: should increase position");
                (address indexToken, uint256 amountIn, uint256 sizeDelta) = abi.decode(_params[i], (address, uint256, uint256));

                uint256 fundingFee = _gmxHelper.getFundingFee(address(this), indexToken); // 30 decimals
                fundingFee = usdToTokenMax(want, fundingFee, true);
                if (indexToken == wbtc) {
                    pendingPositionFeeInfo.wbtcFundingFee = fundingFee;
                    hasWbtcIncrease = true;
                } else {
                    pendingPositionFeeInfo.wethFundingFee = fundingFee;
                    hasWethIncrease = true;
                }
                // add additional funding fee here to save execution fee
                increaseShortPosition(indexToken, amountIn + fundingFee, sizeDelta);
                continue;
            }

            // call remainig actions should be decrease action
            (address indexToken, uint256 collateralDelta, uint256 sizeDelta, address recipient) = abi.decode(param, (address, uint256, uint256, address));

            if (indexToken == wbtc) {
                hasWbtcDecrease = true;
            } else {
                hasWethDecrease = true;
            }

            decreaseShortPosition(indexToken, collateralDelta, sizeDelta, recipient);
        }

        _requireConfirm();

        emit RebalanceActions(block.timestamp, true, hasWbtcIncrease, hasWbtcDecrease, hasWethIncrease, hasWethDecrease);
    }

    /// @dev rebalance init function
    function minimiseDeltaWithSellGlp(bytes4[] calldata _selectors, bytes[] calldata _params) external payable onlyKeepersAndAbove {
        require(confirmed, "StrategyVault: not confirmed yet");
        require(!exited, "StrategyVault: strategy already exited");
        uint256 length = _selectors.length;
        require(msg.value >= executionFee * (length - 1), "StrategyVault: not enough execution fee");
        IGmxHelper _gmxHelper = IGmxHelper(gmxHelper);
        
        _updatePendingPositionFundingRate();

        _harvest();
        
        bool hasWbtcIncrease;
        bool hasWbtcDecrease;
        bool hasWethIncrease;
        bool hasWethDecrease;
        // save current balance of want to track debt cost after rebalance; 
        confirmList.beforeWantBalance = IERC20(want).balanceOf(address(this));

        for(uint256 i=0; i<length; i++){
            bytes4 selector = _selectors[i];
            bytes memory param = _params[i];
            if(i == 0) {
                require(selector == this.sellGlp.selector, "StrategyVault: should sell glp first");

                (uint256 amount, address recipient) = abi.decode(param, (uint256, address));
                if (amount == 0) { continue; }

                sellGlp(amount, recipient);
                continue;
            }

            if(i==1 || i == 2) {
                require(selector == this.increaseShortPosition.selector, "StrategyVault: should increase position");
                (address indexToken, uint256 amountIn, uint256 sizeDelta) = abi.decode(_params[i], (address, uint256, uint256));

                uint256 fundingFee = _gmxHelper.getFundingFee(address(this), indexToken); // 30 decimals
                fundingFee = usdToTokenMax(want, fundingFee, true);

                if (indexToken == wbtc) {
                    pendingPositionFeeInfo.wbtcFundingFee = fundingFee;
                    hasWbtcIncrease = true;
                } else {
                    pendingPositionFeeInfo.wethFundingFee = fundingFee;
                    hasWethIncrease = true;
                }
                // add additional funding fee here to save execution fee
                increaseShortPosition(indexToken, amountIn + fundingFee, sizeDelta);
                continue;
            }

            // remainig actions should be decrease action
            (address indexToken, uint256 collateralDelta, uint256 sizeDelta, address recipient) = abi.decode(param, (address, uint256, uint256, address));
            
            if (indexToken == wbtc) {
                hasWbtcDecrease = true;
            } else {
                hasWethDecrease = true;
            }

            decreaseShortPosition(indexToken, collateralDelta, sizeDelta, recipient);
        }

        _requireConfirm();

        emit RebalanceActions(block.timestamp, false, hasWbtcIncrease, hasWbtcDecrease, hasWethIncrease, hasWethDecrease);
    }
    
    /// depreacted
    /// @dev deposit init function 
    /// execute wbtc, weth increase positions
    function executeIncreasePositions(bytes[] calldata _params) external payable onlyRouter {
    }

    /// deprecated
    /// @dev withdraw init function
    /// execute wbtc, weth decrease positions
    function executeDecreasePositions(bytes[] calldata _params) external payable onlyRouter {
    }
    
    /// deprecated
    /// @dev should be called only if positions execution had been failed
    function retryPositions(bytes4[] calldata _selectors, bytes[] calldata _params) external payable onlyKeepersAndAbove {
    }

    /// deprecated
    function buyNeuGlp(uint256 _amountIn) external onlyRouter returns (uint256) {
    }

    /// deprecated
    function sellNeuGlp(uint256 _glpAmount, address _recipient) external onlyRouter returns (uint256) {
    }

    /// deprecated
    // confirm for deposit & withdraw
    function confirm() external onlyRouter {
    }

    // confirm for rebalance
    function confirmRebalance() external onlyKeepersAndAbove {
        _confirm();

        uint256 currentBalance = IERC20(want).balanceOf(address(this));

        uint256 fundingFee = pendingPositionFeeInfo.wbtcFundingFee + pendingPositionFeeInfo.wethFundingFee;

        // fundingFee must be added in order to avoid double counting
        currentBalance += fundingFee; // want decimals

        bool hasDebt = currentBalance < confirmList.beforeWantBalance;
        uint256 delta = hasDebt ? confirmList.beforeWantBalance - currentBalance : currentBalance - confirmList.beforeWantBalance;

        if(hasDebt) {
            prepaidGmxFee = prepaidGmxFee + delta;
        } else {
            if (prepaidGmxFee > delta) {
                prepaidGmxFee -= delta;
            } else {
                feeReserves += delta - prepaidGmxFee;
                prepaidGmxFee = 0;
            }
        }

        confirmList.beforeWantBalance = 0;

        _clearPendingPositionFeeInfo();

        confirmed = true;

        emit ConfirmRebalance(hasDebt, delta, prepaidGmxFee);
    }

    function _confirm() internal {
        IGmxHelper _gmxHelper = IGmxHelper(gmxHelper);

        (,,,uint256 wbtcFundingRate,,,,) = _gmxHelper.getPosition(address(this), wbtc);
        (,,,uint256 wethFundingRate,,,,) = _gmxHelper.getPosition(address(this), weth);

        uint256 lastUpdatedFundingRate = pendingPositionFeeInfo.fundingRate;
        require(wbtcFundingRate >= lastUpdatedFundingRate && wethFundingRate >= lastUpdatedFundingRate, "StrategyVault: positions not executed");
        
        if (wbtcFundingRate > lastUpdatedFundingRate) {
            uint256 wbtcFundingFee = _gmxHelper.getFundingFeeWithRate(address(this), wbtc, lastUpdatedFundingRate); // 30 decimals
            unpaidFundingFee[wbtc] += usdToTokenMax(want, wbtcFundingFee, true);
        } 

        if (wethFundingRate > lastUpdatedFundingRate) {
            uint256 wethFundingFee = _gmxHelper.getFundingFeeWithRate(address(this), weth, lastUpdatedFundingRate); // 30 decimals
            unpaidFundingFee[weth] += usdToTokenMax(want, wethFundingFee, true);
        }
        
        uint256 fundingFee = pendingPositionFeeInfo.wbtcFundingFee + pendingPositionFeeInfo.wethFundingFee;

        prepaidGmxFee += fundingFee; // want decimals

        emit ConfirmFundingRates(lastUpdatedFundingRate, wbtcFundingRate, wethFundingRate);
        emit ConfirmFundingFees(pendingPositionFeeInfo.wbtcFundingFee, pendingPositionFeeInfo.wethFundingFee, prepaidGmxFee);
    }

    function harvest() external {
        _harvest();
    }

    function _harvest() internal {
        _collectManagementFee();

        IRewardRouter(rewardRouter).handleRewards(true, true, true, true, true, true, false);

        uint256 beforeWantBalance = IERC20(want).balanceOf(address(this));
        // this might include referral rewards 
        uint256 wethBalance = IERC20(weth).balanceOf(address(this));
        if (wethBalance > 0) {
            address[] memory path = new address[](2);
            path[0] = weth;
            path[1] = want;
            IRouter(gmxRouter).swap(path, wethBalance, 0, address(this));
        }
        uint256 amountOut = IERC20(want).balanceOf(address(this)) - beforeWantBalance;
        if (amountOut == 0) {
            return;
        }

        feeReserves += amountOut;

        emit Harvest(amountOut, feeReserves);

        return;
    }

    // (totalVaule) / (totalSupply + alpha) = (totalValue * (1-(managementFee * duration))) / totalSupply 
    // alpha = (totalSupply / (1-(managementFee * duration))) - totalSupply
    function _collectManagementFee() internal {
        uint256 _lastCollect = lastCollect;
        if (_lastCollect == 0) {
            return;
        }
        uint256 duration = block.timestamp - _lastCollect;
        uint256 supply = IERC20(nGlp).totalSupply() - IERC20(nGlp).balanceOf(management);
        uint256 alpha = supply * MANAGEMENT_FEE_BPS / (MANAGEMENT_FEE_BPS - (managementFee * duration / SECS_PER_YEAR)) - supply;
        if (alpha == 0) {
            return;
        }
        IMintable(nGlp).mint(management, alpha);
        lastCollect = block.timestamp;   

        emit CollectManagementFee(alpha, lastCollect);
    }

    function activateManagementFee() external onlyGov {
        lastCollect = block.timestamp;
    }

    function deactivateManagementFee() external onlyGov {
        lastCollect = 0;
    }

    /// @dev repaying funding fee requires execution fee
    /// @dev needs to call regularly by keepers
    function repayFundingFee() external payable onlyKeepersAndAbove {
        require(!exited, "StrategyVault: strategy already exited");
        require(msg.value >= executionFee * 2, "StrategyVault: not enough execution fee");

        _harvest();

        IGmxHelper _gmxHelper = IGmxHelper(gmxHelper);

        uint256 wbtcFundingFee = _gmxHelper.getFundingFee(address(this), wbtc); // 30 decimals
        wbtcFundingFee = usdToTokenMax(want, wbtcFundingFee, true);
        uint256 wethFundingFee = _gmxHelper.getFundingFee(address(this), weth);
        wethFundingFee = usdToTokenMax(want, wethFundingFee, true);
        
        uint256 balance = IERC20(want).balanceOf(address(this));
        require(wethFundingFee + wbtcFundingFee <= balance, "StrategyVault: not enough balance to repay");

        if (wbtcFundingFee > 0) {
            increaseShortPosition(wbtc, wbtcFundingFee, 0);
        }

        if (wethFundingFee > 0) {
            increaseShortPosition(weth, wethFundingFee, 0);
        }

        prepaidGmxFee = prepaidGmxFee + wbtcFundingFee + wethFundingFee;

        emit RepayFundingFee(wbtcFundingFee, wethFundingFee, prepaidGmxFee);
    }

    function exitStrategy() external payable onlyGov {
        require(!exited, "StrategyVault: strategy already exited");
        require(confirmed, "StrategyVault: not confirmed yet");
        IGmxHelper _gmxHelper = IGmxHelper(gmxHelper);

        _harvest();

        sellGlp(IERC20(fsGlp).balanceOf(address(this)), address(this));

        (uint256 wbtcSize,,,,,,,) = _gmxHelper.getPosition(address(this), wbtc);
        (uint256 wethSize,,,,,,,) = _gmxHelper.getPosition(address(this), weth);

        decreaseShortPosition(wbtc, 0, wbtcSize, msg.sender);
        decreaseShortPosition(weth, 0, wethSize, msg.sender);

        exited = true;
    }

    // executed only if strategy exited
    // make sure to withdraw insuranceFund and withdraw fees beforehand
    function settle(uint256 _amount, address _recipient) external onlyRouter {
        require(exited, "StrategyVault: strategy not exited yet");
        uint256 value = _totalValue();
        uint256 supply = IERC20(nGlp).totalSupply();
        uint256 amountOut = value * _amount / supply;
        IERC20(want).transfer(_recipient, amountOut);
        emit Settle(_amount, amountOut, _recipient);
    }

    function _updatePendingPositionFundingRate() internal {
        uint256 cumulativeFundingRate = IGmxHelper(gmxHelper).getCumulativeFundingRates(want);
        pendingPositionFeeInfo.fundingRate = cumulativeFundingRate;
    }

    function _requireConfirm() internal {
        confirmed = false;
    }

    function _clearPendingPositionFeeInfo() internal {
        pendingPositionFeeInfo.fundingRate = 0;
        pendingPositionFeeInfo.wbtcFundingFee = 0;
        pendingPositionFeeInfo.wethFundingFee = 0;
    }

    function depositInsuranceFund(uint256 _amount) public onlyGov {
        IERC20(want).transferFrom(msg.sender, address(this), _amount);
        insuranceFund += _amount;

        emit DepositInsuranceFund(_amount, insuranceFund);
    }

    function buyGlp(uint256 _amount) public onlyKeepersAndAbove returns (uint256) {
        emit BuyGlp(_amount);
        return IRewardRouter(glpRewardRouter).mintAndStakeGlp(want, _amount, 0, 0);
    }

    function sellGlp(uint256 _amount, address _recipient) public onlyKeepersAndAbove returns (uint256) {
        emit SellGlp(_amount, _recipient);
        return IRewardRouter(glpRewardRouter).unstakeAndRedeemGlp(want, _amount, 0, _recipient);
    }

    function increaseShortPosition(
        address _indexToken,
        uint256 _amountIn,
        uint256 _sizeDelta
    ) public payable onlyKeepersAndAbove {
        require(IGmxHelper(gmxHelper).validateMaxGlobalShortSize(_indexToken, _sizeDelta), "StrategyVault: max global shorts exceeded");

        address[] memory path = new address[](1);
        path[0] = want;

        IPositionRouter(positionRouter).createIncreasePosition{value: executionFee}(
            path,
            _indexToken,
            _amountIn,
            0, // minOut
            _sizeDelta,
            false,
            0, // acceptablePrice
            executionFee,
            referralCode,
            callbackTarget
        );

        emit IncreaseShortPosition(_indexToken, _amountIn, _sizeDelta);
    }

    function decreaseShortPosition(
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        address _recipient
    ) public payable onlyKeepersAndAbove {
        address[] memory path = new address[](1);
        path[0] = want;

        IPositionRouter(positionRouter).createDecreasePosition{value: executionFee}(
            path,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            false,
            _recipient,
            type(uint256).max, // acceptablePrice
            0,
            executionFee,
            false,
            callbackTarget
        );

        emit DecreaseShortPosition(_indexToken, _collateralDelta, _sizeDelta, _recipient);
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "StrategyVault: invalid address");
        gov = _gov;
        emit SetGov(_gov);
    }

    function setGmxHelper(address _helper) external onlyGov {
        require(_helper != address(0), "StrategyVault: invalid address");
        gmxHelper = _helper;
        emit SetGmxHelper(_helper);
    }

    function setMarginFeeBasisPoints(uint256 _bps) external onlyGov {
        marginFeeBasisPoints = _bps;
    }

    function setKeeper(address _keeper, bool _isActive) external onlyGov {
        require(_keeper != address(0), "StrategyVault: invalid address");
        keepers[_keeper] = _isActive;
        emit SetKeeper(_keeper, _isActive);
    }

    function setWant(address _want) external onlyGov {
        IERC20(want).approve(glpManager, 0);
        IERC20(want).approve(gmxRouter, 0);
        want = _want;
        IERC20(_want).approve(glpManager, type(uint256).max);
        IERC20(_want).approve(gmxRouter, type(uint256).max);
        emit SetWant(_want);
    }

    function setExecutionFee(uint256 _executionFee) external onlyGov {
        require(_executionFee > IPositionRouter(positionRouter).minExecutionFee(), "StrategyVault: execution fee needs to be set higher");
        executionFee = _executionFee;
        emit SetExecutionFee(_executionFee);
    }

    function setCallbackTarget(address _callbackTarget) external onlyGov {
        callbackTarget = _callbackTarget;
        emit SetCallbackTarget(_callbackTarget);
    }

    function setRouter(address _router, bool _isActive) external onlyGov {
        require(_router != address(0), "StrategyVault: invalid address");
        routers[_router] = _isActive;
        emit SetRouter(_router, _isActive);
    }

    function setManagement(address _management, uint256 _fee) external onlyGov {
        require(_management != address(0), "StrategyVault: invalid address");
        require(MAX_MANAGEMENT_FEE >= _fee, "StrategyVault: max fee exceeded");
        management = _management;
        managementFee =_fee;
        emit SetManagement(_management, _fee);
    }

    function registerAndSetReferralCode(string memory _text) public onlyGov {
        bytes32 stringToByte32 = bytes32(bytes(_text));

        IReferralStorage(referralStorage).registerCode(stringToByte32);
        IReferralStorage(referralStorage).setTraderReferralCodeByUser(stringToByte32);
        referralCode = stringToByte32;
    }

    function totalValue() external view returns (uint256) {
        return _totalValue();
    }

    function _totalValue() internal view returns (uint256) {
        return exited ? IERC20(want).balanceOf(address(this)) : IGmxHelper(gmxHelper).totalValue(address(this));
    }

    function repayUnpaidFundingFee() external payable onlyKeepersAndAbove {
        require(!exited, "StrategyVault: strategy already exited");

        uint256 unpaidFundingFeeWbtc = unpaidFundingFee[wbtc];
        uint256 unpaidFundingFeeWeth = unpaidFundingFee[weth];

        if (unpaidFundingFeeWbtc > 0) {
            increaseShortPosition(wbtc, unpaidFundingFeeWbtc, 0);
            unpaidFundingFee[wbtc] = 0;
        }

        if (unpaidFundingFeeWeth > 0) {
            increaseShortPosition(weth, unpaidFundingFeeWeth, 0);
            unpaidFundingFee[weth] = 0;
        }

        emit RepayUnpaidFundingFee(unpaidFundingFeeWbtc, unpaidFundingFeeWeth);
    }

    function withdrawFees(address _receiver) external onlyGov returns (uint256) {
        _harvest();

        if (prepaidGmxFee >= feeReserves) {
            feeReserves = 0;
            prepaidGmxFee -= feeReserves;
            return 0;
        }

        uint256 amount = feeReserves - prepaidGmxFee;
        prepaidGmxFee = 0;
        feeReserves = 0;
        IERC20(want).transfer(_receiver, amount);

        emit WithdrawFees(amount, _receiver);

        return amount;
    }

    function withdrawInsuranceFund(address _receiver) external onlyGov returns (uint256) {
        uint256 curBalance = IERC20(want).balanceOf(address(this));
        uint256 amount = insuranceFund >= curBalance ? curBalance : insuranceFund;
        insuranceFund -= amount;
        IERC20(want).transfer(_receiver, amount);

        emit WithdrawInsuranceFund(amount, _receiver);

        return amount;
    }

    // rescue execution fee
    function withdrawEth() external payable onlyGov {
        payable(msg.sender).transfer(address(this).balance);
        emit WithdrawEth(address(this).balance);
    }

    function adjustPrepaidGmxFee(uint256 _amount) external onlyGov {
        prepaidGmxFee -= _amount;
        emit AdjustPrepaidGmxFee(_amount, prepaidGmxFee);
    }

    function tokenToUsdMin(address _token, uint256 _tokenAmount) public view returns(uint256) {
        if (_tokenAmount == 0) { return 0; }
        uint256 price = IGmxHelper(gmxHelper).getPrice(_token, false);
        uint256 decimals = IERC20(_token).decimals();
        return _tokenAmount * price / (10 ** decimals);
    }

    function usdToTokenMax(address _token, uint256 _usdAmount, bool _isCeil) public view returns(uint256) {
        if (_usdAmount == 0) { return 0; }
        uint256 price = IGmxHelper(gmxHelper).getPrice(_token, false);
        uint256 decimals = IERC20(_token).decimals();
        return _isCeil ? ceilDiv(_usdAmount * (10 ** decimals), price) : _usdAmount * (10 ** decimals) / price;
    }

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        // (a + b - 1) / b can overflow on addition, so we distribute.
        return a == 0 ? 0 : (a - 1) / b + 1;
    }
}
