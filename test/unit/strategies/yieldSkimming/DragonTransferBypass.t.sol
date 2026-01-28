// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import { Test } from "forge-std/Test.sol";
import { Setup } from "test/unit/strategies/yieldSkimming/utils/Setup.sol";
import { IMockStrategy } from "test/mocks/zodiac-core/IMockStrategy.sol";
import { MockStrategySkimming } from "test/mocks/core/tokenized-strategies/MockStrategySkimming.sol";

/// @notice Tests that dragon router transfers are correctly blocked during vault insolvency
contract DragonTransferBypassTest is Setup {
    address internal dragon = makeAddr("dragon");
    address internal ally = makeAddr("ally");

    function setUp() public override {
        super.setUp();

        // Configure dragon router
        vm.startPrank(management);
        IMockStrategy(address(strategy)).setDragonRouter(dragon);
        vm.stopPrank();

        // Cooldown to finalize
        skip(14 days);
        IMockStrategy(address(strategy)).finalizeDragonRouterChange();
    }

    function test_DragonTransferBlockedDuringInsolvency() public {
        // 1) User deposits to create user value debt
        uint256 userDeposit = 1_000_000 ether;
        mintAndDepositIntoStrategy(strategy, user, userDeposit);

        // 2) Increase exchange rate -> on report, profit recognized and dragon gets buffer shares
        MockStrategySkimming(address(strategy)).updateExchangeRate(15e17); // 1.5 * 1e18
        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = IMockStrategy(address(strategy)).report();
        assertGt(_profit, 0, "profit should be recognized on rate increase");
        assertEq(_loss, 0, "no loss on rate increase");

        // Sanity: dragon has shares after profit
        uint256 dragonShares = IMockStrategy(address(strategy)).balanceOf(dragon);
        assertGt(dragonShares, 0, "dragon must have shares after profit");

        // 3) Crash: drop the exchange rate sharply to create insolvency
        //    At rate 1.2: currentValue = 1,000,000 * 1.2 = 1,200,000 ETH value
        //    Total debt = 1,000,000 (user) + 500,000 (dragon) = 1,500,000 ETH value
        //    Since 1,200,000 < 1,500,000, vault is insolvent
        MockStrategySkimming(address(strategy)).updateExchangeRate(12e17); // 1.2 * 1e18

        // 4) Dragon transfer should be blocked during insolvency
        vm.prank(dragon);
        vm.expectRevert("Dragon cannot operate during insolvency");
        IMockStrategy(address(strategy)).transfer(ally, dragonShares);

        // 5) Verify dragon still has all shares (transfer was blocked)
        uint256 dragonSharesAfter = IMockStrategy(address(strategy)).balanceOf(dragon);
        assertEq(dragonSharesAfter, dragonShares, "dragon should still have all shares");

        // 6) Verify ally received no shares
        uint256 allyShares = IMockStrategy(address(strategy)).balanceOf(ally);
        assertEq(allyShares, 0, "ally should have no shares");
    }

    function test_DragonTransferAllowedWhenSolvent() public {
        // 1) User deposits to create user value debt
        uint256 userDeposit = 1_000_000 ether;
        mintAndDepositIntoStrategy(strategy, user, userDeposit);

        // 2) Increase exchange rate -> on report, profit recognized and dragon gets buffer shares
        MockStrategySkimming(address(strategy)).updateExchangeRate(15e17); // 1.5 * 1e18
        vm.prank(keeper);
        (uint256 _profit, uint256 _loss) = IMockStrategy(address(strategy)).report();
        assertGt(_profit, 0, "profit should be recognized on rate increase");
        assertEq(_loss, 0, "no loss on rate increase");

        // Sanity: dragon has shares after profit
        uint256 dragonShares = IMockStrategy(address(strategy)).balanceOf(dragon);
        assertGt(dragonShares, 0, "dragon must have shares after profit");

        // 3) Keep rate at 1.5 or higher to maintain solvency
        //    At rate 1.5: currentValue = 1,000,000 * 1.5 = 1,500,000 ETH value
        //    Total debt = 1,000,000 (user) + 500,000 (dragon) = 1,500,000 ETH value
        //    Since 1,500,000 >= 1,500,000, vault is solvent

        // 4) Dragon transfer should succeed when vault is solvent
        vm.prank(dragon);
        bool ok = IMockStrategy(address(strategy)).transfer(ally, dragonShares);
        assertTrue(ok, "dragon transfer should succeed when vault is solvent");

        // 5) Verify dragon has no shares left
        uint256 dragonSharesAfter = IMockStrategy(address(strategy)).balanceOf(dragon);
        assertEq(dragonSharesAfter, 0, "dragon should have no shares after transfer");

        // 6) Verify ally received all shares
        uint256 allyShares = IMockStrategy(address(strategy)).balanceOf(ally);
        assertEq(allyShares, dragonShares, "ally should have received all dragon shares");
    }
}
