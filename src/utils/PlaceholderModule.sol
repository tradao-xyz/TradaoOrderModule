// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../interfaces/IModuleManager.sol";
import "../interfaces/ISmartAccountFactory.sol";
import "../interfaces/IBiconomyModuleSetup.sol";
import "../interfaces/IEcdsaOwnershipRegistryModule.sol";
import "../interfaces/ISmartAccount.sol";

//v1.7.0
//Ethereum equipped
//Only used to withdraw missed tokens
contract PlaceholderModule is Ownable {
    ISmartAccountFactory private constant BICONOMY_FACTORY =
        ISmartAccountFactory(0x000000a56Aaca3e9a4C479ea6b6CD0DbcB6634F5);
    bytes private constant MODULE_SETUP_DATA = abi.encodeWithSignature("getModuleAddress()"); //0xf004f2f9
    address private constant BICONOMY_MODULE_SETUP = 0x32b9b615a3D848FdEFC958f38a529677A0fc00dD;
    bytes4 private constant OWNERSHIPT_INIT_SELECTOR = 0x2ede3bc0; //bytes4(keccak256("initForSmartAccount(address)"))
    address private constant DEFAULT_ECDSA_OWNERSHIP_MODULE = 0x0000001c5b32F37F5beA87BDD5374eB2aC54eA8e;

    event NewSmartAccount(address indexed creator, address userEOA, uint96 number, address smartAccount);
    event AutoMigrationDone(address indexed aa, address newModule);

    constructor() Ownable(msg.sender) {}

    function deployAA(address userEOA, uint96 number) external {
        uint256 index = uint256(bytes32(bytes.concat(bytes20(userEOA), bytes12(number))));
        address aa = BICONOMY_FACTORY.deployCounterFactualAccount(BICONOMY_MODULE_SETUP, MODULE_SETUP_DATA, index);
        bytes memory data = abi.encodeWithSelector(
            IModuleManager.setupAndEnableModule.selector,
            DEFAULT_ECDSA_OWNERSHIP_MODULE,
            abi.encodeWithSelector(OWNERSHIPT_INIT_SELECTOR, userEOA)
        );
        bool isSuccess = IModuleManager(aa).execTransactionFromModule(aa, 0, data, Enum.Operation.Call);
        require(isSuccess, "500");

        emit NewSmartAccount(msg.sender, userEOA, number, aa);
    }

    function withdraw(address aa, address tokenAddress) external {
        address aaOwner = IEcdsaOwnershipRegistryModule(DEFAULT_ECDSA_OWNERSHIP_MODULE).getOwner(aa);
        require(msg.sender == aaOwner || msg.sender == owner(), "403");

        if (tokenAddress == address(0)) {
            // This is an ETH transfer
            uint256 amount = aa.balance;
            IModuleManager(aa).execTransactionFromModule(aaOwner, amount, "", Enum.Operation.Call);
        } else {
            // This is an ERC20 token transfer
            uint256 amount = IERC20(tokenAddress).balanceOf(aa);
            bytes memory data = abi.encodeWithSelector(IERC20.transfer.selector, aaOwner, amount);
            IModuleManager(aa).execTransactionFromModule(tokenAddress, 0, data, Enum.Operation.Call);
        }
    }

    function migrateModule(address aa, address prevModule) external onlyOwner returns (bool isSuccess) {
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
}
