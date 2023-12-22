## Tradao Order Module

**A module to authorize owner to create orders on behalf of the user.**

The module complies to Biconomy Abstract Account Version 2.0.0. Contracts consists of:

-   **Gmxv2OrderModule**: Restrict the operator to only a few operations, include deploy Smart Account, pay gas and create order on behalf of the user.
-   **BiconomyModuleSetup**: Return module address.

## Workflow

![Alt text](./doc/workflow.png?raw=true "Workflow")

## Addresses (Arbitrum One test)

-   **Gmxv2OrderModule**: 0x06a3BBADE730771E5b4a9d7a5cfdD5Af6f37Cb65
-   **BiconomyModuleSetup**: 0x2692b7d240288fEEA31139d4067255E31Fe71a79
-   **TimelockController**: 
-   **Operator**: 0xAbc2E7AAD178C8f3DF2bdE0d1F2ae8a4DCdFcbD7
-   **Owner of Gmxv2OrderModule**: 0x9a970aF3978198fe88eDdb3c8FCa1915e2CBb2d8
-   **Owner of BiconomyModuleSetup**: TimelockController
-   **Proposer and Executor of TimelockController**: 0x9a970aF3978198fe88eDdb3c8FCa1915e2CBb2d8
-   **Referrals**: 0xC8F9b1A0a120eFA05EEeb28B10b14FdE18Bb0F50

## Usage

### Build

```shell
$ forge build
```

### Deploy

```shell
$ forge create --rpc-url https://arb1.arbitrum.io/rpc \
    --private-key <key> \
    --etherscan-api-key <key> \
    --gas-limit <gasLimit> \
    --gas-price 0.1gwei \
    --legacy \
    --verify \
    src/Gmxv2OrderModule.sol:Gmxv2OrderModule \
    --constructor-args <operator>
```

## Audit

https://github.com/peckshield/publications/tree/master/audit_reports/PeckShield-Audit-Report-Tradao-v1.0.pdf