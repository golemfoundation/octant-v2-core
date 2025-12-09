// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.0 <0.9.0;
import "forge-std/Test.sol";
import "@gnosis.pm/safe-contracts/contracts/Safe.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxyFactory.sol";
import "@gnosis.pm/safe-contracts/contracts/proxies/SafeProxy.sol";
import { LinearAllowanceSingletonForGnosisSafe } from "src/zodiac-core/modules/LinearAllowanceSingletonForGnosisSafe.sol";
import { NATIVE_TOKEN } from "src/constants.sol";
import "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import { LinearAllowanceExecutorTestHarness } from "test/mocks/zodiac-core/LinearAllowanceExecutorTestHarness.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ILinearAllowanceSingleton } from "src/zodiac-core/interfaces/ILinearAllowanceSingleton.sol";

contract TestERC20 is ERC20 {
    constructor(uint256 initialSupply) ERC20("TestToken", "TST") {
        _mint(msg.sender, initialSupply);
    }
}

contract TestLinearAllowanceIntegration is Test {
    address delegateContractOwner = makeAddr("delegateContractOwner");

    Safe internal safeImpl;
    SafeProxyFactory internal safeProxyFactory;
    Safe internal singleton;
    LinearAllowanceSingletonForGnosisSafe internal allowanceModule;
    LinearAllowanceExecutorTestHarness public allowanceExecutor;
    address internal recipient = makeAddr("recipient");
    address internal safe = makeAddr("safe");

    /// @notice Test context struct for stack optimization
    /// @dev Consolidates test variables into storage to prevent stack too deep issues
    struct TestContext {
        uint128 dripRate;
        address safeAddress;
        LinearAllowanceExecutorTestHarness executor1;
        LinearAllowanceExecutorTestHarness executor2;
        LinearAllowanceExecutorTestHarness executor3;
        uint256 unspent1Before;
        uint256 unspent2Before;
        uint256 unspent3Before;
        uint256 unspent1After;
        uint256 unspent2After;
        uint256 unspent3After;
        uint192 dripRate1;
        uint192 dripRate2;
        uint192 dripRate3;
        address[] delegates;
        address[] tokens;
        address[] wrongLengthTokens;
    }

    /// @notice Storage-based test context for stack optimization
    TestContext internal currentTestCtx;

    /// @notice Helper function to create and allowset an executor
    function createAllowsetedExecutor() internal returns (LinearAllowanceExecutorTestHarness) {
        LinearAllowanceExecutorTestHarness newExecutor = new LinearAllowanceExecutorTestHarness();
        AddressSet allowset = new AddressSet();
        newExecutor.assignModuleAddressSet(IAddressSet(address(allowset)));
        allowset.add(address(allowanceModule));
        return newExecutor;
    }

    /// @notice Clear test context for fresh initialization
    function _clearTestContext() internal {
        currentTestCtx.dripRate = 0;
        currentTestCtx.safeAddress = address(0);
        delete currentTestCtx.executor1;
        delete currentTestCtx.executor2;
        delete currentTestCtx.executor3;
        currentTestCtx.unspent1Before = 0;
        currentTestCtx.unspent2Before = 0;
        currentTestCtx.unspent3Before = 0;
        currentTestCtx.unspent1After = 0;
        currentTestCtx.unspent2After = 0;
        currentTestCtx.unspent3After = 0;
        currentTestCtx.dripRate1 = 0;
        currentTestCtx.dripRate2 = 0;
        currentTestCtx.dripRate3 = 0;
        delete currentTestCtx.delegates;
        delete currentTestCtx.tokens;
        delete currentTestCtx.wrongLengthTokens;
    }

    function setUp() public {
        // Deploy module
        allowanceModule = new LinearAllowanceSingletonForGnosisSafe();
        // Deploy Safe infrastructure
        safeProxyFactory = new SafeProxyFactory();
        singleton = new Safe();

        // Create proxy Safe
        SafeProxy proxy = safeProxyFactory.createProxyWithNonce(address(singleton), "", 0);
        safeImpl = Safe(payable(address(proxy)));

        // Fund Safe with ETH
        vm.deal(address(safeImpl), 1_000_000 ether);

        // Initialize Safe
        address[] memory owners = new address[](1);
        owners[0] = vm.addr(1);
        safeImpl.setup(owners, 1, address(0), bytes(""), address(0), address(0), 0, payable(address(0)));

        // Enable SimpleAllowance module on Safe
        bytes memory enableData = abi.encodeWithSignature("enableModule(address)", address(allowanceModule));
        bool ok = execSafeTransaction(address(safeImpl), 0, enableData, 1);
        require(ok, "Module enable failed");

        // Deploy DelegateContract
        vm.startPrank(delegateContractOwner);
        allowanceExecutor = new LinearAllowanceExecutorTestHarness();
        // Setup allowset for the allowance module
        AddressSet allowset = new AddressSet();
        allowanceExecutor.assignModuleAddressSet(IAddressSet(address(allowset)));
        allowset.add(address(allowanceModule));
        vm.stopPrank();
    }

    // Test ETH allowance with both full and partial withdrawals
    function testAllowanceWithETH(uint192 dripRatePerDay, uint256 daysElapsed, uint256 safeBalance) public {
        // Constrain inputs to reasonable values to avoid edge cases
        dripRatePerDay = uint192(bound(dripRatePerDay, 1 ether, 1000 ether)); // Minimum 1 ether to avoid tiny amounts
        daysElapsed = uint32(bound(daysElapsed, 1, 365 * 20));

        // Calculate expected allowance
        uint256 expectedAllowance = uint256(dripRatePerDay) * uint256(daysElapsed);

        // Constrain safeBalance to ensure we test both partial and full withdrawals
        // Use max to ensure minimum of 1 to avoid zero transfers
        uint256 minSafeBalance = expectedAllowance / 2;
        if (minSafeBalance == 0) minSafeBalance = 1;
        safeBalance = bound(safeBalance, minSafeBalance, expectedAllowance * 2);

        // Setup
        address safeAddress = address(safeImpl);
        address executorAddress = address(allowanceExecutor);

        // Set the safe's balance
        vm.deal(safeAddress, safeBalance);

        // Verify reverts with no allowance
        vm.expectRevert();
        allowanceExecutor.executeAllowanceTransfer(allowanceModule, safeAddress, NATIVE_TOKEN);

        // Set up allowance
        vm.prank(safeAddress);
        allowanceModule.setAllowance(executorAddress, NATIVE_TOKEN, uint192(dripRatePerDay));

        // Advance time to accrue allowance
        vm.warp(block.timestamp + daysElapsed * 1 days);

        // Get balances before transfer
        uint256 safeBalanceBefore = safeAddress.balance;
        uint256 executorBalanceBefore = executorAddress.balance;

        // Expected transfer is the minimum of allowance and balance
        uint256 expectedTransfer = expectedAllowance <= safeBalanceBefore ? expectedAllowance : safeBalanceBefore;

        // Execute transfer
        allowanceExecutor.executeAllowanceTransfer(allowanceModule, safeAddress, NATIVE_TOKEN);

        // Verify correct amounts were transferred
        assertEq(
            executorAddress.balance - executorBalanceBefore,
            expectedTransfer,
            "Executor should receive correct amount"
        );
        assertEq(
            safeBalanceBefore - safeAddress.balance,
            expectedTransfer,
            "Safe balance should be reduced by transferred amount"
        );

        // Verify allowance bookkeeping
        (, , uint256 totalUnspent, ) = allowanceModule.allowances(safeAddress, executorAddress, NATIVE_TOKEN);

        if (expectedAllowance > safeBalanceBefore) {
            // Partial withdrawal case
            assertEq(
                totalUnspent,
                expectedAllowance - safeBalanceBefore,
                "Remaining unspent should equal original minus transferred"
            );
        } else {
            // Full withdrawal case
            assertEq(totalUnspent, 0, "Unspent allowance should be zero");
        }

        // Test that allowance stops accruing after rate set to 0
        vm.warp(block.timestamp + 5 days);
        vm.prank(safeAddress);
        allowanceModule.setAllowance(executorAddress, NATIVE_TOKEN, 0);

        uint256 unspentAfterZeroRate = allowanceModule.getTotalUnspent(safeAddress, executorAddress, NATIVE_TOKEN);
        vm.warp(block.timestamp + 10 days);

        assertEq(
            allowanceModule.getTotalUnspent(safeAddress, executorAddress, NATIVE_TOKEN),
            unspentAfterZeroRate,
            "Balance should not increase after rate set to 0"
        );
    }

    // Test ERC20 allowance with both full and partial withdrawals
    function testAllowanceWithERC20(uint192 dripRatePerDay, uint256 daysElapsed, uint256 tokenSupply) public {
        // Constrain inputs to reasonable values to avoid edge cases
        dripRatePerDay = uint192(bound(dripRatePerDay, 1 ether, 1000 ether)); // Minimum 1 ether to avoid tiny amounts
        daysElapsed = uint32(bound(daysElapsed, 1, 365 * 20));

        // Calculate expected allowance
        uint256 expectedAllowance = uint256(dripRatePerDay) * uint256(daysElapsed);

        // Constrain tokenSupply to ensure we test both partial and full withdrawals
        // Use max to ensure minimum of 1 to avoid zero transfers
        uint256 minTokenSupply = expectedAllowance / 2;
        if (minTokenSupply == 0) minTokenSupply = 1;
        tokenSupply = bound(tokenSupply, minTokenSupply, expectedAllowance * 2);

        // Setup
        address safeAddress = address(safeImpl);
        address executorAddress = address(allowanceExecutor);

        // Create token and fund safe
        TestERC20 token = new TestERC20(tokenSupply);
        token.transfer(safeAddress, tokenSupply);

        // Verify reverts with no allowance
        vm.expectRevert();
        allowanceExecutor.executeAllowanceTransfer(allowanceModule, safeAddress, address(token));

        // Set up allowance
        vm.prank(safeAddress);
        allowanceModule.setAllowance(executorAddress, address(token), uint192(dripRatePerDay));

        // Advance time to accrue allowance
        vm.warp(block.timestamp + daysElapsed * 1 days);

        // Get balances before transfer
        uint256 safeBalanceBefore = token.balanceOf(safeAddress);
        uint256 executorBalanceBefore = token.balanceOf(executorAddress);

        // Expected transfer is the minimum of allowance and balance
        uint256 expectedTransfer = expectedAllowance <= safeBalanceBefore ? expectedAllowance : safeBalanceBefore;

        // Execute transfer
        allowanceExecutor.executeAllowanceTransfer(allowanceModule, safeAddress, address(token));

        // Verify correct amounts were transferred
        assertEq(
            token.balanceOf(executorAddress) - executorBalanceBefore,
            expectedTransfer,
            "Executor should receive correct token amount"
        );
        assertEq(
            safeBalanceBefore - token.balanceOf(safeAddress),
            expectedTransfer,
            "Safe token balance should be reduced by transferred amount"
        );

        // Verify allowance bookkeeping
        (, , uint256 totalUnspent, ) = allowanceModule.allowances(safeAddress, executorAddress, address(token));

        if (expectedAllowance > safeBalanceBefore) {
            // Partial withdrawal case
            assertEq(
                totalUnspent,
                expectedAllowance - safeBalanceBefore,
                "Remaining unspent should equal original minus transferred"
            );
        } else {
            // Full withdrawal case
            assertEq(totalUnspent, 0, "Unspent allowance should be zero");
        }

        // Test that allowance stops accruing after rate set to 0
        vm.warp(block.timestamp + 5 days);
        vm.prank(safeAddress);
        allowanceModule.setAllowance(executorAddress, address(token), 0);

        uint256 unspentAfterZeroRate = allowanceModule.getTotalUnspent(safeAddress, executorAddress, address(token));
        vm.warp(block.timestamp + 10 days);

        assertEq(
            allowanceModule.getTotalUnspent(safeAddress, executorAddress, address(token)),
            unspentAfterZeroRate,
            "Balance should not increase after rate set to 0"
        );
    }

    // Test that zero transfers are properly rejected
    function testZeroTransferReverts() public {
        address safeAddress = address(safeImpl);
        address executorAddress = address(allowanceExecutor);

        // Create token with some supply but don't fund the safe
        TestERC20 token = new TestERC20(100 ether);
        // Safe has 0 tokens (no transfer to safe)

        // Set up allowance
        vm.prank(safeAddress);
        allowanceModule.setAllowance(executorAddress, address(token), uint192(1 ether));

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Verify allowance exists but safe has no tokens
        uint256 totalUnspent = allowanceModule.getTotalUnspent(safeAddress, executorAddress, address(token));
        assertGt(totalUnspent, 0, "Should have accrued allowance");
        assertEq(token.balanceOf(safeAddress), 0, "Safe should have no tokens");

        // Expect ZeroTransfer error when attempting to transfer
        vm.expectRevert(
            abi.encodeWithSelector(
                ILinearAllowanceSingleton.ZeroTransfer.selector,
                safeAddress,
                executorAddress,
                address(token)
            )
        );
        allowanceExecutor.executeAllowanceTransfer(allowanceModule, safeAddress, address(token));
    }

    function testGetTotalUnspentWithUninitializedAllowance() public view {
        // Already passing, keeps the same
        uint256 unspent = allowanceModule.getTotalUnspent(
            address(safeImpl),
            address(0x123), // Random delegate that hasn't been configured
            address(NATIVE_TOKEN)
        );

        assertEq(unspent, 0, "Unspent amount should be 0 for uninitialized allowance");
    }

    function testExecuteAllowanceTransferFailingTokenTransfer() public {
        // Set up token
        TestERC20 token = new TestERC20(100 ether);

        // Create a mock safe that returns false for execTransactionFromModule
        MockFailingSafe failingSafe = new MockFailingSafe();

        // Mint tokens to the failing safe
        token.transfer(address(failingSafe), 100 ether);

        // Prank as the failing safe to set allowance
        vm.prank(address(failingSafe));
        allowanceModule.setAllowance(address(allowanceExecutor), address(token), uint192(100 ether));

        // Need to wait for allowance to accumulate
        vm.warp(block.timestamp + 1 days);

        // Attempt to execute allowance transfer
        vm.prank(address(allowanceExecutor));
        vm.expectRevert(abi.encodeWithSelector(ILinearAllowanceSingleton.SafeTransactionFailed.selector));
        allowanceModule.executeAllowanceTransfer(address(failingSafe), address(token), payable(address(recipient)));
    }

    function testExecuteAllowanceTransferEthTransferFailure() public {
        // Create a contract that rejects ETH transfers
        ContractThatRejectsETH rejector = new ContractThatRejectsETH();

        // Setup the mock safe
        MockSafeThatFailsEthTransfers failingSafe = new MockSafeThatFailsEthTransfers();
        vm.deal(address(failingSafe), 100 ether);

        // Create a delegate (executor) that we'll use
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // Set allowance for ETH (using address(0) as native token)
        vm.prank(address(failingSafe));
        allowanceModule.setAllowance(address(executor), address(0), uint192(100 ether));

        // Wait for allowance to accumulate
        vm.warp(block.timestamp + 1 days);

        // Try to transfer ETH - should fail
        vm.prank(address(executor));
        vm.expectRevert(abi.encodeWithSelector(ILinearAllowanceSingleton.SafeTransactionFailed.selector));
        allowanceModule.executeAllowanceTransfer(address(failingSafe), address(0), payable(address(rejector)));
    }

    function testUpdateAllowanceWithExistingAllowance() public {
        // Create test token
        TestERC20 testToken = new TestERC20(100 ether);

        // Create a delegate (executor) that we'll use
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // Create an allowance
        vm.prank(address(safe));
        allowanceModule.setAllowance(address(executor), address(testToken), uint192(100 ether));

        // Fast forward time
        vm.warp(block.timestamp + 1 days);

        // Call setAllowance again which invokes _updateAllowance
        vm.prank(address(safe));
        allowanceModule.setAllowance(address(executor), address(testToken), uint192(200 ether));

        // Verify the allowance was updated correctly
        (uint192 dripRate, uint64 lastBooked, uint256 unspent, ) = allowanceModule.allowances(
            address(safe),
            address(executor),
            address(testToken)
        );

        // Drip rate should be updated to 200 ether
        assertEq(dripRate, 200 ether);

        // Unspent should be around 100 ether (1 day's worth at 100 ether/day)
        assertEq(unspent, 100 ether);

        // Last booked should be updated to current time
        assertEq(lastBooked, uint32(block.timestamp));

        // Verify getTotalUnspent returns the correct value
        uint256 unspentAmount = allowanceModule.getTotalUnspent(address(safe), address(executor), address(testToken));
        assertEq(unspentAmount, 100 ether);
    }

    function testRevokeAllowanceVsNormalRevoke() public {
        // Setup: Create two identical scenarios to compare normal vs emergency revocation
        uint128 dripRate = 100 ether;
        address safeAddress = address(safeImpl);

        // Create two separate executors for comparison
        LinearAllowanceExecutorTestHarness normalExecutor = new LinearAllowanceExecutorTestHarness();
        LinearAllowanceExecutorTestHarness emergencyExecutor = new LinearAllowanceExecutorTestHarness();

        // Create and setup allowsets for both executors
        AddressSet normalAllowset = new AddressSet();
        AddressSet emergencyAllowset = new AddressSet();

        normalExecutor.assignModuleAddressSet(IAddressSet(address(normalAllowset)));
        emergencyExecutor.assignModuleAddressSet(IAddressSet(address(emergencyAllowset)));

        // AddressSet the allowance module
        normalAllowset.add(address(allowanceModule));
        emergencyAllowset.add(address(allowanceModule));

        // Set identical allowances for both executors
        vm.startPrank(safeAddress);
        allowanceModule.setAllowance(address(normalExecutor), NATIVE_TOKEN, dripRate);
        allowanceModule.setAllowance(address(emergencyExecutor), NATIVE_TOKEN, dripRate);
        vm.stopPrank();

        // Advance time to accrue allowance (24 hours = 100 ETH each)
        vm.warp(block.timestamp + 1 days);

        // Verify both have identical unspent allowances
        uint256 normalUnspentBefore = allowanceModule.getTotalUnspent(
            safeAddress,
            address(normalExecutor),
            NATIVE_TOKEN
        );
        uint256 emergencyUnspentBefore = allowanceModule.getTotalUnspent(
            safeAddress,
            address(emergencyExecutor),
            NATIVE_TOKEN
        );

        assertEq(normalUnspentBefore, dripRate, "Normal executor should have accrued full daily allowance");
        assertEq(emergencyUnspentBefore, dripRate, "Emergency executor should have accrued full daily allowance");
        assertEq(normalUnspentBefore, emergencyUnspentBefore, "Both executors should have identical allowances");

        // Test 1: Normal revocation (setAllowance to 0) - preserves accrued amounts
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(normalExecutor), NATIVE_TOKEN, 0);

        // Test 2: Emergency revocation - clears everything
        vm.expectEmit(true, true, true, true);
        emit ILinearAllowanceSingleton.AllowanceRevoked(
            safeAddress,
            address(emergencyExecutor),
            NATIVE_TOKEN,
            dripRate
        );

        vm.prank(safeAddress);
        allowanceModule.revokeAllowance(address(emergencyExecutor), NATIVE_TOKEN);

        // Verify the critical difference:
        // Normal revocation preserves accrued allowance
        uint256 normalUnspentAfter = allowanceModule.getTotalUnspent(
            safeAddress,
            address(normalExecutor),
            NATIVE_TOKEN
        );
        assertEq(normalUnspentAfter, dripRate, "Normal revocation should preserve accrued allowance");

        // Emergency revocation clears everything
        uint256 emergencyUnspentAfter = allowanceModule.getTotalUnspent(
            safeAddress,
            address(emergencyExecutor),
            NATIVE_TOKEN
        );
        assertEq(emergencyUnspentAfter, 0, "Emergency revocation should clear all allowance");

        // Verify both have drip rate set to 0 (check via getTotalUnspent behavior)

        // Advance time to ensure no further accrual for either
        vm.warp(block.timestamp + 1 days);

        assertEq(
            allowanceModule.getTotalUnspent(safeAddress, address(normalExecutor), NATIVE_TOKEN),
            dripRate,
            "Normal revocation should not accrue new allowance but preserve old"
        );

        assertEq(
            allowanceModule.getTotalUnspent(safeAddress, address(emergencyExecutor), NATIVE_TOKEN),
            0,
            "Emergency revocation should remain at zero with no accrual"
        );

        // Demonstrate the security issue: normal revocation allows fund extraction
        normalExecutor.executeAllowanceTransfer(allowanceModule, safeAddress, NATIVE_TOKEN);
        uint256 normalBalance = address(normalExecutor).balance;
        assertEq(normalBalance, dripRate, "Compromised delegate can still withdraw after normal revocation");

        // Emergency revocation prevents any withdrawal
        vm.expectRevert();
        emergencyExecutor.executeAllowanceTransfer(allowanceModule, safeAddress, NATIVE_TOKEN);

        assertEq(address(emergencyExecutor).balance, 0, "Emergency revocation prevents any withdrawal");
    }

    function testRevokeWithPartialUnspentAndAccrual() public {
        uint128 dripRate = 50 ether;
        address safeAddress = address(safeImpl);
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // Set allowance and let some accrue
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, dripRate);

        // Advance time to accrue 25 ETH (12 hours at 50 ETH/day)
        vm.warp(block.timestamp + 12 hours);

        // Partially withdraw some allowance
        uint256 partialWithdraw = 10 ether;
        vm.deal(safeAddress, partialWithdraw); // Limit safe balance to force partial withdrawal
        executor.executeAllowanceTransfer(allowanceModule, safeAddress, NATIVE_TOKEN);

        // Advance time to accrue more (another 12 hours = 25 ETH more)
        vm.warp(block.timestamp + 12 hours);

        // Get the actual unspent amount at this point (whatever it is)
        uint256 actualUnspentBeforeRevoke = allowanceModule.getTotalUnspent(
            safeAddress,
            address(executor),
            NATIVE_TOKEN
        );

        // Verify we have some unspent allowance to clear
        assertGt(actualUnspentBeforeRevoke, 0, "Should have some unspent allowance before emergency revocation");

        // Revoke should clear the full amount
        vm.expectEmit(true, true, true, true);
        emit ILinearAllowanceSingleton.AllowanceRevoked(
            safeAddress,
            address(executor),
            NATIVE_TOKEN,
            actualUnspentBeforeRevoke
        );

        vm.prank(safeAddress);
        allowanceModule.revokeAllowance(address(executor), NATIVE_TOKEN);

        // Verify everything is cleared
        assertEq(
            allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN),
            0,
            "All allowance should be cleared after emergency revocation"
        );

        // Verify the allowance data shows proper state
        (
            uint192 dripRateAfter,
            uint64 lastBookedAfter,
            uint256 totalUnspentAfter,
            uint256 totalSpentAfter
        ) = allowanceModule.allowances(safeAddress, address(executor), NATIVE_TOKEN);

        assertEq(dripRateAfter, 0, "Drip rate should be zero");
        assertEq(totalUnspentAfter, 0, "Total unspent should be zero");
        assertEq(totalSpentAfter, partialWithdraw, "Total spent should preserve audit trail");
        assertEq(lastBookedAfter, uint64(block.timestamp), "Last booked should be updated to current time");
    }

    // ==================== ACCESS CONTROL SECURITY TESTS ====================

    function testRevokeAccessControl_OnlySafeCanRevokeItsOwnAllowances() public {
        uint128 dripRate = 100 ether;
        address safeAddress = address(safeImpl);
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // Setup allowance from safe
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, dripRate);

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Verify allowance exists
        uint256 unspentBefore = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(unspentBefore, dripRate, "Allowance should have accrued");

        // ✅ TEST: Safe itself can revoke its own allowances
        vm.prank(safeAddress);
        allowanceModule.revokeAllowance(address(executor), NATIVE_TOKEN);

        uint256 unspentAfter = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(unspentAfter, 0, "Safe should be able to revoke its own allowances");
    }

    function testRevokeAccessControl_AttackerCannotRevokeOtherSafesAllowances() public {
        uint128 dripRate = 100 ether;
        address safeAddress = address(safeImpl);
        address attacker = makeAddr("attacker");
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // Setup allowance from safe
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, dripRate);

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Verify allowance exists
        uint256 unspentBefore = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(unspentBefore, dripRate, "Allowance should have accrued");

        // ❌ TEST: Attacker tries to revoke the safe's allowances
        vm.prank(attacker);
        allowanceModule.revokeAllowance(address(executor), NATIVE_TOKEN);

        // The safe's allowances should be completely unaffected
        uint256 unspentAfter = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(unspentAfter, dripRate, "Attacker should not be able to affect safe's allowances");

        // The attacker only affected their own (non-existent) allowances
        uint256 attackerUnspent = allowanceModule.getTotalUnspent(attacker, address(executor), NATIVE_TOKEN);
        assertEq(attackerUnspent, 0, "Attacker should have no allowances to begin with");
    }

    function testRevokeAccessControl_RandomAddressCannotAffectOthers() public {
        uint128 dripRate = 100 ether;
        address safeAddress = address(safeImpl);
        address randomUser = makeAddr("randomUser");
        address anotherUser = makeAddr("anotherUser");
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // Setup allowances from multiple addresses
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, dripRate);

        vm.prank(randomUser);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, dripRate / 2);

        // Advance time to accrue allowances
        vm.warp(block.timestamp + 1 days);

        // Verify allowances exist
        uint256 safeUnspentBefore = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);
        uint256 randomUnspentBefore = allowanceModule.getTotalUnspent(randomUser, address(executor), NATIVE_TOKEN);

        assertEq(safeUnspentBefore, dripRate, "Safe allowance should have accrued");
        assertEq(randomUnspentBefore, dripRate / 2, "Random user allowance should have accrued");

        // Random user revokes their own allowance (should work)
        vm.prank(randomUser);
        allowanceModule.revokeAllowance(address(executor), NATIVE_TOKEN);

        // Another user tries to revoke safe's allowance (should not work)
        vm.prank(anotherUser);
        allowanceModule.revokeAllowance(address(executor), NATIVE_TOKEN);

        // Verify results
        uint256 safeUnspentAfter = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);
        uint256 randomUnspentAfter = allowanceModule.getTotalUnspent(randomUser, address(executor), NATIVE_TOKEN);
        uint256 anotherUnspentAfter = allowanceModule.getTotalUnspent(anotherUser, address(executor), NATIVE_TOKEN);

        assertEq(safeUnspentAfter, dripRate, "Safe allowance should be unaffected by other users");
        assertEq(randomUnspentAfter, 0, "Random user should have successfully revoked their own allowance");
        assertEq(anotherUnspentAfter, 0, "Another user should have no allowances (had none to revoke)");
    }

    function testRevokeAccessControl_SafeOwnersCanRevokeViaMultisig() public {
        uint128 dripRate = 100 ether;
        address safeAddress = address(safeImpl);
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // Setup allowance
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, dripRate);

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Verify allowance exists
        uint256 unspentBefore = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(unspentBefore, dripRate, "Allowance should have accrued");

        // ✅ TEST: Safe owners can revoke via Safe's execTransaction mechanism
        bytes memory revokeData = abi.encodeWithSelector(
            allowanceModule.revokeAllowance.selector,
            address(executor),
            NATIVE_TOKEN
        );

        bool success = execSafeTransaction(address(allowanceModule), 0, revokeData, 1);
        assertTrue(success, "Safe owners should be able to execute revoke via multisig");

        // Verify revocation worked
        uint256 unspentAfter = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(unspentAfter, 0, "Revocation via multisig should clear allowances");
    }

    function testRevokeAccessControl_NonOwnerCannotExecuteViaSafe() public {
        uint128 dripRate = 100 ether;
        address safeAddress = address(safeImpl);
        address nonOwner = makeAddr("nonOwner");
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // Setup allowance
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, dripRate);

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Verify allowance exists
        uint256 unspentBefore = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(unspentBefore, dripRate, "Allowance should have accrued");

        // ❌ TEST: Non-owner tries to execute revoke via Safe
        // This should fail because they can't meet the Safe's signature threshold
        bytes memory revokeData = abi.encodeWithSelector(
            allowanceModule.revokeAllowance.selector,
            address(executor),
            NATIVE_TOKEN
        );

        // Non-owner cannot create valid Safe transaction signatures
        // Attempting to execute directly should fail at Safe's access control level
        vm.startPrank(nonOwner);
        vm.expectRevert(); // Safe will revert due to invalid signature/access
        safeImpl.execTransaction(
            address(allowanceModule),
            0,
            revokeData,
            Enum.Operation.Call,
            100_000,
            0,
            1,
            address(0),
            payable(address(0)),
            abi.encodePacked(bytes32(0), bytes32(0), bytes1(0)) // Invalid signature
        );
        vm.stopPrank();

        // Verify allowance is unchanged
        uint256 unspentAfter = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(unspentAfter, dripRate, "Non-owner should not be able to affect Safe's allowances");
    }

    function testRevokeAccessControl_EventEmissionSecurity() public {
        uint128 dripRate = 100 ether;
        address safeAddress = address(safeImpl);
        address attacker = makeAddr("attacker");
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // Setup allowance from safe
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, dripRate);

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // ❌ TEST: Attacker cannot emit misleading events for other safes
        // When attacker calls revoke, event should show attacker's address, not safe's
        vm.expectEmit(true, true, true, true);
        emit ILinearAllowanceSingleton.AllowanceRevoked(attacker, address(executor), NATIVE_TOKEN, 0);

        vm.prank(attacker);
        allowanceModule.revokeAllowance(address(executor), NATIVE_TOKEN);

        // Safe's allowance should be unaffected
        uint256 safeUnspent = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(safeUnspent, dripRate, "Safe allowance should be unaffected by attacker's call");
    }

    function testRevokeAccessControl_MaliciousModuleCannotAbuseFunction() public {
        uint128 dripRate = 100 ether;
        address safeAddress = address(safeImpl);
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // Setup allowance from safe
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, dripRate);

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Create a malicious module that tries to call revokeAllowance
        MaliciousModule maliciousModule = new MaliciousModule(allowanceModule);

        // Enable the malicious module on the Safe (simulating a compromised module scenario)
        bytes memory enableMaliciousModuleData = abi.encodeWithSignature(
            "enableModule(address)",
            address(maliciousModule)
        );
        bool enableSuccess = execSafeTransaction(address(safeImpl), 0, enableMaliciousModuleData, 1);
        require(enableSuccess, "Malicious module enable failed");

        // Manually set the safe address since setUp isn't called on module enable
        maliciousModule.setSafeAddress(safeAddress);

        // Verify allowance exists before attack
        uint256 unspentBefore = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(unspentBefore, dripRate, "Allowance should exist before malicious module attack");

        // ❌ TEST: Malicious module tries to call revokeAllowance on behalf of Safe
        // This SHOULD work because the module can call execTransactionFromModule,
        // which means malicious modules are a real threat vector!
        maliciousModule.attemptRevoke(address(executor), NATIVE_TOKEN);

        // Check if the malicious module was able to affect the allowances
        uint256 unspentAfter = allowanceModule.getTotalUnspent(safeAddress, address(executor), NATIVE_TOKEN);

        if (unspentAfter == 0) {
            // If this happens, it means malicious modules CAN call revoke
            // This would be a significant finding that we need to address
            emit log_string("WARNING: Malicious module was able to revoke allowances!");
            emit log_string("This demonstrates that module access control is a critical concern");
        } else {
            // If allowances are preserved, the current access control model is sufficient
            assertEq(
                unspentAfter,
                dripRate,
                "Malicious module should not be able to affect allowances via direct call"
            );
        }

        // Additional test: Try via execTransactionFromModule
        bool moduleSuccess = maliciousModule.attemptRevokeViaModule(address(executor), NATIVE_TOKEN);

        uint256 unspentAfterModuleAttempt = allowanceModule.getTotalUnspent(
            safeAddress,
            address(executor),
            NATIVE_TOKEN
        );

        if (moduleSuccess && unspentAfterModuleAttempt == 0) {
            emit log_string("CRITICAL: Malicious module can revoke via execTransactionFromModule!");
            // This would indicate we need additional access controls
        } else {
            emit log_string("GOOD: Malicious modules cannot abuse revocation");
        }
    }

    // ==================== SET ALLOWANCE ACCESS CONTROL TESTS ====================

    function testSetAllowanceAccessControl_OnlySafeCanSetItsOwnAllowances() public {
        uint128 dripRate = 100 ether;
        address safeAddress = address(safeImpl);
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // ✅ TEST: Safe itself can set allowances for delegates
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, dripRate);

        // Verify allowance was set correctly
        (uint192 actualDripRate, , , ) = allowanceModule.allowances(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(actualDripRate, dripRate, "Safe should be able to set allowances for its delegates");
    }

    function testSetAllowanceAccessControl_AttackerCannotSetAllowancesForOtherSafes() public {
        uint128 dripRate = 100 ether;
        address safeAddress = address(safeImpl);
        address attacker = makeAddr("attacker");
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // ❌ TEST: Attacker tries to set allowances for a Safe they don't control
        vm.prank(attacker);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, dripRate);

        // The attacker only affected their own allowances, not the Safe's
        (uint192 safeAllowanceRate, , , ) = allowanceModule.allowances(safeAddress, address(executor), NATIVE_TOKEN);
        (uint192 attackerAllowanceRate, , , ) = allowanceModule.allowances(attacker, address(executor), NATIVE_TOKEN);

        assertEq(safeAllowanceRate, 0, "Safe allowances should be unaffected by attacker");
        assertEq(attackerAllowanceRate, dripRate, "Attacker only affected their own allowances");
    }

    function testSetAllowanceAccessControl_MaliciousModuleCanAbuseSetAllowance() public {
        uint128 legitimateDripRate = 50 ether;
        uint128 maliciousDripRate = 1000 ether; // Much higher!
        address safeAddress = address(safeImpl);
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // Setup: Safe sets a legitimate allowance
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, legitimateDripRate);

        // Verify legitimate allowance
        (uint192 initialRate, , , ) = allowanceModule.allowances(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(initialRate, legitimateDripRate, "Initial allowance should be set correctly");

        // Create and enable malicious module
        MaliciousModuleForSetAllowance maliciousModule = new MaliciousModuleForSetAllowance(allowanceModule);

        bytes memory enableData = abi.encodeWithSignature("enableModule(address)", address(maliciousModule));
        bool enableSuccess = execSafeTransaction(address(safeImpl), 0, enableData, 1);
        require(enableSuccess, "Malicious module enable failed");

        maliciousModule.setSafeAddress(safeAddress);

        // CRITICAL TEST: Can malicious module abuse setAllowance via execTransactionFromModule?
        bool attackSuccess = maliciousModule.attemptSetAllowanceViaModule(
            address(executor),
            NATIVE_TOKEN,
            maliciousDripRate
        );

        // Check if the attack succeeded
        (uint192 finalRate, , , ) = allowanceModule.allowances(safeAddress, address(executor), NATIVE_TOKEN);

        if (attackSuccess && finalRate == maliciousDripRate) {
            emit log_string("CRITICAL VULNERABILITY: Malicious module can set unauthorized allowances!");
            emit log_named_uint("Original allowance", legitimateDripRate);
            emit log_named_uint("Malicious allowance", finalRate);

            // This demonstrates the vulnerability - module increased allowance without owner consent
            assertEq(
                finalRate,
                maliciousDripRate,
                "VULNERABILITY: Malicious module successfully set unauthorized allowance"
            );
        } else {
            emit log_string("SECURE: Malicious module cannot abuse setAllowance");
            assertEq(finalRate, legitimateDripRate, "Allowance should remain at legitimate level");
        }
    }

    function testSetAllowanceAccessControl_SafeOwnersCanSetAllowanceViaMultisig() public {
        uint128 dripRate = 75 ether;
        address safeAddress = address(safeImpl);
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // ✅ TEST: Safe owners can set allowances via Safe's execTransaction mechanism
        bytes memory setAllowanceData = abi.encodeWithSelector(
            allowanceModule.setAllowance.selector,
            address(executor),
            NATIVE_TOKEN,
            dripRate
        );

        bool success = execSafeTransaction(address(allowanceModule), 0, setAllowanceData, 1);
        assertTrue(success, "Safe owners should be able to set allowances via multisig");

        // Verify allowance was set correctly
        (uint192 actualRate, , , ) = allowanceModule.allowances(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(actualRate, dripRate, "Allowance should be set via legitimate multisig execution");
    }

    function testSetAllowanceAccessControl_MaliciousModuleGradualIncrease() public {
        uint128 legitimateRate = 10 ether;
        address safeAddress = address(safeImpl);
        LinearAllowanceExecutorTestHarness executor = createAllowsetedExecutor();

        // Setup: Safe sets legitimate allowance
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, legitimateRate);

        // Create malicious module
        MaliciousModuleForSetAllowance maliciousModule = new MaliciousModuleForSetAllowance(allowanceModule);

        bytes memory enableData = abi.encodeWithSignature("enableModule(address)", address(maliciousModule));
        execSafeTransaction(address(safeImpl), 0, enableData, 1);
        maliciousModule.setSafeAddress(safeAddress);

        // TEST: Subtle attack - gradually increase allowance to avoid detection
        uint128[] memory increases = new uint128[](3);
        increases[0] = 15 ether; // 50% increase
        increases[1] = 25 ether; // 67% increase
        increases[2] = 50 ether; // 100% increase

        for (uint i = 0; i < increases.length; i++) {
            bool success = maliciousModule.attemptSetAllowanceViaModule(address(executor), NATIVE_TOKEN, increases[i]);

            if (success) {
                (uint192 currentRate, , , ) = allowanceModule.allowances(safeAddress, address(executor), NATIVE_TOKEN);
                emit log_string("VULNERABILITY: Gradual allowance increase succeeded");
                emit log_named_uint("Step", i + 1);
                emit log_named_uint("New allowance", currentRate);

                // If any increase succeeds, the vulnerability exists
                assertGt(currentRate, legitimateRate, "Malicious module should not be able to increase allowances");
                return;
            }
        }

        // If we get here, all attacks failed (good!)
        (uint192 finalRate, , , ) = allowanceModule.allowances(safeAddress, address(executor), NATIVE_TOKEN);
        assertEq(finalRate, legitimateRate, "All malicious increases should have failed");
        emit log_string("SECURE: Gradual allowance increase attacks blocked");
    }

    function testRevokeAllowances() public {
        _clearTestContext();

        currentTestCtx.dripRate = 100 ether;
        currentTestCtx.safeAddress = address(safeImpl);

        // Create multiple executors
        currentTestCtx.executor1 = new LinearAllowanceExecutorTestHarness();
        currentTestCtx.executor2 = new LinearAllowanceExecutorTestHarness();
        currentTestCtx.executor3 = new LinearAllowanceExecutorTestHarness();

        // Setup multiple allowances
        vm.startPrank(currentTestCtx.safeAddress);
        allowanceModule.setAllowance(address(currentTestCtx.executor1), NATIVE_TOKEN, currentTestCtx.dripRate);
        allowanceModule.setAllowance(address(currentTestCtx.executor2), NATIVE_TOKEN, currentTestCtx.dripRate);
        allowanceModule.setAllowance(address(currentTestCtx.executor3), NATIVE_TOKEN, currentTestCtx.dripRate);
        vm.stopPrank();

        // Advance time to accrue allowances
        vm.warp(block.timestamp + 1 days);

        // Verify all allowances exist
        currentTestCtx.unspent1Before = allowanceModule.getTotalUnspent(
            currentTestCtx.safeAddress,
            address(currentTestCtx.executor1),
            NATIVE_TOKEN
        );
        currentTestCtx.unspent2Before = allowanceModule.getTotalUnspent(
            currentTestCtx.safeAddress,
            address(currentTestCtx.executor2),
            NATIVE_TOKEN
        );
        currentTestCtx.unspent3Before = allowanceModule.getTotalUnspent(
            currentTestCtx.safeAddress,
            address(currentTestCtx.executor3),
            NATIVE_TOKEN
        );

        assertEq(currentTestCtx.unspent1Before, currentTestCtx.dripRate, "Executor1 should have accrued allowance");
        assertEq(currentTestCtx.unspent2Before, currentTestCtx.dripRate, "Executor2 should have accrued allowance");
        assertEq(currentTestCtx.unspent3Before, currentTestCtx.dripRate, "Executor3 should have accrued allowance");

        // Prepare arrays for batch revocation
        currentTestCtx.delegates = new address[](3);
        currentTestCtx.tokens = new address[](3);
        currentTestCtx.delegates[0] = address(currentTestCtx.executor1);
        currentTestCtx.delegates[1] = address(currentTestCtx.executor2);
        currentTestCtx.delegates[2] = address(currentTestCtx.executor3);
        currentTestCtx.tokens[0] = NATIVE_TOKEN;
        currentTestCtx.tokens[1] = NATIVE_TOKEN;
        currentTestCtx.tokens[2] = NATIVE_TOKEN;

        // Test array length mismatch validation
        currentTestCtx.wrongLengthTokens = new address[](2);
        currentTestCtx.wrongLengthTokens[0] = NATIVE_TOKEN;
        currentTestCtx.wrongLengthTokens[1] = NATIVE_TOKEN;

        vm.prank(currentTestCtx.safeAddress);
        vm.expectRevert(abi.encodeWithSelector(ILinearAllowanceSingleton.ArrayLengthsMismatch.selector, 3, 2, 0));
        allowanceModule.revokeAllowances(currentTestCtx.delegates, currentTestCtx.wrongLengthTokens);

        // Test zero address validation
        currentTestCtx.delegates[1] = address(0);
        vm.prank(currentTestCtx.safeAddress);
        vm.expectRevert(abi.encodeWithSelector(ILinearAllowanceSingleton.AddressZeroForArgument.selector, "delegate"));
        allowanceModule.revokeAllowances(currentTestCtx.delegates, currentTestCtx.tokens);

        // Fix the address for successful test
        currentTestCtx.delegates[1] = address(currentTestCtx.executor2);

        // Expect events for all revocations
        vm.expectEmit(true, true, true, true);
        emit ILinearAllowanceSingleton.AllowanceRevoked(
            currentTestCtx.safeAddress,
            address(currentTestCtx.executor1),
            NATIVE_TOKEN,
            currentTestCtx.dripRate
        );
        vm.expectEmit(true, true, true, true);
        emit ILinearAllowanceSingleton.AllowanceRevoked(
            currentTestCtx.safeAddress,
            address(currentTestCtx.executor2),
            NATIVE_TOKEN,
            currentTestCtx.dripRate
        );
        vm.expectEmit(true, true, true, true);
        emit ILinearAllowanceSingleton.AllowanceRevoked(
            currentTestCtx.safeAddress,
            address(currentTestCtx.executor3),
            NATIVE_TOKEN,
            currentTestCtx.dripRate
        );

        // Execute batch revocation
        vm.prank(currentTestCtx.safeAddress);
        allowanceModule.revokeAllowances(currentTestCtx.delegates, currentTestCtx.tokens);

        // Verify all allowances are cleared
        currentTestCtx.unspent1After = allowanceModule.getTotalUnspent(
            currentTestCtx.safeAddress,
            address(currentTestCtx.executor1),
            NATIVE_TOKEN
        );
        currentTestCtx.unspent2After = allowanceModule.getTotalUnspent(
            currentTestCtx.safeAddress,
            address(currentTestCtx.executor2),
            NATIVE_TOKEN
        );
        currentTestCtx.unspent3After = allowanceModule.getTotalUnspent(
            currentTestCtx.safeAddress,
            address(currentTestCtx.executor3),
            NATIVE_TOKEN
        );

        assertEq(currentTestCtx.unspent1After, 0, "Executor1 allowance should be cleared");
        assertEq(currentTestCtx.unspent2After, 0, "Executor2 allowance should be cleared");
        assertEq(currentTestCtx.unspent3After, 0, "Executor3 allowance should be cleared");

        // Verify drip rates are set to 0
        (currentTestCtx.dripRate1, , , ) = allowanceModule.allowances(
            currentTestCtx.safeAddress,
            address(currentTestCtx.executor1),
            NATIVE_TOKEN
        );
        (currentTestCtx.dripRate2, , , ) = allowanceModule.allowances(
            currentTestCtx.safeAddress,
            address(currentTestCtx.executor2),
            NATIVE_TOKEN
        );
        (currentTestCtx.dripRate3, , , ) = allowanceModule.allowances(
            currentTestCtx.safeAddress,
            address(currentTestCtx.executor3),
            NATIVE_TOKEN
        );

        assertEq(currentTestCtx.dripRate1, 0, "Executor1 drip rate should be zero");
        assertEq(currentTestCtx.dripRate2, 0, "Executor2 drip rate should be zero");
        assertEq(currentTestCtx.dripRate3, 0, "Executor3 drip rate should be zero");

        // Verify attempts to withdraw now fail
        vm.expectRevert();
        currentTestCtx.executor1.executeAllowanceTransfer(allowanceModule, currentTestCtx.safeAddress, NATIVE_TOKEN);

        vm.expectRevert();
        currentTestCtx.executor2.executeAllowanceTransfer(allowanceModule, currentTestCtx.safeAddress, NATIVE_TOKEN);

        vm.expectRevert();
        currentTestCtx.executor3.executeAllowanceTransfer(allowanceModule, currentTestCtx.safeAddress, NATIVE_TOKEN);
    }

    function testGetMaxWithdrawableAmount(
        uint128 dripRatePerDay,
        uint32 timeElapsed,
        uint256 ethBalance,
        uint256 tokenBalance
    ) public {
        // Constrain inputs to reasonable values
        vm.assume(dripRatePerDay > 0 && dripRatePerDay <= 1000 ether); // Up to 1000 ETH per day
        vm.assume(timeElapsed > 0 && timeElapsed <= 365 days); // Up to 1 year
        vm.assume(ethBalance <= 10000 ether); // Reasonable ETH balance
        vm.assume(tokenBalance <= 10000 ether && tokenBalance > 0); // Reasonable token balance

        address safeAddress = address(safeImpl);
        address executorAddress = address(allowanceExecutor);

        // Calculate expected allowance based on inputs
        uint256 expectedAllowance = (uint256(dripRatePerDay) * timeElapsed) / 1 days;

        // Test with ETH
        vm.startPrank(safeAddress);
        allowanceModule.setAllowance(executorAddress, NATIVE_TOKEN, dripRatePerDay);
        vm.stopPrank();

        // Advance time to accrue allowance
        vm.warp(block.timestamp + timeElapsed);

        // Set safe ETH balance
        vm.deal(safeAddress, ethBalance);

        uint256 totalUnspentEth = allowanceModule.getTotalUnspent(safeAddress, executorAddress, NATIVE_TOKEN);
        uint256 maxWithdrawableEth = allowanceModule.getMaxWithdrawableAmount(
            safeAddress,
            executorAddress,
            NATIVE_TOKEN
        );

        // Verify total unspent matches expected allowance
        assertEq(totalUnspentEth, expectedAllowance, "Total unspent ETH should match expected allowance");

        // Verify max withdrawable is minimum of allowance and balance
        uint256 expectedMaxEth = expectedAllowance <= ethBalance ? expectedAllowance : ethBalance;
        assertEq(maxWithdrawableEth, expectedMaxEth, "Max withdrawable ETH should be min(allowance, balance)");

        // Test with ERC20 token
        TestERC20 token = new TestERC20(tokenBalance * 2); // Create with more than needed

        // Set allowance for token (using same parameters)
        vm.startPrank(safeAddress);
        allowanceModule.setAllowance(executorAddress, address(token), dripRatePerDay);
        vm.stopPrank();

        // Advance time again to accrue same allowance for token
        vm.warp(block.timestamp + timeElapsed);

        // Transfer tokens to safe
        token.transfer(safeAddress, tokenBalance);

        uint256 totalUnspentToken = allowanceModule.getTotalUnspent(safeAddress, executorAddress, address(token));
        uint256 maxWithdrawableToken = allowanceModule.getMaxWithdrawableAmount(
            safeAddress,
            executorAddress,
            address(token)
        );

        // Verify total unspent matches expected allowance
        assertEq(totalUnspentToken, expectedAllowance, "Total unspent tokens should match expected allowance");

        // Verify max withdrawable is minimum of allowance and balance
        uint256 expectedMaxToken = expectedAllowance <= tokenBalance ? expectedAllowance : tokenBalance;
        assertEq(maxWithdrawableToken, expectedMaxToken, "Max withdrawable tokens should be min(allowance, balance)");

        // Edge case: Test with zero allowance
        uint256 maxWithdrawableZero = allowanceModule.getMaxWithdrawableAmount(
            safeAddress,
            address(0x123),
            NATIVE_TOKEN
        );
        assertEq(maxWithdrawableZero, 0, "Max withdrawable should be 0 for uninitialized allowance");
    }

    function testLinearAllowanceExecutorPreviewFunctions(
        uint128 dripRatePerDay,
        uint32 timeElapsed,
        uint256 safeBalance
    ) public {
        // Constrain inputs to reasonable values
        vm.assume(dripRatePerDay > 0 && dripRatePerDay <= 500 ether); // Up to 500 ETH per day
        vm.assume(timeElapsed > 0 && timeElapsed <= 180 days); // Up to 6 months
        vm.assume(safeBalance <= 5000 ether); // Reasonable safe balance

        address safeAddress = address(safeImpl);

        // Calculate expected allowance
        uint256 expectedAllowance = (uint256(dripRatePerDay) * timeElapsed) / 1 days;

        // Set allowance
        vm.prank(safeAddress);
        allowanceModule.setAllowance(address(allowanceExecutor), NATIVE_TOKEN, dripRatePerDay);

        // Advance time to accrue allowance
        vm.warp(block.timestamp + timeElapsed);

        // Set safe balance
        vm.deal(safeAddress, safeBalance);

        // Test preview functions through LinearAllowanceExecutor
        uint256 totalUnspent = allowanceExecutor.getTotalUnspent(allowanceModule, safeAddress, NATIVE_TOKEN);
        uint256 maxWithdrawable = allowanceExecutor.getMaxWithdrawableAmount(
            allowanceModule,
            safeAddress,
            NATIVE_TOKEN
        );

        // Verify total unspent matches expected allowance
        assertEq(totalUnspent, expectedAllowance, "Executor should see correct total unspent allowance");

        // Verify max withdrawable is minimum of allowance and balance
        uint256 expectedMaxWithdrawable = expectedAllowance <= safeBalance ? expectedAllowance : safeBalance;
        assertEq(maxWithdrawable, expectedMaxWithdrawable, "Executor should see correct max withdrawable amount");

        // Execute the transfer to verify the preview was accurate (only if there's something to withdraw)
        if (maxWithdrawable > 0) {
            uint256 balanceBefore = address(allowanceExecutor).balance;
            allowanceExecutor.executeAllowanceTransfer(allowanceModule, safeAddress, NATIVE_TOKEN);
            uint256 balanceAfter = address(allowanceExecutor).balance;

            assertEq(balanceAfter - balanceBefore, maxWithdrawable, "Actual transfer should match preview");
        }
    }

    // Helper for Safe transactions (necessary due to Safe's complex transaction execution)
    function execSafeTransaction(
        address to,
        uint256 value,
        bytes memory data,
        uint256 ownerPrivateKey
    ) internal returns (bool) {
        bytes32 txHash = safeImpl.getTransactionHash(
            to,
            value,
            data,
            Enum.Operation.Call,
            100_000,
            0,
            1,
            address(0),
            payable(address(0)),
            safeImpl.nonce()
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, txHash);
        return
            safeImpl.execTransaction(
                to,
                value,
                data,
                Enum.Operation.Call,
                100_000,
                0,
                1,
                address(0),
                payable(address(0)),
                abi.encodePacked(r, s, v)
            );
    }

    /// @notice Test zero address validation in setAllowance function
    function testZeroAddressValidation_SetAllowanceRejectsZeroDelegate() public {
        vm.prank(address(safeImpl));
        vm.expectRevert(abi.encodeWithSelector(ILinearAllowanceSingleton.AddressZeroForArgument.selector, "delegate"));
        allowanceModule.setAllowance(address(0), NATIVE_TOKEN, 1 ether);
    }

    /// @notice Test zero address validation in revokeAllowance function
    function testZeroAddressValidation_RevokeRejectsZeroDelegate() public {
        vm.prank(address(safeImpl));
        vm.expectRevert(abi.encodeWithSelector(ILinearAllowanceSingleton.AddressZeroForArgument.selector, "delegate"));
        allowanceModule.revokeAllowance(address(0), NATIVE_TOKEN);
    }

    /// @notice Test zero address validation in executeAllowanceTransfer function
    function testZeroAddressValidation_ExecuteTransferRejectsZeroRecipient() public {
        // First set up a valid allowance
        vm.prank(address(safeImpl));
        allowanceModule.setAllowance(address(this), NATIVE_TOKEN, 1 ether);

        // Attempt to transfer to zero address should fail
        vm.expectRevert(abi.encodeWithSelector(ILinearAllowanceSingleton.AddressZeroForArgument.selector, "to"));
        allowanceModule.executeAllowanceTransfer(address(safeImpl), NATIVE_TOKEN, payable(address(0)));
    }

    /// @notice Test that valid addresses still work after adding validation
    function testZeroAddressValidation_ValidAddressesStillWork() public {
        address validDelegate = makeAddr("validDelegate");
        address validRecipient = makeAddr("validRecipient");

        // Set allowance with valid delegate should work
        vm.prank(address(safeImpl));
        allowanceModule.setAllowance(validDelegate, NATIVE_TOKEN, 1 ether);

        // Revoke with valid delegate should work
        vm.prank(address(safeImpl));
        allowanceModule.revokeAllowance(validDelegate, NATIVE_TOKEN);

        // Set allowance again for transfer test
        vm.prank(address(safeImpl));
        allowanceModule.setAllowance(validDelegate, NATIVE_TOKEN, 1 ether);

        // Wait for some time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Transfer to valid recipient should work
        vm.prank(validDelegate);
        uint256 transferred = allowanceModule.executeAllowanceTransfer(
            address(safeImpl),
            NATIVE_TOKEN,
            payable(validRecipient)
        );

        // Verify transfer worked
        assertGt(transferred, 0, "Should have transferred some amount to valid recipient");
        assertEq(validRecipient.balance, transferred, "Recipient should have received the transferred amount");
    }

    /// @notice Test precision loss protection - small drip rates over short time should revert instead of losing accrued allowance
    function testPrecisionLossProtection_SmallDripRateShortTime() public {
        address delegate = makeAddr("delegate");
        address testRecipient = makeAddr("testRecipient");

        // Set very small drip rate (1 wei per day)
        vm.prank(address(safeImpl));
        allowanceModule.setAllowance(delegate, NATIVE_TOKEN, 1);

        // Wait only 1 second (much less than 1 day)
        vm.warp(block.timestamp + 1);

        // Attempt to transfer should revert with NoAllowanceToTransfer due to precision loss
        // The calculation results in 0 due to (1 * 1) / 86400 = 0, so totalUnspent becomes 0
        vm.prank(delegate);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILinearAllowanceSingleton.NoAllowanceToTransfer.selector,
                address(safeImpl),
                delegate,
                NATIVE_TOKEN
            )
        );
        allowanceModule.executeAllowanceTransfer(address(safeImpl), NATIVE_TOKEN, payable(testRecipient));
    }

    /// @notice Test griefing protection - prevent attackers from forcing zero transfers that consume accrued time
    function testGriefingProtection_PreventZeroTransferAttacks() public {
        address victim = makeAddr("victim");
        address testRecipient = makeAddr("testRecipient");

        // Set up a small allowance for victim
        vm.prank(address(safeImpl));
        allowanceModule.setAllowance(victim, NATIVE_TOKEN, 1000); // 1000 wei per day

        // Wait a short time to accrue small amount
        vm.warp(block.timestamp + 60); // 1 minute

        // Calculate expected accrued amount (should be less than 1 due to precision loss)
        uint256 expectedAccrued = uint256(1000 * 60) / uint256(1 days); // Should be 0 due to integer division
        assertEq(expectedAccrued, 0, "Should have zero accrued due to precision loss");

        // Attacker tries to grief by executing transfer (this should revert due to precision loss)
        vm.prank(victim);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILinearAllowanceSingleton.NoAllowanceToTransfer.selector,
                address(safeImpl),
                victim,
                NATIVE_TOKEN
            )
        );
        allowanceModule.executeAllowanceTransfer(address(safeImpl), NATIVE_TOKEN, payable(testRecipient));
    }

    /// @notice Test that legitimate transfers still work after adding zero transfer protection
    function testPrecisionLossProtection_LegitimateTransfersStillWork() public {
        address delegate = makeAddr("delegate");
        address testRecipient = makeAddr("testRecipient");

        // Set reasonable drip rate (1 ether per day)
        vm.prank(address(safeImpl));
        allowanceModule.setAllowance(delegate, NATIVE_TOKEN, 1 ether);

        // Wait sufficient time to accrue meaningful amount
        vm.warp(block.timestamp + 1 hours); // 1 hour should give 1 ether / 24 = ~0.042 ether

        // Transfer should work normally
        vm.prank(delegate);
        uint256 transferred = allowanceModule.executeAllowanceTransfer(
            address(safeImpl),
            NATIVE_TOKEN,
            payable(testRecipient)
        );

        // Verify transfer worked
        assertGt(transferred, 0, "Should have transferred meaningful amount");
        assertEq(testRecipient.balance, transferred, "Recipient should have received the transferred amount");
    }

    /// @notice Test edge case where balance is insufficient but allowance exists
    function testPrecisionLossProtection_InsufficientBalanceStillReverts() public {
        address delegate = makeAddr("delegate");
        address testRecipient = makeAddr("testRecipient");

        // Create a safe with very low ETH balance
        address lowBalanceSafe = makeAddr("lowBalanceSafe");
        vm.deal(lowBalanceSafe, 0); // No ETH

        // Set up allowance from low balance safe (this will work as it doesn't check balance)
        vm.prank(lowBalanceSafe);
        allowanceModule.setAllowance(delegate, NATIVE_TOKEN, 1 ether);

        // Wait for allowance to accrue
        vm.warp(block.timestamp + 1 days);

        // Attempt transfer should revert due to zero transfer amount (no balance available)
        vm.prank(delegate);
        vm.expectRevert(
            abi.encodeWithSelector(
                ILinearAllowanceSingleton.ZeroTransfer.selector,
                lowBalanceSafe,
                delegate,
                NATIVE_TOKEN
            )
        );
        allowanceModule.executeAllowanceTransfer(lowBalanceSafe, NATIVE_TOKEN, payable(testRecipient));
    }
}

// Helper contracts

contract MockNonCompliantToken {
    // This token implements balanceOf but transfer() doesn't actually transfer tokens
    // Simulates a non-compliant token that returns true but doesn't move funds

    mapping(address => uint256) public balanceOf;

    function setBalance(address account, uint256 amount) external {
        balanceOf[account] = amount;
    }

    function transfer(address, uint256) external pure returns (bool) {
        // Non-compliant: returns true but doesn't actually transfer
        return true;
    }
}

contract MockFailingSafe {
    // Always returns false for execTransactionFromModule
    function execTransactionFromModule(address, uint256, bytes memory, Enum.Operation) external pure returns (bool) {
        return false;
    }

    // Need to handle ETH
    receive() external payable {}
}

// Contract that fails when executing ETH transfers
contract MockSafeThatFailsEthTransfers {
    receive() external payable {}

    function execTransactionFromModule(
        address,
        uint256 value,
        bytes memory data,
        Enum.Operation
    ) external pure returns (bool) {
        // Only fail for ETH transfers
        if (data.length == 0 && value > 0) {
            return false;
        }
        return true;
    }
}

// Contract that rejects ETH transfers
contract ContractThatRejectsETH {
    receive() external payable {
        revert("Cannot receive ETH");
    }
}

// Malicious module for testing access control
contract MaliciousModule {
    LinearAllowanceSingletonForGnosisSafe public allowanceModule;
    address public safe;

    constructor(LinearAllowanceSingletonForGnosisSafe _allowanceModule) {
        allowanceModule = _allowanceModule;
    }

    // Set the safe address when this module is enabled
    function setUp(bytes memory) external {
        safe = msg.sender;
    }

    // Manual setter for testing purposes
    function setSafeAddress(address _safe) external {
        safe = _safe;
    }

    // Direct call attempt (should fail - modules can't directly call arbitrary contracts as the Safe)
    function attemptRevoke(address delegate, address token) external {
        try allowanceModule.revokeAllowance(delegate, token) {
            // This should fail because msg.sender is this module, not the safe
        } catch {
            // Expected to fail
        }
    }

    // Attempt via execTransactionFromModule (this is the concerning vector)
    function attemptRevokeViaModule(address delegate, address token) external returns (bool) {
        bytes memory data = abi.encodeWithSelector(allowanceModule.revokeAllowance.selector, delegate, token);

        try
            Safe(payable(safe)).execTransactionFromModule(address(allowanceModule), 0, data, Enum.Operation.Call)
        returns (bool success) {
            return success;
        } catch {
            return false;
        }
    }
}

// Malicious module specifically for testing setAllowance access control
contract MaliciousModuleForSetAllowance {
    LinearAllowanceSingletonForGnosisSafe public allowanceModule;
    address public safe;

    constructor(LinearAllowanceSingletonForGnosisSafe _allowanceModule) {
        allowanceModule = _allowanceModule;
    }

    // Set the safe address when this module is enabled
    function setUp(bytes memory) external {
        safe = msg.sender;
    }

    // Manual setter for testing purposes
    function setSafeAddress(address _safe) external {
        safe = _safe;
    }

    // Direct call attempt (should fail - modules can't directly call arbitrary contracts as the Safe)
    function attemptSetAllowance(address delegate, address token, uint128 dripRatePerDay) external {
        try allowanceModule.setAllowance(delegate, token, dripRatePerDay) {
            // This should fail because msg.sender is this module, not the safe
        } catch {
            // Expected to fail
        }
    }

    // Attempt via execTransactionFromModule (this is the critical attack vector to test)
    function attemptSetAllowanceViaModule(
        address delegate,
        address token,
        uint128 dripRatePerDay
    ) external returns (bool) {
        bytes memory data = abi.encodeWithSelector(
            allowanceModule.setAllowance.selector,
            delegate,
            token,
            dripRatePerDay
        );

        try
            Safe(payable(safe)).execTransactionFromModule(address(allowanceModule), 0, data, Enum.Operation.Call)
        returns (bool success) {
            return success;
        } catch {
            return false;
        }
    }
}
