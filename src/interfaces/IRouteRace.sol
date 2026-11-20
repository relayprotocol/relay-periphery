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

/// @notice The three race commands of the router: their selectors and their arguments.
/// @dev The router has no external function with these selectors, so a direct call reverts. A race
/// is a command of `multicall`: an entry of `calls` with the router as `target`, the encoded call
/// of one of these functions as `callData`, and `allowFailure` false. Only the outermost
/// `multicall` runs a race. A race with `allowFailure` true, and a race in a nested `multicall`,
/// revert with `InvalidNativeCommand`.
///
/// `flags` is a bit field with the same meaning in the three commands. Add the values to set more
/// than one bit. The other bits have no effect.
/// - 1 (`EMIT_EVENTS`): emit the race events `RouteTrialSucceeded`, `RouteTrialFailed`,
///   `RouteExecutionFailed` and `RouteRaceWon`. Not set: the race emits none of them.
/// - 2 (`KEEP_ALLOWANCES`), for an ERC-20 `tokenIn`: approve a spender for the maximum amount if
///   its allowance is below `amountIn`, and leave the allowances in place after the race. Not set:
///   approve each spender for `amountIn`, and set its allowance back to zero before the race ends.
/// - 4 (`DIRECT_OUTPUT`): the routes must send the output to `recipient`, and the router measures
///   the output as the increase of the balance of `recipient`. Not set: the routes must send the
///   output to the router, and the router sends `amountOut` to `recipient`.
/// - 8 (`NO_INPUT_REFUND`): leave in the router the ERC-20 input that the race did not spend. Not
///   set: send it to the `refundTo` of the `multicall`, or to the caller of the `multicall` if
///   `refundTo` is the zero address.
/// - 16 (`LOG_FUNDS_MOVEMENT`): emit `FundsMovement` from the router to `recipient` for `amountOut`
///   of `tokenOut`, with the `metadata` of the `multicall`. Not set, or `recipient` is the router:
///   no such event.
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
