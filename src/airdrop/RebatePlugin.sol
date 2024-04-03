// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../BiconomyModuleSetup.sol";
import "../interfaces/IDatastore.sol";
import "../interfaces/Order.sol";
import "../interfaces/IPriceFeed.sol";
import "../interfaces/IPostExecutionHandler.sol";

contract RebatePlugin is Ownable, IPostExecutionHandler {
    using SafeERC20 for IERC20Metadata;

    uint256 public rebateRate = 8000; //80%;

    uint256 private constant RATE_BASE = 10000;
    BiconomyModuleSetup private constant BICONOMY_MODULE_SETUP =
        BiconomyModuleSetup(0x32b9b615a3D848FdEFC958f38a529677A0fc00dD);
    IDataStore private constant DATASTORE = IDataStore(0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8);
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    uint256 private constant WETH_MULTIPLIER = 10 ** 18;
    uint256 private constant WETH_PRICE_MULTIPLIER = 10 ** 12;
    address private constant ARB = 0x912CE59144191C1204E64559FE8253a0e49E6548;
    uint256 private constant ARB_MULTIPLIER = 10 ** 18;
    uint256 private constant ARB_PRICE_MULTIPLIER = 10 ** 12;
    bytes32 private constant POSITION_FEE_FACTOR = 0x3999256650a6ebfea3dfbd4d56990f4d9048943a0e38ea6aabfc65122556c342; //keccak256(abi.encode("POSITION_FEE_FACTOR"))
    uint256 private constant FLOAT_PRECISION = 10 ** 30;

    event Rebate(
        address indexed account,
        bytes32 indexed orderKey,
        uint256 volume,
        uint256 volumeRebate,
        uint256 executionFee,
        uint256 executionFeeRebate,
        uint256 arbPrice,
        uint256 ethPrice
    );
    event RebateRateUpdated(uint256 prevRate, uint256 currentRate);

    constructor() Ownable(msg.sender) {}

    // Function to receive ETH
    receive() external payable {}

    function updateRebateRate(uint256 _rebateRate) external onlyOwner {
        require(_rebateRate < RATE_BASE, "400");
        uint256 prevRate = rebateRate;
        rebateRate = _rebateRate;
        emit RebateRateUpdated(prevRate, _rebateRate);
    }

    function withdraw(address _token) external onlyOwner {
        if (_token == address(0)) {
            // This is an ETH transfer
            uint256 balance = address(this).balance;
            require(balance > 0, "403");
            (bool sent,) = address(msg.sender).call{value: balance}("");
            require(sent, "500");
        } else {
            // This is an ERC20 token transfer
            uint256 balance = IERC20Metadata(_token).balanceOf(address(this));
            IERC20Metadata(_token).safeTransfer(address(msg.sender), balance);
        }
    }

    function handleOrder(bytes32 key, Order.Props memory order) external returns (bool) {
        uint256 _rebateRate = rebateRate;
        if (_rebateRate == 0) {
            return true;
        }
        require(msg.sender == BICONOMY_MODULE_SETUP.getModuleAddress(), "401");

        uint256 rebateTokenPrice = getPriceFeedPrice(ARB);
        uint256 ethPrice = getPriceFeedPrice(WETH);

        uint256 openFeeRebateAmount = order.numbers.sizeDeltaUsd * getGmxOpenFeeRate(order.addresses.market)
            / (10 ** 30) * _rebateRate * (ARB_MULTIPLIER * ARB_PRICE_MULTIPLIER / (10 ** 30)) / rebateTokenPrice / RATE_BASE;

        uint256 executionFeeRebateAmount = order.numbers.executionFee * ethPrice / WETH_PRICE_MULTIPLIER * _rebateRate
            * (ARB_MULTIPLIER * ARB_PRICE_MULTIPLIER / WETH_MULTIPLIER) / rebateTokenPrice / RATE_BASE;

        uint256 arbBalance = IERC20Metadata(ARB).balanceOf(address(this));
        uint256 totalRebate = openFeeRebateAmount + executionFeeRebateAmount;
        if (arbBalance >= totalRebate) {
            IERC20Metadata(ARB).safeTransfer(order.addresses.account, totalRebate);

            emit Rebate(
                order.addresses.account,
                key,
                order.numbers.sizeDeltaUsd,
                openFeeRebateAmount,
                order.numbers.executionFee,
                executionFeeRebateAmount,
                rebateTokenPrice,
                ethPrice
            );
            return true;
        } else {
            return false;
        }
    }

    //return price with token's GMX price precision
    function getPriceFeedPrice(address tokenAddress) public view returns (uint256) {
        bytes32 priceFeedKey = keccak256(abi.encode(keccak256(abi.encode("PRICE_FEED")), tokenAddress));
        address priceFeedAddress = DATASTORE.getAddress(priceFeedKey);
        IPriceFeed priceFeed = IPriceFeed(priceFeedAddress);

        (
            /* uint80 roundID */
            ,
            int256 _price,
            /* uint256 startedAt */
            ,
            /* uint256 updatedAt */
            ,
            /* uint80 answeredInRound */
        ) = priceFeed.latestRoundData();

        require(_price > 0, "priceFeed");

        uint256 price = toUint256(_price);
        uint256 priceFeedMultiplier = getPriceFeedMultiplier(tokenAddress);

        uint256 adjustedPrice = (price * priceFeedMultiplier / FLOAT_PRECISION);

        return adjustedPrice;
    }

    // @dev get the multiplier value to convert the external price feed price to the price of 1 unit of the token
    // represented with 30 decimals
    // for example, if USDC has 6 decimals and a price of 1 USD, one unit of USDC would have a price of
    // 1 / (10 ^ 6) * (10 ^ 30) => 1 * (10 ^ 24)
    // if the external price feed has 8 decimals, the price feed price would be 1 * (10 ^ 8)
    // in this case the priceFeedMultiplier should be 10 ^ 46
    // the conversion of the price feed price would be 1 * (10 ^ 8) * (10 ^ 46) / (10 ^ 30) => 1 * (10 ^ 24)
    // formula for decimals for price feed multiplier: 60 - (external price feed decimals) - (token decimals)
    //
    // @param dataStore DataStore
    // @param token the token to get the price feed multiplier for
    // @return the price feed multipler
    function getPriceFeedMultiplier(address tokenAddress) public view returns (uint256) {
        bytes32 priceFeedMultiplierKey =
            keccak256(abi.encode(keccak256(abi.encode("PRICE_FEED_MULTIPLIER")), tokenAddress));
        uint256 multiplier = DATASTORE.getUint(priceFeedMultiplierKey);

        require(multiplier > 0, "500");

        return multiplier;
    }

    //return gmxOpenFeeRate, e.g. 6 * (10 ** 26) => div by 10**30 = 0.06%
    function getGmxOpenFeeRate(address market) public view returns (uint256) {
        uint256 positiveImpactFeeRate = DATASTORE.getUint(keccak256(abi.encode(POSITION_FEE_FACTOR, market, true)));
        uint256 nagetiveImpactFeeRate = DATASTORE.getUint(keccak256(abi.encode(POSITION_FEE_FACTOR, market, false)));
        return (positiveImpactFeeRate + nagetiveImpactFeeRate) / 2;
    }

    /**
     * @dev Converts a signed int256 into an unsigned uint256.
     *
     * Requirements:
     *
     * - input must be greater than or equal to 0.
     */
    function toUint256(int256 value) internal pure returns (uint256) {
        require(value >= 0, "500TU");
        return uint256(value);
    }
}
