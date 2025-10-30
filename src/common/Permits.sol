// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

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

struct Permit3009 {
    address from;
    uint256 value;
    uint256 validAfter;
    uint256 validBefore;
    uint8 v;
    bytes32 r;
    bytes32 s;
}
