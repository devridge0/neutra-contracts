// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IReferralStorage {
    function registerCode(bytes32 _code) external;

    function setTraderReferralCodeByUser(bytes32 _code) external;
}
