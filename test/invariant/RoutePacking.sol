// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Route, RouteLib} from "../../src/interfaces/IRouteRace.sol";

function packRoute(
    address target,
    address spender,
    uint256 value,
    uint256 gasLimit,
    uint256 feePpm,
    bytes memory callData
) pure returns (Route memory) {
    bool approveTarget = spender == target;
    return Route(
        RouteLib.pack(target, gasLimit, feePpm, approveTarget), approveTarget ? address(0) : spender, value, callData
    );
}
