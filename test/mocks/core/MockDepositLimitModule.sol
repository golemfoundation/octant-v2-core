// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

// Mock for deposit limit module
contract MockDepositLimitModule {
    uint256 public defaultDepositLimit = type(uint256).max;
    bool public enforceAllowset = false;
    mapping(address => bool) public allowset;
    // user -> limit
    mapping(address => uint256) public userAlreadyDeposited;

    function setDefaultDepositLimit(uint256 newLimit) external {
        defaultDepositLimit = newLimit;
    }

    function setEnforceAllowset(bool enforce) external {
        enforceAllowset = enforce;
    }

    function setAllowset(address account) external {
        allowset[account] = true;
    }

    function availableDepositLimit(address user) external view returns (uint256) {
        if (user == address(0) || user == msg.sender) {
            return 0;
        }

        if (enforceAllowset && !allowset[user]) {
            return 0;
        }

        return defaultDepositLimit;
    }
}
