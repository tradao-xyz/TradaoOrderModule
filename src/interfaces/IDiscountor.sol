// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

// import "./IEcdsaOwnershipRegistryModule.sol";

interface IDiscountor {
    //0.get owner of the account
    // address eoa = tryGetEoa(account);
    // if (eoa == address(0)) {
    //     return profitTakeRatio;
    // } else {
    // }
    //1. check specific NFT and token owned by the account
    //2. calc the disccounted profitTakeRatio
    //return: percent of 10000
    function getFollowerDiscount(address account, address market, uint256 profit, address followee)
        external
        view
        returns (uint256);

    //1. get the NFT and token owned by followee
    //2. calc the platformRatio
    //return: percent of 10000
    function getFolloweeDiscount(address account, address market, address followee) external view returns (uint256);

    // IEcdsaOwnershipRegistryModule private constant OWNERSHIP_MODULE =
    //     IEcdsaOwnershipRegistryModule(0x0000001c5b32F37F5beA87BDD5374eB2aC54eA8e);

    // function tryGetEoa(address scw) internal view returns (address) {
    //     try OWNERSHIP_MODULE.getOwner(scw) returns (address v) {
    //         return v;
    //     } catch Error(string memory) /*reason*/ {
    //         // This is executed in case
    //         // revert was called inside getData
    //         // and a reason string was provided.
    //         return address(0);
    //     }
    // }
}
