// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @dev Used by RelayApprovalProxyV2_1. Retains the unused `nonce` field so
///      that the deployed V2.1 ABI and function selectors are unchanged. New
///      code should use `Permit2612V3`.
struct Permit2612 {
    address token;
    address owner;
    uint256 value;
    uint256 nonce;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

/// @dev `Permit2612` without the `nonce` field. ERC-2612 derives the nonce
///      on-chain from the token's own `nonces(owner)` counter, so a
///      caller-supplied nonce is never read and only signals replay protection
///      that does not exist.
struct Permit2612V3 {
    address token;
    address owner;
    uint256 value;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

struct Permit3009 {
    address from;
    uint256 value;
    uint256 validAfter;
    uint256 validBefore;
    uint8 v;
    bytes32 r;
    bytes32 s;
}
