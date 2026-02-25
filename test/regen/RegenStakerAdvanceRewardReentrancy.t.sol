// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AccessMode } from "src/constants.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { Staker } from "staker/Staker.sol";
import { MockEarningPowerCalculator } from "test/mocks/MockEarningPowerCalculator.sol";
import { MockERC20Staking } from "test/mocks/MockERC20Staking.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";

interface ITransferFromHook {
    function onTransferFromHook() external;
}

contract ReenteringMockERC20Staking is MockERC20Staking {
    bool public reenterEnabled;
    uint256 public transferFromCount;

    constructor() MockERC20Staking(18) {}

    function setReenterEnabled(bool _enabled) external {
        reenterEnabled = _enabled;
    }

    function transferFrom(address from, address to, uint256 value) public override(ERC20, IERC20) returns (bool) {
        transferFromCount++;
        bool ok = super.transferFrom(from, to, value);

        // Trigger reentry on the second transferFrom in stakeWithAdvanceReward:
        // deposit is already created and lock must already be active.
        if (reenterEnabled && transferFromCount == 2 && from.code.length > 0) {
            ITransferFromHook(from).onTransferFromHook();
        }

        return ok;
    }
}

contract AdvanceRewardReentrantAttacker is ITransferFromHook {
    RegenStakerWithoutDelegateSurrogateVotes public immutable staker;
    ReenteringMockERC20Staking public immutable token;

    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryRevertData;

    uint256 public attackAmount;
    uint256 public attackAdvance;

    constructor(RegenStakerWithoutDelegateSurrogateVotes _staker, ReenteringMockERC20Staking _token) {
        staker = _staker;
        token = _token;
    }

    function execute(uint256 _amount, uint256 _advance) external {
        attackAmount = _amount;
        attackAdvance = _advance;

        token.approve(address(staker), _amount);
        staker.stakeWithAdvanceReward(_amount, address(0xBEEF), address(this), _advance, _advance);
    }

    function onTransferFromHook() external override {
        require(msg.sender == address(token), "only token");
        if (reentryAttempted) return;

        reentryAttempted = true;
        try staker.withdraw(Staker.DepositIdentifier.wrap(0), attackAmount - attackAdvance) {
            reentrySucceeded = true;
        } catch (bytes memory data) {
            reentryRevertData = data;
        }
    }
}

contract RegenStakerAdvanceRewardReentrancyTest is Test {
    ReenteringMockERC20Staking public token;
    MockEarningPowerCalculator public earningPowerCalculator;
    RegenStakerWithoutDelegateSurrogateVotes public staker;
    AddressSet public allocationAllowset;

    address public admin = makeAddr("admin");
    uint128 public constant REWARD_DURATION = 30 days;

    function setUp() public {
        token = new ReenteringMockERC20Staking();
        earningPowerCalculator = new MockEarningPowerCalculator();

        vm.startPrank(admin);
        allocationAllowset = new AddressSet();
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
    }

    function test_stakeWithAdvanceReward_reentrantWithdrawBlockedByPreSetLock() public {
        AdvanceRewardReentrantAttacker attacker = new AdvanceRewardReentrantAttacker(staker, token);

        uint256 amount = 100e18;
        uint256 advance = 5e18;

        token.mint(address(attacker), amount);
        token.setReenterEnabled(true);

        attacker.execute(amount, advance);

        assertTrue(attacker.reentryAttempted(), "reentry should have been attempted");
        assertFalse(attacker.reentrySucceeded(), "reentrant withdraw must fail");
        assertEq(
            _selector(attacker.reentryRevertData()),
            RegenStakerBase.CommitmentLockActive.selector,
            "wrong revert selector"
        );

        Staker.DepositIdentifier depositId = Staker.DepositIdentifier.wrap(0);
        (uint96 balance, , , , , , ) = staker.deposits(depositId);
        assertEq(balance, amount - advance, "deposit should remain locked and staked");
        assertGt(staker.advanceRewardLockEnd(depositId), block.timestamp, "commitment lock should be active");
        assertEq(token.balanceOf(address(attacker)), advance, "attacker should only keep advance payout");
    }

    function _selector(bytes memory data) internal pure returns (bytes4 sel) {
        if (data.length < 4) return bytes4(0);
        assembly {
            sel := mload(add(data, 32))
        }
    }
}
