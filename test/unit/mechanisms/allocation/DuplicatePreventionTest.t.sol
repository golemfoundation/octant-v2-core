// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DuplicatePreventionTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();
    }

    function testDuplicatePrevention() public {
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Test Mechanism",
            symbol: "TEST",
            votingDelay: 100,
            votingPeriod: 1000,
            quorumShares: 500,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        // Deploy first mechanism
        address firstMechanism = factory.deployQuadraticVotingMechanism(config, 50, 100);
        assertTrue(firstMechanism != address(0), "First mechanism should deploy");

        // Try to deploy identical mechanism - should revert
        vm.expectRevert(
            abi.encodeWithSelector(AllocationMechanismFactory.MechanismAlreadyExists.selector, firstMechanism)
        );
        factory.deployQuadraticVotingMechanism(config, 50, 100);

        // Deploy with different parameters - should succeed
        config.name = "Different Mechanism";
        address secondMechanism = factory.deployQuadraticVotingMechanism(config, 50, 100);
        assertTrue(secondMechanism != address(0), "Second mechanism should deploy");
        assertTrue(firstMechanism != secondMechanism, "Mechanisms should be different");
    }

    function testPredictMechanismAddress() public {
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Predictable Mechanism",
            symbol: "PRED",
            votingDelay: 100,
            votingPeriod: 1000,
            quorumShares: 500,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        // Predict address before deployment
        address predicted = factory.predictMechanismAddress(config, 50, 100, address(this));

        // Deploy mechanism
        address deployed = factory.deployQuadraticVotingMechanism(config, 50, 100);

        // Verify prediction was correct
        assertEq(predicted, deployed, "Predicted address should match deployed address");
    }
}
