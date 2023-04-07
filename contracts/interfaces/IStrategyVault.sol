// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IStrategyVault {
    function totalAssets() external view returns (uint256);

    function feeReserves() external view returns (uint256);

    function handleBuy(uint256 _amount) external payable returns (uint256);

    function handleSell(uint256 _amount, address _recipient) external payable;

    function harvest() external;

    function confirm() external;

    function confirmCallback() external;

    function totalValue() external view returns (uint256);

    function executePositions(bytes4[] calldata _selectors, bytes[] calldata _params) external payable;

    function confirmAndDealGlp(bytes4 _selector, bytes calldata _param) external;

    function executeDecreasePositions(bytes[] calldata _params) external payable;

    function executeIncreasePositions(bytes[] calldata _params) external payable;

    function buyNeuGlp(uint256 _amountIn) external returns (uint256);

    function sellNeuGlp(uint256 _glpAmount, address _recipient) external returns (uint256);

    function settle(uint256 _amount, address _recipient) external;

    function exited() external view returns (bool);

    function usdToTokenMax(address _token, uint256 _usdAmount, bool _isCeil) external returns (uint256);

    function decreaseShortPositionsWithCallback(
        uint256 _wbtcCollateralDelta,
        uint256 _wbtcSizeDelta,
        uint256 _wethCollateralDelta,
        uint256 _wethSizeDelta,
        bool _shouldRepayWbtc,
        bool _shouldRepayWeth,
        address _recipient,
        address _callbackTarget
    ) external payable returns (bytes32, bytes32);

    function increaseShortPositionsWithCallback(
        uint256 _wbtcAmountIn,
        uint256 _wbtcSizeDelta,
        uint256 _wethAmountIn,
        uint256 _wethSizeDelta,
        address _callbackTarget
    ) external payable returns (bytes32, bytes32);

    function instantRepayFundingFee(address _indexToken, address _callbackTarget) external payable;

    function buyGlp(uint256 _amount) external returns (uint256);

    function sellGlp(uint256 _amount, address _recipient) external returns (uint256);

    function transferFailedAmount(uint256 _wantAmount, uint256 _glpAmount) external;
}
