// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

contract Counter {
    uint256 public count;
    string public name;
    
    constructor() {
        count = 0;
        name = "Counter";
    }

    function increment() public {
        count++;
    }

    function decrement() public {
        count--;
    }
}