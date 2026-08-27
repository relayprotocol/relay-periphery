#!/bin/bash

forge script ./script/RouterAndApprovalProxyDeployer.s.sol:RouterAndApprovalProxyDeployer \
    --slow \
    --broadcast \
    --private-key $DEPLOYER_PK \
    --create2-deployer $CREATE2_FACTORY