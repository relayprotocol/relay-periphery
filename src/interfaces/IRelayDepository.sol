// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

interface IRelayDepository {
    function depositNative(address depositor, bytes32 id) external payable;

    function depositErc20(address depositor, address token, bytes32 id) external;
}
