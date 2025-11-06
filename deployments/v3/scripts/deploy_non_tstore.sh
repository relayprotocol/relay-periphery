#!/bin/bash

export FOUNDRY_PROFILE=london

forge script ./script/v3/RouterAndApprovalProxyV3_NonTstore_Deployer.s.sol:RouterAndApprovalProxyV3_NonTstore_Deployer \
    --slow \
    --broadcast \
    --contracts ./src/v3/Relay \
    --private-key $DEPLOYER_PK \
    --create2-deployer $CREATE2_FACTORY --legacy