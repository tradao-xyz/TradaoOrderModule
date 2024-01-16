// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IProfitShare.sol";
import "./interfaces/IDiscountor.sol";

contract ProfitShare is Ownable, IProfitShare {
    uint256 public profitTakeRatio; // default 0%
    uint256 public platformRatio;
    address public discountor;

    // used to record token balances to evaluate amounts transferred in
    uint256 public prevUsdcBalance;
    uint256 public platformClaimable;
    mapping(address => uint256) public followeeClaimable;
    mapping(address => uint256) public followeeClaimtime;

    uint256 private constant MAX_PROFIT_TAKE_RATIO = 800; //8.00%;
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 private constant CLAIM_EXPIRED_TIME = 180 days;

    event ProfitTakeRatioUpdated(uint256 prevRatio, uint256 currentRatio);
    event DefaultPlatformRatio(uint256 prevRatio, uint256 currentRatio);
    event DistributeProfit(
        address indexed followee, address follower, uint256 followeeProfitDelta, uint256 platformProfitDelta
    );
    event DiscountorUpdated(address prevDiscountor, address currentDiscountor);

    constructor() Ownable(msg.sender) {
        updateDefaultPlatformRatio(6250); //default 62.50%
    }

    function updateDiscountor(address newDiscountor) external onlyOwner {
        address _prev = discountor;
        discountor = newDiscountor;
        emit DiscountorUpdated(_prev, newDiscountor);
    }

    function updateProfitTakeRatio(uint256 _ratio) external onlyOwner {
        require(_ratio <= MAX_PROFIT_TAKE_RATIO, "400");
        uint256 _prevRatio = profitTakeRatio;
        profitTakeRatio = _ratio;
        emit ProfitTakeRatioUpdated(_prevRatio, _ratio);
    }

    function updateDefaultPlatformRatio(uint256 _ratio) public onlyOwner {
        require(_ratio <= 10000, "400");
        uint256 _prevRatio = platformRatio;
        platformRatio = _ratio;
        emit DefaultPlatformRatio(_prevRatio, _ratio);
    }

    //params: address account, address market, uint256 profit, address followee
    function getProfitTakeRatio(address account, address market, uint256 profit, address followee)
        external
        view
        override
        returns (uint256)
    {
        address _discountor = discountor;
        if (_discountor != address(0)) {
            uint256 discountRatio = IDiscountor(_discountor).getFollowerDiscount(account, market, profit, followee);
            return profitTakeRatio * discountRatio / 10000;
        } else {
            return profitTakeRatio;
        }
    }

    function distributeProfit(address account, address market, address followee) external override {
        uint256 amountIn = _recordTransferIn();

        uint256 _platformRatioFinal = platformRatio;
        address _discountor = discountor;
        if (_discountor != address(0)) {
            uint256 discountRatio = IDiscountor(_discountor).getFolloweeDiscount(account, market, followee);
            if (discountRatio < 10000) {
                _platformRatioFinal = _platformRatioFinal * discountRatio / 10000;
            }
        }

        //save claimable of platform and followee
        uint256 platformAmount = amountIn * _platformRatioFinal / 10000;
        uint256 followeeAmount = amountIn - platformAmount;
        emit DistributeProfit(followee, account, followeeAmount, platformAmount);
        platformClaimable = platformClaimable + platformAmount;
        followeeClaimable[followee] = followeeClaimable[followee] + followeeAmount;
    }

    function followeeClaim() external {
        uint256 claimable = followeeClaimable[msg.sender];
        followeeClaimable[msg.sender] = 0;
        followeeClaimtime[msg.sender] = block.timestamp;
        IERC20(USDC).transfer(msg.sender, claimable);
        _afterTransferOut();
    }

    function platformClaim() external onlyOwner {
        uint256 claimable = platformClaimable;
        platformClaimable = 0;
        IERC20(USDC).transfer(msg.sender, claimable);
        _afterTransferOut();
    }

    function claimExpired(address followee) external onlyOwner {
        require(block.timestamp - followeeClaimtime[followee] > CLAIM_EXPIRED_TIME, "unexpired");
        uint256 claimable = followeeClaimable[followee];
        followeeClaimable[followee] = 0;
        followeeClaimtime[followee] = block.timestamp;
        IERC20(USDC).transfer(msg.sender, claimable);
        _afterTransferOut();
    }

    // @return the amount of tokens transferred in
    function _recordTransferIn() internal returns (uint256 amount) {
        uint256 nextBalance = IERC20(USDC).balanceOf(address(this));
        amount = nextBalance - prevUsdcBalance;
        prevUsdcBalance = nextBalance;
    }

    // @dev update the internal balance after tokens have been transferred out
    function _afterTransferOut() internal {
        prevUsdcBalance = IERC20(USDC).balanceOf(address(this));
    }
}
