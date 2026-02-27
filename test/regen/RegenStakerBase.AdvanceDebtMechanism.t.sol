// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { RegenStaker } from "src/regen/RegenStaker.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { ISwapRouter } from "src/utils/vendor/uniswap/ISwapRouter.sol";
import { Staker } from "staker/Staker.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { MockEarningPowerCalculator } from "test/mocks/MockEarningPowerCalculator.sol";
import { TokenizedAllocationMechanism } from "src/mechanisms/TokenizedAllocationMechanism.sol";
import { OctantQFMechanism } from "src/mechanisms/mechanism/OctantQFMechanism.sol";
import { AllocationConfig } from "src/mechanisms/BaseAllocationMechanism.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";

// ═══════════════════════════════════════════════════════════════════════
// Helpers
// ═══════════════════════════════════════════════════════════════════════

interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

/// @notice Minimal Uniswap V3 router mock — mints rewardToken to recipient
contract MockSwapRouter is ISwapRouter {
    using SafeERC20 for IERC20;

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable override returns (uint256 amountOut) {
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountIn; // 1:1 swap
        IMintableToken(params.tokenOut).mint(params.recipient, amountOut);
    }

    function exactInput(ExactInputParams calldata) external payable override returns (uint256) { revert("unsupported"); }
    function exactOutputSingle(ExactOutputSingleParams calldata) external payable override returns (uint256) { revert("unsupported"); }
    function exactOutput(ExactOutputParams calldata) external payable override returns (uint256) { revert("unsupported"); }
    function uniswapV3SwapCallback(int256, int256, bytes calldata) external pure override { revert("unsupported"); }
}

// ═══════════════════════════════════════════════════════════════════════
// Same-token: RegenStaker (with surrogates) + OctantQFMechanism
// ═══════════════════════════════════════════════════════════════════════

/// @title Advance Debt + Mechanism integration — same-token, surrogate variant
/// @notice Proves the full advance → contribute → earn → claim cycle works end-to-end
///         with a real OctantQFMechanism when STAKE_TOKEN == REWARD_TOKEN.
contract AdvanceDebtMechanismSameTokenTest is Test {
    RegenStaker public staker;
    MockERC20Staking public token;
    MockEarningPowerCalculator public earningPowerCalculator;
    OctantQFMechanism public mechanism;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public user;
    uint256 private userPk;
    address public delegatee = makeAddr("delegatee");

    uint256 public constant STAKE_AMOUNT = 200e18;
    uint256 public constant REWARD_AMOUNT = 10_000e18;
    uint128 public constant REWARD_DURATION = 30 days;

    function setUp() public {
        (user, userPk) = makeAddrAndKey("user");

        token = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();

        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        AllocationConfig memory cfg = AllocationConfig({
            asset: IERC20(address(token)),
            name: "TestMech",
            symbol: "TM",
            votingDelay: 1,
            votingPeriod: 30 days,
            quorumShares: 1,
            timelockDelay: 1,
            gracePeriod: 100,
            owner: admin
        });
        mechanism = new OctantQFMechanism(
            address(impl), cfg, 1, 1,
            IAddressSet(address(0)), IAddressSet(address(0)), AccessMode.NONE
        );

        vm.startPrank(admin);
        allocationAllowset = new AddressSet();
        allocationAllowset.add(address(mechanism));
        vm.stopPrank();

        vm.prank(admin);
        staker = new RegenStaker(
            IERC20(address(token)),
            token,
            earningPowerCalculator,
            0,
            admin,
            REWARD_DURATION,
            1e18,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        // Fund user and seed reward pool
        token.mint(user, STAKE_AMOUNT);
        token.mint(address(staker), REWARD_AMOUNT);

        vm.startPrank(admin);
        staker.setRewardNotifier(admin, true);
        staker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();
    }

    /// @dev EIP-712 helper — builds a contribute signature for the user
    function _signContribute(
        address signer,
        uint256 pk,
        uint256 amount
    ) internal returns (uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(mechanism)).DOMAIN_SEPARATOR();
        uint256 nonce = TokenizedAllocationMechanism(address(mechanism)).nonces(signer);
        deadline = block.timestamp + 1 days;

        bytes32 typeHash = keccak256("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typeHash, signer, address(staker), amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    // ─── Core integration: advance → contribute immediately ───

    function test_advanceCredit_enablesImmediateContribute_sameToken() public {
        uint256 advanceAmount = (STAKE_AMOUNT * 5) / 100; // 10e18

        vm.startPrank(user);
        token.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stakeWithAdvanceReward(
            STAKE_AMOUNT, delegatee, user, advanceAmount, advanceAmount
        );
        vm.stopPrank();

        // Advance is credited, not transferred
        assertEq(token.balanceOf(user), 0, "no tokens should leave to user");
        assertEq(staker.unclaimedReward(depositId), advanceAmount, "advance credited as unclaimed");
        assertEq(staker.advanceDebt(depositId), advanceAmount, "debt matches credit");

        // Contribute the full advance credit to the mechanism — this is the whole point
        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _signContribute(user, userPk, advanceAmount);

        uint256 mechBalBefore = token.balanceOf(address(mechanism));
        vm.prank(user);
        uint256 contributed = staker.contribute(depositId, address(mechanism), advanceAmount, deadline, v, r, s);

        assertEq(contributed, advanceAmount, "full advance should be contributable");
        assertEq(token.balanceOf(address(mechanism)) - mechBalBefore, advanceAmount, "mechanism should receive tokens");

        // User has voting power in the mechanism
        uint256 votingPower = TokenizedAllocationMechanism(address(mechanism)).votingPower(user);
        assertGt(votingPower, 0, "user should have voting power after contribute");

        // Debt persists after contribute
        assertEq(staker.advanceDebt(depositId), advanceAmount, "debt unaffected by contribute");
    }

    // ─── Full cycle: advance → contribute → earn → claim (reduced by debt) ───

    function test_fullCycle_advanceContributeEarnClaim_sameToken() public {
        uint256 advanceAmount = (STAKE_AMOUNT * 5) / 100;

        // Stake with advance
        vm.startPrank(user);
        token.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stakeWithAdvanceReward(
            STAKE_AMOUNT, delegatee, user, advanceAmount, advanceAmount
        );
        vm.stopPrank();

        // Contribute advance credit
        {
            (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _signContribute(user, userPk, advanceAmount);
            vm.prank(user);
            staker.contribute(depositId, address(mechanism), advanceAmount, deadline, v, r, s);
        }

        // Earn rewards
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        uint256 unclaimed = staker.unclaimedReward(depositId);
        require(unclaimed > advanceAmount, "must earn more than debt");

        // Claim — debt is deducted
        uint256 userBalBefore = token.balanceOf(user);
        vm.prank(user);
        uint256 claimed = staker.claimReward(depositId);

        assertEq(claimed, unclaimed - advanceAmount, "payout reduced by debt");
        assertEq(token.balanceOf(user) - userBalBefore, claimed, "actual transfer matches claim");
        assertEq(staker.advanceDebt(depositId), 0, "debt fully repaid");

        // Second claim — no debt, normal payout
        vm.warp(block.timestamp + REWARD_DURATION / 4);
        uint256 unclaimed2 = staker.unclaimedReward(depositId);

        vm.prank(user);
        uint256 claimed2 = staker.claimReward(depositId);
        assertEq(claimed2, unclaimed2, "no debt deduction on subsequent claim");
    }

    // ─── Solvency: notifyRewardAmount works after advance + contribute ───

    function test_solvencyInvariant_afterAdvanceAndContribute_sameToken() public {
        uint256 advanceAmount = (STAKE_AMOUNT * 5) / 100;

        vm.startPrank(user);
        token.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stakeWithAdvanceReward(
            STAKE_AMOUNT, delegatee, user, advanceAmount, advanceAmount
        );
        vm.stopPrank();

        // Contribute full advance
        {
            (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _signContribute(user, userPk, advanceAmount);
            vm.prank(user);
            staker.contribute(depositId, address(mechanism), advanceAmount, deadline, v, r, s);
        }

        // Warp past reward end, then schedule new rewards
        vm.warp(block.timestamp + REWARD_DURATION + 1);

        uint256 newReward = 5_000e18;
        token.mint(address(staker), newReward);

        // This must not revert — solvency invariant holds
        vm.prank(admin);
        staker.notifyRewardAmount(newReward);
    }

    // ─── Compound with debt deduction ───

    function test_compoundRewards_deductsDebt_sameToken() public {
        uint256 advanceAmount = (STAKE_AMOUNT * 5) / 100;

        vm.startPrank(user);
        token.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stakeWithAdvanceReward(
            STAKE_AMOUNT, delegatee, user, advanceAmount, advanceAmount
        );
        vm.stopPrank();

        // Earn rewards
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        uint256 unclaimedBefore = staker.unclaimedReward(depositId);
        require(unclaimedBefore > advanceAmount, "must earn more than debt");

        (uint96 balBefore, , , , , , ) = staker.deposits(depositId);

        vm.prank(user);
        uint256 compounded = staker.compoundRewards(depositId);

        assertEq(compounded, unclaimedBefore - advanceAmount, "compound reduced by debt");
        (uint96 balAfter, , , , , , ) = staker.deposits(depositId);
        assertEq(balAfter, balBefore + compounded, "balance increased by compounded amount");
        assertEq(staker.advanceDebt(depositId), 0, "debt fully repaid");
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Different-token: RegenStaker (with surrogates) + swap + mechanism
// ═══════════════════════════════════════════════════════════════════════

/// @title Advance Debt + Mechanism integration — different tokens, surrogate variant
/// @notice When STAKE_TOKEN != REWARD_TOKEN, advance goes through swap router.
///         The swapped reward tokens stay in contract and are credited as unclaimed.
contract AdvanceDebtMechanismDifferentTokenTest is Test {
    RegenStaker public staker;
    MockERC20Staking public stakeToken;
    MockERC20Staking public rewardToken;
    MockEarningPowerCalculator public earningPowerCalculator;
    MockSwapRouter public swapRouter;
    OctantQFMechanism public mechanism;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public user;
    uint256 private userPk;
    address public delegatee = makeAddr("delegatee");

    uint256 public constant STAKE_AMOUNT = 200e18;
    uint256 public constant ADVANCE_AMOUNT = 10e18;
    uint256 public constant REWARD_AMOUNT = 10_000e18;
    uint128 public constant REWARD_DURATION = 30 days;

    function setUp() public {
        (user, userPk) = makeAddrAndKey("user");

        stakeToken = new MockERC20Staking(18);
        rewardToken = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();
        swapRouter = new MockSwapRouter();

        // Mechanism uses REWARD_TOKEN as asset
        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        AllocationConfig memory cfg = AllocationConfig({
            asset: IERC20(address(rewardToken)),
            name: "TestMech",
            symbol: "TM",
            votingDelay: 1,
            votingPeriod: 30 days,
            quorumShares: 1,
            timelockDelay: 1,
            gracePeriod: 100,
            owner: admin
        });
        mechanism = new OctantQFMechanism(
            address(impl), cfg, 1, 1,
            IAddressSet(address(0)), IAddressSet(address(0)), AccessMode.NONE
        );

        vm.startPrank(admin);
        allocationAllowset = new AddressSet();
        allocationAllowset.add(address(mechanism));
        vm.stopPrank();

        vm.prank(admin);
        staker = new RegenStaker(
            IERC20(address(rewardToken)),
            stakeToken,
            earningPowerCalculator,
            0,
            admin,
            REWARD_DURATION,
            1e18,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        vm.prank(admin);
        staker.setAdvanceSwapConfig(address(swapRouter), 3000);

        stakeToken.mint(user, STAKE_AMOUNT);
        rewardToken.mint(address(staker), REWARD_AMOUNT);

        vm.startPrank(admin);
        staker.setRewardNotifier(admin, true);
        staker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();
    }

    function _signContribute(
        address signer,
        uint256 pk,
        uint256 amount
    ) internal returns (uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(mechanism)).DOMAIN_SEPARATOR();
        uint256 nonce = TokenizedAllocationMechanism(address(mechanism)).nonces(signer);
        deadline = block.timestamp + 1 days;

        bytes32 typeHash = keccak256("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typeHash, signer, address(staker), amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    function test_advanceCredit_enablesImmediateContribute_differentToken() public {
        vm.startPrank(user);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stakeWithAdvanceReward(
            STAKE_AMOUNT, delegatee, user, ADVANCE_AMOUNT, ADVANCE_AMOUNT
        );
        vm.stopPrank();

        // Swapped reward tokens stay in contract, credited as unclaimed
        assertEq(rewardToken.balanceOf(user), 0, "no reward tokens should go to user");
        assertEq(staker.unclaimedReward(depositId), ADVANCE_AMOUNT, "advance credited as unclaimed");
        assertEq(staker.advanceDebt(depositId), ADVANCE_AMOUNT, "debt matches credit");

        // Contribute the advance credit to the mechanism
        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _signContribute(user, userPk, ADVANCE_AMOUNT);

        uint256 mechBalBefore = rewardToken.balanceOf(address(mechanism));
        vm.prank(user);
        uint256 contributed = staker.contribute(depositId, address(mechanism), ADVANCE_AMOUNT, deadline, v, r, s);

        assertEq(contributed, ADVANCE_AMOUNT, "full advance should be contributable");
        assertEq(rewardToken.balanceOf(address(mechanism)) - mechBalBefore, ADVANCE_AMOUNT, "mechanism received tokens");

        uint256 votingPower = TokenizedAllocationMechanism(address(mechanism)).votingPower(user);
        assertGt(votingPower, 0, "user should have voting power");
        assertEq(staker.advanceDebt(depositId), ADVANCE_AMOUNT, "debt persists after contribute");
    }

    function test_fullCycle_differentToken() public {
        vm.startPrank(user);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stakeWithAdvanceReward(
            STAKE_AMOUNT, delegatee, user, ADVANCE_AMOUNT, ADVANCE_AMOUNT
        );
        vm.stopPrank();

        // Contribute advance
        {
            (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _signContribute(user, userPk, ADVANCE_AMOUNT);
            vm.prank(user);
            staker.contribute(depositId, address(mechanism), ADVANCE_AMOUNT, deadline, v, r, s);
        }

        // Earn rewards
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        uint256 unclaimed = staker.unclaimedReward(depositId);
        require(unclaimed > ADVANCE_AMOUNT, "must earn more than debt");

        // Claim — debt deducted
        vm.prank(user);
        uint256 claimed = staker.claimReward(depositId);

        assertEq(claimed, unclaimed - ADVANCE_AMOUNT, "payout reduced by debt");
        assertEq(rewardToken.balanceOf(user), claimed, "actual transfer matches");
        assertEq(staker.advanceDebt(depositId), 0, "debt fully repaid");
    }

    function test_solvencyInvariant_differentToken() public {
        vm.startPrank(user);
        stakeToken.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stakeWithAdvanceReward(
            STAKE_AMOUNT, delegatee, user, ADVANCE_AMOUNT, ADVANCE_AMOUNT
        );
        vm.stopPrank();

        // Contribute full advance
        {
            (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _signContribute(user, userPk, ADVANCE_AMOUNT);
            vm.prank(user);
            staker.contribute(depositId, address(mechanism), ADVANCE_AMOUNT, deadline, v, r, s);
        }

        vm.warp(block.timestamp + REWARD_DURATION + 1);

        uint256 newReward = 5_000e18;
        rewardToken.mint(address(staker), newReward);

        // Must not revert
        vm.prank(admin);
        staker.notifyRewardAmount(newReward);
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Same-token: RegenStakerWithoutDelegateSurrogateVotes + mechanism
// ═══════════════════════════════════════════════════════════════════════

/// @title Advance Debt + Mechanism integration — same-token, no-delegate variant
/// @notice The no-delegate variant holds stakes in the main contract.
///         This tests that the solvency check (totalStaked + carryOver) still works
///         when advance credit is added to totalRewards.
contract AdvanceDebtMechanismNoDelegateTest is Test {
    RegenStakerWithoutDelegateSurrogateVotes public staker;
    MockERC20Staking public token;
    MockEarningPowerCalculator public earningPowerCalculator;
    OctantQFMechanism public mechanism;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    address public user;
    uint256 private userPk;
    address public delegatee = makeAddr("delegatee");

    uint256 public constant STAKE_AMOUNT = 200e18;
    uint256 public constant REWARD_AMOUNT = 10_000e18;
    uint128 public constant REWARD_DURATION = 30 days;

    function setUp() public {
        (user, userPk) = makeAddrAndKey("user");

        token = new MockERC20Staking(18);
        earningPowerCalculator = new MockEarningPowerCalculator();

        TokenizedAllocationMechanism impl = new TokenizedAllocationMechanism();
        AllocationConfig memory cfg = AllocationConfig({
            asset: IERC20(address(token)),
            name: "TestMech",
            symbol: "TM",
            votingDelay: 1,
            votingPeriod: 30 days,
            quorumShares: 1,
            timelockDelay: 1,
            gracePeriod: 100,
            owner: admin
        });
        mechanism = new OctantQFMechanism(
            address(impl), cfg, 1, 1,
            IAddressSet(address(0)), IAddressSet(address(0)), AccessMode.NONE
        );

        vm.startPrank(admin);
        allocationAllowset = new AddressSet();
        allocationAllowset.add(address(mechanism));
        vm.stopPrank();

        vm.prank(admin);
        staker = new RegenStakerWithoutDelegateSurrogateVotes(
            IERC20(address(token)),
            IERC20(address(token)),
            earningPowerCalculator,
            0,
            admin,
            REWARD_DURATION,
            1e18,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            IAddressSet(address(allocationAllowset))
        );

        token.mint(user, STAKE_AMOUNT);
        token.mint(address(staker), REWARD_AMOUNT);

        vm.startPrank(admin);
        staker.setRewardNotifier(admin, true);
        staker.notifyRewardAmount(REWARD_AMOUNT);
        vm.stopPrank();
    }

    function _signContribute(
        address signer,
        uint256 pk,
        uint256 amount
    ) internal returns (uint256 deadline, uint8 v, bytes32 r, bytes32 s) {
        bytes32 domainSeparator = TokenizedAllocationMechanism(address(mechanism)).DOMAIN_SEPARATOR();
        uint256 nonce = TokenizedAllocationMechanism(address(mechanism)).nonces(signer);
        deadline = block.timestamp + 1 days;

        bytes32 typeHash = keccak256("Signup(address user,address payer,uint256 deposit,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typeHash, signer, address(staker), amount, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    function test_advanceCredit_enablesImmediateContribute_noDelegate() public {
        uint256 advanceAmount = (STAKE_AMOUNT * 5) / 100;

        vm.startPrank(user);
        token.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stakeWithAdvanceReward(
            STAKE_AMOUNT, delegatee, user, advanceAmount, advanceAmount
        );
        vm.stopPrank();

        assertEq(token.balanceOf(user), 0, "no tokens to user");
        assertEq(staker.unclaimedReward(depositId), advanceAmount, "advance credited");
        assertEq(staker.advanceDebt(depositId), advanceAmount, "debt matches");

        (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _signContribute(user, userPk, advanceAmount);

        uint256 mechBalBefore = token.balanceOf(address(mechanism));
        vm.prank(user);
        uint256 contributed = staker.contribute(depositId, address(mechanism), advanceAmount, deadline, v, r, s);

        assertEq(contributed, advanceAmount, "full advance contributable");
        assertEq(token.balanceOf(address(mechanism)) - mechBalBefore, advanceAmount, "mechanism got tokens");
        assertGt(TokenizedAllocationMechanism(address(mechanism)).votingPower(user), 0, "user has voting power");
    }

    function test_solvencyInvariant_noDelegate_sameToken() public {
        uint256 advanceAmount = (STAKE_AMOUNT * 5) / 100;

        vm.startPrank(user);
        token.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stakeWithAdvanceReward(
            STAKE_AMOUNT, delegatee, user, advanceAmount, advanceAmount
        );
        vm.stopPrank();

        // Contribute full advance
        {
            (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _signContribute(user, userPk, advanceAmount);
            vm.prank(user);
            staker.contribute(depositId, address(mechanism), advanceAmount, deadline, v, r, s);
        }

        // Verify accounting:
        // contract balance = netStake (in contract) + REWARD_AMOUNT + advanceAmount - advanceAmount (contributed)
        //                   = 190e18 + 10_000e18
        // required = totalStaked + (totalRewards - totalClaimedRewards)
        //          = 190e18 + (10_000e18 + 10e18 - 10e18) = 190e18 + 10_000e18
        // Balance == required, so any new notify with fresh tokens should work.

        vm.warp(block.timestamp + REWARD_DURATION + 1);

        uint256 newReward = 5_000e18;
        token.mint(address(staker), newReward);

        vm.prank(admin);
        staker.notifyRewardAmount(newReward);
    }

    function test_fullCycle_noDelegate() public {
        uint256 advanceAmount = (STAKE_AMOUNT * 5) / 100;

        vm.startPrank(user);
        token.approve(address(staker), STAKE_AMOUNT);
        Staker.DepositIdentifier depositId = staker.stakeWithAdvanceReward(
            STAKE_AMOUNT, delegatee, user, advanceAmount, advanceAmount
        );
        vm.stopPrank();

        // Contribute
        {
            (uint256 deadline, uint8 v, bytes32 r, bytes32 s) = _signContribute(user, userPk, advanceAmount);
            vm.prank(user);
            staker.contribute(depositId, address(mechanism), advanceAmount, deadline, v, r, s);
        }

        // Earn
        vm.warp(block.timestamp + REWARD_DURATION / 2);

        uint256 unclaimed = staker.unclaimedReward(depositId);
        require(unclaimed > advanceAmount, "must earn more than debt");

        // Claim — debt deducted
        uint256 userBalBefore = token.balanceOf(user);
        vm.prank(user);
        uint256 claimed = staker.claimReward(depositId);

        assertEq(claimed, unclaimed - advanceAmount, "payout reduced by debt");
        assertEq(token.balanceOf(user) - userBalBefore, claimed, "transfer matches");
        assertEq(staker.advanceDebt(depositId), 0, "debt repaid");
    }
}
