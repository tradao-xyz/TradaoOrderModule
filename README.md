## Tradao Order Module

**A module to authorize owner to create orders on behalf of the user.**

The module complies to Biconomy Abstract Account Version 2.0.0.

Contracts consists of:

-   **Gmxv2OrderModule**: Verify authorization, build order params, pay gas, send collateral to GMX Vault to create order on behalf of the user.
-   **BiconomyModuleSetup**: Return module address.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
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
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
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
