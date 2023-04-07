// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import {IPositionRouterCallbackReceiver} from "./interfaces/IPositionRouterCallbackReceiver.sol";
import {IStrategyVault} from "./interfaces/IStrategyVault.sol";
import {IRouter} from "./interfaces/IRouter.sol";    

contract RepayCallbackTarget is IPositionRouterCallbackReceiver {
    address public immutable router;
    address public immutable positionRouter;

    event GmxPositionCallback(address keeper, bytes32 positionKey, bool isExecuted, bool isIncrease);

    modifier onlyPositionRouter() {
        _onlyPositionRouter();
        _;
    }

    constructor(address _router, address _positionRouter) {
        router = _router;
        positionRouter = _positionRouter;
    }

    function isContract() external pure returns (bool) {
        return true;
    }

    function gmxPositionCallback(bytes32 _requestKey, bool _isExecuted, bool _isIncrease) external onlyPositionRouter {
        if(!_isExecuted) {
            _failFallback(_isIncrease);
        }

        emit GmxPositionCallback(msg.sender, _requestKey, _isExecuted, _isIncrease);
    }

    function _failFallback(bool _isIncrease) internal {
        IRouter(router).failCallback(_isIncrease);
    }

    function getRequestKey(address _account, uint256 _index) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _index));
    }

    function _onlyPositionRouter() internal {
        require(msg.sender == positionRouter, "invalid positionRouter");
    }
}