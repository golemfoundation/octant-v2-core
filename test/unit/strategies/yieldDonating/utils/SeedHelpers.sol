// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.25;

import { Test } from "forge-std/Test.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { MockERC20 as CoreMockERC20 } from "test/mocks/MockERC20.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";

abstract contract SeedHelpers is Test {
    uint256 internal constant MINIMUM_PROTOCOL_POSITION = 1_000_000_000;

    function _seedMinimumPosition(address strategyAddr, ERC20Mock asset, address management) internal {
        asset.mint(management, MINIMUM_PROTOCOL_POSITION);

        vm.startPrank(management);
        asset.approve(strategyAddr, MINIMUM_PROTOCOL_POSITION);
        YieldDonatingTokenizedStrategy(strategyAddr).seedMinimumPosition();
        vm.stopPrank();
    }

    function _seedMinimumPosition(address strategyAddr, CoreMockERC20 asset, address management) internal {
        asset.mint(management, MINIMUM_PROTOCOL_POSITION);

        vm.startPrank(management);
        asset.approve(strategyAddr, MINIMUM_PROTOCOL_POSITION);
        YieldDonatingTokenizedStrategy(strategyAddr).seedMinimumPosition();
        vm.stopPrank();
    }
}
