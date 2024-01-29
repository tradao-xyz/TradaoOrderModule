// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface ISmartAccount {
    /**
     * @dev Removes a module from the allowlist.
     * @notice This can only be done via a wallet transaction.
     * @notice Disables the module `module` for the wallet.
     * @param prevModule Module that pointed to the module to be removed in the linked list
     * @param module Module to be removed.
     */

    function disableModule(address prevModule, address module) external;
}
