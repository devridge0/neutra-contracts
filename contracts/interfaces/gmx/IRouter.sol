// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IRouter {
    function swap(address[] memory _path, uint256 _amountIn, uint256 _minOut, address _receiver) external;

    function approvePlugin(address _plugin) external;
}
