#!/bin/bash

forge script ./script/v3/RouterAndApprovalProxyV3Deployer.s.sol:RouterAndApprovalProxyV3Deployer \
    --slow \
    --broadcast \
    --private-key $DEPLOYER_PK \
    --create2-deployer $CREATE2_FACTORY