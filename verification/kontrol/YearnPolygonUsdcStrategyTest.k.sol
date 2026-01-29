// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IStrategy } from "src/zodiac-core/interfaces/IStrategy.sol";
import "src/errors.sol";

import { TestERC20 } from "test/kontrol/TestERC20.k.sol";
import { Setup } from "test/kontrol/Setup.k.sol";
import { MockYieldSource } from "test/kontrol/MockYieldSource.k.sol";
import "test/kontrol/StrategyStateSlots.k.sol";

struct ProofState {
    uint256 assetOwnerBalance;
    uint256 assetYieldSourceBalance;
    uint256 assetStrategyBalance;
    uint256 stateTotalAssets;
    uint256 stateTotalSupply;
    uint256 receiverStrategyShares;
    uint256 strategyYieldSourcesShares;
}

struct UserInfo {
    uint256 strategyBalance;
    uint256 lockupTime;
    uint256 unlockTime;
    uint256 lockedShares;
    uint8 isRageQuit;
}

contract YearnPolygonUsdcStrategyKontrolTest is Setup {
    ProofState private preState;
    ProofState private posState;

    function setupSymbolicUser(address user) internal returns (UserInfo memory info) {
        info.strategyBalance = freshUInt256Bounded("userStrategyBalance");
        _storeMappingUInt256(address(strategy), BALANCES_SLOT, uint256(uint160(user)), 0, info.strategyBalance);

        info.lockupTime = freshUInt256Bounded("userLockupTime");
        _storeMappingUInt256(address(strategy), VOLUNTARY_LOCKUPS_SLOT, uint256(uint160(user)), 0, info.lockupTime);

        info.unlockTime = freshUInt256Bounded("userUnlockTime");
        _storeMappingUInt256(address(strategy), VOLUNTARY_LOCKUPS_SLOT, uint256(uint160(user)), 1, info.unlockTime);

        info.lockedShares = freshUInt256Bounded("userLockupShares");
        _storeMappingUInt256(address(strategy), VOLUNTARY_LOCKUPS_SLOT, uint256(uint160(user)), 2, info.lockedShares);

        info.isRageQuit = freshUInt8();
        _storeMappingData(address(strategy), VOLUNTARY_LOCKUPS_SLOT, uint256(uint160(user)), 3, 0, 1, info.isRageQuit);
    }

    function assumeNotShutdown() internal {
        // Assign shutdown slot to 0
        _storeData(address(strategy), SHUTDOWN_SLOT, SHUTDOWN_OFFSET, SHUTDOWN_WIDTH, 0);
    }

    function assumeNonReentrant() internal {
        // Assign entered slot to 0
        _storeData(address(strategy), ENTERED_SLOT, ENTERED_OFFSET, ENTERED_WIDTH, 0);
    }

    function depositAssumptions(
        uint256 amount,
        address receiver,
        UserInfo memory receiverInfo,
        uint256 lockupDuration
    ) internal {
        vm.assume(receiver != address(0));
        vm.assume(receiver != address(strategy));
        vm.assume(receiver != address(dragonRouter));

        assumeNotShutdown();
        assumeNonReentrant();

        vm.assume(receiverInfo.isRageQuit == 0);

        vm.assume(receiver == safeOwner || receiverInfo.strategyBalance == 0);

        vm.assume(amount > 0);

        uint256 assetOwnerBalance = freshUInt256Bounded("assetOwnerBalance");
        vm.assume(0 < assetOwnerBalance);
        TestERC20(_asset).mint(safeOwner, assetOwnerBalance);

        vm.assume(amount == type(uint256).max || amount < assetOwnerBalance);

        if (lockupDuration > 0) {
            uint256 minimumLockupDuration = _loadUInt256(address(strategy), MINIMUM_LOCKUP_DURATION_SLOT);
            if (receiverInfo.unlockTime <= block.timestamp) {
                vm.assume(lockupDuration > minimumLockupDuration);
                // Overflow assumption
                vm.assume(block.timestamp <= type(uint256).max - lockupDuration);
            } else {
                vm.assume(receiverInfo.unlockTime <= type(uint256).max - lockupDuration);
                vm.assume(receiverInfo.unlockTime + lockupDuration >= block.timestamp + minimumLockupDuration);
            }
        }
    }

    function withdrawAssumptions(
        address sender,
        uint256 assets,
        address receiver,
        address _owner,
        uint256 maxLoss
    ) internal {
        vm.assume(sender != address(0));

        assumeNonReentrant();

        UserInfo memory owner = setupSymbolicUser(_owner);

        // If owner has rage quit then the shares should be unlocked otherwise withdraw reverts with
        // DragonTokenizedStrategy__SharesStillLocked()
        vm.assume(owner.isRageQuit != 0 || owner.unlockTime <= block.timestamp);

        vm.assume(receiver != address(0));
        vm.assume(maxLoss <= 10_000); // MAX_BPS = 10_000

        vm.assume(0 < assets);

        // If the owner has rage quit then we should avoid underflow when updating owner.lockedShares -= assets
        vm.assume(owner.isRageQuit == 0 || assets <= owner.lockedShares);
    }

    function _snapshop(ProofState storage state, address receiver) internal {
        state.assetOwnerBalance = TestERC20(_asset).balanceOf(safeOwner);
        state.assetYieldSourceBalance = TestERC20(_asset).balanceOf(YIELD_SOURCE);
        state.assetStrategyBalance = TestERC20(_asset).balanceOf(address(strategy));
        state.stateTotalAssets = strategy.totalAssets();
        state.stateTotalSupply = strategy.totalSupply();
        state.receiverStrategyShares = strategy.balanceOf(receiver);
        state.strategyYieldSourcesShares = IStrategy(YIELD_SOURCE).balanceOf(address(strategy));
    }

    /*//////////////////////////////////////////////////////////////
                            STATE CHANGES
    //////////////////////////////////////////////////////////////*/
    function assertDepositStateChanges(uint256 amount) internal view {
        assertEq(posState.assetOwnerBalance, preState.assetOwnerBalance - amount);
        assertEq(
            posState.assetYieldSourceBalance,
            preState.assetYieldSourceBalance + amount + preState.assetStrategyBalance
        );
        assertEq(posState.assetStrategyBalance, 0);
        assertEq(posState.stateTotalAssets, preState.stateTotalAssets + amount);
        assertEq(posState.stateTotalSupply, preState.stateTotalSupply + amount);
        assertEq(posState.receiverStrategyShares, preState.receiverStrategyShares + amount);
        assertEq(
            posState.strategyYieldSourcesShares,
            preState.strategyYieldSourcesShares + amount + preState.assetStrategyBalance
        );
    }

    /*//////////////////////////////////////////////////////////////
                            INVARIANTS
    //////////////////////////////////////////////////////////////*/

    // TotalAssets should always equal totalSupply of shares
    function principalPreservationInvariant(Mode mode) internal view {
        uint256 totalSupply = strategy.totalSupply();
        uint256 totalAssets = strategy.totalAssets();

        _establish(mode, totalSupply == totalAssets);
    }

    function lockupDurationInvariant(Mode mode, address user) internal view {
        uint256 ownerLockupTime = _loadMappingUInt256(
            address(strategy),
            VOLUNTARY_LOCKUPS_SLOT,
            uint256(uint160(user)),
            0
        );
        uint256 ownerUnlockTime = _loadMappingUInt256(
            address(strategy),
            VOLUNTARY_LOCKUPS_SLOT,
            uint256(uint160(user)),
            1
        );

        _establish(mode, ownerLockupTime <= block.timestamp);
        _establish(mode, ownerLockupTime <= ownerUnlockTime);
    }

    function userBalancesTotalSupplyConsistency(Mode mode, address user) internal view {
        _establish(mode, strategy.balanceOf(user) <= strategy.totalSupply());
    }

    /*//////////////////////////////////////////////////////////////
                            ONLY OWNER TESTS
    //////////////////////////////////////////////////////////////*/

    function testDeposit(uint256 assets, address receiver) public {
        UserInfo memory receiverInfo = setupSymbolicUser(receiver);
        depositAssumptions(assets, receiver, receiverInfo, 0);

        _snapshop(preState, receiver);

        principalPreservationInvariant(Mode.Assume);
        lockupDurationInvariant(Mode.Assume, receiver);
        userBalancesTotalSupplyConsistency(Mode.Assume, receiver);

        vm.startPrank(safeOwner);
        strategy.deposit(assets, receiver);
        vm.stopPrank();

        principalPreservationInvariant(Mode.Assert);
        lockupDurationInvariant(Mode.Assert, receiver);
        userBalancesTotalSupplyConsistency(Mode.Assert, receiver);

        _snapshop(posState, receiver);
        assertDepositStateChanges(assets == type(uint256).max ? preState.assetOwnerBalance : assets);
    }

    function testDepositWithLockup(uint256 assets, address receiver, uint256 lockupDuration) public {
        vm.assume(lockupDuration > 0);
        UserInfo memory receiverInfo = setupSymbolicUser(receiver);
        depositAssumptions(assets, receiver, receiverInfo, lockupDuration);

        _snapshop(preState, receiver);

        principalPreservationInvariant(Mode.Assume);
        lockupDurationInvariant(Mode.Assume, receiver);
        userBalancesTotalSupplyConsistency(Mode.Assume, receiver);

        vm.startPrank(safeOwner);
        strategy.depositWithLockup(assets, receiver, lockupDuration);
        vm.stopPrank();

        principalPreservationInvariant(Mode.Assert);
        lockupDurationInvariant(Mode.Assert, receiver);
        userBalancesTotalSupplyConsistency(Mode.Assert, receiver);

        _snapshop(posState, receiver);
        //TODO: assertions about the lockuptime and lockupshares
        assertDepositStateChanges(assets == type(uint256).max ? preState.assetOwnerBalance : assets);
    }

    function testMint(uint256 shares, address receiver) public {
        vm.assume(shares != type(uint256).max);
        UserInfo memory receiverInfo = setupSymbolicUser(receiver);
        depositAssumptions(shares, receiver, receiverInfo, 0);

        _snapshop(preState, receiver);

        principalPreservationInvariant(Mode.Assume);
        lockupDurationInvariant(Mode.Assume, receiver);
        userBalancesTotalSupplyConsistency(Mode.Assume, receiver);

        vm.startPrank(safeOwner);
        strategy.mint(shares, receiver);
        vm.stopPrank();

        principalPreservationInvariant(Mode.Assert);
        lockupDurationInvariant(Mode.Assert, receiver);
        userBalancesTotalSupplyConsistency(Mode.Assert, receiver);

        _snapshop(posState, receiver);
        assertDepositStateChanges(shares);
    }

    function testMintWithLockup(uint256 shares, address receiver, uint256 lockupDuration) public {
        vm.assume(lockupDuration > 0);
        vm.assume(shares != type(uint256).max);
        UserInfo memory receiverInfo = setupSymbolicUser(receiver);
        depositAssumptions(shares, receiver, receiverInfo, lockupDuration);

        _snapshop(preState, receiver);

        principalPreservationInvariant(Mode.Assume);
        lockupDurationInvariant(Mode.Assume, receiver);
        userBalancesTotalSupplyConsistency(Mode.Assume, receiver);

        vm.startPrank(safeOwner);
        strategy.mintWithLockup(shares, receiver, lockupDuration);
        vm.stopPrank();

        principalPreservationInvariant(Mode.Assert);
        lockupDurationInvariant(Mode.Assert, receiver);
        userBalancesTotalSupplyConsistency(Mode.Assert, receiver);

        _snapshop(posState, receiver);
        //TODO: assertions about the lockuptime and lockupshares
        assertDepositStateChanges(shares);
    }

    /*//////////////////////////////////////////////////////////////
                            ANY USER TESTS
    //////////////////////////////////////////////////////////////*/

    function testWithdraw(uint256 assets, address receiver, address _owner, uint256 maxLoss) public {
        // Sender has to be concrete, otherwise it will branch a lot when setting prank
        address sender = makeAddr("SENDER");
        // TODO Remove this assumption
        vm.assume(sender == _owner);
        withdrawAssumptions(sender, assets, receiver, _owner, maxLoss);

        _snapshop(preState, receiver);

        principalPreservationInvariant(Mode.Assume);
        lockupDurationInvariant(Mode.Assume, _owner);
        userBalancesTotalSupplyConsistency(Mode.Assume, _owner);

        uint256 withdrawable = strategy.maxWithdraw(_owner);
        vm.assume(assets <= withdrawable);

        uint256 loss;
        if (preState.assetStrategyBalance < assets) {
            if (preState.strategyYieldSourcesShares < assets - preState.assetStrategyBalance) {
                loss = assets - preState.strategyYieldSourcesShares + preState.assetStrategyBalance;
                vm.assume(loss < (assets * maxLoss) / 10_000);
            }
        }

        vm.startPrank(sender);
        strategy.withdraw(assets, receiver, _owner, maxLoss);
        vm.stopPrank();

        principalPreservationInvariant(Mode.Assert);
        // This invariant does not hold because if owner has rage quited tand block.timestamp > user.unlocktime
        // because user.lockuptime is assigned to block.timestamp
        // lockupDurationInvariant(Mode.Assert, _owner);
        userBalancesTotalSupplyConsistency(Mode.Assert, _owner);

        //TODO: assert expected state changes
    }

    // This test is true with the  `_freeFunds` issue. Once that is fixed this test should fail
    function testWithdrawWithLossReverts(uint256 assets, address receiver, address _owner, uint256 maxLoss) public {
        // Sender has to be concrete, otherwise it will branch a lot when setting prank
        address sender = makeAddr("SENDER");
        // TODO Remove this assumption
        vm.assume(sender == _owner);
        withdrawAssumptions(sender, assets, receiver, _owner, maxLoss);

        principalPreservationInvariant(Mode.Assume);
        lockupDurationInvariant(Mode.Assume, _owner);
        userBalancesTotalSupplyConsistency(Mode.Assume, _owner);

        uint256 withdrawable = strategy.maxWithdraw(_owner);
        vm.assume(assets <= withdrawable);
        // Assume the stratagey has not enough balance to cover the withdraw amount
        uint256 idle = TestERC20(_asset).balanceOf(address(strategy));
        vm.assume(idle < assets);
        // Assume there was a loss, i.e. the stratagy has not enough balance YIELD_SOURCE to cover the remaining withdraw amount
        vm.assume(IStrategy(YIELD_SOURCE).balanceOf(address(strategy)) < assets - idle);

        vm.startPrank(sender);
        vm.expectRevert("ERC4626: withdraw more than max");
        strategy.withdraw(assets, receiver, _owner, maxLoss);
        vm.stopPrank();
    }

    function testWithdrawRevert(uint256 assets, address receiver, address _owner, uint256 maxLoss) public {
        assumeNonReentrant();

        // Sender has to be concrete, otherwise it will branch a lot when setting prank
        address sender = makeAddr("SENDER");

        UserInfo memory user = setupSymbolicUser(_owner);

        // Assume DragonTokenizedStrategy__SharesStillLocked()
        vm.assume(user.isRageQuit == 0 && block.timestamp < user.unlockTime);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__SharesStillLocked.selector));
        strategy.withdraw(assets, receiver, _owner, maxLoss);
        vm.stopPrank();
    }

    function testRedeem(uint256 shares, address receiver, address _owner, uint256 maxLoss) public {
        // Sender has to be concrete, otherwise it will branch a lot when setting prank
        address sender = makeAddr("SENDER");
        // TODO Remove this assumption
        vm.assume(sender == _owner);
        withdrawAssumptions(sender, shares, receiver, _owner, maxLoss);

        _snapshop(preState, receiver);

        principalPreservationInvariant(Mode.Assume);
        lockupDurationInvariant(Mode.Assume, _owner);
        userBalancesTotalSupplyConsistency(Mode.Assume, _owner);

        uint256 withdrawable = strategy.maxRedeem(_owner);
        vm.assume(shares <= withdrawable);

        uint256 loss;
        if (preState.assetStrategyBalance < shares) {
            if (preState.strategyYieldSourcesShares < shares - preState.assetStrategyBalance) {
                loss = shares - preState.strategyYieldSourcesShares + preState.assetStrategyBalance;
                vm.assume(loss < (shares * maxLoss) / 10_000);
            }
        }

        vm.startPrank(sender);
        strategy.redeem(shares, receiver, _owner, maxLoss);
        vm.stopPrank();

        principalPreservationInvariant(Mode.Assert);
        // This invariant does not hold because if owner has rage quited tand block.timestamp > user.unlocktime
        // because user.lockuptime is assigned to block.timestamp
        // lockupDurationInvariant(Mode.Assert, _owner);
        userBalancesTotalSupplyConsistency(Mode.Assert, _owner);

        //TODO: assert expected state changes
    }

    function testMaxRedeemAllwaysReverts(address _owner) public {
        setupSymbolicUser(_owner);

        vm.assume(strategy.totalSupply() > strategy.totalAssets());
        vm.assume(strategy.totalAssets() > 0);

        vm.expectRevert();
        strategy.maxRedeem(_owner);
    }

    function testRedeemRevert(uint256 shares, address receiver, address _owner, uint256 maxLoss) public {
        assumeNonReentrant();
        // Sender has to be concrete, otherwise it will branch a lot when setting prank
        address sender = makeAddr("SENDER");

        UserInfo memory user = setupSymbolicUser(_owner);

        principalPreservationInvariant(Mode.Assume);
        lockupDurationInvariant(Mode.Assume, _owner);
        userBalancesTotalSupplyConsistency(Mode.Assume, _owner);

        // Assume DragonTokenizedStrategy__SharesStillLocked()
        vm.assume(user.isRageQuit == 0 && block.timestamp < user.unlockTime);

        uint256 redeemable = strategy.maxRedeem(_owner);
        vm.assume(shares <= redeemable);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__SharesStillLocked.selector));
        strategy.redeem(shares, receiver, _owner, maxLoss);
        vm.stopPrank();
    }

    function testInitiateRageQuit() public {
        address sender = makeAddr("SENDER");

        UserInfo memory user = setupSymbolicUser(sender);
        vm.assume(user.strategyBalance > 0);
        vm.assume(block.timestamp < user.unlockTime);
        vm.assume(user.isRageQuit == 0);

        principalPreservationInvariant(Mode.Assume);
        lockupDurationInvariant(Mode.Assume, sender);
        userBalancesTotalSupplyConsistency(Mode.Assume, sender);

        vm.startPrank(sender);
        strategy.initiateRageQuit();
        vm.stopPrank();

        principalPreservationInvariant(Mode.Assert);
        lockupDurationInvariant(Mode.Assert, sender);
        userBalancesTotalSupplyConsistency(Mode.Assert, sender);

        //TODO: assert expected state changes
    }

    //approve
    //accceptManagement

    /*//////////////////////////////////////////////////////////////
                            ONLY MANAGER TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetPendingManagement(address newManagement) public {
        vm.assume(newManagement != address(0));

        vm.startPrank(_management);
        strategy.setPendingManagement(newManagement);
        vm.stopPrank();

        assertEq(newManagement, _loadAddress(address(strategy), PENDING_MANAGEMENT_SLOT));
    }

    function testSetPendingManagementRevert(address /* sender */, address newManagement) public {
        //vm.assume(sender != _management);
        _storeData(address(strategy), HATS_INITIALIZED_SLOT, 0, 1, 0);

        // Sender is this contract to avoid branching on prank
        //vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(TokenizedStrategy__NotManagement.selector));
        strategy.setPendingManagement(newManagement);
        //vm.stopPrank();
    }

    function testAcceptManagement(address newManagement) public {
        _storeAddress(address(strategy), PENDING_MANAGEMENT_SLOT, newManagement);

        vm.startPrank(newManagement);
        strategy.acceptManagement();
        vm.stopPrank();

        assertEq(address(0), _loadAddress(address(strategy), PENDING_MANAGEMENT_SLOT));
        assertEq(newManagement, _loadAddress(address(strategy), MANAGEMENT_SLOT));
    }

    function testAcceptManagementRevert(address sender, address newManagement) public {
        _storeAddress(address(strategy), PENDING_MANAGEMENT_SLOT, newManagement);
        vm.assume(sender != newManagement);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(TokenizedStrategy__NotPendingManagement.selector));
        strategy.acceptManagement();
        vm.stopPrank();
    }

    function testSetKeeper(address keeper) public {
        vm.startPrank(_management);
        strategy.setKeeper(keeper);
        vm.stopPrank();

        assertEq(keeper, _loadAddress(address(strategy), KEEPER_SLOT));
    }

    function testSetKeeperRevert(address sender, address keeper) public {
        vm.assume(sender != _management);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(TokenizedStrategy__NotManagement.selector));
        strategy.setKeeper(keeper);
        vm.stopPrank();
    }

    function testSetEmergencyAdmin(address _emergencyAdmin) public {
        vm.startPrank(_management);
        strategy.setEmergencyAdmin(_emergencyAdmin);
        vm.stopPrank();

        assertEq(_emergencyAdmin, _loadAddress(address(strategy), EMERGENCY_ADMIN_SLOT));
    }

    function testSetEmergencyAdminRevert(address sender, address _emergencyAdmin) public {
        vm.assume(sender != _management);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(TokenizedStrategy__NotManagement.selector));
        strategy.setEmergencyAdmin(_emergencyAdmin);
        vm.stopPrank();
    }

    function testSetName(string calldata _name) public {
        vm.startPrank(_management);
        strategy.setName(_name);
        vm.stopPrank();
    }

    //setupHatsProtocol

    /*//////////////////////////////////////////////////////////////
                            ONLY KEEPER TESTS
    //////////////////////////////////////////////////////////////*/

    function testReport() public {
        assumeNonReentrant();

        // Mint dragonrouter symbolic amount
        uint256 dragonRouterStrategyBalance = freshUInt256Bounded("dragonRouterStrategyBalance");
        _storeMappingUInt256(
            address(strategy),
            BALANCES_SLOT,
            uint256(uint160(address(dragonRouter))),
            0,
            dragonRouterStrategyBalance
        );

        _snapshop(preState, address(dragonRouter));

        principalPreservationInvariant(Mode.Assume);
        userBalancesTotalSupplyConsistency(Mode.Assume, address(dragonRouter));

        uint256 loss;
        if (preState.assetStrategyBalance + preState.strategyYieldSourcesShares <= preState.stateTotalAssets) {
            loss = preState.stateTotalAssets - (preState.assetStrategyBalance + preState.strategyYieldSourcesShares);
            // DragonRouter shares is enough to cover the loss
            vm.assume(dragonRouterStrategyBalance >= loss);
        }

        vm.startPrank(_keeper);
        strategy.report();
        vm.stopPrank();

        principalPreservationInvariant(Mode.Assert);
        userBalancesTotalSupplyConsistency(Mode.Assert, address(dragonRouter));
    }

    function testReportWithLoss() public {
        assumeNonReentrant();

        // Mint dragonrouter symbolic amount
        uint256 dragonRouterStrategyBalance = freshUInt256Bounded("dragonRouterStrategyBalance");
        _storeMappingUInt256(
            address(strategy),
            BALANCES_SLOT,
            uint256(uint160(address(dragonRouter))),
            0,
            dragonRouterStrategyBalance
        );

        _snapshop(preState, address(dragonRouter));

        principalPreservationInvariant(Mode.Assume);
        userBalancesTotalSupplyConsistency(Mode.Assume, address(dragonRouter));

        vm.assume(preState.assetStrategyBalance + preState.strategyYieldSourcesShares < preState.stateTotalAssets);
        uint256 loss = preState.stateTotalAssets -
            (preState.assetStrategyBalance + preState.strategyYieldSourcesShares);
        // DragonRouter shares is not enough to cover the loss
        vm.assume(dragonRouterStrategyBalance < loss);

        vm.startPrank(_keeper);
        strategy.report();
        vm.stopPrank();

        // The invariant breaks
        assertGt(strategy.totalSupply(), strategy.totalAssets());
    }

    function testTend() public {
        assumeNonReentrant();

        principalPreservationInvariant(Mode.Assume);

        vm.startPrank(_keeper);
        strategy.tend();
        vm.stopPrank();

        principalPreservationInvariant(Mode.Assert);
    }

    /*//////////////////////////////////////////////////////////////
                            ONLY REGEN GOVERNANCE TESTS
    //////////////////////////////////////////////////////////////*/

    function testSetLockupDuration(uint256 _lockupDuration) public {
        vm.startPrank(_regenGovernance);
        strategy.setLockupDuration(_lockupDuration);
        vm.stopPrank();
    }

    function testSetRageQuitCooldownPeriod(uint256 _rageQuitCooldownPeriod) public {
        vm.startPrank(_regenGovernance);
        strategy.setRageQuitCooldownPeriod(_rageQuitCooldownPeriod);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            ONLY EMERGENCY TESTS
    //////////////////////////////////////////////////////////////*/

    function testShutdownStrategy() public {
        vm.startPrank(_emergencyAdmin);
        strategy.shutdownStrategy();
        vm.stopPrank();
    }

    function testEmergencyWithdraw(uint256 amount) public {
        vm.startPrank(_emergencyAdmin);
        strategy.emergencyWithdraw(amount);
        vm.stopPrank();
    }
}
