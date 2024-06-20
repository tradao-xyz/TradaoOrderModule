// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

// @title Keys
// @dev Keys for values in the DataStore
library Keys {
    // @dev key for the base gas limit used when estimating execution fee
    bytes32 internal constant ESTIMATED_GAS_FEE_BASE_AMOUNT =
        keccak256(abi.encode("ESTIMATED_GAS_FEE_BASE_AMOUNT_V2_1"));
    // @dev key for the multiplier used when estimating execution fee
    bytes32 internal constant ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR =
        keccak256(abi.encode("ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR"));
    // @dev key for the gas limit used for each oracle price when estimating execution fee
    bytes32 internal constant ESTIMATED_GAS_FEE_PER_ORACLE_PRICE =
        keccak256(abi.encode("ESTIMATED_GAS_FEE_PER_ORACLE_PRICE"));

    // @dev key for the estimated gas limit for increase orders
    bytes32 internal constant INCREASE_ORDER_GAS_LIMIT = keccak256(abi.encode("INCREASE_ORDER_GAS_LIMIT"));
    // @dev key for the estimated gas limit for decrease orders
    bytes32 internal constant DECREASE_ORDER_GAS_LIMIT = keccak256(abi.encode("DECREASE_ORDER_GAS_LIMIT"));

    // @dev key for the estimated gas limit for single swaps
    bytes32 internal constant SINGLE_SWAP_GAS_LIMIT = keccak256(abi.encode("SINGLE_SWAP_GAS_LIMIT"));

    // @dev key for the multiplier used when calculating execution fee
    bytes32 internal constant EXECUTION_GAS_FEE_MULTIPLIER_FACTOR =
        keccak256(abi.encode("EXECUTION_GAS_FEE_MULTIPLIER_FACTOR"));
    // @dev key for the base gas limit used when calculating execution fee
    bytes32 internal constant EXECUTION_GAS_FEE_BASE_AMOUNT =
        keccak256(abi.encode("EXECUTION_GAS_FEE_BASE_AMOUNT_V2_1"));

    // bytes32 internal constant SWAP_ORDER_GAS_LIMIT = keccak256(abi.encode("SWAP_ORDER_GAS_LIMIT"));
}
