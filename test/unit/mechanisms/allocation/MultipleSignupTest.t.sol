// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title Multiple Signup Test
/// @notice Tests that QuadraticVotingMechanism allows multiple signups while OctantQFMechanism prevents them
contract MultipleSignupTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism quadraticMechanism;

    address alice = address(0x1);

    function _tokenized(address _mechanism) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(_mechanism);
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        // Fund alice
        token.mint(alice, 10000 ether);

        // Deploy QuadraticVotingMechanism
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Multiple Signup Test",
            symbol: "MST",
            votingDelay: 100,
            votingPeriod: 1000,
            quorumShares: 100 ether,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(this)
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, 1, 2); // Alpha = 0.5
        quadraticMechanism = QuadraticVotingMechanism(payable(mechanismAddr));
    }

    /// @notice Test that QuadraticVotingMechanism allows multiple signups
    function testQuadraticMechanism_AllowsMultipleSignups() public {
        console.log("=== Testing Multiple Signups in QuadraticVotingMechanism ===");

        // Get timeline info
        uint256 deploymentTime = block.timestamp;
        uint256 votingDelay = _tokenized(address(quadraticMechanism)).votingDelay();
        uint256 votingStartTime = deploymentTime + votingDelay;

        // Stay before voting starts for registration
        vm.warp(votingStartTime - 1);

        // First signup - should work
        vm.startPrank(alice);
        token.approve(address(quadraticMechanism), 1000 ether);
        _tokenized(address(quadraticMechanism)).signup(1000 ether);

        uint256 powerAfterFirst = _tokenized(address(quadraticMechanism)).votingPower(alice);
        console.log("Power after first signup:", powerAfterFirst);
        assertEq(powerAfterFirst, 1000 ether, "First signup should give voting power");

        // Second signup - should also work and add to existing power
        token.approve(address(quadraticMechanism), 500 ether);
        _tokenized(address(quadraticMechanism)).signup(500 ether);

        uint256 powerAfterSecond = _tokenized(address(quadraticMechanism)).votingPower(alice);
        console.log("Power after second signup:", powerAfterSecond);
        assertEq(powerAfterSecond, 1500 ether, "Second signup should add to existing power");

        // Third signup with zero deposit - should work
        _tokenized(address(quadraticMechanism)).signup(0);

        uint256 powerAfterThird = _tokenized(address(quadraticMechanism)).votingPower(alice);
        console.log("Power after third signup (zero deposit):", powerAfterThird);
        assertEq(powerAfterThird, 1500 ether, "Zero deposit signup should not change power");

        vm.stopPrank();

        console.log("SUCCESS: QuadraticVotingMechanism allows multiple signups!");
    }
}
