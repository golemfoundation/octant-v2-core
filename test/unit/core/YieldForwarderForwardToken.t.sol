// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { YieldForwarder } from "src/core/YieldForwarder.sol";
import { SwappingYieldForwarder } from "src/core/SwappingYieldForwarder.sol";
import { MockSwapper } from "test/mocks/MockSwapper.sol";

/// @notice Bailsec #63 -- pre-fix, a `YieldForwarder` deployed as a strategy's
///         `dragonRouter` had no path for arbitrary ERC-20 balances. If Spark (or
///         any airdrop-emitting strategy) called `sweepAirdrop` while the forwarder
///         was the router, the swept tokens were stuck at the forwarder forever.
///         Fix: permissionless `forwardToken(address)` that flushes any ERC-20
///         balance to the immutable `receiver`. Permissionless is safe because
///         the caller cannot choose the destination (it's fixed at construction).
contract YieldForwarderForwardTokenTest is Test {
    YieldForwarder internal forwarder;
    SwappingYieldForwarder internal swappingForwarder;
    ERC20Mock internal token;
    ERC20Mock internal targetAsset;

    address internal receiver = address(0xBEEF);
    address internal keeperEOA = address(0xCAFE);
    address internal randomCaller = address(0xD00D);

    function setUp() public {
        forwarder = new YieldForwarder(receiver, keeperEOA);

        // Swapper implementation is irrelevant for forwardToken tests; we only
        // need a non-zero address so the constructor accepts it.
        targetAsset = new ERC20Mock();
        MockSwapper swapper = new MockSwapper(address(targetAsset), 1e18);
        swappingForwarder = new SwappingYieldForwarder(receiver, keeperEOA, address(targetAsset), address(swapper));

        token = new ERC20Mock();
    }

    // --- YieldForwarder.forwardToken ---

    /// @notice Happy path: permissionless caller flushes the full token balance to `receiver`.
    function test_forwardToken_permissionlessToReceiver() public {
        token.mint(address(forwarder), 123 ether);

        vm.prank(randomCaller);
        forwarder.forwardToken(address(token));

        assertEq(token.balanceOf(receiver), 123 ether, "receiver must get full balance");
        assertEq(token.balanceOf(address(forwarder)), 0, "forwarder must be drained");
    }

    /// @notice Keeper can also call (permissionless => everyone can).
    function test_forwardToken_keeperCallerAllowed() public {
        token.mint(address(forwarder), 7 ether);

        vm.prank(keeperEOA);
        forwarder.forwardToken(address(token));

        assertEq(token.balanceOf(receiver), 7 ether, "keeper call must forward");
    }

    /// @notice Zero balance returns silently (no revert) so bots can call speculatively.
    function test_forwardToken_zeroBalanceIsNoop() public {
        assertEq(token.balanceOf(address(forwarder)), 0, "precondition: zero");

        vm.prank(randomCaller);
        forwarder.forwardToken(address(token));

        assertEq(token.balanceOf(receiver), 0, "no transfer on zero balance");
    }

    /// @notice Emits TokenForwarded with the right (token, receiver, amount) tuple.
    function test_forwardToken_emitsTokenForwardedEvent() public {
        token.mint(address(forwarder), 50 ether);

        vm.expectEmit(true, true, false, true);
        emit YieldForwarder.TokenForwarded(address(token), receiver, 50 ether);

        vm.prank(randomCaller);
        forwarder.forwardToken(address(token));
    }

    /// @notice Destination is locked to the immutable `receiver` regardless of caller.
    function test_forwardToken_destinationIsImmutableReceiver() public {
        token.mint(address(forwarder), 42 ether);

        // The caller's address is not the receiver. Make sure it doesn't get the tokens.
        assertTrue(randomCaller != receiver, "precondition: caller != receiver");
        vm.prank(randomCaller);
        forwarder.forwardToken(address(token));

        assertEq(token.balanceOf(randomCaller), 0, "caller must not get tokens");
        assertEq(token.balanceOf(receiver), 42 ether, "only receiver gets tokens");
    }

    // --- SwappingYieldForwarder inherits forwardToken ---

    /// @notice The swapping variant inherits forwardToken for free; verify mechanically.
    function test_forwardToken_swappingForwarderInheritsBehavior() public {
        token.mint(address(swappingForwarder), 9 ether);

        vm.prank(randomCaller);
        swappingForwarder.forwardToken(address(token));

        assertEq(token.balanceOf(receiver), 9 ether, "swapping variant forwards to receiver");
        assertEq(token.balanceOf(address(swappingForwarder)), 0, "swapping variant drained");
    }
}
