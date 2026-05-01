// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.18;

import { Test } from "forge-std/Test.sol";
import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Setup, IMockStrategy } from "test/unit/strategies/yieldSkimming/utils/Setup.sol";
import { IYieldSkimmingStrategy } from "src/strategies/yieldSkimming/IYieldSkimmingStrategy.sol";
import { MockStrategySkimming } from "test/mocks/core/tokenized-strategies/MockStrategySkimming.sol";
import { MockYieldSourceSkimming } from "test/mocks/core/tokenized-strategies/MockYieldSourceSkimming.sol";
import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

/**
 * @title PlamenHandler
 * @notice Handler contract for invariant fuzzing of YieldSkimmingTokenizedStrategy.
 * @dev Exercises deposit, redeem, report, and dragon operations.
 *      Specifically targets:
 *      - CS-1/EC-3: dragonRouterDebtInAssetValue underflow during report()
 *      - CS-3/TF-1: token donations inflate dragon profit
 *      - CS-6: finalizeDragonRouterChange phantom debt
 *      - RS2-1: 3-arg withdraw debt tracking
 *      - totalSupply == userDebt + dragonDebt invariant
 */
contract PlamenHandler is Test {
    IMockStrategy public immutable strategy;
    ERC20Mock public immutable asset;
    MockYieldSourceSkimming public immutable yieldSource;

    address public immutable keeper;
    address public immutable management;
    address public immutable dragon;

    address[] public actors;

    // Ghost variables for tracking expected state
    uint256 public ghost_totalDeposited;
    uint256 public ghost_totalRedeemed;

    constructor(
        IMockStrategy _strategy,
        ERC20Mock _asset,
        MockYieldSourceSkimming _yieldSource,
        address _keeper,
        address _management,
        address _dragon,
        address[] memory _actors
    ) {
        strategy = _strategy;
        asset = _asset;
        yieldSource = _yieldSource;
        keeper = _keeper;
        management = _management;
        dragon = _dragon;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        if (actors.length == 0) return address(0x1234);
        return actors[seed % actors.length];
    }

    // ── Deposit path ──────────────────────────────────────────────────────────

    function deposit(uint256 assets, uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        assets = bound(assets, 1, 1e24);

        yieldSource.mint(actor, assets);
        vm.prank(actor);
        yieldSource.approve(address(strategy), assets);
        vm.prank(actor);
        (bool ok, ) = address(strategy).call(abi.encodeWithSignature("deposit(uint256,address)", assets, actor));
        if (ok) ghost_totalDeposited += assets;
    }

    // ── Redeem path (2-arg via strategy override) ─────────────────────────────

    function redeemSome(uint256 shareFrac, uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 bal = strategy.balanceOf(actor);
        if (bal == 0) return;
        uint256 shares = bound(shareFrac, 1, bal);

        vm.prank(actor);
        (bool ok, ) = address(strategy).call(
            abi.encodeWithSignature("redeem(uint256,address,address)", shares, actor, actor)
        );
        ok;
    }

    // ── 3-arg withdraw (RS2-1 target) ─────────────────────────────────────────

    function withdraw3Arg(uint256 assetAmt, uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        uint256 maxW = strategy.maxWithdraw(actor);
        if (maxW == 0) return;
        uint256 assets = bound(assetAmt, 1, maxW);

        // 3-arg withdraw bypasses YieldSkimming override → tests debt tracking gap
        vm.prank(actor);
        (bool ok, ) = address(strategy).call(
            abi.encodeWithSignature("withdraw(uint256,address,address)", assets, actor, actor)
        );
        ok;
    }

    // ── Report (normal) ───────────────────────────────────────────────────────

    function report() external {
        vm.prank(keeper);
        (bool ok, ) = address(strategy).call(abi.encodeWithSignature("report()"));
        ok;
    }

    // ── Simulate profit via rate increase ─────────────────────────────────────

    function increaseRate(uint256 bps) external {
        bps = bound(bps, 1, 500); // 0.01% – 5%
        uint256 currentRate = MockStrategySkimming(address(strategy)).getCurrentExchangeRate();
        uint256 newRate = currentRate + (currentRate * bps) / 10_000;
        MockStrategySkimming(address(strategy)).updateExchangeRate(newRate);
    }

    // ── Simulate loss via rate decrease ───────────────────────────────────────

    function decreaseRate(uint256 bps) external {
        bps = bound(bps, 1, 200); // 0.01% – 2%
        uint256 currentRate = MockStrategySkimming(address(strategy)).getCurrentExchangeRate();
        uint256 decrease = (currentRate * bps) / 10_000;
        if (decrease >= currentRate) return;
        MockStrategySkimming(address(strategy)).updateExchangeRate(currentRate - decrease);
    }

    // ── Token donation (CS-3/TF-1 target) ────────────────────────────────────

    function donateTokens(uint256 amount, uint256 /* actorSeed */) external {
        amount = bound(amount, 1, 1e20);
        // Mint yieldSource tokens (the underlying asset) directly to the strategy
        // This triggers the balanceOf(this) != totalAssets divergence in report()
        yieldSource.mint(address(strategy), amount);
    }

    // ── Enable burning and trigger loss (CS-1/EC-3 target) ───────────────────

    function enableBurningAndLoss(uint256 lossBps) external {
        lossBps = bound(lossBps, 1, 300); // up to 3%
        // Enable burning
        vm.prank(management);
        (bool ok1, ) = address(strategy).call(abi.encodeWithSignature("setEnableBurning(bool)", true));
        if (!ok1) return;

        // Simulate a rate decrease (loss)
        uint256 currentRate = MockStrategySkimming(address(strategy)).getCurrentExchangeRate();
        uint256 decrease = (currentRate * lossBps) / 10_000;
        if (decrease == 0 || decrease >= currentRate) return;
        MockStrategySkimming(address(strategy)).updateExchangeRate(currentRate - decrease);

        // Report the loss
        vm.prank(keeper);
        (bool ok2, ) = address(strategy).call(abi.encodeWithSignature("report()"));
        ok2;
    }

    // ── Dragon transfer ───────────────────────────────────────────────────────

    function dragonTransfer(uint256 amount, uint256 actorSeed) external {
        amount = bound(amount, 1, 1e18);
        address to = _actor(actorSeed);
        vm.prank(dragon);
        (bool ok, ) = address(strategy).call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        ok;
    }
}

// ─────────────────────────────────────────────────────────────────────────────

/**
 * @title PlamenInvariantTest
 * @notice Foundry invariant suite for YieldSkimmingTokenizedStrategy.
 *
 * Invariants tested:
 *  1. totalSupply == userDebt + dragonDebt (SYNC_GAP-4 check)
 *  2. dragonRouterDebtInAssetValue never underflows (CS-1/EC-3)
 *  3. report() never reverts due to arithmetic underflow (CS-1 DoS)
 *  4. After deposit, userDebt increases by at least shares minted (deposit accounting)
 *  5. If vault is solvent, totalAssets * rate >= totalDebtOwedToUser (solvency)
 *  6. Dragon cannot hold shares when vault is insolvent (dragon gating)
 *  7. totalSupply is always >= 0 (no negative supply)
 *  8. pendingDragonRouter == 0 iff dragonRouterChangeTimestamp == 0 (cluster invariant)
 */
contract PlamenInvariantTest is StdInvariant, Setup {
    PlamenHandler internal handler;

    uint256 internal constant WAD = 1e18;

    function setUp() public override {
        super.setUp();

        // Enable burning on this strategy for full coverage
        vm.prank(management);
        strategy.setEnableBurning(true);

        address[] memory actors = new address[](4);
        actors[0] = makeAddr("alice");
        actors[1] = makeAddr("bob");
        actors[2] = makeAddr("carol");
        actors[3] = makeAddr("dave");

        handler = new PlamenHandler(strategy, asset, yieldSource, keeper, management, donationAddress, actors);

        // Target handler for fuzzing
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.redeemSome.selector;
        selectors[2] = handler.withdraw3Arg.selector;
        selectors[3] = handler.report.selector;
        selectors[4] = handler.increaseRate.selector;
        selectors[5] = handler.decreaseRate.selector;
        selectors[6] = handler.donateTokens.selector;
        selectors[7] = handler.enableBurningAndLoss.selector;
        selectors[8] = handler.dragonTransfer.selector;
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    // ── Helper views ──────────────────────────────────────────────────────────

    function _getUserDebt() internal view returns (uint256) {
        return IYieldSkimmingStrategy(address(strategy)).gettotalDebtOwedToUserInAssetValue();
    }

    function _getDragonDebt() internal view returns (uint256) {
        return IYieldSkimmingStrategy(address(strategy)).getDragonRouterDebtInAssetValue();
    }

    function _getRate() internal view returns (uint256) {
        return IYieldSkimmingStrategy(address(strategy)).getCurrentExchangeRate();
    }

    function _getVaultValue() internal view returns (uint256) {
        // value = totalAssets * rate / 1e18  (rate is 1e18-scaled in MockStrategySkimming)
        return (strategy.totalAssets() * _getRate()) / WAD;
    }

    // ── Invariant 1: totalSupply == userDebt + dragonDebt ────────────────────
    //
    // From semantic_invariants.md SYNC_GAP-4: the designed invariant is
    // totalSupply == totalDebtOwedToUserInAssetValue + dragonRouterDebtInAssetValue
    // (1 share = 1 value unit).  The fuzz suite checks whether this can be broken.

    function invariant_totalSupplyEqualsDebt() public view {
        uint256 supply = strategy.totalSupply();
        uint256 userDebt = _getUserDebt();
        uint256 dragonDebt = _getDragonDebt();

        // Allow 1 wei rounding tolerance
        uint256 totalDebt = userDebt + dragonDebt;

        // If supply == 0 both debts should also be 0 (or negligibly small due to rounding)
        if (supply == 0) {
            assertLe(totalDebt, 1, "debt must be ~0 when supply is 0");
            return;
        }

        // totalSupply should equal combined debt within 1 wei
        assertApproxEqAbs(supply, totalDebt, 1, "totalSupply != userDebt + dragonDebt (SYNC_GAP-4 violated)");
    }

    // ── Invariant 2: dragonDebt never underflows (stays <= totalSupply) ───────
    //
    // CS-1: dragonBurn in _handleDragonLossProtection can exceed dragonRouterDebtInAssetValue,
    // causing an unchecked subtraction underflow in Solidity ≥0.8 → revert DoS.

    function invariant_dragonDebtDoesNotExceedTotalSupply() public view {
        uint256 dragonDebt = _getDragonDebt();
        uint256 supply = strategy.totalSupply();
        assertLe(dragonDebt, supply + 1, "dragonDebt > totalSupply (potential underflow)");
    }

    // ── Invariant 3: dragonDebt <= dragon balance (debt tracks shares 1:1) ───

    function invariant_dragonDebtMatchesDragonBalance() public view {
        uint256 dragonDebt = _getDragonDebt();
        uint256 dragonBal = strategy.balanceOf(donationAddress);
        // dragon debt should match dragon share balance (within 1 wei rounding)
        assertApproxEqAbs(dragonDebt, dragonBal, 1, "dragonRouterDebtInAssetValue diverges from dragon share balance");
    }

    // ── Invariant 4: userDebt <= (totalSupply - dragonBalance) ───────────────
    //
    // User debt should account for all non-dragon shares.

    function invariant_userDebtMatchesNonDragonShares() public view {
        uint256 userDebt = _getUserDebt();
        uint256 supply = strategy.totalSupply();
        uint256 dragonBal = strategy.balanceOf(donationAddress);
        uint256 nonDragonSupply = supply > dragonBal ? supply - dragonBal : 0;
        // userDebt should track non-dragon shares within 1 wei
        assertApproxEqAbs(userDebt, nonDragonSupply, 1, "userDebt diverges from non-dragon supply");
    }

    // ── Invariant 5: report() does not revert due to underflow (CS-1 DoS) ────
    //
    // We call report() in the invariant to verify it doesn't revert.
    // If it reverts, the invariant fails — surfacing CS-1 underflow DoS.

    function invariant_reportDoesNotRevert() public {
        // Only call if there are shares (avoid no-op)
        if (strategy.totalSupply() == 0) return;

        vm.prank(keeper);
        (bool ok, bytes memory returnData) = address(strategy).call(abi.encodeWithSignature("report()"));
        if (!ok) {
            // Decode revert reason if possible
            string memory reason = "report() reverted";
            if (returnData.length > 4) {
                bytes memory errData = new bytes(returnData.length - 4);
                for (uint256 i = 0; i < errData.length; i++) {
                    errData[i] = returnData[i + 4];
                }
                reason = string(abi.encodePacked("report() reverted: ", errData));
            }
            assertTrue(false, reason);
        }
    }

    // ── Invariant 6: isVaultInsolvent() flag is consistent with actual value math ──
    //
    // The contract's _isVaultInsolvent() defines the canonical solvency state.
    // If the contract reports solvent, vaultValue should be >= userDebt.
    // If the contract reports insolvent, vaultValue should be < userDebt.
    // This catches any divergence between the flag logic and the actual stored state.

    function invariant_solvencyFlagConsistent() public view {
        uint256 userDebt = _getUserDebt();
        if (userDebt == 0) return; // no users, trivially solvent

        uint256 vaultValue = _getVaultValue();
        bool contractSaysInsolvent = IYieldSkimmingStrategy(address(strategy)).isVaultInsolvent();

        if (!contractSaysInsolvent) {
            // Contract says solvent: vault value must cover user debt (allow 1 wei rounding)
            assertGe(vaultValue + 1, userDebt, "contract says solvent but vaultValue < userDebt");
        }
        // When insolvent: by design vaultValue < userDebt; no assertion needed (expected state)
    }

    // ── Invariant 7: dragon shares limited when insolvent ────────────────────
    //
    // If vault is insolvent (vaultValue < userDebt), dragon should be blocked from
    // increasing its balance.

    function invariant_dragonCannotMintWhenInsolvent() public view {
        uint256 userDebt = _getUserDebt();
        if (userDebt == 0) return;

        uint256 vaultValue = _getVaultValue();
        if (vaultValue >= userDebt) return; // solvent

        // Insolvent: dragon balance should not have increased beyond what it had
        // We can't check "increased" without ghost state; instead verify
        // that dragonDebt <= vaultValue (dragon cannot have more value than vault)
        uint256 dragonDebt = _getDragonDebt();
        assertLe(dragonDebt, vaultValue + 1, "dragonDebt > vaultValue during insolvency");
    }

    // ── Invariant 8: pendingDragonRouter and timestamp atomicity ─────────────
    //
    // From semantic_invariants.md Cluster 4:
    // (pendingDragonRouter == address(0)) == (dragonRouterChangeTimestamp == 0)

    function invariant_dragonRouterChangeAtomicity() public view {
        address pending = strategy.pendingDragonRouter();
        uint256 ts = strategy.dragonRouterChangeTimestamp();

        if (pending == address(0)) {
            assertEq(ts, 0, "timestamp set without pending dragon router");
        } else {
            assertGt(ts, 0, "timestamp 0 with pending dragon router");
        }
    }

    // ── Invariant 9: no negative totalSupply ─────────────────────────────────

    function invariant_totalSupplyNonNegative() public view {
        // uint256 cannot be negative; this checks it's consistent with shares
        uint256 supply = strategy.totalSupply();
        uint256 dragonBal = strategy.balanceOf(donationAddress);
        assertGe(supply, dragonBal, "totalSupply < dragon balance (impossible)");
    }
}
