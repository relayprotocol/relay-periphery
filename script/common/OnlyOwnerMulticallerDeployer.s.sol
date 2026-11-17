// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {OnlyOwnerMulticaller} from "../../src/common/OnlyOwnerMulticaller.sol";

contract OnlyOwnerMulticallerDeployer is Script {
    // Thrown when the predicted address doesn't match the deployed address
    error IncorrectContractAddress(address predicted, address actual);

    // Modify for vanity address generation
    bytes32 public SALT = bytes32(uint256(1));

    function setUp() public {}

    function run() public {
        vm.createSelectFork(vm.envString("CHAIN"));

        vm.startBroadcast();

        deployOnlyOwnerMulticaller(vm.envAddress("OWNER"));

        vm.stopBroadcast();
    }

    function deployOnlyOwnerMulticaller(address owner) public returns (address) {
        console2.log("Deploying OnlyOwnerMulticaller");

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
                                    type(OnlyOwnerMulticaller).creationCode,
                                    abi.encode(owner)
                                )
                            )
                        )
                    )
                )
            )
        );

        console2.log("Predicted address for OnlyOwnerMulticaller", predictedAddress);

        // Verify if the contract has already been deployed
        if (_hasBeenDeployed(predictedAddress)) {
            console2.log("OnlyOwnerMulticaller was already deployed");
            return predictedAddress;
        }

        // Deploy
        OnlyOwnerMulticaller multicaller = new OnlyOwnerMulticaller{salt: SALT}(owner);

        // Ensure the predicted and actual addresses match
        if (predictedAddress != address(multicaller)) {
            revert IncorrectContractAddress(
                predictedAddress,
                address(multicaller)
            );
        }

        console2.log("OnlyOwnerMulticaller deployed");

        return address(multicaller);
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
