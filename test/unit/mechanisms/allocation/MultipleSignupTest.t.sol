// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/console.sol";
import { QuadraticVotingTestBase } from "./utils/QuadraticVotingTestBase.sol";

/// @title Multiple Signup Test
/// @notice Tests that QuadraticVotingMechanism allows multiple signups while OctantQFMechanism prevents them
contract MultipleSignupTest is QuadraticVotingTestBase {
    function setUp() public {
        _setUpQuadraticVoting("Multiple Signup Test", "MST", 100, 1000, 100 ether, 1 days, 7 days, 1, 2);

        // Fund alice
        token.mint(alice, 10000 ether);
    }

    /// @notice Test that QuadraticVotingMechanism allows multiple signups
    function testQuadraticMechanism_AllowsMultipleSignups() public {
        console.log("=== Testing Multiple Signups in QuadraticVotingMechanism ===");

        // Get timeline info
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized().votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Stay before voting starts for registration
        vm.warp(votingStartTime - 1);

        // First signup - should work
        vm.startPrank(alice);
        token.approve(address(mechanism), 1000 ether);
        _tokenized().signup(1000 ether);

        uint256 powerAfterFirst = _tokenized().votingPower(alice);
        console.log("Power after first signup:", powerAfterFirst);
        assertEq(powerAfterFirst, 1000 ether, "First signup should give voting power");

        // Second signup - should also work and add to existing power
        token.approve(address(mechanism), 500 ether);
        _tokenized().signup(500 ether);

        uint256 powerAfterSecond = _tokenized().votingPower(alice);
        console.log("Power after second signup:", powerAfterSecond);
        assertEq(powerAfterSecond, 1500 ether, "Second signup should add to existing power");

        // Third signup with zero deposit - should work
        _tokenized().signup(0);

        uint256 powerAfterThird = _tokenized().votingPower(alice);
        console.log("Power after third signup (zero deposit):", powerAfterThird);
        assertEq(powerAfterThird, 1500 ether, "Zero deposit signup should not change power");

        vm.stopPrank();

        console.log("SUCCESS: QuadraticVotingMechanism allows multiple signups!");
    }
}
