// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BatchTokenTransfer is Ownable {
    using SafeERC20 for IERC20;

    constructor() Ownable(msg.sender) {}

    // Function to receive ETH when calling `batchTransfer` with ETH transfers
    receive() external payable {}

    function batchTransfer(address to, address[] calldata tokenAddresses, uint256[] calldata amounts)
        external
        onlyOwner
        returns (bool)
    {
        require(tokenAddresses.length == amounts.length, "Mismatched input lengths");

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            if (tokenAddresses[i] == address(0)) {
                // This is an ETH transfer
                require(address(this).balance >= amounts[i], "Insufficient ETH sent");
                (bool sent,) = to.call{value: amounts[i]}("");
                require(sent, "Failed to send ETH");
            } else {
                // This is an ERC20 token transfer
                IERC20(tokenAddresses[i]).safeTransfer(to, amounts[i]);
            }
        }
        return true;
    }
}
