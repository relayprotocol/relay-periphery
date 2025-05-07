// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract Counter {
    uint256 public count;
    
    constructor() {
        count = 0;
    }

    function increment() public {
        count++;
    }
}