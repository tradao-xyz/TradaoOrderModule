// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/BaseOrderUtils.sol";
import "./interfaces/IDatastore.sol";
import "./interfaces/Keys.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/Precision.sol";
import "./interfaces/IDatastore.sol";
import "./interfaces/Enum.sol";
import "./interfaces/IModuleManager.sol";

//Arbitrum configs
contract Gmxv2OrderModule is Ownable {
    address public operator;

    mapping(address => uint256) public tokenPrice;

    uint256 private constant MAXPRICEBUFFERACTOR = 120; // 120%, require(inputETHPrice < priceFeedPrice * 120%)
    uint256 private constant PRICEUPDATEACTOR = 115; // 115%, threshhold to update the ETH priceFeed price
    uint256 private constant MAXTXGASRATIO = 50; // 50%, require(inputTxGas/ExecutionFeeGasLimit < 50%)

    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    IDataStore private constant DATASTORE = IDataStore(0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8);
    bytes32 private constant REFERRALCODE = 0x74726164616f0000000000000000000000000000000000000000000000000000; //tradao
    bytes4 private constant SETREFERRALCODESELECTOR = 0xe1e01bf3; //bytes4(keccak256("setTraderReferralCodeByUser(bytes32)"))
    bytes private constant SETREFERRALCODECALLDATA = abi.encodeWithSelector(SETREFERRALCODESELECTOR, REFERRALCODE);
    address private constant REFERRALSTORAGE = 0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d;

    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event UpdateTokenPrice(address indexed token, uint256 newPrice);

    error UnsupportedOrderType();

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

    function newOrder() external onlyOperator {}
    function newOrders() external onlyOperator {}
    function cancelOrders(address smartAccount, bytes32 key) external onlyOperator {}

    function _calcGasFee(uint256 ethPrice, Order.OrderType orderType, uint256 txGas)
        internal
        returns (uint256 txGasFee, uint256 executionFee)
    {
        require(ethPrice < tokenPrice[WETH], "ethPrice");
        if (ethPrice * 100 / tokenPrice[WETH] >= PRICEUPDATEACTOR) {
            updateTokenPrice(WETH);
        }

        uint256 executionFeeGasLimit;
        if (orderType == Order.OrderType.MarketIncrease || orderType == Order.OrderType.LimitIncrease) {
            executionFeeGasLimit = getIncreaseExecutionFeeGasLimit();
        } else if (orderType == Order.OrderType.MarketDecrease || orderType == Order.OrderType.LimitDecrease) {
            executionFeeGasLimit = getDecreaseExecutionFeeGasLimit();
        } else {
            revert UnsupportedOrderType();
        }
        require(txGas < executionFeeGasLimit * MAXTXGASRATIO / 100, "txGas");

        txGasFee = txGas * tx.gasprice;
        executionFee = executionFeeGasLimit * tx.gasprice;
    }

    function _buildOrderCommonPart(
        BaseOrderUtils.CreateOrderParams memory params,
        address market,
        Order.OrderType orderType,
        bool isLong
    ) internal pure returns (BaseOrderUtils.CreateOrderParams memory) {
        params.addresses.market = market;
        params.orderType = orderType;
        params.isLong = isLong;
        return params;
    }

    function _buildOrderCustomPart(
        BaseOrderUtils.CreateOrderParams memory params,
        address smartAccount,
        uint256 sizeDeltaUsd,
        uint256 initialCollateralDeltaAmount,
        uint256 triggerPrice,
        uint256 acceptablePrice
    ) internal view returns (BaseOrderUtils.CreateOrderParams memory) {
        if (msg.value > 0) {
            //1. transfer execution fee ETH from this contract to GMX Vault
            //2. transfer gas fee and execution fee USDC from this to TinySwap
        } else {
            //1. transfer execution fee ETH from AA to GMX Vault
            //2. transfer gas fee ETH from this to TinySwap
        }

        params.addresses.receiver = smartAccount;
        params.addresses.callbackContract = address(0);
        params.addresses.uiFeeReceiver = operator;

        params.addresses.initialCollateralToken = USDC;

        params.numbers.sizeDeltaUsd = sizeDeltaUsd;
        params.numbers.initialCollateralDeltaAmount = initialCollateralDeltaAmount;
        params.numbers.triggerPrice = triggerPrice;
        params.numbers.acceptablePrice = acceptablePrice;
        // params.numbers.executionFee = 0;
        params.numbers.callbackGasLimit = 0;
        params.numbers.minOutputAmount = 0;

        params.decreasePositionSwapType = Order.DecreasePositionSwapType.SwapPnlTokenToCollateralToken;
        params.shouldUnwrapNativeToken = true;
        params.referralCode = REFERRALCODE;

        return params;
    }

    function setReferralCode(address smartAccount) external {
        IModuleManager(smartAccount).execTransactionFromModule(
            REFERRALSTORAGE, 0, SETREFERRALCODECALLDATA, Enum.Operation.Call, 0
        );
    }

    function getIncreaseExecutionFeeGasLimit() public view returns (uint256) {
        return adjustGasLimitForEstimate(
            DATASTORE, estimateExecuteOrderGasLimit(DATASTORE, Order.OrderType.MarketIncrease)
        );
    }

    function getDecreaseExecutionFeeGasLimit() public view returns (uint256) {
        return adjustGasLimitForEstimate(
            DATASTORE, estimateExecuteOrderGasLimit(DATASTORE, Order.OrderType.MarketDecrease)
        );
    }

    // @dev adjust the estimated gas limit to help ensure the execution fee is sufficient during
    // the actual execution
    // @param dataStore DataStore
    // @param estimatedGasLimit the estimated gas limit
    function adjustGasLimitForEstimate(IDataStore dataStore, uint256 estimatedGasLimit)
        internal
        view
        returns (uint256)
    {
        uint256 baseGasLimit = dataStore.getUint(Keys.ESTIMATED_GAS_FEE_BASE_AMOUNT);
        uint256 multiplierFactor = dataStore.getUint(Keys.ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR);
        uint256 gasLimit = baseGasLimit + Precision.applyFactor(estimatedGasLimit, multiplierFactor);
        return gasLimit;
    }

    // @dev the estimated gas limit for orders
    function estimateExecuteOrderGasLimit(IDataStore dataStore, Order.OrderType orderType)
        internal
        view
        returns (uint256)
    {
        if (BaseOrderUtils.isIncreaseOrder(orderType)) {
            return dataStore.getUint(Keys.increaseOrderGasLimitKey());
        }

        if (BaseOrderUtils.isDecreaseOrder(orderType)) {
            return dataStore.getUint(Keys.decreaseOrderGasLimitKey()) + dataStore.getUint(Keys.singleSwapGasLimitKey());
        }

        revert UnsupportedOrderType();
    }

    // @dev get and update token price from Oracle
    function updateTokenPrice(address token) public returns (uint256 newPrice) {
        newPrice = getPriceFeedPrice(DATASTORE, token);
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

        require(_price > 0, "priceFeed");

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
