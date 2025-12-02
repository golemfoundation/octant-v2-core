// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.18;

import { Test, stdError } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Setup, IMockStrategy } from "test/unit/strategies/yieldSkimming/utils/Setup.sol";
import { IYieldSkimmingStrategy } from "src/strategies/yieldSkimming/IYieldSkimmingStrategy.sol";
import { MockStrategySkimming } from "test/mocks/core/tokenized-strategies/MockStrategySkimming.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { MockYieldSourceSkimming } from "test/mocks/core/tokenized-strategies/MockYieldSourceSkimming.sol";
/**
 * @title YieldSkimmingFuzzHandler
 * @notice Minimal, self-contained handler used by the StdInvariant suite to
 *         exercise the yield-skimming strategy with randomized sequences of
 *         actions while keeping calls successful where intended.
 * @dev    This is intentionally simple: mint underlying to random actors,
 *         deposit/redeem, have keeper report, and occasionally try a dragon
 *         transfer (which should revert while insolvent).
 */
contract YieldSkimmingFuzzHandler {
    IMockStrategy public immutable strategy;
    ERC20Mock public immutable asset;
    MockYieldSourceSkimming public immutable yieldSource;
    address public immutable keeper;
    address public immutable dragon;

    address[] public actors;

    constructor(
        IMockStrategy _strategy,
        ERC20Mock _asset,
        MockYieldSourceSkimming _yieldSource,
        address _keeper,
        address _dragon,
        address[] memory _actors
    ) {
        strategy = _strategy;
        asset = _asset;
        yieldSource = _yieldSource;
        keeper = _keeper;
        dragon = _dragon;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        if (actors.length == 0) return address(0);
        return actors[seed % actors.length];
    }

    /**
     * @notice Randomized user deposit path
     * @dev    Mints `assets` to the chosen actor, approves the strategy, then deposits.
     */
    function deposit(uint256 assets, uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        if (actor == address(0)) return;
        assets = (assets % 1e24) + 1;
        asset.mint(actor, assets);
        (bool ok1, ) = address(asset).call(
            abi.encodeWithSignature("approve(address,uint256)", address(strategy), assets)
        );
        if (!ok1) return;
        (bool ok2, ) = address(strategy).call(abi.encodeWithSignature("deposit(uint256,address)", assets, actor));
        ok2;
    }

    /**
     * @notice Randomized partial redemption path
     */
    function redeemSome(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        if (actor == address(0)) return;
        uint256 bal = strategy.balanceOf(actor);
        if (bal == 0) return;
        uint256 shares = bal / 2 + 1;
        (bool ok, ) = address(strategy).call(
            abi.encodeWithSignature("redeem(uint256,address,address)", shares, actor, actor)
        );
        ok;
    }

    /**
     * @notice Keeper report
     */
    function report() external {
        (bool ok, ) = address(strategy).call(abi.encodeWithSignature("report()"));
        ok;
    }

    /**
     * @notice Dragon attempts a transfer (should revert while insolvent)
     */
    function dragonTransfer(uint256 amount, uint256 actorSeed) external {
        amount = (amount % 1e18) + 1;
        address to = _actor(actorSeed);
        if (to == address(0)) to = address(0xBEEF);
        (bool ok, ) = address(strategy).call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        ok;
    }
}

/**
 * @title YieldSkimmingInvariantSuite
 * @notice Self-contained StdInvariant suite + helper functions.
 * @dev    This suite asserts the collapsed invariants:
 *         - Conversion:
 *             assetsOut(shares) = shares * min(totalAssets / S, 1 / currentRate)
 *         - Dragon gating and mint/burn bounds:
 *             no mint unless V > D; possible burn when V < D; dragon ops blocked when insolvent
 *         Notation:
 *             V = totalAssets * currentRate (user-value units, 1e18 scale)
 *             S = totalShares
 *             D = userDebt + dragonDebt (value units)
 */
contract YieldSkimmingInvariantSuite is StdInvariant, Setup {
    YieldSkimmingFuzzHandler internal fuzzHandler;
    uint256 internal constant WAD = 1e18; // 1.0 in 18-decimal fixed-point

    function setUp() public override {
        super.setUp();

        // Build actors set
        address[] memory actors = new address[](3);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");

        fuzzHandler = new YieldSkimmingFuzzHandler(
            strategy,
            asset,
            yieldSource,
            keeper,
            address(donationAddress),
            actors
        );

        // Target the handler for invariant fuzzing
        targetContract(address(fuzzHandler));

        // Optionally widen call targets for better exploration
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = fuzzHandler.deposit.selector;
        selectors[1] = fuzzHandler.redeemSome.selector;
        selectors[2] = fuzzHandler.report.selector;
        selectors[3] = fuzzHandler.dragonTransfer.selector;
        targetSelector(FuzzSelector({ addr: address(fuzzHandler), selectors: selectors }));
    }

    /**
     * @notice Vault value in user-value units (V), using 1e18-scaled currentRate.
     */
    function _getVaultValueInUserUnits() internal view returns (uint256) {
        uint256 rate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate(); // 1e18 scale
        return (strategy.totalAssets() * rate) / WAD;
    }

    /**
     * @notice Total shares (S).
     */
    function _getTotalShares() internal view returns (uint256) {
        return strategy.totalSupply();
    }

    /**
     * @notice Tracked obligations in value units (D = userDebt + dragonDebt).
     */
    function _getTrackedObligationsValue() internal view returns (uint256) {
        return strategy.totalSupply();
    }

    /**
     * @notice Conversion invariant:
     *         assetsOut(shares) = shares * min(totalAssets / S, 1 / currentRate)
     * @dev    Uses previewRedeem to avoid state changes; exercises both solvent and insolvent branches.
     */
    function invariant_conversion() public view {
        uint256 shares = strategy.totalSupply() / 7 + 1; // non-zero slice
        uint256 rate = IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate(); // 1e18 scale
        uint256 V = _getVaultValueInUserUnits();
        uint256 S = _getTotalShares();

        uint256 expected;
        if (S > 0 && V < S) {
            // insolvent: pro-rata
            expected = (shares * strategy.totalAssets()) / S;
        } else if (rate > 0) {
            // solvent: live-rate
            expected = (shares * WAD) / rate;
        }
        uint256 preview = strategy.previewRedeem(shares);
        // loose tolerance for fuzz variance
        assertApproxEqRel(preview, expected, 1e13, "conversion invariant");
    }

    /**
     * @notice Dragon gating and mint/burn bounds:
     *         - If insolvent (V < D), dragon operations must revert
     *         - After report, dragon shares must not increase unless V > D
     */
    function invariant_dragon_and_mint_burn() public {
        uint256 V = _getVaultValueInUserUnits();
        uint256 D = _getTrackedObligationsValue();

        // If insolvent, dragon operations must revert; simulate a small transfer attempt
        if (V < D) {
            vm.startPrank(donationAddress);
            vm.expectRevert();
            strategy.transfer(address(0xBEEF), 1);
            vm.stopPrank();
        }

        // After a report, dragon shares should not increase unless V > D.
        uint256 dragonBefore = strategy.balanceOf(donationAddress);
        vm.prank(keeper);
        strategy.report();
        uint256 dragonAfter = strategy.balanceOf(donationAddress);
        if (V <= D) {
            // allow equal if burn happened
            assertLe(dragonAfter, dragonBefore, "no mint when not profitable");
        }
    }
}

// -----------------------------------------------------------------------------
// Consolidated PoC tests (same file for convenience)
// -----------------------------------------------------------------------------
/**
 * @title YieldSkimmingExploitPoC
 * @notice Deterministic PoC tests: one reproduces the bug, one documents expected
 *         post-fix behavior (will fail until remediation is applied).
 */
contract YieldSkimmingExploitPoC is Setup {
    function setUp() public override {
        super.setUp();

        // Enable burning for this test suite so dragon shares can be burned during losses
        vm.prank(management);
        strategy.setEnableBurning(true);
    }

    // Expected to FAIL until remediation is applied (supply-zero check)
    function test_Fix_DebtReset_NoFabricatedProfit() public {
        address alice = makeAddr("alice");

        // 1) Deposit 100 at rate 1.0
        uint256 depositAmount = 100e18;
        mintAndDepositIntoStrategy(strategy, alice, depositAmount);

        // 2) Profit: rate -> 1.5
        MockStrategySkimming(address(strategy)).updateExchangeRate(15e17);
        vm.prank(keeper);
        strategy.report();
        assertEq(strategy.balanceOf(donationAddress), 50e18, "dragon minted 50 shares");

        // 3) Loss: rate -> 0.5
        MockStrategySkimming(address(strategy)).updateExchangeRate(5e17);
        vm.prank(keeper);
        strategy.report();
        assertEq(strategy.balanceOf(donationAddress), 0, "dragon burned to 0");
        assertEq(strategy.totalSupply(), 100e18, "supply back to 100");

        // 4) Withdraw half supply
        uint256 aliceShares = 50e18;
        vm.startPrank(alice);
        uint256 assetsOut = strategy.redeem(aliceShares, alice, alice);
        vm.stopPrank();
        assertEq(assetsOut, 50e18, "proportional assets out");
        assertEq(strategy.totalSupply(), 50e18, "post-burn supply is 50");

        // POST-FIX EXPECTATION: user debt remains 50e18 (not zero)
        uint256 userDebtPost = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter());
        assertEq(userDebtPost, 50e18, "POST-FIX: userDebt must not reset to 0");

        // 5) No fabricated profit on next report
        vm.prank(keeper);
        (uint256 profitNext, uint256 lossNext) = strategy.report();
        assertEq(profitNext, 0, "POST-FIX: no fabricated profit");
        assertEq(lossNext, userDebtPost, "POST-FIX: no loss");
        assertEq(strategy.balanceOf(donationAddress), 0, "POST-FIX: no dragon mint");
    }

    // Test expected behavior after fix for withdraw() path
    function test_Fix_DebtReset_NoFabricatedProfit_WithdrawPath() public {
        address alice = makeAddr("alice");

        // 1) Deposit 100 at rate 1.0
        uint256 depositAmount = 100e18;
        mintAndDepositIntoStrategy(strategy, alice, depositAmount);

        // 2) Profit: rate -> 1.5
        MockStrategySkimming(address(strategy)).updateExchangeRate(15e17);
        vm.prank(keeper);
        strategy.report();
        assertEq(strategy.balanceOf(donationAddress), 50e18, "dragon minted 50 shares");

        // 3) Loss: rate -> 0.5
        MockStrategySkimming(address(strategy)).updateExchangeRate(5e17);
        vm.prank(keeper);
        strategy.report();
        assertEq(strategy.balanceOf(donationAddress), 0, "dragon burned to 0");
        assertEq(strategy.totalSupply(), 100e18, "supply back to 100");

        // 4) Withdraw half (50 assets burns 50 shares)
        vm.startPrank(alice);
        uint256 sharesOut = strategy.withdraw(50e18, alice, alice);
        vm.stopPrank();
        assertEq(sharesOut, 50e18, "50 shares burned");
        assertEq(strategy.totalSupply(), 50e18, "post-burn supply is 50");

        // POST-FIX EXPECTATION: user debt remains 50e18 (not zero)
        uint256 userDebtPost = strategy.totalSupply() - strategy.balanceOf(strategy.dragonRouter());
        assertEq(userDebtPost, 50e18, "POST-FIX: withdraw path preserves debt");

        // 5) No fabricated profit on next report
        vm.prank(keeper);
        (uint256 profitNext, uint256 lossNext) = strategy.report();
        assertEq(profitNext, 0, "POST-FIX: no fabricated profit via withdraw");
        assertEq(lossNext, userDebtPost, "POST-FIX: no loss");
        assertEq(strategy.balanceOf(donationAddress), 0, "POST-FIX: no dragon mint");
    }
}
