// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

// For interacting with our own strategy
interface IBoltMaster {

    function AcceptYield(uint256 _yieldAmount) external;

}
