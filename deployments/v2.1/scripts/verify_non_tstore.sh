#!/bin/bash

# Get the verification flags from the deployment file
VERIFICATION_FLAGS=$(jq -c ".[] | select(.name == \"$CHAIN\") | .verificationFlags" "./deployments/$DEPLOYMENT_FILE")

if [ "$VERIFICATION_FLAGS" != "null" ]; then
    # Split the verification flags into an array
    expanded_verification_flags=(`echo $VERIFICATION_FLAGS | tr -d '"'`)

    # Verify the contracts using the above flags
    forge verify-contract ${expanded_verification_flags[@]} $RELAY_ROUTER ./src/v2.1/RelayRouterV2_1_NonTstore.sol:RelayRouterV2_1_NonTstore
    forge verify-contract ${expanded_verification_flags[@]} $RELAY_APPROVAL_PROXY ./src/v2.1/RelayApprovalProxyV2_1.sol:RelayApprovalProxyV2_1 --constructor-args $(cast abi-encode "constructor(address, address, address)" $DEPLOYER_ADDRESS $RELAY_ROUTER $PERMIT2)
else
    # Verify the contracts
    forge verify-contract --chain $CHAIN $RELAY_ROUTER ./src/v2.1/RelayRouterV2_1_NonTstore.sol:RelayRouterV2_1_NonTstore
    forge verify-contract --chain $CHAIN $RELAY_APPROVAL_PROXY ./src/v2.1/RelayApprovalProxyV2_1.sol:RelayApprovalProxyV2_1 --constructor-args $(cast abi-encode "constructor(address, address, address)" $DEPLOYER_ADDRESS $RELAY_ROUTER $PERMIT2)
fi