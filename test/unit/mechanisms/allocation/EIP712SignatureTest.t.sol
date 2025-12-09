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

/// @title EIP712 Signature Tests
/// @notice Comprehensive tests for EIP-2612 style signature functionality
/// @dev Tests signup and voting with signatures following EIP712 standard
contract EIP712SignatureTest is Test {
    // Constants
    bytes32 private constant TYPE_HASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant SIGNUP_TYPEHASH =
        keccak256("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)");
    bytes32 private constant CAST_VOTE_TYPEHASH =
        keccak256(
            "CastVote(address voter,uint256 proposalId,uint8 choice,uint256 weight,address expectedRecipient,uint256 nonce,uint256 deadline)"
        );
    string private constant EIP712_VERSION = "1";

    // Test contracts
    AllocationMechanismFactory factory;
    ERC20Mock token;
    QuadraticVotingMechanism mechanism;

    // Test actors with known private keys
    uint256 constant ALICE_PRIVATE_KEY = 0x1;
    uint256 constant BOB_PRIVATE_KEY = 0x2;
    uint256 constant CHARLIE_PRIVATE_KEY = 0x3;
    address alice;
    address bob;
    address charlie;
    address relayer = address(0x999);

    // Test parameters
    uint256 constant INITIAL_BALANCE = 10000 ether;
    uint256 constant DEPOSIT_AMOUNT = 1000 ether;
    uint256 constant VOTING_DELAY = 100;
    uint256 constant VOTING_PERIOD = 1000;
    uint256 constant QUORUM_SHARES = 100 ether;

    function setUp() public {
        // Derive addresses from private keys
        alice = vm.addr(ALICE_PRIVATE_KEY);
        bob = vm.addr(BOB_PRIVATE_KEY);
        charlie = vm.addr(CHARLIE_PRIVATE_KEY);

        // Deploy infrastructure
        factory = new AllocationMechanismFactory();
        token = new ERC20Mock();

        // Fund test accounts
        token.mint(alice, INITIAL_BALANCE);
        token.mint(bob, INITIAL_BALANCE);
        token.mint(charlie, INITIAL_BALANCE);
        vm.deal(relayer, 10 ether);

        // Deploy mechanism
        AllocationConfig memory config = AllocationConfig({
            asset: IERC20(address(token)),
            name: "Test Voting",
            symbol: "TEST",
            votingDelay: VOTING_DELAY,
            votingPeriod: VOTING_PERIOD,
            quorumShares: QUORUM_SHARES,
            timelockDelay: 1 days,
            gracePeriod: 7 days,
            owner: address(this)
        });

        address mechanismAddr = factory.deployQuadraticVotingMechanism(config, 1, 1);
        mechanism = QuadraticVotingMechanism(payable(mechanismAddr));
    }

    function _tokenized(address _mechanism) internal pure returns (TokenizedAllocationMechanism) {
        return TokenizedAllocationMechanism(_mechanism);
    }

    // ============ EIP712 Helper Functions ============

    function _computeDomainSeparator(string memory name, address verifyingContract) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    TYPE_HASH,
                    keccak256(bytes(name)),
                    keccak256(bytes(EIP712_VERSION)),
                    block.chainid,
                    verifyingContract
                )
            );
    }

    function _getSignupDigest(
        address user,
        uint256 deposit,
        uint256 nonce,
        uint256 deadline
    ) internal returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(SIGNUP_TYPEHASH, user, user, deposit, nonce, deadline));
        bytes32 domainSeparator = _tokenized(address(mechanism)).DOMAIN_SEPARATOR();
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _getCastVoteDigest(
        address voter,
        uint256 pid,
        uint8 choice,
        uint256 weight,
        address expectedRecipient,
        uint256 nonce,
        uint256 deadline
    ) internal returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(CAST_VOTE_TYPEHASH, voter, pid, choice, weight, expectedRecipient, nonce, deadline)
        );
        bytes32 domainSeparator = _tokenized(address(mechanism)).DOMAIN_SEPARATOR();
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function _signDigest(bytes32 digest, uint256 privateKey) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        (v, r, s) = vm.sign(privateKey, digest);
    }

    // ============ Domain Separator Tests ============

    function test_DomainSeparator_Computed() public {
        bytes32 expectedDomainSeparator = _computeDomainSeparator("Test Voting", address(mechanism));
        bytes32 actualDomainSeparator = _tokenized(address(mechanism)).DOMAIN_SEPARATOR();

        assertEq(actualDomainSeparator, expectedDomainSeparator, "Domain separator mismatch");
    }

    function test_DomainSeparator_ChainFork() public {
        // Get initial domain separator
        bytes32 initialDomainSeparator = _tokenized(address(mechanism)).DOMAIN_SEPARATOR();

        // Simulate chain fork by changing chain ID
        vm.chainId(31337 + 1);

        // Domain separator should be different now
        bytes32 newDomainSeparator = _tokenized(address(mechanism)).DOMAIN_SEPARATOR();
        assertTrue(initialDomainSeparator != newDomainSeparator, "Domain separator should change on fork");

        // Verify it matches expected calculation
        bytes32 expectedDomainSeparator = _computeDomainSeparator("Test Voting", address(mechanism));
        assertEq(newDomainSeparator, expectedDomainSeparator, "New domain separator incorrect");
    }

    // ============ Signup with Signature Tests ============

    function test_SignupWithSignature_Success() public {
        // Move to valid signup period
        vm.warp(block.timestamp + 1);

        // Prepare signature
        uint256 nonce = _tokenized(address(mechanism)).nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _getSignupDigest(alice, DEPOSIT_AMOUNT, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        // Approve tokens
        vm.prank(alice);
        token.approve(address(mechanism), DEPOSIT_AMOUNT);

        // Execute signup with signature
        _tokenized(address(mechanism)).signupWithSignature(alice, DEPOSIT_AMOUNT, deadline, v, r, s);

        // Verify results
        assertEq(_tokenized(address(mechanism)).votingPower(alice), DEPOSIT_AMOUNT, "Voting power incorrect");
        assertEq(token.balanceOf(alice), INITIAL_BALANCE - DEPOSIT_AMOUNT, "Token balance incorrect");
        assertEq(_tokenized(address(mechanism)).nonces(alice), nonce + 1, "Nonce not incremented");
    }

    function test_SignupWithSignature_ZeroDeposit() public {
        vm.warp(block.timestamp + 1);

        uint256 nonce = _tokenized(address(mechanism)).nonces(bob);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _getSignupDigest(bob, 0, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, BOB_PRIVATE_KEY);

        _tokenized(address(mechanism)).signupWithSignature(bob, 0, deadline, v, r, s);

        assertEq(_tokenized(address(mechanism)).votingPower(bob), 0, "Should have 0 voting power");
        assertEq(token.balanceOf(bob), INITIAL_BALANCE, "Balance should not change");
    }

    function test_SignupWithSignature_NonceIncrement() public {
        vm.warp(block.timestamp + 1);

        uint256 initialNonce = _tokenized(address(mechanism)).nonces(alice);

        // First signup
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _getSignupDigest(alice, 100 ether, initialNonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        vm.prank(alice);
        token.approve(address(mechanism), 100 ether);

        _tokenized(address(mechanism)).signupWithSignature(alice, 100 ether, deadline, v, r, s);

        assertEq(_tokenized(address(mechanism)).nonces(alice), initialNonce + 1, "Nonce should increment");
    }

    function test_SignupWithSignature_InvalidSignature() public {
        vm.warp(block.timestamp + 1);

        uint256 nonce = _tokenized(address(mechanism)).nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _getSignupDigest(alice, DEPOSIT_AMOUNT, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        // Create an invalid signature that will recover to address(0)
        v = 99; // Invalid v value
        r = bytes32(0);
        s = bytes32(0);

        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidSigner.selector, address(0), alice));
        _tokenized(address(mechanism)).signupWithSignature(alice, DEPOSIT_AMOUNT, deadline, v, r, s);
    }

    function test_SignupWithSignature_WrongSigner() public {
        vm.warp(block.timestamp + 1);

        uint256 nonce = _tokenized(address(mechanism)).nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _getSignupDigest(alice, DEPOSIT_AMOUNT, nonce, deadline);

        // Sign with Bob's key instead of Alice's
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, BOB_PRIVATE_KEY);

        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidSigner.selector, bob, alice));
        _tokenized(address(mechanism)).signupWithSignature(alice, DEPOSIT_AMOUNT, deadline, v, r, s);
    }

    function test_SignupWithSignature_ExpiredDeadline() public {
        vm.warp(block.timestamp + 1);

        uint256 nonce = _tokenized(address(mechanism)).nonces(alice);
        uint256 deadline = block.timestamp - 1; // Expired
        bytes32 digest = _getSignupDigest(alice, DEPOSIT_AMOUNT, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        vm.expectRevert(
            abi.encodeWithSelector(TokenizedAllocationMechanism.ExpiredSignature.selector, deadline, block.timestamp)
        );
        _tokenized(address(mechanism)).signupWithSignature(alice, DEPOSIT_AMOUNT, deadline, v, r, s);
    }

    function test_SignupWithSignature_ReplayAttack() public {
        vm.warp(block.timestamp + 1);

        uint256 nonce = _tokenized(address(mechanism)).nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _getSignupDigest(alice, 100 ether, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        vm.prank(alice);
        token.approve(address(mechanism), 200 ether);

        // First signup succeeds
        _tokenized(address(mechanism)).signupWithSignature(alice, 100 ether, deadline, v, r, s);

        // Try to replay the same signature
        vm.expectRevert(); // Will revert with wrong nonce
        _tokenized(address(mechanism)).signupWithSignature(alice, 100 ether, deadline, v, r, s);
    }

    function test_SignupWithSignature_RelayerExecution() public {
        vm.warp(block.timestamp + 1);

        uint256 nonce = _tokenized(address(mechanism)).nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _getSignupDigest(alice, DEPOSIT_AMOUNT, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        // Alice approves tokens
        vm.prank(alice);
        token.approve(address(mechanism), DEPOSIT_AMOUNT);

        // Relayer submits the transaction
        vm.prank(relayer);
        _tokenized(address(mechanism)).signupWithSignature(alice, DEPOSIT_AMOUNT, deadline, v, r, s);

        assertEq(_tokenized(address(mechanism)).votingPower(alice), DEPOSIT_AMOUNT, "Alice should have voting power");
    }

    // ============ Cast Vote with Signature Tests ============

    function test_CastVoteWithSignature_Success() public {
        // Setup: Alice signs up first
        vm.warp(block.timestamp + 1);
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT_AMOUNT);
        _tokenized(address(mechanism)).signup(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Create a proposal
        uint256 pid = _tokenized(address(mechanism)).propose(address(0x123), "Test proposal");

        // Move to voting phase
        vm.warp(block.timestamp + VOTING_DELAY);

        // Prepare vote signature
        uint256 nonce = _tokenized(address(mechanism)).nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        uint8 choice = uint8(TokenizedAllocationMechanism.VoteType.For);
        uint256 weight = 100;

        bytes32 digest = _getCastVoteDigest(alice, pid, choice, weight, address(0x123), nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        // Cast vote with signature
        _tokenized(address(mechanism)).castVoteWithSignature(
            alice,
            pid,
            TokenizedAllocationMechanism.VoteType.For,
            weight,
            address(0x123),
            deadline,
            v,
            r,
            s
        );

        // Verify vote was recorded
        assertEq(
            _tokenized(address(mechanism)).votingPower(alice),
            DEPOSIT_AMOUNT - weight * weight,
            "Voting power not reduced"
        );
        assertEq(_tokenized(address(mechanism)).nonces(alice), nonce + 1, "Nonce not incremented");
    }

    function test_CastVoteWithSignature_AllChoices() public {
        // Setup users and proposals
        vm.warp(block.timestamp + 1);

        // All users signup
        address[3] memory users = [alice, bob, charlie];
        uint256[3] memory privateKeys = [ALICE_PRIVATE_KEY, BOB_PRIVATE_KEY, CHARLIE_PRIVATE_KEY];

        for (uint i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            token.approve(address(mechanism), DEPOSIT_AMOUNT);
            _tokenized(address(mechanism)).signup(DEPOSIT_AMOUNT);
            vm.stopPrank();
        }

        // Create proposals
        uint256[3] memory pids;
        for (uint i = 0; i < 3; i++) {
            pids[i] = _tokenized(address(mechanism)).propose(address(uint160(0x100 + i)), "Proposal");
        }

        // Move to voting phase
        vm.warp(block.timestamp + VOTING_DELAY);

        // Test For vote type (QuadraticVotingMechanism only supports For votes)
        TokenizedAllocationMechanism.VoteType[3] memory voteTypes = [
            TokenizedAllocationMechanism.VoteType.For,
            TokenizedAllocationMechanism.VoteType.For,
            TokenizedAllocationMechanism.VoteType.For
        ];

        for (uint i = 0; i < 3; i++) {
            // Scope variables to reduce stack pressure
            {
                uint256 nonce = _tokenized(address(mechanism)).nonces(users[i]);
                uint256 deadline = block.timestamp + 1 hours;
                uint8 choice = uint8(voteTypes[i]);
                uint256 weight = 50;

                bytes32 digest = _getCastVoteDigest(
                    users[i],
                    pids[i],
                    choice,
                    weight,
                    address(uint160(0x100 + i)),
                    nonce,
                    deadline
                );
                (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, privateKeys[i]);

                _tokenized(address(mechanism)).castVoteWithSignature(
                    users[i],
                    pids[i],
                    voteTypes[i],
                    weight,
                    address(uint160(0x100 + i)),
                    deadline,
                    v,
                    r,
                    s
                );
            }

            // Verify votes were recorded - each user voted with weight 50, so cost is 50*50 = 2500
            assertEq(
                _tokenized(address(mechanism)).votingPower(users[i]),
                DEPOSIT_AMOUNT - 50 * 50,
                "Voting power not reduced correctly for quadratic voting"
            );
        }
    }

    function test_CastVoteWithSignature_InvalidSignature() public {
        // Setup
        vm.warp(block.timestamp + 1);
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT_AMOUNT);
        _tokenized(address(mechanism)).signup(DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 pid = _tokenized(address(mechanism)).propose(address(0x123), "Test");

        vm.warp(block.timestamp + VOTING_DELAY);

        uint256 nonce = _tokenized(address(mechanism)).nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _getCastVoteDigest(alice, pid, 1, 100, address(0x123), nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        // Create an invalid signature that will recover to address(0)
        v = 99; // Invalid v value
        r = bytes32(0);
        s = bytes32(0);

        vm.expectRevert(abi.encodeWithSelector(TokenizedAllocationMechanism.InvalidSigner.selector, address(0), alice));
        _tokenized(address(mechanism)).castVoteWithSignature(
            alice,
            pid,
            TokenizedAllocationMechanism.VoteType.For,
            100,
            address(0x123),
            deadline,
            v,
            r,
            s
        );
    }

    function test_CastVoteWithSignature_ExpiredDeadline() public {
        // Setup
        vm.warp(block.timestamp + 1);
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT_AMOUNT);
        _tokenized(address(mechanism)).signup(DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 pid = _tokenized(address(mechanism)).propose(address(0x123), "Test");

        vm.warp(block.timestamp + VOTING_DELAY);

        uint256 nonce = _tokenized(address(mechanism)).nonces(alice);
        uint256 deadline = block.timestamp - 1; // Expired
        bytes32 digest = _getCastVoteDigest(alice, pid, 1, 100, address(0x123), nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        vm.expectRevert(
            abi.encodeWithSelector(TokenizedAllocationMechanism.ExpiredSignature.selector, deadline, block.timestamp)
        );
        _tokenized(address(mechanism)).castVoteWithSignature(
            alice,
            pid,
            TokenizedAllocationMechanism.VoteType.For,
            100,
            address(0x123),
            deadline,
            v,
            r,
            s
        );
    }

    function test_CastVoteWithSignature_ReplayAttack() public {
        // Setup
        vm.warp(block.timestamp + 1);
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT_AMOUNT);
        _tokenized(address(mechanism)).signup(DEPOSIT_AMOUNT);
        vm.stopPrank();

        uint256 pid1 = _tokenized(address(mechanism)).propose(address(0x123), "Test 1");
        // Create second proposal but we don't use pid2 in this test

        vm.warp(block.timestamp + VOTING_DELAY);

        uint256 nonce = _tokenized(address(mechanism)).nonces(alice);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _getCastVoteDigest(alice, pid1, 1, 100, address(0x123), nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        // First vote succeeds
        _tokenized(address(mechanism)).castVoteWithSignature(
            alice,
            pid1,
            TokenizedAllocationMechanism.VoteType.For,
            100,
            address(0x123),
            deadline,
            v,
            r,
            s
        );

        // Try to replay - should fail due to nonce mismatch
        vm.expectRevert();
        _tokenized(address(mechanism)).castVoteWithSignature(
            alice,
            pid1,
            TokenizedAllocationMechanism.VoteType.For,
            100,
            address(0x123),
            deadline,
            v,
            r,
            s
        );
    }

    // ============ Integration Tests ============

    function test_E2E_SignupAndVote() public {
        // Complete flow using only signatures
        vm.warp(block.timestamp + 1);

        // Signup with signature
        uint256 signupNonce = _tokenized(address(mechanism)).nonces(alice);
        uint256 signupDeadline = block.timestamp + 1 hours;
        bytes32 signupDigest = _getSignupDigest(alice, DEPOSIT_AMOUNT, signupNonce, signupDeadline);
        (uint8 sv, bytes32 sr, bytes32 ss) = _signDigest(signupDigest, ALICE_PRIVATE_KEY);

        vm.prank(alice);
        token.approve(address(mechanism), DEPOSIT_AMOUNT);

        vm.prank(relayer);
        _tokenized(address(mechanism)).signupWithSignature(alice, DEPOSIT_AMOUNT, signupDeadline, sv, sr, ss);

        // Create proposal (still needs direct call)
        uint256 pid = _tokenized(address(mechanism)).propose(address(0x123), "E2E Test");

        // Vote with signature
        vm.warp(block.timestamp + VOTING_DELAY);

        uint256 voteNonce = _tokenized(address(mechanism)).nonces(alice);
        uint256 voteDeadline = block.timestamp + 1 hours;
        bytes32 voteDigest = _getCastVoteDigest(alice, pid, 1, 200, address(0x123), voteNonce, voteDeadline);
        (uint8 vv, bytes32 vr, bytes32 vs) = _signDigest(voteDigest, ALICE_PRIVATE_KEY);

        vm.prank(relayer);
        _tokenized(address(mechanism)).castVoteWithSignature(
            alice,
            pid,
            TokenizedAllocationMechanism.VoteType.For,
            200,
            address(0x123),
            voteDeadline,
            vv,
            vr,
            vs
        );

        // Verify final state
        assertEq(
            _tokenized(address(mechanism)).votingPower(alice),
            DEPOSIT_AMOUNT - 200 * 200,
            "Voting power incorrect"
        );
        assertEq(_tokenized(address(mechanism)).nonces(alice), signupNonce + 2, "Nonce should increment twice");
    }

    function test_E2E_MixedMethods() public {
        vm.warp(block.timestamp + 1);

        // Alice uses direct signup
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT_AMOUNT);
        _tokenized(address(mechanism)).signup(DEPOSIT_AMOUNT);
        vm.stopPrank();

        // Bob uses signature signup
        uint256 bobNonce = _tokenized(address(mechanism)).nonces(bob);
        uint256 bobDeadline = block.timestamp + 1 hours;
        bytes32 bobDigest = _getSignupDigest(bob, DEPOSIT_AMOUNT, bobNonce, bobDeadline);
        (uint8 bv, bytes32 br, bytes32 bs) = _signDigest(bobDigest, BOB_PRIVATE_KEY);

        vm.prank(bob);
        token.approve(address(mechanism), DEPOSIT_AMOUNT);

        _tokenized(address(mechanism)).signupWithSignature(bob, DEPOSIT_AMOUNT, bobDeadline, bv, br, bs);

        // Create proposal
        uint256 pid = _tokenized(address(mechanism)).propose(address(0x123), "Mixed test");

        // Voting phase
        vm.warp(block.timestamp + VOTING_DELAY);

        // Alice votes directly
        vm.prank(alice);
        _tokenized(address(mechanism)).castVote(pid, TokenizedAllocationMechanism.VoteType.For, 100, address(0x123));

        // Bob votes with signature
        uint256 bobVoteNonce = _tokenized(address(mechanism)).nonces(bob);
        uint256 bobVoteDeadline = block.timestamp + 1 hours;
        bytes32 bobVoteDigest = _getCastVoteDigest(bob, pid, 1, 150, address(0x123), bobVoteNonce, bobVoteDeadline);
        (uint8 vv, bytes32 vr, bytes32 vs) = _signDigest(bobVoteDigest, BOB_PRIVATE_KEY);

        _tokenized(address(mechanism)).castVoteWithSignature(
            bob,
            pid,
            TokenizedAllocationMechanism.VoteType.For,
            150,
            address(0x123),
            bobVoteDeadline,
            vv,
            vr,
            vs
        );

        // Verify both votes recorded - Alice voted 100 (cost 100^2=10000), Bob voted 150 (cost 150^2=22500)
        assertEq(
            _tokenized(address(mechanism)).votingPower(alice),
            DEPOSIT_AMOUNT - 100 * 100,
            "Alice voting power not reduced correctly"
        );
        assertEq(
            _tokenized(address(mechanism)).votingPower(bob),
            DEPOSIT_AMOUNT - 150 * 150,
            "Bob voting power not reduced correctly"
        );
    }

    function test_NonceSharing() public {
        vm.warp(block.timestamp + 1);

        uint256 initialNonce = _tokenized(address(mechanism)).nonces(alice);

        // Signup increments nonce
        uint256 signupDeadline = block.timestamp + 1 hours;
        bytes32 signupDigest = _getSignupDigest(alice, 100 ether, initialNonce, signupDeadline);
        (uint8 sv, bytes32 sr, bytes32 ss) = _signDigest(signupDigest, ALICE_PRIVATE_KEY);

        vm.prank(alice);
        token.approve(address(mechanism), 100 ether);

        _tokenized(address(mechanism)).signupWithSignature(alice, 100 ether, signupDeadline, sv, sr, ss);

        assertEq(_tokenized(address(mechanism)).nonces(alice), initialNonce + 1, "Nonce should increment after signup");

        // Create proposal for voting
        uint256 pid = _tokenized(address(mechanism)).propose(address(0x123), "Test");

        // Vote uses next nonce
        vm.warp(block.timestamp + VOTING_DELAY);

        uint256 voteNonce = _tokenized(address(mechanism)).nonces(alice);
        assertEq(voteNonce, initialNonce + 1, "Vote should use incremented nonce");

        uint256 voteDeadline = block.timestamp + 1 hours;
        bytes32 voteDigest = _getCastVoteDigest(alice, pid, 1, 50, address(0x123), voteNonce, voteDeadline);
        (uint8 vv, bytes32 vr, bytes32 vs) = _signDigest(voteDigest, ALICE_PRIVATE_KEY);

        _tokenized(address(mechanism)).castVoteWithSignature(
            alice,
            pid,
            TokenizedAllocationMechanism.VoteType.For,
            50,
            address(0x123),
            voteDeadline,
            vv,
            vr,
            vs
        );

        assertEq(_tokenized(address(mechanism)).nonces(alice), initialNonce + 2, "Nonce should increment after vote");
    }

    // ============ View Function Tests ============

    function test_Nonces_View() public {
        assertEq(_tokenized(address(mechanism)).nonces(alice), 0, "Initial nonce should be 0");
        assertEq(_tokenized(address(mechanism)).nonces(bob), 0, "Initial nonce should be 0");

        // Use a signature to increment nonce
        vm.warp(block.timestamp + 1);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _getSignupDigest(alice, 0, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, ALICE_PRIVATE_KEY);

        _tokenized(address(mechanism)).signupWithSignature(alice, 0, deadline, v, r, s);

        assertEq(_tokenized(address(mechanism)).nonces(alice), 1, "Nonce should be 1 after signup");
        assertEq(_tokenized(address(mechanism)).nonces(bob), 0, "Bob's nonce should still be 0");
    }

    function test_DomainSeparator_View() public {
        bytes32 domainSeparator = _tokenized(address(mechanism)).DOMAIN_SEPARATOR();
        assertTrue(domainSeparator != bytes32(0), "Domain separator should not be zero");

        // Verify it's accessible and consistent
        bytes32 domainSeparator2 = _tokenized(address(mechanism)).DOMAIN_SEPARATOR();
        assertEq(domainSeparator, domainSeparator2, "Domain separator should be consistent");
    }

    // ============ Gas Comparison Tests ============

    function test_GasComparison_DirectVsSignature() public {
        vm.warp(block.timestamp + 1);

        // Measure direct signup gas
        vm.startPrank(alice);
        token.approve(address(mechanism), DEPOSIT_AMOUNT * 2);
        uint256 gasStart = gasleft();
        _tokenized(address(mechanism)).signup(DEPOSIT_AMOUNT);
        uint256 directSignupGas = gasStart - gasleft();
        vm.stopPrank();

        // Measure signature signup gas
        uint256 nonce = _tokenized(address(mechanism)).nonces(bob);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = _getSignupDigest(bob, DEPOSIT_AMOUNT, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signDigest(digest, BOB_PRIVATE_KEY);

        vm.prank(bob);
        token.approve(address(mechanism), DEPOSIT_AMOUNT);

        gasStart = gasleft();
        _tokenized(address(mechanism)).signupWithSignature(bob, DEPOSIT_AMOUNT, deadline, v, r, s);
        uint256 signatureSignupGas = gasStart - gasleft();

        console.log("Direct signup gas:", directSignupGas);
        console.log("Signature signup gas:", signatureSignupGas);
        console.log(
            "Additional gas for signature:",
            signatureSignupGas > directSignupGas ? signatureSignupGas - directSignupGas : 0
        );
    }
}
