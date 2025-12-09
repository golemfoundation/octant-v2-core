// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.23;

import { AccessMode } from "src/constants.sol";
import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { RegenStakerWithoutDelegateSurrogateVotes } from "src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol";
import { RegenStakerBase } from "src/regen/RegenStakerBase.sol";
import { RegenSameTokenHandler } from "./RegenSameTokenHandler.t.sol";
import { RegenEarningPowerCalculator } from "src/regen/RegenEarningPowerCalculator.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AddressSet } from "src/utils/AddressSet.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";

contract RegenSameTokenInvariant is StdInvariant, Test {
    RegenStakerWithoutDelegateSurrogateVotes public staker;
    MockERC20 public token;
    AddressSet public allowset;
    RegenEarningPowerCalculator public earningPowerCalculator;
    address public admin = address(0xA);
    address public notifier = address(0xB);
    address public user = address(0xC);
    RegenSameTokenHandler public handler;

    function setUp() public {
        token = new MockERC20(18);
        allowset = new AddressSet();
        allowset.add(user);
        earningPowerCalculator = new RegenEarningPowerCalculator(
            admin,
            IAddressSet(address(allowset)),
            IAddressSet(address(0)),
            AccessMode.ALLOWSET
        );

        staker = new RegenStakerWithoutDelegateSurrogateVotes(
            IERC20(address(token)),
            IERC20(address(token)),
            earningPowerCalculator,
            0,
            admin,
            30 days,
            0,
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            AccessMode.NONE,
            allowset
        );

        vm.prank(admin);
        staker.setRewardNotifier(notifier, true);

        handler = new RegenSameTokenHandler(staker, token, admin, notifier, user);
        targetContract(address(handler));
    }

    function invariant_SameTokenBalanceMeetsRequired() public view {
        // If reward token equals stake token, require: balance >= totalStaked
        if (address(staker.REWARD_TOKEN()) == address(staker.STAKE_TOKEN())) {
            assertGe(token.balanceOf(address(staker)), staker.totalStaked());
        }
    }
}
