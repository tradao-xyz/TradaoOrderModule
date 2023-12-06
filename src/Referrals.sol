// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./interfaces/IReferrals.sol";
import "./BiconomyModuleSetup.sol";

contract Referrals is IReferrals {
    mapping(address => address) private referrals;

    BiconomyModuleSetup private constant BICONOMY_MODULE_SETUP =
        BiconomyModuleSetup(0x2692b7d240288fEEA31139d4067255E31Fe71a79);

    function getReferrer(address aa) external view returns (address) {
        return referrals[aa];
    }

    function setReferrerFromModule(address aa, address _referrer) external {
        require(msg.sender == BICONOMY_MODULE_SETUP.getModuleAddress(), "401");
        referrals[aa] = _referrer;
        emit ReferralUpdated(aa, _referrer);
    }

    function setReferrerFromAA(address _referrer) external {
        require(msg.sender != _referrer, "400");
        referrals[msg.sender] = _referrer;
        emit ReferralUpdated(msg.sender, _referrer);
    }
}
