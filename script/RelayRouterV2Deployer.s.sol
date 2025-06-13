// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ApprovalProxy} from "../src/v2/ApprovalProxy.sol";
import {RelayRouter} from "../src/v2/RelayRouter.sol";

contract RelayRouterV2Deployer is Script {
    // Thrown when the predicted address doesn't match the deployed address
    error IncorrectContractAddress(address predicted, address actual);

    // Modify for vanity address generation
    bytes32 public SALT = bytes32(uint256(1));

    function setUp() public {}

    function run() public {
        vm.createSelectFork(vm.envString("CHAIN"));

        vm.startBroadcast();

        RelayRouter relayRouter = RelayRouter(payable(deployRelayRouter()));
        ApprovalProxy approvalProxy = ApprovalProxy(
            payable(deployApprovalProxy(address(relayRouter)))
        );

        assert(approvalProxy.owner() == msg.sender);
        assert(approvalProxy.router() == address(relayRouter));

        vm.stopBroadcast();
    }

    function deployRelayRouter() public returns (address) {
        console2.log("Deploying RelayRouter");

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
                                abi.encodePacked(type(RelayRouter).creationCode)
                            )
                        )
                    )
                )
            )
        );

        console2.log("Predicted address for RelayRouter", predictedAddress);

        // Verify if the contract has already been deployed
        if (_hasBeenDeployed(predictedAddress)) {
            console2.log("RelayRouter was already deployed");
            return predictedAddress;
        }

        // Deploy
        RelayRouter relayRouter = new RelayRouter{salt: SALT}();

        // Ensure the predicted and actual addresses match
        if (predictedAddress != address(relayRouter)) {
            revert IncorrectContractAddress(
                predictedAddress,
                address(relayRouter)
            );
        }

        console2.log("RelayRouter deployed");

        return address(relayRouter);
    }

    function deployApprovalProxy(address relayRouter) public returns (address) {
        console2.log("Deploying ApprovalProxy");

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
                                    type(ApprovalProxy).creationCode,
                                    abi.encode(msg.sender, relayRouter, permit2)
                                )
                            )
                        )
                    )
                )
            )
        );

        console2.log("Predicted address for ApprovalProxy", predictedAddress);

        // Verify if the contract has already been deployed
        if (_hasBeenDeployed(predictedAddress)) {
            console2.log("ApprovalProxy was already deployed");
            return predictedAddress;
        }

        // Deploy
        ApprovalProxy approvalProxy = new ApprovalProxy{salt: SALT}(
            msg.sender,
            relayRouter,
            permit2
        );

        // Ensure the predicted and actual addresses match
        if (predictedAddress != address(approvalProxy)) {
            revert IncorrectContractAddress(
                predictedAddress,
                address(approvalProxy)
            );
        }

        console2.log("ApprovalProxy deployed");

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
