// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {RelayRouterBase} from "./RelayRouterBase.sol";

contract RelayRouter is RelayRouterBase {
    function _load(bytes32 slot) internal view override returns (uint256 value) {
        assembly ("memory-safe") { value := tload(slot) }
    }

    function _store(bytes32 slot, uint256 value) internal override {
        assembly ("memory-safe") { tstore(slot, value) }
    }
}
