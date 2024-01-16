// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

interface IEcdsaOwnershipRegistryModule {
    /**
     * @dev Returns the owner of the Smart Account. Reverts for Smart Accounts without owners.
     * @param smartAccount Smart Account address.
     * @return owner The owner of the Smart Account.
     */
    function getOwner(address smartAccount) external view returns (address);
}
