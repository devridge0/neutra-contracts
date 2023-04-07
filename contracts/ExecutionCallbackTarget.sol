// SPDX-License-Identifier: MIT

pragma solidity 0.8.11;

import {IPositionRouterCallbackReceiver} from "./interfaces/IPositionRouterCallbackReceiver.sol";
import {IRouter} from "./interfaces/IRouter.sol";
    

contract ExecutionCallbackTarget is IPositionRouterCallbackReceiver {
    enum PositionExecutionStatus { NONE, PARTIAL}

    address public strategyVault;
    address public router;

    PositionExecutionStatus public status;

    event GmxPositionCallback(address keeper, bytes32 requestKey, bool isExecuted, bool isIncrease);

    constructor(address _router) {
        router = _router;
    }

    function isContract() external pure returns (bool) {
        return true;
    }

    function gmxPositionCallback(bytes32 _requestKey, bool _isExecuted, bool _isIncrease) external {
        if(_isExecuted) {
            _successCallback(_isIncrease, _requestKey);
        } else {
            _failFallback(_isIncrease);
        }

        emit GmxPositionCallback(msg.sender, _requestKey, _isExecuted, _isIncrease);
    }

    function getRequestKey(address _account, uint256 _index) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(_account, _index));
    }

    function _successCallback(bool _isIncrease, bytes32 _requestKey) internal {
        if (status == PositionExecutionStatus.NONE) {
            status = PositionExecutionStatus.PARTIAL;
            IRouter(router).firstCallback(_isIncrease, _requestKey);
        } else if (status == PositionExecutionStatus.PARTIAL) {
            status = PositionExecutionStatus.NONE;
            IRouter(router).secondCallback(_isIncrease, _requestKey);
        }
    }

    function _failFallback(bool _isIncrease) internal {
        IRouter(router).failCallback(_isIncrease);
    }
}