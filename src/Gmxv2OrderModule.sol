// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/BaseOrderUtils.sol";
import "./interfaces/IDatastore.sol";
import "./interfaces/Keys.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/Precision.sol";
import "./interfaces/IDatastore.sol";
import "./interfaces/Enum.sol";
import "./interfaces/IModuleManager.sol";
import "./interfaces/ISmartAccountFactory.sol";
import "./interfaces/IWNT.sol";
import "./interfaces/IExchangeRouter.sol";

//1. Arbitrum configs
//2. Operator should approve WETH to this contract
contract Gmxv2OrderModule is Ownable {
    address public operator;
    uint256 public ethPrice;
    uint256 public ethPriceMultiplier = 10 ** 12;

    uint256 private constant MAXPRICEBUFFERACTOR = 120; // 120%, require(inputETHPrice < priceFeedPrice * 120%)
    uint256 private constant PRICEUPDATEACTOR = 115; // 115%, threshhold to update the ETH priceFeed price
    uint256 private constant MAXTXGASRATIO = 50; // 50%, require(inputTxGas/ExecutionFeeGasLimit < 50%)
    uint256 private constant MAX_AA_DEPLOY_GAS = 4000000 gwei; //todo reconfirm

    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    IDataStore private constant DATASTORE = IDataStore(0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8);
    bytes32 private constant REFERRALCODE = 0x74726164616f0000000000000000000000000000000000000000000000000000; //tradao
    address private constant REFERRALSTORAGE = 0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d;
    ISmartAccountFactory private constant BICONOMY_FACTORY =
        ISmartAccountFactory(0x000000a56Aaca3e9a4C479ea6b6CD0DbcB6634F5);
    bytes private constant SETREFERRALCODECALLDATA =
        abi.encodeWithSignature("setTraderReferralCodeByUser(bytes32)", REFERRALCODE);
    bytes private constant MODULE_SETUP_DATA = abi.encodeWithSignature("getModuleAddress()");
    address private constant BICONOMY_MODULE_SETUP = address(0); // todo
    bytes4 private constant OWNERSHIPT_INIT_SELECTOR = 0x2ede3bc0; //bytes4(keccak256("initForSmartAccount(address)"))
    address private constant DEFAULT_ECDSA_OWNERSHIP_MODULE = 0x0000001c5b32F37F5beA87BDD5374eB2aC54eA8e;
    bytes32 private constant ETH_MULTIPLIER_KEY = 0x007b50887d7f7d805ee75efc0a60f8aaee006442b047c7816fc333d6d083cae0; //keccak256(abi.encode(keccak256(abi.encode("PRICE_FEED_MULTIPLIER")), address(WETH)))
    bytes32 private constant ETH_PRICE_FEED_KEY = 0xb1bca3c71fe4192492fabe2c35af7a68d4fc6bbd2cfba3e35e3954464a7d848e; //keccak256(abi.encode(keccak256(abi.encode("PRICE_FEED")), address(WETH)))
    uint256 private ETH_MULTIPLIER = 10 ** 18;
    uint256 private USDC_MULTIPLIER = 10 ** 6;
    address private constant ORDER_VAULT = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;
    IExchangeRouter private constant EXCHANGE_ROUTER = IExchangeRouter(0x7C68C7866A64FA2160F78EEaE12217FFbf871fa8);

    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event UpdateTokenPrice(address indexed token, uint256 newPrice);
    event NewSmartAccount(address indexed creator, address userEOA, address smartAccount);
    event PayGasFailed(address indexed aa, uint256 indexed positionId);
    event OrderCreated(
        address indexed aa,
        uint256 indexed positionId,
        bytes32 orderKey,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 acceptablePrice
    );
    event OrderCreationFailed(
        address indexed aa,
        uint256 indexed positionId,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 acceptablePrice
    );

    error UnsupportedOrderType();

    struct OrderParam {
        uint256 sizeDeltaUsd;
        uint256 initialCollateralDeltaAmount;
        uint256 acceptablePrice;
        address smartAccount;
    }

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

    //single order, could contain trigger price
    function newOrder() external onlyOperator {}

    /**
     *   copy trading orders.
     *   do off chain check before every call:
     *   1. check if very aa's module is enabled
     *   2. check aa's balance
     *   3. get latest eth price, estimate gas
     *   4. do simulation call
     */
    function newOrders(
        uint256 positionId, //followee's positionId
        uint256 _ethPrice,
        uint256 _txGas,
        address market,
        Order.OrderType orderType,
        bool isLong,
        OrderParam[] memory orderParams
    ) external onlyOperator {
        (uint256 _txGasFee, uint256 _executionGasFee) = _calcGas(_ethPrice, orderType, _txGas);
        uint256 len = orderParams.length;
        bool isIncreaseOrder = BaseOrderUtils.isIncreaseOrder(orderType);
        for (uint256 i; i < len; i++) {
            OrderParam memory _orderParam = orderParams[i];
            //todo use try catch to constrain the revert region
            bool isSuccess = _payGas(_orderParam.smartAccount, _txGasFee, _executionGasFee, _ethPrice);
            if (!isSuccess) {
                emit PayGasFailed(_orderParam.smartAccount, positionId);
                break;
            }

            if (isIncreaseOrder && _orderParam.initialCollateralDeltaAmount > 0) {
                require(
                    _aaTransferUsdc(_orderParam.smartAccount, _orderParam.initialCollateralDeltaAmount, ORDER_VAULT),
                    "col"
                );
            }

            //build orderParam
            BaseOrderUtils.CreateOrderParams memory cop;
            _buildOrderCommonPart(_executionGasFee, market, orderType, isLong, cop);
            _buildOrderCustomPart(_orderParam, cop);

            //send order
            bytes32 orderKey = _aaCreateOrder(cop);
            if (orderKey == 0) {
                emit OrderCreationFailed(
                    _orderParam.smartAccount,
                    positionId,
                    _orderParam.sizeDeltaUsd,
                    _orderParam.initialCollateralDeltaAmount,
                    _orderParam.acceptablePrice
                );
            } else {
                emit OrderCreated(
                    _orderParam.smartAccount,
                    positionId,
                    orderKey,
                    _orderParam.sizeDeltaUsd,
                    _orderParam.initialCollateralDeltaAmount,
                    _orderParam.acceptablePrice
                );
            }
        }
    }

    //return orderKey == 0 if failed.
    function _aaCreateOrder(BaseOrderUtils.CreateOrderParams memory cop) internal returns (bytes32 orderKey) {
        bytes memory data = abi.encodeWithSelector(EXCHANGE_ROUTER.createOrder.selector, cop);
        (bool success, bytes memory returnData) = IModuleManager(cop.addresses.receiver)
            .execTransactionFromModuleReturnData(address(EXCHANGE_ROUTER), 0, data, Enum.Operation.Call);
        if (success) {
            orderKey = bytes32(returnData);
        }
    }

    //cancel single order
    function cancelOrder(address smartAccount, bytes32 key) external onlyOperator {}

    function _calcGas(uint256 _ethPrice, Order.OrderType orderType, uint256 _txGas)
        internal
        returns (uint256 txGasFee, uint256 executionGasFee)
    {
        require(_ethPrice * 100 < ethPrice * MAXPRICEBUFFERACTOR, "ethPrice");
        if (_ethPrice * 100 >= ethPrice * PRICEUPDATEACTOR) {
            updateTokenPrice();
        }

        uint256 executionFeeGasLimit;
        if (orderType == Order.OrderType.MarketIncrease || orderType == Order.OrderType.LimitIncrease) {
            executionFeeGasLimit = getIncreaseExecutionFeeGasLimit();
        } else if (orderType == Order.OrderType.MarketDecrease || orderType == Order.OrderType.LimitDecrease) {
            executionFeeGasLimit = getDecreaseExecutionFeeGasLimit();
        } else {
            revert UnsupportedOrderType();
        }
        require(_txGas * 100 < executionFeeGasLimit * MAXTXGASRATIO, "txGas");

        txGasFee = _txGas * tx.gasprice;
        executionGasFee = executionFeeGasLimit * tx.gasprice;
    }

    function _payGas(address aa, uint256 txGasFee, uint256 executionFee, uint256 _ethPrice)
        internal
        returns (bool isSuccess)
    {
        if (aa.balance < txGasFee + executionFee) {
            if (IERC20(WETH).balanceOf(operator) < executionFee) {
                return false;
            }
            //transfer gas fee and execution fee USDC from AA to TinySwap
            isSuccess = _aaTransferUsdc(aa, _calcUsdc(txGasFee + executionFee, _ethPrice), operator);
        } else {
            //convert ETH to WETH to operator
            bytes memory data = abi.encodeWithSelector(IWNT(WETH).depositTo.selector, operator);
            isSuccess =
                IModuleManager(aa).execTransactionFromModule(WETH, txGasFee + executionFee, data, Enum.Operation.Call);
        }
        //transfer execution fee WETH from operator to GMX Vault
        if (isSuccess) {
            require(IERC20(WETH).transferFrom(operator, ORDER_VAULT, executionFee), "op eth");
        }
    }

    function _buildOrderCommonPart(
        uint256 executionFee,
        address market,
        Order.OrderType orderType,
        bool isLong,
        BaseOrderUtils.CreateOrderParams memory params
    ) internal pure {
        params.numbers.executionFee = executionFee;

        params.addresses.market = market;
        params.orderType = orderType;
        params.isLong = isLong;
    }

    function _buildOrderCustomPart(OrderParam memory _orderParam, BaseOrderUtils.CreateOrderParams memory params)
        internal
        view
    {
        params.addresses.receiver = _orderParam.smartAccount;
        params.addresses.callbackContract = address(0);
        params.addresses.uiFeeReceiver = operator;
        params.addresses.initialCollateralToken = USDC;

        params.numbers.sizeDeltaUsd = _orderParam.sizeDeltaUsd;
        params.numbers.initialCollateralDeltaAmount = _orderParam.initialCollateralDeltaAmount;
        params.numbers.callbackGasLimit = 0;
        params.numbers.minOutputAmount = 0;
        params.numbers.acceptablePrice = _orderParam.acceptablePrice;

        params.decreasePositionSwapType = Order.DecreasePositionSwapType.SwapPnlTokenToCollateralToken;
        params.shouldUnwrapNativeToken = true;
        params.referralCode = REFERRALCODE;
    }

    function setReferralCode(address smartAccount) external {
        IModuleManager(smartAccount).execTransactionFromModule(
            REFERRALSTORAGE, 0, SETREFERRALCODECALLDATA, Enum.Operation.Call, 0
        );
    }

    function deployAA(address userEOA, uint256 deployGas) external {
        address aa = _deployAA(userEOA);
        if (msg.sender == operator) {
            require(deployGas <= MAX_AA_DEPLOY_GAS, "gas");
            //transfer gas fee to TinySwap...
            _aaTransferUsdc(aa, _calcUsdc(deployGas * tx.gasprice, ethPrice), operator);
        }
        emit NewSmartAccount(msg.sender, userEOA, aa);
    }

    function _aaTransferUsdc(address aa, uint256 usdcAmount, address to) internal returns (bool isSuccess) {
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, to, usdcAmount);
        isSuccess = IModuleManager(aa).execTransactionFromModule(USDC, 0, data, Enum.Operation.Call);
    }

    function _calcUsdc(uint256 ethAmount, uint256 _ethPrice) internal view returns (uint256 usdcAmount) {
        return ethAmount * _ethPrice * USDC_MULTIPLIER / ETH_MULTIPLIER / ethPriceMultiplier;
    }

    function _aaTransferEth(address aa, uint256 ethAmount, address to) internal returns (bool isSuccess) {
        isSuccess = IModuleManager(aa).execTransactionFromModule(to, ethAmount, "", Enum.Operation.Call);
    }

    function _deployAA(address userEOA) internal returns (address) {
        uint256 index = uint256(uint160(userEOA));
        address aa = BICONOMY_FACTORY.deployCounterFactualAccount(BICONOMY_MODULE_SETUP, MODULE_SETUP_DATA, index);
        bytes memory data = abi.encodeWithSelector(
            IModuleManager.setupAndEnableModule.selector,
            DEFAULT_ECDSA_OWNERSHIP_MODULE,
            abi.encodeWithSelector(OWNERSHIPT_INIT_SELECTOR, userEOA)
        );
        bool isSuccess = IModuleManager(aa).execTransactionFromModule(aa, 0, data, Enum.Operation.Call);
        require(isSuccess, "500");

        return aa;
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
    function updateTokenPrice() public returns (uint256 newPrice) {
        newPrice = getPriceFeedPrice(DATASTORE);
        ethPrice = newPrice;
        emit UpdateTokenPrice(WETH, newPrice);
    }

    function getPriceFeedPrice(IDataStore dataStore) public view returns (uint256) {
        address priceFeedAddress = dataStore.getAddress(ETH_PRICE_FEED_KEY);
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
        uint256 precision = getPriceFeedMultiplier(dataStore);

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
    function getPriceFeedMultiplier(IDataStore dataStore) public view returns (uint256) {
        uint256 multiplier = dataStore.getUint(ETH_MULTIPLIER_KEY);

        require(multiplier > 0, "500");

        return multiplier;
    }

    function updateEthPriceMultiplier() external {
        address priceFeedAddress = IDataStore(DATASTORE).getAddress(ETH_PRICE_FEED_KEY);
        IPriceFeed priceFeed = IPriceFeed(priceFeedAddress);
        uint256 priceFeedDecimal = uint256(IPriceFeed(priceFeed).decimals());
        ethPriceMultiplier = (10 ** priceFeedDecimal) * getPriceFeedMultiplier(DATASTORE) / (10 ** 30);
    }
}