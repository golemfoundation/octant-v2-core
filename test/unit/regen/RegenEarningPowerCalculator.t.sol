// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { AccessMode } from "src/constants.sol";
import "forge-std/Test.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { IAccessControlledEarningPowerCalculator } from "src/regen/interfaces/IAccessControlledEarningPowerCalculator.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

contract RegenEarningPowerCalculatorTest is Test {
    RegenEarningPowerCalculator calculator;
    AddressSet allowset;
    address owner;
    address staker1;
    address staker2;
    address nonOwner;

    function setUp() public {
        owner = makeAddr("owner");
        staker1 = makeAddr("staker1");
        staker2 = makeAddr("staker2");
        nonOwner = makeAddr("nonOwner");

        vm.startPrank(owner);
        allowset = new AddressSet();
        calculator = new RegenEarningPowerCalculator(owner, allowset, IAddressSet(address(0)), AccessMode.ALLOWSET);
        vm.stopPrank();
    }

    function test_Constructor_SetsOwner() public view {
        assertEq(calculator.owner(), owner, "Owner should be set correctly");
    }

    function test_Constructor_SetsInitialAddressSet() public view {
        assertEq(address(calculator.allowset()), address(allowset), "Initial allowset should be set");
    }

    function test_Constructor_EmitsAllowsetAssigned() public {
        AddressSet localTestAllowset = new AddressSet();

        vm.expectEmit();
        emit IAccessControlledEarningPowerCalculator.AllowsetAssigned(localTestAllowset);

        vm.prank(owner);
        new RegenEarningPowerCalculator(owner, localTestAllowset, IAddressSet(address(0)), AccessMode.ALLOWSET);
    }

    function test_SupportsInterface_IAccessControlledEarningPowerCalculator() public view {
        assertTrue(calculator.supportsInterface(type(IAccessControlledEarningPowerCalculator).interfaceId));
    }

    function test_SupportsInterface_IERC165() public view {
        assertTrue(calculator.supportsInterface(type(IERC165).interfaceId));
    }

    function testFuzz_GetEarningPower_AllowsetDisabled(uint256 stakedAmount) public {
        vm.startPrank(owner);
        calculator.setAccessMode(AccessMode.NONE);
        vm.stopPrank();

        uint256 earningPower = calculator.getEarningPower(stakedAmount, staker1, address(0));
        if (stakedAmount > type(uint96).max) {
            assertEq(earningPower, type(uint96).max, "EP should be capped at uint96 max");
        } else {
            assertEq(earningPower, stakedAmount, "EP should be stakedAmount when allowset disabled");
        }
    }

    function testFuzz_GetEarningPower_UserAllowseted(uint256 stakedAmount) public {
        vm.prank(owner);
        allowset.add(staker1);

        uint256 earningPower = calculator.getEarningPower(stakedAmount, staker1, address(0));
        if (stakedAmount > type(uint96).max) {
            assertEq(earningPower, type(uint96).max, "EP should be capped at uint96 max");
        } else {
            assertEq(earningPower, stakedAmount, "EP should be stakedAmount for allowseted user");
        }
    }

    function testFuzz_GetEarningPower_UserNotAllowseted(uint256 stakedAmount) public view {
        uint256 earningPower = calculator.getEarningPower(stakedAmount, staker1, address(0));
        assertEq(earningPower, 0);
    }

    function testFuzz_GetNewEarningPower_ChangesAddressSet(uint256 initialStakedAmount, uint256 oldEP) public {
        vm.assume(initialStakedAmount <= type(uint96).max);
        vm.assume(oldEP <= type(uint96).max);
        vm.assume(oldEP > 0); // Ensure oldEP > 0 so changing allowset causes a change

        vm.prank(owner);
        allowset.add(staker1);

        // Change calculator's allowset to one where staker1 is NOT present
        AddressSet newEmptyAllowset;
        vm.prank(owner);
        newEmptyAllowset = new AddressSet();
        vm.prank(owner);
        calculator.setAllowset(newEmptyAllowset);

        (uint256 newEP, bool qualifies) = calculator.getNewEarningPower(
            initialStakedAmount,
            staker1,
            address(0),
            oldEP
        );
        assertEq(newEP, 0, "New EP should be 0 after changing allowset");
        assertTrue(qualifies, "Should qualify for bump after changing allowset");
    }

    /// @notice Most complex test, covers almost all possible scenarios
    function testFuzz_GetNewEarningPower_StakeChange(
        uint256 newStake,
        uint256 oldEarningPower,
        bool isAllowsetEnabled,
        bool isStakerAllowseted
    ) public {
        vm.assume(oldEarningPower <= type(uint96).max);

        // Setup allowset state
        if (!isAllowsetEnabled) {
            vm.prank(owner);
            calculator.setAccessMode(AccessMode.NONE);
        } else if (isStakerAllowseted) {
            vm.prank(owner);
            allowset.add(staker1);
        }

        // Calculate expected new earning power
        uint256 expectedNewEP;
        if (!isAllowsetEnabled || isStakerAllowseted) {
            expectedNewEP = newStake > type(uint96).max ? type(uint96).max : newStake;
        } else {
            expectedNewEP = 0; // Not allowseted
        }
        bool expectedQualifies = expectedNewEP != oldEarningPower;

        (uint256 newEP, bool qualifies) = calculator.getNewEarningPower(newStake, staker1, address(0), oldEarningPower);

        assertEq(newEP, expectedNewEP, "New earning power mismatch");
        assertEq(qualifies, expectedQualifies, "Qualifies for bump mismatch");
    }

    function testFuzz_GetNewEarningPower_CappedAtUint96Max_BecomesEligible(uint256 stakedAmount, uint256 oldEP) public {
        vm.assume(stakedAmount > type(uint96).max);
        vm.assume(oldEP < type(uint96).max);

        vm.prank(owner);
        allowset.add(staker1);

        (uint256 newEP, bool qualifies) = calculator.getNewEarningPower(stakedAmount, staker1, address(0), oldEP);
        assertEq(newEP, type(uint96).max, "New EP should be capped at uint96 max");
        assertTrue(qualifies, "Should qualify for bump when EP increases to cap");
    }

    function test_GetNewEarningPower_CappedAtUint96Max_RemainsEligible_NoBump() public {
        vm.prank(owner);
        allowset.add(staker1);

        // Old and new EP are type(uint96).max, so no significant change.
        uint256 stakedAmount = uint256(type(uint96).max) + 1000;
        uint256 oldEarningPower = type(uint96).max;

        (uint256 newEP, bool qualifies) = calculator.getNewEarningPower(
            stakedAmount,
            staker1,
            address(0),
            oldEarningPower
        );
        assertEq(newEP, type(uint96).max, "New EP should remain capped at uint96 max");
        assertFalse(qualifies, "Should not qualify for bump when EP remains at cap");
    }

    function test_SetAllowset_AsOwner() public {
        AddressSet newAllowset = new AddressSet();

        vm.prank(owner);
        calculator.setAllowset(newAllowset);

        assertEq(address(calculator.allowset()), address(newAllowset), "AddressSet should be updated");
    }

    function test_SetAllowset_EmitsAllowsetAssigned() public {
        AddressSet newAllowset = new AddressSet();

        vm.expectEmit();
        emit IAccessControlledEarningPowerCalculator.AllowsetAssigned(newAllowset);

        vm.prank(owner);
        calculator.setAllowset(newAllowset);
    }

    function testFuzz_RevertIf_SetAllowset_NotOwner(address notOwnerAddr) public {
        vm.assume(notOwnerAddr != owner);

        AddressSet newAllowset = new AddressSet();
        vm.startPrank(notOwnerAddr);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", notOwnerAddr));
        calculator.setAllowset(newAllowset);
        vm.stopPrank();
    }

    function testFuzz_SetAllowset_ToAddressZero_DisablesIt(uint256 stakedAmount) public {
        assertFalse(calculator.allowset().contains(staker1), "Staker1 should not be in allowset");

        vm.startPrank(owner);
        calculator.setAccessMode(AccessMode.NONE);
        vm.stopPrank();

        assertEq(uint256(calculator.accessMode()), uint256(AccessMode.NONE), "Mode should be NONE");

        uint256 earningPower = calculator.getEarningPower(stakedAmount, staker1, address(0));
        if (stakedAmount > type(uint96).max) {
            assertEq(earningPower, type(uint96).max, "EP should be capped at uint96 max");
        } else {
            assertEq(earningPower, stakedAmount, "EP should be stakedAmount when mode is NONE");
        }
    }
}
