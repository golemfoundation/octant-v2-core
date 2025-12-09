// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import { LinearAllowanceExecutorTestHarness } from "test/mocks/zodiac-core/LinearAllowanceExecutorTestHarness.sol";
import { LinearAllowanceSingletonForGnosisSafe } from "src/zodiac-core/modules/LinearAllowanceSingletonForGnosisSafe.sol";
import { LinearAllowanceExecutor } from "src/zodiac-core/LinearAllowanceExecutor.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockSafe } from "test/mocks/zodiac-core/MockSafe.sol";
import { NATIVE_TOKEN, AccessMode } from "src/constants.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { NotInAllowset, InBlockset } from "src/errors.sol";

contract LinearAllowanceExecutorTest is Test {
    LinearAllowanceExecutorTestHarness public executor;
    LinearAllowanceSingletonForGnosisSafe public allowanceModule;
    MockSafe public mockSafe;
    MockERC20 public mockToken;
    AddressSet public moduleAllowset;

    uint192 constant DRIP_RATE = 1 ether; // 1 token per day

    function setUp() public {
        // Deploy contracts
        executor = new LinearAllowanceExecutorTestHarness();
        allowanceModule = new LinearAllowanceSingletonForGnosisSafe();
        mockSafe = new MockSafe();
        mockToken = new MockERC20(18);
        moduleAllowset = new AddressSet();

        // Set the allowset on the executor
        executor.assignModuleAddressSet(IAddressSet(address(moduleAllowset)));
        executor.setModuleAccessMode(AccessMode.ALLOWSET);

        // AddressSet the allowance module
        moduleAllowset.add(address(allowanceModule));

        // Enable module on mock Safe
        mockSafe.enableModule(address(allowanceModule));

        // Fund Safe with ETH and tokens
        vm.deal(address(mockSafe), 10 ether);
        mockToken.mint(address(mockSafe), 10 ether);
    }

    function testExecuteAllowanceTransferWithNativeToken() public {
        // Set up allowance for executor
        vm.prank(address(mockSafe));
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, DRIP_RATE);

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Get executor's balance before transfer
        uint256 executorBalanceBefore = address(executor).balance;

        // Execute allowance transfer
        uint256 transferredAmount = executor.executeAllowanceTransfer(allowanceModule, address(mockSafe), NATIVE_TOKEN);

        // Verify transfer
        assertEq(transferredAmount, DRIP_RATE, "Should transfer the exact drip rate amount");
        assertEq(
            address(executor).balance - executorBalanceBefore,
            DRIP_RATE,
            "Executor balance should increase by the transferred amount"
        );
    }

    function testExecuteAllowanceTransferWithERC20() public {
        // Set up allowance for executor
        vm.prank(address(mockSafe));
        allowanceModule.setAllowance(address(executor), address(mockToken), DRIP_RATE);

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Get executor's token balance before transfer
        uint256 executorBalanceBefore = mockToken.balanceOf(address(executor));

        // Execute allowance transfer
        uint256 transferredAmount = executor.executeAllowanceTransfer(
            allowanceModule,
            address(mockSafe),
            address(mockToken)
        );

        // Verify transfer
        assertEq(transferredAmount, DRIP_RATE, "Should transfer the exact drip rate amount");
        assertEq(
            mockToken.balanceOf(address(executor)) - executorBalanceBefore,
            DRIP_RATE,
            "Executor token balance should increase by the transferred amount"
        );
    }

    function testGetTotalUnspent() public {
        // Set up allowance for executor
        vm.prank(address(mockSafe));
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, DRIP_RATE);

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Get total unspent allowance
        uint256 totalUnspent = executor.getTotalUnspent(allowanceModule, address(mockSafe), NATIVE_TOKEN);

        // Verify result
        assertEq(totalUnspent, DRIP_RATE, "Total unspent should equal the drip rate after 1 day");
    }

    function testReceiveEther() public {
        uint256 sendAmount = 1 ether;
        vm.deal(address(this), sendAmount);

        uint256 executorBalanceBefore = address(executor).balance;

        (bool success, ) = address(executor).call{ value: sendAmount }("");
        assertTrue(success, "Ether transfer should succeed");

        uint256 executorBalanceAfter = address(executor).balance;
        assertEq(executorBalanceAfter - executorBalanceBefore, sendAmount, "Should receive the sent ether");
    }

    function testPartialAllowanceTransfer() public {
        // Set up allowance for executor
        vm.prank(address(mockSafe));
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, DRIP_RATE);

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Reduce Safe's balance to be less than allowance
        uint256 safeBalance = 0.5 ether;
        vm.deal(address(mockSafe), safeBalance);

        // Execute allowance transfer
        uint256 transferredAmount = executor.executeAllowanceTransfer(allowanceModule, address(mockSafe), NATIVE_TOKEN);

        // Verify transfer
        assertEq(transferredAmount, safeBalance, "Should transfer only the available balance");
    }

    function testModuleAllowsetValidation() public {
        // Deploy a new module that is not inAllowset
        LinearAllowanceSingletonForGnosisSafe nonAllowsetedModule = new LinearAllowanceSingletonForGnosisSafe();

        // Try to use non-inAllowset module - should revert
        vm.expectRevert(abi.encodeWithSelector(NotInAllowset.selector, address(nonAllowsetedModule)));
        executor.executeAllowanceTransfer(nonAllowsetedModule, address(mockSafe), NATIVE_TOKEN);

        // AddressSet the module
        moduleAllowset.add(address(nonAllowsetedModule));

        // Now it should work (will revert for different reason - no allowance set)
        vm.expectRevert(); // Different revert reason
        executor.executeAllowanceTransfer(nonAllowsetedModule, address(mockSafe), NATIVE_TOKEN);

        // Remove from allowset
        moduleAllowset.remove(address(nonAllowsetedModule));

        // Should revert again with allowset error
        vm.expectRevert(abi.encodeWithSelector(NotInAllowset.selector, address(nonAllowsetedModule)));
        executor.executeAllowanceTransfer(nonAllowsetedModule, address(mockSafe), NATIVE_TOKEN);
    }

    function testModuleAccessModeNone() public {
        // Deploy a new module that is not in allowset
        LinearAllowanceSingletonForGnosisSafe newModule = new LinearAllowanceSingletonForGnosisSafe();

        // Set mode to NONE
        executor.setModuleAccessMode(AccessMode.NONE);

        // Set up allowance for executor
        vm.prank(address(mockSafe));
        newModule.setAllowance(address(executor), NATIVE_TOKEN, DRIP_RATE);

        // Enable module on mock Safe
        mockSafe.enableModule(address(newModule));

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Should work even though module is not in allowset
        uint256 transferredAmount = executor.executeAllowanceTransfer(newModule, address(mockSafe), NATIVE_TOKEN);
        assertEq(transferredAmount, DRIP_RATE, "Should transfer even with module not in allowset");
    }

    function testModuleAccessModeBlockset() public {
        // Deploy a new module
        LinearAllowanceSingletonForGnosisSafe blockedModule = new LinearAllowanceSingletonForGnosisSafe();

        // Add it to the address set
        moduleAllowset.add(address(blockedModule));

        // Set mode to BLOCKSET
        executor.setModuleAccessMode(AccessMode.BLOCKSET);

        // Try to use blocked module - should revert
        vm.expectRevert(abi.encodeWithSelector(InBlockset.selector, address(blockedModule)));
        executor.executeAllowanceTransfer(blockedModule, address(mockSafe), NATIVE_TOKEN);

        // Remove from blockset
        moduleAllowset.remove(address(blockedModule));

        // Set up allowance for executor
        vm.prank(address(mockSafe));
        blockedModule.setAllowance(address(executor), NATIVE_TOKEN, DRIP_RATE);

        // Enable module on mock Safe
        mockSafe.enableModule(address(blockedModule));

        // Advance time to accrue allowance
        vm.warp(block.timestamp + 1 days);

        // Should work now that it's not in the blockset
        uint256 transferredAmount = executor.executeAllowanceTransfer(blockedModule, address(mockSafe), NATIVE_TOKEN);
        assertEq(transferredAmount, DRIP_RATE, "Should transfer when module not in blockset");
    }

    function testModuleAccessModeSwitching() public {
        // Start with ALLOWSET mode (from setUp)
        assertEq(uint(executor.moduleAccessMode()), uint(AccessMode.ALLOWSET), "Should start in ALLOWSET mode");

        // allowanceModule is in the allowset, so it should work
        vm.prank(address(mockSafe));
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, DRIP_RATE);
        vm.warp(block.timestamp + 1 days);
        uint256 transferredAmount = executor.executeAllowanceTransfer(allowanceModule, address(mockSafe), NATIVE_TOKEN);
        assertEq(transferredAmount, DRIP_RATE, "Should work in ALLOWSET mode");

        // Switch to BLOCKSET mode
        executor.setModuleAccessMode(AccessMode.BLOCKSET);

        // Now it should fail because allowanceModule is in the set
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(abi.encodeWithSelector(InBlockset.selector, address(allowanceModule)));
        executor.executeAllowanceTransfer(allowanceModule, address(mockSafe), NATIVE_TOKEN);

        // Switch to NONE mode
        executor.setModuleAccessMode(AccessMode.NONE);

        // Now it should work again - allowance accumulated during BLOCKSET period (1 day)
        transferredAmount = executor.executeAllowanceTransfer(allowanceModule, address(mockSafe), NATIVE_TOKEN);
        assertEq(transferredAmount, DRIP_RATE, "Should work in NONE mode");
    }

    function testExecuteMultipleTransfersWithChangingAllowance() public {
        // Set up allowance for executor
        vm.prank(address(mockSafe));
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, DRIP_RATE);

        // Advance time to accrue allowance
        skip(1 days);
        vm.roll(1);

        // First transfer
        uint256 transferredAmount1 = executor.executeAllowanceTransfer(
            allowanceModule,
            address(mockSafe),
            NATIVE_TOKEN
        );

        // Increase drip rate
        vm.prank(address(mockSafe));
        allowanceModule.setAllowance(address(executor), NATIVE_TOKEN, DRIP_RATE * 2);

        // Advance time to accrue more allowance
        skip(1 days);
        vm.roll(block.number + 1);

        // Second transfer
        uint256 transferredAmount2 = executor.executeAllowanceTransfer(
            allowanceModule,
            address(mockSafe),
            NATIVE_TOKEN
        );

        // Verify transfers
        assertEq(transferredAmount1, DRIP_RATE, "First transfer should use original drip rate");
        assertEq(transferredAmount2, DRIP_RATE * 2, "Second transfer should use updated drip rate");
    }
}
