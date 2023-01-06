// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import {MintableERC20} from "./base/MintableERC20.sol";

contract EsNEU is MintableERC20 {
    constructor() MintableERC20("esNEU", "Escrowed Neutral Token") {}

    // no need to correspond with want decimals
    function decimals() public view override returns (uint8) {
        return 18;
    }
}
