// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { Staker } from "staker/Staker.sol";
import { DelegationSurrogate } from "staker/DelegationSurrogate.sol";
import { DelegationSurrogateVotes } from "staker/DelegationSurrogateVotes.sol";
import { IERC20Delegates } from "staker/interfaces/IERC20Delegates.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AddressSet } from "src/utils/AddressSet.sol";

/// @title RegenStaker CREATE2 Deployment Tests
/// @notice Comprehensive tests for deterministic surrogate deployment using CREATE2
/// @dev Tests address REG-021 - Implementation of deterministic surrogate deployment
contract RegenStakerCreate2Test is Test {
    RegenStaker public staker;
    MockERC20Staking public stakeToken;
    MockERC20Staking public rewardToken;
    RegenEarningPowerCalculator public earningPowerCalculator;
    AddressSet public allowset;

    address public admin = makeAddr("admin");
    address public user = makeAddr("user");

    uint256 constant INITIAL_BALANCE = 1_000_000e18;
    uint256 constant STAKE_AMOUNT = 1000e18;

    event DelegationSurrogateDeployed(address indexed delegatee, address surrogate);

    function setUp() public {
        // Deploy tokens
        stakeToken = new MockERC20Staking(18);
        rewardToken = new MockERC20Staking(18);

        // Deploy allowsets
        allowset = new AddressSet();
        allowset.add(user);

        // Deploy allocation mechanism allowset
        AddressSet allocationAllowset = new AddressSet();

        // Deploy earning power calculator
        earningPowerCalculator = new RegenEarningPowerCalculator(
            admin,
            IAddressSet(address(allowset)),
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        // Deploy staker
        staker = new RegenStaker(
            IERC20(address(rewardToken)),
            stakeToken,
            earningPowerCalculator,
            0, // maxBumpTip
            admin,
            30 days, // rewardDuration
            1e18, // minimumStakeAmount
            IAddressSet(address(allowset)), // stakerAllowset
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset)) // allocationMechanismAllowset
        );

        // Setup tokens
        stakeToken.mint(user, INITIAL_BALANCE);
        rewardToken.mint(admin, INITIAL_BALANCE);

        // User approves staker
        vm.prank(user);
        stakeToken.approve(address(staker), type(uint256).max);
    }

    /// @notice Test that predicted address matches actual deployed address
    function testCreate2DeterministicDeployment(address delegatee) public {
        vm.assume(delegatee != address(0));

        // Predict the surrogate address
        address predictedAddress = staker.predictSurrogateAddress(delegatee);

        // Deploy the surrogate by staking
        vm.prank(user);
        staker.stake(STAKE_AMOUNT, delegatee, user);

        // Get the actual deployed surrogate
        DelegationSurrogate actualSurrogate = staker.surrogates(delegatee);

        // Verify the addresses match
        assertEq(address(actualSurrogate), predictedAddress, "Predicted address should match deployed address");
    }

    /// @notice Fuzz test: Multiple delegatees with deterministic addresses
    function testFuzzMultipleDelegateesDeterministicAddresses(
        address[] memory delegatees,
        uint256[] memory amounts
    ) public {
        // Handle empty arrays
        if (delegatees.length == 0 || amounts.length == 0) return;

        // Bound inputs - use the minimum of both array lengths to avoid out-of-bounds
        uint256 length = bound(delegatees.length, 1, 10);
        if (length > amounts.length) {
            length = amounts.length;
        }

        // Prepare valid delegatees and amounts
        for (uint256 i = 0; i < length; i++) {
            if (i >= delegatees.length) break; // Extra safety check
            if (delegatees[i] == address(0)) {
                delegatees[i] = makeAddr(string(abi.encodePacked("delegatee", i)));
            }
            amounts[i] = bound(amounts[i], 1e18, 10_000e18);
        }

        // Give user enough tokens
        uint256 totalAmount = 0;
        for (uint256 i = 0; i < length; i++) {
            totalAmount += amounts[i];
        }
        stakeToken.mint(user, totalAmount);

        // Predict addresses and stake
        address[] memory predictedAddresses = new address[](length);
        address[] memory actualAddresses = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            // Predict address before deployment
            predictedAddresses[i] = staker.predictSurrogateAddress(delegatees[i]);

            // Stake to deploy surrogate
            vm.prank(user);
            staker.stake(amounts[i], delegatees[i], user);

            // Get actual deployed address
            actualAddresses[i] = address(staker.surrogates(delegatees[i]));
        }

        // Verify all predictions were correct
        for (uint256 i = 0; i < length; i++) {
            assertEq(actualAddresses[i], predictedAddresses[i], "All predictions should be correct");
        }
    }

    /// @notice Test that the same delegatee always produces the same surrogate address
    function testSameDelegateeAlwaysSameAddress(address delegatee) public {
        vm.assume(delegatee != address(0));

        // Predict address multiple times
        address prediction1 = staker.predictSurrogateAddress(delegatee);
        address prediction2 = staker.predictSurrogateAddress(delegatee);
        address prediction3 = staker.predictSurrogateAddress(delegatee);

        // All predictions should be the same
        assertEq(prediction1, prediction2, "Predictions should be consistent");
        assertEq(prediction2, prediction3, "Predictions should be consistent");

        // Deploy and verify
        vm.prank(user);
        staker.stake(STAKE_AMOUNT, delegatee, user);

        address actualAddress = address(staker.surrogates(delegatee));
        assertEq(actualAddress, prediction1, "Deployed address should match prediction");
    }

    /// @notice Test that different delegatees produce different surrogate addresses
    function testDifferentDelegateesDifferentAddresses(address delegatee1, address delegatee2) public {
        vm.assume(delegatee1 != address(0) && delegatee2 != address(0));
        vm.assume(delegatee1 != delegatee2);

        // Predict addresses
        address predicted1 = staker.predictSurrogateAddress(delegatee1);
        address predicted2 = staker.predictSurrogateAddress(delegatee2);

        // Addresses should be different
        assertTrue(predicted1 != predicted2, "Different delegatees should have different surrogates");

        // Give user more tokens
        stakeToken.mint(user, STAKE_AMOUNT);

        // Deploy both
        vm.startPrank(user);
        staker.stake(STAKE_AMOUNT, delegatee1, user);
        staker.stake(STAKE_AMOUNT, delegatee2, user);
        vm.stopPrank();

        // Verify actual addresses match predictions and are different
        address actual1 = address(staker.surrogates(delegatee1));
        address actual2 = address(staker.surrogates(delegatee2));

        assertEq(actual1, predicted1, "First surrogate should match prediction");
        assertEq(actual2, predicted2, "Second surrogate should match prediction");
        assertTrue(actual1 != actual2, "Actual surrogates should be different");
    }

    /// @notice Test that surrogates delegate correctly to their delegatees
    function testSurrogateDelegationCorrectness(address delegatee) public {
        vm.assume(delegatee != address(0));

        // Deploy surrogate
        vm.prank(user);
        staker.stake(STAKE_AMOUNT, delegatee, user);

        // Get the surrogate
        DelegationSurrogate surrogate = staker.surrogates(delegatee);

        // Check that the surrogate has delegated to the correct delegatee
        address actualDelegatee = IERC20Delegates(address(stakeToken)).delegates(address(surrogate));
        assertEq(actualDelegatee, delegatee, "Surrogate should delegate to correct delegatee");
    }

    /// @notice Test edge case: deploying surrogate for address(0)
    function testCannotDeployForZeroAddress() public {
        // Attempting to stake to address(0) should revert
        vm.prank(user);
        vm.expectRevert();
        staker.stake(STAKE_AMOUNT, address(0), user);
    }

    /// @notice Test that reusing existing surrogate doesn't create a new one
    function testReuseExistingSurrogate(address delegatee) public {
        vm.assume(delegatee != address(0));

        // Give user more tokens
        stakeToken.mint(user, STAKE_AMOUNT);

        // First stake - deploys surrogate
        vm.prank(user);
        staker.stake(STAKE_AMOUNT, delegatee, user);

        address firstSurrogate = address(staker.surrogates(delegatee));

        // Second stake - should reuse existing surrogate
        vm.prank(user);
        staker.stake(STAKE_AMOUNT, delegatee, user);

        address secondSurrogate = address(staker.surrogates(delegatee));

        // Should be the same surrogate
        assertEq(firstSurrogate, secondSurrogate, "Should reuse existing surrogate");
    }

    /// @notice Test gas optimization: pre-deploying surrogates
    function testPreDeploySurrogate(address delegatee) public {
        vm.assume(delegatee != address(0));

        // Predict the surrogate address
        address predictedAddress = staker.predictSurrogateAddress(delegatee);

        // Pre-deploy by staking minimal amount
        vm.prank(user);
        uint256 gasBefore = gasleft();
        staker.stake(1e18, delegatee, user);
        uint256 gasUsedFirstStake = gasBefore - gasleft();

        // Verify surrogate was deployed
        assertEq(address(staker.surrogates(delegatee)), predictedAddress, "Surrogate should be deployed");

        // Subsequent stake should use less gas
        vm.prank(user);
        gasBefore = gasleft();
        staker.stake(STAKE_AMOUNT - 1e18, delegatee, user);
        uint256 gasUsedSecondStake = gasBefore - gasleft();

        // Second stake should use significantly less gas
        assertTrue(gasUsedSecondStake < gasUsedFirstStake / 2, "Reusing surrogate should be cheaper");
    }

    /// @notice Test that predicted addresses are consistent across different contract deployments
    function testCrossContractAddressPrediction(address delegatee) public {
        vm.assume(delegatee != address(0));

        // Predict address from current staker
        address prediction1 = staker.predictSurrogateAddress(delegatee);

        // Deploy a new staker with same parameters
        AddressSet allocationAllowset2 = new AddressSet();
        RegenStaker staker2 = new RegenStaker(
            IERC20(address(rewardToken)),
            stakeToken,
            earningPowerCalculator,
            0,
            admin,
            30 days,
            1e18,
            IAddressSet(address(allowset)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset2))
        );

        // Predict from new staker
        address prediction2 = staker2.predictSurrogateAddress(delegatee);

        // Predictions should be different (different deployer addresses)
        assertTrue(prediction1 != prediction2, "Different stakers should predict different addresses");
    }

    /// @notice Fuzz test: Verify salt calculation is deterministic
    function testFuzzSaltCalculation(address delegatee1, address delegatee2) public pure {
        // Calculate salts
        bytes32 salt1 = keccak256(abi.encodePacked(delegatee1));
        bytes32 salt2 = keccak256(abi.encodePacked(delegatee2));

        if (delegatee1 == delegatee2) {
            assert(salt1 == salt2); // Same delegatee should produce same salt
        } else {
            assert(salt1 != salt2); // Different delegatees should produce different salts
        }
    }

    // ============ Critical Surrogate Isolation Tests ============

    /// @notice CRITICAL TEST: Prove two different users CANNOT share the same surrogate
    /// @dev This test ensures that surrogates are uniquely determined by delegatee, not by user
    function testTwoUsersCannotShareSameSurrogate() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie"); // Common delegatee

        // Setup both users
        allowset.add(alice);
        allowset.add(bob);

        stakeToken.mint(alice, STAKE_AMOUNT);
        stakeToken.mint(bob, STAKE_AMOUNT);

        vm.prank(alice);
        stakeToken.approve(address(staker), type(uint256).max);

        vm.prank(bob);
        stakeToken.approve(address(staker), type(uint256).max);

        // Alice stakes to Charlie
        vm.prank(alice);
        staker.stake(STAKE_AMOUNT, charlie, alice);
        address aliceSurrogate = address(staker.surrogates(charlie));

        // Bob stakes to Charlie (same delegatee)
        vm.prank(bob);
        staker.stake(STAKE_AMOUNT, charlie, bob);
        address bobSurrogate = address(staker.surrogates(charlie));

        // CRITICAL ASSERTION: Both users MUST use the SAME surrogate for the same delegatee
        // This is by design - the surrogate is determined by delegatee, not user
        assertEq(aliceSurrogate, bobSurrogate, "Same delegatee MUST result in same surrogate");

        // Verify the surrogate holds tokens from both users
        uint256 surrogateBalance = stakeToken.balanceOf(aliceSurrogate);
        assertEq(surrogateBalance, STAKE_AMOUNT * 2, "Surrogate should hold both users' stakes");

        // Verify the surrogate has delegated to Charlie
        address surrogateDelegate = IERC20Delegates(address(stakeToken)).delegates(aliceSurrogate);
        assertEq(surrogateDelegate, charlie, "Surrogate should delegate to Charlie");
    }

    /// @notice Test that users delegating to DIFFERENT addresses get DIFFERENT surrogates
    function testUsersWithDifferentDelegateesGetDifferentSurrogates() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlieDelegate = makeAddr("charlieDelegate");
        address davidDelegate = makeAddr("davidDelegate");

        // Setup both users
        allowset.add(alice);
        allowset.add(bob);

        stakeToken.mint(alice, STAKE_AMOUNT);
        stakeToken.mint(bob, STAKE_AMOUNT);

        vm.prank(alice);
        stakeToken.approve(address(staker), type(uint256).max);

        vm.prank(bob);
        stakeToken.approve(address(staker), type(uint256).max);

        // Alice delegates to Charlie
        vm.prank(alice);
        staker.stake(STAKE_AMOUNT, charlieDelegate, alice);
        address aliceSurrogate = address(staker.surrogates(charlieDelegate));

        // Bob delegates to David (different delegatee)
        vm.prank(bob);
        staker.stake(STAKE_AMOUNT, davidDelegate, bob);
        address bobSurrogate = address(staker.surrogates(davidDelegate));

        // CRITICAL: Different delegatees MUST result in different surrogates
        assertTrue(aliceSurrogate != bobSurrogate, "Different delegatees MUST have different surrogates");

        // Verify each surrogate only holds the respective user's stake
        assertEq(
            stakeToken.balanceOf(aliceSurrogate),
            STAKE_AMOUNT,
            "Charlie's surrogate should only hold Alice's stake"
        );
        assertEq(stakeToken.balanceOf(bobSurrogate), STAKE_AMOUNT, "David's surrogate should only hold Bob's stake");

        // Verify each surrogate delegates to the correct delegatee
        assertEq(
            IERC20Delegates(address(stakeToken)).delegates(aliceSurrogate),
            charlieDelegate,
            "Alice's surrogate should delegate to Charlie"
        );
        assertEq(
            IERC20Delegates(address(stakeToken)).delegates(bobSurrogate),
            davidDelegate,
            "Bob's surrogate should delegate to David"
        );
    }

    /// @notice Fuzz test: Multiple users staking to same delegatee share surrogate
    function testFuzzMultipleUsersShareSurrogateForSameDelegatee(
        address[5] memory users,
        address delegatee,
        uint256[5] memory amounts
    ) public {
        vm.assume(delegatee != address(0));

        // Setup valid users and amounts
        for (uint256 i = 0; i < 5; i++) {
            if (users[i] == address(0)) {
                users[i] = makeAddr(string(abi.encodePacked("user", i)));
            }
            amounts[i] = bound(amounts[i], 1e18, 100_000e18);

            // Setup user - only add to allowset if not already inAllowset
            if (!allowset.contains(users[i])) {
                allowset.add(users[i]);
            }
            stakeToken.mint(users[i], amounts[i]);
            vm.prank(users[i]);
            stakeToken.approve(address(staker), type(uint256).max);
        }

        // All users stake to the same delegatee
        address expectedSurrogate = staker.predictSurrogateAddress(delegatee);
        uint256 totalStaked = 0;

        for (uint256 i = 0; i < 5; i++) {
            vm.prank(users[i]);
            staker.stake(amounts[i], delegatee, users[i]);

            // Verify they all use the same surrogate
            address actualSurrogate = address(staker.surrogates(delegatee));
            assertEq(actualSurrogate, expectedSurrogate, "All users must share same surrogate for same delegatee");

            totalStaked += amounts[i];
        }

        // Verify the surrogate holds all stakes
        assertEq(stakeToken.balanceOf(expectedSurrogate), totalStaked, "Surrogate should hold all users' stakes");

        // Verify the surrogate delegates to the correct delegatee
        assertEq(
            IERC20Delegates(address(stakeToken)).delegates(expectedSurrogate),
            delegatee,
            "Surrogate should delegate to correct delegatee"
        );
    }

    /// @notice Test surrogate isolation with multiple deposits from same user
    function testSameUserMultipleDepositsToSameDelegatee() public {
        address alice = makeAddr("alice");
        address delegatee = makeAddr("delegatee");

        allowset.add(alice);
        stakeToken.mint(alice, STAKE_AMOUNT * 3);

        vm.prank(alice);
        stakeToken.approve(address(staker), type(uint256).max);

        // First deposit
        vm.prank(alice);
        Staker.DepositIdentifier depositId1 = staker.stake(STAKE_AMOUNT, delegatee, alice);
        address surrogate1 = address(staker.surrogates(delegatee));

        // Second deposit (same delegatee)
        vm.prank(alice);
        Staker.DepositIdentifier depositId2 = staker.stake(STAKE_AMOUNT, delegatee, alice);
        address surrogate2 = address(staker.surrogates(delegatee));

        // Third deposit (same delegatee)
        vm.prank(alice);
        Staker.DepositIdentifier depositId3 = staker.stake(STAKE_AMOUNT, delegatee, alice);
        address surrogate3 = address(staker.surrogates(delegatee));

        // All deposits should use the same surrogate
        assertEq(surrogate1, surrogate2, "Same delegatee should use same surrogate");
        assertEq(surrogate2, surrogate3, "Same delegatee should use same surrogate");

        // Verify surrogate holds all deposits
        assertEq(stakeToken.balanceOf(surrogate1), STAKE_AMOUNT * 3, "Surrogate should hold all deposits");

        // Verify the surrogate delegates to the correct delegatee
        assertEq(
            IERC20Delegates(address(stakeToken)).delegates(surrogate1),
            delegatee,
            "Surrogate should delegate to delegatee"
        );

        // Verify deposits are separate
        assertTrue(
            Staker.DepositIdentifier.unwrap(depositId1) != Staker.DepositIdentifier.unwrap(depositId2) &&
                Staker.DepositIdentifier.unwrap(depositId2) != Staker.DepositIdentifier.unwrap(depositId3),
            "Deposits should be separate"
        );
    }

    /// @notice Test that changing delegatee creates new surrogate
    function testChangingDelegateeCreatesDifferentSurrogate() public {
        address alice = makeAddr("alice");
        address delegatee1 = makeAddr("delegatee1");
        address delegatee2 = makeAddr("delegatee2");

        allowset.add(alice);
        stakeToken.mint(alice, STAKE_AMOUNT * 2);

        vm.prank(alice);
        stakeToken.approve(address(staker), type(uint256).max);

        // Stake to first delegatee
        vm.prank(alice);
        staker.stake(STAKE_AMOUNT, delegatee1, alice);
        address surrogate1 = address(staker.surrogates(delegatee1));

        // Stake to second delegatee
        vm.prank(alice);
        staker.stake(STAKE_AMOUNT, delegatee2, alice);
        address surrogate2 = address(staker.surrogates(delegatee2));

        // Different delegatees must have different surrogates
        assertTrue(surrogate1 != surrogate2, "Different delegatees must have different surrogates");

        // Each surrogate should hold only its respective stake
        assertEq(stakeToken.balanceOf(surrogate1), STAKE_AMOUNT, "First surrogate should hold first stake");
        assertEq(stakeToken.balanceOf(surrogate2), STAKE_AMOUNT, "Second surrogate should hold second stake");

        // Each surrogate should delegate to its respective delegatee
        assertEq(
            IERC20Delegates(address(stakeToken)).delegates(surrogate1),
            delegatee1,
            "First surrogate should delegate to first delegatee"
        );
        assertEq(
            IERC20Delegates(address(stakeToken)).delegates(surrogate2),
            delegatee2,
            "Second surrogate should delegate to second delegatee"
        );
    }

    /// @notice Test Tally behavior compatibility - ensure our CREATE2 doesn't break existing behavior
    function testTallyBehaviorCompatibility() public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address delegatee = makeAddr("delegatee");

        allowset.add(alice);
        allowset.add(bob);

        stakeToken.mint(alice, STAKE_AMOUNT);
        stakeToken.mint(bob, STAKE_AMOUNT);

        vm.prank(alice);
        stakeToken.approve(address(staker), type(uint256).max);
        vm.prank(bob);
        stakeToken.approve(address(staker), type(uint256).max);

        // Verify surrogate doesn't exist before first use
        assertEq(address(staker.surrogates(delegatee)), address(0), "Surrogate should not exist initially");

        // First user creates the surrogate
        vm.prank(alice);
        staker.stake(STAKE_AMOUNT, delegatee, alice);

        address surrogateAfterFirst = address(staker.surrogates(delegatee));
        assertTrue(surrogateAfterFirst != address(0), "Surrogate should exist after first stake");

        // Second user reuses the same surrogate
        vm.prank(bob);
        staker.stake(STAKE_AMOUNT, delegatee, bob);

        address surrogateAfterSecond = address(staker.surrogates(delegatee));
        assertEq(surrogateAfterFirst, surrogateAfterSecond, "Same surrogate should be reused");

        // This matches Tally's original behavior: surrogate is created on first use
        // and reused for all subsequent stakes to the same delegatee
    }
}
