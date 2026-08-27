// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @dev ERC-2612 permit data. There is deliberately no `nonce` field: the
///      nonce is derived on-chain from the token's own `nonces(owner)`
///      counter, so a caller-supplied nonce is never read and only signals
///      replay protection that does not exist.
struct Permit2612 {
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
