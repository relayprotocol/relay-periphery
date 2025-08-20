// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {RelayApprovalProxyV2_1} from "../src/v2.1/RelayApprovalProxyV2_1.sol";
import {RelayRouterV2_1} from "../src/v2.1/RelayRouterV2_1.sol";

contract RouterAndApprovalProxyV2_1Deployer is Script {
    // Thrown when the predicted address doesn't match the deployed address
    error IncorrectContractAddress(address predicted, address actual);

    // Modify for vanity address generation
    bytes32 public SALT = bytes32(uint256(1));

    function setUp() public {}

    function run() public {
        vm.createSelectFork(vm.envString("CHAIN"));

        vm.startBroadcast();

        RelayRouterV2_1 router = RelayRouterV2_1(payable(deployRouter()));
        RelayApprovalProxyV2_1 approvalProxy = RelayApprovalProxyV2_1(
            payable(deployApprovalProxy(address(router)))
        );

        assert(approvalProxy.owner() == msg.sender);
        assert(approvalProxy.router() == address(router));

        vm.stopBroadcast();
    }

    function deployRouter() public returns (address) {
        console2.log("Deploying RelayRouterV2_1");

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
                                abi.encodePacked(type(RelayRouterV2_1).creationCode)
                            )
                        )
                    )
                )
            )
        );

        console2.log("Predicted address for RelayRouterV2_1", predictedAddress);

        // Verify if the contract has already been deployed
        if (_hasBeenDeployed(predictedAddress)) {
            console2.log("RelayRouterV2_1 was already deployed");
            return predictedAddress;
        }

        // Deploy
        RelayRouterV2_1 router = new RelayRouterV2_1{salt: SALT}();

        // Ensure the predicted and actual addresses match
        if (predictedAddress != address(router)) {
            revert IncorrectContractAddress(
                predictedAddress,
                address(router)
            );
        }

        console2.log("RelayRouterV2_1 deployed");

        return address(router);
    }

    function deployApprovalProxy(address router) public returns (address) {
        console2.log("Deploying ApprovalProxyV2_1");

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
                                    type(RelayApprovalProxyV2_1).creationCode,
                                    abi.encode(msg.sender, router, permit2)
                                )
                            )
                        )
                    )
                )
            )
        );

        console2.log("Predicted address for RelayApprovalProxyV2_1", predictedAddress);

        // Verify if the contract has already been deployed
        if (_hasBeenDeployed(predictedAddress)) {
            console2.log("RelayApprovalProxyV2_1 was already deployed");
            return predictedAddress;
        }

        // Deploy
        RelayApprovalProxyV2_1 approvalProxy = new RelayApprovalProxyV2_1{salt: SALT}(
            msg.sender,
            router,
            permit2
        );

        // Ensure the predicted and actual addresses match
        if (predictedAddress != address(approvalProxy)) {
            revert IncorrectContractAddress(
                predictedAddress,
                address(approvalProxy)
            );
        }

        console2.log("RelayApprovalProxyV2_1 deployed");

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