// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol"; // For OwnableUnauthorizedAccount error

contract AllowsetTest is Test {
    AddressSet allowset;
    address owner;
    address user1;
    address user2;
    address user3;
    address nonOwner;

    function setUp() public {
        address intendedOwner = makeAddr("intendedOwner"); // Create a dedicated address for ownership
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        nonOwner = makeAddr("nonOwner");

        vm.prank(intendedOwner); // Prank as the intended owner for the deployment
        allowset = new AddressSet();

        owner = intendedOwner; // Assign the 'owner' variable to the actual owner of the allowset
    }

    // --- Constructor & Ownership Tests ---
    function test_Constructor_SetsOwnerCorrectly() public view {
        assertEq(allowset.owner(), owner, "Owner should be the intendedOwner");
    }

    // --- isAllowseted Tests ---
    function test_IsAllowseted_InitiallyFalse() public view {
        assertFalse(allowset.contains(user1), "User1 should not be inAllowset initially");
        assertFalse(allowset.contains(address(0)), "Address(0) should not be inAllowset initially");
    }

    // --- addToAllowset Tests ---
    function test_AddToAllowset_SingleAccount() public {
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        vm.prank(owner);
        allowset.add(accounts);

        assertTrue(allowset.contains(user1), "User1 should be inAllowset after adding");
        assertFalse(allowset.contains(user2), "User2 should still not be inAllowset");
    }

    function test_AddToAllowset_MultipleAccounts() public {
        address[] memory accounts = new address[](2);
        accounts[0] = user1;
        accounts[1] = user2;

        vm.prank(owner);
        allowset.add(accounts);

        assertTrue(allowset.contains(user1), "User1 should be inAllowset");
        assertTrue(allowset.contains(user2), "User2 should be inAllowset");
        assertFalse(allowset.contains(user3), "User3 should not be inAllowset");
    }

    function test_AddToAllowset_EmptyList() public {
        address[] memory accounts = new address[](0);

        vm.prank(owner);
        vm.expectRevert();
        allowset.add(accounts);
    }

    function test_AddToAllowset_AddAddressZero() public {
        address[] memory accounts = new address[](1);
        accounts[0] = address(0);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                AddressSet.IllegalAddressSetOperation.selector,
                address(0),
                "Address zero not allowed."
            )
        );
        allowset.add(accounts);
    }

    function test_AddToAllowset_AlreadyAllowseted() public {
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        vm.startPrank(owner);
        allowset.add(accounts); // Add once
        assertTrue(allowset.contains(user1));

        vm.expectRevert(
            abi.encodeWithSelector(AddressSet.IllegalAddressSetOperation.selector, user1, "Address already in set.")
        );
        allowset.add(accounts); // Add again
        vm.stopPrank();
    }

    function test_RevertIf_AddToAllowset_NotOwner() public {
        address[] memory accounts = new address[](1);
        accounts[0] = user1;

        vm.startPrank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        allowset.add(accounts);
        vm.stopPrank();
    }

    // --- removeFromAllowset Tests ---
    function test_RemoveFromAllowset_SingleAccount() public {
        address[] memory addAccounts = new address[](1);
        addAccounts[0] = user1;
        vm.startPrank(owner);
        allowset.add(addAccounts);
        assertTrue(allowset.contains(user1));

        address[] memory removeAccounts = new address[](1);
        removeAccounts[0] = user1;
        allowset.remove(removeAccounts);

        assertFalse(allowset.contains(user1), "User1 should not be inAllowset after removal");
        vm.stopPrank();
    }

    function test_RemoveFromAllowset_MultipleAccounts() public {
        address[] memory addAccounts = new address[](3);
        addAccounts[0] = user1;
        addAccounts[1] = user2;
        addAccounts[2] = user3;
        vm.startPrank(owner);
        allowset.add(addAccounts);
        assertTrue(allowset.contains(user1));
        assertTrue(allowset.contains(user2));
        assertTrue(allowset.contains(user3));

        address[] memory removeAccounts = new address[](2);
        removeAccounts[0] = user1;
        removeAccounts[1] = user3;
        allowset.remove(removeAccounts);

        assertFalse(allowset.contains(user1), "User1 should be removed");
        assertTrue(allowset.contains(user2), "User2 should remain inAllowset");
        assertFalse(allowset.contains(user3), "User3 should be removed");
        vm.stopPrank();
    }

    function test_RemoveFromAllowset_EmptyList() public {
        address[] memory addAccounts = new address[](1);
        addAccounts[0] = user1;
        vm.startPrank(owner);
        allowset.add(addAccounts);
        assertTrue(allowset.contains(user1));

        address[] memory removeAccounts = new address[](0);
        vm.expectRevert();
        allowset.remove(removeAccounts);
        vm.stopPrank();
    }

    function test_RemoveFromAllowset_AddressZero() public {
        vm.startPrank(owner);
        address[] memory removeAccounts = new address[](1);
        removeAccounts[0] = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                AddressSet.IllegalAddressSetOperation.selector,
                address(0),
                "Address zero not allowed."
            )
        );
        allowset.remove(removeAccounts);
        vm.stopPrank();
    }

    function test_RemoveFromAllowset_AccountNotAllowseted() public {
        address[] memory accounts = new address[](1);
        accounts[0] = user1; // user1 is not inAllowset yet

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(AddressSet.IllegalAddressSetOperation.selector, user1, "Address not in set.")
        );
        allowset.remove(accounts);

        assertFalse(allowset.contains(user1), "User1 should remain not inAllowset");
    }

    function test_RevertIf_RemoveFromAllowset_NotOwner() public {
        address[] memory addAccounts = new address[](1);
        addAccounts[0] = user1;
        vm.startPrank(owner); // owner adds user1
        allowset.add(addAccounts);
        vm.stopPrank(); // Stop owner prank before starting nonOwner prank

        address[] memory removeAccounts = new address[](1);
        removeAccounts[0] = user1;

        vm.startPrank(nonOwner); // nonOwner tries to remove
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        allowset.remove(removeAccounts);
        vm.stopPrank();

        vm.prank(owner); // Verify user1 still inAllowset as owner didn't remove
        assertTrue(allowset.contains(user1), "User1 should still be inAllowset as non-owner failed to remove");
    }
}
