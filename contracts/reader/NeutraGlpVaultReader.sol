// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import {IERC20} from "../interfaces/IERC20.sol";
import {IVault} from "../interfaces/gmx/IVault.sol";
import {IPositionRouter} from "../interfaces/gmx/IPositionRouter.sol";
import {IGlpManager} from "../interfaces/gmx/IGlpManager.sol";
import {IRouter} from "../interfaces/IRouter.sol";
import {IGmxHelper} from "../interfaces/IGmxHelper.sol";

contract NeutraGlpVaultReader {
    struct InitialConfig {
        address gmxVault;
        address positionRouter;
        address glpManager;
        address router;
        address gmxHelper;
        address strategyVault;
        address want;
        address wbtc;
        address weth;
        address glp;
        address fsGlp;
        address nGlp;
    }

    address public gmxVault;
    address public positionRouter;
    address public glpManager;
    address public router;
    address public gmxHelper;
    address public strategyVault;
    address public want;
    address public wbtc;
    address public weth;
    address public glp;
    address public fsGlp;
    address public nGlp;

    uint256 public constant USD_PRECISION = 10 ** 30;
    uint256 public constant USDG_PRECISION = 10 ** 18;
    uint256 public constant POSITION_FEE_BASIS = 10;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    uint256 public ONE_USD_WANT;
    uint256 public ONE_GLP;
    uint256 public ONE_NEUTRA_GLP;

    constructor(InitialConfig memory _config) {
        gmxVault = _config.gmxVault;
        positionRouter = _config.positionRouter;
        glpManager = _config.glpManager;
        router = _config.router;
        gmxHelper = _config.gmxHelper;
        strategyVault = _config.strategyVault;
        want = _config.want;
        wbtc = _config.wbtc;
        weth = _config.weth;
        glp = _config.glp;
        fsGlp = _config.fsGlp;
        nGlp = _config.nGlp;

        ONE_USD_WANT = 10 ** IERC20(want).decimals();
        ONE_GLP = 10 ** IERC20(fsGlp).decimals();
        ONE_NEUTRA_GLP = 10 ** IERC20(nGlp).decimals();
    }

    function getWantDepositMintAndFee(uint256 _amountIn) public view returns (uint256, uint256, uint256) {
        (uint256 glpAmountIn, uint256 wbtcAmountIn, uint256 wethAmountIn) = IRouter(router).getDepositParams(_amountIn);

        (uint256 glpMintAmount, uint256 glpFeeUsd) = getGlpMintAmountAndFee(glpAmountIn);

        (uint256 wbtcSize, uint256 wethSize) = getSize(glpMintAmount, false);

        uint256 positionFeeUsd = ((wbtcSize + wethSize) * POSITION_FEE_BASIS) / BASIS_POINTS_DIVISOR;

        uint256 increasedValue = ((glpMintAmount * glpPrice(false)) / (10 ** IERC20(glp).decimals())) +
            IVault(gmxVault).tokenToUsdMin(want, wbtcAmountIn) +
            IVault(gmxVault).tokenToUsdMin(want, wethAmountIn) -
            positionFeeUsd;

        uint256 mintAmount = (increasedValue * IERC20(nGlp).totalSupply()) /
            IGmxHelper(gmxHelper).totalValue(strategyVault);

        return (mintAmount, glpFeeUsd, positionFeeUsd);
    }

    function getGlpDepositMintAndFee(uint256 _amountIn) public view returns (uint256, uint256, uint256) {
        uint256 valueInUsdg = IGmxHelper(gmxHelper).getLongValueInUsdg(_amountIn);
        uint256 redemptionAmount = IGmxHelper(gmxHelper).getRedemptionAmount(want, valueInUsdg);

        (, uint256 wbtcAmountIn, uint256 wethAmountIn) = IRouter(router).getDepositParams(redemptionAmount);

        uint256 unstakeGlpAmount = (_amountIn * (wbtcAmountIn + wethAmountIn)) / redemptionAmount;

        uint256 glpRemainAmount = _amountIn - unstakeGlpAmount;

        (uint256 wbtcSize, uint256 wethSize) = getSize(glpRemainAmount, false);

        uint256 positionFeeUsd = ((wbtcSize + wethSize) * POSITION_FEE_BASIS) / BASIS_POINTS_DIVISOR;

        (uint256 wantAmountOut, uint256 glpFeeUsd) = getSellGlpWantOutAndFee(unstakeGlpAmount);

        wbtcAmountIn = (wantAmountOut * wbtcAmountIn) / (wbtcAmountIn + wethAmountIn);
        wethAmountIn = wantAmountOut - wbtcAmountIn;

        uint256 increasedValue = ((glpRemainAmount * glpPrice(false)) / (10 ** IERC20(glp).decimals())) +
            IVault(gmxVault).tokenToUsdMin(want, wbtcAmountIn) +
            IVault(gmxVault).tokenToUsdMin(want, wethAmountIn) -
            positionFeeUsd;

        uint256 mintAmount = (increasedValue * IERC20(nGlp).totalSupply()) /
            IGmxHelper(gmxHelper).totalValue(strategyVault);

        return (mintAmount, glpFeeUsd, positionFeeUsd);
    }

    function getWithdrawWantOutAndFee(uint256 _amountIn) public view returns (uint256, uint256, uint256) {
        uint256 shareNumerator = _amountIn;
        uint256 shareDenominator = IERC20(nGlp).totalSupply();

        uint256 glpSellAmount = (IERC20(fsGlp).balanceOf(strategyVault) * shareNumerator) / shareDenominator;

        (uint256 glpWantAmountOut, uint256 glpFeeUsd) = getSellGlpWantOutAndFee(glpSellAmount);

        (uint256 wbtcSize, , , , , , , ) = IGmxHelper(gmxHelper).getPosition(strategyVault, wbtc);
        (uint256 wethSize, , , , , , , ) = IGmxHelper(gmxHelper).getPosition(strategyVault, weth);

        uint256 positionFeeUsd = ((wbtcSize + wethSize) * shareNumerator * POSITION_FEE_BASIS) /
            BASIS_POINTS_DIVISOR /
            shareDenominator;

        uint256 wbtcShortValue = (IGmxHelper(gmxHelper).getShortValue(strategyVault, wbtc) * shareNumerator) /
            shareDenominator;
        uint256 wethShortValue = (IGmxHelper(gmxHelper).getShortValue(strategyVault, weth) * shareNumerator) /
            shareDenominator;

        uint256 shortAmountOut = IVault(gmxVault).usdToTokenMin(want, wbtcShortValue + wethShortValue - positionFeeUsd);

        uint256 wantOut = glpWantAmountOut + shortAmountOut;

        return (wantOut, glpFeeUsd, positionFeeUsd);
    }

    function getWithdrawGlpWantOutAndFee(uint256 _amountIn) public view returns (uint256, uint256, uint256) {
        uint256 shareNumerator = _amountIn;
        uint256 shareDenominator = IERC20(nGlp).totalSupply();

        uint256 glpOut = (IERC20(fsGlp).balanceOf(strategyVault) * shareNumerator) / shareDenominator;

        (uint256 wbtcSize, , , , , , , ) = IGmxHelper(gmxHelper).getPosition(strategyVault, wbtc);
        (uint256 wethSize, , , , , , , ) = IGmxHelper(gmxHelper).getPosition(strategyVault, weth);

        uint256 positionFeeUsd = ((wbtcSize + wethSize) * shareNumerator * POSITION_FEE_BASIS) /
            BASIS_POINTS_DIVISOR /
            shareDenominator;

        uint256 wbtcShortValue = (IGmxHelper(gmxHelper).getShortValue(strategyVault, wbtc) * shareNumerator) /
            shareDenominator;
        uint256 wethShortValue = (IGmxHelper(gmxHelper).getShortValue(strategyVault, weth) * shareNumerator) /
            shareDenominator;

        uint256 wantOut = IVault(gmxVault).usdToTokenMin(want, wbtcShortValue + wethShortValue - positionFeeUsd);

        return (glpOut, wantOut, positionFeeUsd);
    }

    function getCaps() public view returns (uint256, uint256, uint256) {
        uint256 wantDepositCap = getWantDepositCap();
        uint256 glpDepositCap = getGlpDepositCap();
        uint256 wantWithdrawCap = getWantWithdrawCap();

        return (wantDepositCap, glpDepositCap, wantWithdrawCap);
    }

    function getWantDepositCap() public view returns (uint256) {
        uint256 wantGlpCap = getWantGlpCap();
        uint256 wantSizeReserveCap = getWantSizeAndReserveCap();

        return wantGlpCap < wantSizeReserveCap ? wantGlpCap : wantSizeReserveCap;
    }

    function getWantGlpCap() public view returns (uint256) {
        (uint256 glpAmountIn, , ) = IRouter(router).getDepositParams(ONE_USD_WANT);
        uint256 usdPerWant = IVault(gmxVault).tokenToUsdMin(want, glpAmountIn);
        uint256 usdgPerWant = (usdPerWant * USDG_PRECISION) / USD_PRECISION;

        uint256 usdgAmount = IVault(gmxVault).usdgAmounts(want);
        uint256 maxUsdgAmount = IVault(gmxVault).maxUsdgAmounts(want);

        uint256 buyableUsdg = maxUsdgAmount > usdgAmount ? maxUsdgAmount - usdgAmount : 0;

        uint256 maxWant = (buyableUsdg * (ONE_USD_WANT)) / usdgPerWant;
        return maxWant;
    }

    function getWantSizeAndReserveCap() public view returns (uint256) {
        (uint256 glpAmountIn, , ) = IRouter(router).getDepositParams(ONE_USD_WANT);

        (uint256 glpMintAmount, ) = getGlpMintAmountAndFee(glpAmountIn);

        (uint256 wbtcSize, uint256 wethSize) = getSize(glpMintAmount, false);

        uint256 wbtcAvailableSize = getAvailableSize(wbtc);

        uint256 wethAvailableSize = getAvailableSize(weth);

        uint256 maxWantWbtc = wbtcAvailableSize > 0 ? (ONE_USD_WANT * wbtcAvailableSize) / wbtcSize : 0;
        uint256 maxWantWeth = wethAvailableSize > 0 ? (ONE_USD_WANT * wethAvailableSize) / wethSize : 0;

        uint256 reserveDelta = IVault(gmxVault).usdToTokenMax(want, wbtcSize) +
            IVault(gmxVault).usdToTokenMax(want, wethSize);

        uint256 wantAvailableReserve = getAvailablePoolAmount(want);

        uint256 maxWantReserve = wantAvailableReserve > 0 ? (ONE_USD_WANT * wantAvailableReserve) / reserveDelta : 0;

        uint256 cap = maxWantWbtc < maxWantWeth ? maxWantWbtc : maxWantWeth;

        cap = cap < maxWantReserve ? cap : maxWantReserve;

        return cap;
    }

    function getGlpDepositCap() public view returns (uint256) {
        uint256 valueInUsdg = IGmxHelper(gmxHelper).getLongValueInUsdg(ONE_GLP);
        uint256 redemptionAmount = IGmxHelper(gmxHelper).getRedemptionAmount(want, valueInUsdg);

        (, uint256 wbtcAmountIn, uint256 wethAmountIn) = IRouter(router).getDepositParams(redemptionAmount);

        uint256 unstakeGlpAmount = (ONE_GLP * (wbtcAmountIn + wethAmountIn)) / redemptionAmount;

        uint256 glpRemainAmount = ONE_GLP - unstakeGlpAmount;

        (uint256 wbtcSize, uint256 wethSize) = getSize(glpRemainAmount, false);

        uint256 wbtcAvailableSize;
        uint256 wethAvailableSize;

        {
            uint256 wbtcGlobalSize = IVault(gmxVault).globalShortSizes(wbtc);
            uint256 wbtcMaxGlobalSize = IPositionRouter(positionRouter).maxGlobalShortSizes(wbtc);

            wbtcAvailableSize = wbtcMaxGlobalSize > wbtcGlobalSize ? wbtcMaxGlobalSize - wbtcGlobalSize : 0;

            uint256 wethGlobalSize = IVault(gmxVault).globalShortSizes(weth);
            uint256 wethMaxGlobalSize = IPositionRouter(positionRouter).maxGlobalShortSizes(weth);

            wethAvailableSize = wethMaxGlobalSize > wethGlobalSize ? wethMaxGlobalSize - wethGlobalSize : 0;
        }

        uint256 cap;
        {
            uint256 reserveDelta = IVault(gmxVault).usdToTokenMax(want, wbtcSize) +
                IVault(gmxVault).usdToTokenMax(want, wethSize);

            uint256 wantAvailableReserve = getAvailablePoolAmount(want);

            uint256 maxGlpReserve = wantAvailableReserve > 0 ? (ONE_GLP * wantAvailableReserve) / reserveDelta : 0;

            uint256 maxGlpWbtc = wbtcAvailableSize > 0 ? (ONE_GLP * wbtcAvailableSize) / wbtcSize : 0;
            uint256 maxGlpWeth = wethAvailableSize > 0 ? (ONE_GLP * wethAvailableSize) / wethSize : 0;

            cap = maxGlpWbtc < maxGlpWeth ? maxGlpWbtc : maxGlpWeth;

            cap = cap < maxGlpReserve ? cap : maxGlpReserve;
        }

        return cap;
    }

    function getWantWithdrawCap() public view returns (uint256) {
        uint256 shareNumerator = 10 ** IERC20(nGlp).decimals();
        uint256 shareDenominator = IERC20(nGlp).totalSupply();

        uint256 glpSellAmount = (IERC20(fsGlp).balanceOf(strategyVault) * shareNumerator) / shareDenominator;
        uint256 amountInUsdg = IGmxHelper(gmxHelper).getLongValueInUsdg(glpSellAmount);
        uint256 wantOut = IGmxHelper(gmxHelper).getRedemptionAmount(want, amountInUsdg);

        uint256 poolAmount = IVault(gmxVault).poolAmounts(want);
        uint256 reserveAmount = IVault(gmxVault).reservedAmounts(want);

        uint256 wantCap = reserveAmount < poolAmount ? poolAmount - reserveAmount : 0;

        uint256 maxNGlp = wantCap != 0 ? (wantCap * ONE_NEUTRA_GLP) / wantOut : 0;

        return maxNGlp;
    }

    function getGlpMintAmountAndFee(uint256 _amountIn) public view returns (uint256, uint256) {
        uint256 amountInUsd = IVault(gmxVault).tokenToUsdMin(want, _amountIn);
        uint256 amountInUsdg = (amountInUsd * USDG_PRECISION) / USD_PRECISION;
        uint256 feeBasisPoints = IVault(gmxVault).getFeeBasisPoints(
            want,
            amountInUsdg,
            IVault(gmxVault).mintBurnFeeBasisPoints(),
            IVault(gmxVault).taxBasisPoints(),
            true
        );
        uint256 glpFeeUsd = (amountInUsd * feeBasisPoints) / BASIS_POINTS_DIVISOR;

        uint256 glpMintAmount = ((amountInUsd - glpFeeUsd) * ONE_GLP) / glpPrice(true);
        return (glpMintAmount, glpFeeUsd);
    }

    function getSellGlpWantOutAndFee(uint256 _amountIn) public view returns (uint256, uint256) {
        uint256 amountInUsdg = IGmxHelper(gmxHelper).getLongValueInUsdg(_amountIn);
        uint256 amountInUsd = (amountInUsdg * USD_PRECISION) / USDG_PRECISION;
        uint256 feeBasisPoints = IVault(gmxVault).getFeeBasisPoints(
            want,
            amountInUsdg,
            IVault(gmxVault).mintBurnFeeBasisPoints(),
            IVault(gmxVault).taxBasisPoints(),
            false
        );
        uint256 glpFeeUsd = (amountInUsd * feeBasisPoints) / BASIS_POINTS_DIVISOR;

        uint256 wantAmountOut = IVault(gmxVault).usdToTokenMin(want, amountInUsd - glpFeeUsd);

        return (wantAmountOut, glpFeeUsd);
    }

    function getSize(uint256 _glpAmountIn, bool _maximise) public view returns (uint256, uint256) {
        uint256 totalSupply = IERC20(glp).totalSupply();
        address[] memory tokens = new address[](2);
        tokens[0] = wbtc;
        tokens[1] = weth;
        uint256[] memory aums = IGmxHelper(gmxHelper).getTokenAums(tokens, _maximise);

        return ((aums[0] * _glpAmountIn) / totalSupply, (aums[1] * _glpAmountIn) / totalSupply);
    }

    function glpPrice(bool _maximise) public view returns (uint256) {
        uint256 totalSupply = IERC20(glp).totalSupply();
        uint256 aum = IGlpManager(glpManager).getAum(_maximise);
        return (aum * (10 ** IERC20(glp).decimals())) / totalSupply;
    }

    function getAvailableSize(address _indexToken) public view returns (uint256) {
        uint256 globalSize = IVault(gmxVault).globalShortSizes(_indexToken);
        uint256 maxGlobalSize = IPositionRouter(positionRouter).maxGlobalShortSizes(_indexToken);

        return maxGlobalSize > globalSize ? maxGlobalSize - globalSize : 0;
    }

    function getAvailablePoolAmount(address _indexToken) public view returns (uint256) {
        uint256 reservedAmount = IVault(gmxVault).reservedAmounts(_indexToken);
        uint256 poolAmount = IVault(gmxVault).poolAmounts(_indexToken);

        return poolAmount > reservedAmount ? poolAmount - reservedAmount : 0;
    }
}
