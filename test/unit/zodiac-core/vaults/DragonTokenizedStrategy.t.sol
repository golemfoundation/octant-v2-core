// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;

import { Test } from "forge-std/Test.sol";
import { DragonTokenizedStrategy } from "src/zodiac-core/vaults/DragonTokenizedStrategy.sol";
import { MockStrategy } from "test/mocks/zodiac-core/MockStrategy.sol";
import { MockYieldSource } from "test/mocks/core/MockYieldSource.sol";
import { TokenizedStrategy__NotOperator, DragonTokenizedStrategy__InsufficientLockupDuration, DragonTokenizedStrategy__InvalidReceiver, DragonTokenizedStrategy__RageQuitInProgress, DragonTokenizedStrategy__SharesStillLocked, DragonTokenizedStrategy__StrategyInShutdown, DragonTokenizedStrategy__SharesAlreadyUnlocked, DragonTokenizedStrategy__NoSharesToRageQuit, DragonTokenizedStrategy__ZeroLockupDuration, DragonTokenizedStrategy__WithdrawMoreThanMax, DragonTokenizedStrategy__RedeemMoreThanMax, TokenizedStrategy__TransferFailed, ZeroAssets, ZeroShares, DragonTokenizedStrategy__DepositMoreThanMax, DragonTokenizedStrategy__MintMoreThanMax, ERC20InsufficientBalance, DragonTokenizedStrategy__ReceiverHasExistingShares } from "src/errors.sol";
import { BaseTest } from "../Base.t.sol";
import { ITokenizedStrategy } from "src/zodiac-core/interfaces/ITokenizedStrategy.sol";
import { console } from "forge-std/console.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

/// @dev This test is incomplete.
/// @dev temps.safe == operator == dragon
contract DragonTokenizedStrategyTest is BaseTest {
    event RageQuitInitiated(address indexed user, uint256 indexed unlockTime);

    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");
    address dragonRouter = makeAddr("dragonRouter");
    address management = makeAddr("management");
    address regenGovernance = makeAddr("regenGovernance");
    address operator = makeAddr("operator");
    address randomUser = makeAddr("randomUser");
    testTemps temps;
    MockStrategy moduleImplementation;
    DragonTokenizedStrategy module;
    MockYieldSource yieldSource;
    DragonTokenizedStrategy tokenizedStrategyImplementation;
    string public name = "Test Mock Strategy";
    uint256 public maxReportDelay = 9;

    function setUp() public {
        _configure(true, "eth");

        moduleImplementation = new MockStrategy();
        tokenizedStrategyImplementation = new DragonTokenizedStrategy();
        yieldSource = new MockYieldSource(NATIVE_TOKEN);
        temps = _testTemps(
            address(moduleImplementation),
            abi.encode(
                address(tokenizedStrategyImplementation),
                NATIVE_TOKEN,
                address(yieldSource),
                management,
                keeper,
                dragonRouter,
                maxReportDelay,
                name,
                regenGovernance
            )
        );
        module = DragonTokenizedStrategy(payable(temps.module));

        operator = temps.safe;
    }

    /// @dev Demonstrates that initial params are set correctly.
    function testInitialize() public view {
        assertTrue(
            keccak256(abi.encodePacked(ITokenizedStrategy(address(module)).name())) == keccak256(abi.encodePacked(name))
        );
        assertTrue(ITokenizedStrategy(address(module)).management() == management);
        assertTrue(ITokenizedStrategy(address(module)).keeper() == keeper);
        assertTrue(ITokenizedStrategy(address(module)).operator() == operator);
        assertTrue(ITokenizedStrategy(address(module)).dragonRouter() == dragonRouter);
    }

    /// @dev Demonstrates that a dragon is able to toggle the feature switch to enable deposits by others.
    function testFuzz_dragonCanToggleDragonMode(uint depositAmount) public {
        depositAmount = bound(depositAmount, 1 wei, type(uint232).max);

        // Non-dragon can't toggle
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(TokenizedStrategy__NotOperator.selector));
        module.toggleDragonMode(false);

        // Non-dragon can't deposit
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(TokenizedStrategy__NotOperator.selector));
        module.deposit(depositAmount, randomUser);

        // Dragon can toggle
        vm.prank(operator);
        module.toggleDragonMode(false);
        assertFalse(module.isDragonOnly(), "Should exit dragon mode");

        // Non-dragon can deposit
        vm.deal(randomUser, depositAmount);
        vm.prank(randomUser);
        module.deposit{ value: depositAmount }(depositAmount, randomUser);

        // Toggle back
        vm.prank(operator);
        module.toggleDragonMode(true);
        assertTrue(module.isDragonOnly(), "Should enter dragon mode");

        // Non-dragon can't deposit
        vm.prank(randomUser);
        vm.expectRevert(abi.encodeWithSelector(TokenizedStrategy__NotOperator.selector));
        module.deposit(depositAmount, randomUser);
    }

    /// @dev Demonstrates that a non-dragon user can deposit when dragon mode is off.
    function testFuzz_nonDragonCanDepositWhenDragonModeOff(
        uint depositAmount,
        string memory alice,
        string memory bob,
        string memory charlie
    ) public {
        depositAmount = bound(depositAmount, 1 wei, type(uint232).max);

        vm.assume(bytes(alice).length != bytes(bob).length);
        vm.assume(bytes(alice).length != bytes(charlie).length);
        vm.assume(bytes(bob).length != bytes(charlie).length);

        // Toggle dragon mode off to allow non-dragon deposits
        vm.prank(operator);
        module.toggleDragonMode(false);

        vm.startPrank(makeAddr(alice));
        vm.deal(makeAddr(alice), 3 * depositAmount);
        vm.deal(makeAddr(charlie), 1 * depositAmount);

        module.deposit{ value: depositAmount }(depositAmount, makeAddr(alice)); // Regular deposit to self
        module.deposit{ value: depositAmount }(depositAmount, makeAddr(bob)); // Regular deposit to others

        uint256 lockupDuration = module.minimumLockupDuration();
        vm.expectRevert(abi.encodeWithSelector(DragonTokenizedStrategy__InvalidReceiver.selector));
        module.depositWithLockup{ value: depositAmount }(depositAmount, makeAddr(charlie), lockupDuration);
        vm.stopPrank();

        vm.prank(makeAddr(charlie));
        module.depositWithLockup{ value: depositAmount }(depositAmount, makeAddr(charlie), lockupDuration);

        // Verify balances
        assertEq(module.balanceOf(makeAddr(bob)), depositAmount, "Deposit from Alice to Bob failed.");
        assertEq(module.balanceOf(makeAddr(alice)), depositAmount, "A self-deposit failed.");
        assertEq(module.balanceOf(makeAddr(charlie)), depositAmount, "Deposit to self with lockup failed.");
    }

    /// @dev Demonstrates that the lockup duration is enforced for non-dragons.
    /// @dev Demonstrates that a non-dragon can withdraw after the lockup period has expired.
    function testFuzz_lockupEnforcementForNonDragons(
        uint256 lockupDuration,
        uint256 unlockOffset,
        uint256 depositAmount
    ) public {
        lockupDuration = bound(lockupDuration, 1 days, 10000 days);
        depositAmount = bound(depositAmount, 1 wei, type(uint232).max);

        vm.prank(operator);
        module.toggleDragonMode(false);

        vm.deal(randomUser, depositAmount);
        vm.startPrank(randomUser);

        if (lockupDuration <= module.minimumLockupDuration()) {
            // Should revert for durations under minimum
            vm.expectRevert(DragonTokenizedStrategy__InsufficientLockupDuration.selector);
            module.depositWithLockup{ value: depositAmount }(depositAmount, randomUser, lockupDuration);
        } else {
            // Should succeed for valid durations
            module.depositWithLockup{ value: depositAmount }(depositAmount, randomUser, lockupDuration);

            // Verify lockup state
            (uint256 unlockTime, uint256 lockedShares, bool isRageQuit, , ) = module.getUserLockupInfo(randomUser);
            assertEq(unlockTime, block.timestamp + lockupDuration, "Unlock time mismatch");
            assertEq(lockedShares, depositAmount, "Incorrect locked shares");
            assertFalse(isRageQuit, "Should not be in rage quit");

            // Verify withdrawal restrictions during lockup
            assertEq(module.maxWithdraw(randomUser), 0, "Withdrawals should be locked");
            assertEq(module.maxRedeem(randomUser), 0, "Redemptions should be locked");

            // Attempt early withdrawal before unlock time
            unlockOffset = bound(unlockOffset, 1, unlockTime - lockupDuration);
            uint256 randomTimeBeforeUnlock = unlockTime - unlockOffset;
            vm.warp(randomTimeBeforeUnlock); // Move to random time before unlock
            vm.expectRevert(DragonTokenizedStrategy__SharesStillLocked.selector);
            module.withdraw(1 ether, randomUser, randomUser);

            // Fast forward past unlock time
            vm.warp(unlockTime);

            // Verify withdrawal becomes possible
            assertEq(module.maxWithdraw(randomUser), depositAmount, "Withdraw should be available after unlock");
            assertEq(module.maxRedeem(randomUser), depositAmount, "Redeem should be available after unlock");

            // Execute withdrawal and verify state changes
            uint256 preBalance = address(randomUser).balance;
            uint256 maxLoss = 0;
            module.withdraw(depositAmount, randomUser, randomUser, maxLoss);

            assertEq(address(randomUser).balance, preBalance + depositAmount, "Funds not received");
            assertEq(module.balanceOf(randomUser), 0, "Shares not burned");
            (, , , uint256 remainingShares, ) = module.getUserLockupInfo(randomUser);
            assertEq(remainingShares, 0, "Lockup shares not cleared");
        }

        vm.stopPrank();
    }

    /// @dev Demonstrates that a locked-up non-dragon is able to rage quit.
    function testFuzz_lockedNonDragonCanRageQuit(uint depositAmount) public {
        depositAmount = bound(depositAmount, 1 wei, type(uint232).max);
        // Define deposit parameters.
        uint256 lockupDuration = module.minimumLockupDuration();

        // Toggle off dragon mode so that non-safe (non-operator) users may deposit
        vm.prank(operator);
        module.toggleDragonMode(false);

        // randomUser deposits with a lockup.
        vm.deal(randomUser, depositAmount);
        vm.prank(randomUser);
        module.depositWithLockup{ value: depositAmount }(depositAmount, randomUser, lockupDuration);

        // Verify initial lockup state: not in rage quit.
        (
            uint256 unlockTime,
            uint256 lockedShares,
            bool isRageQuit,
            uint256 totalShares,
            uint256 withdrawableShares
        ) = module.getUserLockupInfo(randomUser);
        assertFalse(isRageQuit, "User should not be in rage quit initially");
        assertEq(
            unlockTime,
            block.timestamp + lockupDuration,
            "Unlock time should be the sum of the current timestamp and the lockup duration"
        );
        assertEq(lockedShares, depositAmount, "Locked shares should equal deposit amount initially");
        assertEq(totalShares, depositAmount, "Total shares should equal deposit amount initially");
        assertEq(withdrawableShares, 0, "Withdrawable shares should be 0 initially");

        // Capture current timestamp for expected unlock calculation.
        uint256 beforeTimestamp = block.timestamp;

        // User initiates rage quit.
        vm.prank(randomUser);
        module.initiateRageQuit();

        // Check that the lockup state now reflects rage quit.
        (
            uint256 newUnlock,
            uint256 newLockedShares,
            bool newIsRageQuit,
            uint256 newTotalShares,
            uint256 newWithdrawableShares
        ) = module.getUserLockupInfo(randomUser);
        assertTrue(newIsRageQuit, "User should be in rage quit state after initiating rage quit");
        assertEq(newUnlock, beforeTimestamp + lockupDuration, "Unlock time after rage quit is incorrect");
        assertEq(newLockedShares, depositAmount, "Locked shares should equal deposit amount after rage quit");
        assertEq(newTotalShares, depositAmount, "Total shares should equal deposit amount after rage quit");
        assertEq(newWithdrawableShares, 0, "Withdrawable shares should be 0 immediately after rage quit");
    }

    /// @dev Demonstrates that non-dragons can't deposit/mint after initial lockup.
    function testFuzz_nonDragonCannotDepositOrMintWithLockupAfterLockup(uint initialDeposit) public {
        initialDeposit = bound(initialDeposit, 1 ether, 100 ether);
        uint256 lockupDuration = module.minimumLockupDuration();

        // Enable non-operator deposits
        vm.prank(operator);
        module.toggleDragonMode(false);

        // Initial deposit with lockup
        vm.deal(randomUser, 2 * initialDeposit);
        vm.startPrank(randomUser);
        module.depositWithLockup{ value: initialDeposit }(initialDeposit, randomUser, lockupDuration);
        vm.stopPrank();

        // Attempt additional deposit before lockup expiration
        vm.startPrank(randomUser);
        vm.expectRevert(DragonTokenizedStrategy__ReceiverHasExistingShares.selector);
        module.depositWithLockup{ value: initialDeposit }(initialDeposit, randomUser, lockupDuration);

        vm.expectRevert(DragonTokenizedStrategy__ReceiverHasExistingShares.selector);
        module.mintWithLockup(initialDeposit, randomUser, lockupDuration);
        vm.stopPrank();

        // Fast-forward past lockup period
        skip(lockupDuration);

        // Attempt deposit after lockup expiration (should still fail for lockup deposits)
        vm.startPrank(randomUser);
        vm.expectRevert(DragonTokenizedStrategy__ReceiverHasExistingShares.selector);
        module.depositWithLockup{ value: initialDeposit }(initialDeposit, randomUser, lockupDuration);

        vm.expectRevert(DragonTokenizedStrategy__ReceiverHasExistingShares.selector);
        module.mintWithLockup(initialDeposit, randomUser, lockupDuration);
        vm.stopPrank();
    }

    /// @dev Demonstrates that non-dragons CAN deposit/mint without lockup after initial deposit.
    function testFuzz_nonDragonCanDepositWithoutLockupAfterInitialDeposit(
        uint initialDeposit,
        uint additionalDeposit
    ) public {
        initialDeposit = bound(initialDeposit, 1 ether, 100 ether);
        additionalDeposit = bound(additionalDeposit, 1 ether, 100 ether);
        uint256 lockupDuration = module.minimumLockupDuration();

        // Enable non-operator deposits
        vm.prank(operator);
        module.toggleDragonMode(false);

        // Initial deposit with lockup
        vm.deal(randomUser, initialDeposit + additionalDeposit);
        vm.startPrank(randomUser);
        module.depositWithLockup{ value: initialDeposit }(initialDeposit, randomUser, lockupDuration);
        uint256 initialShares = module.balanceOf(randomUser);
        assertEq(initialShares, initialDeposit, "Initial shares should match initial deposit");

        // Now test that additional deposit WITHOUT lockup succeeds
        module.deposit{ value: additionalDeposit }(additionalDeposit, randomUser);

        // Verify the shares were added correctly
        uint256 finalShares = module.balanceOf(randomUser);
        assertEq(finalShares, initialShares + additionalDeposit, "Shares should increase by additional deposit amount");

        vm.stopPrank();

        // Reset for testing mint
        address mintUser = makeAddr("mintUser");
        vm.deal(mintUser, initialDeposit + additionalDeposit);

        // Initial mint with lockup
        vm.startPrank(mintUser);
        module.mintWithLockup{ value: initialDeposit }(initialDeposit, mintUser, lockupDuration);
        initialShares = module.balanceOf(mintUser);

        // Test that additional mint WITHOUT lockup succeeds
        module.mint{ value: additionalDeposit }(additionalDeposit, mintUser);

        // Verify the shares were added correctly
        finalShares = module.balanceOf(mintUser);
        assertEq(finalShares, initialShares + additionalDeposit, "Shares should increase by additional mint amount");

        vm.stopPrank();
    }

    /// @dev Demonstrates that one can't lockup for others when dragon mode is off.
    function testFuzz_cannotLockupForOthersWhenDragonModeOff(uint depositAmount, string memory receiver) public {
        // Setup
        uint256 lockupDuration = module.minimumLockupDuration();
        depositAmount = bound(depositAmount, 1 wei, type(uint232).max);

        // Test depositWithLockup to others while dragon mode is on.
        vm.prank(operator);
        vm.expectRevert();
        module.depositWithLockup(depositAmount, makeAddr(receiver), lockupDuration);
        vm.prank(randomUser);
        vm.expectRevert();
        module.depositWithLockup(depositAmount, makeAddr(receiver), lockupDuration);

        // Test mintWithLockup to others
        vm.prank(operator);
        vm.expectRevert();
        module.mintWithLockup(depositAmount, makeAddr(receiver), lockupDuration);
        vm.prank(randomUser);
        vm.expectRevert();
        module.mintWithLockup(depositAmount, makeAddr(receiver), lockupDuration);

        // Disable dragon mode
        vm.prank(operator);
        module.toggleDragonMode(false);

        // Test depositWithLockup to others while dragon mode is off.
        vm.prank(operator);
        vm.expectRevert();
        module.depositWithLockup(depositAmount, makeAddr(receiver), lockupDuration);
        vm.prank(randomUser);
        vm.expectRevert();
        module.depositWithLockup(depositAmount, makeAddr(receiver), lockupDuration);

        // Test mintWithLockup to others
        vm.prank(operator);
        vm.expectRevert();
        module.mintWithLockup(depositAmount, makeAddr(receiver), lockupDuration);
        vm.prank(randomUser);
        vm.expectRevert();
        module.mintWithLockup(depositAmount, makeAddr(receiver), lockupDuration);
    }

    /// @dev Demonstrates that a non-dragon who deposited funds earlier can withdraw them
    /// after the contract is switched into dragon-only mode.
    function testFuzz_nonDragonCanWithdrawAfterDragonModeTurnsOn(uint256 initialDeposit) public {
        // Setup
        initialDeposit = bound(initialDeposit, 1 wei, type(uint232).max);

        // 1. Enable non-dragon deposits first
        vm.prank(operator);
        module.toggleDragonMode(false);

        // 2. Degen deposits funds
        vm.prank(randomUser);
        vm.deal(randomUser, initialDeposit);
        module.deposit{ value: initialDeposit }(initialDeposit, randomUser);
        uint256 initialShares = ITokenizedStrategy(address(module)).balanceOf(randomUser);
        assert(initialShares > 0);
        assertEq(module.balanceOf(randomUser), initialDeposit, "Deposit amount mismatch");

        // 3. Operator toggles dragon-only mode on.
        vm.prank(operator);
        module.toggleDragonMode(true);

        // 4. The same non-dragon withdraws their funds.
        vm.prank(randomUser);
        module.withdraw(initialDeposit, randomUser, randomUser);
        uint256 finalShares = ITokenizedStrategy(address(module)).balanceOf(randomUser);
        assertEq(finalShares, 0, "User should have no shares after full withdrawal");
        assertEq(address(randomUser).balance, initialDeposit, "Funds not received");
    }

    /// @dev Demonstrates that rage quit doesn't extend a user's lockup time
    function testRageQuitDoesntExtendLockupTime(uint256 depositAmount, uint256 timeRemaining) public {
        depositAmount = bound(depositAmount, 1 wei, type(uint232).max);
        timeRemaining = bound(timeRemaining, 1 minutes, module.rageQuitCooldownPeriod());
        // Setup: Toggle dragon mode off to allow non-operator deposits
        vm.prank(operator);
        module.toggleDragonMode(false);

        // Define test parameters
        uint256 lockupDuration = module.minimumLockupDuration(); // Use minimum valid lockup

        // User deposits with lockup
        vm.deal(randomUser, depositAmount);
        vm.prank(randomUser);
        module.depositWithLockup{ value: depositAmount }(depositAmount, randomUser, lockupDuration);

        // Fast forward to near the end of lockup period (e.g., 1 week remaining)
        uint256 timeToWarp = lockupDuration - timeRemaining;
        vm.warp(block.timestamp + timeToWarp);

        // Capture the original unlock time before rage quit
        uint256 originalUnlockTime = module.getUnlockTime(randomUser);
        uint256 remainingLockupTime = originalUnlockTime - block.timestamp;
        assertEq(remainingLockupTime, timeRemaining, "Should have 7 days remaining before rage quit");

        // User initiates rage quit
        vm.prank(randomUser);
        module.initiateRageQuit();

        // Verify the unlock time wasn't extended
        uint256 newUnlockTime = module.getUnlockTime(randomUser);
        assertEq(newUnlockTime, originalUnlockTime, "Rage quit should not extend unlock time");

        // Verify rage quit state
        (uint256 unlockTime, , bool isRageQuit, , ) = module.getUserLockupInfo(randomUser);
        assertTrue(isRageQuit, "Should be in rage quit state");
        assertEq(unlockTime, originalUnlockTime, "Unlock time should match original");

        // Test gradual unlocking works correctly
        uint256 halfwayPoint = block.timestamp + (remainingLockupTime / 2);
        vm.warp(halfwayPoint);

        // Calculate exact expected unlocked amount
        uint256 timeElapsed = block.timestamp - (originalUnlockTime - remainingLockupTime);
        uint256 totalDuration = remainingLockupTime;
        uint256 expectedWithdrawable = (timeElapsed * depositAmount) / totalDuration;
        uint256 actualWithdrawable = module.maxWithdraw(randomUser);

        // Use exact assertion
        assertEq(actualWithdrawable, expectedWithdrawable, "Unlocked amount should match exact calculation");

        // Fast forward to just after unlock time
        vm.warp(originalUnlockTime);

        // Should be able to withdraw everything
        assertEq(
            module.maxWithdraw(randomUser),
            module.balanceOf(randomUser),
            "Should be able to withdraw all after unlock"
        );
    }

    /// @dev Demonstrates that maxRedeem doesn't revert when totalSupply > totalAssets (underwater scenario)
    function testMaxRedeemAfterCatastrophicLoss(uint depositAmount, uint lossAmount) public {
        depositAmount = bound(depositAmount, 2, type(uint128).max);
        lossAmount = bound(lossAmount, depositAmount / 2, depositAmount - 1);

        // Toggle off dragon-only mode to allow non-dragon deposits
        vm.prank(operator);
        module.toggleDragonMode(false);

        // Use an arbitrary receiver address
        address testReceiver = makeAddr("testReceiver");

        // Deposit to testReceiver
        vm.deal(testReceiver, depositAmount);
        vm.prank(testReceiver);
        module.deposit{ value: depositAmount }(depositAmount, testReceiver);

        // Fast forward past lockup period to allow withdrawals
        vm.warp(block.timestamp + module.minimumLockupDuration());

        // First, get current totalAssets
        uint256 currentTotalAssets = module.totalAssets();

        // Mock the report function to return the desired profit and loss values
        vm.mockCall(
            address(module),
            abi.encodeWithSelector(DragonTokenizedStrategy.report.selector),
            abi.encode(0, lossAmount) // 0 profit, lossAmount loss
        );

        // After the report, we need to modify the internal accounting
        vm.mockCall(
            address(module),
            abi.encodeWithSelector(module.totalAssets.selector),
            abi.encode(currentTotalAssets - lossAmount)
        );

        // Trigger a report to recognize the loss
        vm.prank(keeper);
        (uint256 profit, uint256 loss) = module.report();

        // Verify loss was recognized
        assertEq(loss, lossAmount, "Loss should match simulated amount");
        assertEq(profit, 0, "Should have no profit");

        // Verify protocol state: totalSupply > totalAssets
        uint256 totalAssets = module.totalAssets();
        uint256 totalSupply = module.totalSupply();
        assertTrue(totalSupply > totalAssets, "Protocol should be in underwater state");

        // Call the actual maxRedeem function (no mocking)
        uint256 maxRedeemAmount = module.maxRedeem(testReceiver);

        // Verify maxRedeem returns the correct value
        assertEq(maxRedeemAmount, module.balanceOf(testReceiver), "maxRedeem should return correct share amount");

        // Get the initial balance before redeeming
        uint256 initialBalance = address(testReceiver).balance;

        // Verify user can actually redeem shares
        vm.prank(testReceiver);
        uint256 assetsReceived = module.redeem(maxRedeemAmount, testReceiver, testReceiver);

        // Verify the assets received matches the balance change
        uint256 finalBalance = address(testReceiver).balance;
        assertEq(finalBalance - initialBalance, assetsReceived, "Balance change should match reported assets received");

        // Verify shares were burned
        assertEq(module.balanceOf(testReceiver), 0, "All user shares should be burned after redemption");

        // Get the shares of dragon router
        uint256 dragonRouterShares = module.balanceOf(module.dragonRouter());
        assertEq(dragonRouterShares, 0, "Dragon router should have no shares");
    }
}
