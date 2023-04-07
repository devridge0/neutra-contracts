// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

interface IGmxHelper {
    function getTokenAums(address[] memory _tokens, bool _maximise) external view returns (uint256[] memory);

    function getTokenAumsPerAmount(uint256 _fsGlpAmount, bool _maximise) external view returns (uint256, uint256);

    function getPrice(address _token, bool _maximise) external view returns (uint256);

    function totalValue(address _account) external view returns (uint256);

    function getLastFundingTime() external view returns (uint256);

    function getCumulativeFundingRates(address _token) external view returns (uint256);

    function getFundingFee(address _account, address _indexToken) external view returns (uint256);

    function getLongValue(uint256 _glpAmount) external view returns (uint256);

    function getLongValueInUsdg(uint256 _glpAmount) external view returns (uint256);

    function getShortValue(address _account, address _indexToken) external view returns (uint256);

    function getMintBurnFeeBasisPoints(
        address _token,
        uint256 _usdgDelta,
        bool _increment
    ) external view returns (uint256);

    function getGlpTotalSupply() external view returns (uint256);

    function getAumInUsdg(bool _maximise) external view returns (uint256);

    function getRedemptionAmount(address _token, uint256 _usdgAmount) external view returns (uint256);

    function getPosition(
        address _account,
        address _indexToken
    ) external view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256);

    function getFundingFeeWithRate(
        address _account,
        address _indexToken,
        uint256 _fundingRate
    ) external view returns (uint256);

    function getDelta(address _indexToken, uint256 _size, uint256 _avgPrice) external view returns (bool, uint256);

    function getAvailableShortSize(address _indexToken) external view returns (uint256);

    function getAvailableGlpAmountIn(address _token) external view returns (uint256);

    function validateMaxGlobalShortSize(address _indexToken, uint256 _sizeDelta) external view returns (bool);

    function getAum(bool _maximise) external view returns (uint256);

    function adjustDecimalsToUsdg(uint256 _amount, address _token) external view returns (uint256);

    function adjustDecimalsFromUsdg(uint256 _amount, address _token) external view returns (uint256);

    function getRequestQueueLengths() external view returns (uint256, uint256, uint256, uint256);
}
