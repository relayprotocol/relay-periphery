// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.13;

import {TestERC3009} from "./TestERC3009.sol";

/// @dev EIP-3009 token that withholds a fee on every transfer, so the payee
///      receives less than the authorized value.
contract TestERC3009Fee is TestERC3009 {
    /// @notice Basis points withheld on each transfer.
    uint256 public constant FEE_BPS = 100;

    address public constant FEE_SINK = address(0xFEE);

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from == address(0) || to == address(0) || to == FEE_SINK) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * FEE_BPS) / 10_000;
        super._update(from, FEE_SINK, fee);
        super._update(from, to, value - fee);
    }
}
