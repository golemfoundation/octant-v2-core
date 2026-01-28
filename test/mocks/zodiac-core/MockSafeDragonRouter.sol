// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity >=0.7.0 <0.9.0;

contract MockSafeDragonRouter {
    address public splitChecker;

    constructor(address _splitChecker) {
        splitChecker = _splitChecker;
    }

    function setUp(address _splitChecker) public {
        splitChecker = _splitChecker;
    }
}
