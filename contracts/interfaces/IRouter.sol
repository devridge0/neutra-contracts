// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IRouter {
    function executePositionsBeforeDealGlp(
        uint256 _amount,
        bytes[] calldata _params,
        bool _isWithdraw
    ) external payable;

    function confirmAndBuy(uint256 _wantAmount, address _recipient) external returns (uint256);

    function confirmAndSell(uint256 _glpAmount, address _recipient) external returns (uint256);

    function firstCallback(bool _isIncrease, bytes32 _requestKey) external;

    function secondCallback(bool _isIncrease, bytes32 _requestKey) external;

    function failCallback(bool _isIncrease) external;

    function getDepositParams(uint256 _amount) external view returns (uint256, uint256, uint256);
}
