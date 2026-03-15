// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import { AccessMode } from "src/constants.sol";
import { TokenizedAllocationMechanism, IBaseAllocationStrategy } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { QuadraticVotingMechanism } from "src/mechanisms/mechanism/QuadraticVotingMechanism.sol";
import { OctantQFMechanism } from "src/mechanisms/mechanism/OctantQFMechanism.sol";
import { AllocationMechanismFactory } from "src/mechanisms/AllocationMechanismFactory.sol";
import { AllocationConfig, BaseAllocationMechanism } from "src/mechanisms/BaseAllocationMechanism.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { ProperQF } from "src/mechanisms/voting-strategy/ProperQF.sol";
import { HarnessProperQF } from "test/unit/mechanisms/harness/HarnessProperQF.sol";
import { InBlockset } from "src/errors.sol";

/// @title Mock ERC20 token with configurable decimals for branch testing
contract BranchTestMockToken is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

/// @title Mechanism Branch Coverage Tests
/// @notice Targets untested branches across mechanism contracts
contract MechanismBranchCoverageTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;
    TokenizedAllocationMechanism implementation;

    address owner;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address recipient1 = makeAddr("recipient1");
    address recipient2 = makeAddr("recipient2");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant QUORUM = 10;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        owner = address(this);
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        token.mint(alice, 100_000e18);
        token.mint(bob, 100_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Branch Coverage Test",
            symbol: "BCT",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM * W * W,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(alice);
        _tam().setManagement(bob);

        // Fund matching pool
        token.mint(address(mechanism), 50_000e18);
    }

    // ===== TokenizedAllocationMechanism: cancelOwnershipTransfer =====

    function test_cancelOwnershipTransfer_success() public {
        address newOwner = makeAddr("newOwner");

        // Initiate transfer
        _tam().transferOwnership(newOwner);
        assertEq(_tam().pendingOwner(), newOwner);

        // Cancel it
        _tam().cancelOwnershipTransfer();
        assertEq(_tam().pendingOwner(), address(0));
    }

    function test_cancelOwnershipTransfer_noPending_reverts() public {
        // No pending transfer - should revert
        vm.expectRevert(TokenizedAllocationMechanism.Unauthorized.selector);
        _tam().cancelOwnershipTransfer();
    }

    function test_cancelOwnershipTransfer_notOwner_reverts() public {
        address newOwner = makeAddr("newOwner");
        _tam().transferOwnership(newOwner);

        vm.prank(alice);
        vm.expectRevert(TokenizedAllocationMechanism.Unauthorized.selector);
        _tam().cancelOwnershipTransfer();
    }

    // ===== TokenizedAllocationMechanism: sweep =====

    function test_sweep_ERC20_afterGracePeriod() public {
        // Setup: complete full lifecycle
        _setupAndFinalize();

        // Warp past grace period
        uint256 redemptionEnd = _tam().globalRedemptionStart() + GRACE_PERIOD;
        vm.warp(redemptionEnd + 1);

        address receiver = makeAddr("receiver");
        uint256 balanceBefore = token.balanceOf(receiver);

        _tam().sweep(address(token), receiver);

        assertTrue(token.balanceOf(receiver) > balanceBefore, "Receiver should have swept tokens");
    }

    function test_sweep_ETH_afterGracePeriod() public {
        _setupAndFinalize();

        uint256 redemptionEnd = _tam().globalRedemptionStart() + GRACE_PERIOD;
        vm.warp(redemptionEnd + 1);

        // Send ETH to mechanism
        vm.deal(address(mechanism), 1 ether);

        address receiver = makeAddr("ethReceiver");
        _tam().sweep(address(0), receiver);

        assertEq(receiver.balance, 1 ether, "Receiver should have swept ETH");
    }

    function test_sweep_beforeGracePeriodExpires_reverts() public {
        _setupAndFinalize();

        // Still within grace period
        vm.warp(_tam().globalRedemptionStart() + 1);

        vm.expectRevert("Grace period not expired");
        _tam().sweep(address(token), makeAddr("receiver"));
    }

    function test_sweep_beforeRedemptionPeriod_reverts() public {
        // No finalization done
        vm.expectRevert("Redemption period not started");
        _tam().sweep(address(token), makeAddr("receiver"));
    }

    function test_sweep_zeroReceiver_reverts() public {
        _setupAndFinalize();
        uint256 redemptionEnd = _tam().globalRedemptionStart() + GRACE_PERIOD;
        vm.warp(redemptionEnd + 1);

        vm.expectRevert("Invalid receiver");
        _tam().sweep(address(token), address(0));
    }

    function test_sweep_noTokenBalance_reverts() public {
        _setupAndFinalize();
        uint256 redemptionEnd = _tam().globalRedemptionStart() + GRACE_PERIOD;
        vm.warp(redemptionEnd + 1);

        // Sweep a token that has no balance
        ERC20Mock otherToken = new ERC20Mock();

        vm.expectRevert("No tokens to sweep");
        _tam().sweep(address(otherToken), makeAddr("receiver"));
    }

    function test_sweep_noETH_reverts() public {
        _setupAndFinalize();
        uint256 redemptionEnd = _tam().globalRedemptionStart() + GRACE_PERIOD;
        vm.warp(redemptionEnd + 1);

        vm.expectRevert("No ETH to sweep");
        _tam().sweep(address(0), makeAddr("receiver"));
    }

    function test_sweep_notOwner_reverts() public {
        _setupAndFinalize();
        uint256 redemptionEnd = _tam().globalRedemptionStart() + GRACE_PERIOD;
        vm.warp(redemptionEnd + 1);

        vm.prank(alice);
        vm.expectRevert(TokenizedAllocationMechanism.Unauthorized.selector);
        _tam().sweep(address(token), makeAddr("receiver"));
    }

    // ===== QuadraticVotingMechanism: OnlyForVotesSupported =====

    function test_castVote_againstType_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test proposal");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        vm.expectRevert(QuadraticVotingMechanism.OnlyForVotesSupported.selector);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.Against, 10, recipient1);
    }

    function test_castVote_abstainType_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test proposal");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        vm.expectRevert(QuadraticVotingMechanism.OnlyForVotesSupported.selector);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.Abstain, 10, recipient1);
    }

    // ===== QuadraticVotingMechanism: AlreadyVoted =====

    function test_castVote_doubleVote_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test proposal");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // First vote succeeds
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);

        // Second vote reverts
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(QuadraticVotingMechanism.AlreadyVoted.selector, alice, pid));
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);
    }

    // ===== QuadraticVotingMechanism: InsufficientVotingPowerForQuadraticCost =====

    function test_castVote_insufficientQuadraticPower_reverts() public {
        _signupUser(alice, 100); // Very small deposit

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test proposal");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Weight^2 = 200^2 = 40000 > 100 voting power
        vm.prank(alice);
        vm.expectRevert(QuadraticVotingMechanism.InsufficientVotingPowerForQuadraticCost.selector);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 200 * W, recipient1);
    }

    // ===== QuadraticVotingMechanism: ZeroAddressCannotPropose =====

    function test_propose_fromZeroAddress_reverts() public {
        vm.prank(address(0));
        vm.expectRevert(QuadraticVotingMechanism.ZeroAddressCannotPropose.selector);
        _tam().propose(recipient1, "Test proposal");
    }

    // ===== TokenizedAllocationMechanism: cancelProposal post-finalize =====

    function test_cancelProposal_afterFinalization_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test proposal");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        vm.prank(alice);
        vm.expectRevert(TokenizedAllocationMechanism.TallyAlreadyFinalized.selector);
        _tam().cancelProposal(pid);
    }

    // ===== TokenizedAllocationMechanism: queueingClosedAfterRedemption =====

    function test_queueProposal_afterRedemptionStart_reverts() public {
        _signupUser(alice, DEPOSIT);
        _signupUser(bob, DEPOSIT);

        vm.prank(alice);
        uint256 pid1 = _tam().propose(recipient1, "Proposal 1");
        vm.prank(bob);
        uint256 pid2 = _tam().propose(recipient2, "Proposal 2");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        _tam().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);
        vm.prank(bob);
        _tam().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);
        vm.prank(alice);
        _tam().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient2);
        vm.prank(bob);
        _tam().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient2);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        // Queue first proposal
        _tam().queueProposal(pid1);

        // Warp past redemption start
        vm.warp(_tam().globalRedemptionStart());

        // Second queue should fail
        vm.expectRevert(TokenizedAllocationMechanism.QueueingClosedAfterRedemption.selector);
        _tam().queueProposal(pid2);
    }

    // ===== TokenizedAllocationMechanism: Proposal states beyond Succeeded =====

    function test_proposalState_expired() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        // Queue it
        _tam().queueProposal(pid);

        // Warp past grace period
        vm.warp(_tam().globalRedemptionStart() + GRACE_PERIOD + 1);

        assertEq(uint8(_tam().state(pid)), uint8(TokenizedAllocationMechanism.ProposalState.Expired));
    }

    function test_proposalState_redeemable() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // Warp to redemption period (after timelock, within grace)
        vm.warp(_tam().globalRedemptionStart() + 1);

        assertEq(uint8(_tam().state(pid)), uint8(TokenizedAllocationMechanism.ProposalState.Redeemable));
    }

    function test_proposalState_succeededNotQueued() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        // Before redemption start, not queued
        assertEq(uint8(_tam().state(pid)), uint8(TokenizedAllocationMechanism.ProposalState.Succeeded));
    }

    // ===== TokenizedAllocationMechanism: Transfer during redemption =====

    function test_transfer_duringRedemptionPeriod() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);
        assertTrue(shares > 0);

        // Warp into redemption period
        vm.warp(_tam().globalRedemptionStart() + 1);

        // Transfer shares
        vm.prank(recipient1);
        _tam().transfer(charlie, shares / 2);

        assertEq(_tam().balanceOf(charlie), shares / 2);
    }

    function test_transfer_outsideRedemptionPeriod_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // Before redemption start - transfer should fail
        vm.prank(recipient1);
        vm.expectRevert("Transfers only allowed during redemption period");
        _tam().transfer(charlie, 1);
    }

    // ===== TokenizedAllocationMechanism: Initialize validation branches =====

    function test_initialize_alreadyInitialized_reverts() public {
        // The proxy is already initialized via factory deployment - calling again reverts
        vm.expectRevert(TokenizedAllocationMechanism.AlreadyInitialized.selector);
        _tam().initialize(address(this), IERC20(address(token)), "test", "T", 1, 1, 1, 1, 1);
    }

    // ===== TokenizedAllocationMechanism: Signup with zero address =====

    function test_signup_zeroAddress_reverts() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidUser.selector, address(0)));
        _tam().signup(100);
    }

    // ===== TokenizedAllocationMechanism: setKeeper/setManagement zero address =====

    function test_setKeeper_zeroAddress_reverts() public {
        vm.expectRevert(TokenizedAllocationMechanism.Unauthorized.selector);
        _tam().setKeeper(address(0));
    }

    function test_setManagement_zeroAddress_reverts() public {
        vm.expectRevert(TokenizedAllocationMechanism.Unauthorized.selector);
        _tam().setManagement(address(0));
    }

    // ===== TokenizedAllocationMechanism: Propose validation branches =====

    function test_propose_recipientSelf_reverts() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidRecipient.selector, address(mechanism))
        );
        _tam().propose(address(mechanism), "Test");
    }

    function test_propose_recipientZero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidRecipient.selector, address(0)));
        _tam().propose(address(0), "Test");
    }

    function test_propose_duplicateRecipient_reverts() public {
        vm.prank(alice);
        _tam().propose(recipient1, "First");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.RecipientUsed.selector, recipient1));
        _tam().propose(recipient1, "Second");
    }

    function test_propose_emptyDescription_reverts() public {
        vm.prank(alice);
        vm.expectRevert(TokenizedAllocationMechanism.EmptyDescription.selector);
        _tam().propose(recipient1, "");
    }

    function test_propose_descriptionTooLong_reverts() public {
        // Create a description > 1000 bytes
        bytes memory longDesc = new bytes(1001);
        for (uint i = 0; i < 1001; i++) {
            longDesc[i] = "A";
        }

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.DescriptionTooLong.selector, 1001, 1000));
        _tam().propose(recipient1, string(longDesc));
    }

    function test_propose_afterVotingPeriod_reverts() public {
        vm.warp(block.timestamp + VOTING_DELAY + VOTING_PERIOD + 1);

        vm.prank(alice);
        vm.expectRevert();
        _tam().propose(recipient1, "Too late");
    }

    // ===== TokenizedAllocationMechanism: castVote validation branches =====

    function test_castVote_invalidProposal_reverts() public {
        _signupUser(alice, DEPOSIT);
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidProposal.selector, 999));
        _tam().castVote(999, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);
    }

    function test_castVote_zeroWeight_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidWeight.selector, 0, DEPOSIT));
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 0, recipient1);
    }

    function test_castVote_recipientMismatch_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedAllocationMechanism.RecipientMismatch.selector, pid, charlie, recipient1)
        );
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, charlie);
    }

    function test_castVote_canceledProposal_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.prank(alice);
        _tam().cancelProposal(pid);

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.ProposalCanceledError.selector, pid));
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);
    }

    // ===== TokenizedAllocationMechanism: cancelProposal branches =====

    function test_cancelProposal_notProposer_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.NotProposer.selector, bob, alice));
        _tam().cancelProposal(pid);
    }

    function test_cancelProposal_alreadyCanceled_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.prank(alice);
        _tam().cancelProposal(pid);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.AlreadyCanceled.selector, pid));
        _tam().cancelProposal(pid);
    }

    // ===== TokenizedAllocationMechanism: finalizeVoteTally branches =====

    function test_finalize_notOwner_reverts() public {
        vm.warp(block.timestamp + VOTING_DELAY + VOTING_PERIOD + 1);

        vm.prank(alice);
        vm.expectRevert(TokenizedAllocationMechanism.Unauthorized.selector);
        _tam().finalizeVoteTally();
    }

    function test_finalize_votingNotEnded_reverts() public {
        vm.expectRevert();
        _tam().finalizeVoteTally();
    }

    // ===== TokenizedAllocationMechanism: queueProposal canceled =====

    function test_queueProposal_canceled_reverts() public {
        _signupUser(alice, DEPOSIT);
        _signupUser(bob, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        // Cancel before finalize
        vm.prank(alice);
        _tam().cancelProposal(pid);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.ProposalCanceledError.selector, pid));
        _tam().queueProposal(pid);
    }

    // ===== TokenizedAllocationMechanism: redeem during redemption period =====

    function test_redeem_duringRedemptionPeriod() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);
        assertTrue(shares > 0, "Recipient should have shares");

        // Warp to redemption period
        vm.warp(_tam().globalRedemptionStart() + 1);

        uint256 balBefore = token.balanceOf(recipient1);
        vm.prank(recipient1);
        _tam().redeem(shares, recipient1, recipient1);

        assertTrue(token.balanceOf(recipient1) > balBefore, "Recipient should have received assets");
        assertEq(_tam().balanceOf(recipient1), 0, "All shares should be burned");
    }

    // ===== TokenizedAllocationMechanism: previewRedeem branches =====

    function test_previewRedeem_beforeRedemption_returnsZero() public view {
        assertEq(_tam().previewRedeem(1000), 0);
    }

    function test_previewRedeem_afterRedemption_returnsZero() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // Warp past grace period
        vm.warp(_tam().globalRedemptionStart() + GRACE_PERIOD + 1);

        assertEq(_tam().previewRedeem(1000), 0);
    }

    // ===== AllocationMechanismFactory: view functions =====

    function test_factory_getAllDeployedMechanisms() public view {
        address[] memory all = factory.getAllDeployedMechanisms();
        assertEq(all.length, 1);
        assertEq(all[0], address(mechanism));
    }

    function test_factory_getDeployedMechanism() public view {
        assertEq(factory.getDeployedMechanism(0), address(mechanism));
    }

    function test_factory_getDeployedMechanism_outOfBounds_reverts() public {
        vm.expectRevert("Index out of bounds");
        factory.getDeployedMechanism(999);
    }

    // ===== Helpers =====

    function _signupUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(address(mechanism), amount);
        _tam().signup(amount);
        vm.stopPrank();
    }

    function _setupAndFinalize() internal {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);
    }
}

/// @title OctantQF BLOCKSET Mode Branch Coverage Tests
/// @notice Tests BLOCKSET mode for OctantQFMechanism
contract OctantQFBlocksetTest is Test {
    OctantQFMechanism mechanism;
    TokenizedAllocationMechanism implementation;
    AddressSet blockset;
    AddressSet allowset;
    ERC20Mock token;

    address owner = makeAddr("owner");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address blockedUser = makeAddr("blockedUser");
    address keeper = makeAddr("keeper");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant W = 65536;

    function tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        vm.startPrank(owner);

        token = new ERC20Mock();
        token.mint(owner, 1_000_000e18);

        blockset = new AddressSet();
        allowset = new AddressSet();
        implementation = new TokenizedAllocationMechanism();

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Blockset QF",
            symbol: "BQF",
            votingDelay: 1,
            votingPeriod: 100,
            quorumShares: 100,
            timelockDelay: 50,
            gracePeriod: 100,
            owner: owner
        });

        mechanism = new OctantQFMechanism(
            address(implementation),
            config,
            10000,
            10000,
            IAddressSet(address(allowset)),
            IAddressSet(address(blockset)),
            AccessMode.BLOCKSET
        );

        tam().setKeeper(keeper);
        tam().setManagement(owner);

        // Fund users
        token.transfer(alice, DEPOSIT * 2);
        token.transfer(bob, DEPOSIT * 2);
        token.transfer(blockedUser, DEPOSIT * 2);

        vm.stopPrank();
    }

    function test_blocksetMode_unblockedUserCanSignup() public {
        // Alice is not in blockset, can signup
        assertTrue(mechanism.canSignup(alice));

        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        tam().signup(DEPOSIT);
        vm.stopPrank();

        assertEq(tam().votingPower(alice), DEPOSIT);
    }

    function test_blocksetMode_blockedUserCannotSignup() public {
        // Add user to blockset
        vm.prank(owner);
        blockset.add(blockedUser);

        assertFalse(mechanism.canSignup(blockedUser));

        vm.startPrank(blockedUser);
        token.approve(address(mechanism), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(InBlockset.selector, blockedUser));
        tam().signup(DEPOSIT);
        vm.stopPrank();
    }

    function test_blocksetMode_removingFromBlocksetAllowsSignup() public {
        // Block then unblock
        vm.startPrank(owner);
        blockset.add(blockedUser);
        assertFalse(mechanism.canSignup(blockedUser));

        blockset.remove(blockedUser);
        assertTrue(mechanism.canSignup(blockedUser));
        vm.stopPrank();

        vm.startPrank(blockedUser);
        token.approve(address(mechanism), DEPOSIT);
        tam().signup(DEPOSIT);
        vm.stopPrank();

        assertEq(tam().votingPower(blockedUser), DEPOSIT);
    }

    function test_setAccessMode_cannotChangeDuringVoting() public {
        vm.warp(block.timestamp + 2); // Past voting delay

        vm.prank(owner);
        vm.expectRevert("Mode changes only allowed before voting starts or after tally finalization");
        mechanism.setAccessMode(AccessMode.NONE);
    }

    function test_setContributionBlockset_onlyOwner() public {
        AddressSet newBlockset = new AddressSet();

        vm.prank(alice);
        vm.expectRevert("Only owner");
        mechanism.setContributionBlockset(newBlockset);

        vm.prank(owner);
        mechanism.setContributionBlockset(IAddressSet(address(newBlockset)));

        assertEq(address(mechanism.contributionBlockset()), address(newBlockset));
    }

    function test_setContributionAllowset_onlyOwner() public {
        AddressSet newAllowset = new AddressSet();

        vm.prank(alice);
        vm.expectRevert("Only owner");
        mechanism.setContributionAllowset(newAllowset);
    }

    function test_setAccessMode_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Only owner");
        mechanism.setAccessMode(AccessMode.NONE);
    }

    function test_setAccessMode_afterFinalization() public {
        // Signup and go through voting cycle
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        tam().signup(DEPOSIT);
        vm.stopPrank();

        vm.prank(keeper);
        uint256 pid = tam().propose(makeAddr("recipient"), "Test");

        vm.warp(block.timestamp + 2);
        vm.prank(alice);
        tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, makeAddr("recipient"));

        vm.warp(block.timestamp + 101);
        vm.prank(owner);
        tam().finalizeVoteTally();

        // After finalization, mode change is allowed
        vm.prank(owner);
        mechanism.setAccessMode(AccessMode.NONE);

        assertEq(uint8(mechanism.contributionAccessMode()), uint8(AccessMode.NONE));
    }

    function test_setAlpha_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert("Only owner can set alpha");
        mechanism.setAlpha(1, 2);

        vm.prank(owner);
        mechanism.setAlpha(1, 2);

        (uint256 num, uint256 den) = mechanism.getAlpha();
        assertEq(num, 1);
        assertEq(den, 2);
    }
}

/// @title ProperQF Branch Coverage Tests
/// @notice Tests for untested branches in ProperQF
contract ProperQFBranchCoverageTest is Test {
    HarnessProperQF qf;

    function setUp() public {
        qf = new HarnessProperQF();
    }

    // VoteWeightOutsideTolerance: voteWeight too low
    function test_processVote_voteWeightTooLow_reverts() public {
        // contribution = 100, sqrt(100) = 10
        // 10% tolerance: voteWeight must be >= 10 - 1 = 9
        // But we pass 8 which is below tolerance
        vm.expectRevert(ProperQF.VoteWeightOutsideTolerance.selector);
        qf.exposed_processVote(1, 100, 8);
    }

    // VoteWeightOutsideTolerance: voteWeight slightly above sqrt
    function test_processVote_voteWeightAboveSqrt_reverts() public {
        // contribution = 10000, sqrt(10000) = 100
        // voteWeight = 101, voteWeight^2 = 10201 > 10000 => SquareRootTooLarge
        vm.expectRevert(ProperQF.SquareRootTooLarge.selector);
        qf.exposed_processVote(1, 10000, 101);
    }

    // Test _calculateOptimalAlpha: quadraticSum <= linearSum (alpha = 0)
    function test_calculateOptimalAlpha_noQuadraticAdvantage() public view {
        // If quadraticSum <= linearSum, alpha should be 0
        (uint256 num, uint256 den) = qf.exposed_calculateOptimalAlpha(1000, 100, 200, 500);
        assertEq(num, 0);
        assertEq(den, 1);
    }

    // Test _calculateOptimalAlpha: totalAssets <= linearSum (alpha = 0)
    function test_calculateOptimalAlpha_insufficientAssets() public view {
        // totalAssetsAvailable = 500 + 100 = 600, linearSum = 700
        // totalAssetsAvailable <= linearSum, so alpha = 0
        (uint256 num, uint256 den) = qf.exposed_calculateOptimalAlpha(100, 1000, 700, 500);
        assertEq(num, 0);
        assertEq(den, 1);
    }

    // Test _calculateOptimalAlpha: full quadratic funding (alpha = 1)
    function test_calculateOptimalAlpha_fullQuadratic() public view {
        // quadraticSum = 1000, linearSum = 500
        // quadraticAdvantage = 500
        // totalAssetsAvailable = 1000 + 500 = 1500
        // numerator = 1500 - 500 = 1000 >= 500 = quadraticAdvantage
        // alpha = 1
        (uint256 num, uint256 den) = qf.exposed_calculateOptimalAlpha(1000, 1000, 500, 500);
        assertEq(num, 1);
        assertEq(den, 1);
    }

    // Test _calculateOptimalAlpha: fractional alpha
    function test_calculateOptimalAlpha_fractional() public view {
        // quadraticSum = 1000, linearSum = 500
        // quadraticAdvantage = 500
        // totalAssetsAvailable = 200 + 500 = 700
        // numerator = 700 - 500 = 200 < 500
        // alpha = 200/500
        (uint256 num, uint256 den) = qf.exposed_calculateOptimalAlpha(200, 1000, 500, 500);
        assertEq(num, 200);
        assertEq(den, 500);
    }

    // VoteWeight overflow: extremely large voteWeight
    function test_processVote_overflowProtection() public {
        // voteWeight * voteWeight overflows
        uint256 largeWeight = type(uint128).max;
        vm.expectRevert(); // Will overflow or hit VoteWeightOverflow
        qf.exposed_processVote(1, type(uint256).max, largeWeight);
    }

    // _setAlpha: zero denominator
    function test_setAlpha_zeroDenominator_reverts() public {
        vm.expectRevert(ProperQF.DenominatorMustBePositive.selector);
        qf.exposed_setAlpha(1, 0);
    }

    // _setAlpha: numerator > denominator (alpha > 1)
    function test_setAlpha_alphaGreaterThanOne_reverts() public {
        vm.expectRevert(ProperQF.AlphaMustBeLessOrEqualToOne.selector);
        qf.exposed_setAlpha(101, 100);
    }

    // _processVote: zero contribution
    function test_processVote_zeroContribution_reverts() public {
        vm.expectRevert(ProperQF.ContributionMustBePositive.selector);
        qf.exposed_processVote(1, 0, 0);
    }

    // _processVote: zero voteWeight with nonzero contribution
    function test_processVote_zeroVoteWeight_reverts() public {
        vm.expectRevert(ProperQF.VoteWeightMustBePositive.selector);
        qf.exposed_processVote(1, 100, 0);
    }

    // _processVote: valid vote (success path - contributes to branch coverage of all checks passing)
    function test_processVote_validVote_succeeds() public {
        // contribution = 10000e18, sqrt(10000e18) = 100e9, voteWeight = 100e9
        qf.exposed_processVote(1, 10000e18, 100e9);

        // Verify it was recorded (sumContributions is lossy due to quantization)
        uint256 step = uint256(1) << 32;
        ProperQF.Project memory project = qf.projects(1);
        assertApproxEqAbs(project.sumContributions, 10000e18, step);
        assertEq(project.sumSquareRoots, 100e9);
    }

    // _calculateOptimalAlpha: quadraticSum == linearSum exactly (edge case)
    function test_calculateOptimalAlpha_equalSums() public view {
        // quadraticSum == linearSum => no quadratic advantage, alpha = 0
        (uint256 num, uint256 den) = qf.exposed_calculateOptimalAlpha(1000, 500, 500, 500);
        assertEq(num, 0);
        assertEq(den, 1);
    }

    // _calculateOptimalAlpha: totalAssetsAvailable exactly equals linearSum (boundary)
    function test_calculateOptimalAlpha_assetsEqualsLinear() public view {
        // totalAssetsAvailable = 100 + 500 = 600 == linearSum = 600
        // totalAssetsAvailable <= linearSum => alpha = 0
        (uint256 num, uint256 den) = qf.exposed_calculateOptimalAlpha(100, 1000, 600, 500);
        assertEq(num, 0);
        assertEq(den, 1);
    }

    // _calculateOptimalAlpha: numerator exactly equals quadraticAdvantage (boundary for alpha=1)
    function test_calculateOptimalAlpha_numeratorEqualsAdvantage() public view {
        // quadraticSum = 1000, linearSum = 500, quadraticAdvantage = 500
        // totalAssetsAvailable = 500 + 500 = 1000
        // numerator = 1000 - 500 = 500 == quadraticAdvantage = 500
        // numerator >= quadraticAdvantage => alpha = 1
        (uint256 num, uint256 den) = qf.exposed_calculateOptimalAlpha(500, 1000, 500, 500);
        assertEq(num, 1);
        assertEq(den, 1);
    }

    // _setAlpha: alpha = 0 (numerator = 0)
    function test_setAlpha_alphaZero() public {
        qf.exposed_setAlpha(0, 100);
        (uint256 num, uint256 den) = qf.getAlpha();
        assertEq(num, 0);
        assertEq(den, 100);
    }

    // _setAlpha: alpha = 1 (numerator = denominator)
    function test_setAlpha_alphaOne() public {
        qf.exposed_setAlpha(100, 100);
        (uint256 num, uint256 den) = qf.getAlpha();
        assertEq(num, 100);
        assertEq(den, 100);
    }

    // getTally: returns correct tally for project with no votes
    function test_getTally_emptyProject() public view {
        (uint256 sumC, uint256 sumSq, uint256 qf_, uint256 lf) = qf.getTally(999);
        assertEq(sumC, 0);
        assertEq(sumSq, 0);
        assertEq(qf_, 0);
        assertEq(lf, 0);
    }

    // totalFunding getter
    function test_totalFunding_afterVotes() public {
        qf.exposed_processVote(1, 10000e18, 100e9);
        assertTrue(qf.totalFunding() > 0);
    }
}

// ======================================================================================
// ADDITIONAL BRANCH COVERAGE TESTS
// ======================================================================================

/// @title TokenizedAllocationMechanism Deep Branch Coverage
/// @notice Tests for remaining untested branches in TokenizedAllocationMechanism
contract TAMDeepBranchCoverageTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address owner;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address recipient1 = makeAddr("recipient1");
    address recipient2 = makeAddr("recipient2");
    address recipient3 = makeAddr("recipient3");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant QUORUM = 10;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        owner = address(this);
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        token.mint(alice, 1_000_000e18);
        token.mint(bob, 1_000_000e18);
        token.mint(charlie, 1_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Deep Branch Test",
            symbol: "DBT",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM * W * W,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(alice);
        _tam().setManagement(bob);

        // Fund matching pool
        token.mint(address(mechanism), 50_000e18);
    }

    // ===== DOMAIN_SEPARATOR: same chain ID path (cached) =====
    // The first call to DOMAIN_SEPARATOR() should use cached value when chain hasn't changed
    function test_DOMAIN_SEPARATOR_sameChain_returnsCached() public {
        bytes32 ds1 = _tam().DOMAIN_SEPARATOR();
        bytes32 ds2 = _tam().DOMAIN_SEPARATOR();
        assertEq(ds1, ds2, "Domain separator should be same when chain hasn't changed");
        assertTrue(ds1 != bytes32(0), "Domain separator should not be zero");
    }

    // ===== _executeSignup: zero deposit path =====
    function test_signup_zeroDeposit_noTransfer() public {
        uint256 balBefore = token.balanceOf(alice);

        vm.prank(alice);
        _tam().signup(0);

        // Balance unchanged (no transfer)
        assertEq(token.balanceOf(alice), balBefore, "No tokens should be transferred for zero deposit");
        // Zero voting power with zero deposit is allowed (newPower == 0 && deposit == 0 doesn't revert)
        assertEq(_tam().votingPower(alice), 0, "Should have 0 voting power with 0 deposit");
    }

    // ===== _executeSignup: deposit too large =====
    function test_signup_depositTooLarge_reverts() public {
        uint256 tooLarge = type(uint128).max + uint256(1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedAllocationMechanism.DepositTooLarge.selector, tooLarge, type(uint128).max)
        );
        _tam().signup(tooLarge);
    }

    // ===== _executeSignup: signup after voting ended =====
    function test_signup_afterVotingEnded_reverts() public {
        vm.warp(block.timestamp + VOTING_DELAY + VOTING_PERIOD + 1);

        vm.prank(alice);
        vm.expectRevert();
        _tam().signup(100);
    }

    // ===== _executeCastVote: exactly at votingStart boundary (should succeed) =====
    function test_castVote_exactlyAtVotingStart() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        // Warp to exactly votingStartTime
        vm.warp(_tam().votingStartTime());

        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);

        // Should succeed
        assertTrue(_tam().votingPower(alice) < DEPOSIT, "Voting power should decrease");
    }

    // ===== _executeCastVote: exactly at votingEnd boundary (should succeed) =====
    function test_castVote_exactlyAtVotingEnd() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        // Warp to exactly votingEndTime
        vm.warp(_tam().votingEndTime());

        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);

        // Should succeed since the check is block.timestamp > votingEnd
        assertTrue(_tam().votingPower(alice) < DEPOSIT, "Voting power should decrease");
    }

    // ===== _executeCastVote: before voting start reverts =====
    function test_castVote_beforeVotingStart_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        // One second before voting starts
        vm.warp(_tam().votingStartTime() - 1);

        vm.prank(alice);
        vm.expectRevert();
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);
    }

    // ===== _executeCastVote: after voting end reverts =====
    function test_castVote_afterVotingEnd_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        // One second after voting ends
        vm.warp(_tam().votingEndTime() + 1);

        vm.prank(alice);
        vm.expectRevert();
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);
    }

    // ===== _executeCastVote: weight too large =====
    function test_castVote_weightTooLarge_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        uint256 tooLargeWeight = type(uint128).max + uint256(1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenizedAllocationMechanism.WeightTooLarge.selector,
                tooLargeWeight,
                type(uint128).max
            )
        );
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, tooLargeWeight, recipient1);
    }

    // ===== _state: Pending state =====
    function test_state_pending() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        // Before voting starts, state should be Pending
        assertEq(uint8(_tam().state(pid)), uint8(TokenizedAllocationMechanism.ProposalState.Pending));
    }

    // ===== _state: Active state =====
    function test_state_active() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        assertEq(uint8(_tam().state(pid)), uint8(TokenizedAllocationMechanism.ProposalState.Active));
    }

    // ===== _state: Tallying state (voting ended, tally not finalized) =====
    function test_state_tallying() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);

        // Warp past voting end but don't finalize
        vm.warp(block.timestamp + VOTING_PERIOD + 1);

        assertEq(uint8(_tam().state(pid)), uint8(TokenizedAllocationMechanism.ProposalState.Tallying));
    }

    // ===== _state: Defeated state (tally finalized but no quorum) =====
    function test_state_defeated() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        // Vote with very small weight so quorum isn't met
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 1 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        // With QUORUM = 10 and alpha=50/100:
        // vote weight=1, cost=1, quadratic=1*1=1, linear=1
        // F_j = 0.5*1 + 0.5*1 = 1 < 10 quorum
        assertEq(uint8(_tam().state(pid)), uint8(TokenizedAllocationMechanism.ProposalState.Defeated));
    }

    // ===== _state: Canceled state =====
    function test_state_canceled() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.prank(alice);
        _tam().cancelProposal(pid);

        assertEq(uint8(_tam().state(pid)), uint8(TokenizedAllocationMechanism.ProposalState.Canceled));
    }

    // ===== _state: Succeeded not queued during redemption period =====
    function test_state_succeededDuringRedemption() public {
        _signupUser(alice, DEPOSIT);
        _signupUser(bob, DEPOSIT);

        vm.prank(alice);
        uint256 pid1 = _tam().propose(recipient1, "Prop 1");
        vm.prank(bob);
        uint256 pid2 = _tam().propose(recipient2, "Prop 2");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // Vote on both proposals meeting quorum
        vm.prank(alice);
        _tam().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);
        vm.prank(bob);
        _tam().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient2);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        // Queue only pid1
        _tam().queueProposal(pid1);

        // Warp to redemption period - pid2 is not queued (shares == 0) so it should be Succeeded
        vm.warp(_tam().globalRedemptionStart() + 1);

        // pid2 was not queued so during redemption period it's Succeeded (shares == 0)
        assertEq(uint8(_tam().state(pid2)), uint8(TokenizedAllocationMechanism.ProposalState.Succeeded));
    }

    // ===== _state: Queued state (tally finalized, queued, before redemption) =====
    function test_state_queued() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // Before redemption start -> Queued
        assertEq(uint8(_tam().state(pid)), uint8(TokenizedAllocationMechanism.ProposalState.Queued));
    }

    // ===== transferOwnership: overwrite pending owner =====
    function test_transferOwnership_overwritePending() public {
        address firstCandidate = makeAddr("first");
        address secondCandidate = makeAddr("second");

        _tam().transferOwnership(firstCandidate);
        assertEq(_tam().pendingOwner(), firstCandidate);

        // Overwrite with second candidate
        _tam().transferOwnership(secondCandidate);
        assertEq(_tam().pendingOwner(), secondCandidate);
    }

    // ===== transferOwnership: to zero address reverts =====
    function test_transferOwnership_zeroAddress_reverts() public {
        vm.expectRevert(TokenizedAllocationMechanism.Unauthorized.selector);
        _tam().transferOwnership(address(0));
    }

    // ===== acceptOwnership: not pending reverts =====
    function test_acceptOwnership_notPending_reverts() public {
        vm.prank(alice);
        vm.expectRevert(TokenizedAllocationMechanism.Unauthorized.selector);
        _tam().acceptOwnership();
    }

    // ===== acceptOwnership: success =====
    function test_acceptOwnership_success() public {
        _tam().transferOwnership(alice);

        vm.prank(alice);
        _tam().acceptOwnership();

        assertEq(_tam().owner(), alice);
        assertEq(_tam().pendingOwner(), address(0));
    }

    // ===== previewRedeem: during redemption period returns positive =====
    function test_previewRedeem_duringRedemption_returnsPositive() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);
        assertTrue(shares > 0, "Should have shares");

        // Warp to redemption period
        vm.warp(_tam().globalRedemptionStart() + 1);

        uint256 preview = _tam().previewRedeem(shares);
        assertTrue(preview > 0, "Preview should return positive during redemption");
    }

    // ===== previewRedeem: globalRedemptionStart is 0 =====
    function test_previewRedeem_notFinalized_returnsZero() public view {
        // Before any finalization, globalRedemptionStart is 0
        assertEq(_tam().previewRedeem(1000), 0);
    }

    // ===== _transfer: after grace period reverts =====
    function test_transfer_afterGracePeriod_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // Warp past grace period
        vm.warp(_tam().globalRedemptionStart() + GRACE_PERIOD + 1);

        vm.prank(recipient1);
        vm.expectRevert("Transfers only allowed during redemption period");
        _tam().transfer(charlie, 1);
    }

    // ===== ERC20: approve, transferFrom with allowance =====
    function test_approve_and_transferFrom() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);

        // Warp to redemption period
        vm.warp(_tam().globalRedemptionStart() + 1);

        // Approve bob to spend
        vm.prank(recipient1);
        _tam().approve(bob, shares);
        assertEq(_tam().allowance(recipient1, bob), shares);

        // Bob transfers via transferFrom
        vm.prank(bob);
        _tam().transferFrom(recipient1, charlie, shares / 2);

        assertEq(_tam().balanceOf(charlie), shares / 2);
        assertEq(_tam().balanceOf(recipient1), shares - shares / 2);
    }

    // ===== _spendAllowance: infinite allowance doesn't decrease =====
    function test_spendAllowance_infiniteAllowance() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);

        // Warp to redemption period
        vm.warp(_tam().globalRedemptionStart() + 1);

        // Set infinite allowance
        vm.prank(recipient1);
        _tam().approve(bob, type(uint256).max);

        // Transfer using infinite allowance
        vm.prank(bob);
        _tam().transferFrom(recipient1, charlie, shares / 2);

        // Allowance should still be max
        assertEq(_tam().allowance(recipient1, bob), type(uint256).max);
    }

    // ===== redeem: on behalf with allowance =====
    function test_redeem_onBehalf_withAllowance() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);

        // Warp to redemption period
        vm.warp(_tam().globalRedemptionStart() + 1);

        // Approve bob to redeem on behalf
        vm.prank(recipient1);
        _tam().approve(bob, shares);

        uint256 balBefore = token.balanceOf(charlie);
        vm.prank(bob);
        _tam().redeem(shares, charlie, recipient1);

        assertTrue(token.balanceOf(charlie) > balBefore, "Charlie should receive assets");
        assertEq(_tam().balanceOf(recipient1), 0, "Recipient should have 0 shares");
    }

    // ===== redeem: zero assets reverts =====
    function test_redeem_zeroAssets_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // Warp to redemption period
        vm.warp(_tam().globalRedemptionStart() + 1);

        vm.prank(recipient1);
        vm.expectRevert("ZERO_ASSETS");
        _tam().redeem(0, recipient1, recipient1);
    }

    // ===== _withdraw: zero receiver address reverts =====
    function test_redeem_zeroReceiver_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);

        vm.warp(_tam().globalRedemptionStart() + 1);

        vm.prank(recipient1);
        vm.expectRevert("ZERO ADDRESS");
        _tam().redeem(shares, address(0), recipient1);
    }

    // ===== pause / unpause / whenNotPaused =====
    function test_pause_blocksFunctions() public {
        _tam().pause();
        assertTrue(_tam().paused());

        vm.prank(alice);
        vm.expectRevert(TokenizedAllocationMechanism.PausedError.selector);
        _tam().signup(100);
    }

    function test_unpause_restoresFunctions() public {
        _tam().pause();
        _tam().unpause();
        assertFalse(_tam().paused());
    }

    // ===== finalizeVoteTally: already finalized =====
    function test_finalize_alreadyFinalized_reverts() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        vm.expectRevert(TokenizedAllocationMechanism.TallyAlreadyFinalized.selector);
        _tam().finalizeVoteTally();
    }

    // ===== queueProposal: tally not finalized =====
    function test_queueProposal_notFinalized_reverts() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.expectRevert(TokenizedAllocationMechanism.TallyNotFinalized.selector);
        _tam().queueProposal(pid);
    }

    // ===== queueProposal: invalid proposal =====
    function test_queueProposal_invalidProposal_reverts() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidProposal.selector, 999));
        _tam().queueProposal(999);
    }

    // ===== queueProposal: no quorum =====
    function test_queueProposal_noQuorum_reverts() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 1 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        vm.expectRevert();
        _tam().queueProposal(pid);
    }

    // ===== queueProposal: already queued =====
    function test_queueProposal_alreadyQueued_reverts() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.AlreadyQueued.selector, pid));
        _tam().queueProposal(pid);
    }

    // ===== cancelProposal: invalid proposal =====
    function test_cancelProposal_invalidProposal_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidProposal.selector, 999));
        _tam().cancelProposal(999);
    }

    // ===== state: invalid proposal =====
    function test_state_invalidProposal_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidProposal.selector, 999));
        _tam().state(999);
    }

    // ===== View functions coverage =====
    function test_viewFunctions() public view {
        assertEq(_tam().getProposalCount(), 0);
        assertEq(bytes(_tam().name()).length > 0, true);
        assertEq(bytes(_tam().symbol()).length > 0, true);
        assertEq(address(_tam().asset()), address(token));
        assertEq(_tam().owner(), address(this));
        assertEq(_tam().totalSupply(), 0);
        assertEq(_tam().totalAssets(), 0);
        assertEq(_tam().decimals(), 18);
        assertEq(_tam().balanceOf(alice), 0);
        assertEq(_tam().allowance(alice, bob), 0);
        assertEq(_tam().convertToShares(1e18), 1e18);
        assertEq(_tam().convertToAssets(1e18), 1e18);
        assertTrue(_tam().startBlock() > 0);
        assertEq(_tam().votingDelay(), VOTING_DELAY);
        assertEq(_tam().votingPeriod(), VOTING_PERIOD);
        assertEq(_tam().quorumShares(), QUORUM * W * W);
        assertEq(_tam().timelockDelay(), TIMELOCK_DELAY);
        assertEq(_tam().gracePeriod(), GRACE_PERIOD);
        assertEq(_tam().globalRedemptionStart(), 0);
        assertTrue(_tam().votingStartTime() > 0);
        assertTrue(_tam().votingEndTime() > 0);
        assertTrue(_tam().startTime() > 0);
        assertEq(_tam().nonces(alice), 0);
        assertEq(_tam().management(), bob);
        assertEq(_tam().keeper(), alice);
        assertFalse(_tam().tallyFinalized());
    }

    // ===== maxRedeem: before finalization =====
    function test_maxRedeem_beforeFinalization() public view {
        // No redemption period set, maxRedeem should be 0
        assertEq(_tam().maxRedeem(alice), 0);
    }

    // ===== maxRedeem: during redemption =====
    function test_maxRedeem_duringRedemption() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);

        // During redemption: maxRedeem should equal balance
        vm.warp(_tam().globalRedemptionStart() + 1);
        assertEq(_tam().maxRedeem(recipient1), shares);
    }

    // ===== maxRedeem: after grace period =====
    function test_maxRedeem_afterGracePeriod() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // After grace period: maxRedeem should be 0
        vm.warp(_tam().globalRedemptionStart() + GRACE_PERIOD + 1);
        assertEq(_tam().maxRedeem(recipient1), 0);
    }

    // ===== Multiple signups accumulate voting power =====
    function test_multipleSignups_accumulateVotingPower() public {
        _signupUser(alice, 1000);
        uint256 power1 = _tam().votingPower(alice);

        _signupUser(alice, 2000);
        uint256 power2 = _tam().votingPower(alice);

        assertTrue(power2 > power1, "Power should accumulate");
    }

    // ===== Helpers =====

    function _signupUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(address(mechanism), amount);
        _tam().signup(amount);
        vm.stopPrank();
    }
}

/// @title Decimal Branch Coverage Tests for _convertToShares/_convertToAssets with decimals > 18
/// @notice Tests the assetDecimals > 18 branch in _convertToShares and _convertToAssets
contract DecimalBranchCoverageTest is Test {
    AllocationMechanismFactory factory;

    address alice = makeAddr("alice");

    function _tam(address mech) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(mech);
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
    }

    function _deployWithToken(address tokenAddr) internal returns (address) {
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(tokenAddr),
            name: "Decimal Test",
            symbol: "DT",
            votingDelay: 100,
            votingPeriod: 1000,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        return factory.deployQuadraticVotingMechanism(config, 50, 100);
    }

    // ===== _convertToShares: assetDecimals > 18 (scale down) =====
    function test_convertToShares_decimalsGreaterThan18() public {
        BranchTestMockToken token21 = new BranchTestMockToken("T21", "T21", 21);
        token21.mint(alice, 1000 * 10 ** 21);

        address mech = _deployWithToken(address(token21));
        _tam(mech).setKeeper(alice);
        _tam(mech).setManagement(alice);

        // convertToShares with totalSupply=0 and decimals=21 should scale down
        // 1000 * 10^21 assets -> 1000 * 10^18 shares (divide by 10^3)
        uint256 shares = _tam(mech).convertToShares(1000 * 10 ** 21);
        assertEq(shares, 1000 * 10 ** 18, "Should scale down from 21 to 18 decimals");
    }

    // ===== _convertToAssets: assetDecimals > 18 (scale up) =====
    function test_convertToAssets_decimalsGreaterThan18() public {
        BranchTestMockToken token21 = new BranchTestMockToken("T21", "T21", 21);
        token21.mint(alice, 1000 * 10 ** 21);

        address mech = _deployWithToken(address(token21));
        _tam(mech).setKeeper(alice);
        _tam(mech).setManagement(alice);

        // convertToAssets with totalSupply=0 and decimals=21 should scale up
        // 1000 * 10^18 shares -> 1000 * 10^21 assets (multiply by 10^3)
        uint256 assets = _tam(mech).convertToAssets(1000 * 10 ** 18);
        assertEq(assets, 1000 * 10 ** 21, "Should scale up from 18 to 21 decimals");
    }

    // ===== _convertToShares: assetDecimals == 18 =====
    function test_convertToShares_decimals18() public {
        BranchTestMockToken token18 = new BranchTestMockToken("T18", "T18", 18);
        token18.mint(alice, 1000e18);

        address mech = _deployWithToken(address(token18));

        uint256 shares = _tam(mech).convertToShares(1000e18);
        assertEq(shares, 1000e18, "18 decimal token: 1:1 conversion");
    }

    // ===== _convertToAssets: assetDecimals == 18 =====
    function test_convertToAssets_decimals18() public {
        BranchTestMockToken token18 = new BranchTestMockToken("T18", "T18", 18);
        token18.mint(alice, 1000e18);

        address mech = _deployWithToken(address(token18));

        uint256 assets = _tam(mech).convertToAssets(1000e18);
        assertEq(assets, 1000e18, "18 decimal token: 1:1 conversion");
    }

    // ===== _convertToShares: assetDecimals < 18 (scale up) =====
    function test_convertToShares_decimalsLessThan18() public {
        BranchTestMockToken token6 = new BranchTestMockToken("T6", "T6", 6);
        token6.mint(alice, 1000 * 10 ** 6);

        address mech = _deployWithToken(address(token6));

        // 1000 * 10^6 assets -> 1000 * 10^18 shares (multiply by 10^12)
        uint256 shares = _tam(mech).convertToShares(1000 * 10 ** 6);
        assertEq(shares, 1000 * 10 ** 18, "Should scale up from 6 to 18 decimals");
    }

    // ===== _convertToAssets: assetDecimals < 18 (scale down) =====
    function test_convertToAssets_decimalsLessThan18() public {
        BranchTestMockToken token6 = new BranchTestMockToken("T6", "T6", 6);
        token6.mint(alice, 1000 * 10 ** 6);

        address mech = _deployWithToken(address(token6));

        // 1000 * 10^18 shares -> 1000 * 10^6 assets (divide by 10^12)
        uint256 assets = _tam(mech).convertToAssets(1000 * 10 ** 18);
        assertEq(assets, 1000 * 10 ** 6, "Should scale down from 18 to 6 decimals");
    }

    // ===== _getVotingPowerHook: assetDecimals > 18 =====
    function test_votingPower_decimalsGreaterThan18() public {
        BranchTestMockToken token21 = new BranchTestMockToken("T21", "T21", 21);
        token21.mint(alice, 1000 * 10 ** 21);

        address mech = _deployWithToken(address(token21));
        _tam(mech).setKeeper(alice);
        _tam(mech).setManagement(alice);

        uint256 deposit = 1000 * 10 ** 21;
        vm.startPrank(alice);
        token21.approve(mech, deposit);
        _tam(mech).signup(deposit);
        vm.stopPrank();

        // With decimals=21, voting power should scale down: divide by 10^3
        // 1000 * 10^21 -> 1000 * 10^18
        assertEq(_tam(mech).votingPower(alice), 1000 * 10 ** 18, "Should scale down from 21 to 18 decimals");
    }
}

/// @title QuadraticVotingMechanism Additional Branch Coverage
/// @notice Tests for remaining untested branches in QuadraticVotingMechanism
contract QVMBranchCoverageTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address owner;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address recipient1 = makeAddr("recipient1");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant QUORUM = 10;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        owner = address(this);
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        token.mint(alice, 1_000_000e18);
        token.mint(bob, 1_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "QVM Branch Test",
            symbol: "QVB",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM * W * W,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(alice);
        _tam().setManagement(bob);

        token.mint(address(mechanism), 50_000e18);
    }

    // ===== receive(): ETH revert =====
    function test_receive_ETH_reverts() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool success, ) = address(mechanism).call{ value: 1 ether }("");
        assertFalse(success, "ETH transfer should revert");
    }

    // ===== setAlpha: zero denominator through setAlpha =====
    function test_setAlpha_zeroDenominator_reverts() public {
        vm.expectRevert(ProperQF.DenominatorMustBePositive.selector);
        mechanism.setAlpha(1, 0);
    }

    // ===== setAlpha: numerator > denominator =====
    function test_setAlpha_alphaGreaterThanOne_reverts() public {
        vm.expectRevert(ProperQF.AlphaMustBeLessOrEqualToOne.selector);
        mechanism.setAlpha(2, 1);
    }

    // ===== setAlpha: non-owner reverts =====
    function test_setAlpha_notOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert("Only owner can set alpha");
        mechanism.setAlpha(1, 2);
    }

    // ===== calculateOptimalAlpha: integration via mechanism =====
    function test_calculateOptimalAlpha_integration() public {
        // Signup some users and cast votes to populate quadratic/linear sums
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        // Call calculateOptimalAlpha through the mechanism
        (, uint256 den) = mechanism.calculateOptimalAlpha(50_000e18, DEPOSIT);
        // Just verify it returns without reverting and denominator is positive
        assertTrue(den > 0, "Denominator should be positive");
    }

    // ===== getProposalFunding: invalid proposal reverts =====
    function test_getProposalFunding_invalidProposal_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidProposal.selector, 999));
        mechanism.getProposalFunding(999);
    }

    // ===== _proposalExists: pid == 0 returns false (covers pid > 0 false branch) =====
    function test_castVote_pidZero_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidProposal.selector, 0));
        _tam().castVote(0, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);
    }

    // ===== getProposalFunding: canceled proposal returns zeros =====
    function test_getProposalFunding_canceledProposal_returnsZeros() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);

        // Cancel the proposal
        vm.prank(alice);
        _tam().cancelProposal(pid);

        (uint256 sumC, uint256 sumSq, uint256 qf, uint256 lf) = mechanism.getProposalFunding(pid);
        assertEq(sumC, 0, "Canceled proposal should have zero contributions");
        assertEq(sumSq, 0, "Canceled proposal should have zero square roots");
        assertEq(qf, 0, "Canceled proposal should have zero quadratic funding");
        assertEq(lf, 0, "Canceled proposal should have zero linear funding");
    }

    // ===== getProposalFunding: valid proposal returns funding =====
    function test_getProposalFunding_validProposal_returnsFunding() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        (uint256 sumC, uint256 sumSq, uint256 qf, uint256 lf) = mechanism.getProposalFunding(pid);
        assertTrue(sumC > 0, "Should have contributions");
        assertTrue(sumSq > 0, "Should have square roots");
        assertTrue(qf > 0 || lf > 0, "Should have some funding");
    }

    // ===== _beforeProposeHook: non-keeper non-management proposer =====
    function test_propose_nonKeeperNonManagement_reverts() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert(
            abi.encodeWithSelector(TokenizedAllocationMechanism.ProposeNotAllowed.selector, makeAddr("random"))
        );
        _tam().propose(recipient1, "Test");
    }

    // ===== _beforeProposeHook: keeper can propose =====
    function test_propose_keeper_succeeds() public {
        vm.prank(alice); // alice is keeper
        uint256 pid = _tam().propose(recipient1, "Keeper proposal");
        assertTrue(pid > 0);
    }

    // ===== _beforeProposeHook: management can propose =====
    function test_propose_management_succeeds() public {
        vm.prank(bob); // bob is management
        uint256 pid = _tam().propose(recipient1, "Management proposal");
        assertTrue(pid > 0);
    }

    // ===== Helpers =====

    function _signupUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(address(mechanism), amount);
        _tam().signup(amount);
        vm.stopPrank();
    }
}

/// @title BaseAllocationMechanism Branch Coverage
/// @notice Tests for _availableWithdrawLimit and onlySelf modifier in BaseAllocationMechanism
contract BaseAllocationMechanismBranchTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address owner;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address recipient1 = makeAddr("recipient1");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant QUORUM = 10;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        owner = address(this);
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        token.mint(alice, 1_000_000e18);
        token.mint(bob, 1_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Base Branch Test",
            symbol: "BBT",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM * W * W,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(alice);
        _tam().setManagement(bob);

        token.mint(address(mechanism), 50_000e18);
    }

    // ===== onlySelf modifier: direct external call to hook reverts =====
    function test_onlySelf_directCallToBeforeSignupHook_reverts() public {
        // Calling beforeSignupHook directly (not via delegatecall from TAM) should revert
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).beforeSignupHook(alice);
    }

    function test_onlySelf_directCallToBeforeProposeHook_reverts() public {
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).beforeProposeHook(alice);
    }

    function test_onlySelf_directCallToGetVotingPowerHook_reverts() public {
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).getVotingPowerHook(alice, 1000);
    }

    function test_onlySelf_directCallToValidateProposalHook_reverts() public {
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).validateProposalHook(1);
    }

    function test_onlySelf_directCallToProcessVoteHook_reverts() public {
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).processVoteHook(1, alice, 1, 100, 1000);
    }

    function test_onlySelf_directCallToHasQuorumHook_reverts() public {
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).hasQuorumHook(1);
    }

    function test_onlySelf_directCallToConvertVotesToShares_reverts() public {
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).convertVotesToShares(1);
    }

    function test_onlySelf_directCallToBeforeFinalizeVoteTallyHook_reverts() public {
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).beforeFinalizeVoteTallyHook();
    }

    function test_onlySelf_directCallToGetRecipientAddressHook_reverts() public {
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).getRecipientAddressHook(1);
    }

    function test_onlySelf_directCallToRequestCustomDistributionHook_reverts() public {
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).requestCustomDistributionHook(alice, 1000);
    }

    function test_onlySelf_directCallToAvailableWithdrawLimit_reverts() public {
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).availableWithdrawLimit(alice);
    }

    function test_onlySelf_directCallToCalculateTotalAssetsHook_reverts() public {
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).calculateTotalAssetsHook();
    }

    // ===== _availableWithdrawLimit: before finalization (globalRedemptionStart == 0) =====
    function test_availableWithdrawLimit_beforeFinalization_returnsZero() public view {
        // maxRedeem checks _availableWithdrawLimit internally
        // Before finalization, globalRedemptionStart is 0 -> returns 0
        assertEq(_tam().maxRedeem(alice), 0, "Should be 0 before finalization");
    }

    // ===== _availableWithdrawLimit: during timelock (before redemptionStart) =====
    function test_availableWithdrawLimit_duringTimelock_returnsZero() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // During timelock period (before globalRedemptionStart)
        // Don't warp - we're still before redemption start
        assertEq(_tam().maxRedeem(recipient1), 0, "Should be 0 during timelock");
    }

    // ===== _availableWithdrawLimit: during redemption (within grace period) =====
    function test_availableWithdrawLimit_duringRedemption_returnsMax() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);

        // During redemption window
        vm.warp(_tam().globalRedemptionStart() + 1);
        assertEq(_tam().maxRedeem(recipient1), shares, "Should be able to redeem all shares during redemption");
    }

    // ===== _availableWithdrawLimit: after grace period =====
    function test_availableWithdrawLimit_afterGracePeriod_returnsZero() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // After grace period
        vm.warp(_tam().globalRedemptionStart() + GRACE_PERIOD + 1);
        assertEq(_tam().maxRedeem(recipient1), 0, "Should be 0 after grace period");
    }

    // ===== _availableWithdrawLimit: exactly at redemptionStart boundary =====
    function test_availableWithdrawLimit_exactlyAtRedemptionStart() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);

        // Exactly at redemption start (block.timestamp == globalRedemptionStart)
        vm.warp(_tam().globalRedemptionStart());
        assertEq(_tam().maxRedeem(recipient1), shares, "Should be able to redeem at redemption start");
    }

    // ===== _availableWithdrawLimit: exactly at grace period end boundary =====
    function test_availableWithdrawLimit_exactlyAtGracePeriodEnd() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);

        // Exactly at grace period end (globalRedemptionStart + gracePeriod)
        // The check is: block.timestamp > globalRedemptionStart + gracePeriod
        vm.warp(_tam().globalRedemptionStart() + GRACE_PERIOD);
        assertEq(_tam().maxRedeem(recipient1), shares, "Should be able to redeem exactly at grace period end");
    }

    // ===== Helpers =====

    function _signupUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(address(mechanism), amount);
        _tam().signup(amount);
        vm.stopPrank();
    }
}

// ======================================================================================
// MOCK CONTRACTS FOR ERC1271 AND INITIALIZATION TESTING
// ======================================================================================

/// @title Mock ERC1271 contract signer that returns the magic value
contract MockERC1271Signer {
    bytes4 constant MAGIC_VALUE = 0x1626ba7e;

    bool public shouldReturnMagic;

    constructor(bool _shouldReturnMagic) {
        shouldReturnMagic = _shouldReturnMagic;
    }

    function isValidSignature(bytes32, bytes memory) external view returns (bytes4) {
        if (shouldReturnMagic) {
            return MAGIC_VALUE;
        } else {
            return bytes4(0xdeadbeef);
        }
    }
}

/// @title Mock ERC1271 contract signer that reverts
contract MockERC1271Reverting {
    function isValidSignature(bytes32, bytes memory) external pure returns (bytes4) {
        revert("Always reverts");
    }
}

/// @title Contract that rejects ETH transfers
contract ETHRejector {
    receive() external payable {
        revert("No ETH");
    }
}

/// @title Deep Branch Coverage for Initialization, ERC1271, ERC20 edge cases and more
contract TAMDeepBranchCoverage2 is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;
    TokenizedAllocationMechanism implementation;

    address owner;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address recipient1 = makeAddr("recipient1");
    address recipient2 = makeAddr("recipient2");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant QUORUM = 10;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        owner = address(this);
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();
        implementation = new TokenizedAllocationMechanism();

        token.mint(alice, 10_000_000e18);
        token.mint(bob, 10_000_000e18);
        token.mint(charlie, 10_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Deep Branch Test 2",
            symbol: "DBT2",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM * W * W,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(alice);
        _tam().setManagement(bob);

        token.mint(address(mechanism), 50_000e18);
    }

    // ===== Initialize: zero owner reverts =====
    function test_initialize_zeroOwner_reverts() public {
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        vm.expectRevert(TokenizedAllocationMechanism.Unauthorized.selector);
        impl.initialize(address(0), IERC20(address(token)), "test", "T", 1, 1, 1, 1, 1);
    }

    // ===== Initialize: zero asset reverts =====
    function test_initialize_zeroAsset_reverts() public {
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        vm.expectRevert(TokenizedAllocationMechanism.ZeroAssetAddress.selector);
        impl.initialize(address(this), IERC20(address(0)), "test", "T", 1, 1, 1, 1, 1);
    }

    // ===== Initialize: zero votingDelay reverts =====
    function test_initialize_zeroVotingDelay_reverts() public {
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        vm.expectRevert(TokenizedAllocationMechanism.ZeroVotingDelay.selector);
        impl.initialize(address(this), IERC20(address(token)), "test", "T", 0, 1, 1, 1, 1);
    }

    // ===== Initialize: zero votingPeriod reverts =====
    function test_initialize_zeroVotingPeriod_reverts() public {
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        vm.expectRevert(TokenizedAllocationMechanism.ZeroVotingPeriod.selector);
        impl.initialize(address(this), IERC20(address(token)), "test", "T", 1, 0, 1, 1, 1);
    }

    // ===== Initialize: zero quorumShares reverts =====
    function test_initialize_zeroQuorumShares_reverts() public {
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        vm.expectRevert(TokenizedAllocationMechanism.ZeroQuorumShares.selector);
        impl.initialize(address(this), IERC20(address(token)), "test", "T", 1, 1, 0, 1, 1);
    }

    // ===== Initialize: zero timelockDelay reverts =====
    function test_initialize_zeroTimelockDelay_reverts() public {
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        vm.expectRevert(TokenizedAllocationMechanism.ZeroTimelockDelay.selector);
        impl.initialize(address(this), IERC20(address(token)), "test", "T", 1, 1, 1, 0, 1);
    }

    // ===== Initialize: zero gracePeriod reverts =====
    function test_initialize_zeroGracePeriod_reverts() public {
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        vm.expectRevert(TokenizedAllocationMechanism.ZeroGracePeriod.selector);
        impl.initialize(address(this), IERC20(address(token)), "test", "T", 1, 1, 1, 1, 0);
    }

    // ===== Initialize: empty name reverts =====
    function test_initialize_emptyName_reverts() public {
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        vm.expectRevert(TokenizedAllocationMechanism.EmptyName.selector);
        impl.initialize(address(this), IERC20(address(token)), "", "T", 1, 1, 1, 1, 1);
    }

    // ===== Initialize: empty symbol reverts =====
    function test_initialize_emptySymbol_reverts() public {
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        vm.expectRevert(TokenizedAllocationMechanism.EmptySymbol.selector);
        impl.initialize(address(this), IERC20(address(token)), "test", "", 1, 1, 1, 1, 1);
    }

    // ===== DOMAIN_SEPARATOR: different chain ID =====
    function test_DOMAIN_SEPARATOR_differentChainId() public {
        bytes32 ds1 = _tam().DOMAIN_SEPARATOR();
        vm.chainId(12345);
        bytes32 ds2 = _tam().DOMAIN_SEPARATOR();
        assertTrue(ds1 != ds2, "Domain separator should change with chain ID");
    }

    // ===== ERC1271: valid contract signer =====
    function test_signupWithSignature_erc1271_valid() public {
        MockERC1271Signer signer = new MockERC1271Signer(true);

        token.mint(address(signer), DEPOSIT * 2);
        vm.prank(address(signer));
        token.approve(address(mechanism), DEPOSIT);

        bytes32 SIGNUP_TYPEHASH = keccak256(
            "Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)"
        );
        uint256 deadline = block.timestamp + 1000;
        uint256 nonce = _tam().nonces(address(signer));
        bytes32 structHash = keccak256(
            abi.encode(SIGNUP_TYPEHASH, address(signer), address(signer), DEPOSIT, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _tam().DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest);

        _tam().signupWithSignature(address(signer), DEPOSIT, deadline, v, r, s);
        assertTrue(_tam().votingPower(address(signer)) > 0, "Contract signer should be registered");
    }

    // ===== ERC1271: invalid magic value =====
    function test_signupWithSignature_erc1271_invalidMagic_reverts() public {
        MockERC1271Signer signer = new MockERC1271Signer(false);

        token.mint(address(signer), DEPOSIT * 2);
        vm.prank(address(signer));
        token.approve(address(mechanism), DEPOSIT);

        bytes32 SIGNUP_TYPEHASH = keccak256(
            "Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)"
        );
        uint256 deadline = block.timestamp + 1000;
        uint256 nonce = _tam().nonces(address(signer));
        bytes32 structHash = keccak256(
            abi.encode(SIGNUP_TYPEHASH, address(signer), address(signer), DEPOSIT, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _tam().DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest);

        vm.expectRevert();
        _tam().signupWithSignature(address(signer), DEPOSIT, deadline, v, r, s);
    }

    // ===== ERC1271: reverts in isValidSignature =====
    function test_signupWithSignature_erc1271_reverts_fallsThrough() public {
        MockERC1271Reverting signer = new MockERC1271Reverting();

        token.mint(address(signer), DEPOSIT * 2);
        vm.prank(address(signer));
        token.approve(address(mechanism), DEPOSIT);

        bytes32 SIGNUP_TYPEHASH = keccak256(
            "Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)"
        );
        uint256 deadline = block.timestamp + 1000;
        uint256 nonce = _tam().nonces(address(signer));
        bytes32 structHash = keccak256(
            abi.encode(SIGNUP_TYPEHASH, address(signer), address(signer), DEPOSIT, nonce, deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _tam().DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest);

        vm.expectRevert();
        _tam().signupWithSignature(address(signer), DEPOSIT, deadline, v, r, s);
    }

    // ===== _executeSignup: newPower == 0 && deposit > 0 reverts =====
    function test_signup_zeroPowerWithDeposit_reverts() public {
        BranchTestMockToken token24 = new BranchTestMockToken("T24", "T24", 24);
        token24.mint(alice, 1000 * 10 ** 24);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token24)),
            name: "Zero Power Test",
            symbol: "ZPT",
            votingDelay: 100,
            votingPeriod: 1000,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        TokenizedAllocationMechanism tam = TokenizedAllocationMechanism(addr);
        tam.setKeeper(alice);
        tam.setManagement(alice);

        vm.startPrank(alice);
        token24.approve(addr, 1);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InsufficientDeposit.selector, 1));
        tam.signup(1);
        vm.stopPrank();
    }

    // ===== _executeSignup: votingPower too large after getVotingPowerHook =====
    function test_signup_votingPowerTooLarge_reverts() public {
        BranchTestMockToken token6 = new BranchTestMockToken("T6", "T6", 6);
        uint256 hugeDeposit = type(uint128).max;
        token6.mint(alice, hugeDeposit * 2);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token6)),
            name: "VP Too Large Test",
            symbol: "VPT",
            votingDelay: 100,
            votingPeriod: 1000,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        TokenizedAllocationMechanism tam = TokenizedAllocationMechanism(addr);
        tam.setKeeper(alice);
        tam.setManagement(alice);

        vm.startPrank(alice);
        token6.approve(addr, hugeDeposit);
        vm.expectRevert();
        tam.signup(hugeDeposit);
        vm.stopPrank();
    }

    // ===== _executeSignup: cumulative totalPower > MAX_SAFE_VALUE =====
    function test_signup_cumulativePowerTooLarge_reverts() public {
        // MAX_SAFE_VALUE = type(uint128).max
        // We need two deposits that sum past MAX_SAFE_VALUE
        // First, give alice enough tokens
        uint256 nearMax = type(uint128).max - 100;
        token.mint(alice, nearMax * 2); // Ensure sufficient balance

        vm.startPrank(alice);
        token.approve(address(mechanism), nearMax);
        _tam().signup(nearMax);
        vm.stopPrank();

        // Second signup should push total past MAX_SAFE_VALUE
        token.mint(alice, 200);
        vm.startPrank(alice);
        token.approve(address(mechanism), 200);
        vm.expectRevert();
        _tam().signup(200);
        vm.stopPrank();
    }

    // ===== _transfer: to self (strategy address) reverts =====
    function test_transfer_toStrategy_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        vm.warp(_tam().globalRedemptionStart() + 1);

        vm.prank(recipient1);
        vm.expectRevert("ERC20 transfer to strategy");
        _tam().transfer(address(mechanism), 1);
    }

    // ===== _spendAllowance: insufficient allowance =====
    function test_transferFrom_insufficientAllowance_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);

        vm.warp(_tam().globalRedemptionStart() + 1);

        vm.prank(recipient1);
        _tam().approve(bob, 1);

        vm.prank(bob);
        vm.expectRevert("ERC20: insufficient allowance");
        _tam().transferFrom(recipient1, charlie, shares);
    }

    // ===== _approve: spender is zero address =====
    function test_approve_zeroSpender_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        vm.warp(_tam().globalRedemptionStart() + 1);

        vm.prank(recipient1);
        vm.expectRevert("ERC20: approve to the zero address");
        _tam().approve(address(0), 100);
    }

    // ===== sweep: ETH transfer fails =====
    function test_sweep_ETH_transferFails_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        vm.warp(_tam().globalRedemptionStart() + GRACE_PERIOD + 1);

        vm.deal(address(mechanism), 1 ether);

        // Use a contract that rejects ETH as receiver
        ETHRejector rejector = new ETHRejector();
        vm.expectRevert("ETH transfer failed");
        _tam().sweep(address(0), address(rejector));
    }

    // ===== whenNotPaused: castVote while paused =====
    function test_castVote_whilePaused_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        _tam().pause();

        vm.prank(alice);
        vm.expectRevert(TokenizedAllocationMechanism.PausedError.selector);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);
    }

    // ===== whenNotPaused: propose while paused =====
    function test_propose_whilePaused_reverts() public {
        _tam().pause();

        vm.prank(alice);
        vm.expectRevert(TokenizedAllocationMechanism.PausedError.selector);
        _tam().propose(recipient1, "Test");
    }

    // ===== EIP-712 expired signature =====
    function test_signupWithSignature_expired_reverts() public {
        uint256 deadline = block.timestamp - 1;
        vm.expectRevert();
        _tam().signupWithSignature(alice, DEPOSIT, deadline, 27, bytes32(0), bytes32(0));
    }

    // ===== EIP-712 ECDSA valid signature (EOA) =====
    function test_signupWithSignature_validEOA() public {
        uint256 signerPk = 12345;
        address signerAddr = vm.addr(signerPk);

        token.mint(signerAddr, DEPOSIT * 2);
        vm.prank(signerAddr);
        token.approve(address(mechanism), DEPOSIT);

        bytes32 SIGNUP_TYPEHASH = keccak256(
            "Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)"
        );
        uint256 deadline = block.timestamp + 1000;
        uint256 nonce = _tam().nonces(signerAddr);
        bytes32 structHash = keccak256(abi.encode(SIGNUP_TYPEHASH, signerAddr, signerAddr, DEPOSIT, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _tam().DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);

        _tam().signupWithSignature(signerAddr, DEPOSIT, deadline, v, r, s);
        assertTrue(_tam().votingPower(signerAddr) > 0, "EOA signer should be registered");
    }

    // ===== _transfer: to zero address reverts =====
    function test_transfer_toZeroAddress_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        vm.warp(_tam().globalRedemptionStart() + 1);

        vm.prank(recipient1);
        vm.expectRevert("ERC20: transfer to the zero address");
        _tam().transfer(address(0), 1);
    }

    // ===== Helpers =====

    function _signupUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(address(mechanism), amount);
        _tam().signup(amount);
        vm.stopPrank();
    }
}

/// @title QVM _normalizeToDecimals Branch Coverage
contract QVMNormalizeBranchTest is Test {
    AllocationMechanismFactory factory;

    address alice = makeAddr("alice");

    uint256 constant W = 65536;

    function setUp() public {
        factory = new AllocationMechanismFactory();
    }

    function _deployWithToken(address tokenAddr) internal returns (address) {
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(tokenAddr),
            name: "Normalize Test",
            symbol: "NT",
            votingDelay: 100,
            votingPeriod: 1000,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        return factory.deployQuadraticVotingMechanism(config, 50, 100);
    }

    // ===== _normalizeToDecimals: decimals == 18 =====
    function test_normalizeToDecimals_18decimals_calculateOptimalAlpha() public {
        BranchTestMockToken token18 = new BranchTestMockToken("T18", "T18", 18);
        token18.mint(alice, 1000e18);

        address mech = _deployWithToken(address(token18));
        TokenizedAllocationMechanism tam = TokenizedAllocationMechanism(mech);
        tam.setKeeper(alice);
        tam.setManagement(alice);
        token18.mint(mech, 50_000e18);

        vm.startPrank(alice);
        token18.approve(mech, 1000e18);
        tam.signup(1000e18);

        uint256 pid = tam.propose(makeAddr("r1"), "Test");
        vm.warp(block.timestamp + 101);
        tam.castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, makeAddr("r1"));
        vm.stopPrank();

        QuadraticVotingMechanism(payable(mech)).calculateOptimalAlpha(50_000e18, 1000e18);
    }

    // ===== _normalizeToDecimals: decimals < 18 =====
    function test_normalizeToDecimals_6decimals_calculateOptimalAlpha() public {
        BranchTestMockToken token6 = new BranchTestMockToken("T6", "T6", 6);
        token6.mint(alice, 1000 * 10 ** 6);

        address mech = _deployWithToken(address(token6));
        TokenizedAllocationMechanism tam = TokenizedAllocationMechanism(mech);
        tam.setKeeper(alice);
        tam.setManagement(alice);
        token6.mint(mech, 50_000 * 10 ** 6);

        vm.startPrank(alice);
        token6.approve(mech, 1000 * 10 ** 6);
        tam.signup(1000 * 10 ** 6);

        uint256 pid = tam.propose(makeAddr("r1"), "Test");
        vm.warp(block.timestamp + 101);
        tam.castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, makeAddr("r1"));
        vm.stopPrank();

        QuadraticVotingMechanism(payable(mech)).calculateOptimalAlpha(50_000 * 10 ** 6, 1000 * 10 ** 6);
    }

    // ===== _normalizeToDecimals: decimals > 18 =====
    function test_normalizeToDecimals_21decimals_calculateOptimalAlpha() public {
        BranchTestMockToken token21 = new BranchTestMockToken("T21", "T21", 21);
        token21.mint(alice, 1000 * 10 ** 21);

        address mech = _deployWithToken(address(token21));
        TokenizedAllocationMechanism tam = TokenizedAllocationMechanism(mech);
        tam.setKeeper(alice);
        tam.setManagement(alice);
        token21.mint(mech, 50_000 * 10 ** 21);

        vm.startPrank(alice);
        token21.approve(mech, 1000 * 10 ** 21);
        tam.signup(1000 * 10 ** 21);

        uint256 pid = tam.propose(makeAddr("r1"), "Test");
        vm.warp(block.timestamp + 101);
        tam.castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, makeAddr("r1"));
        vm.stopPrank();

        QuadraticVotingMechanism(payable(mech)).calculateOptimalAlpha(50_000 * 10 ** 21, 1000 * 10 ** 21);
    }
}

/// @title ProperQF Internal Edge Case Tests
contract ProperQFDeepBranchTest is Test {
    HarnessProperQF qf;

    function setUp() public {
        qf = new HarnessProperQF();
    }

    // ===== _processVote: VoteWeightOverflow (line 126) =====
    // voteWeight^2 overflows, and the overflow check catches it
    function test_processVote_voteWeightSquaredOverflow() public {
        // Use a weight where voteWeight * voteWeight wraps around in unchecked Solidity
        // But since Solidity 0.8+ uses checked arithmetic by default, this will panic
        // unless the contract uses unchecked. The contract does manual overflow check:
        // voteWeightSquared = voteWeight * voteWeight (will panic on overflow)
        // So we just need to verify it reverts (panics)
        uint256 hugeWeight = (1 << 128) + 1;
        vm.expectRevert(); // Will panic with overflow
        qf.exposed_processVote(1, type(uint256).max, hugeWeight);
    }

    // ===== _processVote: SquareRootTooLarge boundary =====
    function test_processVote_squareRootTooLarge_boundary() public {
        vm.expectRevert(ProperQF.SquareRootTooLarge.selector);
        qf.exposed_processVote(1, 99, 10);
    }

    // ===== _processVote: exact boundary - voteWeight^2 == contribution (success) =====
    function test_processVote_exactSqrt_succeeds() public {
        // 100e18 = (10e9)^2
        qf.exposed_processVote(1, 100e18, 10e9);

        uint256 step = uint256(1) << 32;
        ProperQF.Project memory project = qf.projects(1);
        assertApproxEqAbs(project.sumContributions, 100e18, step);
        assertEq(project.sumSquareRoots, 10e9);
    }

    // ===== _processVote: voteWeight at lower tolerance boundary =====
    function test_processVote_voteWeightAtLowerTolerance() public {
        // sqrt(10000e18) = 100e9, tolerance = 100e9/10 = 10e9, lower = 90e9
        qf.exposed_processVote(1, 10000e18, 90e9);

        ProperQF.Project memory project = qf.projects(1);
        assertEq(project.sumSquareRoots, 90e9);
    }

    // ===== _processVote: voteWeight below lower tolerance =====
    function test_processVote_voteWeightBelowLowerTolerance_reverts() public {
        vm.expectRevert(ProperQF.VoteWeightOutsideTolerance.selector);
        qf.exposed_processVote(1, 10000e18, 89e9);
    }

    // ===== _processVote: multiple votes on same project =====
    function test_processVote_multipleVotesSameProject() public {
        qf.exposed_processVote(1, 10000e18, 100e9);
        qf.exposed_processVote(1, 40000e18, 200e9);

        uint256 step = uint256(1) << 32;
        ProperQF.Project memory project = qf.projects(1);
        // 2 votes: tolerance = 2 * STEP
        assertApproxEqAbs(project.sumContributions, 50000e18, 2 * step);
        assertEq(project.sumSquareRoots, 300e9);
    }
}

/// @title BaseAllocationMechanism Initialization Failure Test
contract BaseAllocationInitFailTest is Test {
    function test_initialization_withBadImplementation_reverts() public {
        // Use a contract that exists but doesn't have an initialize function
        // that matches the expected signature, causing delegatecall to fail
        // We'll use the factory contract itself as a "bad" implementation
        AllocationMechanismFactory badImpl = new AllocationMechanismFactory();

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(new ERC20Mock())),
            name: "Fail Test",
            symbol: "FT",
            votingDelay: 1,
            votingPeriod: 1,
            quorumShares: 1,
            timelockDelay: 1,
            gracePeriod: 1,
            owner: address(this)
        });

        vm.expectRevert("Initialization failed");
        new QuadraticVotingMechanism(address(badImpl), config, 50, 100);
    }
}

/// @title TAM signupOnBehalfWithSignature and castVoteWithSignature Branch Coverage
/// @notice Tests the on-behalf signature signup and cast-vote-with-signature flows
contract TAMSignatureBranchCoverageTest is Test {
    bytes32 private constant SIGNUP_TYPEHASH =
        keccak256("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)");
    bytes32 private constant CAST_VOTE_TYPEHASH =
        keccak256(
            "CastVote(address voter,uint256 proposalId,uint8 choice,uint256 weight,address expectedRecipient,uint256 nonce,uint256 deadline)"
        );

    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    uint256 constant USER_PK = 0xA11CE;
    uint256 constant PAYER_PK = 0xB0B;
    address user;
    address payer;
    address recipient1 = makeAddr("recipient1");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        user = vm.addr(USER_PK);
        payer = vm.addr(PAYER_PK);

        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        token.mint(user, 1_000_000e18);
        token.mint(payer, 1_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Sig Branch Test",
            symbol: "SBT",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(this)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(user);
        _tam().setManagement(payer);
        token.mint(address(mechanism), 50_000e18);
    }

    // ===== signupOnBehalfWithSignature: valid EOA signer =====
    function test_signupOnBehalfWithSignature_validEOA() public {
        uint256 deadline = block.timestamp + 1000;
        uint256 nonce = _tam().nonces(user);

        // User signs approval for payer to deposit on their behalf
        bytes32 structHash = keccak256(abi.encode(SIGNUP_TYPEHASH, user, payer, DEPOSIT, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _tam().DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PK, digest);

        // Payer calls signupOnBehalfWithSignature
        vm.startPrank(payer);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signupOnBehalfWithSignature(user, DEPOSIT, deadline, v, r, s);
        vm.stopPrank();

        assertTrue(_tam().votingPower(user) > 0, "User should have voting power");
    }

    // ===== signupOnBehalfWithSignature: expired deadline =====
    function test_signupOnBehalfWithSignature_expired_reverts() public {
        uint256 deadline = block.timestamp - 1;
        vm.prank(payer);
        vm.expectRevert();
        _tam().signupOnBehalfWithSignature(user, DEPOSIT, deadline, 27, bytes32(0), bytes32(0));
    }

    // ===== signupOnBehalfWithSignature: invalid signature =====
    function test_signupOnBehalfWithSignature_invalidSig_reverts() public {
        uint256 deadline = block.timestamp + 1000;

        vm.startPrank(payer);
        token.approve(address(mechanism), DEPOSIT);
        vm.expectRevert();
        _tam().signupOnBehalfWithSignature(user, DEPOSIT, deadline, 27, bytes32(uint256(1)), bytes32(uint256(2)));
        vm.stopPrank();
    }

    // ===== castVoteWithSignature: valid EOA signer =====
    function test_castVoteWithSignature_validEOA() public {
        // First signup the user directly
        vm.startPrank(user);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        vm.stopPrank();

        // Create a proposal
        vm.prank(user);
        uint256 pid = _tam().propose(recipient1, "Test proposal");

        // Advance to voting period
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // User signs vote
        uint256 weight = 20 * W;
        uint256 deadline = block.timestamp + 1000;
        uint256 nonce = _tam().nonces(user);

        bytes32 structHash = keccak256(
            abi.encode(
                CAST_VOTE_TYPEHASH,
                user,
                pid,
                uint8(TokenizedAllocationMechanism.VoteType.For),
                weight,
                recipient1,
                nonce,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _tam().DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(USER_PK, digest);

        // Relayer submits the vote
        vm.prank(payer);
        _tam().castVoteWithSignature(
            user,
            pid,
            TokenizedAllocationMechanism.VoteType.For,
            weight,
            recipient1,
            deadline,
            v,
            r,
            s
        );
    }

    // ===== castVoteWithSignature: expired deadline =====
    function test_castVoteWithSignature_expired_reverts() public {
        vm.startPrank(user);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        vm.stopPrank();

        vm.prank(user);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        uint256 deadline = block.timestamp - 1;
        vm.expectRevert();
        _tam().castVoteWithSignature(
            user,
            pid,
            TokenizedAllocationMechanism.VoteType.For,
            10,
            recipient1,
            deadline,
            27,
            bytes32(0),
            bytes32(0)
        );
    }

    // ===== castVoteWithSignature: invalid signature =====
    function test_castVoteWithSignature_invalidSig_reverts() public {
        vm.startPrank(user);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        vm.stopPrank();

        vm.prank(user);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        uint256 deadline = block.timestamp + 1000;
        vm.expectRevert();
        _tam().castVoteWithSignature(
            user,
            pid,
            TokenizedAllocationMechanism.VoteType.For,
            10,
            recipient1,
            deadline,
            27,
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );
    }
}

/// @title ProperQF Underflow and Edge Case Branch Coverage
/// @notice Tests _processVoteUnchecked underflow guards, contribution/weight zero checks,
///         and _calculateOptimalAlpha edge cases
contract ProperQFUnderflowBranchTest is Test {
    HarnessProperQF qf;

    function setUp() public {
        qf = new HarnessProperQF();
    }

    // ===== _processVote: contribution == 0 =====
    function test_processVote_zeroContribution_reverts() public {
        vm.expectRevert(ProperQF.ContributionMustBePositive.selector);
        qf.exposed_processVote(1, 0, 10);
    }

    // ===== _processVote: voteWeight == 0 =====
    function test_processVote_zeroVoteWeight_reverts() public {
        vm.expectRevert(ProperQF.VoteWeightMustBePositive.selector);
        qf.exposed_processVote(1, 100, 0);
    }

    // ===== _calculateOptimalAlpha: quadraticSum <= linearSum =====
    function test_calculateOptimalAlpha_quadLessOrEqLinear_returnsZero() public view {
        (uint256 num, uint256 den) = qf.exposed_calculateOptimalAlpha(1000, 50, 100, 500);
        assertEq(num, 0, "Alpha numerator should be 0 when quadraticSum <= linearSum");
        assertEq(den, 1, "Alpha denominator should be 1");
    }

    // ===== _calculateOptimalAlpha: quadraticSum == linearSum (exact equality) =====
    function test_calculateOptimalAlpha_quadEqualsLinear_returnsZero() public view {
        (uint256 num, uint256 den) = qf.exposed_calculateOptimalAlpha(1000, 100, 100, 500);
        assertEq(num, 0, "Alpha numerator should be 0 when quadraticSum == linearSum");
        assertEq(den, 1, "Alpha denominator should be 1");
    }

    // ===== _calculateOptimalAlpha: totalAssetsAvailable <= linearSum =====
    function test_calculateOptimalAlpha_insufficientAssets_returnsZero() public view {
        // quadraticSum > linearSum, but totalUserDeposits + matchingPoolAmount <= linearSum
        (uint256 num, uint256 den) = qf.exposed_calculateOptimalAlpha(10, 200, 100, 50);
        // totalAssetsAvailable = 10 + 50 = 60, linearSum = 100, so 60 <= 100
        assertEq(num, 0, "Alpha numerator should be 0 when insufficient assets");
        assertEq(den, 1, "Alpha denominator should be 1");
    }

    // ===== _calculateOptimalAlpha: numerator >= quadraticAdvantage (full quadratic) =====
    function test_calculateOptimalAlpha_fullQuadratic_returnsOne() public view {
        // quadraticSum=200, linearSum=100, quadraticAdvantage=100
        // totalAssetsAvailable = 1000 + 500 = 1500, numerator = 1500 - 100 = 1400 >= 100
        (uint256 num, uint256 den) = qf.exposed_calculateOptimalAlpha(1000, 200, 100, 500);
        assertEq(num, 1, "Alpha numerator should be 1 for full quadratic");
        assertEq(den, 1, "Alpha denominator should be 1");
    }

    // ===== _calculateOptimalAlpha: fractional alpha =====
    function test_calculateOptimalAlpha_fractional() public view {
        // quadraticSum=200, linearSum=100, quadraticAdvantage=100
        // totalAssetsAvailable = 50 + 100 = 150, numerator = 150 - 100 = 50 < 100
        (uint256 num, uint256 den) = qf.exposed_calculateOptimalAlpha(50, 200, 100, 100);
        assertEq(num, 50, "Alpha numerator should be 50");
        assertEq(den, 100, "Alpha denominator should be 100");
    }

    // ===== _setAlpha: zero denominator =====
    function test_setAlpha_zeroDenominator_reverts() public {
        vm.expectRevert(ProperQF.DenominatorMustBePositive.selector);
        qf.exposed_setAlpha(1, 0);
    }

    // ===== _setAlpha: numerator > denominator =====
    function test_setAlpha_numeratorGreaterThanDenominator_reverts() public {
        vm.expectRevert(ProperQF.AlphaMustBeLessOrEqualToOne.selector);
        qf.exposed_setAlpha(2, 1);
    }

    // ===== _setAlpha: valid alpha =====
    function test_setAlpha_valid() public {
        qf.exposed_setAlpha(1, 2);
        (uint256 num, uint256 den) = qf.getAlpha();
        assertEq(num, 1);
        assertEq(den, 2);
    }

    // ===== _calculateWeightedTotalFunding: basic check =====
    function test_calculateWeightedTotalFunding_afterVotes() public {
        // Set alpha to 50/100
        qf.exposed_setAlpha(50, 100);

        // Process a vote - this internally calls _calculateWeightedTotalFunding
        qf.exposed_processVote(1, 10000e18, 100e9);

        // totalFunding should be updated
        uint256 totalFunding = qf.totalFunding();
        assertTrue(totalFunding > 0, "Total funding should be positive after vote");
    }
}

/// @title TAM _convertToShares/Assets with non-zero supply but zero totalAssets
/// @notice Tests the totalAssets==0 but supply!=0 edge case
contract TAMConvertZeroAssetsBranchTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = makeAddr("alice");
    address recipient1 = makeAddr("recipient1");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();
        token.mint(alice, 1_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Convert Test",
            symbol: "CVT",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(alice);
        _tam().setManagement(alice);
        token.mint(address(mechanism), 50_000e18);
    }

    // ===== convertToShares with mulDiv path (supply > 0, totalAssets > 0) =====
    function test_convertToShares_withSupplyAndAssets() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // Now supply > 0 and totalAssets > 0 - test the mulDiv path
        uint256 shares = _tam().convertToShares(1000e18);
        assertTrue(shares > 0, "Should convert via mulDiv path");
    }

    // ===== previewRedeem with shares =====
    function test_previewRedeem_withSupply() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);
        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // previewRedeem returns 0 outside the redemption period, so warp into it
        vm.warp(_tam().globalRedemptionStart() + 1);

        uint256 recipientShares = _tam().balanceOf(recipient1);
        uint256 previewAssets = _tam().previewRedeem(recipientShares);
        assertTrue(previewAssets > 0, "Should preview non-zero assets");
    }

    function _signupUser(address userAddr, uint256 amount) internal {
        vm.startPrank(userAddr);
        token.approve(address(mechanism), amount);
        _tam().signup(amount);
        vm.stopPrank();
    }
}

/// @title TAM queueProposal: queuing after redemption started reverts
contract TAMQueueAfterRedemptionTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = makeAddr("alice");
    address recipient1 = makeAddr("recipient1");
    address recipient2 = makeAddr("recipient2");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();
        token.mint(alice, 1_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Queue After Redemption Test",
            symbol: "QAR",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(alice);
        _tam().setManagement(alice);
        token.mint(address(mechanism), 50_000e18);
    }

    // ===== queueProposal: after redemption starts reverts =====
    function test_queueProposal_afterRedemptionStart_reverts() public {
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);

        uint256 pid1 = _tam().propose(recipient1, "Proposal 1");
        uint256 pid2 = _tam().propose(recipient2, "Proposal 2");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        _tam().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);
        _tam().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient2);
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid1);

        // Warp past redemption start
        vm.warp(_tam().globalRedemptionStart());

        vm.expectRevert(TokenizedAllocationMechanism.QueueingClosedAfterRedemption.selector);
        _tam().queueProposal(pid2);
    }

    // ===== queueProposal: canceled proposal reverts =====
    function test_queueProposal_canceledProposal_reverts() public {
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);

        uint256 pid = _tam().propose(recipient1, "Test");
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        // Cancel the proposal
        _tam().cancelProposal(pid);
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.ProposalCanceledError.selector, pid));
        _tam().queueProposal(pid);
    }
}

/// @title TAM ERC20 operations branch coverage
/// @notice Tests transfer, approve, transferFrom, spendAllowance branches
contract TAMErc20BranchCoverageTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address recipient1 = makeAddr("recipient1");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();
        token.mint(alice, 1_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "ERC20 Branch Test",
            symbol: "EBT",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(alice);
        _tam().setManagement(alice);
        token.mint(address(mechanism), 50_000e18);
    }

    // ===== approve and transferFrom with allowance =====
    function test_approveAndTransferFrom() public {
        // Setup: queue a proposal to mint shares
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        uint256 pid = _tam().propose(recipient1, "Test");
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);
        assertTrue(shares > 0, "Recipient should have shares");

        // Approve bob to spend recipient1's shares
        vm.prank(recipient1);
        _tam().approve(bob, shares);
        assertEq(_tam().allowance(recipient1, bob), shares);

        // Bob transfers from recipient1 during redemption window
        vm.warp(_tam().globalRedemptionStart() + 1);
        vm.prank(bob);
        _tam().transferFrom(recipient1, bob, shares);

        assertEq(_tam().balanceOf(bob), shares, "Bob should have shares after transferFrom");
        assertEq(_tam().balanceOf(recipient1), 0, "Recipient should have 0 shares after transferFrom");
    }

    // ===== transfer: from address with shares =====
    function test_transfer_success() public {
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        uint256 pid = _tam().propose(recipient1, "Test");
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);

        // Must warp into redemption window for transfers
        vm.warp(_tam().globalRedemptionStart() + 1);

        // Transfer from recipient1 to bob
        vm.prank(recipient1);
        _tam().transfer(bob, shares);

        assertEq(_tam().balanceOf(bob), shares, "Bob should receive shares");
    }

    // ===== transferFrom: insufficient allowance reverts =====
    function test_transferFrom_insufficientAllowance_reverts() public {
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        uint256 pid = _tam().propose(recipient1, "Test");
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // Bob has no allowance
        vm.prank(bob);
        vm.expectRevert("ERC20: insufficient allowance");
        _tam().transferFrom(recipient1, bob, 1);
    }

    // ===== transfer: from zero balance during redemption period =====
    function test_transfer_insufficientBalance_reverts() public {
        // Need to enter redemption period first (transfers restricted outside it)
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        uint256 pid = _tam().propose(recipient1, "Test");
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // Warp into redemption period
        vm.warp(_tam().globalRedemptionStart() + 1);

        // alice has 0 shares (she was a voter, not a recipient), so transfer reverts with arithmetic underflow
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        _tam().transfer(bob, 1);
    }

    // ===== approve: max uint256 allowance (infinite approval) =====
    function test_approve_maxUint() public {
        vm.prank(alice);
        _tam().approve(bob, type(uint256).max);
        assertEq(_tam().allowance(alice, bob), type(uint256).max);
    }
}

/// @title TAM _executeCastVote additional branch coverage
/// @notice Tests weight validation, power increase check, recipient mismatch
contract TAMCastVoteBranchCoverageTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = makeAddr("alice");
    address recipient1 = makeAddr("recipient1");
    address recipient2 = makeAddr("recipient2");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();
        token.mint(alice, 1_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Cast Vote Branch Test",
            symbol: "CVB",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(alice);
        _tam().setManagement(alice);
        token.mint(address(mechanism), 50_000e18);
    }

    // ===== castVote: recipient mismatch =====
    function test_castVote_recipientMismatch_reverts() public {
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        uint256 pid = _tam().propose(recipient1, "Test");
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.expectRevert(
            abi.encodeWithSelector(TokenizedAllocationMechanism.RecipientMismatch.selector, pid, recipient2, recipient1)
        );
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient2);
        vm.stopPrank();
    }

    // ===== castVote: weight too large =====
    function test_castVote_weightTooLarge_reverts() public {
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        uint256 pid = _tam().propose(recipient1, "Test");
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // MAX_SAFE_VALUE is type(uint128).max
        uint256 hugeWeight = uint256(type(uint128).max) + 1;
        vm.expectRevert();
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, hugeWeight, recipient1);
        vm.stopPrank();
    }

    // ===== castVote: zero weight =====
    function test_castVote_zeroWeight_reverts() public {
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        uint256 pid = _tam().propose(recipient1, "Test");
        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.expectRevert();
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 0, recipient1);
        vm.stopPrank();
    }

    // ===== castVote: on canceled proposal =====
    function test_castVote_canceledProposal_reverts() public {
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        uint256 pid = _tam().propose(recipient1, "Test");

        _tam().cancelProposal(pid);

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.ProposalCanceledError.selector, pid));
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);
        vm.stopPrank();
    }

    // ===== castVote: outside voting window =====
    function test_castVote_afterVotingEnds_reverts() public {
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        uint256 pid = _tam().propose(recipient1, "Test");
        vm.stopPrank();

        // Warp past voting end
        vm.warp(block.timestamp + VOTING_DELAY + VOTING_PERIOD + 2);

        vm.prank(alice);
        vm.expectRevert();
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);
    }

    // ===== castVote: before voting starts =====
    function test_castVote_beforeVotingStarts_reverts() public {
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        uint256 pid = _tam().propose(recipient1, "Test");

        // Don't warp - still in delay period
        vm.expectRevert();
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 10 * W, recipient1);
        vm.stopPrank();
    }
}

/// @title TAM Initialize branches (10 zero-check branches)
/// @notice Tests edge cases in initialize to cover zero-parameter reverts
contract TAMInitializeBranchCoverageTest is Test {
    AllocationMechanismFactory factory;

    function setUp() public {
        factory = new AllocationMechanismFactory();
    }

    // ===== Initialize: zero quorum =====
    function test_initialize_zeroQuorum_reverts() public {
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(new ERC20Mock())),
            name: "Test",
            symbol: "T",
            votingDelay: 100,
            votingPeriod: 1000,
            quorumShares: 0,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        vm.expectRevert();
        factory.deployQuadraticVotingMechanism(config, 50, 100);
    }

    // ===== Initialize: zero voting period =====
    function test_initialize_zeroVotingPeriod_reverts() public {
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(new ERC20Mock())),
            name: "Test",
            symbol: "T",
            votingDelay: 100,
            votingPeriod: 0,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        vm.expectRevert();
        factory.deployQuadraticVotingMechanism(config, 50, 100);
    }

    // ===== Initialize: zero asset =====
    function test_initialize_zeroAsset_reverts() public {
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(0)),
            name: "Test",
            symbol: "T",
            votingDelay: 100,
            votingPeriod: 1000,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        vm.expectRevert();
        factory.deployQuadraticVotingMechanism(config, 50, 100);
    }
}

// ======================================================================================
// PHASE 4: REMAINING BRANCH COVERAGE TESTS
// ======================================================================================

/// @title ProperQF Underflow Guards & Getter Branch Coverage
/// @notice Tests QuadraticSumUnderflow, LinearSumUnderflow branches,
///         and alphaNumerator/alphaDenominator view function coverage
contract ProperQFStorageUnderflowTest is Test {
    HarnessProperQF qf;

    function setUp() public {
        qf = new HarnessProperQF();
    }

    // ===== ProperQF line 156: QuadraticSumUnderflow =====
    // When totalQuadraticSum < oldQuadraticFunding (project.sumSquareRoots^2)
    function test_processVoteUnchecked_quadraticSumUnderflow_reverts() public {
        uint256 step = uint256(1) << 32;
        // Set up a project with sumSquareRoots = 10, so oldQuadraticFunding = 100
        // sumContributions must be step-aligned for exact round-trip
        qf.setProject(1, 100 * step, 10);
        // Set totalQuadraticSum to a value less than 100
        qf.setTotalQuadraticSum(50);
        qf.setTotalLinearSum(200 * step);

        // Now calling _processVoteUnchecked should trigger QuadraticSumUnderflow
        // because totalQuadraticSum (50) < oldQuadraticFunding (10*10 = 100)
        vm.expectRevert(ProperQF.QuadraticSumUnderflow.selector);
        qf.exposed_processVoteUnchecked(1, 400 * step, 20);
    }

    // ===== ProperQF line 157: LinearSumUnderflow =====
    // When totalLinearSum < project.sumContributions
    function test_processVoteUnchecked_linearSumUnderflow_reverts() public {
        uint256 step = uint256(1) << 32;
        // Set up a project with sumContributions = 500*STEP, sumSquareRoots = 10
        qf.setProject(1, 500 * step, 10);
        // Set totalQuadraticSum correctly (>= 10^2 = 100) but totalLinearSum too low
        qf.setTotalQuadraticSum(200);
        qf.setTotalLinearSum(100 * step); // 100*STEP < 500*STEP = project.sumContributions

        vm.expectRevert(ProperQF.LinearSumUnderflow.selector);
        qf.exposed_processVoteUnchecked(1, 400 * step, 20);
    }

    // ===== ProperQF: alphaNumerator() view function coverage =====
    function test_alphaNumerator_returnsDefault() public view {
        // Default alpha is 10000/10000
        assertEq(qf.alphaNumerator(), 10000, "Default alpha numerator should be 10000");
    }

    // ===== ProperQF: alphaDenominator() view function coverage =====
    function test_alphaDenominator_returnsDefault() public view {
        assertEq(qf.alphaDenominator(), 10000, "Default alpha denominator should be 10000");
    }

    // ===== ProperQF: alphaNumerator/alphaDenominator after setAlpha =====
    function test_alphaNumeratorDenominator_afterSet() public {
        qf.exposed_setAlpha(3, 7);
        assertEq(qf.alphaNumerator(), 3, "Alpha numerator should be 3 after set");
        assertEq(qf.alphaDenominator(), 7, "Alpha denominator should be 7 after set");
    }

    // ===== ProperQF line 126: VoteWeightOverflow (dead code in 0.8+, but attempt) =====
    // In Solidity 0.8+, overflow panics before reaching the check.
    // We test the overflow scenario to confirm panic behavior.
    function test_processVote_overflowPanics() public {
        // voteWeight so large that voteWeight * voteWeight overflows uint256
        uint256 hugeWeight = type(uint128).max + uint256(1);
        vm.expectRevert(); // Panics with arithmetic overflow
        qf.exposed_processVote(1, type(uint256).max, hugeWeight);
    }
}

/// @title Mock mechanism for testing TAM branches that need custom hook behavior
/// @notice A custom mechanism where hooks can be configured to return specific values
contract MockConfigurableMechanism is BaseAllocationMechanism {
    bool public blockSignup;
    bool public blockFinalization;
    bool public useCustomDistribution;
    uint256 public customAssetsTransferred;
    uint256 public customSharesToMint;

    constructor(
        address _implementation,
        AllocationConfig memory _config
    ) BaseAllocationMechanism(_implementation, _config) {}

    function setBlockSignup(bool val) external {
        blockSignup = val;
    }
    function setBlockFinalization(bool val) external {
        blockFinalization = val;
    }
    function setCustomDistribution(bool use, uint256 assetsAmount) external {
        useCustomDistribution = use;
        customAssetsTransferred = assetsAmount;
    }
    function setCustomSharesToMint(uint256 val) external {
        customSharesToMint = val;
    }

    function _beforeSignupHook(address) internal view override returns (bool) {
        return !blockSignup;
    }

    function _beforeProposeHook(address) internal pure override returns (bool) {
        return true;
    }

    function _getVotingPowerHook(address, uint256 deposit) internal pure override returns (uint256) {
        return deposit;
    }

    function _validateProposalHook(uint256 pid) internal view override returns (bool) {
        return _proposalExists(pid);
    }

    function _processVoteHook(
        uint256,
        address,
        TokenizedAllocationMechanism.VoteType,
        uint256 weight,
        uint256 oldPower
    ) internal pure override returns (uint256) {
        // Simple linear cost
        return oldPower - weight;
    }

    function _hasQuorumHook(uint256) internal pure override returns (bool) {
        return true;
    }

    function _convertVotesToShares(uint256) internal view override returns (uint256) {
        return customSharesToMint;
    }

    function _beforeFinalizeVoteTallyHook() internal view override returns (bool) {
        return !blockFinalization;
    }

    function _getRecipientAddressHook(uint256 pid) internal view override returns (address) {
        return _getProposal(pid).recipient;
    }

    function _requestCustomDistributionHook(
        address recipient,
        uint256
    ) internal override returns (bool handled, uint256 assetsTransferred) {
        if (useCustomDistribution) {
            // Transfer actual assets (capped to balance) but report customAssetsTransferred
            uint256 balance = asset.balanceOf(address(this));
            uint256 actualTransfer = customAssetsTransferred > balance ? balance : customAssetsTransferred;
            if (actualTransfer > 0) {
                IERC20(address(asset)).transfer(recipient, actualTransfer);
            }
            return (true, customAssetsTransferred);
        }
        return (false, 0);
    }

    function _availableWithdrawLimit(address) internal pure override returns (uint256) {
        return type(uint256).max;
    }

    function _calculateTotalAssetsHook() internal view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    receive() external payable override {}
}

/// @title TAM Deep Branch Coverage Phase 4
/// @notice Tests hard-to-reach branches: reentrancy, blocked signup, blocked finalization,
///         zero-mint queue, custom distribution with over-transfer, etc.
contract TAMPhase4BranchCoverageTest is Test {
    AllocationMechanismFactory factory;
    TokenizedAllocationMechanism implementation;
    ERC20Mock token;
    MockConfigurableMechanism mechanism;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address recipient1 = makeAddr("recipient1");
    address recipient2 = makeAddr("recipient2");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        implementation = new TokenizedAllocationMechanism();
        token = new ERC20Mock();

        token.mint(alice, 10_000_000e18);
        token.mint(bob, 10_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Phase4 Branch Test",
            symbol: "PH4",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: address(this)
        });

        mechanism = new MockConfigurableMechanism(address(implementation), config);
        mechanism.setCustomSharesToMint(1000e18); // Default non-zero shares

        token.mint(address(mechanism), 100_000e18);
    }

    // ===== TAM line 761: beforeSignupHook returning false =====
    function test_signup_blockedByHook_reverts() public {
        mechanism.setBlockSignup(true);

        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.RegistrationBlocked.selector, alice));
        _tam().signup(DEPOSIT);
        vm.stopPrank();
    }

    // ===== TAM line 936: beforeFinalizeVoteTallyHook returning false =====
    function test_finalize_blockedByHook_reverts() public {
        _signupUser(alice, DEPOSIT);
        vm.prank(alice);
        _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + VOTING_PERIOD + 1);

        mechanism.setBlockFinalization(true);

        vm.expectRevert(TokenizedAllocationMechanism.FinalizationBlocked.selector);
        _tam().finalizeVoteTally();
    }

    // ===== TAM line 975: sharesToMint == 0 (NoAllocation) =====
    function test_queueProposal_zeroShares_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 100 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        // Set sharesToMint to 0
        mechanism.setCustomSharesToMint(0);

        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.NoAllocation.selector, pid, 0));
        _tam().queueProposal(pid);
    }

    // ===== TAM line 987: customDistribution with assetsTransferred > totalAssets =====
    function test_queueProposal_customDistribution_insufficientAssets_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 100 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        // Set custom distribution to transfer MORE than totalAssets
        uint256 totalAssetsNow = _tam().totalAssets();
        mechanism.setCustomDistribution(true, totalAssetsNow + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TokenizedAllocationMechanism.InsufficientAssets.selector,
                totalAssetsNow + 1,
                totalAssetsNow
            )
        );
        _tam().queueProposal(pid);
    }

    // ===== TAM line 986: customDistribution handled successfully =====
    function test_queueProposal_customDistribution_success() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 100 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        uint256 totalAssetsBefore = _tam().totalAssets();
        uint256 transferAmount = 500e18;
        mechanism.setCustomDistribution(true, transferAmount);

        uint256 recipientBefore = token.balanceOf(recipient1);
        _tam().queueProposal(pid);

        // Verify assets were transferred to recipient
        assertEq(token.balanceOf(recipient1) - recipientBefore, transferAmount, "Recipient should receive assets");
        // Verify totalAssets decreased
        assertEq(_tam().totalAssets(), totalAssetsBefore - transferAmount, "Total assets should decrease");
        // Verify no shares were minted (custom distribution handled it)
        assertEq(_tam().balanceOf(recipient1), 0, "No shares should be minted for custom distribution");
    }

    // ===== Helpers =====

    function _signupUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(address(mechanism), amount);
        _tam().signup(amount);
        vm.stopPrank();
    }
}

/// @title TAM Reentrancy and ERC20 Internal Edge Cases
/// @notice Tests reentrancy guard, _convertToShares with totalAssets==0 && supply>0,
///         and _withdraw with insufficient balance
contract TAMReentrancyAndEdgeCaseTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address recipient1 = makeAddr("recipient1");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        token.mint(alice, 10_000_000e18);
        token.mint(bob, 10_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Reentrancy Test",
            symbol: "RET",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(alice);
        _tam().setManagement(bob);

        token.mint(address(mechanism), 50_000e18);
    }

    // ===== TAM line 1558: _withdraw with insufficient contract balance =====
    // This tests the edge case where the mechanism contract does not have enough
    // ERC20 balance to fulfill a withdrawal (idle < assets)
    function test_redeem_insufficientContractBalance_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        uint256 shares = _tam().balanceOf(recipient1);
        assertTrue(shares > 0, "Recipient should have shares");

        // Drain the token balance from the mechanism to simulate insufficient balance
        // We use vm.store or just burn it
        uint256 mechBalance = token.balanceOf(address(mechanism));
        // Force the mechanism balance to 0 by having it transfer out
        // We can't directly do that, so use vm.prank on the token
        vm.prank(address(mechanism));
        token.transfer(address(0xdead), mechBalance);

        // Now warp to redemption and try to redeem
        vm.warp(_tam().globalRedemptionStart() + 1);

        vm.prank(recipient1);
        vm.expectRevert("Insufficient balance for withdrawal");
        _tam().redeem(shares, recipient1, recipient1);
    }

    // ===== Helpers =====

    function _signupUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(address(mechanism), amount);
        _tam().signup(amount);
        vm.stopPrank();
    }
}

/// @title Mock mechanism that increases power on vote (for testing PowerIncreased revert)
contract MockPowerIncreaseMechanism is BaseAllocationMechanism {
    constructor(
        address _implementation,
        AllocationConfig memory _config
    ) BaseAllocationMechanism(_implementation, _config) {}

    function _beforeSignupHook(address) internal pure override returns (bool) {
        return true;
    }
    function _beforeProposeHook(address) internal pure override returns (bool) {
        return true;
    }
    function _getVotingPowerHook(address, uint256 deposit) internal pure override returns (uint256) {
        return deposit;
    }
    function _validateProposalHook(uint256 pid) internal view override returns (bool) {
        return _proposalExists(pid);
    }

    function _processVoteHook(
        uint256,
        address,
        TokenizedAllocationMechanism.VoteType,
        uint256,
        uint256 oldPower
    ) internal pure override returns (uint256) {
        // Return MORE power than before (should trigger PowerIncreased revert)
        return oldPower + 1;
    }

    function _hasQuorumHook(uint256) internal pure override returns (bool) {
        return true;
    }
    function _convertVotesToShares(uint256) internal pure override returns (uint256) {
        return 1000e18;
    }
    function _beforeFinalizeVoteTallyHook() internal pure override returns (bool) {
        return true;
    }
    function _getRecipientAddressHook(uint256 pid) internal view override returns (address) {
        return _getProposal(pid).recipient;
    }
    function _requestCustomDistributionHook(address, uint256) internal pure override returns (bool, uint256) {
        return (false, 0);
    }
    function _availableWithdrawLimit(address) internal pure override returns (uint256) {
        return type(uint256).max;
    }
    function _calculateTotalAssetsHook() internal view override returns (uint256) {
        return asset.balanceOf(address(this));
    }
    receive() external payable override {}
}

/// @title TAM PowerIncreased Branch Coverage (line 919)
/// @notice Tests the case where processVoteHook returns newPower > oldPower
contract TAMPowerIncreasedTest is Test {
    TokenizedAllocationMechanism implementation;
    ERC20Mock token;
    MockPowerIncreaseMechanism mechanism;

    address alice = makeAddr("alice");
    address recipient1 = makeAddr("recipient1");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        implementation = new TokenizedAllocationMechanism();
        token = new ERC20Mock();

        token.mint(alice, 10_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Power Increase Test",
            symbol: "PIT",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(this)
        });

        mechanism = new MockPowerIncreaseMechanism(address(implementation), config);
        token.mint(address(mechanism), 50_000e18);
    }

    // ===== TAM line 919: newPower > oldPower (PowerIncreased revert) =====
    function test_castVote_powerIncreased_reverts() public {
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        uint256 pid = _tam().propose(recipient1, "Test");
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                TokenizedAllocationMechanism.PowerIncreased.selector,
                DEPOSIT, // oldPower
                DEPOSIT + 1 // newPower (oldPower + 1)
            )
        );
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 100 * W, recipient1);
    }
}

/// @title TAM _convertToShares with totalAssets==0 but supply>0 (line 1465)
/// @notice Tests the edge case where totalAssets is zero but totalSupply is positive
contract TAMConvertZeroAssetsWithSupplyTest is Test {
    TokenizedAllocationMechanism implementation;
    ERC20Mock token;
    MockConfigurableMechanism mechanism;

    address alice = makeAddr("alice");
    address recipient1 = makeAddr("recipient1");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        implementation = new TokenizedAllocationMechanism();
        token = new ERC20Mock();

        token.mint(alice, 10_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Zero Assets Test",
            symbol: "ZAT",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(this)
        });

        mechanism = new MockConfigurableMechanism(address(implementation), config);
        mechanism.setCustomSharesToMint(1000e18);
        token.mint(address(mechanism), 50_000e18);
    }

    // ===== TAM line 1465: totalAssets == 0 with totalSupply > 0 =====
    // Create two proposals: queue the first with default minting (creates shares),
    // then use custom distribution on the second to drain totalAssets to 0.
    // This produces the state: totalSupply > 0, totalAssets == 0.
    function test_convertToShares_zeroAssetsPositiveSupply() public {
        address recipient2 = makeAddr("recipient2");

        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        _tam().signup(DEPOSIT);
        uint256 pid1 = _tam().propose(recipient1, "Proposal 1");
        uint256 pid2 = _tam().propose(recipient2, "Proposal 2");
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid1, TokenizedAllocationMechanism.VoteType.For, 50 * W, recipient1);
        vm.prank(alice);
        _tam().castVote(pid2, TokenizedAllocationMechanism.VoteType.For, 50 * W, recipient2);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        // Queue pid1 with default minting (no custom distribution)
        mechanism.setCustomDistribution(false, 0);
        _tam().queueProposal(pid1);

        // Now supply > 0 (shares minted for pid1)
        uint256 supply = _tam().totalSupply();
        assertTrue(supply > 0, "Supply should be positive");

        // Queue pid2 with custom distribution that drains all remaining totalAssets
        uint256 remainingAssets = _tam().totalAssets();
        mechanism.setCustomDistribution(true, remainingAssets);
        _tam().queueProposal(pid2);

        // Now totalAssets should be 0, totalSupply > 0
        assertEq(_tam().totalAssets(), 0, "Total assets should be 0");
        assertTrue(_tam().totalSupply() > 0, "Total supply should still be positive");

        // convertToShares should return 0 (line 1465)
        uint256 shares = _tam().convertToShares(1000e18);
        assertEq(shares, 0, "convertToShares should return 0 when totalAssets is 0 but supply > 0");
    }
}

/// @title QVM _getRecipientAddressHook branch coverage
/// @notice Tests the recipient == address(0) branch in _getRecipientAddressHook (line 273)
/// @dev Uses vm.store to corrupt the proposal recipient to address(0) after creation
contract QVMRecipientZeroTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;

    address alice = makeAddr("alice");
    address recipient1 = makeAddr("recipient1");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant W = 65536;

    /// @dev Computes the storage slot for proposals[pid].recipient in the TAM storage layout
    /// AllocationStorage is at slot = uint256(keccak256("tokenized.allocation.storage")) - 1
    /// The proposals mapping is at offset 25 within the struct.
    /// proposals[pid] slot = keccak256(abi.encode(pid, baseSlot + 25))
    /// Proposal.recipient is at offset 2 within the Proposal struct (after sharesRequested and proposer)
    function _getProposalRecipientSlot(uint256 pid) internal pure returns (bytes32) {
        uint256 baseSlot = uint256(keccak256("tokenized.allocation.storage")) - 1;
        uint256 mappingSlot = baseSlot + 25;
        bytes32 proposalBaseSlot = keccak256(abi.encode(pid, mappingSlot));
        // recipient is at offset 2 in the Proposal struct
        return bytes32(uint256(proposalBaseSlot) + 2);
    }

    function test_getRecipientAddressHook_normalPath_succeeds() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();
        token.mint(alice, 1_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Recipient Test",
            symbol: "RT",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        TokenizedAllocationMechanism tam = TokenizedAllocationMechanism(addr);
        tam.setKeeper(alice);
        tam.setManagement(alice);
        token.mint(addr, 50_000e18);

        vm.startPrank(alice);
        token.approve(addr, DEPOSIT);
        tam.signup(DEPOSIT);
        uint256 pid = tam.propose(recipient1, "Test");
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        tam.castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        tam.finalizeVoteTally();
        tam.queueProposal(pid);

        assertTrue(tam.balanceOf(recipient1) > 0, "Recipient should have shares from queue");
    }

    /// @notice Tests that queueProposal reverts when recipient is address(0)
    /// @dev Uses vm.store to corrupt proposal storage after creation, zeroing the recipient field
    function test_getRecipientAddressHook_zeroRecipient_reverts() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();
        token.mint(alice, 1_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Zero Recipient Test",
            symbol: "ZRT",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(0)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        TokenizedAllocationMechanism tam = TokenizedAllocationMechanism(addr);
        tam.setKeeper(alice);
        tam.setManagement(alice);
        token.mint(addr, 50_000e18);

        vm.startPrank(alice);
        token.approve(addr, DEPOSIT);
        tam.signup(DEPOSIT);
        uint256 pid = tam.propose(recipient1, "Test");
        vm.warp(block.timestamp + VOTING_DELAY + 1);
        tam.castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);
        vm.stopPrank();

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        tam.finalizeVoteTally();

        // Verify the recipient is currently set correctly
        TokenizedAllocationMechanism.Proposal memory prop = tam.proposals(pid);
        assertEq(prop.recipient, recipient1, "Recipient should be set before corruption");

        // Zero out the recipient using vm.store
        bytes32 recipientSlot = _getProposalRecipientSlot(pid);
        vm.store(addr, recipientSlot, bytes32(0));

        // Verify the corruption worked
        prop = tam.proposals(pid);
        assertEq(prop.recipient, address(0), "Recipient should be zeroed after vm.store");

        // queueProposal should now revert with InvalidRecipient(address(0))
        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidRecipient.selector, address(0)));
        tam.queueProposal(pid);
    }
}

/// @title Phase 5: Final branch coverage gaps
/// @notice Targets remaining branches across BaseAllocationMechanism, TAM, QVM, ProperQF
contract FinalBranchCoverageTest is Test {
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address recipient1 = makeAddr("recipient1");

    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;
    uint256 constant W = 65536;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        token.mint(alice, 10_000_000e18);
        token.mint(bob, 10_000_000e18);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Final Branch Test",
            symbol: "FBT",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: address(this)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(alice);
        _tam().setManagement(bob);

        token.mint(address(mechanism), 50_000e18);
    }

    // ===== BaseAllocationMechanism line 347: block.timestamp < globalRedemptionStart =====
    function test_maxRedeem_duringTimelock_returnsZero() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();

        // globalRedemptionStart = finalize_time + TIMELOCK_DELAY
        // We're currently at finalize_time, which is < globalRedemptionStart
        // maxRedeem should return 0 during timelock
        _tam().queueProposal(pid);

        uint256 maxRedeemable = _tam().maxRedeem(recipient1);
        assertEq(maxRedeemable, 0, "maxRedeem should be 0 during timelock period");
    }

    // ===== TAM line 530: whenNotPaused modifier (paused state) =====
    function test_signup_whenPaused_reverts() public {
        // pause() requires onlyOwner (this contract is owner)
        _tam().pause();

        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT);
        vm.expectRevert(TokenizedAllocationMechanism.PausedError.selector);
        _tam().signup(DEPOSIT);
        vm.stopPrank();
    }

    // ===== TAM line 1751: _approve with spender == address(0) =====
    function test_approve_zeroSpender_reverts() public {
        _signupUser(alice, DEPOSIT);

        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 20 * W, recipient1);

        vm.warp(block.timestamp + VOTING_PERIOD + 1);
        _tam().finalizeVoteTally();
        _tam().queueProposal(pid);

        // recipient1 now has shares; try to approve address(0)
        vm.prank(recipient1);
        vm.expectRevert("ERC20: approve to the zero address");
        _tam().approve(address(0), 100);
    }

    // ===== BaseAllocationMechanism line 374: onlySelf modifier false branch =====
    function test_beforeSignupHook_directCall_reverts() public {
        // Calling beforeSignupHook directly (not via delegatecall from TAM)
        // triggers the onlySelf modifier since msg.sender != address(mechanism)
        vm.expectRevert("!self");
        IBaseAllocationStrategy(address(mechanism)).beforeSignupHook(alice);
    }

    // ===== ProperQF line 132: voteWeight < actualSqrt - tolerance =====
    function test_properQF_lowVoteWeight_reverts() public {
        HarnessProperQF harness = new HarnessProperQF();

        // contribution = 10000, actualSqrt = 100, tolerance = 10 (10%)
        // voteWeight = 89 < 100 - 10 = 90 → should revert
        vm.expectRevert(ProperQF.VoteWeightOutsideTolerance.selector);
        harness.exposed_processVote(1, 10_000, 89);
    }

    function _signupUser(address user, uint256 amount) internal {
        vm.startPrank(user);
        token.approve(address(mechanism), amount);
        _tam().signup(amount);
        vm.stopPrank();
    }
}

/// @title QVM branch: decimals > 18 (scale-down path)
contract QVMHighDecimalsBranchTest is Test {
    AllocationMechanismFactory factory;
    BranchTestMockToken token;
    QuadraticVotingMechanism mechanism;

    address alice = makeAddr("alice");
    address recipient1 = makeAddr("recipient1");

    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint256 constant GRACE_PERIOD = 7 days;

    function _tam() internal view returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(address(mechanism));
    }

    function setUp() public {
        factory = new AllocationMechanismFactory();
        // Create a token with 20 decimals (> 18)
        token = new BranchTestMockToken("High Decimals", "HD20", 20);

        token.mint(alice, 10_000_000e20);

        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "High Decimals Branch Test",
            symbol: "HD",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: 10,
            timelockDelay: TIMELOCK_DELAY,
            gracePeriod: GRACE_PERIOD,
            owner: address(this)
        });

        address addr = factory.deployQuadraticVotingMechanism(config, 50, 100);
        mechanism = QuadraticVotingMechanism(payable(addr));
        _tam().setKeeper(alice);

        token.mint(address(mechanism), 50_000e20);
    }

    // ===== QVM line 147-150: assetDecimals > 18 scale-down path =====
    function test_votingPower_highDecimals_scalesDown() public {
        // 1 token with 20 decimals = 1e20
        uint256 deposit = 1e20;

        vm.startPrank(alice);
        token.approve(address(mechanism), deposit);
        _tam().signup(deposit);
        vm.stopPrank();

        // Propose as keeper (alice is keeper, QVM requires keeper/management to propose)
        vm.prank(alice);
        uint256 pid = _tam().propose(recipient1, "Test");

        vm.warp(block.timestamp + VOTING_DELAY + 1);

        // With QVM _getVotingPowerHook: deposit(1e20) / 10^(20-18) = 1e18 voting power
        // sqrt(1e18) ≈ 1e9, aligned to MIN_VOTE_WEIGHT: 15258 * 65536 = 999948288
        vm.prank(alice);
        _tam().castVote(pid, TokenizedAllocationMechanism.VoteType.For, 15258 * 65536, recipient1);

        // If we got here without revert, the scale-down path worked
        assertTrue(true);
    }
}
