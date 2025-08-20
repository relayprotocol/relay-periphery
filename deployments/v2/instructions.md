IMPORTANT! Make sure you're on commit [`7cea29ad`](https://github.com/relayprotocol/relay-periphery/tree/7cea29ad)!

There are two deployment scripts that need to be triggered for every new chain:

- v1: `./script/RelayReceiverV1Deployer.s.sol` (legacy contract that we still want to maintain)
- v2: `./script/RelayRouterV2Deployer.s.sol` or `./script/RelayRouter_NonTstoreV2Deployer.s.sol` (depending on the EVM version supported by the chain)

Both scripts require the following environment variables:

- `DEPLOYER_PK`: the private key of the deployer wallet
- `CHAIN`: the chain to deploy on (the available options can be found in `./foundry.toml`)
- `CREATE2_FACTORY`: the addres of the `CREATE2` factory to be used for deterministic deployments - the default factory should be deployed at `0x4e59b44847b379578588920ca78fbf26c0b4956c`, in case it's not available on a given chain we should deploy it there or otherwise use a different factory
- `ETHERSCAN_API_KEY`: the API key needed to verify the contracts on Etherscan-powered explorers

In addition, the v1 script requires the following environment variables:

- `SOLVER`: the address of the solver tied to the `RelayReceiver` contract

In addition, the v2 script requires the following environment variables:

- `PERMIT2`: the address of the `PERMIT2` contract to use for `ApprovalProxy` - the default permit2 should be deployed at `0x000000000022d473030f116ddee9f6b43ac78ba3`, in case it's not available on a given chain we should deploy it there or otherwise use a different permit2

### Deployment

The deployment can be triggered via the following command:

```bash
forge script ./script/RelayReceiverV1Deployer.s.sol:RelayReceiverV1Deployer \
    --slow \
    --multi \
    --broadcast \
    --verify \
    --private-key $DEPLOYER_PK \
    --create2-deployer $CREATE2_FACTORY
```

```bash
forge script ./script/RelayRouterV2Deployer.s.sol:RelayRouterV2Deployer \
    --slow \
    --multi \
    --broadcast \
    --verify \
    --private-key $DEPLOYER_PK \
    --create2-deployer $CREATE2_FACTORY
```

Do not forget to add the corresponding deployment information to the `./addresses.json` file! Also, please ensure all deployed contracts are verified!

### Verification

The above script should do the deployment and verification altogether. However, in cases when the verification failed for some reason, it can be triggered individually via the following commands:

```bash
# RelayReceiver
forge verify-contract --chain $CHAIN $RELAY_RECEIVER ./src/v2/RelayReceiver.sol:RelayReceiver

# RelayRouter
forge verify-contract --chain $CHAIN $RELAY_ROUTER ./src/v2/RelayRouter.sol:RelayRouter

# ApprovalProxy
forge verify-contract --chain $CHAIN $APPROVAL_PROXY ./src/v2/ApprovalProxy.sol:ApprovalProxy --constructor-args $(cast abi-encode "constructor(address, address, address)" $DEPLOYER_ADDRESS $RELAY_ROUTER $PERMIT2)
```

In case `forge` doesn't have any default explorer for a given chain, make sure to pass the following extra arguments to the `forge verify-contract` commands: `--verifier-url $VERIFIER_URL --etherscan-api-key $VERIFIER_API_KEY`.
