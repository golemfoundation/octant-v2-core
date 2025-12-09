// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/// @title Cantina Competition September 2025 – Finding 197 Fix
/// @notice Ensures proposal cancellation no longer permanently blocks the recipient.
contract Finding197Fix is Test {
    AllocationMechanismFactory internal factory;
    QuadraticVotingMechanism internal mechanism;
    ERC20Mock internal token;

    address internal keeper = address(0xC0FFEE);
    address internal management = address(0xBEEF);
    address internal recipient = address(0xDEAD);

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        token.mint(keeper, 1_000 ether);

        AllocationConfig memory config = AllocationConfig({
            asset: token,
            name: "Cantina 197",
            symbol: "C197",
            votingDelay: 1,
            votingPeriod: 10,
            quorumShares: 1,
            timelockDelay: 1,
            gracePeriod: 1,
            owner: address(0)
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, 1, 1);
        mechanism = QuadraticVotingMechanism(payable(mechanismAddr));

        TokenizedAllocationMechanism tokenized = TokenizedAllocationMechanism(mechanismAddr);
        tokenized.setKeeper(keeper);
        tokenized.setManagement(management);

        vm.startPrank(keeper);
        token.approve(mechanismAddr, type(uint256).max);
        tokenized.signup(100 ether);
        vm.stopPrank();
    }

    function testFix_AllowsReproposalAfterCancel() public {
        vm.prank(keeper);
        uint256 firstProposalId = TokenizedAllocationMechanism(address(mechanism)).propose(recipient, "Initial");

        vm.prank(management);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.RecipientUsed.selector, recipient));
        TokenizedAllocationMechanism(address(mechanism)).propose(recipient, "Should revert");

        vm.prank(keeper);
        TokenizedAllocationMechanism(address(mechanism)).cancelProposal(firstProposalId);

        vm.prank(management);
        uint256 secondProposalId = TokenizedAllocationMechanism(address(mechanism)).propose(recipient, "Reproposal");

        assertGt(secondProposalId, firstProposalId, "Reproposal should succeed with new id");
    }
}
