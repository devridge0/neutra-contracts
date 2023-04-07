// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import "./StrategyVault.sol";

contract StrategyVaultV2 is StrategyVault {
    event InstantRepayFundingFee(address indexToken, uint256 fundingFee, uint256 prePaidGmxFee);
    event IncreaseShortPositionsWithCallback(
        uint256 wbtcAmountIn, 
        uint256 wbtcSizeDelta, 
        uint256 wethAmountIn, 
        uint256 wethSizeDelta
    );
    event DecreaseShortPositionsWithCallback(
        address recipient, 
        uint256 wbtcCollateralDelta, 
        uint256 wbtcSizeDelta, 
        uint256 wethCollateralDelta, 
        uint256 wethSizeDelta, 
        bool shouldRepayWbtc, 
        bool shouldRepayWeth
    );
    event SetFundingFee(address indexToken, uint256 fundingFee);

    function increaseShortPositionsWithCallback(
        uint256 _wbtcAmountIn,
        uint256 _wbtcSizeDelta,
        uint256 _wethAmountIn,
        uint256 _wethSizeDelta,
        address _callbackTarget
    ) public payable onlyRouter returns (bytes32, bytes32) {
        require(confirmed, "not confirmed yet");

        _updatePendingPositionFundingRate();

        bytes32 wbtcRequestKey = _increaseShortPositionWithCallback(wbtc, _wbtcAmountIn, _wbtcSizeDelta, _callbackTarget);
        bytes32 wethRequestKey = _increaseShortPositionWithCallback(weth, _wethAmountIn, _wethSizeDelta, _callbackTarget);

        _requireConfirm();

        emit IncreaseShortPositionsWithCallback(_wbtcAmountIn, _wbtcSizeDelta, _wethAmountIn, _wethSizeDelta);

        return (wbtcRequestKey, wethRequestKey);
    }

    function _increaseShortPositionWithCallback(
        address _indexToken,
        uint256 _amountIn,
        uint256 _sizeDelta,
        address _callbackTarget
    ) internal returns (bytes32) {
        require(_callbackTarget != address(0), "invalid callbackTarget");

        address[] memory path = new address[](1);
        path[0] = want;

        uint256 fundingFee = IGmxHelper(gmxHelper).getFundingFee(address(this), _indexToken);
        fundingFee = usdToTokenMax(want, fundingFee, true);

        if (_indexToken == wbtc) {
            pendingPositionFeeInfo.wbtcFundingFee = fundingFee;
        } else {
            pendingPositionFeeInfo.wethFundingFee = fundingFee;
        }

        emit SetFundingFee(_indexToken, fundingFee);

        return IPositionRouter(positionRouter).createIncreasePosition{value: executionFee}(
            path,
            _indexToken,
            _amountIn + fundingFee,
            0, // minOut
            _sizeDelta,
            false,
            0, // acceptablePrice
            executionFee,
            referralCode,
            _callbackTarget
        );
    }

    function decreaseShortPositionsWithCallback(
        uint256 _wbtcCollateralDelta,
        uint256 _wbtcSizeDelta,
        uint256 _wethCollateralDelta,
        uint256 _wethSizeDelta,
        bool _shouldRepayWbtc,
        bool _shouldRepayWeth,
        address _recipient,
        address _callbackTarget
    ) public payable onlyRouter returns (bytes32, bytes32) {
        require(confirmed, "not confirmed yet");

        _updatePendingPositionFundingRate();

        bytes32 wbtcRequestKey = _decreaseShortPositionWithCallback(wbtc, _wbtcCollateralDelta, _wbtcSizeDelta, _shouldRepayWbtc, _recipient, _callbackTarget);
        bytes32 wethRequestKey = _decreaseShortPositionWithCallback(weth, _wethCollateralDelta, _wethSizeDelta, _shouldRepayWeth, _recipient, _callbackTarget);

        _requireConfirm();
        confirmList.hasDecrease = true;

        emit DecreaseShortPositionsWithCallback(
            _recipient, 
            _wbtcCollateralDelta, 
            _wbtcSizeDelta, 
            _wethCollateralDelta, 
            _wethSizeDelta, 
            _shouldRepayWbtc, 
            _shouldRepayWeth
        );

        return (wbtcRequestKey, wethRequestKey);
    }

    function _decreaseShortPositionWithCallback(
        address _indexToken, 
        uint256 _collateralDelta, 
        uint256 _sizeDelta,
        bool _shouldRepay,
        address _recipient,
        address _callbackTarget
    ) internal returns (bytes32) {
        require(_callbackTarget != address(0), "invalid callbackTarget");

        address[] memory path = new address[](1);
        path[0] = want;

        if (!_shouldRepay) {
            uint256 fundingFee = IGmxHelper(gmxHelper).getFundingFee(address(this), _indexToken);
            fundingFee = usdToTokenMax(want, fundingFee, true);

            if (_indexToken == wbtc) {
                pendingPositionFeeInfo.wbtcFundingFee = fundingFee;
            } else {
                pendingPositionFeeInfo.wethFundingFee = fundingFee;
            }
            
            emit SetFundingFee(_indexToken, fundingFee);
        }


        return IPositionRouter(positionRouter).createDecreasePosition{value: executionFee}(
            path,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            false,
            _recipient,
            type(uint256).max,
            0,
            executionFee,
            false,
            _callbackTarget
        );
    }

    function instantRepayFundingFee(address _indexToken, address _callbackTarget) external payable onlyKeepersAndAbove {
        uint256 fundingFee = IGmxHelper(gmxHelper).getFundingFee(address(this), _indexToken);
        fundingFee = usdToTokenMax(want, fundingFee, true);

        uint256 balance = IERC20(want).balanceOf(address(this));
        require(fundingFee <= balance, "StrategyVault: not enough balance to repay");

        prepaidGmxFee += fundingFee;

        address[] memory path = new address[](1);
        path[0] = want;

        IPositionRouter(positionRouter).createIncreasePosition{value: executionFee}(
            path,
            _indexToken,
            fundingFee,
            0, // minOut
            0,
            false,
            0, // acceptablePrice
            executionFee,
            referralCode,
            _callbackTarget
        );

        emit InstantRepayFundingFee(_indexToken, fundingFee, prepaidGmxFee);
    }

    function confirmCallback() public onlyRouter {
        require(!confirmed, "already confirmed");

        _confirm();

        // when positions are decreased, it is necessary to check 
        // whether funding fee is equal to zero or not
        // if funding fee is not zero, strategyVault should transfer funding fee to recipient
        if (confirmList.hasDecrease) {
            uint256 fundingFee = pendingPositionFeeInfo.wbtcFundingFee + pendingPositionFeeInfo.wethFundingFee;
            IERC20(want).transfer(msg.sender, fundingFee);
            confirmList.hasDecrease = false;
        }

        _clearPendingPositionFeeInfo();

        confirmed = true;
    }

    function emergencyConfrim() external onlyKeepersAndAbove {
        require(!confirmed, "already confirmed");

        _clearPendingPositionFeeInfo();
        confirmList.hasDecrease = false;
        confirmed = true;
    }

    function approveToken(address _token, address _spender) external onlyGov {
        require(_token != address(0) && _spender != address(0), "invalid address");
        IERC20(_token).approve(_spender, type(uint256).max);
    }
}
