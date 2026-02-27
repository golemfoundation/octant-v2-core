// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { Staker } from "staker/Staker.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockEarningPowerCalculator } from "test/mocks/MockEarningPowerCalculator.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { OctantQFMechanism } from "src/mechanisms/mechanism/OctantQFMechanism.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";

/// @title RegenStakerBase Voting Power Assignment Test
/// @notice Proves that voting power in allocation mechanisms is assigned to the contributor (msg.sender),
///         not necessarily the deposit owner. This is INTENDED BEHAVIOR per REG-019.
/// @dev This test definitively shows:
///      - When owner contributes: owner gets voting power
///      - When claimer contributes: claimer gets voting power (NOT the owner)
///      This demonstrates the trust model where claimers can direct voting power using owner's rewards
contract RegenStakerBaseVotingPowerAssignmentTest is Test {
    RegenStaker public regenStaker;
    MockERC20Staking public token;
    MockEarningPowerCalculator public earningPowerCalculator;
    OctantQFMechanism public allocationMechanism;
    AddressSet public stakerAllowset;
    AddressSet public contributionAllowset;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public owner;
    uint256 private ownerPk;
    address public claimer;
    uint256 private claimerPk;
    address public delegatee = makeAddr("delegatee");

    uint256 public constant STAKE_AMOUNT = 100e18;
    uint256 public constant REWARD_AMOUNT = 1000e18;
    uint128 public constant REWARD_DURATION = 30 days;
    uint256 public constant CONTRIBUTION_AMOUNT = 10e18;

    Staker.DepositIdentifier public depositId;

    function setUp() public {
        // Create addresses with private keys for signature generation
        (owner, ownerPk) = makeAddrAndKey("owner");
        (claimer, claimerPk) = makeAddrAndKey("claimer");

        // Deploy infrastructure
        token = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();

        // Deploy real allocation mechanism
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        AllocationConfig memory cfg = AllocationConfig({
            asset: IERC20(address(token)),
            name: "TestAlloc",
            symbol: "TA",
            votingDelay: 1,
            votingPeriod: 30 days,
            quorumShares: 1,
            timelockDelay: 1,
            gracePeriod: 100,
            owner: admin
        });
        allocationMechanism = new OctantQFMechanism(
            address(impl),
            cfg,
            1,
            1,
            IAddressSet(address(0)), // contributionAllowset
            IAddressSet(address(0)), // contributionBlockset
            AccessMode.NONE
        );

        // Deploy and configure allowsets
        vm.startPrank(admin);
        stakerAllowset = new AddressSet();
        contributionAllowset = new AddressSet();
        allocationAllowset = new AddressSet();

        // Add both owner and claimer to necessary allowsets
        stakerAllowset.add(owner);
        stakerAllowset.add(claimer);
        contributionAllowset.add(owner);
        contributionAllowset.add(claimer);
        allocationAllowset.add(address(allocationMechanism));
        vm.stopPrank();

        // Deploy RegenStaker with same token for stake/reward
        vm.prank(admin);
        regenStaker = new RegenStaker(
            IERC20(address(token)), // rewardsToken
            token, // stakeToken
            earningPowerCalculator,
            0, // maxBumpTip
            admin,
            REWARD_DURATION,
            1e18, // minimumStakeAmount
            IAddressSet(address(stakerAllowset)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        // Fund and create deposit with claimer designation
        token.mint(owner, STAKE_AMOUNT);
        token.mint(address(regenStaker), REWARD_AMOUNT);

        vm.startPrank(owner);
        token.approve(address(regenStaker), STAKE_AMOUNT);
        depositId = regenStaker.stake(STAKE_AMOUNT, delegatee, claimer);
        vm.stopPrank();

        // Setup rewards
        vm.startPrank(admin);
        regenStaker.setRewardNotifier(admin, true);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();

        // Accumulate rewards
        vm.warp(block.timestamp + REWARD_DURATION / 4);
    }

    /// @notice Test that when OWNER contributes, OWNER gets voting power
    /// @dev This is the expected base case - contributor gets voting power
    function testVotingPower_OwnerContribute_OwnerGetsVotingPower() public {
        // Create signature for owner to contribute
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(allocationMechanism)).DOMAIN_SEPARATOR();
        uint256 nonce = TokenizedAllocationMechanism(address(allocationMechanism)).nonces(owner);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 typeHash = keccak256(
            bytes("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)")
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, owner, address(regenStaker), CONTRIBUTION_AMOUNT, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        // Owner contributes their own deposit's rewards
        vm.prank(owner);
        uint256 contributed = regenStaker.contribute(
            depositId,
            address(allocationMechanism),
            CONTRIBUTION_AMOUNT,
            deadline,
            v,
            r,
            s
        );

        // Verify contribution succeeded
        assertEq(contributed, CONTRIBUTION_AMOUNT, "Contribution amount mismatch");

        // CRITICAL ASSERTION: Owner gets the voting power
        uint256 ownerVotingPower = TokenizedAllocationMechanism(address(allocationMechanism)).votingPower(owner);
        assertEq(ownerVotingPower, CONTRIBUTION_AMOUNT, "Owner should have voting power equal to contribution");

        // CRITICAL ASSERTION: Claimer has NO voting power
        uint256 claimerVotingPower = TokenizedAllocationMechanism(address(allocationMechanism)).votingPower(claimer);
        assertEq(claimerVotingPower, 0, "Claimer should have no voting power when owner contributes");
    }

    /// @notice Test that when CLAIMER contributes, CLAIMER gets voting power (NOT owner)
    /// @dev This proves the intended behavior where voting power follows the contributor
    function testVotingPower_ClaimerContribute_ClaimerGetsVotingPower() public {
        // Claimer provides signature and receives voting power (claimer autonomy)
        // Defense-in-depth: deposit.owner must also be eligible (checked separately)

        // Create signature for claimer (who will receive voting power)
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(allocationMechanism)).DOMAIN_SEPARATOR();
        uint256 nonce = TokenizedAllocationMechanism(address(allocationMechanism)).nonces(claimer);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 typeHash = keccak256(
            bytes("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)")
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, claimer, address(regenStaker), CONTRIBUTION_AMOUNT, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimerPk, digest);

        // Claimer contributes owner's deposit's rewards
        vm.prank(claimer);
        uint256 contributed = regenStaker.contribute(
            depositId,
            address(allocationMechanism),
            CONTRIBUTION_AMOUNT,
            deadline,
            v,
            r,
            s
        );

        // Verify contribution succeeded
        assertEq(contributed, CONTRIBUTION_AMOUNT, "Contribution amount mismatch");

        // CRITICAL ASSERTION: Claimer gets the voting power (contributor principle)
        uint256 claimerVotingPower = TokenizedAllocationMechanism(address(allocationMechanism)).votingPower(claimer);
        assertEq(claimerVotingPower, CONTRIBUTION_AMOUNT, "Claimer should have voting power as contributor");

        // CRITICAL ASSERTION: Owner has NO voting power
        uint256 ownerVotingPower = TokenizedAllocationMechanism(address(allocationMechanism)).votingPower(owner);
        assertEq(ownerVotingPower, 0, "Owner should have no voting power when claimer contributes");
    }

    /// @notice Test that both owner and claimer contributions result in each getting their own voting power
    /// @dev Owner contributes → owner gets voting power, Claimer contributes → claimer gets voting power
    function testVotingPower_BothContribute_EachGetsOwnVotingPower() public {
        uint256 halfContribution = CONTRIBUTION_AMOUNT / 2;

        // First: Owner contributes half
        _contributeAsOwner(halfContribution);

        // Second: Claimer contributes the other half
        _contributeAsClaimer(halfContribution);

        // CRITICAL ASSERTION: Each contributor gets their own voting power
        uint256 ownerVotingPower = TokenizedAllocationMechanism(address(allocationMechanism)).votingPower(owner);
        uint256 claimerVotingPower = TokenizedAllocationMechanism(address(allocationMechanism)).votingPower(claimer);

        assertEq(ownerVotingPower, halfContribution, "Owner gets voting power from own contribution");
        assertEq(claimerVotingPower, halfContribution, "Claimer gets voting power from own contribution");
    }

    // Helper function to reduce stack depth
    function _contributeAsOwner(uint256 amount) internal {
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(allocationMechanism)).DOMAIN_SEPARATOR();
        uint256 nonce = TokenizedAllocationMechanism(address(allocationMechanism)).nonces(owner);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 typeHash = keccak256(
            bytes("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)")
        );
        bytes32 structHash = keccak256(abi.encode(typeHash, owner, address(regenStaker), amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPk, digest);

        vm.prank(owner);
        uint256 contributed = regenStaker.contribute(
            depositId,
            address(allocationMechanism),
            amount,
            deadline,
            v,
            r,
            s
        );
        assertEq(contributed, amount, "Owner contribution mismatch");
    }

    // Helper function to reduce stack depth
    function _contributeAsClaimer(uint256 amount) internal {
        // Claimer provides signature and receives voting power (claimer autonomy)
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(allocationMechanism)).DOMAIN_SEPARATOR();
        uint256 nonce = TokenizedAllocationMechanism(address(allocationMechanism)).nonces(claimer);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 typeHash = keccak256(
            bytes("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)")
        );
        bytes32 structHash = keccak256(abi.encode(typeHash, claimer, address(regenStaker), amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimerPk, digest);

        vm.prank(claimer);
        uint256 contributed = regenStaker.contribute(
            depositId,
            address(allocationMechanism),
            amount,
            deadline,
            v,
            r,
            s
        );
        assertEq(contributed, amount, "Claimer contribution mismatch");
    }

    /// @notice Test that attempting to contribute without proper signature fails
    /// @dev Ensures voting power assignment requires valid authorization
    function testVotingPower_WrongSignature_Reverts() public {
        // Test wrong signature by using an unrelated signer
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(allocationMechanism)).DOMAIN_SEPARATOR();
        uint256 nonce = TokenizedAllocationMechanism(address(allocationMechanism)).nonces(owner);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 typeHash = keccak256(
            bytes("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)")
        );
        // Sign for owner but with WRONG private key
        bytes32 structHash = keccak256(
            abi.encode(typeHash, owner, address(regenStaker), CONTRIBUTION_AMOUNT, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimerPk, digest); // Wrong signer!

        // Try to contribute with wrong signature - should fail
        vm.prank(claimer);
        vm.expectRevert(); // Will revert due to signature mismatch
        regenStaker.contribute(depositId, address(allocationMechanism), CONTRIBUTION_AMOUNT, deadline, v, r, s);

        // Verify no voting power was assigned
        uint256 ownerVotingPower = TokenizedAllocationMechanism(address(allocationMechanism)).votingPower(owner);
        assertEq(ownerVotingPower, 0, "Owner should have no voting power after failed contribution");
    }
}

// ---- Moved from RegenStakerWithAdvanceRewards.t.sol ----
contract RegenStakerWithAdvanceRewardsTest is Test {
    RegenStaker public regenStaker;
    MockERC20Staking public token;
    MockEarningPowerCalculator public earningPowerCalculator;
    OctantQFMechanism public allocationMechanism;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public owner;
    uint256 private ownerPk;
    address public claimer;
    address public delegatee = makeAddr("delegatee");
    address public stranger = makeAddr("stranger");

    uint256 public constant STAKE_AMOUNT = 1000e18;
    uint256 public constant REWARD_AMOUNT = 10_000e18;
    uint128 public constant REWARD_DURATION = 30 days;

    Staker.DepositIdentifier public depositId;

    function setUp() public {
        (owner, ownerPk) = makeAddrAndKey("owner");
        claimer = makeAddr("claimer");

        token = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();

        // Deploy a real OctantQFMechanism (same token for stake/reward)
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        AllocationConfig memory cfg = AllocationConfig({
            asset: IERC20(address(token)),
            name: "AdvanceTest",
            symbol: "ST",
            votingDelay: 1,
            votingPeriod: 30 days,
            quorumShares: 1,
            timelockDelay: 1,
            gracePeriod: 100,
            owner: admin
        });
        allocationMechanism = new OctantQFMechanism(
            address(impl),
            cfg,
            1,
            1,
            IAddressSet(address(0)), // contributionAllowset (open)
            IAddressSet(address(0)), // contributionBlockset (none)
            AccessMode.NONE
        );

        vm.startPrank(admin);
        allocationAllowset = new AddressSet();
        allocationAllowset.add(address(allocationMechanism));
        vm.stopPrank();

        vm.prank(admin);
        regenStaker = new RegenStaker(
            IERC20(address(token)), // rewardsToken (same as stake token)
            token,
            earningPowerCalculator,
            0, // maxBumpTip
            admin,
            REWARD_DURATION,
            1e18, // minimumStakeAmount
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        // Fund owner and stake
        token.mint(owner, STAKE_AMOUNT);
        token.mint(address(regenStaker), REWARD_AMOUNT);

        vm.startPrank(owner);
        token.approve(address(regenStaker), STAKE_AMOUNT);
        depositId = regenStaker.stake(STAKE_AMOUNT, delegatee, claimer);
        vm.stopPrank();

        // Schedule rewards
        vm.startPrank(admin);
        regenStaker.setRewardNotifier(admin, true);
        regenStaker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();
    }

    // =========================================================
    // Helpers
    // =========================================================

    /// @dev Returns deposit balance from the public tuple getter
    function _depositBalance(Staker.DepositIdentifier _depositId) internal view returns (uint96 bal) {
        (bal, , , , , , ) = regenStaker.deposits(_depositId);
    }

    /// @dev Returns deposit earning power from the public tuple getter

    function _contributeSignatureFor(
        address _contributor,
        uint256 _contributorPk,
        uint256 _amount
    ) internal returns (uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(allocationMechanism)).DOMAIN_SEPARATOR();
        uint256 nonce = TokenizedAllocationMechanism(address(allocationMechanism)).nonces(_contributor);
        deadline = block.timestamp + 1 days;

        bytes32 typeHash = keccak256(
            bytes("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)")
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, _contributor, address(regenStaker), _amount, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(_contributorPk, digest);
    }

    // =========================================================
    // stakeWithAdvanceReward
    // =========================================================

    function test_stakeWithAdvanceReward_stakesAndEarmarksInOneCall() public {
        address bob = makeAddr("bob");
        uint256 bobStakeAmount = 200e18;
        uint256 advanceAmount = (bobStakeAmount * 5) / 100;

        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            bobStakeAmount,
            delegatee,
            bob,
            advanceAmount,
            advanceAmount
        );
        vm.stopPrank();

        (uint96 balance, address ownerAddr, , address delegateeAddr, address claimerAddr, , ) = regenStaker.deposits(
            bobDepositId
        );
        assertEq(ownerAddr, bob, "owner mismatch");
        assertEq(delegateeAddr, delegatee, "delegatee mismatch");
        assertEq(claimerAddr, bob, "claimer mismatch");
        assertEq(balance, bobStakeAmount - advanceAmount, "deposit balance should be reduced by earmark");

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(bobDepositId);
        assertEq(lockEnd, block.timestamp + 5 * 30 days, "lock end mismatch");
        assertEq(token.balanceOf(bob), 0, "advance should stay in contract, not go to user");
        assertEq(regenStaker.unclaimedReward(bobDepositId), advanceAmount, "advance should be credited as unclaimed");
        assertEq(regenStaker.advanceDebt(bobDepositId), advanceAmount, "advance debt should match credit");
    }

    function test_stakeWithAdvanceReward_withExplicitClaimer() public {
        address bob = makeAddr("bob2");
        uint256 bobStakeAmount = 120e18;

        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        uint256 advanceAmount = (bobStakeAmount * 2) / 100;
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            bobStakeAmount,
            delegatee,
            claimer,
            advanceAmount,
            advanceAmount
        );
        vm.stopPrank();

        (, address ownerAddr, , , address claimerAddr, , ) = regenStaker.deposits(bobDepositId);
        assertEq(ownerAddr, bob, "owner mismatch");
        assertEq(claimerAddr, claimer, "explicit claimer mismatch");
    }

    function test_stakeWithAdvanceReward_usesCeilDivisionForTinyAdvanceLock() public {
        uint256 smallStakeAmount = 20e18;
        uint256 tinyAdvance = 1;
        uint256 lockDurationPerPercent = 30 days;
        token.mint(owner, smallStakeAmount);

        uint256 expectedDuration = ((tinyAdvance * lockDurationPerPercent * 100) - 1) / smallStakeAmount + 1;
        assertEq(expectedDuration, 1, "expected tiny advance lock duration should be 1 second");

        vm.startPrank(owner);
        token.approve(address(regenStaker), smallStakeAmount);
        Staker.DepositIdentifier tinyDepositId = regenStaker.stakeWithAdvanceReward(
            smallStakeAmount,
            delegatee,
            owner,
            tinyAdvance,
            tinyAdvance
        );
        vm.stopPrank();

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(tinyDepositId);
        assertEq(lockEnd, block.timestamp + expectedDuration, "lock end should use ceil division");
    }

    function test_stakeWithAdvanceReward_revertsInvalidAdvanceAmount() public {
        address bob = makeAddr("bob3");
        uint256 bobStakeAmount = 120e18;
        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.ZeroOperation.selector));
        regenStaker.stakeWithAdvanceReward(bobStakeAmount, delegatee, claimer, 0, 0);
        uint256 tooLargeAdvance = (bobStakeAmount * 5) / 100 + 1;
        vm.expectRevert(
            abi.encodeWithSelector(RegenStakerBase.CantAfford.selector, tooLargeAdvance, bobStakeAmount / 20)
        );
        regenStaker.stakeWithAdvanceReward(bobStakeAmount, delegatee, claimer, tooLargeAdvance, 0);
        vm.stopPrank();
    }

    function test_stakeWithAdvanceReward_sameTokenRevertsWhenMinOutTooHigh() public {
        address bob = makeAddr("bob4");
        uint256 bobStakeAmount = 120e18;
        uint256 advanceAmount = (bobStakeAmount * 2) / 100;
        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.CantAfford.selector, advanceAmount + 1, advanceAmount));
        regenStaker.stakeWithAdvanceReward(bobStakeAmount, delegatee, claimer, advanceAmount, advanceAmount + 1);
        vm.stopPrank();
    }

    function test_setAdvanceSwapConfig_adminOnlyAndStores() public {
        address router = makeAddr("router");
        uint24 fee = 500;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Staker.Staker__Unauthorized.selector, bytes32("not admin"), owner));
        regenStaker.setAdvanceSwapConfig(router, fee);

        vm.prank(admin);
        regenStaker.setAdvanceSwapConfig(router, fee);
    }

    function test_withdraw_revertsDuringLock_andAllowedAfterExpiry() public {
        address bob = makeAddr("bob5");
        uint256 bobStakeAmount = 200e18;
        uint256 advanceAmount = (bobStakeAmount * 5) / 100;
        token.mint(bob, bobStakeAmount);

        vm.startPrank(bob);
        token.approve(address(regenStaker), bobStakeAmount);
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            bobStakeAmount,
            delegatee,
            bob,
            advanceAmount,
            advanceAmount
        );
        (uint96 balance, , , , , , ) = regenStaker.deposits(bobDepositId);
        uint64 lockEnd = regenStaker.advanceRewardLockEnd(bobDepositId);

        vm.expectRevert(abi.encodeWithSelector(RegenStakerBase.CommitmentLockActive.selector, bobDepositId, lockEnd));
        regenStaker.withdraw(bobDepositId, balance);

        vm.warp(lockEnd + 1);
        regenStaker.withdraw(bobDepositId, balance);
        vm.stopPrank();

        (uint96 remainingBalance, , , , , , ) = regenStaker.deposits(bobDepositId);
        assertEq(remainingBalance, 0, "full withdraw should clear balance");
        uint64 currentLockEnd = regenStaker.advanceRewardLockEnd(bobDepositId);
        assertEq(currentLockEnd, 0, "lock should clear after lock expiry and withdraw");
    }

    // =========================================================
    // contribute (reward-only, REWARD_TOKEN path)
    // =========================================================

    function test_contribute_usesRewardsOnly_whenAvailable() public {
        vm.warp(block.timestamp + REWARD_DURATION / 4);

        uint256 rewardAvailable = regenStaker.unclaimedReward(depositId);
        uint256 rewardToContribute = rewardAvailable / 2;
        require(rewardToContribute > 0, "reward-to-contribute should be > 0");

        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(owner, ownerPk, rewardToContribute);

        uint256 mechanismBalanceBefore = token.balanceOf(address(allocationMechanism));
        uint96 balanceBefore = _depositBalance(depositId);
        uint256 totalStakedBefore = regenStaker.totalStaked();

        vm.prank(owner);
        uint256 contributed = regenStaker.contribute(
            depositId,
            address(allocationMechanism),
            rewardToContribute,
            deadline,
            v,
            r,
            s
        );

        assertEq(contributed, rewardToContribute, "contributed amount mismatch");
        assertEq(
            token.balanceOf(address(allocationMechanism)) - mechanismBalanceBefore,
            rewardToContribute,
            "all contribution should hit mechanism"
        );
        assertEq(_depositBalance(depositId), balanceBefore, "deposit balance should not reduce");
        assertEq(regenStaker.totalStaked(), totalStakedBefore, "total staked should not change");
    }

    function test_contribute_rewardOnlyLegStillWorksDuringActiveLock() public {
        uint256 ownerStakeAmount = 200e18;
        token.mint(owner, ownerStakeAmount);

        vm.startPrank(owner);
        token.approve(address(regenStaker), ownerStakeAmount);
        Staker.DepositIdentifier lockedDepositId = regenStaker.stakeWithAdvanceReward(
            ownerStakeAmount,
            delegatee,
            owner,
            (ownerStakeAmount * 5) / 100,
            (ownerStakeAmount * 5) / 100
        );
        vm.stopPrank();

        vm.warp(block.timestamp + REWARD_DURATION / 4);

        uint64 lockEnd = regenStaker.advanceRewardLockEnd(lockedDepositId);

        uint256 rewardAvailable = regenStaker.unclaimedReward(lockedDepositId);
        uint256 rewardToContribute = rewardAvailable / 2;
        require(rewardToContribute > 0, "reward-to-contribute should be > 0");

        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(owner, ownerPk, rewardToContribute);

        uint256 mechanismBalanceBefore = token.balanceOf(address(allocationMechanism));
        vm.prank(owner);
        uint256 contributed = regenStaker.contribute(
            lockedDepositId,
            address(allocationMechanism),
            rewardToContribute,
            deadline,
            v,
            r,
            s
        );

        assertEq(contributed, rewardToContribute);
        assertEq(token.balanceOf(address(allocationMechanism)) - mechanismBalanceBefore, rewardToContribute);
        // contribute() does not touch lock metadata
        uint64 currentLockEnd = regenStaker.advanceRewardLockEnd(lockedDepositId);
        assertEq(currentLockEnd, lockEnd);
    }

    function test_contribute_zeroAmountStillAllowedForContributionSignup() public {
        vm.warp(block.timestamp + REWARD_DURATION / 4);
        uint256 rewardAvailable = regenStaker.unclaimedReward(depositId);
        require(rewardAvailable > 0, "reward should be available");

        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(owner, ownerPk, 0);

        vm.prank(owner);
        uint256 contributed = regenStaker.contribute(depositId, address(allocationMechanism), 0, deadline, v, r, s);
        assertEq(contributed, 0, "zero amount should still be a valid signup path");
    }

    // =========================================================
    // Advance debt tests
    // =========================================================

    function test_advanceDebt_deductedFromClaimReward() public {
        // Stake with advance to create a deposit with debt
        address bob = makeAddr("bob-debt-claim");
        uint256 stakeAmount = 200e18;
        uint256 advanceAmount = (stakeAmount * 5) / 100; // 10e18

        token.mint(bob, stakeAmount);
        vm.startPrank(bob);
        token.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            stakeAmount,
            delegatee,
            bob,
            advanceAmount,
            advanceAmount
        );
        vm.stopPrank();

        assertEq(regenStaker.advanceDebt(bobDepositId), advanceAmount, "debt should be set");

        // Warp to accrue rewards > debt
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        uint256 unclaimedBefore = regenStaker.unclaimedReward(bobDepositId);
        require(unclaimedBefore > advanceAmount, "must accrue more than debt for this test");

        uint256 bobBalBefore = token.balanceOf(bob);

        vm.prank(bob);
        uint256 claimed = regenStaker.claimReward(bobDepositId);

        // Payout should be reduced by the full debt amount
        // unclaimed includes advance credit + accrued rewards; debt is deducted first
        // So: payout = unclaimedBefore - advanceAmount
        assertEq(claimed, unclaimedBefore - advanceAmount, "payout should be reduced by debt");
        assertEq(token.balanceOf(bob) - bobBalBefore, claimed, "balance should increase by claimed amount");
        assertEq(regenStaker.advanceDebt(bobDepositId), 0, "debt should be fully repaid");
    }

    function test_advanceDebt_deductedFromCompoundRewards() public {
        // Stake with advance to create a deposit with debt
        address bob = makeAddr("bob-debt-compound");
        uint256 stakeAmount = 200e18;
        uint256 advanceAmount = (stakeAmount * 5) / 100; // 10e18

        token.mint(bob, stakeAmount);
        vm.startPrank(bob);
        token.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            stakeAmount,
            delegatee,
            bob,
            advanceAmount,
            advanceAmount
        );
        vm.stopPrank();

        // Warp to accrue rewards > debt
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        uint256 unclaimedBefore = regenStaker.unclaimedReward(bobDepositId);
        require(unclaimedBefore > advanceAmount, "must accrue more than debt for this test");

        (uint96 balBefore, , , , , , ) = regenStaker.deposits(bobDepositId);

        vm.prank(bob);
        uint256 compounded = regenStaker.compoundRewards(bobDepositId);

        // Compound amount should be reduced by the full debt
        assertEq(compounded, unclaimedBefore - advanceAmount, "compounded should be reduced by debt");
        (uint96 balAfter, , , , , , ) = regenStaker.deposits(bobDepositId);
        assertEq(balAfter, balBefore + compounded, "balance should increase by compounded amount");
        assertEq(regenStaker.advanceDebt(bobDepositId), 0, "debt should be fully repaid");
    }

    function test_advanceDebt_notDeductedFromContribute() public {
        // Stake with advance to create deposit with debt + credit
        address bob;
        uint256 bobPk;
        (bob, bobPk) = makeAddrAndKey("bob-debt-contribute");
        uint256 stakeAmount = 200e18;
        uint256 advanceAmount = (stakeAmount * 5) / 100; // 10e18

        token.mint(bob, stakeAmount);
        vm.startPrank(bob);
        token.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            stakeAmount,
            delegatee,
            bob,
            advanceAmount,
            advanceAmount
        );
        vm.stopPrank();

        // Contribute the full advance credit immediately (the whole point of the design)
        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(bob, bobPk, advanceAmount);

        uint256 mechanismBalBefore = token.balanceOf(address(allocationMechanism));

        vm.prank(bob);
        uint256 contributed = regenStaker.contribute(
            bobDepositId,
            address(allocationMechanism),
            advanceAmount,
            deadline,
            v,
            r,
            s
        );

        assertEq(contributed, advanceAmount, "full advance should be contributable");
        assertEq(
            token.balanceOf(address(allocationMechanism)) - mechanismBalBefore,
            advanceAmount,
            "mechanism should receive full advance"
        );
        // Debt persists — it is NOT affected by contribute
        assertEq(regenStaker.advanceDebt(bobDepositId), advanceAmount, "debt should persist after contribute");
    }

    function test_advanceDebt_repaidGradually() public {
        // Stake with advance
        address bob = makeAddr("bob-gradual");
        uint256 stakeAmount = 200e18;
        uint256 advanceAmount = (stakeAmount * 5) / 100; // 10e18

        token.mint(bob, stakeAmount);
        vm.startPrank(bob);
        token.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            stakeAmount,
            delegatee,
            bob,
            advanceAmount,
            advanceAmount
        );
        vm.stopPrank();

        // Warp a small amount — accrue less than debt
        vm.warp(block.timestamp + REWARD_DURATION / 20);

        uint256 unclaimedBefore = regenStaker.unclaimedReward(bobDepositId);
        // unclaimed includes advance credit + small accrued rewards
        // If total unclaimed < debt, all would be consumed. But unclaimed includes the advance credit itself.
        // After advance: checkpoint = advanceAmount. Then some rewards accrue on top.
        // debt = advanceAmount. So unclaimed = advanceAmount + accrued.
        // After debt deduction: checkpoint -= advanceAmount → remaining = accrued.
        // The first claim should fully repay debt and give accrued rewards as payout.
        require(unclaimedBefore > advanceAmount, "advance credit + accrued should exceed debt");

        vm.prank(bob);
        uint256 claimed1 = regenStaker.claimReward(bobDepositId);

        assertEq(claimed1, unclaimedBefore - advanceAmount, "first claim should pay out earned minus debt");
        assertEq(regenStaker.advanceDebt(bobDepositId), 0, "debt should be fully repaid after first claim");

        // Second claim — no debt, normal operation
        vm.warp(block.timestamp + REWARD_DURATION / 10);
        uint256 unclaimed2 = regenStaker.unclaimedReward(bobDepositId);

        vm.prank(bob);
        uint256 claimed2 = regenStaker.claimReward(bobDepositId);

        assertEq(claimed2, unclaimed2, "second claim should not have debt deduction");
    }

    function test_advanceDebt_fullCycleContributeThenClaim() public {
        // Full cycle: stake with advance → contribute advance → earn rewards → claim (reduced by debt)
        address bob;
        uint256 bobPk;
        (bob, bobPk) = makeAddrAndKey("bob-full-cycle");
        uint256 stakeAmount = 200e18;
        uint256 advanceAmount = (stakeAmount * 5) / 100; // 10e18

        token.mint(bob, stakeAmount);
        vm.startPrank(bob);
        token.approve(address(regenStaker), stakeAmount);
        Staker.DepositIdentifier bobDepositId = regenStaker.stakeWithAdvanceReward(
            stakeAmount,
            delegatee,
            bob,
            advanceAmount,
            advanceAmount
        );
        vm.stopPrank();

        // Step 1: Contribute the full advance credit immediately
        {
            (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _contributeSignatureFor(bob, bobPk, advanceAmount);
            vm.prank(bob);
            regenStaker.contribute(bobDepositId, address(allocationMechanism), advanceAmount, deadline, v, r, s);
        }

        // Verify: unclaimed is now 0 (contributed), debt is still full
        assertEq(regenStaker.unclaimedReward(bobDepositId), 0, "unclaimed should be zero after contributing all");
        assertEq(regenStaker.advanceDebt(bobDepositId), advanceAmount, "debt should persist after contribute");

        // Step 2: Earn rewards
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        uint256 unclaimed = regenStaker.unclaimedReward(bobDepositId);
        require(unclaimed > advanceAmount, "should have earned more than debt");

        // Step 3: Claim — debt should be deducted
        uint256 bobBalBefore = token.balanceOf(bob);

        vm.prank(bob);
        uint256 claimed = regenStaker.claimReward(bobDepositId);

        assertEq(claimed, unclaimed - advanceAmount, "payout should be earned minus debt");
        assertEq(token.balanceOf(bob) - bobBalBefore, claimed, "balance should reflect reduced payout");
        assertEq(regenStaker.advanceDebt(bobDepositId), 0, "debt should be fully repaid");
    }
}
