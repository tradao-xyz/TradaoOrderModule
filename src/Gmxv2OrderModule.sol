// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/BaseOrderUtils.sol";
import "./interfaces/IDatastore.sol";
import "./interfaces/Keys.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/Precision.sol";
import "./interfaces/Enum.sol";
import "./interfaces/IModuleManager.sol";
import "./interfaces/ISmartAccountFactory.sol";
import "./interfaces/IWNT.sol";
import "./interfaces/IExchangeRouter.sol";
import "./interfaces/IReferrals.sol";
import "./interfaces/IOrderCallbackReceiver.sol";
import "./interfaces/IProfitShare.sol";
import "./interfaces/IBiconomyModuleSetup.sol";
import "./interfaces/ISmartAccount.sol";
import "./interfaces/IEcdsaOwnershipRegistryModule.sol";
import "./interfaces/IPostExecutionHandler.sol";

//v1.7.0
//Arbitrum equipped
//Operator should approve WETH to this contract.
contract Gmxv2OrderModule is Ownable, IOrderCallbackReceiver {
    address private constant SENTINEL_OPERATORS = address(0x1);
    mapping(address => address) public operators;

    uint256 public ethPriceMultiplier = 10 ** 12; // cache for gas saving, ETH's GMX price precision
    mapping(bytes32 => ProfitTakeParam) public orderCollateral; //[order key, position collateral]
    address public postExecutionHandler;

    uint256 public simpleGasBase = 150000; //deployAA, cancelOrder
    uint256 public newOrderGasBase = 250000; //every newOrder
    uint256 public callbackGasLimit = 400000;

    mapping(address => bool) public autoMigrationOffList;

    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    IDataStore private constant DATASTORE = IDataStore(0xFD70de6b91282D8017aA4E741e9Ae325CAb992d8);
    bytes32 private constant REFERRALCODE = 0x74726164616f7800000000000000000000000000000000000000000000000000; //tradaox
    address private constant REFERRALSTORAGE = 0xe6fab3F0c7199b0d34d7FbE83394fc0e0D06e99d;
    ISmartAccountFactory private constant BICONOMY_FACTORY =
        ISmartAccountFactory(0x000000a56Aaca3e9a4C479ea6b6CD0DbcB6634F5);
    bytes private constant SETREFERRALCODECALLDATA =
        abi.encodeWithSignature("setTraderReferralCodeByUser(bytes32)", REFERRALCODE);
    bytes private constant MODULE_SETUP_DATA = abi.encodeWithSignature("getModuleAddress()"); //0xf004f2f9
    address private constant BICONOMY_MODULE_SETUP = 0x32b9b615a3D848FdEFC958f38a529677A0fc00dD;
    bytes4 private constant OWNERSHIPT_INIT_SELECTOR = 0x2ede3bc0; //bytes4(keccak256("initForSmartAccount(address)"))
    address private constant DEFAULT_ECDSA_OWNERSHIP_MODULE = 0x0000001c5b32F37F5beA87BDD5374eB2aC54eA8e;
    bytes32 private constant ETH_MULTIPLIER_KEY = 0x007b50887d7f7d805ee75efc0a60f8aaee006442b047c7816fc333d6d083cae0; //keccak256(abi.encode(keccak256(abi.encode("PRICE_FEED_MULTIPLIER")), address(WETH)))
    bytes32 private constant ETH_PRICE_FEED_KEY = 0xb1bca3c71fe4192492fabe2c35af7a68d4fc6bbd2cfba3e35e3954464a7d848e; //keccak256(abi.encode(keccak256(abi.encode("PRICE_FEED")), address(WETH)))
    uint256 private constant ETH_MULTIPLIER = 10 ** 18;
    uint256 private constant USDC_MULTIPLIER = 10 ** 6;
    address private constant ORDER_VAULT = 0x31eF83a530Fde1B38EE9A18093A333D8Bbbc40D5;
    IExchangeRouter private constant EXCHANGE_ROUTER = IExchangeRouter(0x7C68C7866A64FA2160F78EEaE12217FFbf871fa8);
    IReferrals private constant TRADAO_REFERRALS = IReferrals(0xdb3643FE2693Beb1a78704E937F7C568FdeEeDdf);
    address private constant ORDER_HANDLER = 0x352f684ab9e97a6321a13CF03A61316B681D9fD2;
    bytes32 private constant COLLATERAL_AMOUNT = 0xb88da5cd71628783263477a6261c2906e380aa32e85e2e87b2463bbdc1127221; //keccak256(abi.encode("COLLATERAL_AMOUNT"));
    uint256 private constant MIN_PROFIT_TAKE_BASE = 5 * USDC_MULTIPLIER;
    uint256 private constant MAX_PROFIT_TAKE_RATIO = 2000; //20.00%;
    IProfitShare private constant PROFIT_SHARE = IProfitShare(0xBA6Eed0E234e65124BeA17c014CAc502B4441D64);

    event GasBaseUpdated(uint256 simple, uint256 newOrder);
    event CallbackGasLimitUpdated(uint256 callback);
    event EnabledOperator(address indexed operator);
    event DisabledOperator(address indexed operator);
    event NewSmartAccount(address indexed creator, address userEOA, uint96 number, address smartAccount);
    event OrderCreated(
        address indexed aa,
        address indexed followee,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 acceptablePrice,
        bytes32 orderKey,
        uint256 triggerPrice,
        address tradaoReferrer
    );
    event OrderCreationFailed(
        address indexed aa,
        address indexed followee,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 acceptablePrice,
        uint256 triggerPrice,
        Enum.OrderFailureReason reason
    );
    event OrderCancelled(address indexed aa, bytes32 orderKey);
    event PayGasFailed(address indexed aa, uint256 gasFeeEth, uint256 ethPrice, uint256 aaUSDCBalance);
    event TakeProfitSuccess(address indexed account, bytes32 orderKey, uint256 amount, address to);
    event TakeProfitFailed(address indexed account, bytes32 orderKey, Enum.TakeProfitFailureReason reason);
    event PostExecutionHandlerUpdated(address prevAddress, address currentAddress);

    error UnsupportedOrderType();
    error OrderCreationError(
        address aa,
        address followee,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 acceptablePrice,
        uint256 triggerPrice
    );

    event AutoMigrationDisabled(address indexed aa, bool isDisable);
    event AutoMigrationDone(address indexed aa, address newModule);

    struct OrderParamBase {
        address followee; //the trader that copy from; 0: not a copy trade.
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

    struct ProfitTakeParam {
        address followee;
        uint256 prevCollateral;
        address operator;
    }

    /**
     * @dev Only allows addresses with the operator role to call the function.
     */
    modifier onlyOperator() {
        require(SENTINEL_OPERATORS != msg.sender && operators[msg.sender] != address(0), "403");
        _;
    }

    modifier onlyOrderHandler() {
        require(msg.sender == ORDER_HANDLER, "403");
        _;
    }

    constructor(address initialOperator) Ownable(msg.sender) {
        operators[initialOperator] = SENTINEL_OPERATORS;
        operators[SENTINEL_OPERATORS] = initialOperator;
        emit EnabledOperator(initialOperator);
    }

    function enableOperator(address _operator) external onlyOwner {
        // operator address cannot be null or sentinel. operator cannot be added twice.
        require(_operator != address(0) && _operator != SENTINEL_OPERATORS && operators[_operator] == address(0), "400");

        operators[_operator] = operators[SENTINEL_OPERATORS];
        operators[SENTINEL_OPERATORS] = _operator;

        emit EnabledOperator(_operator);
    }

    function disableOperator(address prevoperator, address _operator) external onlyOwner {
        // Validate operator address and check that it corresponds to operator index.
        require(
            _operator != address(0) && _operator != SENTINEL_OPERATORS && operators[prevoperator] == _operator, "400"
        );
        operators[prevoperator] = operators[_operator];
        delete operators[_operator];
        emit DisabledOperator(_operator);
    }

    function deployAA(address userEOA, uint96 number, address _referrer) external returns (bool isSuccess) {
        uint256 startGas = gasleft();

        address aa = _deployAA(userEOA, number);
        setReferralCode(aa);
        if (_referrer != address(0)) {
            TRADAO_REFERRALS.setReferrerFromModule(aa, _referrer);
        }
        emit NewSmartAccount(msg.sender, userEOA, number, aa);
        isSuccess = true;

        if (operators[msg.sender] != address(0)) {
            uint256 ethPrice = getPriceFeedPrice();
            uint256 gasUsed = _adjustGasUsage(startGas - gasleft(), simpleGasBase);
            isSuccess = _payGas(aa, gasUsed * tx.gasprice, ethPrice);
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

        uint256 ethPrice = getPriceFeedPrice();
        uint256 gasUsed = _adjustGasUsage(startGas - gasleft(), simpleGasBase);
        success = _payGas(smartAccount, gasUsed * tx.gasprice, ethPrice);
    }

    //single order, could contain trigger price
    function newOrder(uint256 triggerPrice, OrderParamBase memory _orderBase, OrderParam memory _orderParam)
        external
        onlyOperator
        returns (bytes32 orderKey)
    {
        uint256 startGasLeft = gasleft();
        uint256 ethPrice = getPriceFeedPrice();
        uint256 _executionGasFee = getExecutionFeeGasLimit(_orderBase.orderType) * tx.gasprice;
        orderKey = _newOrder(_executionGasFee, triggerPrice, _orderBase, _orderParam);

        uint256 gasFeeAmount = _adjustGasUsage(startGasLeft - gasleft(), newOrderGasBase) * tx.gasprice;
        _payGas(
            _orderParam.smartAccount,
            orderKey == 0x0000000000000000000000000000000000000000000000000000000000000001
                ? gasFeeAmount
                : gasFeeAmount + _executionGasFee,
            ethPrice
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
        uint256 _executionGasFee = getExecutionFeeGasLimit(_orderBase.orderType) * tx.gasprice;
        uint256 multiplierFactor = DATASTORE.getUint(Keys.EXECUTION_GAS_FEE_MULTIPLIER_FACTOR);
        uint256 _newOrderGasBase = newOrderGasBase;

        uint256 len = orderParams.length;
        orderKeys = new bytes32[](len);
        for (uint256 i; i < len; i++) {
            OrderParam memory _orderParam = orderParams[i];
            orderKeys[i] = _newOrder(_executionGasFee, 0, _orderBase, _orderParam);
            uint256 gasUsed = lastGasLeft - gasleft();
            lastGasLeft = gasleft();
            uint256 gasFeeAmount = (_newOrderGasBase + Precision.applyFactor(gasUsed, multiplierFactor)) * tx.gasprice;
            _payGas(
                _orderParam.smartAccount,
                orderKeys[i] == 0x0000000000000000000000000000000000000000000000000000000000000001
                    ? gasFeeAmount
                    : gasFeeAmount + _executionGasFee,
                ethPrice
            );
        }
    }

    //@return, bytes32(uint256(1)): pay execution Fee failed
    function _newOrder(
        uint256 _executionGasFee,
        uint256 triggerPrice,
        OrderParamBase memory _orderBase,
        OrderParam memory _orderParam
    ) internal returns (bytes32 orderKey) {
        //transfer execution fee WETH from operator to GMX Vault
        bool isSuccess = IERC20(WETH).transferFrom(msg.sender, ORDER_VAULT, _executionGasFee);
        if (!isSuccess) {
            emit OrderCreationFailed(
                _orderParam.smartAccount,
                _orderBase.followee,
                _orderParam.sizeDeltaUsd,
                _orderParam.initialCollateralDeltaAmount,
                _orderParam.acceptablePrice,
                triggerPrice,
                Enum.OrderFailureReason.PayExecutionFeeFailed
            );
            return bytes32(0x0000000000000000000000000000000000000000000000000000000000000001); //bytes32(uint256(1))
        }

        bool isIncreaseOrder = BaseOrderUtils.isIncreaseOrder(_orderBase.orderType);
        if (isIncreaseOrder && _orderParam.initialCollateralDeltaAmount > 0) {
            isSuccess = _aaTransferUsdc(_orderParam.smartAccount, _orderParam.initialCollateralDeltaAmount, ORDER_VAULT);
            if (!isSuccess) {
                emit OrderCreationFailed(
                    _orderParam.smartAccount,
                    _orderBase.followee,
                    _orderParam.sizeDeltaUsd,
                    _orderParam.initialCollateralDeltaAmount,
                    _orderParam.acceptablePrice,
                    triggerPrice,
                    Enum.OrderFailureReason.TransferCollateralToVaultFailed
                );
                return bytes32(0x0000000000000000000000000000000000000000000000000000000000000002); //bytes32(uint256(2));
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
        cop.addresses.callbackContract = address(this);
        cop.numbers.callbackGasLimit = callbackGasLimit;

        //send order
        orderKey = _aaCreateOrder(cop);
        if (orderKey == 0) {
            if (isIncreaseOrder && _orderParam.initialCollateralDeltaAmount > 0) {
                //protect user's collateral.
                revert OrderCreationError(
                    _orderParam.smartAccount,
                    _orderBase.followee,
                    _orderParam.sizeDeltaUsd,
                    _orderParam.initialCollateralDeltaAmount,
                    _orderParam.acceptablePrice,
                    triggerPrice
                );
            } else {
                emit OrderCreationFailed(
                    _orderParam.smartAccount,
                    _orderBase.followee,
                    _orderParam.sizeDeltaUsd,
                    _orderParam.initialCollateralDeltaAmount,
                    _orderParam.acceptablePrice,
                    triggerPrice,
                    Enum.OrderFailureReason.CreateOrderFailed
                );
            }
        } else {
            emit OrderCreated(
                _orderParam.smartAccount,
                _orderBase.followee,
                _orderParam.sizeDeltaUsd,
                _orderParam.initialCollateralDeltaAmount,
                _orderParam.acceptablePrice,
                orderKey,
                triggerPrice,
                TRADAO_REFERRALS.getReferrer(_orderParam.smartAccount)
            );

            //save position collateral
            orderCollateral[orderKey] = ProfitTakeParam(
                _orderBase.followee,
                getCollateral(_orderParam.smartAccount, _orderBase.market, USDC, _orderBase.isLong),
                msg.sender
            );
        }
        return orderKey;
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
            isSuccess = _aaTransferUsdc(aa, _calcUsdc(totalGasFeeEth, _ethPrice), msg.sender);
        } else {
            //convert ETH to WETH to operator
            bytes memory data = abi.encodeWithSelector(IWNT(WETH).depositTo.selector, msg.sender);
            (bool success, bytes memory returnData) =
                IModuleManager(aa).execTransactionFromModuleReturnData(WETH, totalGasFeeEth, data, Enum.Operation.Call);
            isSuccess = success && (returnData.length == 0 || abi.decode(returnData, (bool)));
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
        if (usdcAmount == 0) {
            return true;
        }
        bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, to, usdcAmount);
        (bool success, bytes memory returnData) =
            IModuleManager(aa).execTransactionFromModuleReturnData(USDC, 0, data, Enum.Operation.Call);
        return success && (returnData.length == 0 || abi.decode(returnData, (bool)));
    }

    function _calcUsdc(uint256 ethAmount, uint256 _ethPrice) internal view returns (uint256 usdcAmount) {
        return ethAmount * _ethPrice * USDC_MULTIPLIER / ETH_MULTIPLIER / ethPriceMultiplier;
    }

    function _deployAA(address userEOA, uint96 number) internal returns (address) {
        uint256 index = uint256(bytes32(bytes.concat(bytes20(userEOA), bytes12(number))));
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

    function getExecutionFeeGasLimit(Order.OrderType orderType) public view returns (uint256) {
        uint256 gasBase = _estimateExecuteOrderGasLimit(DATASTORE, orderType) + callbackGasLimit;
        return _adjustGasLimitForEstimate(gasBase);
    }

    // @dev adjust the estimated gas limit to help ensure the execution fee is sufficient during
    // the actual execution
    // @param dataStore DataStore
    // @param estimatedGasLimit the estimated gas limit
    function _adjustGasLimitForEstimate(uint256 estimatedGasLimit) internal view returns (uint256) {
        uint256 baseGasLimit = DATASTORE.getUint(Keys.ESTIMATED_GAS_FEE_BASE_AMOUNT);
        uint256 multiplierFactor = DATASTORE.getUint(Keys.ESTIMATED_GAS_FEE_MULTIPLIER_FACTOR);
        return baseGasLimit + Precision.applyFactor(estimatedGasLimit, multiplierFactor);
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
    // @param gasUsed the amount of gas used
    function _adjustGasUsage(uint256 gasUsed, uint256 baseGas) internal view returns (uint256) {
        // the gas cost is estimated based on the gasprice of the request txn
        // the actual cost may be higher if the gasprice is higher in the execution txn
        // the multiplierFactor should be adjusted to account for this
        uint256 multiplierFactor = DATASTORE.getUint(Keys.EXECUTION_GAS_FEE_MULTIPLIER_FACTOR);
        uint256 gasLimit = Precision.applyFactor(gasUsed, multiplierFactor);
        return baseGas + gasLimit;
    }

    function updateGasBase(uint256 _simpleGasBase, uint256 _newOrderGasBase) external onlyOperator {
        uint256 baseGasLimit = DATASTORE.getUint(Keys.EXECUTION_GAS_FEE_BASE_AMOUNT);
        require(_simpleGasBase <= _newOrderGasBase && _newOrderGasBase < baseGasLimit, "400");
        simpleGasBase = _simpleGasBase;
        newOrderGasBase = _newOrderGasBase;
        emit GasBaseUpdated(_simpleGasBase, _newOrderGasBase);
    }

    function updateCallbackGasLimit(uint256 _callbackGasLimit) external onlyOperator {
        require(_callbackGasLimit <= simpleGasBase, "400");
        callbackGasLimit = _callbackGasLimit;
        emit CallbackGasLimitUpdated(_callbackGasLimit);
    }

    //return price with token's GMX price precision
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
        uint256 priceFeedMultiplier = getPriceFeedMultiplier(DATASTORE);

        uint256 adjustedPrice = Precision.mulDiv(price, priceFeedMultiplier, Precision.FLOAT_PRECISION);

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

    function setReferralCode(address smartAccount) public returns (bool isSuccess) {
        return IModuleManager(smartAccount).execTransactionFromModule(
            REFERRALSTORAGE, 0, SETREFERRALCODECALLDATA, Enum.Operation.Call
        );
    }

    // @dev called after an order execution
    // @param key the key of the order
    // @param order the order that was executed
    function afterOrderExecution(bytes32 key, Order.Props memory order, EventUtils.EventLogData memory eventData)
        external
        onlyOrderHandler
    {
        ProfitTakeParam storage ptp = orderCollateral[key];
        if (ptp.operator == address(0)) {
            //not a Tradao order
            return;
        }

        if (postExecutionHandler != address(0)) {
            IPostExecutionHandler(postExecutionHandler).handleOrder(key, order);
        }

        address followee = ptp.followee;
        if (followee == address(0) || !BaseOrderUtils.isDecreaseOrder(order.numbers.orderType)) {
            //not a decrease order, no need to take profit.
            return;
        }

        uint256 prevCollateral = ptp.prevCollateral;
        if (prevCollateral == 0) {
            //exception
            emit TakeProfitFailed(order.addresses.account, key, Enum.TakeProfitFailureReason.PrevCollateralMissed);
            return;
        }
        delete orderCollateral[key];

        if (eventData.addressItems.items[0].value != USDC) {
            //exception
            emit TakeProfitFailed(order.addresses.account, key, Enum.TakeProfitFailureReason.InvalidCollateralToken);
            return;
        }

        uint256 outputAmount = eventData.uintItems.items[0].value;
        if (outputAmount < MIN_PROFIT_TAKE_BASE) {
            //do not take profit if output is too small.
            emit TakeProfitFailed(order.addresses.account, key, Enum.TakeProfitFailureReason.ProfitTooSmall);
            return;
        }

        uint256 curCollateral = getCollateral(order.addresses.account, order.addresses.market, USDC, order.flags.isLong);
        if (curCollateral >= prevCollateral) {
            //exception, the realized pnl will be transfered to user's account
            emit TakeProfitFailed(order.addresses.account, key, Enum.TakeProfitFailureReason.CollateralAmountInversed);
            return;
        }

        uint256 collateralDelta = prevCollateral - curCollateral;
        if (outputAmount < collateralDelta + MIN_PROFIT_TAKE_BASE) {
            //do not take profit if it's loss or profit is too small.
            emit TakeProfitFailed(order.addresses.account, key, Enum.TakeProfitFailureReason.ProfitTooSmall);
            return;
        }

        //take profit
        //get profitTakeRatio, can't greater than MAX_PROFIT_TAKE_RATIO
        uint256 profitTakeRatio = PROFIT_SHARE.getProfitTakeRatio(
            order.addresses.account, order.addresses.market, outputAmount - collateralDelta, followee
        );
        if (profitTakeRatio == 0) {
            return;
        } else if (profitTakeRatio > MAX_PROFIT_TAKE_RATIO) {
            profitTakeRatio = MAX_PROFIT_TAKE_RATIO;
        }

        uint256 profitTaken = (outputAmount - collateralDelta) * profitTakeRatio / 10000;
        if (_aaTransferUsdc(order.addresses.account, profitTaken, address(PROFIT_SHARE))) {
            PROFIT_SHARE.distributeProfit(order.addresses.account, order.addresses.market, followee);
            emit TakeProfitSuccess(order.addresses.account, key, profitTaken, address(PROFIT_SHARE));
        } else {
            emit TakeProfitFailed(order.addresses.account, key, Enum.TakeProfitFailureReason.TransferError);
        }
    }

    // @dev called after an order cancellation
    // @param key the key of the order
    // @param order the order that was cancelled
    function afterOrderCancellation(bytes32 key, Order.Props memory order, EventUtils.EventLogData memory)
        external
        onlyOrderHandler
    {
        ProfitTakeParam storage ptp = orderCollateral[key];
        if (ptp.prevCollateral > 0) {
            emit TakeProfitFailed(order.addresses.account, key, Enum.TakeProfitFailureReason.Canceled);
        }
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

    function disableAutoMigration(address aa, bool isDisable) external {
        require(msg.sender == IEcdsaOwnershipRegistryModule(DEFAULT_ECDSA_OWNERSHIP_MODULE).getOwner(aa), "403");
        autoMigrationOffList[aa] = isDisable;

        emit AutoMigrationDisabled(aa, isDisable);
    }

    function migrateModule(address aa, address prevModule) external onlyOperator returns (bool isSuccess) {
        require(!autoMigrationOffList[aa], "401");

        address newModule = IBiconomyModuleSetup(BICONOMY_MODULE_SETUP).getModuleAddress();
        require(newModule != address(0) && newModule != address(this), "400");

        bytes memory enableNewModuleData = abi.encodeWithSelector(IModuleManager.enableModule.selector, newModule);
        isSuccess = IModuleManager(aa).execTransactionFromModule(aa, 0, enableNewModuleData, Enum.Operation.Call);
        require(isSuccess, "500A");

        bytes memory diableThisModuleData =
            abi.encodeWithSelector(ISmartAccount.disableModule.selector, prevModule, address(this));
        isSuccess = IModuleManager(aa).execTransactionFromModule(aa, 0, diableThisModuleData, Enum.Operation.Call);

        require(IModuleManager(aa).isModuleEnabled(newModule), "500B");
        require(!IModuleManager(aa).isModuleEnabled(address(this)), "500C");

        emit AutoMigrationDone(aa, newModule);
    }

    function withdraw(address aa, address[] calldata tokenAddresses, uint256[] calldata amounts) external {
        require(tokenAddresses.length == amounts.length, "400");
        require(msg.sender == IEcdsaOwnershipRegistryModule(DEFAULT_ECDSA_OWNERSHIP_MODULE).getOwner(aa), "403");

        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            if (amounts[i] == 0) {
                continue;
            }

            if (tokenAddresses[i] == address(0)) {
                // This is an ETH transfer
                require(aa.balance >= amounts[i], "400A");
                IModuleManager(aa).execTransactionFromModule(msg.sender, amounts[i], "", Enum.Operation.Call);
            } else {
                // This is an ERC20 token transfer
                require(IERC20(tokenAddresses[i]).balanceOf(aa) >= amounts[i], "400B");
                bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, amounts[i]);
                IModuleManager(aa).execTransactionFromModule(tokenAddresses[i], 0, data, Enum.Operation.Call);
            }
        }
    }

    function updatePostExecutionHandler(address handler) external onlyOwner {
        address _prev = postExecutionHandler;
        postExecutionHandler = handler;
        emit PostExecutionHandlerUpdated(_prev, handler);
    }
}
