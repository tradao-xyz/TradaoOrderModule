// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IProfitShare {
    //return profit take ratio, factor: 10000
    function getProfitTakeRatio(address account, address market, uint256 profit, address followee)
        external
        view
        returns (uint256);
    function distributeProfit(address account, address market, address followee) external;
}
