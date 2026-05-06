// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { DirectTransfer } from "src/core/DirectTransfer.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

contract DirectTransferTest is Test {
    DirectTransfer internal directTransfer;
    MockERC20 internal token;
    MockERC20 internal otherToken;

    address internal alice = address(0xA11CE);
    address internal project = address(0xB0B);

    uint256 internal constant START_BALANCE = 1_000 ether;

    event Transferred(address indexed token, address indexed from, address indexed to, uint256 amount);

    function setUp() public {
        directTransfer = new DirectTransfer();
        token = new MockERC20(18);
        otherToken = new MockERC20(6);

        token.mint(alice, START_BALANCE);
        otherToken.mint(alice, START_BALANCE);
    }

    function test_transfer_movesTokensAndEmitsEvent() public {
        uint256 amount = 5 ether;

        vm.prank(alice);
        token.approve(address(directTransfer), amount);

        vm.expectEmit(true, true, true, true, address(directTransfer));
        emit Transferred(address(token), alice, project, amount);

        vm.prank(alice);
        directTransfer.transfer(IERC20(address(token)), project, amount);

        assertEq(token.balanceOf(alice), START_BALANCE - amount, "sender balance");
        assertEq(token.balanceOf(project), amount, "recipient balance");
        assertEq(token.balanceOf(address(directTransfer)), 0, "contract holds nothing");
    }

    function test_transfer_worksAcrossDifferentTokens() public {
        uint256 amountA = 3 ether;
        uint256 amountB = 250e6;

        vm.startPrank(alice);
        token.approve(address(directTransfer), amountA);
        otherToken.approve(address(directTransfer), amountB);
        directTransfer.transfer(IERC20(address(token)), project, amountA);
        directTransfer.transfer(IERC20(address(otherToken)), project, amountB);
        vm.stopPrank();

        assertEq(token.balanceOf(project), amountA, "token A received");
        assertEq(otherToken.balanceOf(project), amountB, "token B received");
    }

    function test_transfer_revertsOnZeroToken() public {
        vm.prank(alice);
        vm.expectRevert(DirectTransfer.ZeroToken.selector);
        directTransfer.transfer(IERC20(address(0)), project, 1);
    }

    function test_transfer_revertsOnZeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert(DirectTransfer.ZeroRecipient.selector);
        directTransfer.transfer(IERC20(address(token)), address(0), 1);
    }

    function test_transfer_revertsOnZeroAmount() public {
        vm.prank(alice);
        vm.expectRevert(DirectTransfer.ZeroAmount.selector);
        directTransfer.transfer(IERC20(address(token)), project, 0);
    }

    function test_transfer_revertsWithoutApproval() public {
        vm.prank(alice);
        vm.expectRevert();
        directTransfer.transfer(IERC20(address(token)), project, 1 ether);
    }

    function test_transfer_revertsOnInsufficientBalance() public {
        uint256 amount = START_BALANCE + 1;

        vm.prank(alice);
        token.approve(address(directTransfer), amount);

        vm.prank(alice);
        vm.expectRevert();
        directTransfer.transfer(IERC20(address(token)), project, amount);
    }

    function testFuzz_transfer_emitsEventWithExactValues(uint256 amount) public {
        amount = bound(amount, 1, START_BALANCE);

        vm.prank(alice);
        token.approve(address(directTransfer), amount);

        vm.expectEmit(true, true, true, true, address(directTransfer));
        emit Transferred(address(token), alice, project, amount);

        vm.prank(alice);
        directTransfer.transfer(IERC20(address(token)), project, amount);

        assertEq(token.balanceOf(project), amount);
    }
}
