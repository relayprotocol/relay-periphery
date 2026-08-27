#!/bin/bash

export FOUNDRY_PROFILE=london

forge script ./script/RouterAndApprovalProxy_NonTstore_Deployer.s.sol:RouterAndApprovalProxy_NonTstore_Deployer \
    --slow \
    --broadcast \
    --contracts ./src/Relay \
    --private-key $DEPLOYER_PK \
    --create2-deployer $CREATE2_FACTORY --legacy