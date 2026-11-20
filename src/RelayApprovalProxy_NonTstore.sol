// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {RelayApprovalProxyBase} from "./RelayApprovalProxyBase.sol";

contract RelayApprovalProxy_NonTstore is RelayApprovalProxyBase {
    constructor(address _owner, address _router, address _permit2)
        RelayApprovalProxyBase(_owner, _router, _permit2)
    {}

    function _load(bytes32 slot) internal view override returns (uint256 value) {
        assembly ("memory-safe") { value := sload(slot) }
    }

    function _store(bytes32 slot, uint256 value) internal override {
        assembly ("memory-safe") { sstore(slot, value) }
    }
}
