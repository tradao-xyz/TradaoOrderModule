// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

//Owner should be transferred to a timelock contract
contract BiconomyModuleSetup is Ownable {
    address public module;

    event ModuleUpdated(address prev, address current);

    constructor(address _module) Ownable(msg.sender) {
        module = _module;
        emit ModuleUpdated(address(0), _module);
    }

    function getModuleAddress() external view returns (address) {
        return module;
    }

    function updateModule(address _module) external onlyOwner {
        module = _module;
        emit ModuleUpdated(module, _module);
    }
}
