// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IStakedGlp {
    function transferFrom(address _sender, address _recipient, uint256 _amount) external returns (bool);
    function approve(address _spender, uint256 _amount) external returns (bool);
    function transfer(address _recipient, uint256 _amount) external returns (bool);
}