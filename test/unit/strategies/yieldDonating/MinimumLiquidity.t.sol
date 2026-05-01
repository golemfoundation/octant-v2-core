// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.25;

import { Setup } from "./utils/Setup.sol";
import { IBaseStrategy } from "src/core/interfaces/IBaseStrategy.sol";

/// @notice Regression suite for the Bailsec dust-share accounting chain using
///         Uniswap V2-style minimum liquidity plus dragon recovery-surplus shares.
contract MinimumLiquidityTest is Setup {
    address internal constant DEAD_SHARES = address(0xdead);
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;

    /// @dev ERC-7201 base slot derived from "octant.tokenized.strategy.storage". Matches the
    ///      `BASE_STRATEGY_STORAGE` constant inside `TokenizedStrategy`.
    bytes32 internal constant OCTANT_STRATEGY_STORAGE =
        keccak256(abi.encode(uint256(keccak256("octant.tokenized.strategy.storage")) - 1)) & ~bytes32(uint256(0xff));

    /// @dev StrategyData.totalSupply sits at offset 8 from the base.
    bytes32 internal constant TOTAL_SUPPLY_SLOT = bytes32(uint256(OCTANT_STRATEGY_STORAGE) + 8);

    /// @dev StrategyData.totalAssets sits one slot after totalSupply.
    bytes32 internal constant TOTAL_ASSETS_SLOT = bytes32(uint256(OCTANT_STRATEGY_STORAGE) + 9);

    address internal attacker = address(0xA11CE);
    address internal victim = address(0xB0B);

    function _deposit(address account, uint256 assets) internal returns (uint256 shares) {
        asset.mint(account, assets);

        vm.startPrank(account);
        asset.approve(address(strategy), assets);
        shares = strategy.deposit(assets, account);
        vm.stopPrank();
    }

    function _writeStrategyState(uint256 totalSupply_, uint256 totalAssets_) internal {
        vm.store(address(strategy), TOTAL_SUPPLY_SLOT, bytes32(totalSupply_));
        vm.store(address(strategy), TOTAL_ASSETS_SLOT, bytes32(totalAssets_));
    }

    function _reportForcedRecovery(uint256 oldSupply, uint256 recovery) internal {
        _writeStrategyState({ totalSupply_: oldSupply, totalAssets_: 0 });
        asset.mint(address(strategy), recovery);

        vm.prank(keeper);
        strategy.report();
    }

    function _enterZeroAssetDustState(uint256 initialAssets) internal {
        uint256 attackerShares = _deposit(attacker, initialAssets);

        vm.prank(attacker);
        strategy.withdraw(attackerShares - 1, attacker, attacker, MAX_BPS);

        assertEq(strategy.balanceOf(attacker), 1, "attacker dust share");
        assertEq(strategy.balanceOf(DEAD_SHARES), MINIMUM_LIQUIDITY, "dead shares seeded");
        assertEq(strategy.totalSupply(), MINIMUM_LIQUIDITY + 1, "only dead plus dust supply remains");
        assertEq(strategy.totalAssets(), MINIMUM_LIQUIDITY + 1, "only locked plus dust assets remain");

        yieldSource.simulateLoss(MINIMUM_LIQUIDITY + 1);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(profit, 0, "no profit on loss report");
        assertEq(loss, MINIMUM_LIQUIDITY + 1, "remaining assets are reported lost");
        assertEq(strategy.totalAssets(), 0, "tracked assets reduced to zero");
        assertEq(strategy.totalSupply(), MINIMUM_LIQUIDITY + 1, "supply remains nonzero");
    }

    function test_firstDepositSeedsDeadMinimumLiquidity() public {
        uint256 firstDeposit = 100 ether;

        uint256 shares = _deposit(user, firstDeposit);

        assertEq(shares, firstDeposit - MINIMUM_LIQUIDITY, "first depositor funds locked shares");
        assertEq(strategy.balanceOf(user), firstDeposit - MINIMUM_LIQUIDITY, "user receives remainder");
        assertEq(strategy.balanceOf(DEAD_SHARES), MINIMUM_LIQUIDITY, "dead address receives minimum");
        assertEq(strategy.totalSupply(), firstDeposit, "total supply stays 1:1 with assets");
        assertEq(strategy.totalAssets(), firstDeposit, "total assets track the deposit");
    }

    function test_firstDepositAtOrBelowMinimumLiquidityReverts() public {
        asset.mint(user, MINIMUM_LIQUIDITY);

        vm.startPrank(user);
        asset.approve(address(strategy), MINIMUM_LIQUIDITY);
        vm.expectRevert("ZERO_SHARES");
        strategy.deposit(MINIMUM_LIQUIDITY, user);
        vm.stopPrank();

        assertEq(strategy.totalSupply(), 0, "no dead shares minted on failed first deposit");
    }

    function test_firstDepositMaxDepositReturnsZeroWhenLimitCannotFundMinimumLiquidity() public {
        vm.mockCall(
            address(strategy),
            abi.encodeWithSelector(IBaseStrategy.availableDepositLimit.selector, victim),
            abi.encode(MINIMUM_LIQUIDITY)
        );

        assertEq(strategy.maxDeposit(victim), 0, "dust first-deposit limit is unusable");
        assertEq(strategy.maxMint(victim), 0, "dust first-deposit limit mints no shares");

        asset.mint(victim, MINIMUM_LIQUIDITY);
        vm.startPrank(victim);
        asset.approve(address(strategy), MINIMUM_LIQUIDITY);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(MINIMUM_LIQUIDITY, victim);
        vm.stopPrank();

        vm.clearMockedCalls();
    }

    function test_firstDepositMaxDepositAllowsLimitAboveMinimumLiquidity() public {
        uint256 limit = MINIMUM_LIQUIDITY + 1;

        vm.mockCall(
            address(strategy),
            abi.encodeWithSelector(IBaseStrategy.availableDepositLimit.selector, victim),
            abi.encode(limit)
        );

        assertEq(strategy.maxDeposit(victim), limit, "first-deposit limit can fund minimum liquidity");
        assertEq(strategy.maxMint(victim), 1, "only surplus over minimum liquidity is mintable");

        asset.mint(victim, limit);
        vm.startPrank(victim);
        asset.approve(address(strategy), limit);
        uint256 shares = strategy.deposit(strategy.maxDeposit(victim), victim);
        vm.stopPrank();

        assertEq(shares, 1, "deposits the first usable share");
        assertEq(strategy.balanceOf(DEAD_SHARES), MINIMUM_LIQUIDITY, "dead shares seeded");
        assertEq(strategy.totalSupply(), limit, "supply includes first user and dead shares");
        assertEq(strategy.totalAssets(), limit, "assets track the limited first deposit");

        vm.clearMockedCalls();
    }

    function test_firstDepositAndMintPreviewBoundaries() public view {
        assertEq(strategy.previewDeposit(MINIMUM_LIQUIDITY - 1), 0, "deposit below lock mints zero");
        assertEq(strategy.previewDeposit(MINIMUM_LIQUIDITY), 0, "deposit equal to lock mints zero");
        assertEq(strategy.previewDeposit(MINIMUM_LIQUIDITY + 1), 1, "deposit above lock mints remainder");
        assertEq(strategy.previewMint(0), 0, "zero first mint costs zero");
        assertEq(strategy.previewMint(1), MINIMUM_LIQUIDITY + 1, "first mint pays lock");
    }

    function test_firstMintIncludesMinimumLiquidityCost() public {
        uint256 requestedShares = 10 ether;
        uint256 requiredAssets = requestedShares + MINIMUM_LIQUIDITY;
        asset.mint(user, requiredAssets);

        vm.startPrank(user);
        asset.approve(address(strategy), requiredAssets);
        uint256 assets = strategy.mint(requestedShares, user);
        vm.stopPrank();

        assertEq(assets, requiredAssets, "first mint pays for locked liquidity");
        assertEq(strategy.balanceOf(user), requestedShares, "user receives exact requested shares");
        assertEq(strategy.balanceOf(DEAD_SHARES), MINIMUM_LIQUIDITY, "dead shares seeded");
        assertEq(strategy.totalSupply(), requiredAssets, "supply equals deposited assets");
        assertEq(strategy.totalAssets(), requiredAssets, "assets equal minted supply");
    }

    function test_zeroAssetTerminalStateMaxViewsReturnZero() public {
        _enterZeroAssetDustState(100 ether);

        assertEq(strategy.maxDeposit(victim), 0, "terminal maxDeposit");
        assertEq(strategy.maxMint(victim), 0, "terminal maxMint");
        assertEq(strategy.maxWithdraw(attacker), 0, "terminal maxWithdraw");
        assertEq(strategy.maxWithdraw(attacker, MAX_BPS), 0, "terminal maxWithdraw overload");
        assertEq(strategy.maxRedeem(attacker), 0, "terminal maxRedeem");
        assertEq(strategy.maxRedeem(attacker, MAX_BPS), 0, "terminal maxRedeem overload");
        assertEq(strategy.previewDeposit(1 ether), 0, "terminal previewDeposit");
        assertEq(strategy.previewMint(1 ether), 0, "terminal previewMint");
        assertEq(strategy.previewWithdraw(1), 0, "terminal previewWithdraw");
        assertEq(strategy.previewRedeem(1), 0, "terminal previewRedeem");
        assertEq(strategy.convertToShares(1 ether), 0, "terminal convertToShares");
        assertEq(strategy.convertToAssets(1), 0, "terminal convertToAssets");
    }

    function test_zeroAssetTerminalStateBlocksDepositMintWithdrawAndRedeem() public {
        _enterZeroAssetDustState(100 ether);

        asset.mint(victim, 1 ether);
        vm.startPrank(victim);
        asset.approve(address(strategy), 1 ether);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(1 ether, victim);
        vm.expectRevert("ERC4626: mint more than max");
        strategy.mint(1 ether, victim);
        vm.stopPrank();

        vm.prank(attacker);
        vm.expectRevert("ERC4626: withdraw more than max");
        strategy.withdraw(1, attacker, attacker, MAX_BPS);

        vm.prank(attacker);
        vm.expectRevert("ERC4626: redeem more than max");
        strategy.redeem(1, attacker, attacker, MAX_BPS);
    }

    function test_zeroAssetTerminalStateMaxViewsRecoverAfterReport() public {
        uint256 recovery = 100 ether;

        _enterZeroAssetDustState(100 ether);
        asset.mint(address(strategy), recovery);

        vm.prank(keeper);
        strategy.report();

        assertEq(strategy.maxDeposit(victim), type(uint256).max, "deposit capacity restored");
        assertEq(strategy.maxMint(victim), type(uint256).max, "mint capacity restored");
        assertEq(strategy.maxWithdraw(attacker), 1, "dust withdrawal restored at capped value");
        assertEq(strategy.maxRedeem(attacker), 1, "dust redeem restored at capped value");
        assertEq(strategy.maxRedeem(attacker, MAX_BPS), 1, "redeem overload restored at capped value");
    }

    function test_recoveryReportMintsSurplusToDragonAndRestoresDonationMinting() public {
        uint256 recovery = 100 ether;
        uint256 laterProfit = 7 ether;
        uint256 expectedRecoveryShares = recovery - MINIMUM_LIQUIDITY - 1;

        _enterZeroAssetDustState(100 ether);

        asset.mint(address(strategy), recovery);

        vm.prank(keeper);
        (uint256 recoveryProfit, uint256 recoveryLoss) = strategy.report();

        assertEq(recoveryProfit, recovery, "donation is reported as recovered profit");
        assertEq(recoveryLoss, 0, "no loss on recovery");
        assertEq(strategy.totalAssets(), recovery, "tracked assets restored");
        assertEq(strategy.totalSupply(), recovery, "recovery restores 1:1 PPS");
        assertEq(strategy.balanceOf(address(strategy)), 0, "no surplus recovery shares are locked");
        assertEq(strategy.balanceOf(donationAddress), expectedRecoveryShares, "surplus recovery shares go to dragon");
        assertEq(strategy.maxWithdraw(attacker), 1, "dust holder can only claim its dust");

        asset.mint(address(yieldSource), laterProfit);

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(profit, laterProfit, "later yield reports normally");
        assertEq(loss, 0, "no later loss");
        assertEq(
            strategy.balanceOf(donationAddress),
            expectedRecoveryShares + laterProfit,
            "dragon keeps recovery shares and receives later profit shares"
        );
    }

    function test_recoveryAtOrBelowOldSupplyDoesNotMintSurplusToDragon() public {
        uint256 oldSupply = MINIMUM_LIQUIDITY + 1;

        _reportForcedRecovery({ oldSupply: oldSupply, recovery: oldSupply - 1 });
        assertEq(strategy.totalAssets(), oldSupply - 1, "below-supply recovery tracked");
        assertEq(strategy.totalSupply(), oldSupply, "below-supply recovery does not mint");
        assertEq(strategy.balanceOf(address(strategy)), 0, "no locked surplus below supply");
        assertEq(strategy.balanceOf(donationAddress), 0, "dragon gets no below-supply surplus");
    }

    function test_recoveryEqualToOldSupplyDoesNotMintSurplusToDragon() public {
        uint256 oldSupply = MINIMUM_LIQUIDITY + 1;

        _reportForcedRecovery({ oldSupply: oldSupply, recovery: oldSupply });
        assertEq(strategy.totalAssets(), oldSupply, "equal-supply recovery tracked");
        assertEq(strategy.totalSupply(), oldSupply, "equal-supply recovery does not mint");
        assertEq(strategy.balanceOf(address(strategy)), 0, "no locked surplus at supply boundary");
        assertEq(strategy.balanceOf(donationAddress), 0, "dragon gets no equal-supply surplus");
    }

    function test_recoveryAboveOldSupplyMintsOnlySurplusToDragon() public {
        uint256 oldSupply = MINIMUM_LIQUIDITY + 1;
        uint256 recovery = 100 ether;
        uint256 expectedRecoveryShares = recovery - oldSupply;

        _reportForcedRecovery({ oldSupply: oldSupply, recovery: recovery });
        assertEq(strategy.totalAssets(), recovery, "surplus recovery tracked");
        assertEq(strategy.totalSupply(), recovery, "dragon surplus restores one-to-one pps");
        assertEq(strategy.balanceOf(address(strategy)), 0, "no surplus is locked");
        assertEq(strategy.balanceOf(donationAddress), expectedRecoveryShares, "only surplus goes to dragon");
    }

    function test_bailsecChainCannotReachFirstDepositorInflation() public {
        uint256 recovery = 100 ether;
        uint256 victimDeposit = 150 ether;

        _enterZeroAssetDustState(100 ether);

        asset.mint(address(strategy), recovery);

        vm.prank(keeper);
        strategy.report();

        vm.prank(attacker);
        strategy.withdraw(1, attacker, attacker, 0);

        assertEq(strategy.totalAssets(), recovery - 1, "only requested dust asset is removed");
        assertEq(strategy.totalSupply(), recovery - 1, "dragon shares keep supply nonzero");

        uint256 attackerSandwichShares = _deposit(attacker, 1);
        uint256 victimShares = _deposit(victim, victimDeposit);

        assertEq(attackerSandwichShares, 1, "attacker receives fair shares for dust");
        assertEq(victimShares, victimDeposit, "victim deposit mints at fair 1:1 PPS");

        vm.prank(attacker);
        uint256 attackerAssets = strategy.redeem(attackerSandwichShares, attacker, attacker, 0);

        assertEq(attackerAssets, 1, "attacker cannot amplify a 1 wei deposit");
    }

    function test_forcedGhostStateBlocksDepositsUntilReportLocksShares() public {
        uint256 trackedGhostAssets = 100 ether;
        uint256 donatedAssets = 5 ether;

        _writeStrategyState({ totalSupply_: 0, totalAssets_: trackedGhostAssets });
        asset.mint(address(yieldSource), trackedGhostAssets + donatedAssets);

        assertEq(strategy.maxDeposit(victim), 0, "ghost state blocks deposits");
        assertEq(strategy.maxMint(victim), 0, "ghost state blocks mints");
        assertEq(strategy.previewDeposit(1 ether), 0, "ghost state does not price first depositor");

        asset.mint(victim, 1 ether);
        vm.startPrank(victim);
        asset.approve(address(strategy), 1 ether);
        vm.expectRevert("ERC4626: deposit more than max");
        strategy.deposit(1 ether, victim);
        vm.stopPrank();

        vm.prank(keeper);
        (uint256 profit, uint256 loss) = strategy.report();

        assertEq(profit, donatedAssets, "report observes donated surplus");
        assertEq(loss, 0, "no loss while balance exceeds tracked assets");
        assertEq(strategy.totalAssets(), trackedGhostAssets + donatedAssets, "assets are reconciled");
        assertEq(strategy.totalSupply(), trackedGhostAssets + donatedAssets, "locked supply repairs PPS");
        assertEq(
            strategy.balanceOf(address(strategy)),
            trackedGhostAssets + donatedAssets,
            "ghost collateral is locked to the strategy"
        );

        uint256 shares = _deposit(victim, 1 ether);
        assertEq(shares, 1 ether, "post-heal deposit mints at fair PPS");
    }
}
