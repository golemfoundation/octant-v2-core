// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.25;

import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import {
    IPool,
    IPoolAddressesProvider,
    IPoolDataProvider,
    IPoolDataProviderSlim
} from "src/strategies/interfaces/IAaveV3.sol";

interface IRewardsController {
    /// @notice Claims all accrued rewards across the supplied assets to `to`.
    /// @dev On Aave V3 mainnet (`0x8164cc65827dcFe994AB23944CBC90e0aa80bFcb`) this is
    ///      callable from any contract -- there is no permission gate. When no rewards
    ///      are configured for the supplied assets the call is effectively a no-op.
    function claimAllRewards(
        address[] calldata assets,
        address to
    ) external returns (address[] memory rewardsList, uint256[] memory claimedAmounts);
}

/**
 * @title AaveV3Strategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Yield-donating strategy that earns yield from Aave V3
 * @dev Deposits assets into Aave V3 lending pool to earn interest
 *
 *      WARNING: THIS CONTRACT IS UNAUDITED AND NOT INTENDED FOR PRODUCTION USE.
 *      USE AT YOUR OWN RISK.
 *
 *      YIELD FLOW:
 *      1. Deposits assets into Aave V3 pool
 *      2. Receives aTokens that automatically accrue interest
 *      3. On report, profit is minted as shares to donation address
 *
 *      DEPOSIT/WITHDRAW LIMITS:
 *      - Aave V3 has supply caps per asset that limit total deposits
 *      - Strategy checks available capacity before deposits
 *      - Withdrawals limited by available liquidity in the pool
 *
 * @custom:security Aave pool must be trusted and not manipulatable
 */
contract AaveV3Strategy is BaseHealthCheck {
    using SafeERC20 for IERC20;

    /// @notice Address of the Aave V3 addresses provider
    IPoolAddressesProvider public immutable addressesProvider;

    /// @notice Address of the Aave V3 pool
    IPool public immutable pool;

    /// @notice Address of the aToken for the underlying asset
    address public immutable aToken;

    /// @notice Address of Aave V3's RewardsController for liquidity-mining incentives.
    /// @dev Wired at construction so the strategy can claim supply-side emissions if/when
    ///      Aave governance enables them on a market we use. May be `address(0)` for
    ///      chains/markets where no RewardsController exists; in that case
    ///      `claimAaveRewards` reverts with a clear message instead of silently no-op'ing
    ///      on a zero target.
    IRewardsController public immutable rewardsController;

    /// @notice Emitted on a successful `claimAaveRewards` call.
    event AaveRewardsClaimed(address indexed to, address[] rewardsList, uint256[] amounts);

    /// @notice Emitted on a successful `sweepAirdrop` call.
    event TokenSwept(address indexed token, uint256 amount, address indexed recipient);

    /**
     * @notice Initializes the Aave V3 strategy
     * @dev Sets up connections to Aave V3 pool, derives aToken from pool registry, and wires the
     *      optional RewardsController for incentive claims.
     * @param _addressesProvider Address of Aave V3 addresses provider
     * @param _rewardsController Address of Aave V3 RewardsController (may be `address(0)` to disable)
     * @param _asset Address of the underlying asset (must be supported by Aave pool)
     * @param _name Strategy display name (e.g., "Octant Aave V3 USDC Strategy")
     * @param _symbol Strategy share token symbol (e.g., "osAAVE")
     * @param _management Address with management permissions
     * @param _keeper Address authorized to call report() and tend()
     * @param _emergencyAdmin Address authorized for emergency shutdown
     * @param _donationAddress Address receiving minted profit shares
     * @param _enableBurning True to enable loss protection via share burning
     * @param _tokenizedStrategyAddress Address of TokenizedStrategy implementation contract
     */
    constructor(
        address _addressesProvider,
        address _rewardsController,
        address _asset,
        string memory _name,
        string memory _symbol,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    )
        BaseHealthCheck(
            _asset,
            _name,
            _symbol,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        )
    {
        require(_addressesProvider != address(0), "Zero addressesProvider");

        addressesProvider = IPoolAddressesProvider(_addressesProvider);
        pool = IPool(addressesProvider.getPool());
        // _rewardsController may be address(0) — see `claimAaveRewards` for the explicit guard.
        rewardsController = IRewardsController(_rewardsController);

        // Do NOT cache the data provider as immutable. Aave's `addressesProvider`
        // rotates the `PoolDataProvider` over time (the Pool itself is a transparent
        // proxy and is stable, but the data provider is a fresh deployment per Aave
        // AIP). A cached pointer would keep reading stale supply caps, totals, and
        // pause flags forever. Read it inline for the constructor-only aToken
        // derivation; runtime calls go through the public `dataProvider()` view.
        IPoolDataProvider initialDataProvider = IPoolDataProvider(addressesProvider.getPoolDataProvider());
        (address _aToken, , ) = initialDataProvider.getReserveTokensAddresses(_asset);
        require(_aToken != address(0), "Asset not supported by pool");
        aToken = _aToken;
    }

    /**
     * @notice Claims all accrued Aave V3 supply-side rewards on this strategy's aToken
     *         position and forwards them directly to the dragon router.
     * @dev The hook is keeper-callable so it can be folded into the same cron that calls
     *      `report()`. When no emissions are configured for the aToken the call is a no-op
     *      (returns empty arrays). Off-chain Merit/Merkl claims are out of scope -- those
     *      rely on Merkle proofs against an external curator and must be handled by the
     *      Octant multisig, not the strategy.
     *
     *      Reverts on `address(0)` rewardsController so a misconfigured deployment is
     *      surfaced loudly instead of silently swallowing claim attempts.
     *
     *      The dragon router used as `to` MUST be capable of accepting arbitrary
     *      ERC-20s. EOA / splitter routers are fine; an immutable single-asset router
     *      would lose any non-asset reward token.
     * @return rewardsList Reward token addresses claimed (may be empty)
     * @return amounts     Reward amounts transferred to the dragon router
     */
    function claimAaveRewards() external onlyKeepers returns (address[] memory rewardsList, uint256[] memory amounts) {
        require(address(rewardsController) != address(0), "AaveV3Strategy: RewardsController not configured");
        address[] memory assets = new address[](1);
        assets[0] = aToken;
        address dragon = TokenizedStrategy.dragonRouter();
        (rewardsList, amounts) = rewardsController.claimAllRewards(assets, dragon);
        emit AaveRewardsClaimed(dragon, rewardsList, amounts);
    }

    /**
     * @notice Sweeps non-critical ERC-20 balances on this strategy address to the dragon
     *         router. Mirrors `SparkStrategy.sweepAirdrop` so the operational interface
     *         is consistent across strategies.
     * @dev Used to forward airdrops, off-chain reward distributions (Merkl/Merit settled
     *      by an off-chain curator), and any stray ERC-20 that lands on the strategy
     *      address. Excludes the strategy asset and the aToken to protect the deployed
     *      position.
     * @param _token Address of the token to sweep (must NOT be `asset` or `aToken`)
     */
    function sweepAirdrop(address _token) external onlyKeepers {
        require(_token != address(asset), "AaveV3Strategy: Cannot sweep main asset");
        require(_token != aToken, "AaveV3Strategy: Cannot sweep aToken");
        uint256 balance = IERC20(_token).balanceOf(address(this));
        require(balance > 0, "AaveV3Strategy: No balance to sweep");
        address dragon = TokenizedStrategy.dragonRouter();
        IERC20(_token).safeTransfer(dragon, balance);
        emit TokenSwept(_token, balance, dragon);
    }

    /**
     * @notice Returns the current Aave V3 pool data provider.
     * @dev Resolved from `addressesProvider` on every call so the strategy picks up
     *      governance-driven `PoolDataProvider` rotations without redeployment. The
     *      few hundred extra gas per limit query is the cost of not silently reading
     *      stale supply caps / pause flags.
     * @return Current `IPoolDataProvider` instance reported by the addresses provider.
     */
    function dataProvider() public view returns (IPoolDataProvider) {
        return IPoolDataProvider(addressesProvider.getPoolDataProvider());
    }

    /**
     * @notice Returns maximum additional assets that can be deposited
     * @dev Checks Aave V3 supply cap and subtracts current supply.
     *
     *      DUST CAVEAT: Aave mints aTokens proportional to `amount / liquidityIndex`.
     *      For sub-unit deposits on a high-index reserve, the scaled mint amount can round
     *      to zero and `pool.supply` reverts with `INVALID_MINT_AMOUNT`. This view does
     *      NOT pre-filter such dust; integrators relying on `maxDeposit` should be prepared
     *      for Aave reverts on amounts below the per-reserve scaled-unit floor.
     *      A pre-flight check is intentionally omitted to keep the hot path cheap for
     *      the typical case where deposits are far above the dust threshold.
     * @return limit Maximum additional deposit amount in asset base units
     */
    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        // Aave-side blockers make `pool.supply` revert when the reserve is paused,
        // inactive, or frozen; surfacing capacity through `maxDeposit` would only
        // route users into failing transactions.
        if (dataProvider().getPaused(address(asset))) return 0;
        (, , , , , , , , bool isActive, bool isFrozen) = dataProvider().getReserveConfigurationData(address(asset));
        if (!isActive || isFrozen) return 0;

        (, uint256 supplyCap) = dataProvider().getReserveCaps(address(asset));

        // If supply cap is 0, it means unlimited (see https://github.com/aave/aave-v3-core/blob/782f51917056a53a2c228701058a6c3fb233684a/contracts/protocol/libraries/types/DataTypes.sol#L53)
        if (supplyCap == 0) {
            return type(uint256).max;
        }

        // Aave's `validateSupply` enforces
        //   (scaledTotalSupply + accruedToTreasury).rayMul(nextLiquidityIndex) + amount
        //     <= supplyCap * 10^decimals
        // `getATokenTotalSupply` omits the `accruedToTreasury` contribution, so a
        // headroom check that uses `totalAToken` alone over-reports cap room and
        // lets users hit a downstream `SUPPLY_CAP_EXCEEDED` revert. The helper
        // rayMul-scales treasury into underlying units and keeps its locals out
        // of this function's stack frame (needed for the `--no-via-ir` coverage
        // build profile, which otherwise hits a stack-too-deep on the 12-return
        // decoder combined with the surrounding locals).
        uint256 totalSupply = _cappedTotalSupply();

        // Cap is in whole tokens, need to adjust for decimals (see https://github.com/aave/aave-v3-core/blob/782f51917056a53a2c228701058a6c3fb233684a/contracts/protocol/libraries/types/DataTypes.sol#L53)
        uint256 supplyCapScaled = supplyCap * 10 ** IERC20Metadata(address(asset)).decimals();

        if (supplyCapScaled > totalSupply) {
            uint256 availableCapacity = supplyCapScaled - totalSupply;
            uint256 idleBalance = IERC20(address(asset)).balanceOf(address(this));

            // Safely subtract idle balance to avoid underflow
            if (availableCapacity <= idleBalance) {
                return 0;
            } else {
                return availableCapacity - idleBalance;
            }
        } else {
            return 0;
        }
    }

    /// @dev Returns the cap-denominator view of total supplied assets, rayMul-scaled
    ///      into underlying units to match Aave's `validateSupply`:
    ///      `totalAToken + rayMul(accruedToTreasuryScaled, nextLiquidityIndex)`,
    ///      ceiling-rounded so headroom stays conservative.
    ///
    ///      `liquidityIndex` is read via `IPool.getReserveNormalizedIncome` — this is
    ///      the projected `nextLiquidityIndex` Aave uses, avoiding the few-seconds-of-
    ///      accrual gap vs the stored `liquidityIndex` on the data provider.
    ///
    ///      Uses `IPoolDataProviderSlim` (3-return view of `getReserveData`) instead
    ///      of the full 12-return interface: the narrower ABI decoder keeps the call
    ///      site within the EVM stack budget under the `--no-via-ir` + `--no-optimizer`
    ///      `forge coverage` build. Identical on-chain behavior — Solidity decodes the
    ///      first three 32-byte slots of the return data and stops.
    function _cappedTotalSupply() internal view returns (uint256) {
        (, uint256 accruedToTreasuryScaled, uint256 totalAToken) = IPoolDataProviderSlim(address(dataProvider()))
            .getReserveData(address(asset));
        return
            totalAToken +
            Math.mulDiv(
                accruedToTreasuryScaled,
                pool.getReserveNormalizedIncome(address(asset)),
                1e27,
                Math.Rounding.Ceil
            );
    }

    /**
     * @notice Returns maximum assets withdrawable without expected loss
     * @dev Checks pool liquidity to ensure withdrawals won't fail due to high utilization.
     *
     *      DUST CAVEAT: mirrors `availableDepositLimit`. Aave burns aTokens proportional
     *      to `amount / liquidityIndex`; sub-unit withdrawals can round to a zero scaled
     *      burn amount and revert with `INVALID_BURN_AMOUNT`. This view does NOT pre-filter
     *      dust amounts; callers must handle Aave reverts on amounts below the per-reserve
     *      scaled-unit floor.
     * @return limit Maximum withdrawal amount in asset base units
     */
    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        // Idle balance is always withdrawable -- it lives on this contract, no Aave
        // pool interaction is required to move it out. This matters on a paused or
        // inactive reserve (short-circuit below) AND after `emergencyWithdraw`
        // pulls everything out of Aave into idle.
        uint256 idleBalance = IERC20(address(asset)).balanceOf(address(this));

        // `pool.withdraw` reverts when the reserve is paused or inactive.
        // (Withdrawals are NOT blocked by `isFrozen` -- a frozen reserve still allows
        // exits.) Cap `maxWithdraw`/`maxRedeem` at idle-only so users can still exit
        // any balance already out of the pool even while the Aave side is blocked.
        if (dataProvider().getPaused(address(asset))) return idleBalance;
        (, , , , , , , , bool isActive, ) = dataProvider().getReserveConfigurationData(address(asset));
        if (!isActive) return idleBalance;

        // Get our aToken balance which represents our deposited assets
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));

        // Check pool liquidity - the underlying asset balance held by the aToken contract
        uint256 poolLiquidity = IERC20(address(asset)).balanceOf(aToken);

        // We can only withdraw up to the pool's available liquidity
        uint256 withdrawableFromPool = aTokenBalance < poolLiquidity ? aTokenBalance : poolLiquidity;

        return withdrawableFromPool + idleBalance;
    }

    /**
     * @dev Deposits idle assets into Aave V3 pool.
     *
     *      We used to grant `type(uint256).max` allowance to the pool in the constructor.
     *      The Aave pool is an upgradeable proxy controlled by external governance, so a
     *      standing max-approval would let a hostile upgrade drain the strategy's idle
     *      balance at any time. We now approve exactly `_amount` for the call and clear
     *      the allowance afterward, even if a broken counterparty returns after pulling
     *      less than `_amount`. `forceApprove` handles non-standard tokens that require
     *      clearing an existing non-zero allowance first.
     * @param _amount Amount of assets to deploy in asset base units
     */
    function _deployFunds(uint256 _amount) internal override {
        IERC20(address(asset)).forceApprove(address(pool), _amount);
        pool.supply(address(asset), _amount, address(this), 0);
        IERC20(address(asset)).forceApprove(address(pool), 0);
    }

    /**
     * @dev Withdraws assets from Aave V3 pool
     * @param _amount Amount of assets to withdraw in asset base units
     */
    function _freeFunds(uint256 _amount) internal override {
        pool.withdraw(address(asset), _amount, address(this));
    }

    /**
     * @dev Emergency withdrawal after strategy shutdown.
     *
     *      AAVE DEPENDENCY: this path delegates to `_freeFunds`, which calls
     *      `pool.withdraw(asset, amount, this)` with no fallback. Emergency
     *      withdrawal therefore depends on Aave pool state -- if Aave has
     *      paused the reserve, marked it inactive, or utilization is too high
     *      for the requested amount, the call reverts and no funds are pulled.
     *
     *      OPERATIONAL RUNBOOK when Aave blocks an emergency exit:
     *      1. Call `shutdownStrategy()` first -- this marks the strategy
     *         shutdown for new deposits independently of Aave state.
     *      2. Call `emergencyWithdraw(amount)` with `amount` capped at the
     *         Aave-backed portion of `availableWithdrawLimit(address(0))`.
     *         The view already accounts for pool liquidity; on a paused or
     *         inactive reserve it surfaces only idle assets, which are already
     *         outside Aave and remain withdrawable through regular user exits.
     *      3. Repeat step 2 as Aave liquidity returns or pauses lift. A
     *         strategy stuck on a paused reserve recovers automatically once
     *         Aave governance resumes the pool; no contract-level rescue is
     *         possible without trusting the Aave counterparty.
     * @param _amount Amount of assets to withdraw in asset base units
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        _freeFunds(_amount);
    }

    /**
     * @dev Reports current total assets under management
     * @return _totalAssets Sum of aToken balance and idle assets in asset base units
     */
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        // aTokens have 1:1 value with underlying asset
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));

        // Include idle funds as per BaseStrategy specification
        uint256 idleAssets = IERC20(address(asset)).balanceOf(address(this));

        _totalAssets = aTokenBalance + idleAssets;

        return _totalAssets;
    }
}
