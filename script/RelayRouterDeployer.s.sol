// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Script.sol";

import {RelayRouter} from "../src/v2/RelayRouter.sol";

contract RelayRouterDeployer is Script {
    function run() public {
        // Utilizes the locally-defined DEPLOYER_PRIVATE_KEY environment variable to sign txs
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));

        // Deploy RelayRouter
        new RelayRouter();

        vm.stopBroadcast();
    }
}
