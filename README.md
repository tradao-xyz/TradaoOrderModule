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

-   **Gmxv2OrderModule**: 0x583bBB891C478A6D2a312dc1c31d51279F7f6a5d
-   **ProfitShare**: 0xBA6Eed0E234e65124BeA17c014CAc502B4441D64
-   **Referrals**: 0xdb3643FE2693Beb1a78704E937F7C568FdeEeDdf

<br />

-   **TimelockController**: 0xF66ba754cA6bF5f333DF02ba159963297a8e965A
-   **BatchTokenTransfer**: 0x717088c0d8Ddc9dDaD26fe8E3d2E0fb15d7aD0A9
-   **RebatePlugin**: 0x51d36c03bfE0ACAe2b16bA149B3A2D987496bfA3

<br />

-   **Operator**: 0xad470962Ab06323C6C480bd94bEd4c23f8bA4D05, 0xAbc2E7AAD178C8f3DF2bdE0d1F2ae8a4DCdFcbD7
-   **Owner of Gmxv2OrderModule**: 0x9a970aF3978198fe88eDdb3c8FCa1915e2CBb2d8 (multisig, [transaction](https://arbiscan.io/tx/0x63625559add48e45882c990fac0c34bbae9d31e07c9c5cac3a5b7c050de7a488))
-   **Owner of BiconomyModuleSetup**: 0xF66ba754cA6bF5f333DF02ba159963297a8e965A (TimelockController, [transaction](https://arbiscan.io/tx/0xcf0cbb1d0ebaec37f9e6cacfc63ed70875fd7fca760dfaf1d1892e2833df8100))
-   **Owner of ProfitShare**: 0x9a970aF3978198fe88eDdb3c8FCa1915e2CBb2d8 (multisig, [transaction](https://arbiscan.io/tx/0xe99d876e717bde60bad1554524c5de51c816ee552803536d031a30686f91855d))
-   **Proposer of TimelockController**: 0x9a970aF3978198fe88eDdb3c8FCa1915e2CBb2d8 (multisig, [transaction](https://arbiscan.io/tx/0x41a9bbd93286f673d1e7efa561ad7a8bb7ce56d10f89c141bde603e6208b5506))
-   **Executor of TimelockController**: 0x0000000000000000000000000000000000000000 (any address, [transaction](https://arbiscan.io/tx/0x41a9bbd93286f673d1e7efa561ad7a8bb7ce56d10f89c141bde603e6208b5506))
-   **Admin of TimelockController**: Renounced ([transaction](https://arbiscan.io/tx/0xfd9fb29a2cdbb93ce5fd3840afe9944fa336712c75a41f7e30c0becf967fe83e))
-   **Owner of RebatePlugin**: 0xB12f2EFA06A7e7b4569E750Fb83aD9060eAf2F06 (transfer to multisig after test)

### COMMON: 

#### Arbitrum One, OP Mainnet, Polygon Mainnet, BNB Smart Chain Mainnet, BASE, Avalanch C-Chain, Ethereum Mainnet

-   **BiconomyModuleSetup**: 0x32b9b615a3D848FdEFC958f38a529677A0fc00dD
-   **Deployer**: 0xB12f2EFA06A7e7b4569E750Fb83aD9060eAf2F06

#### Ethereum Mainnet

-   **PlaceholderModule**: 0xb1B645011A893DACe075d2e153149574aD327AC0

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