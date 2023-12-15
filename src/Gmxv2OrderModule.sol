// SPDX-License-Identifier: BUSL-1.1
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
import "./interfaces/IReferrals.sol";
import "./interfaces/IOrderCallbackReceiver.sol";

//v1.2.1
//Arbitrum equipped
//Operator should approve WETH to this contract
contract Gmxv2OrderModule is Ownable, IOrderCallbackReceiver {
    address public operator;
    uint256 public ethPriceMultiplier = 10 ** 12; // cache for gas saving;
    uint256 public txGasFactor = 110; // 110%, a buffer to track L1 gas price movements;
    mapping(bytes32 => uint256) public orderCollateral; //[order key, position collateral]
    uint256 public profitTakeRatio = 0; // 0%

    uint256 private constant MAX_PROFIT_TAKE_RATIO = 10; //10%;
    uint256 private constant MAX_TXGAS_FACTOR = 200; // 200%;
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    IDataStore private constant DATASTORE = IDataStore(0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8);
    bytes32 private constant REFERRALCODE = 0x74726164616f0000000000000000000000000000000000000000000000000000; //tradao
    address private constant REFERRALSTORAGE = 0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d;
    ISmartAccountFactory private constant BICONOMY_FACTORY =
        ISmartAccountFactory(0x000000a56Aaca3e9a4C479ea6b6CD0DbcB6634F5);
    bytes private constant SETREFERRALCODECALLDATA =
        abi.encodeWithSignature("setTraderReferralCodeByUser(bytes32)", REFERRALCODE);
    bytes private constant MODULE_SETUP_DATA = abi.encodeWithSignature("getModuleAddress()"); //0xf004f2f9
    address private constant BICONOMY_MODULE_SETUP = 0x2692b7d240288fEEA31139d4067255E31Fe71a79;
    bytes4 private constant OWNERSHIPT_INIT_SELECTOR = 0x2ede3bc0; //bytes4(keccak256("initForSmartAccount(address)"))
    address private constant DEFAULT_ECDSA_OWNERSHIP_MODULE = 0x0000001c5b32F37F5beA87BDD5374eB2aC54eA8e;
    bytes32 private constant ETH_MULTIPLIER_KEY = 0x007b50887d7f7d805ee75efc0a60f8aaee006442b047c7816fc333d6d083cae0; //keccak256(abi.encode(keccak256(abi.encode("PRICE_FEED_MULTIPLIER")), address(WETH)))
    bytes32 private constant ETH_PRICE_FEED_KEY = 0xb1bca3c71fe4192492fabe2c35af7a68d4fc6bbd2cfba3e35e3954464a7d848e; //keccak256(abi.encode(keccak256(abi.encode("PRICE_FEED")), address(WETH)))
    uint256 private constant ETH_MULTIPLIER = 10 ** 18;
    uint256 private constant USDC_MULTIPLIER = 10 ** 6;
    address private constant ORDER_VAULT = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;
    IExchangeRouter private constant EXCHANGE_ROUTER = IExchangeRouter(0x7C68C7866A64FA2160F78EEaE12217FFbf871fa8);
    IReferrals private constant REFERRALS = IReferrals(0xC8F9b1A0a120eFA05EEeb28B10b14FdE18Bb0F50);
    address private constant ORDER_HANDLER = 0x352f684ab9e97a6321a13CF03A61316B681D9fD2;
    bytes32 private constant COLLATERAL_AMOUNT = 0xb88da5cd71628783263477a6261c2906e380aa32e85e2e87b2463bbdc1127221; //keccak256(abi.encode("COLLATERAL_AMOUNT"));
    uint256 private constant CALLBACK_GAS_LIMIT = 300000; //todo

    event OperatorTransferred(address indexed previousOperator, address indexed newOperator);
    event NewSmartAccount(address indexed creator, address userEOA, address smartAccount);
    event OrderCreated(
        address indexed aa,
        uint256 indexed positionId,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 acceptablePrice,
        bytes32 orderKey,
        uint256 triggerPrice,
        address tradaoReferrer
    );
    event OrderCreationFailed(
        address indexed aa,
        uint256 indexed positionId,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 acceptablePrice,
        uint256 triggerPrice,
        Enum.FailureReason reason
    );
    event OrderCancelled(address indexed aa, bytes32 orderKey);
    event PayGasFailed(address indexed aa, uint256 gasFeeEth, uint256 ethPrice, uint256 aaUSDCBalance);
    event TxGasFactorUpdated(uint256 prevFactor, uint256 currentFactor);
    event ProfitTakeRatioUpdated(uint256 prevRatio, uint256 currentRatio);

    error UnsupportedOrderType();
    error OrderCreationError(
        address aa,
        uint256 positionId,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 acceptablePrice,
        uint256 triggerPrice
    );

    struct OrderParamBase {
        uint256 positionId; //blocknumber + transactionId + logId: the trade that copy from; 0: not a copy trade.
        address market;
        Order.OrderType orderType;
        bool isLong;
    }

    struct OrderParam {
        uint256 sizeDeltaUsd;
        uint256 initialCollateralDeltaAmount; //for increase, indicate USDC transfer amount; for decrease, set to createOrderParams
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

    modifier onlyOrderHandler() {
        require(msg.sender == ORDER_HANDLER, "401");
        _;
    }

    constructor(address initialOperator) Ownable(msg.sender) {
        operator = initialOperator;
        emit OperatorTransferred(address(0), initialOperator);
    }

    function transferOperator(address newOperator) external onlyOwner {
        address oldOperator = operator;
        operator = newOperator;
        emit OperatorTransferred(oldOperator, newOperator);
    }

    function deployAA(address userEOA, address _referrer) external returns (bool isSuccess) {
        uint256 startGas = gasleft();

        address aa = _deployAA(userEOA);
        setReferralCode(aa);
        if (_referrer != address(0)) {
            REFERRALS.setReferrerFromModule(aa, _referrer);
        }
        emit NewSmartAccount(msg.sender, userEOA, aa);
        isSuccess = true;

        if (msg.sender == operator) {
            uint256 ethPrice = getPriceFeedPrice();
            uint256 gasUsed = _adjustGasUsage(startGas - gasleft());
            //transfer gas fee to TinySwap...
            isSuccess = _aaTransferUsdc(aa, _calcUsdc(gasUsed * tx.gasprice, ethPrice), operator);
        }
    }

    //cancel single order
    function cancelOrder(address smartAccount, bytes32 key) external onlyOperator returns (bool success) {
        uint256 startGas = gasleft();
        require(key > 0, "key");

        bytes memory data = abi.encodeWithSelector(EXCHANGE_ROUTER.cancelOrder.selector, key);
        success = IModuleManager(smartAccount).execTransactionFromModule(
            address(EXCHANGE_ROUTER), 0, data, Enum.Operation.Call
        );
        if (success) {
            emit OrderCancelled(smartAccount, key);
        }

        uint256 gasUsed = _adjustGasUsage(startGas - gasleft());
        _aaTransferEth(smartAccount, gasUsed * tx.gasprice, operator);
    }

    //single order, could contain trigger price
    function newOrder(uint256 triggerPrice, OrderParamBase memory _orderBase, OrderParam memory _orderParam)
        external
        onlyOperator
        returns (bytes32 orderKey)
    {
        uint256 startGasLeft = gasleft();
        uint256 ethPrice = getPriceFeedPrice();
        bool isSaveCollateral = _orderBase.positionId > 0 && BaseOrderUtils.isDecreaseOrder(_orderBase.orderType)
            && _orderParam.sizeDeltaUsd > 0;
        uint256 _executionGasFee = getExecutionFeeGasLimit(_orderBase.orderType, isSaveCollateral) * tx.gasprice;
        (bytes32 _orderKey, bool _isExecutionFeePayed) =
            _newOrder(_executionGasFee, triggerPrice, isSaveCollateral, _orderBase, _orderParam);
        orderKey = _orderKey;

        uint256 gasFeeAmount = _adjustGasUsage(startGasLeft - gasleft()) * tx.gasprice;
        _payGas(
            _orderParam.smartAccount, _isExecutionFeePayed ? gasFeeAmount + _executionGasFee : gasFeeAmount, ethPrice
        );
    }

    /**
     *   copy trading orders.
     *   do off chain check before every call:
     *   1. check if very aa's module is enabled
     *   2. estimate gas, check aa's balance
     *   3. do simulation call
     */
    function newOrders(OrderParamBase memory _orderBase, OrderParam[] memory orderParams)
        external
        onlyOperator
        returns (bytes32[] memory orderKeys)
    {
        uint256 lastGasLeft = gasleft();
        uint256 ethPrice = getPriceFeedPrice();
        bool isSaveCollateral = _orderBase.positionId > 0 && BaseOrderUtils.isDecreaseOrder(_orderBase.orderType)
            && orderParams[0].sizeDeltaUsd > 0;
        uint256 _executionGasFee = getExecutionFeeGasLimit(_orderBase.orderType, isSaveCollateral) * tx.gasprice;
        uint256 multiplierFactor = DATASTORE.getUint(Keys.EXECUTION_GAS_FEE_MULTIPLIER_FACTOR);
        uint256 gasFeeAmount;

        uint256 len = orderParams.length;
        orderKeys = new bytes32[](len);
        for (uint256 i; i < len; i++) {
            OrderParam memory _orderParam = orderParams[i];
            (bytes32 _orderKey, bool _isExecutionFeePayed) =
                _newOrder(_executionGasFee, 0, isSaveCollateral, _orderBase, _orderParam);
            orderKeys[i] = _orderKey;
            uint256 gasUsed = lastGasLeft - gasleft();
            lastGasLeft = gasleft();
            gasFeeAmount = Precision.applyFactor(gasUsed, multiplierFactor) * txGasFactor / 100 * tx.gasprice;
            _payGas(
                _orderParam.smartAccount,
                _isExecutionFeePayed ? gasFeeAmount + _executionGasFee : gasFeeAmount,
                ethPrice
            );
        }
    }

    function _newOrder(
        uint256 _executionGasFee,
        uint256 triggerPrice,
        bool isSaveCollateral,
        OrderParamBase memory _orderBase,
        OrderParam memory _orderParam
    ) internal returns (bytes32 orderKey, bool isExecutionFeePayed) {
        //transfer execution fee WETH from operator to GMX Vault
        bool isSuccess = IERC20(WETH).transferFrom(operator, ORDER_VAULT, _executionGasFee);
        if (!isSuccess) {
            emit OrderCreationFailed(
                _orderParam.smartAccount,
                _orderBase.positionId,
                _orderParam.sizeDeltaUsd,
                _orderParam.initialCollateralDeltaAmount,
                _orderParam.acceptablePrice,
                triggerPrice,
                Enum.FailureReason.PayExecutionFeeFailed
            );
            return (0, false);
        }

        bool isIncreaseOrder = BaseOrderUtils.isIncreaseOrder(_orderBase.orderType);
        if (isIncreaseOrder && _orderParam.initialCollateralDeltaAmount > 0) {
            isSuccess = _aaTransferUsdc(_orderParam.smartAccount, _orderParam.initialCollateralDeltaAmount, ORDER_VAULT);
            if (!isSuccess) {
                emit OrderCreationFailed(
                    _orderParam.smartAccount,
                    _orderBase.positionId,
                    _orderParam.sizeDeltaUsd,
                    _orderParam.initialCollateralDeltaAmount,
                    _orderParam.acceptablePrice,
                    triggerPrice,
                    Enum.FailureReason.TransferCollateralToVaultFailed
                );
                return (0, true);
            }
        }

        //build orderParam
        BaseOrderUtils.CreateOrderParams memory cop;
        _buildOrderCustomPart(_orderBase, _orderParam, cop);
        cop.numbers.executionFee = _executionGasFee;
        cop.numbers.triggerPrice = triggerPrice;
        if (!isIncreaseOrder) {
            cop.numbers.initialCollateralDeltaAmount = _orderParam.initialCollateralDeltaAmount;
        }

        if (isSaveCollateral) {
            cop.addresses.callbackContract = address(this);
            cop.numbers.callbackGasLimit = CALLBACK_GAS_LIMIT;
        }

        //send order
        orderKey = _aaCreateOrder(cop);
        if (orderKey == 0) {
            if (isIncreaseOrder && _orderParam.initialCollateralDeltaAmount > 0) {
                //protect user's collateral.
                revert OrderCreationError(
                    _orderParam.smartAccount,
                    _orderBase.positionId,
                    _orderParam.sizeDeltaUsd,
                    _orderParam.initialCollateralDeltaAmount,
                    _orderParam.acceptablePrice,
                    triggerPrice
                );
            } else {
                emit OrderCreationFailed(
                    _orderParam.smartAccount,
                    _orderBase.positionId,
                    _orderParam.sizeDeltaUsd,
                    _orderParam.initialCollateralDeltaAmount,
                    _orderParam.acceptablePrice,
                    triggerPrice,
                    Enum.FailureReason.CreateOrderFailed
                );
            }
        } else {
            emit OrderCreated(
                _orderParam.smartAccount,
                _orderBase.positionId,
                _orderParam.sizeDeltaUsd,
                _orderParam.initialCollateralDeltaAmount,
                _orderParam.acceptablePrice,
                orderKey,
                triggerPrice,
                REFERRALS.getReferrer(_orderParam.smartAccount)
            );

            if (isSaveCollateral) {
                //save position collateral
                orderCollateral[orderKey] =
                    getCollateral(_orderParam.smartAccount, _orderBase.market, USDC, _orderBase.isLong);
            }
        }
        return (orderKey, true);
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

    function _payGas(address aa, uint256 totalGasFeeEth, uint256 _ethPrice) internal returns (bool isSuccess) {
        if (aa.balance < totalGasFeeEth) {
            //transfer gas fee and execution fee USDC from AA to TinySwap
            isSuccess = _aaTransferUsdc(aa, _calcUsdc(totalGasFeeEth, _ethPrice), operator);
        } else {
            //convert ETH to WETH to operator
            bytes memory data = abi.encodeWithSelector(IWNT(WETH).depositTo.selector, operator);
            isSuccess = IModuleManager(aa).execTransactionFromModule(WETH, totalGasFeeEth, data, Enum.Operation.Call);
        }
        if (!isSuccess) {
            emit PayGasFailed(aa, totalGasFeeEth, _ethPrice, IERC20(USDC).balanceOf(aa));
        }
    }

    function _buildOrderCustomPart(
        OrderParamBase memory _orderBase,
        OrderParam memory _orderParam,
        BaseOrderUtils.CreateOrderParams memory params
    ) internal pure {
        params.addresses.initialCollateralToken = USDC;
        params.decreasePositionSwapType = Order.DecreasePositionSwapType.SwapPnlTokenToCollateralToken;
        params.shouldUnwrapNativeToken = true;

        //common part
        params.addresses.market = _orderBase.market;
        params.orderType = _orderBase.orderType;
        params.isLong = _orderBase.isLong;

        //custom part
        params.addresses.receiver = _orderParam.smartAccount;
        params.numbers.sizeDeltaUsd = _orderParam.sizeDeltaUsd;
        params.numbers.acceptablePrice = _orderParam.acceptablePrice;
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

    function getExecutionFeeGasLimit(Order.OrderType orderType, bool isSaveCollateral) public view returns (uint256) {
        uint256 gasBase = _adjustGasLimitForEstimate(DATASTORE, _estimateExecuteOrderGasLimit(DATASTORE, orderType));
        if (isSaveCollateral) {
            return gasBase + CALLBACK_GAS_LIMIT;
        } else {
            return gasBase;
        }
    }

    // @dev adjust the estimated gas limit to help ensure the execution fee is sufficient during
    // the actual execution
    // @param dataStore DataStore
    // @param estimatedGasLimit the estimated gas limit
    function _adjustGasLimitForEstimate(IDataStore dataStore, uint256 estimatedGasLimit)
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
    function _estimateExecuteOrderGasLimit(IDataStore dataStore, Order.OrderType orderType)
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

    // @dev adjust the gas usage to pay operator
    // @param dataStore DataStore
    // @param gasUsed the amount of gas used
    function _adjustGasUsage(uint256 gasUsed) internal view returns (uint256) {
        // the gas cost is estimated based on the gasprice of the request txn
        // the actual cost may be higher if the gasprice is higher in the execution txn
        // the multiplierFactor should be adjusted to account for this
        uint256 multiplierFactor = DATASTORE.getUint(Keys.EXECUTION_GAS_FEE_MULTIPLIER_FACTOR);
        uint256 gasLimit = Precision.applyFactor(gasUsed, multiplierFactor);
        return gasLimit * txGasFactor / 100;
    }

    function getPriceFeedPrice() public view returns (uint256) {
        address priceFeedAddress = DATASTORE.getAddress(ETH_PRICE_FEED_KEY);
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
        uint256 precision = getPriceFeedMultiplier(DATASTORE);

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
        address priceFeedAddress = DATASTORE.getAddress(ETH_PRICE_FEED_KEY);
        IPriceFeed priceFeed = IPriceFeed(priceFeedAddress);
        uint256 priceFeedDecimal = uint256(IPriceFeed(priceFeed).decimals());
        ethPriceMultiplier = (10 ** priceFeedDecimal) * getPriceFeedMultiplier(DATASTORE) / (10 ** 30);
    }

    function setReferralCode(address smartAccount) public onlyOperator returns (bool isSuccess) {
        return IModuleManager(smartAccount).execTransactionFromModule(
            REFERRALSTORAGE, 0, SETREFERRALCODECALLDATA, Enum.Operation.Call
        );
    }

    function updateTxGasFactor(uint256 _txGasFactor) external onlyOperator {
        require(_txGasFactor <= MAX_TXGAS_FACTOR, "400");
        uint256 _prevFactor = txGasFactor;
        txGasFactor = _txGasFactor;
        emit TxGasFactorUpdated(_prevFactor, _txGasFactor);
    }

    function updateProfitTakeRatio(uint256 _ratio) external onlyOperator {
        require(_ratio <= MAX_PROFIT_TAKE_RATIO, "400");
        uint256 _prevRatio = profitTakeRatio;
        profitTakeRatio = _ratio;
        emit ProfitTakeRatioUpdated(_prevRatio, _ratio);
    }

    // @dev called after an order execution
    // @param key the key of the order
    // @param order the order that was executed
    function afterOrderExecution(bytes32 key, Order.Props memory order, EventUtils.EventLogData memory eventData)
        external
        onlyOrderHandler
    {
        if (eventData.addressItems.items[0].value != USDC) {
            //exception
            return;
        }

        uint256 outputAmount = eventData.uintItems.items[0].value;
        if (outputAmount < USDC_MULTIPLIER) {
            //do not take profit if output is too small.
            return;
        }

        uint256 prevCollateral = orderCollateral[key];
        if (prevCollateral == 0) {
            //exception
            return;
        }

        uint256 curCollateral = getCollateral(order.addresses.account, order.addresses.market, USDC, order.flags.isLong);
        if (curCollateral >= prevCollateral) {
            //exception
            return;
        }

        uint256 collateralDelta = prevCollateral - curCollateral;
        if (outputAmount < collateralDelta + USDC_MULTIPLIER) {
            //do not take profit if it's loss or profit is too small.
            return;
        }

        //take profit
        uint256 profitTaken = (outputAmount - collateralDelta) * profitTakeRatio / 100;
        _aaTransferUsdc(order.addresses.account, profitTaken, owner());

        delete orderCollateral[key];
    }

    // @dev called after an order cancellation
    // @param key the key of the order
    // @param order the order that was cancelled
    function afterOrderCancellation(bytes32 key, Order.Props memory, EventUtils.EventLogData memory)
        external
        onlyOrderHandler
    {
        delete orderCollateral[key];
    }

    // @dev called after an order has been frozen, see OrderUtils.freezeOrder in OrderHandler for more info
    // @param key the key of the order
    // @param order the order that was frozen
    function afterOrderFrozen(bytes32, Order.Props memory, EventUtils.EventLogData memory) external onlyOrderHandler {}

    // @dev get the key for a position, then get the collateral of the position
    // @param account the position's account
    // @param market the position's market
    // @param collateralToken the position's collateralToken
    // @param isLong whether the position is long or short
    // @return the collateral amount amplified in collateral token decimals.
    function getCollateral(address account, address market, address collateralToken, bool isLong)
        internal
        view
        returns (uint256)
    {
        bytes32 key = keccak256(abi.encode(account, market, collateralToken, isLong));
        return DATASTORE.getUint(keccak256(abi.encode(key, COLLATERAL_AMOUNT)));
    }
}
