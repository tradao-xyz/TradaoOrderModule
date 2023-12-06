// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

interface IReferrals {
    event ReferralUpdated(address indexed aa, address indexed referral);

    function getReferrer(address aa) external view returns (address);

    function setReferrerFromModule(address _aa, address _referrer) external;
}
