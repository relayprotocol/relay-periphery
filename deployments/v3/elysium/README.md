# Elysium: deployment setup

Adds a Foundry RPC alias and a deployment record example. The router version and EVM target require confirmation before deployment.

## Files

- `foundry.toml`: RPC alias `elysium`.
- `deployment.env.example`: environment inputs for the existing script `script/RouterAndApprovalProxyDeployer.s.sol:RouterAndApprovalProxyDeployer`.
- `deployment.json.example`: fields for `deployments/v3/addresses.json`.

Use a separate environment file for each deployment. The templates contain no signing key. A production deployment requires explicit authorization for that specific action.

## Complete this draft

- [ ] Confirm mainnet chain ID, RPC, explorer, and EVM support.
- [ ] Select the router version required for launch and the October 26 transition.
- [ ] Verify CREATE2 factory and Permit2 bytecode; confirm the approval proxy owner.
- [ ] Simulate the selected deployment script with the intended sender.
- [ ] Record deployed addresses and transaction hashes; verify bytecode and source.
- [ ] Move the completed record into `deployments/v3/addresses.json`.

## Network data

The [official specifications](https://elysium.kinetiq.xyz/docs/chain-specifications) publish chain ID `99801` for testnet. Mainnet details remain pending as of October 16, 2026. All `ELYSIUM_` markers in the examples require confirmed mainnet values. Numeric markers must become JSON numbers where the target schema requires numbers.

The examples stay outside the active address records. Keep this PR in draft until the remaining steps pass.
