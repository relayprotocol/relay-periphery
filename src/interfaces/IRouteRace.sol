// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IRelayRouter} from "./IRelayRouter.sol";

/// @dev `packed` carries the target in bits 0-159, the gas cap in bits 160-223, the fee in parts
/// per million in bits 224-254, and in bit 255 whether the target is also the spender to approve,
/// in which case `spender` is ignored.
struct Route {
    uint256 packed;
    address spender;
    uint256 value;
    bytes callData;
}

library RouteLib {
    error RouteFieldTooLarge();

    uint256 internal constant GAS_LIMIT_SHIFT = 160;
    uint256 internal constant FEE_SHIFT = 224;
    uint256 internal constant APPROVE_TARGET = 1 << 255;

    function pack(address target, uint256 gasLimit, uint256 feePpm, bool approveTarget)
        internal
        pure
        returns (uint256 packed)
    {
        if (gasLimit > type(uint64).max || feePpm > type(uint32).max >> 1) revert RouteFieldTooLarge();
        packed = uint256(uint160(target)) | gasLimit << GAS_LIMIT_SHIFT | feePpm << FEE_SHIFT;
        if (approveTarget) packed |= APPROVE_TARGET;
    }

    function targetOf(uint256 packed) internal pure returns (address) {
        return address(uint160(packed));
    }

    function gasLimitOf(uint256 packed) internal pure returns (uint256) {
        return uint64(packed >> GAS_LIMIT_SHIFT);
    }

    function feePpmOf(uint256 packed) internal pure returns (uint256) {
        return (packed << 1) >> (FEE_SHIFT + 1);
    }
}

interface IRouteRace is IRelayRouter {
    function raceSingle(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        address recipient,
        uint256 flags,
        Route[] calldata routes
    ) external payable returns (uint256 winnerIndex, uint256 amountOut);

    function race(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        address recipient,
        uint256 flags,
        Route[] calldata routes
    ) external payable returns (uint256 winnerIndex, uint256 amountOut);

    function raceWithBackups(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        address recipient,
        uint256 flags,
        Route[] calldata routes,
        uint256 mainCount
    ) external payable returns (uint256 winnerIndex, uint256 amountOut);
}
