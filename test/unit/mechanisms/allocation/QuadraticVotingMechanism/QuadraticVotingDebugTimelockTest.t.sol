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

contract QuadraticVotingDebugTimelockTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = address(0x1);
    address charlie = address(0x3);

    uint256 constant LARGE_DEPOSIT = 1000 ether;
    uint256 constant TIMELOCK_DELAY = 1 days;

    function _tokenized(address _mechanism) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(_mechanism);
    }

    function setUp() public {
        // Set timestamp before deploying mechanism
        vm.warp(100000);

        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();
        token.mint(alice, 2000 ether);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Debug Test",
            symbol: "DEBUG",
            votingDelay: 100,
            votingPeriod: 1000,
            quorumShares: 500,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, 50, 100); // 50% alpha
        mechanism = QuadraticVotingMechanism(payable(mechanismAddr));
        _tokenized(address(mechanism)).setKeeper(alice);
    }

    function testDebugTimelock() public {
        console.log("Initial timestamp:", block.timestamp);

        // Setup successful proposal during delay period (before voting starts)
        vm.startPrank(alice);
        token.approve(address(mechanism), LARGE_DEPOSIT);
        _tokenized(address(mechanism)).signup(LARGE_DEPOSIT);
        uint256 pid = _tokenized(address(mechanism)).propose(charlie, "Charlie's Project");
        vm.stopPrank();

        // Move to voting period: startTime + votingDelay = 100000 + 100 = 100100
        vm.warp(100100);

        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 31, charlie); // 31^2 = 961 > 500 quorum

        // Move past voting period: startTime + votingDelay + votingPeriod = 100000 + 100 + 1000 = 101100
        vm.warp(101101);
        (bool success, ) = address(mechanism).call(abi.encodeWithSignature("finalizeVoteTally()"));
        require(success, "Finalization failed");

        console.log("=== BEFORE QUEUING ===");
        console.log("Current timestamp:", block.timestamp);
        console.log("Charlie redeemableAfter BEFORE:", _tokenized(address(mechanism)).globalRedemptionStart());
        console.log("Charlie balance BEFORE:", _tokenized(address(mechanism)).balanceOf(charlie));
        console.log("Charlie maxRedeem BEFORE:", _tokenized(address(mechanism)).maxRedeem(charlie));

        uint256 queueTime = block.timestamp;
        console.log("Queue time:", queueTime);
        console.log("Timelock delay:", _tokenized(address(mechanism)).timelockDelay());
        console.log("Expected redeemable time:", queueTime + TIMELOCK_DELAY);

        (bool success2, ) = address(mechanism).call(abi.encodeWithSignature("queueProposal(uint256)", pid));
        require(success2, "Queue failed");

        console.log("=== AFTER QUEUING ===");
        console.log("Current timestamp:", block.timestamp);
        console.log("Charlie redeemableAfter AFTER:", _tokenized(address(mechanism)).globalRedemptionStart());
        console.log("Charlie balance AFTER:", _tokenized(address(mechanism)).balanceOf(charlie));
        console.log("Charlie maxRedeem AFTER:", _tokenized(address(mechanism)).maxRedeem(charlie));

        // Check if timelock is working
        uint256 maxRedeem = _tokenized(address(mechanism)).maxRedeem(charlie);
        console.log("Max redeem immediately after queue:", maxRedeem);

        if (maxRedeem == 0) {
            console.log("SUCCESS: Timelock is blocking redemption");
        } else {
            console.log("FAILURE: Timelock is NOT blocking redemption");
            console.log("Expected: 0, Got:", maxRedeem);
        }

        // Debug the _availableWithdrawLimit logic step by step
        uint256 redeemableTime = _tokenized(address(mechanism)).globalRedemptionStart();
        console.log("Debug - redeemableTime:", redeemableTime);
        console.log("Debug - block.timestamp:", block.timestamp);
        console.log("Debug - block.timestamp < redeemableTime:", block.timestamp < redeemableTime);

        if (redeemableTime == 0) {
            console.log("DEBUG: redeemableTime is 0 - this should not happen after queuing");
        } else if (block.timestamp < redeemableTime) {
            console.log("DEBUG: We are in timelock period - should return 0");
        } else {
            console.log("DEBUG: We are past timelock - should allow redemption");
        }
    }
}
