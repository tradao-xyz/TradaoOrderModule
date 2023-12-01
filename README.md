## Tradao Order Module

**A module to authorize owner to create orders on behalf of the user.**

The module complies to Biconomy Abstract Account Version 2.0.0.

Contracts consists of:

-   **Gmxv2OrderModule**: Verify authorization, build order params, pay gas, send collateral to GMX Vault to create order on behalf of the user.
-   **BiconomyModuleSetup**: Return module address.

## Workflow

![Alt text](./doc/workflow.png?raw=true "Workflow")

## Addresses (test)

-   **Gmxv2OrderModule**: 0xA561292b36130cDA72aCA87F485BE4C1f8A64758
-   **BiconomyModuleSetup**: 0x2692b7d240288fEEA31139d4067255E31Fe71a79
-   **TimelockController**: 
-   **Operator**: 0xAbc2E7AAD178C8f3DF2bdE0d1F2ae8a4DCdFcbD7
-   **Owner of Gmxv2OrderModule**: 0xAbc2E7AAD178C8f3DF2bdE0d1F2ae8a4DCdFcbD7
-   **Owner of BiconomyModuleSetup**: TimelockController
-   **Proposer and Executor of TimelockController**: 0xAbc2E7AAD178C8f3DF2bdE0d1F2ae8a4DCdFcbD7

## Usage

### Build

```shell
$ forge build
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge create --rpc-url https://arb1.arbitrum.io/rpc \
    --private-key <key> \
    --etherscan-api-key <key> \
    --gas-limit 67024456 \
    --gas-price 0.1gwei \
    --legacy \
    --verify \
    src/Gmxv2OrderModule.sol:Gmxv2OrderModule \
    --constructor-args <operator>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
