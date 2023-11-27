// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/BaseOrderUtils.sol";
import "./interfaces/IDatastore.sol";
import "./interfaces/Keys.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/Precision.sol";

contract Gmxv2OrderModule is Ownable {
    address public operator;

    uint256 private constant MAXL1GASBUFFER = 20000000;
    uint256 private constant MAXEXECUTIONFEEGASLIMIT = 70000000;

    uint256 public executionFeeGasLimit;

    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    uint256 private constant MAXPRICEBUFFER = 20; // 20%

    address private constant DATASTORE = 0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8;

    mapping(address => uint256) public tokenPrice;

    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event ExecutionFeeGasLimitUpdated(uint256 prevLimit, uint256 newLimit);

    event UpdateTokenPrice(address indexed token, uint256 newPrice);

    /**
     * @dev Only allows addresses with the operator role to call the function.
     */
    modifier onlyOperator() {
        require(msg.sender == operator, "401");
        _;
    }

    //Owner should be transfer to a TimelockController
    constructor(address initialOwner, address initialOperator) Ownable(initialOwner) {
        operator = initialOperator;
    }

    function transferOperator(address newOperator) external onlyOwner {
        address oldOperator = operator;
        operator = newOperator;
        emit OperatorTransferred(oldOperator, newOperator);
    }

    function updateExecutionFeeGasLimit(uint256 newLimit) external onlyOperator {
        require(newLimit <= MAXEXECUTIONFEEGASLIMIT, "400");
        uint256 oldLimit = newLimit;
        executionFeeGasLimit = newLimit;
        emit ExecutionFeeGasLimitUpdated(oldLimit, newLimit);
    }

    function newOrder() external onlyOperator {}
    function newOrders() external onlyOperator {}
    function cancelOrders(address smartAccount, bytes32 key) external onlyOperator {}

    function _buildOrderParam(
        address smartAccount,
        uint256 _executionFeeGasLimit,
        uint256 usdcAmount,
        address market,
        address swapPath,
        uint256 sizeDeltaUsd,
        uint256 initialCollateralDeltaAmount,
        uint256 acceptablePrice,
        Order.OrderType orderType,
        bool isLong
    ) internal view returns (BaseOrderUtils.CreateOrderParams memory params) {
        params.addresses.receiver = smartAccount;
        params.addresses.callbackContract = address(0);
        params.addresses.uiFeeReceiver = owner();
        params.addresses.market = market;
        params.addresses.initialCollateralToken = USDC;
        // params.addresses.swapPath = new address[](0);
    }

    function updateTokenPrice(address token) public returns (uint256 newPrice) {
        newPrice = getPriceFeedPrice(IDataStore(DATASTORE), token);
        tokenPrice[token] = newPrice;
        emit UpdateTokenPrice(token, newPrice);
    }

    function getPriceFeedPrice(IDataStore dataStore, address token) public view returns (uint256) {
        address priceFeedAddress = dataStore.getAddress(Keys.priceFeedKey(token));
        require(priceFeedAddress != address(0), "500");

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

        require(_price > 0, "500");

        uint256 price = SafeCast.toUint256(_price);
        uint256 precision = getPriceFeedMultiplier(dataStore, token);

        uint256 adjustedPrice = Precision.mulDiv(price, precision, Precision.FLOAT_PRECISION);

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
    function getPriceFeedMultiplier(IDataStore dataStore, address token) public view returns (uint256) {
        uint256 multiplier = dataStore.getUint(Keys.priceFeedMultiplierKey(token));

        require(multiplier > 0, "500");

        return multiplier;
    }
}
