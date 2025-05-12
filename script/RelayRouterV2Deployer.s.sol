// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";

import {ApprovalProxy} from "../src/v2/ApprovalProxy.sol";
import {RelayRouter} from "../src/v2/RelayRouter.sol";

contract RelayRouterV2Deployer is Script {
    address public constant PERMIT2 =
        0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function setUp() public {}

    function run() public {
        vm.createSelectFork(vm.envString("CHAIN"));

        vm.startBroadcast();

        RelayRouter relayRouter = new RelayRouter();
        ApprovalProxy approvalProxy = new ApprovalProxy(
            msg.sender,
            address(relayRouter),
            PERMIT2
        );

        assert(approvalProxy.owner() == msg.sender);
        assert(approvalProxy.router() == address(relayRouter));

        vm.stopBroadcast();
    }
}
