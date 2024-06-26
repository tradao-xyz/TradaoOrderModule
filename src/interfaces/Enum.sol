// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

/// @title Enum - Collection of enums
abstract contract Enum {
    enum Operation {
        Call,
        DelegateCall
    }

    enum OrderFailureReason {
        PayExecutionFeeFailed,
        TransferCollateralToVaultFailed,
        CreateOrderFailed
    }

    enum TakeProfitFailureReason {
        Canceled,
        PrevCollateralMissed,
        InvalidCollateralToken,
        CollateralAmountInversed,
        TransferError,
        ProfitTooSmall,
        Frozen
    }
}
