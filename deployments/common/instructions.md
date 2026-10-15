There is a single deployment script that needs to be triggered for every new chain, `./script/common/OnlyOwnerMulticallerDeployer.s.sol`

The script requires the following environment variables:

- `DEPLOYER_PK`: the private key of the deployer wallet
- `CHAIN`: the chain to deploy on (the available options can be found in `./foundry.toml`)
- `CREATE2_FACTORY`: the address of the `CREATE2` factory to be used for deterministic deployments - the default factory should be deployed at `0x4e59b44847b379578588920ca78fbf26c0b4956c`, in case it's not available on a given chain we should deploy it there or otherwise use a different factory
- `OWNER`: the address that will own the multicaller (must be the same across all chains to produce a canonical deployment address)
- `ETHERSCAN_API_KEY`: the API key needed to verify the contracts on Etherscan-powered explorers

> **Note on canonical addresses:** The deployed address is derived from the CREATE2 factory address, the salt, and the contract creation bytecode (which includes the `OWNER` constructor argument). To get the same address on every chain, ensure `CREATE2_FACTORY`, `SALT`, and `OWNER` are identical. The project's `foundry.toml` sets `bytecode_hash = "none"` and `cbor_metadata = false` to strip non-deterministic compiler metadata from the bytecode.

### Deployment

The deployment can be triggered via the following command:

```bash
forge script ./script/common/OnlyOwnerMulticallerDeployer.s.sol:OnlyOwnerMulticallerDeployer \
    --slow \
    --multi \
    --broadcast \
    --verify \
    --private-key $DEPLOYER_PK \
    --create2-deployer $CREATE2_FACTORY
```

The script will automatically skip deployment if the contract already exists at the predicted address.

### Verification

The above script should do the deployment and verification altogether. However, in cases when the verification failed for some reason, it can be triggered individually via the following command:

```bash
forge verify-contract \
    --chain $CHAIN \
    --constructor-args $(cast abi-encode "constructor(address)" $OWNER) \
    $ONLY_OWNER_MULTICALLER \
    ./src/common/OnlyOwnerMulticaller.sol:OnlyOwnerMulticaller
```

In case `forge` doesn't have any default explorer for a given chain, make sure to pass the following extra arguments to the `forge verify-contract` command: `--verifier-url $VERIFIER_URL --etherscan-api-key $VERIFIER_API_KEY`.
