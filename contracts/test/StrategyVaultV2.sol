// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC20} from "../interfaces/IERC20.sol";
import {IGlpManager} from "../interfaces/gmx/IGlpManager.sol";
import {IPositionRouter} from "../interfaces/gmx/IPositionRouter.sol";
import {IRewardRouter} from "../interfaces/gmx/IRewardRouter.sol";
import {IReferralStorage} from "../interfaces/gmx/IReferralStorage.sol";
import {IGmxHelper} from "../interfaces/IGmxHelper.sol";

struct InitialConfig {
    address glpManager;
    address positionRouter;
    address rewardRouter;
    address router;
    address referralStorage;
    address fsGlp;
    address gmxHelper;
    address want;
    address wbtc;
    address weth;
}

contract StrategyVaultV2 is Initializable, UUPSUpgradeable {
    bool public executed;

    bytes32 public referralCode;

    uint256 public constant BASE_PRECISION = 10000000000;
    uint256 public constant MINIMUM_COLLATERAL = 10;
    uint256 public constant FEE_PRECISION = 10000;
    uint256 public marginFeeBasisPoints;
    uint256 public executionFee;
    uint256 public insuranceFund;
    uint256 public targetValue;

    address public gov;
    address public keeper;
    // deposit token
    address public want;
    address public wbtc;
    address public weth;
    address public gmxHelper;

    // GMX interfaces
    address public glpManager;
    address public positionRouter;
    address public rewardRouter;
    address public router;
    address public referralStorage;
    address public fsGlp;
    address public callbackTarget;

    modifier onlyGov() {
        _onlyGov();
        _;
    }

    modifier onlyKeepers() {
        _onlyKeepers();
        _;
    }

    function initialize(InitialConfig memory _config) public initializer {
        glpManager = _config.glpManager;
        positionRouter = _config.positionRouter;
        rewardRouter = _config.rewardRouter;
        router = _config.router;
        referralStorage = _config.referralStorage;
        fsGlp = _config.fsGlp;

        want = _config.want;
        wbtc = _config.wbtc;
        weth = _config.weth;
        gov = msg.sender;
        marginFeeBasisPoints = 10;
        executionFee = 100000000000000;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyGov {}

    function _onlyGov() internal view {
        require(msg.sender == gov, "StrategyVault: Not Authorized");
    }

    function _onlyKeepers() internal view {
        require(msg.sender == keeper || msg.sender == gov || msg.sender == address(this), "StrategyVault: Not Keepers");
    }

    function depositInsuranceFund(uint256 _amount) public onlyKeepers {
        IERC20(want).transferFrom(msg.sender, address(this), _amount);
        insuranceFund += _amount;
    }

    function executeStrategy(uint256 _amount) public payable onlyKeepers {
        require(!executed, "StrategyVault: strategy already executed");
        require(msg.value == 2 * executionFee, "StrategyVault: not enough execution fee");

        uint256 mintAmount = buyGlp(_amount);
        (uint256 wbtcAum, uint256 wethAum) = IGmxHelper(gmxHelper).getTokenAumsPerAmount(
            IERC20(fsGlp).balanceOf(address(this)),
            false
        );
        uint256 wbtcRatio = (wbtcAum * BASE_PRECISION) / (wbtcAum + wethAum);
        uint256 wbtcAmountIn = ((IERC20(want).balanceOf(address(this)) - insuranceFund) * wbtcRatio) / BASE_PRECISION;
        uint256 wethAmountIn = IERC20(want).balanceOf(address(this)) - insuranceFund - wbtcAmountIn;

        require(wbtcAmountIn > MINIMUM_COLLATERAL * IERC20(want).decimals(), "StrategyVault: not enough wbtc amountIn");
        require(wethAmountIn > MINIMUM_COLLATERAL * IERC20(want).decimals(), "StrategyVault: not enough weth amountIn");

        increaseShortPosition(wbtc, wbtcAmountIn, wbtcAum);
        increaseShortPosition(weth, wethAmountIn, wethAum);

        executed = true;
    }

    function buyGlp(uint256 _amount) public onlyKeepers returns (uint256) {
        //TODO: improve slippage
        return IRewardRouter(rewardRouter).mintAndStakeGlp(want, _amount, 0, 0);
    }

    function sellGlp(uint256 _amount) public onlyKeepers returns (uint256) {
        require(
            IGlpManager(glpManager).lastAddedAt(address(this)) + (IGlpManager(glpManager).cooldownDuration()) <=
                block.timestamp,
            "StrategyVault: cooldown duration not yet passed"
        );

        //TODO: improve slippage
        return IRewardRouter(rewardRouter).unstakeAndRedeemGlp(want, _amount, 0, address(this));
    }

    function increaseShortPosition(
        address _indexToken,
        uint256 _amountIn,
        uint256 _sizeDelta
    ) public payable onlyKeepers {
        address[] memory path = new address[](1);
        path[0] = want;

        //TODO: can improve minOut and acceptablePrcie
        IPositionRouter(positionRouter).createIncreasePosition{value: executionFee}(
            path,
            _indexToken,
            _amountIn,
            0, // minOut
            _sizeDelta,
            false,
            0, // acceptablePrcie
            executionFee,
            referralCode,
            callbackTarget
        );
    }

    function decreaseShortPosition(
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta
    ) public payable onlyKeepers {
        address[] memory path = new address[](1);
        path[0] = want;

        //TODO: can improve acceptablePrice and minOut
        IPositionRouter(positionRouter).createDecreasePosition{value: executionFee}(
            path,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            false,
            address(this),
            type(uint256).max, // acceptablePrcie
            0,
            executionFee,
            false,
            callbackTarget
        );
    }

    function adjustForDecimals(uint256 _amount, address _tokenDiv, address _tokenMul) public view returns (uint256) {
        uint256 decimalsDiv = _tokenDiv == address(0) ? 30 : IERC20(_tokenDiv).decimals();
        uint256 decimalsMul = _tokenMul == address(0) ? 30 : IERC20(_tokenMul).decimals();
        return (_amount * (10 ** decimalsMul)) / (10 ** decimalsDiv);
    }

    function setKeeper(address _keeper) external onlyGov {
        keeper = _keeper;
    }

    function setWant(address _want) external onlyGov {
        want = _want;
        IERC20(want).approve(glpManager, type(uint256).max);
        IERC20(want).approve(router, type(uint256).max);
    }

    function setExecutionFee(uint256 _executionFee) external onlyGov {
        executionFee = _executionFee;
    }

    function setCallbackTarget(address _callbackTarget) external onlyGov {
        callbackTarget = _callbackTarget;
    }

    function setMarginFeeBasisPoints(uint256 _feeBps) external onlyGov {
        marginFeeBasisPoints = _feeBps;
    }

    function registerAndSetReferralCode(string memory _text) public onlyGov {
        bytes32 stringToByte32 = bytes32(bytes(_text));

        IReferralStorage(referralStorage).registerCode(stringToByte32);
        IReferralStorage(referralStorage).setTraderReferralCodeByUser(stringToByte32);
        referralCode = stringToByte32;
    }
}
