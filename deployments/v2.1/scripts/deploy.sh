#!/bin/bash

forge script ./script/RouterAndApprovalProxyV2_1Deployer.s.sol:RouterAndApprovalProxyV2_1Deployer \
    --slow \
    --broadcast \
    --private-key $DEPLOYER_PK \
    --create2-deployer $CREATE2_FACTORY