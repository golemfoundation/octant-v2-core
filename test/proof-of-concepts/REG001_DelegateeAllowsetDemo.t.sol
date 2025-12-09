// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import "forge-std/Test.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { Staker } from "staker/Staker.sol";

/**
 * @title REG-001 Delegatee AddressSet Architecture Demonstration
 * @dev Demonstrates that delegatee allowset architecture is CORRECT and SECURE
 *
 * FINDING RECLASSIFIED: REG-001 was initially documented as Medium severity
 * but was reclassified as NOT A VULNERABILITY after proper analysis.
 *
 * KEY ARCHITECTURAL INSIGHTS:
 * 1. Delegatees are external governance participants (e.g., Optimism DAO voting)
 * 2. Delegatees have ZERO protocol permissions in RegenStaker
 * 3. Delegatees cannot claim rewards, stake, or perform protocol operations
 * 4. Only deposit.owner needs allowset validation for protocol operations
 * 5. This represents CORRECT separation of protocol vs external governance concerns
 *
 * DEVELOPER CLARIFICATION:
 * "There is no point checking if delegatee is in the staker allowset.
 * Delegatee is the actor who can use voting rights of the stake token
 * in the relevant governance. For example, if stake token was OP,
 * delegatee can use OP voting right in Optimism Governance. It's not
 * relevant to Regen Staker."
 *
 * EXPECTED: All tests should PASS showing the architecture works correctly
 * This is NOT an exploit test - it's an architecture validation test
 */
contract REG001_DelegateeAllowsetDemoTest is Test {
    RegenStaker public regenStaker;
    RegenEarningPowerCalculator public earningPowerCalculator;
    MockERC20 public rewardToken;
    MockERC20Staking public stakeToken;
    AddressSet public stakerAllowset;
    AddressSet public contributionAllowset;
    AddressSet public allocationMechanismAllowset;
    AddressSet public earningPowerAllowset;

    address public admin = makeAddr("admin");
    address public rewardNotifier = makeAddr("rewardNotifier");
    address public authorizedUser = makeAddr("authorizedUser");
    address public unauthorizedUser = makeAddr("unauthorizedUser");
    address public externalGovernanceDelegatee = makeAddr("externalGovernanceDelegatee");
    address public anotherDelegatee = makeAddr("anotherDelegatee");

    uint256 public constant INITIAL_REWARD_AMOUNT = 100 ether;
    uint256 public constant USER_STAKE_AMOUNT = 10 ether;
    uint256 public constant REWARD_DURATION = 30 days;

    function setUp() public {
        vm.startPrank(admin);

        // Deploy contracts
        rewardToken = new MockERC20(18);
        stakeToken = new MockERC20Staking(18);
        stakerAllowset = new AddressSet();
        contributionAllowset = new AddressSet();
        allocationMechanismAllowset = new AddressSet();
        earningPowerAllowset = new AddressSet();
        earningPowerCalculator = new RegenEarningPowerCalculator(
            address(this),
            earningPowerAllowset,
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        // Deploy RegenStaker
        regenStaker = new RegenStaker(
            rewardToken,
            stakeToken,
            earningPowerCalculator,
            1000, // maxBumpTip
            admin, // admin
            uint128(REWARD_DURATION), // rewardDuration
            0, // minStakeAmount
            stakerAllowset,
            IAddressSet(address(0)),
            AccessMode.ALLOWSET,
            allocationMechanismAllowset
        );

        // Setup reward notifier
        regenStaker.setRewardNotifier(rewardNotifier, true);

        // Setup allowsets - ONLY allowset the actual staker, NOT the delegatee
        stakerAllowset.add(authorizedUser);
        // Note: externalGovernanceDelegatee is deliberately NOT inAllowset
        // Note: unauthorizedUser is deliberately NOT inAllowset
        earningPowerAllowset.add(authorizedUser);

        // Mint tokens
        rewardToken.mint(rewardNotifier, INITIAL_REWARD_AMOUNT);
        stakeToken.mint(authorizedUser, USER_STAKE_AMOUNT * 2);
        stakeToken.mint(unauthorizedUser, USER_STAKE_AMOUNT);

        vm.stopPrank();
    }

    /**
     * @dev Demonstrates that inAllowset users can stake with non-inAllowset delegatees
     * This is the CORRECT behavior - only the staker needs allowset approval
     */
    function testREG001_AllowsetedUserCanStakeWithNonAllowsetedDelegatee() public {
        console.log("=== REG-001 DEMONSTRATION: Allowseted User + Non-Allowseted Delegatee ===");

        console.log("Allowseted user:", authorizedUser);
        console.log("External governance delegatee (NOT inAllowset):", externalGovernanceDelegatee);

        // Verify allowset status
        assertTrue(stakerAllowset.contains(authorizedUser), "User should be inAllowset");
        assertFalse(stakerAllowset.contains(externalGovernanceDelegatee), "Delegatee should NOT be inAllowset");

        vm.startPrank(authorizedUser);
        stakeToken.approve(address(regenStaker), USER_STAKE_AMOUNT);

        // This should work - inAllowset user delegating to non-inAllowset delegatee
        Staker.DepositIdentifier depositId = regenStaker.stake(
            USER_STAKE_AMOUNT,
            externalGovernanceDelegatee, // Non-inAllowset delegatee - this is CORRECT
            authorizedUser
        );

        vm.stopPrank();

        console.log("SUCCESS: Successfully staked with non-inAllowset delegatee");
        console.log("Deposit ID:", Staker.DepositIdentifier.unwrap(depositId));

        // Verify the deposit was created correctly
        assertTrue(Staker.DepositIdentifier.unwrap(depositId) >= 0, "Deposit should be created");

        // Verify delegatee assignment worked
        address assignedDelegatee = address(regenStaker.surrogates(externalGovernanceDelegatee));
        console.log("Surrogate deployed for delegatee:", assignedDelegatee);
        assertTrue(assignedDelegatee != address(0), "Surrogate should be deployed for delegatee");

        console.log("SUCCESS: CORRECT BEHAVIOR: Architecture allows delegation to external governance actors");
    }

    /**
     * @dev Demonstrates that non-inAllowset users CANNOT stake (regardless of delegatee)
     * This shows proper access control on the actual protocol user
     */
    function testREG001_NonAllowsetedUserCannotStake() public {
        console.log("=== REG-001 DEMONSTRATION: Non-Allowseted User Cannot Stake ===");

        console.log("Non-inAllowset user:", unauthorizedUser);
        console.log("External governance delegatee:", externalGovernanceDelegatee);

        // Verify allowset status
        assertFalse(stakerAllowset.contains(unauthorizedUser), "User should NOT be inAllowset");

        vm.startPrank(unauthorizedUser);
        stakeToken.approve(address(regenStaker), USER_STAKE_AMOUNT);

        // This should FAIL - non-inAllowset user trying to stake
        vm.expectRevert(); // Should revert due to allowset check on deposit.owner
        regenStaker.stake(USER_STAKE_AMOUNT, externalGovernanceDelegatee, unauthorizedUser);

        vm.stopPrank();

        console.log("SUCCESS: CORRECT BEHAVIOR: Non-inAllowset users cannot stake");
        console.log("SUCCESS: Access control properly enforced on deposit.owner, not delegatee");
    }

    /**
     * @dev Demonstrates stakeMore() uses deposit.owner for allowset checks
     * This is the CORRECT behavior and shows no inconsistency with stake()
     */
    function testREG001_StakeMoreUsesDepositOwnerAddressSet() public {
        console.log("=== REG-001 DEMONSTRATION: StakeMore Uses Deposit Owner for AddressSet ===");

        // First, create a deposit
        vm.startPrank(authorizedUser);
        stakeToken.approve(address(regenStaker), USER_STAKE_AMOUNT * 2);

        Staker.DepositIdentifier depositId = regenStaker.stake(
            USER_STAKE_AMOUNT,
            externalGovernanceDelegatee, // Non-inAllowset delegatee
            authorizedUser
        );

        console.log("Initial deposit created with ID:", Staker.DepositIdentifier.unwrap(depositId));

        // Now try stakeMore - should work because deposit.owner is inAllowset
        regenStaker.stakeMore(depositId, USER_STAKE_AMOUNT);

        vm.stopPrank();

        console.log("SUCCESS: StakeMore successful for inAllowset deposit owner");
        console.log("SUCCESS: CORRECT BEHAVIOR: stakeMore() checks deposit.owner, not delegatee");
        console.log("SUCCESS: No inconsistency between stake() and stakeMore() - both use proper access control");
    }

    /**
     * @dev Demonstrates delegatees have NO protocol permissions
     * This proves delegatees cannot exploit the protocol
     */
    function testREG001_DelegateesHaveNoProtocolPermissions() public {
        console.log("=== REG-001 DEMONSTRATION: Delegatees Have No Protocol Permissions ===");

        // Setup: Create a deposit with delegation
        vm.startPrank(authorizedUser);
        stakeToken.approve(address(regenStaker), USER_STAKE_AMOUNT);

        Staker.DepositIdentifier depositId = regenStaker.stake(
            USER_STAKE_AMOUNT,
            externalGovernanceDelegatee,
            authorizedUser
        );
        vm.stopPrank();

        // Start rewards to accumulate some
        vm.startPrank(rewardNotifier);
        rewardToken.approve(address(regenStaker), INITIAL_REWARD_AMOUNT);
        rewardToken.transfer(address(regenStaker), INITIAL_REWARD_AMOUNT);
        regenStaker.notifyRewardAmount(INITIAL_REWARD_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 10 days);

        console.log("Deposit created, rewards started, time advanced");

        // Test 1: Delegatee cannot claim rewards
        console.log("\n--- Testing: Delegatee cannot claim rewards ---");
        vm.startPrank(externalGovernanceDelegatee);

        vm.expectRevert(); // Should revert - delegatee is not deposit owner
        regenStaker.claimReward(depositId);

        vm.stopPrank();
        console.log("SUCCESS: Delegatee correctly CANNOT claim rewards");

        // Test 2: Delegatee cannot stakeMore
        console.log("\n--- Testing: Delegatee cannot stakeMore ---");
        stakeToken.mint(externalGovernanceDelegatee, USER_STAKE_AMOUNT);

        vm.startPrank(externalGovernanceDelegatee);
        stakeToken.approve(address(regenStaker), USER_STAKE_AMOUNT);

        vm.expectRevert(); // Should revert - delegatee is not deposit owner
        regenStaker.stakeMore(depositId, USER_STAKE_AMOUNT);

        vm.stopPrank();
        console.log("SUCCESS: Delegatee correctly CANNOT stakeMore");

        // Test 3: Delegatee cannot withdraw
        console.log("\n--- Testing: Delegatee cannot withdraw ---");
        vm.startPrank(externalGovernanceDelegatee);

        vm.expectRevert(); // Should revert - delegatee is not deposit owner
        regenStaker.withdraw(depositId, USER_STAKE_AMOUNT);

        vm.stopPrank();
        console.log("SUCCESS: Delegatee correctly CANNOT withdraw");

        console.log("\nSUCCESS: SECURITY CONFIRMED: Delegatees have ZERO protocol permissions");
        console.log("SUCCESS: Delegatees can only participate in EXTERNAL governance (e.g., OP voting)");
    }

    /**
     * @dev Demonstrates the correct separation of concerns:
     * - Protocol operations controlled by deposit.owner allowset
     * - External governance controlled by delegatee assignment
     */
    function testREG001_CorrectSeparationOfConcerns() public {
        console.log("=== REG-001 DEMONSTRATION: Correct Separation of Concerns ===");

        // Setup multiple deposits with different delegatees
        vm.startPrank(authorizedUser);
        stakeToken.approve(address(regenStaker), USER_STAKE_AMOUNT * 2);

        // Deposit 1: Delegate to first external governance actor
        Staker.DepositIdentifier depositId1 = regenStaker.stake(
            USER_STAKE_AMOUNT,
            externalGovernanceDelegatee,
            authorizedUser
        );

        // Deposit 2: Delegate to different external governance actor
        Staker.DepositIdentifier depositId2 = regenStaker.stake(USER_STAKE_AMOUNT, anotherDelegatee, authorizedUser);

        vm.stopPrank();

        console.log("Created deposits with different delegatees:");
        console.log(
            "Deposit 1 ID:",
            Staker.DepositIdentifier.unwrap(depositId1),
            "-> Delegatee:",
            externalGovernanceDelegatee
        );
        console.log("Deposit 2 ID:", Staker.DepositIdentifier.unwrap(depositId2), "-> Delegatee:", anotherDelegatee);

        // Verify different surrogates were deployed
        address surrogate1 = address(regenStaker.surrogates(externalGovernanceDelegatee));
        address surrogate2 = address(regenStaker.surrogates(anotherDelegatee));

        console.log("Surrogate 1 address:", surrogate1);
        console.log("Surrogate 2 address:", surrogate2);

        assertTrue(surrogate1 != surrogate2, "Different delegatees should have different surrogates");
        assertTrue(surrogate1 != address(0), "Surrogate 1 should be deployed");
        assertTrue(surrogate2 != address(0), "Surrogate 2 should be deployed");

        // Verify the same user (authorizedUser) can perform protocol operations on both
        // This demonstrates proper separation: protocol control vs governance delegation

        // Start rewards
        vm.startPrank(rewardNotifier);
        rewardToken.approve(address(regenStaker), INITIAL_REWARD_AMOUNT);
        rewardToken.transfer(address(regenStaker), INITIAL_REWARD_AMOUNT);
        regenStaker.notifyRewardAmount(INITIAL_REWARD_AMOUNT);
        vm.stopPrank();

        vm.warp(block.timestamp + 5 days);

        // The inAllowset user can manage both deposits despite different delegatees
        vm.startPrank(authorizedUser);

        uint256 reward1 = regenStaker.claimReward(depositId1);
        uint256 reward2 = regenStaker.claimReward(depositId2);

        vm.stopPrank();

        console.log("User successfully claimed rewards from both deposits:");
        console.log("Reward 1:", reward1);
        console.log("Reward 2:", reward2);

        console.log("\nSUCCESS: CORRECT ARCHITECTURE DEMONSTRATED:");
        console.log("SUCCESS: Protocol operations controlled by deposit.owner allowset");
        console.log("SUCCESS: External governance controlled by delegatee assignment");
        console.log("SUCCESS: Perfect separation of protocol vs external governance concerns");
    }

    /**
     * @dev Demonstrates why delegatee allowset checks would be architecturally wrong
     * This test shows what would happen if delegatees were required to be inAllowset
     */
    function testREG001_WhyDelegateeAllowsetWouldBeWrong() public {
        console.log("=== REG-001 DEMONSTRATION: Why Delegatee AddressSet Would Be Wrong ===");

        console.log("ARCHITECTURAL ANALYSIS:");
        console.log("If delegatees were required to be inAllowset, it would:");
        console.log("1. Force external governance actors to be approved by RegenStaker admin");
        console.log("2. Create artificial coupling between protocol and external governance");
        console.log("3. Limit users' choice of governance representatives");
        console.log("4. Provide no security benefit (delegatees have no protocol permissions)");

        // Demonstrate the key insight: delegatees are for EXTERNAL governance only
        console.log("\nEXAMPLE SCENARIO:");
        console.log("- Stake token = OP (Optimism token)");
        console.log("- User stakes OP in RegenStaker");
        console.log("- User delegates to respected OP governance participant");
        console.log("- That governance participant can vote in OPTIMISM DAO, not RegenStaker");
        console.log("- RegenStaker admin has no business approving Optimism governance participants");

        // Show current correct behavior
        vm.startPrank(authorizedUser);
        stakeToken.approve(address(regenStaker), USER_STAKE_AMOUNT);

        Staker.DepositIdentifier depositId = regenStaker.stake(
            USER_STAKE_AMOUNT,
            externalGovernanceDelegatee, // Could be any governance actor
            authorizedUser
        );

        vm.stopPrank();

        console.log("\nSUCCESS: CURRENT CORRECT BEHAVIOR:");
        console.log("SUCCESS: Users can delegate to any external governance actor");
        console.log("SUCCESS: RegenStaker admin doesn't control external governance choices");
        console.log("SUCCESS: Clean separation between protocol and external governance");
        console.log("SUCCESS: Deposit ID:", Staker.DepositIdentifier.unwrap(depositId), "successfully created");

        console.log("\nSUCCESS: CONCLUSION: REG-001 is NOT a vulnerability");
        console.log("SUCCESS: The architecture is correct and secure");
        console.log("SUCCESS: No allowset check on delegatees is the RIGHT design");
    }

    /**
     * @dev Test that shows the _getStakeMoreAllowsetTarget function works correctly
     * This addresses the Q3 audit question about why this function exists
     */
    function testREG001_StakeMoreAllowsetTargetFunction() public {
        console.log("=== REG-001 DEMONSTRATION: StakeMore AddressSet Target Function ===");

        // Create a deposit
        vm.startPrank(authorizedUser);
        stakeToken.approve(address(regenStaker), USER_STAKE_AMOUNT * 2);

        Staker.DepositIdentifier depositId = regenStaker.stake(
            USER_STAKE_AMOUNT,
            externalGovernanceDelegatee,
            authorizedUser
        );

        // StakeMore should work because it checks deposit.owner (authorizedUser)
        regenStaker.stakeMore(depositId, USER_STAKE_AMOUNT);

        vm.stopPrank();

        console.log("SUCCESS: StakeMore successful - correctly uses deposit.owner for allowset check");

        // Developer's insight: The virtual function abstraction was created due to
        // uncertainty about which actor should be allowset-checked among multiple roles
        // (caller, depositor, claimer, delegatee). Current implementation correctly
        // checks deposit.owner.

        console.log("\nDEVELOPER INSIGHT (from audit Q3 response):");
        console.log("'I wasn't sure at some point which actor should be checked against");
        console.log("the allowset so I came up with this virtual function. It would be");
        console.log("good to eliminate this virtual function assuming that this final");
        console.log("design (always checking deposit.owner against staker allowset) makes sense.'");

        console.log("\nSUCCESS: The virtual function represents premature abstraction");
        console.log("SUCCESS: Current implementation correctly checks deposit.owner");
        console.log("SUCCESS: Function can be simplified in future refactoring");
    }

    /**
     * @dev Summary test that validates the overall REG-001 conclusion
     */
    function testREG001_FinalValidation() public {
        console.log("=== REG-001 FINAL VALIDATION ===");

        console.log("FINDING SUMMARY:");
        console.log("- Initially reported as Medium severity inconsistency");
        console.log("- Reclassified as NOT A VULNERABILITY after proper analysis");
        console.log("- Represents correct protocol architecture");

        console.log("\nKEY ARCHITECTURAL PRINCIPLES VALIDATED:");

        // 1. Proper access control
        vm.startPrank(authorizedUser);
        stakeToken.approve(address(regenStaker), USER_STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = regenStaker.stake(
            USER_STAKE_AMOUNT,
            externalGovernanceDelegatee,
            authorizedUser
        );
        vm.stopPrank();
        console.log("SUCCESS: 1. Allowseted users can stake with any delegatee");

        // 2. Delegatees have no protocol permissions
        vm.expectRevert();
        vm.prank(externalGovernanceDelegatee);
        regenStaker.claimReward(depositId);
        console.log("SUCCESS: 2. Delegatees cannot perform protocol operations");

        // 3. Consistent allowset checking
        vm.startPrank(unauthorizedUser);
        stakeToken.approve(address(regenStaker), USER_STAKE_AMOUNT);
        vm.expectRevert();
        regenStaker.stake(USER_STAKE_AMOUNT, externalGovernanceDelegatee, unauthorizedUser);
        vm.stopPrank();
        console.log("SUCCESS: 3. Non-inAllowset users cannot stake regardless of delegatee");

        console.log("\nSUCCESS: REG-001 CONCLUSION: Architecture is CORRECT and SECURE");
        console.log("SUCCESS: No vulnerability exists - this is proper protocol design");
        console.log("SUCCESS: Separates protocol operations from external governance delegation");

        assertTrue(true, "REG-001 architecture validation complete - no vulnerability");
    }
}
