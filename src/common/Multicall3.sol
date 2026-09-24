// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

struct Call3Value {
    address target;
    bool allowFailure;
    uint256 value;
    bytes callData;
}

struct Result {
    bool success;
    bytes returnData;
}

/// @title Multicall3
/// @notice Aggregate results from multiple function calls
/// @dev Multicall & Multicall2 backwards-compatible
/// @dev Aggregate methods are marked `payable` to save 24 gas per call
/// @dev This is a fork of the original Multicall3 contract with multicalls
/// @dev only executable by address(this). This contract is meant to be inherited
/// @dev by other contracts that need to perform multicalls.
/// @author Michael Elliot <mike@makerdao.com>
/// @author Joshua Levine <joshua@makerdao.com>
/// @author Nick Johnson <arachnid@notdot.net>
/// @author Andreas Bigger <andreas@nascent.xyz>
/// @author Matt Solomon <matt@mattsolomon.dev>
contract Multicall3 {
    /// @notice Revert if a call targets the zero address
    error InvalidTarget(address target);

    /// @notice Emitted for every solver call that succeeded, after it
    ///         returns. Calls are made in order, so the events of one
    ///         multicall land in call order; a nested multicall emits its own
    ///         calls' events before the enclosing call's event
    /// @dev    Carries `keccak256(callData)` rather than the calldata. The
    ///         calldata is already committed by the order the solver signed,
    ///         so a consumer that holds the order checks the hash instead of
    ///         paying for a copy of bytes it already has
    /// @param to The call's target
    /// @param dataHash `keccak256` of the call's calldata
    /// @param amount The native value forwarded with the call
    event SolverCallExecuted(address to, bytes32 dataHash, uint256 amount);

    /// @notice Aggregate calls
    /// @param calls An array of Call3Value structs
    /// @return returnData An array of Result structs
    function _aggregate3Value(Call3Value[] calldata calls) internal returns (Result[] memory returnData) {
        uint256 length = calls.length;
        returnData = new Result[](length);
        Call3Value calldata calli;

        for (uint256 i = 0; i < length;) {
            Result memory result = returnData[i];
            calli = calls[i];

            // A `CALL` to the zero address returns success and permanently
            // burns any value forwarded with it, and `SolverCallExecuted`
            // would then report the burn as a successful call. Reject it
            // regardless of `allowFailure`: a zero target is a malformed
            // call, not a failure worth tolerating.
            if (calli.target == address(0)) {
                revert InvalidTarget(address(0));
            }

            uint256 val = calli.value;
            // One copy of the calldata into memory serves both the call and
            // the hash below; passing the calldata slice to each would copy
            // it twice
            bytes memory callData = calli.callData;
            (result.success, result.returnData) = calli.target.call{value: val}(callData);

            // Make sure to bubble-up any reverts
            if (!calli.allowFailure && !result.success) {
                bytes memory revertData = result.returnData;
                assembly {
                    revert(add(revertData, 32), mload(revertData))
                }
            }

            if (result.success) {
                emit SolverCallExecuted(calli.target, keccak256(callData), val);
            }

            unchecked {
                ++i;
            }
        }
    }
}
