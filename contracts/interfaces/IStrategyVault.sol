// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IStrategyVault {
    function totalAssets() external view returns (uint256);

    function handleBuy(uint256 _amount) external payable returns (uint256);

    function handleSell(uint256 _amount, address _recipient) external payable;

    function harvest() external;

    function confirm() external;

    function totalValue() external view returns (uint256);

    function executePositions(bytes4[] calldata _selectors, bytes[] calldata _params) external payable;

    function confirmAndDealGlp(bytes4 _selector, bytes calldata _param) external;

    function executeDecreasePositions(bytes[] calldata _params) external payable;

    function executeIncreasePositions(bytes[] calldata _params) external payable;

    function buyNeuGlp(uint256 _amountIn) external returns (uint256);

    function sellNeuGlp(uint256 _amountIn, address _recipient) external returns (uint256);

    function settle(uint256 _amount, address _recipient) external;
}
