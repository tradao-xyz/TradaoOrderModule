## Tradao Order Module

**A module to authorize owner to create orders on behalf of the user.**

The module complies to Biconomy Abstract Account Version 2.0.0. Contracts consists of:

-   **Gmxv2OrderModule**: Restrict the operator to only a few operations, include deploy Smart Account, pay gas and create order on behalf of the user.
-   **BiconomyModuleSetup**: Return module address.
-   **ProfitShare**: Calculate follower profit share ratio with a discount.

## Workflow

![Alt text](./doc/workflow.png?raw=true "Workflow")

## Addresses

### Arbitrum One

-   **Gmxv2OrderModule**: 0xdf55dac0d6651a13900c265133809d68635ae495
-   **ProfitShare**: 0xBA6Eed0E234e65124BeA17c014CAc502B4441D64
-   **Referrals**: 0xdb3643FE2693Beb1a78704E937F7C568FdeEeDdf

-   **Operator**: 0xad470962Ab06323C6C480bd94bEd4c23f8bA4D05
-   **Owner of Gmxv2OrderModule**: 0xB12f2EFA06A7e7b4569E750Fb83aD9060eAf2F06
-   **Owner of BiconomyModuleSetup**: 0xB12f2EFA06A7e7b4569E750Fb83aD9060eAf2F06
-   **Owner of ProfitShare**: 0xad470962Ab06323C6C480bd94bEd4c23f8bA4D05

### ALL

-   **BiconomyModuleSetup**: 0x32b9b615a3D848FdEFC958f38a529677A0fc00dD
-   **Deployer**: 0xB12f2EFA06A7e7b4569E750Fb83aD9060eAf2F06

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