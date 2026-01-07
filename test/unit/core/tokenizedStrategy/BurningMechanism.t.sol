// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title Burning Mechanism Test
/// @notice Tests for the burning mechanism functionality in TokenizedStrategy
contract BurningMechanismTest is Test {
    ERC20Mock public asset;
    YieldDonatingTokenizedStrategy public yieldDonatingStrategy;
    YieldSkimmingTokenizedStrategy public yieldSkimmingStrategy;
    YieldDonatingTokenizedStrategy public yieldDonatingImplementation;
    YieldSkimmingTokenizedStrategy public yieldSkimmingImplementation;

    address public management = address(0x1);
    address public keeper = address(0x2);
    address public emergencyAdmin = address(0x3);
    address public dragonRouter = address(0x4);
    address public unauthorizedUser = address(0x5);

    event Transfer(address indexed from, address indexed to, uint256 value);
    event UpdateBurningMechanism(bool enableBurning);

    function setUp() public {
        asset = new ERC20Mock();

        // Deploy implementations
        yieldDonatingImplementation = new YieldDonatingTokenizedStrategy();
        yieldSkimmingImplementation = new YieldSkimmingTokenizedStrategy();

        // Deploy proxies
        yieldDonatingStrategy = YieldDonatingTokenizedStrategy(
            address(new ERC1967Proxy(address(yieldDonatingImplementation), ""))
        );
        yieldSkimmingStrategy = YieldSkimmingTokenizedStrategy(
            address(new ERC1967Proxy(address(yieldSkimmingImplementation), ""))
        );

        // Initialize strategies
        yieldDonatingStrategy.initialize(
            address(asset),
            "Yield Donating Strategy",
            "osYD",
            management,
            keeper,
            emergencyAdmin,
            dragonRouter,
            true // enableBurning initially true
        );

        yieldSkimmingStrategy.initialize(
            address(asset),
            "Yield Skimming Strategy",
            "osYS",
            management,
            keeper,
            emergencyAdmin,
            dragonRouter,
            false // enableBurning initially false
        );
    }

    /// @notice Test that burning mechanism is initialized correctly
    function testInitialBurningState() public view {
        assertTrue(yieldDonatingStrategy.enableBurning(), "Yield donating should have burning enabled");
        assertFalse(yieldSkimmingStrategy.enableBurning(), "Yield skimming should have burning disabled");
    }

    /// @notice Test that only management can set burning mechanism
    function testOnlyManagementCanSetBurning() public {
        // Test that management can set burning
        vm.startPrank(management);
        yieldDonatingStrategy.setEnableBurning(false);
        assertFalse(yieldDonatingStrategy.enableBurning(), "Management should be able to disable burning");

        yieldSkimmingStrategy.setEnableBurning(true);
        assertTrue(yieldSkimmingStrategy.enableBurning(), "Management should be able to enable burning");
        vm.stopPrank();

        // Test that non-management cannot set burning
        vm.startPrank(unauthorizedUser);
        vm.expectRevert("!management");
        yieldDonatingStrategy.setEnableBurning(true);

        vm.expectRevert("!management");
        yieldSkimmingStrategy.setEnableBurning(false);
        vm.stopPrank();

        // Test that keeper cannot set burning
        vm.startPrank(keeper);
        vm.expectRevert("!management");
        yieldDonatingStrategy.setEnableBurning(true);
        vm.stopPrank();

        // Test that emergencyAdmin cannot set burning
        vm.startPrank(emergencyAdmin);
        vm.expectRevert("!management");
        yieldDonatingStrategy.setEnableBurning(true);
        vm.stopPrank();
    }

    /// @notice Test burning mechanism toggle functionality
    function testBurningToggle() public {
        vm.startPrank(management);

        // Test multiple toggles for yield donating strategy
        assertTrue(yieldDonatingStrategy.enableBurning(), "Should start with burning enabled");

        yieldDonatingStrategy.setEnableBurning(false);
        assertFalse(yieldDonatingStrategy.enableBurning(), "Should disable burning");

        yieldDonatingStrategy.setEnableBurning(true);
        assertTrue(yieldDonatingStrategy.enableBurning(), "Should re-enable burning");

        yieldDonatingStrategy.setEnableBurning(true);
        assertTrue(yieldDonatingStrategy.enableBurning(), "Should remain enabled when set to same value");

        // Test multiple toggles for yield skimming strategy
        assertFalse(yieldSkimmingStrategy.enableBurning(), "Should start with burning disabled");

        yieldSkimmingStrategy.setEnableBurning(true);
        assertTrue(yieldSkimmingStrategy.enableBurning(), "Should enable burning");

        yieldSkimmingStrategy.setEnableBurning(false);
        assertFalse(yieldSkimmingStrategy.enableBurning(), "Should disable burning");

        yieldSkimmingStrategy.setEnableBurning(false);
        assertFalse(yieldSkimmingStrategy.enableBurning(), "Should remain disabled when set to same value");

        vm.stopPrank();
    }

    /// @notice Test that burning state is independent per strategy
    function testIndependentBurningState() public {
        vm.startPrank(management);

        // Set different states
        yieldDonatingStrategy.setEnableBurning(true);
        yieldSkimmingStrategy.setEnableBurning(false);

        assertTrue(yieldDonatingStrategy.enableBurning(), "Yield donating should have burning enabled");
        assertFalse(yieldSkimmingStrategy.enableBurning(), "Yield skimming should have burning disabled");

        // Change one, verify the other is unchanged
        yieldDonatingStrategy.setEnableBurning(false);

        assertFalse(yieldDonatingStrategy.enableBurning(), "Yield donating should now have burning disabled");
        assertFalse(yieldSkimmingStrategy.enableBurning(), "Yield skimming state should be unchanged");

        // Change the other, verify first is unchanged
        yieldSkimmingStrategy.setEnableBurning(true);

        assertFalse(yieldDonatingStrategy.enableBurning(), "Yield donating state should be unchanged");
        assertTrue(yieldSkimmingStrategy.enableBurning(), "Yield skimming should now have burning enabled");

        vm.stopPrank();
    }

    /// @notice Fuzz test burning mechanism settings
    function testFuzzBurningSetting(bool enableBurning1, bool enableBurning2, bool enableBurning3) public {
        vm.startPrank(management);

        // Set initial states
        yieldDonatingStrategy.setEnableBurning(enableBurning1);
        yieldSkimmingStrategy.setEnableBurning(enableBurning2);

        assertEq(yieldDonatingStrategy.enableBurning(), enableBurning1, "Yield donating burning state mismatch");
        assertEq(yieldSkimmingStrategy.enableBurning(), enableBurning2, "Yield skimming burning state mismatch");

        // Change states
        yieldDonatingStrategy.setEnableBurning(enableBurning3);
        yieldSkimmingStrategy.setEnableBurning(!enableBurning3);

        assertEq(yieldDonatingStrategy.enableBurning(), enableBurning3, "Yield donating burning state change failed");
        assertEq(yieldSkimmingStrategy.enableBurning(), !enableBurning3, "Yield skimming burning state change failed");

        vm.stopPrank();
    }

    /// @notice Test burning mechanism with zero address management (should revert)
    function testCannotSetBurningWithZeroManagement() public {
        // This test verifies that strategies with proper management validation work correctly
        // We can't test zero management directly as it would be caught during initialization

        vm.startPrank(address(0));
        vm.expectRevert("!management");
        yieldDonatingStrategy.setEnableBurning(false);
        vm.stopPrank();
    }

    /// @notice Test getter function consistency
    function testGetterConsistency() public {
        vm.startPrank(management);

        // Test that getter returns accurate state
        yieldDonatingStrategy.setEnableBurning(true);
        assertTrue(yieldDonatingStrategy.enableBurning());

        yieldDonatingStrategy.setEnableBurning(false);
        assertFalse(yieldDonatingStrategy.enableBurning());

        yieldSkimmingStrategy.setEnableBurning(true);
        assertTrue(yieldSkimmingStrategy.enableBurning());

        yieldSkimmingStrategy.setEnableBurning(false);
        assertFalse(yieldSkimmingStrategy.enableBurning());

        vm.stopPrank();
    }

    /// @notice Test that burning mechanism persists through multiple function calls
    function testBurningPersistence() public {
        vm.startPrank(management);

        // Set burning state
        yieldDonatingStrategy.setEnableBurning(true);
        assertTrue(yieldDonatingStrategy.enableBurning());

        // Perform other operations that shouldn't affect burning state
        yieldDonatingStrategy.setName("New Name");
        yieldDonatingStrategy.setKeeper(address(0x999));

        // Verify burning state persists
        assertTrue(yieldDonatingStrategy.enableBurning(), "Burning state should persist through other operations");

        vm.stopPrank();
    }

    /// @notice Test burning mechanism view function gas usage
    function testBurningGetterGasUsage() public view {
        // These calls should be very cheap since they're just reading storage
        uint256 gasBefore = gasleft();
        yieldDonatingStrategy.enableBurning();
        uint256 gasAfter = gasleft();

        uint256 gasUsed = gasBefore - gasAfter;
        // Gas usage should be minimal for a simple storage read
        assertLt(gasUsed, 15000, "Burning getter should use minimal gas");
    }

    /// @notice Test that events are emitted when burning mechanism is changed
    function testBurningEventEmission() public {
        vm.startPrank(management);

        // Test disabling burning emits event
        vm.expectEmit(true, true, true, true);
        emit UpdateBurningMechanism(false);
        yieldDonatingStrategy.setEnableBurning(false);

        // Test enabling burning emits event
        vm.expectEmit(true, true, true, true);
        emit UpdateBurningMechanism(true);
        yieldDonatingStrategy.setEnableBurning(true);

        // Test that setting to same value still emits event
        vm.expectEmit(true, true, true, true);
        emit UpdateBurningMechanism(true);
        yieldDonatingStrategy.setEnableBurning(true);

        vm.stopPrank();
    }
}
