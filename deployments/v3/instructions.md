There is a single deployment script that needs to be triggered for every new chain, `./script/RouterAndApprovalProxyDeployer.s.sol` or `./script/RouterAndApprovalProxy_NonTstore_Deployer.s.sol` (depending on the EVM version supported by the chain)

Both scripts require the following environment variables:

- `DEPLOYER_PK`: the private key of the deployer wallet (any funded key: it only pays gas)
- `OWNER`: the address to set as the `ApprovalProxy` owner - since it is a constructor argument it is part of the `CREATE2` input, so pinning it keeps the proxy address identical on every chain regardless of which key broadcasts (the canonical owner is `0x463cB782c8dd0a1887b77336DfF74D60F006F56E`)
- `CHAIN`: the chain to deploy on (the available options can be found in `./foundry.toml`)
- `CREATE2_FACTORY`: the addres of the `CREATE2` factory to be used for deterministic deployments - the default factory should be deployed at `0x4e59b44847b379578588920ca78fbf26c0b4956c`, in case it's not available on a given chain we should deploy it there or otherwise use a different factory
- `PERMIT2`: the address of the `PERMIT2` contract to use for `ApprovalProxy` - the default permit2 should be deployed at `0x000000000022d473030f116ddee9f6b43ac78ba3`, in case it's not available on a given chain we should deploy it there or otherwise use a different permit2
- `ETHERSCAN_API_KEY`: the API key needed to verify the contracts on Etherscan-powered explorers

### Before deploying 3.2

Router 3.2 changes the `SolverCallExecuted` event: it emits `keccak256(callData)` as
`bytes32 dataHash` instead of the calldata, so the event's topic changes. The oracle's
`verifySolverCalls` must accept that shape before any 3.2 router takes fills, or every
fill on that chain fails attestation until it does. The oracle release that decodes both
shapes has to be live first. `RelayApprovalProxy` has no code change and stays at version 3.1;
its version string is the EIP-712 domain version that multicall authorizations are signed
against, so it only moves when the proxy itself changes. It is still redeployed at a new
address, because the router address is one of its constructor arguments and part of its
CREATE2 input.

3.2 is the first version compiled with `optimizer_runs = 1_000_000` (see `foundry.toml`); 3.0
and 3.1 were compiled at the compiler default of 200. Compiler settings are part of the
creation code and therefore of every CREATE2 address, so:

- Deploy 3.2 from the repo as is. The solver registry expects the addresses that this build
  produces; a different setting lands somewhere else and never verifies.
- Record `"optimizerRuns": 1000000` on every 3.2 entry in `addresses.json`. Entries without
  the field were compiled at 200.
- To re verify a 3.0 or 3.1 contract on an explorer from this repo, pass
  `--optimizer-runs 200` to `forge verify-contract` (or check out the commit that deployed it).
- Deploy `RelayReceiver` with `FOUNDRY_PROFILE=receiver` (200 runs) so new chains get the same
  receiver address as the existing ones. See `script/receiver/ReceiverDeployer.s.sol`.

### Deployment

The deployment can be triggered via the following command:

```bash
forge script ./script/RouterAndApprovalProxyDeployer.s.sol:RouterAndApprovalProxyDeployer \
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
forge verify-contract --chain $CHAIN $RELAY_ROUTER ./src/RelayRouter.sol:RelayRouter

# RelayApprovalProxy
forge verify-contract --chain $CHAIN $RELAY_APPROVAL_PROXY ./src/RelayApprovalProxy.sol:RelayApprovalProxy --constructor-args $(cast abi-encode "constructor(address, address, address)" $OWNER $RELAY_ROUTER $PERMIT2)
```

In case `forge` doesn't have any default explorer for a given chain, make sure to pass the following extra arguments to the `forge verify-contract` commands: `--verifier-url $VERIFIER_URL --etherscan-api-key $VERIFIER_API_KEY`.

### Legacy EVM versions deployment

Some chains do not support the default EVM version used by the contracts (Cancun). In that case, we default to compiling using the London EVM version. Since that version does not support features like transient storage, we need to use the `_NonTstore` version of the `RelayRouter`. This implies two things:

- use the `RouterAndApprovalProxy_NonTstore_Deployer` script (`./script/RouterAndApprovalProxy_NonTstore_Deployer.s.sol`)
- adjust the `forge script` command by passing `--skip Test.sol --skip RelayRouter.sol --skip ReentrancyGuardMsgSender.sol --skip RouterAndApprovalProxyDeployer.s.sol` (this makes `forge` skip the transient-storage sources and everything that imports them, which the London EVM version cannot compile) — `./deployments/v3/scripts/deploy_non_tstore.sh` already does this
