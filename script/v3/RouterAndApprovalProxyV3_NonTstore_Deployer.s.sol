// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {RelayApprovalProxyV3} from "../../src/v3/RelayApprovalProxyV3.sol";
import {
    RelayRouterV3_NonTstore
} from "../../src/v3/RelayRouterV3_NonTstore.sol";

contract RouterAndApprovalProxyV3_NonTstore_Deployer is Script {
    // Thrown when the predicted address doesn't match the deployed address
    error IncorrectContractAddress(address predicted, address actual);

    // Modify for vanity address generation
    bytes32 public SALT = bytes32(uint256(1));

    function setUp() public {}

    function run() public {
        vm.createSelectFork(vm.envString("CHAIN"));

        vm.startBroadcast();

        RelayRouterV3_NonTstore router = RelayRouterV3_NonTstore(
            payable(deployRouter())
        );
        RelayApprovalProxyV3 approvalProxy = RelayApprovalProxyV3(
            payable(deployApprovalProxy(address(router)))
        );

        assert(approvalProxy.owner() == msg.sender);

        vm.stopBroadcast();
    }

    function deployRouter() public returns (address) {
        console2.log("Deploying RelayRouterV3_NonTstore");

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
                                    type(RelayRouterV3_NonTstore).creationCode
                                )
                            )
                        )
                    )
                )
            )
        );

        console2.log(
            "Predicted address for RelayRouterV3_NonTstore",
            predictedAddress
        );

        // Verify if the contract has already been deployed
        if (_hasBeenDeployed(predictedAddress)) {
            console2.log("RelayRouterV3_NonTstore was already deployed");
            return predictedAddress;
        }

        // Deploy
        RelayRouterV3_NonTstore router = new RelayRouterV3_NonTstore{
            salt: SALT
        }();

        // Ensure the predicted and actual addresses match
        if (predictedAddress != address(router)) {
            revert IncorrectContractAddress(predictedAddress, address(router));
        }

        console2.log("RelayRouterV3_NonTstore deployed");

        return address(router);
    }

    function deployApprovalProxy(address router) public returns (address) {
        console2.log("Deploying ApprovalProxyV3");

        address create2Factory = vm.envAddress("CREATE2_FACTORY");
        address permit2 = vm.envAddress("PERMIT2");

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
                                    type(RelayApprovalProxyV3).creationCode,
                                    abi.encode(msg.sender, router, permit2)
                                )
                            )
                        )
                    )
                )
            )
        );

        console2.log(
            "Predicted address for RelayApprovalProxyV3",
            predictedAddress
        );

        // Verify if the contract has already been deployed
        if (_hasBeenDeployed(predictedAddress)) {
            console2.log("RelayApprovalProxyV3 was already deployed");
            return predictedAddress;
        }

        // Deploy
        RelayApprovalProxyV3 approvalProxy = new RelayApprovalProxyV3{
            salt: SALT
        }(msg.sender, router, permit2);

        // Ensure the predicted and actual addresses match
        if (predictedAddress != address(approvalProxy)) {
            revert IncorrectContractAddress(
                predictedAddress,
                address(approvalProxy)
            );
        }

        console2.log("RelayApprovalProxyV3 deployed");

        return address(approvalProxy);
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
