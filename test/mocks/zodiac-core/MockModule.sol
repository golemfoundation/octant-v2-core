// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract MockModule {
    address public owner;

    function setUp(address _owner) public {
        owner = _owner;
    }

    function setUp(bytes memory data) public {
        (address _owner, ) = abi.decode(data, (address, bytes));
        owner = _owner;
    }
}
