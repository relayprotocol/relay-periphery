// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {Call3Value, Result} from "./RelayV2_1Structs.sol";

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
    event SolverCallExecuted(address to, bytes data, uint256 amount);

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

            uint256 val = calli.value;
            (result.success, result.returnData) = calli.target.call{value: val}(calli.callData);

            // Make sure to bubble-up any reverts
            if (!calli.allowFailure && !result.success) {
                bytes memory revertData = result.returnData;
                assembly {
                    revert(add(revertData, 32), mload(revertData))
                }
            }

            if (result.success) {
                emit SolverCallExecuted(calli.target, calli.callData, calli.value);
            }

            unchecked {
                ++i;
            }
        }
    }
}
