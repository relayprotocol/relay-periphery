#!/bin/bash

export FOUNDRY_PROFILE=london

forge script ./script/v2.1/RouterAndApprovalProxyV2_1_NonTstore_Deployer.s.sol:RouterAndApprovalProxyV2_1_NonTstore_Deployer \
    --slow \
    --broadcast \
    --contracts ./src/v2.1/Relay \
    --private-key $DEPLOYER_PK \
    --create2-deployer $CREATE2_FACTORY \
    --legacy