// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IBiconomyModuleSetup {
    function getModuleAddress() external view returns (address);
}
