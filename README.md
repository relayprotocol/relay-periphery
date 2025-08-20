# Relay periphery contracts

### Install dependencies

Install all required dependencies using the following command:

```bash
git submodule update --init --recursive
```

### Deployment instructions

See the [deployments](./deployments/index.md) section for instructions on how to deploy the relevant contracts.

### Build

```shell
$ forge build
```

### Test

The tests should be run on the latest Ethereum fork, as follows:

```shell
$ forge test --fork-url https://rpc.flashbots.net
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```
