There is a single deployment script that needs to be triggered for every new chain, `./script/v3/RouterAndApprovalProxyV3Deployer.s.sol` or `./script/v3/RouterAndApprovalProxyV3Deployer_NonTstore.s.sol` (depending on the EVM version supported by the chain)

Both scripts require the following environment variables:

- `DEPLOYER_PK`: the private key of the deployer wallet
- `CHAIN`: the chain to deploy on (the available options can be found in `./foundry.toml`)
- `CREATE2_FACTORY`: the addres of the `CREATE2` factory to be used for deterministic deployments - the default factory should be deployed at `0x4e59b44847b379578588920ca78fbf26c0b4956c`, in case it's not available on a given chain we should deploy it there or otherwise use a different factory
- `PERMIT2`: the address of the `PERMIT2` contract to use for `ApprovalProxy` - the default permit2 should be deployed at `0x000000000022d473030f116ddee9f6b43ac78ba3`, in case it's not available on a given chain we should deploy it there or otherwise use a different permit2
- `ETHERSCAN_API_KEY`: the API key needed to verify the contracts on Etherscan-powered explorers

### Deployment

The deployment can be triggered via the following command:

```bash
forge script ./script/v3/RouterAndApprovalProxyV3Deployer.s.sol:RouterAndApprovalProxyV3Deployer \
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
# RelayRouter
forge verify-contract --chain $CHAIN $RELAY_ROUTER ./src/v3/RelayRouterV3.sol:RelayRouterV3

# RelayApprovalProxy
forge verify-contract --chain $CHAIN $RELAY_APPROVAL_PROXY ./src/v3/RelayApprovalProxyV3.sol:RelayApprovalProxyV3 --constructor-args $(cast abi-encode "constructor(address, address, address)" $DEPLOYER_ADDRESS $RELAY_ROUTER $PERMIT2)
```

In case `forge` doesn't have any default explorer for a given chain, make sure to pass the following extra arguments to the `forge verify-contract` commands: `--verifier-url $VERIFIER_URL --etherscan-api-key $VERIFIER_API_KEY`.

### Legacy EVM versions deployment

Some chains do not support the default EVM version used by the contracts (Cancun). In that case, we default to compiling using the London EVM version. Since that version does not support features like transient storage, we need to use the `_NonTstore` version of the `RelayRouterV3`. This implies two things:

- use the `RouterAndApprovalProxyV3_NonTstoreDeployer` script
- adjust the `forge script` command by passing `--contracts src/v3/Relay*` (this will result in `forge` skipping compilation for some files that use unsupported features)
