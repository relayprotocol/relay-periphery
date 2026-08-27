#!/bin/bash

export FOUNDRY_PROFILE=london

# The london profile cannot compile the transient-storage sources, so skip
# them (and everything that imports them) instead of pointing --contracts at
# a source subset: the flattened src/ layout no longer separates them by path.
forge script ./script/RouterAndApprovalProxy_NonTstore_Deployer.s.sol:RouterAndApprovalProxy_NonTstore_Deployer \
    --slow \
    --broadcast \
    --skip Test.sol \
    --skip RelayRouter.sol \
    --skip ReentrancyGuardMsgSender.sol \
    --skip RouterAndApprovalProxyDeployer.s.sol \
    --private-key $DEPLOYER_PK \
    --create2-deployer $CREATE2_FACTORY --legacy