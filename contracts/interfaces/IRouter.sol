// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IRouter {
    function executePositionsBeforeDealGlp(
        uint256 _amount,
        bytes[] calldata _params,
        bool _isWithdraw
    ) external payable;

    function confirmAndBuy(address _recipient) external returns (uint256);

    function confirmAndSell(address _recipient) external returns (uint256);
}
