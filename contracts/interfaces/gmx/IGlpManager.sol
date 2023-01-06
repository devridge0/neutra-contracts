// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IGlpManager {
    function aumAddition() external view returns (uint256);

    function aumDedection() external view returns (uint256);

    function getAum(bool maximise) external view returns (uint256);

    function getAums() external view returns (uint256[] memory);

    function cooldownDuration() external view returns (uint256);

    function lastAddedAt(address) external view returns (uint256);

    function getAumInUsdg(bool maximise) external view returns (uint256);
}
