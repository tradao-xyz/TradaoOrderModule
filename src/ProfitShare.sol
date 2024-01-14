// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IProfitShare.sol";

contract ProfitShare is Ownable, IProfitShare {
    address public profitTaker;
    uint256 public profitTakeRatio = 0; // 0%

    uint256 private constant MAX_PROFIT_TAKE_RATIO = 800; //8.00%;

    event ProfitTakerTransferred(address indexed previousTaker, address indexed newTaker);
    event ProfitTakeRatioUpdated(uint256 prevRatio, uint256 currentRatio);

    constructor(address initialProfitTaker) Ownable(msg.sender) {
        profitTaker = initialProfitTaker;
        emit ProfitTakerTransferred(address(0), initialProfitTaker);
    }

    function transferProfitTaker(address newProfitTaker) external onlyOwner {
        address oldTaker = profitTaker;
        profitTaker = newProfitTaker;
        emit ProfitTakerTransferred(oldTaker, newProfitTaker);
    }

    function updateProfitTakeRatio(uint256 _ratio) external onlyOwner {
        require(_ratio <= MAX_PROFIT_TAKE_RATIO, "400");
        uint256 _prevRatio = profitTakeRatio;
        profitTakeRatio = _ratio;
        emit ProfitTakeRatioUpdated(_prevRatio, _ratio);
    }

    function getProfitTakeRatio(address account, address market, uint256 profit, address followee)
        external
        view
        override
        returns (uint256)
    {
        return profitTakeRatio;
    }

    function distributeProfit(address account, address market, uint256 profit, address followee) external override {}
}
