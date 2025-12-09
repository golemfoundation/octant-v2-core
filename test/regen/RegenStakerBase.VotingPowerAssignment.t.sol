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
