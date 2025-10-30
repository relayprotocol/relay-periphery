// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {RelayReceiver} from "../../src/receiver/RelayReceiver.sol";

contract RelayReceiverDeployer is Script {
    // Thrown when the predicted address doesn't match the deployed address
    error IncorrectContractAddress(address predicted, address actual);

    // Modify for vanity address generation
    bytes32 public SALT = bytes32(uint256(1));

    function setUp() public {}

    function run() public {
        vm.createSelectFork(vm.envString("CHAIN"));

        vm.startBroadcast();

        deployRelayReceiver(vm.envAddress("SOLVER"));

        vm.stopBroadcast();
    }

    function deployRelayReceiver(address solver) public returns (address) {
        console2.log("Deploying RelayReceiver");

        address create2Factory = vm.envAddress("CREATE2_FACTORY");

        // Compute predicted address
        address predictedAddress = address(
            uint160(
                uint(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            create2Factory,
                            SALT,
                            keccak256(
                                abi.encodePacked(
                                    type(RelayReceiver).creationCode,
                                    abi.encode(solver)
                                )
                            )
                        )
                    )
                )
            )
        );

        console2.log("Predicted address for RelayReceiver", predictedAddress);

        // Verify if the contract has already been deployed
        if (_hasBeenDeployed(predictedAddress)) {
            console2.log("RelayReceiver was already deployed");
            return predictedAddress;
        }

        // Deploy
        RelayReceiver relayReceiver = new RelayReceiver{salt: SALT}(solver);

        // Ensure the predicted and actual addresses match
        if (predictedAddress != address(relayReceiver)) {
            revert IncorrectContractAddress(
                predictedAddress,
                address(relayReceiver)
            );
        }

        console2.log("RelayReceiver deployed");

        return address(relayReceiver);
    }

    function _hasBeenDeployed(
        address addressToCheck
    ) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addressToCheck)
        }
        return (size > 0);
    }
}
