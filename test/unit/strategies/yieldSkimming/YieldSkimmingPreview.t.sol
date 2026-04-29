// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.18;

import { Setup, IMockStrategy } from "./utils/Setup.sol";
import { MockStrategySkimming } from "test/mocks/core/tokenized-strategies/MockStrategySkimming.sol";
import { YieldSkimmingTokenizedStrategy } from "src/strategies/yieldSkimming/YieldSkimmingTokenizedStrategy.sol";

/// @notice Regression suite for yield-skimming preview accuracy: ERC-4626 `previewX` must
///         match the real `deposit` / `mint` / `withdraw` / `redeem` call including the
///         strategy-specific gates (insolvency revert on deposit/mint, lazy dragon burn on
///         withdraw/redeem). Without the overrides, `previewDeposit(x)` in an insolvent
///         vault returns a positive share estimate even though the real `deposit` reverts
///         with "Cannot operate when vault is insolvent".
contract YieldSkimmingPreviewTest is Setup {
    uint256 internal constant INITIAL_RATE = 1e18;
    uint256 internal constant DEPOSIT_AMOUNT = 100e18;
    bytes32 internal constant TOKENIZED_STRATEGY_STORAGE =
        keccak256(abi.encode(uint256(keccak256("octant.tokenized.strategy.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 internal constant TOTAL_SUPPLY_SLOT = bytes32(uint256(TOKENIZED_STRATEGY_STORAGE) + 8);
    bytes32 internal constant TOTAL_ASSETS_SLOT = bytes32(uint256(TOKENIZED_STRATEGY_STORAGE) + 9);

    function setUp() public override {
        super.setUp();
    }

    function _writeStrategyState(uint256 totalSupply_, uint256 totalAssets_) internal {
        vm.store(address(strategy), TOTAL_SUPPLY_SLOT, bytes32(totalSupply_));
        vm.store(address(strategy), TOTAL_ASSETS_SLOT, bytes32(totalAssets_));
    }

    /// @dev Drops the exchange rate to force `_isVaultInsolvent` -> true. After a deposit
    ///      at the initial rate, halving the rate leaves `currentVaultValue` below
    ///      `totalDebtOwedToUserInAssetValue` (which was locked in at the higher rate).
    function _makeInsolventAfterDeposit(uint256 newRate) internal {
        MockStrategySkimming(address(strategy)).updateExchangeRate(newRate);
        assertTrue(
            YieldSkimmingTokenizedStrategy(address(strategy)).isVaultInsolvent(),
            "setup: vault should be insolvent after rate drop"
        );
    }

    // -------------------------------------------------------------------------
    // Deposit / mint: preview mirrors the solvency gate that `deposit` / `mint`
    // enforce via `_requireVaultSolvency`.
    // -------------------------------------------------------------------------

    function test_previewDeposit_matchesDepositWhenSolvent(uint256 _amount) public {
        _amount = bound(_amount, 1e6, 1e24);

        // Seed the vault so totalSupply > 0 (otherwise previewDeposit takes the
        // 1:1 fallback in _convertToShares and we aren't exercising the rate path).
        mintAndDepositIntoStrategy(strategy, user, DEPOSIT_AMOUNT);

        uint256 predicted = strategy.previewDeposit(_amount);

        // Fund a fresh user and deposit to measure the real return.
        address alice = makeAddr("alice");
        yieldSource.mint(alice, _amount);
        vm.prank(alice);
        yieldSource.approve(address(strategy), _amount);

        vm.prank(alice);
        uint256 actual = strategy.deposit(_amount, alice);

        assertEq(predicted, actual, "previewDeposit must equal actual deposit shares");
    }

    function test_previewDeposit_returnsZeroWhenInsolvent() public {
        mintAndDepositIntoStrategy(strategy, user, DEPOSIT_AMOUNT);

        _makeInsolventAfterDeposit(INITIAL_RATE / 2);

        assertEq(strategy.previewDeposit(1e18), 0, "previewDeposit must return 0 while the real deposit would revert");
    }

    function test_previewMint_matchesMintWhenSolvent(uint256 _shares) public {
        _shares = bound(_shares, 1e6, 1e24);

        mintAndDepositIntoStrategy(strategy, user, DEPOSIT_AMOUNT);

        uint256 predicted = strategy.previewMint(_shares);

        address bob = makeAddr("bob");
        yieldSource.mint(bob, predicted + 1e18); // a little slack for rounding
        vm.prank(bob);
        yieldSource.approve(address(strategy), type(uint256).max);

        vm.prank(bob);
        uint256 actual = strategy.mint(_shares, bob);

        assertEq(predicted, actual, "previewMint must equal actual mint assets");
    }

    function test_previewMint_returnsZeroWhenInsolvent() public {
        mintAndDepositIntoStrategy(strategy, user, DEPOSIT_AMOUNT);

        _makeInsolventAfterDeposit(INITIAL_RATE / 2);

        assertEq(strategy.previewMint(1e18), 0, "previewMint must return 0 while the real mint would revert");
    }

    function test_previewsReturnZeroWhenSupplyZeroAssetsPositive() public {
        _writeStrategyState({ totalSupply_: 0, totalAssets_: DEPOSIT_AMOUNT });

        assertEq(strategy.maxDeposit(user), 0, "stranded assets should block deposits");
        assertEq(strategy.maxMint(user), 0, "stranded assets should block mints");
        assertEq(strategy.previewDeposit(1e18), 0, "previewDeposit should mirror stranded-assets guard");
        assertEq(strategy.previewMint(1e18), 0, "previewMint should mirror stranded-assets guard");
        assertEq(strategy.convertToShares(1e18), 0, "convertToShares should mirror stranded-assets guard");
        assertEq(strategy.convertToAssets(1e18), 0, "convertToAssets should mirror stranded-assets guard");
    }

    // -------------------------------------------------------------------------
    // Withdraw / redeem: with no pending dragon burn the inherited preview math
    // is correct; exercise it to lock in the happy path.
    // -------------------------------------------------------------------------

    function test_previewRedeem_matchesRedeemWhenSolvent(uint256 _shares) public {
        mintAndDepositIntoStrategy(strategy, user, DEPOSIT_AMOUNT);

        uint256 userShares = strategy.balanceOf(user);
        _shares = bound(_shares, 1, userShares);

        uint256 predicted = strategy.previewRedeem(_shares);

        vm.prank(user);
        uint256 actual = strategy.redeem(_shares, user, user);

        assertEq(predicted, actual, "previewRedeem must equal actual redeem assets");
    }

    function test_previewWithdraw_matchesWithdrawWhenSolvent(uint256 _assets) public {
        mintAndDepositIntoStrategy(strategy, user, DEPOSIT_AMOUNT);

        uint256 maxAssets = strategy.maxWithdraw(user);
        _assets = bound(_assets, 1, maxAssets);

        uint256 predicted = strategy.previewWithdraw(_assets);

        uint256 sharesBefore = strategy.balanceOf(user);
        vm.prank(user);
        strategy.withdraw(_assets, user, user);
        uint256 sharesAfter = strategy.balanceOf(user);
        uint256 actual = sharesBefore - sharesAfter;

        assertEq(predicted, actual, "previewWithdraw must equal actual shares burned");
    }

    // -------------------------------------------------------------------------
    // Redeem with a pending lazy dragon burn: preview must price against the
    // POST-burn supply, otherwise it underestimates the assets a user receives.
    // -------------------------------------------------------------------------

    function test_previewRedeem_reflectsPendingDragonBurn() public {
        // Enable burning so `_applyDragonLossProtectionIfNeeded` actually fires
        // on the redeem path we are testing.
        vm.prank(management);
        YieldSkimmingTokenizedStrategy(address(strategy)).setEnableBurning(true);

        // User deposits and locks in a value debt of DEPOSIT_AMOUNT at the initial rate.
        mintAndDepositIntoStrategy(strategy, user, DEPOSIT_AMOUNT);

        // Report a profit so the dragon router receives shares that can be burned.
        // Bump the yield-source balance of the strategy to simulate appreciation,
        // then call report() to mint dragon shares at the higher rate.
        MockStrategySkimming(address(strategy)).updateExchangeRate((INITIAL_RATE * 12) / 10); // +20%
        vm.prank(keeper);
        strategy.report();
        assertGt(strategy.balanceOf(donationAddress), 0, "dragon must hold shares for burn simulation");

        // Drop the rate back below the user's locked-in debt to cause insolvency.
        // The lazy burn logic will then be eligible during `redeem`.
        MockStrategySkimming(address(strategy)).updateExchangeRate(INITIAL_RATE / 2);
        assertTrue(
            YieldSkimmingTokenizedStrategy(address(strategy)).isVaultInsolvent(),
            "vault must be insolvent for the lazy burn to fire"
        );

        // Preview the user's redeem with the burn pending, then execute redeem and
        // confirm the real output matches the preview (post-burn pricing).
        uint256 userShares = strategy.balanceOf(user);
        uint256 predicted = strategy.previewRedeem(userShares);

        vm.prank(user);
        uint256 actual = strategy.redeem(userShares, user, user);

        assertEq(predicted, actual, "previewRedeem must mirror post-burn redeem math");
    }
}
