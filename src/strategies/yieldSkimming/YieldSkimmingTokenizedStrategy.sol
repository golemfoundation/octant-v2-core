// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import { IBaseStrategy } from "src/core/interfaces/IBaseStrategy.sol";
import { TokenizedStrategy, Math } from "src/core/TokenizedStrategy.sol";
import { WadRayMath } from "src/utils/libs/Maths/WadRay.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IYieldSkimmingStrategy } from "src/strategies/yieldSkimming/IYieldSkimmingStrategy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title YieldSkimmingTokenizedStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Specialized TokenizedStrategy for yield-bearing assets with appreciating exchange rates.
 * @dev Mechanism:
 *      - Shares represent value-units of the underlying asset at the strategy exchange rate
 *        (1 share = 1 unit of underlying-asset value as returned by getCurrentExchangeRate)
 *        rather than raw asset amounts. Note: the underlying-asset value is NOT pegged to native ETH,
 *        even when the asset references stETH/wstETH/rETH — value follows the live exchange rate.
 *      - On report(), compares total vault value (assets * rate) vs total outstanding shares
 *        • Profit: mints dragon shares equal to excess value above total share debt
 *        • Loss: burns dragon shares (if enabled) up to available balance to cover shortfall
 *      - Insolvency determination: vault cannot cover user debt (excludes dragon shares as loss buffer)
 *      - Dual conversion modes:
 *        • Solvent: rate-based conversions using current exchange rate (RAY precision)
 *        • Insolvent: proportional distribution using base TokenizedStrategy logic
 *      - Dragon solvency protection: prevents dragon operations that would compromise user debt coverage
 *      - Dragon restrictions: cannot deposit/mint, cannot transfer to self, operations blocked during insolvency
 */
contract YieldSkimmingTokenizedStrategy is TokenizedStrategy {
    using Math for uint256;
    using WadRayMath for uint256;
    using SafeERC20 for ERC20;

    /// @dev Storage for yield skimming strategy
    struct YieldSkimmingStorage {
        uint256 totalDebtOwedToUserInAssetValue; // Track underlying-asset-value debt owed to users only
        uint256 lastReportedRate; // Track the last reported rate
        uint256 dragonRouterDebtInAssetValue; // Track the underlying-asset-value debt owed to dragon router
    }

    // ERC-7201 namespaced storage slot for yield-skimming state.
    // Formula: keccak256(abi.encode(uint256(keccak256(NAMESPACE)) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YIELD_SKIMMING_STORAGE_SLOT =
        keccak256(abi.encode(uint256(keccak256("octant.yieldSkimming.exchangeRate")) - 1)) & ~bytes32(uint256(0xff));

    /// @dev Event emitted when harvest is performed
    event Harvest(address indexed caller, uint256 currentRate);

    /// @dev Events for donation tracking
    /// @param dragonRouter Address receiving or burning donation shares
    /// @param amount Amount of value-shares minted or burned (1 share = 1 value unit)
    /// @param exchangeRate Current exchange rate (scaled to wad) at the time of the event
    event DonationMinted(address indexed dragonRouter, uint256 amount, uint256 exchangeRate);
    /// @dev Emitted when dragon shares are burned to cover value losses
    event DonationBurned(address indexed dragonRouter, uint256 amount, uint256 exchangeRate);

    /**
     * @notice Deposit assets into the strategy with value debt tracking
     * @dev Requirements:
     *      - Vault must be solvent (reverts otherwise)
     *      - Receiver cannot be dragon router (dragon shares minted via report())
     *      - Tracks asset value debt
     * @param assets Amount of assets to deposit in asset base units
     * @param receiver Address to receive the shares (cannot be dragon router)
     * @return shares Amount of shares minted (1 share = 1 unit of underlying-asset value at the current rate)
     */
    function deposit(uint256 assets, address receiver) public virtual override nonReentrant returns (uint256 shares) {
        // Block deposits during vault insolvency
        _requireVaultSolvency();

        StrategyData storage S = _strategyStorage();
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();
        uint256 currentRate = _currentRateRay();

        // dragon router cannot deposit
        require(receiver != S.dragonRouter, "Dragon cannot deposit");

        if (YS.lastReportedRate == 0) {
            YS.lastReportedRate = currentRate;
        }

        // Deposit full balance if using max uint.
        if (assets == type(uint256).max) {
            assets = S.asset.balanceOf(msg.sender);
        }

        // Checking max deposit will also check if shutdown.
        require(assets <= _maxDeposit(S, receiver), "ERC4626: deposit more than max");

        // Issue shares based on value (1 share = 1 unit of underlying-asset value, except in case of uncovered loss)
        shares = assets.mulDiv(currentRate, WadRayMath.RAY);
        require(shares != 0, "ZERO_SHARES");

        // Update value debt
        YS.totalDebtOwedToUserInAssetValue += shares;

        // Call internal deposit to handle transfers and minting
        _deposit(S, receiver, assets, shares);

        return shares;
    }

    /**
     * @notice Mint exact shares from the strategy with value debt tracking
     * @dev Implements insolvency protection and tracks underlying-asset-value debt
     * @param shares Amount of shares to mint
     * @param receiver Address to receive the shares
     * @return assets Amount of assets deposited in asset base units (1 share = 1 unit of underlying-asset value, except in case of uncovered loss)
     */
    function mint(uint256 shares, address receiver) public virtual override nonReentrant returns (uint256 assets) {
        // Block mints during vault insolvency
        _requireVaultSolvency();

        StrategyData storage S = _strategyStorage();
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();

        // dragon router cannot mint
        require(receiver != S.dragonRouter, "Dragon cannot mint");

        uint256 currentRate = _currentRateRay();
        if (YS.lastReportedRate == 0) {
            YS.lastReportedRate = currentRate;
        }

        // Checking max mint will also check if shutdown
        require(shares <= _maxMint(S, receiver), "ERC4626: mint more than max");

        // Calculate assets needed based on value (1 share = 1 unit of underlying-asset value, except in case of uncovered loss)
        assets = shares.mulDiv(WadRayMath.RAY, currentRate, Math.Rounding.Ceil);
        require(assets != 0, "ZERO_ASSETS");

        // Update value debt
        YS.totalDebtOwedToUserInAssetValue += shares;

        // Call internal deposit to handle transfers and minting
        _deposit(S, receiver, assets, shares);

        return assets;
    }

    /**
     * @notice Redeem shares from the strategy with value debt tracking
     * @dev Shares represent underlying-asset value (1 share = 1 unit of underlying-asset value at the current rate, except in case of uncovered loss)
     * @param shares Amount of shares to redeem
     * @param receiver Address to receive the assets
     * @param owner Address whose shares are being redeemed
     * @param maxLoss Maximum acceptable loss in basis points
     * @return assets Amount of assets returned in asset base units
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss
    ) public override nonReentrant returns (uint256 assets) {
        StrategyData storage S = _strategyStorage();
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();

        // Burn stale dragon shares before pricing user exits to prevent dilution
        // by unburned junior capital during insolvency
        if (owner != S.dragonRouter) {
            _applyDragonLossProtectionIfNeeded(S, YS);
        }

        // Calculate actual value returned for debt tracking (before redemption)
        uint256 valueToReturn = shares; // 1 share = 1 unit of underlying-asset value, except in case of uncovered loss (regardless of actual assets received)

        // Validate inputs and check limits (replaces super.redeem validation)
        require(shares <= _maxRedeem(S, owner), "ERC4626: redeem more than max");
        require((assets = _convertToAssets(S, shares, Math.Rounding.Floor)) != 0, "ZERO_ASSETS");

        // Check if dragon redemption would compromise vault solvency
        _requireDragonSolvencyAfterOperation(owner, shares);

        assets = _withdraw(S, receiver, owner, assets, shares, maxLoss);

        // Update value debt after successful redemption (only for users)
        if (owner != S.dragonRouter) {
            YS.totalDebtOwedToUserInAssetValue = YS.totalDebtOwedToUserInAssetValue > valueToReturn
                ? YS.totalDebtOwedToUserInAssetValue - valueToReturn
                : 0;
        } else {
            YS.dragonRouterDebtInAssetValue = YS.dragonRouterDebtInAssetValue > valueToReturn
                ? YS.dragonRouterDebtInAssetValue - valueToReturn
                : 0;
        }

        // if vault is empty, reset all debts to 0
        if (_totalSupply(S) == 0) {
            YS.totalDebtOwedToUserInAssetValue = 0;
            YS.dragonRouterDebtInAssetValue = 0;
        }

        return assets;
    }

    /**
     * @notice Withdraw assets from the strategy with value debt tracking
     * @dev Calculates shares needed for the asset amount requested
     * @param assets Amount of assets to withdraw in asset base units
     * @param receiver Address to receive the assets
     * @param owner Address whose shares are being redeemed
     * @param maxLoss Maximum acceptable loss in basis points
     * @return shares Amount of shares burned in share base units
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss
    ) public override nonReentrant returns (uint256 shares) {
        StrategyData storage S = _strategyStorage();
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();

        // Burn stale dragon shares before pricing user exits to prevent dilution
        // by unburned junior capital during insolvency
        if (owner != S.dragonRouter) {
            _applyDragonLossProtectionIfNeeded(S, YS);
        }

        // Validate inputs and check limits (replaces super.withdraw validation)
        require(assets <= _maxWithdraw(S, owner), "ERC4626: withdraw more than max");
        require((shares = _convertToShares(S, assets, Math.Rounding.Ceil)) != 0, "ZERO_SHARES");

        // Calculate actual value returned for debt tracking (before withdrawal)
        uint256 valueToReturn = shares; // 1 share = 1 unit of underlying-asset value

        // Check if dragon withdrawal would compromise vault solvency
        _requireDragonSolvencyAfterOperation(owner, shares);

        _withdraw(S, receiver, owner, assets, shares, maxLoss);

        // Update value debt after successful withdrawal (only for users)
        if (owner != S.dragonRouter) {
            YS.totalDebtOwedToUserInAssetValue = YS.totalDebtOwedToUserInAssetValue > valueToReturn
                ? YS.totalDebtOwedToUserInAssetValue - valueToReturn
                : 0;
        } else {
            YS.dragonRouterDebtInAssetValue = YS.dragonRouterDebtInAssetValue > valueToReturn
                ? YS.dragonRouterDebtInAssetValue - valueToReturn
                : 0;
        }

        // if vault is empty, reset all debts to 0
        if (_totalSupply(S) == 0) {
            YS.totalDebtOwedToUserInAssetValue = 0;
            YS.dragonRouterDebtInAssetValue = 0;
        }

        return shares;
    }

    /**
     * @notice Get the maximum amount of assets that can be deposited by a user
     * @dev Returns 0 for dragon router as they cannot deposit
     * @param receiver Address that would receive the shares
     * @return Maximum deposit amount in asset base units
     */
    function maxDeposit(address receiver) public view virtual override returns (uint256) {
        StrategyData storage S = _strategyStorage();
        if (_currentRateRay() == 0) {
            return 0;
        }
        if (receiver == S.dragonRouter || _isVaultInsolvent()) {
            return 0;
        }
        return super.maxDeposit(receiver);
    }

    /**
     * @notice Get the maximum amount of shares that can be minted by a user
     * @dev Returns 0 for dragon router as they cannot mint
     * @param receiver Address that would receive the shares
     * @return Maximum mint amount in shares
     */
    function maxMint(address receiver) public view virtual override returns (uint256) {
        StrategyData storage S = _strategyStorage();
        if (_currentRateRay() == 0) {
            return 0;
        }
        if (receiver == S.dragonRouter || _isVaultInsolvent()) {
            return 0;
        }
        return super.maxMint(receiver);
    }

    /**
     * @notice Get the maximum amount of assets that can be withdrawn by a user
     * @dev Dragon router has restrictions based on solvency protection to ensure user debt coverage.
     *      For non-dragon users during insolvency, simulates the lazy dragon burn that will occur
     *      in withdraw() to return the correct post-burn amount (ERC4626 compliance).
     * @param owner Address whose shares would be burned
     * @return Maximum withdraw amount in asset base units
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        StrategyData storage S = _strategyStorage();

        uint256 baseMaxWithdraw = super.maxWithdraw(owner);

        // Apply dragon-specific restrictions
        if (owner == S.dragonRouter) {
            uint256 dragonMaxRedeemShares = _maxDragonRedeemableShares();

            uint256 dragonMaxWithdrawAssets = _convertToAssets(S, dragonMaxRedeemShares, Math.Rounding.Floor);
            return Math.min(dragonMaxWithdrawAssets, baseMaxWithdraw);
        }

        // Simulate the lazy burn that withdraw() will perform to reflect post-burn pricing.
        // Without this, maxWithdraw underreports because _convertToAssets uses totalSupply
        // that still includes dragon shares (which the lazy burn will remove).
        uint256 burnAmount = _simulateDragonBurnAmount();
        if (burnAmount > 0) {
            uint256 postBurnSupply = _totalSupply(S) - burnAmount;
            if (postBurnSupply == 0) return 0;

            uint256 ownerShares = _balanceOf(S, owner);
            return ownerShares.mulDiv(S.totalAssets, postBurnSupply, Math.Rounding.Floor);
        }

        return baseMaxWithdraw;
    }

    /**
     * @notice Get the maximum amount of shares that can be redeemed by a user
     * @dev Dragon router has restrictions based on solvency protection to ensure user debt coverage.
     *      For non-dragon users, super.maxRedeem returns _balanceOf(owner) because
     *      availableWithdrawLimit is uncapped — no burn simulation needed here.
     * @param owner Address whose shares would be burned
     * @return Maximum redeem amount in shares
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        StrategyData storage S = _strategyStorage();

        uint256 baseMaxRedeem = super.maxRedeem(owner);

        // Apply dragon-specific restrictions
        if (owner == S.dragonRouter) {
            uint256 dragonMaxRedeem = _maxDragonRedeemableShares();
            return Math.min(baseMaxRedeem, dragonMaxRedeem);
        }

        return baseMaxRedeem;
    }

    /**
     * @notice Get the total underlying-asset-value debt owed to users
     * @return Total user debt in underlying-asset value units
     */
    function gettotalDebtOwedToUserInAssetValue() external view returns (uint256) {
        return _strategyYieldSkimmingStorage().totalDebtOwedToUserInAssetValue;
    }

    /**
     * @notice Get the total underlying-asset-value debt owed to dragon router
     * @return Total dragon router debt in underlying-asset value units
     */
    function getDragonRouterDebtInAssetValue() external view returns (uint256) {
        return _strategyYieldSkimmingStorage().dragonRouterDebtInAssetValue;
    }

    /**
     * @notice Get the total underlying-asset-value debt owed to both users and dragon router combined
     * @return Total debt in underlying-asset value units combining users and dragon router
     */
    function getTotalValueDebtInAssetValue() external view returns (uint256) {
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();
        return YS.totalDebtOwedToUserInAssetValue + YS.dragonRouterDebtInAssetValue;
    }

    /**
     * @notice Preview the shares that would be minted for a deposit of `assets`.
     * @dev Returns 0 when the vault is insolvent or the exchange rate is 0. The real
     *      `deposit` path reverts via `_requireVaultSolvency`, so an inherited preview
     *      would lie to ERC-4626 integrators that expect `previewDeposit` to match the
     *      call they are about to make. In the solvent branch the inherited
     *      `_convertToShares` override already uses the same rate-based math as
     *      `deposit`, so delegating to `super.previewDeposit` is accurate.
     * @param assets Amount of assets hypothetically deposited
     * @return shares Shares a depositor would receive (0 when a real deposit would revert)
     */
    function previewDeposit(uint256 assets) public view virtual override returns (uint256 shares) {
        if (_currentRateRay() == 0 || _isVaultInsolvent()) return 0;
        return super.previewDeposit(assets);
    }

    /**
     * @notice Preview the assets required to mint exactly `shares`.
     * @dev Mirror of `previewDeposit`: returns 0 when the real `mint` path would revert
     *      (vault insolvent or exchange rate missing). Solvent branch uses the same
     *      Ceil-rounded conversion as `mint`.
     * @param shares Amount of shares hypothetically minted
     * @return assets Assets a minter would deposit (0 when a real mint would revert)
     */
    function previewMint(uint256 shares) public view virtual override returns (uint256 assets) {
        if (_currentRateRay() == 0 || _isVaultInsolvent()) return 0;
        return super.previewMint(shares);
    }

    /**
     * @notice Preview the shares burned to withdraw `assets`.
     * @dev The real `withdraw` path applies the lazy dragon burn before pricing the
     *      exit, so the post-burn `totalSupply` is the correct denominator in the
     *      insolvent branch. Simulate that burn via `_simulateDragonBurnAmount` and
     *      mirror the parent pro-rata math (Ceil rounding) against the reduced supply.
     *      When no burn is pending, the inherited `_convertToShares` override already
     *      matches `withdraw`, so `super.previewWithdraw` is accurate.
     * @param assets Amount of assets hypothetically withdrawn
     * @return shares Shares that would be burned (reflects pending dragon burn)
     */
    function previewWithdraw(uint256 assets) public view virtual override returns (uint256 shares) {
        uint256 burnAmount = _simulateDragonBurnAmount();
        if (burnAmount == 0) return super.previewWithdraw(assets);

        StrategyData storage S = _strategyStorage();
        if (S.totalAssets == 0) return 0;
        uint256 postBurnSupply = _totalSupply(S) - burnAmount;
        return assets.mulDiv(postBurnSupply, S.totalAssets, Math.Rounding.Ceil);
    }

    /**
     * @notice Preview the assets returned for redeeming `shares`.
     * @dev Mirror of `previewWithdraw`. Dragon-share burning never changes `totalAssets`
     *      or `totalDebtOwedToUserInAssetValue`, so `_isVaultInsolvent` stays true after
     *      the simulated burn and the parent pro-rata branch is the one that will fire
     *      in `redeem`. Floor rounding matches `redeem`'s `_convertToAssets` call.
     *      The preview is owner-agnostic by ERC-4626 shape; it models the non-dragon
     *      redemption path because that is where the lazy burn applies. Dragon-owner
     *      redemptions use `maxRedeem` for sizing, which already has its own override.
     * @param shares Amount of shares hypothetically redeemed
     * @return assets Assets a redeemer would receive (reflects pending dragon burn)
     */
    function previewRedeem(uint256 shares) public view virtual override returns (uint256 assets) {
        uint256 burnAmount = _simulateDragonBurnAmount();
        if (burnAmount == 0) return super.previewRedeem(shares);

        StrategyData storage S = _strategyStorage();
        uint256 postBurnSupply = _totalSupply(S) - burnAmount;
        if (postBurnSupply == 0) return 0;
        return shares.mulDiv(S.totalAssets, postBurnSupply, Math.Rounding.Floor);
    }

    /**
     * @notice Transfer shares with dragon solvency protection and debt rebalancing
     * @dev Special behaviors for dragon router:
     *      - Dragon cannot transfer to itself (reverts)
     *      - Dragon transfers trigger solvency checks to prevent user debt undercoverage
     *      - Transfers blocked if they would make vault unable to cover user debt
     *      - Dragon-involved transfers rebalance debt tracking (sender loses debt, receiver gains it)
     *      For non-dragon transfers, behaves like standard ERC20 transfer
     * @param to Address receiving shares
     * @param amount Amount of shares to transfer
     * @return success Whether the transfer succeeded
     */
    function transfer(address to, uint256 amount) external override returns (bool success) {
        StrategyData storage S = _strategyStorage();

        // Prevent dragon router from transferring to itself
        if (msg.sender == S.dragonRouter && to == S.dragonRouter) {
            revert("Dragon cannot transfer to itself");
        }

        _requireDragonSolvencyAfterOperation(msg.sender, amount);

        // Handle debt rebalancing when dragon is involved
        if (msg.sender == S.dragonRouter || to == S.dragonRouter) {
            _rebalanceDebtOnDragonTransfer(msg.sender, to, amount);
        }

        // Use base contract logic for actual transfer
        _transfer(S, msg.sender, to, amount);

        return true;
    }

    /**
     * @notice Transfer shares from one address to another with dragon solvency protection and debt rebalancing
     * @dev Special behaviors for dragon router:
     *      - Dragon cannot transfer to itself (reverts)
     *      - Dragon transfers trigger solvency checks to prevent user debt undercoverage
     *      - Transfers blocked if they would make vault unable to cover user debt
     *      - Dragon-involved transfers rebalance debt tracking (sender loses debt, receiver gains it)
     *      For non-dragon transfers, behaves like standard ERC20 transferFrom
     * @param from Address transferring shares
     * @param to Address receiving shares
     * @param amount Amount of shares to transfer
     * @return success Whether the transfer succeeded
     */
    function transferFrom(address from, address to, uint256 amount) external override returns (bool success) {
        StrategyData storage S = _strategyStorage();

        // Prevent dragon router from transferring to itself
        if (from == S.dragonRouter && to == S.dragonRouter) {
            revert("Dragon cannot transfer to itself");
        }

        _requireDragonSolvencyAfterOperation(from, amount);

        // Handle debt rebalancing when dragon is involved
        if (from == S.dragonRouter || to == S.dragonRouter) {
            _rebalanceDebtOnDragonTransfer(from, to, amount);
        }

        // Use base contract logic for actual transfer
        _spendAllowance(S, from, msg.sender, amount);
        _transfer(S, from, to, amount);

        return true;
    }

    /**
     * @notice Reports yield skimming strategy performance and handles profit distribution and loss coverage
     * @dev Overrides report to handle yield appreciation and loss recovery through dragon share minting/burning.
     *
     * Health check effectiveness depends on report() frequency. Exchange rate checks
     * become less effective over time if reports are infrequent, as profit limits may be exceeded.
     * Management should ensure regular reporting or adjust profit/loss ratios based on expected frequency.
     *
     * Key behaviors:
     * 1. **Value Comparison**: Compares current total value (assets * exchange rate) vs total outstanding shares
     * 2. **Profit Capture**: When current value exceeds total shares, mints dragon shares equal to excess value
     * 3. **Loss Protection**: When current value is less than total shares, burns dragon shares (if enabled) to cover shortfall
     * 4. **Insolvency Handling**: If dragon buffer insufficient for losses, remaining shortfall is handled through proportional asset distribution during withdrawals
     *
     * Event semantics: the `loss` value emitted via `Reported` is a gross
     * shortfall — the full gap between total value debt and current vault
     * value at the time of the call — not an incremental delta since the last
     * report. If `report()` is called multiple times during the same impairment
     * (e.g. dragon shares cannot fully cover the loss), the same gross shortfall
     * is re-emitted on each call.
     *
     * Integrators must not naively sum `loss` across consecutive `Reported`
     * events to compute cumulative damage; doing so double-counts persistent
     * impairments. Treat the event as a level signal, not a delta signal.
     *
     * @return profit Profit in assets from underlying value appreciation since the last report
     * @return loss Loss in assets — gross shortfall (level), not a delta. See event semantics above.
     */
    function report()
        public
        override(TokenizedStrategy)
        nonReentrant
        onlyKeepers
        returns (uint256 profit, uint256 loss)
    {
        StrategyData storage S = super._strategyStorage();
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();

        // Update total assets from harvest
        uint256 currentTotalAssets = IBaseStrategy(address(this)).harvestAndReport();

        uint256 totalAssetsBalance = S.asset.balanceOf(address(this));
        if (totalAssetsBalance != currentTotalAssets) {
            S.totalAssets = totalAssetsBalance;
        }

        uint256 currentRate = _currentRateRay();
        uint256 totalAssets = totalAssetsBalance;
        uint256 currentValue = totalAssets.mulDiv(currentRate, WadRayMath.RAY);
        // Compare current value to total debt (user debt + dragon router debt combined)

        if (currentValue > YS.totalDebtOwedToUserInAssetValue + YS.dragonRouterDebtInAssetValue) {
            // Yield captured! Mint profit shares to dragon
            uint256 profitValue = currentValue - YS.totalDebtOwedToUserInAssetValue - YS.dragonRouterDebtInAssetValue;

            uint256 profitShares = profitValue; // 1 share = 1 unit of underlying-asset value, except in case of uncovered loss

            // Convert profit value to assets for reporting
            profit = profitValue.mulDiv(WadRayMath.RAY, currentRate);

            _mint(S, S.dragonRouter, profitShares);

            // update the dragon value debt
            YS.dragonRouterDebtInAssetValue += profitValue;

            emit DonationMinted(S.dragonRouter, profitShares, currentRate.rayToWad());
        } else if (currentValue < YS.totalDebtOwedToUserInAssetValue + YS.dragonRouterDebtInAssetValue) {
            // Loss - burn dragon shares first
            uint256 lossValue = YS.totalDebtOwedToUserInAssetValue + YS.dragonRouterDebtInAssetValue - currentValue;

            // Handle loss protection through dragon burning
            loss = _handleDragonLossProtection(S, YS, lossValue, currentRate);
        }

        // Update last report timestamp
        S.lastReport = uint96(block.timestamp);
        YS.lastReportedRate = currentRate;
        emit Harvest(msg.sender, currentRate.rayToWad());
        // `loss` here is a gross shortfall (level), not a delta; see report() NatSpec.
        emit Reported(profit, loss);

        return (profit, loss);
    }

    /**
     * @notice Get the last reported exchange rate (RAY precision)
     * @return Last reported exchange rate in RAY precision
     */
    function getLastRateRay() external view returns (uint256) {
        return _strategyYieldSkimmingStorage().lastReportedRate;
    }

    /**
     * @notice Check if the vault is currently insolvent
     * @return isInsolvent True if vault cannot cover user debt (excludes dragon shares as they absorb losses)
     */
    function isVaultInsolvent() external view returns (bool) {
        return _isVaultInsolvent();
    }

    /**
     * @dev Converts assets to shares using value debt approach with solvency awareness
     * @param S Strategy storage
     * @param assets Amount of assets to convert
     * @param rounding Rounding mode for division
     * @return Amount of shares equivalent in value (1 share = 1 unit of underlying-asset value, except in case of uncovered loss)
     */
    function _convertToShares(
        StrategyData storage S,
        uint256 assets,
        Math.Rounding rounding
    ) internal view virtual override returns (uint256) {
        if (_totalSupply(S) == 0 && _totalAssets(S) != 0) return 0;

        if (_isVaultInsolvent()) {
            // Vault insolvent - use parent TokenizedStrategy logic
            return super._convertToShares(S, assets, rounding);
        } else {
            // Vault solvent - normal rate-based conversion
            uint256 currentRate = _currentRateRay();
            if (currentRate > 0) {
                return assets.mulDiv(currentRate, WadRayMath.RAY, rounding);
            } else {
                // Rate is 0 - asset has no value, use parent logic as fallback
                return super._convertToShares(S, assets, rounding);
            }
        }
    }

    /**
     * @dev Converts shares to assets using value debt approach with solvency awareness
     * @param S Strategy storage
     * @param shares Amount of shares to convert
     * @param rounding Rounding mode for division
     * @return Amount of assets user would receive in asset base units
     */
    function _convertToAssets(
        StrategyData storage S,
        uint256 shares,
        Math.Rounding rounding
    ) internal view virtual override returns (uint256) {
        if (_totalSupply(S) == 0 && _totalAssets(S) != 0) return 0;

        if (_isVaultInsolvent()) {
            // Vault insolvent - use parent TokenizedStrategy logic
            return super._convertToAssets(S, shares, rounding);
        } else {
            // Vault solvent - normal rate-based conversion
            uint256 currentRate = _currentRateRay();
            if (currentRate > 0) {
                return shares.mulDiv(WadRayMath.RAY, currentRate, rounding);
            } else {
                // Rate is 0 - asset has no value, use parent logic as fallback
                return super._convertToAssets(S, shares, rounding);
            }
        }
    }

    /**
     * @dev When the last user exit leaves surplus value because the exchange
     *      rate moved up after the latest report, materialize that surplus as
     *      dragon shares before the user shares are burned.
     */
    function _handleFinalWithdrawSurplus(
        StrategyData storage S,
        uint256 assetsToRemove,
        uint256 totalAssets_,
        uint256 assets
    ) internal override returns (uint256) {
        uint256 surplus = totalAssets_ - assetsToRemove;
        uint256 currentRate = _currentRateRay();
        uint256 surplusValue = surplus.mulDiv(currentRate, WadRayMath.RAY);

        if (surplusValue == 0) {
            uint256 requiredIdle = assets + surplus;
            uint256 idle = S.asset.balanceOf(address(this));
            if (idle < requiredIdle) {
                IBaseStrategy(address(this)).freeFunds(requiredIdle - idle);
                idle = S.asset.balanceOf(address(this));
            }

            if (idle < requiredIdle) return assetsToRemove;

            S.asset.safeTransfer(S.dragonRouter, surplus);
            return totalAssets_;
        }

        _mint(S, S.dragonRouter, surplusValue);
        _strategyYieldSkimmingStorage().dragonRouterDebtInAssetValue += surplusValue;

        emit DonationMinted(S.dragonRouter, surplusValue, currentRate.rayToWad());

        return assetsToRemove;
    }

    /**
     * @dev Checks if the vault is currently insolvent
     * @return isInsolvent True if vault cannot cover user value debt
     */
    function _isVaultInsolvent() internal view returns (bool isInsolvent) {
        StrategyData storage S = _strategyStorage();
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();
        uint256 currentRate = _currentRateRay();
        uint256 currentVaultValue = S.totalAssets.mulDiv(currentRate, WadRayMath.RAY);

        // Vault is only insolvent if it cannot cover user debt
        // Dragon debt is excluded as dragon shares are designed to absorb losses
        return YS.totalDebtOwedToUserInAssetValue > 0 && currentVaultValue < YS.totalDebtOwedToUserInAssetValue;
    }

    /**
     * @dev Calculates the maximum amount of shares the dragon can redeem without making the vault unable to cover user debt
     * @return maxDragonRedeemable Maximum shares the dragon can redeem
     */
    function _maxDragonRedeemableShares() internal view returns (uint256 maxDragonRedeemable) {
        StrategyData storage S = _strategyStorage();
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();
        uint256 currentRate = _currentRateRay();
        uint256 currentVaultValue = S.totalAssets.mulDiv(currentRate, WadRayMath.RAY);

        // if enableBurning is false, dragon can redeem its full balance
        if (!S.enableBurning) {
            return _balanceOf(S, S.dragonRouter);
        }

        // If vault value is already below user debt, dragon cannot withdraw
        if (currentVaultValue <= YS.totalDebtOwedToUserInAssetValue) {
            return 0;
        }

        // Calculate excess value available for dragon (vault value - user debt)
        uint256 excessValue = currentVaultValue - YS.totalDebtOwedToUserInAssetValue;

        // Dragon can only redeem up to their debt or the excess value, whichever is lower
        uint256 dragonWithdrawableValue = Math.min(YS.dragonRouterDebtInAssetValue, excessValue);

        // Since dragon shares are 1:1 with value debt, return the value directly
        return dragonWithdrawableValue;
    }

    /**
     * @dev Blocks dragon router from withdrawing during vault insolvency
     * @param account The address to check (only blocks if it's the dragon router)
     */
    function _requireDragonSolvency(address account) internal view {
        StrategyData storage S = _strategyStorage();

        // if enableBurning is false, dragon can withdraw its full balance
        if (!S.enableBurning) {
            return;
        }

        // Only check if account is dragon router
        if (account == S.dragonRouter && _isVaultInsolvent()) {
            revert("Dragon cannot operate during insolvency");
        }
    }

    /**
     * @dev Checks vault solvency when dragon sends shares out (transfer, redeem, withdraw)
     * @param from Address shares are coming from
     * @param amount Amount of shares being moved
     * @dev Only checks when dragon is SENDING shares. Transfers TO dragon always improve
     *      user debt coverage so no check is needed for those.
     */
    function _requireDragonSolvencyAfterOperation(address from, uint256 amount) internal view {
        StrategyData storage S = _strategyStorage();
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();

        // if enableBurning is false, dragon can transfer freely
        if (!S.enableBurning) {
            return;
        }

        // Only check if dragon router is sending shares (user transfers to dragon always improve solvency)
        if (from != S.dragonRouter) {
            return;
        }

        // Calculate current vault value
        uint256 currentRate = _currentRateRay();
        uint256 currentVaultValue = S.totalAssets.mulDiv(currentRate, WadRayMath.RAY);

        // Dragon is sending shares - user debt will increase by the amount transferred
        uint256 currentUserDebt = YS.totalDebtOwedToUserInAssetValue;
        uint256 userDebtAfterTransfer = currentUserDebt + amount;
        if (currentVaultValue < userDebtAfterTransfer) {
            revert("Transfer would cause vault insolvency");
        }
    }

    /**
     * @dev Rebalances debt tracking when dragon transfers shares in or out
     */
    function _rebalanceDebtOnDragonTransfer(address from, address to, uint256 transferAmount) internal {
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();
        StrategyData storage S = _strategyStorage();

        // Direct transfer: shares represent underlying-asset value 1:1 in this system
        if (from == S.dragonRouter) {
            // Dragon sends shares: dragon loses debt obligation, users gain debt obligation
            require(YS.dragonRouterDebtInAssetValue >= transferAmount, "Insufficient dragon debt");
            unchecked {
                YS.dragonRouterDebtInAssetValue -= transferAmount;
            }
            YS.totalDebtOwedToUserInAssetValue += transferAmount;
        } else if (to == S.dragonRouter) {
            // User sends shares to dragon: users lose debt obligation, dragon gains debt obligation
            require(YS.totalDebtOwedToUserInAssetValue >= transferAmount, "Insufficient user debt");
            unchecked {
                YS.totalDebtOwedToUserInAssetValue -= transferAmount;
            }
            YS.dragonRouterDebtInAssetValue += transferAmount;
        }
    }

    /**
     * @dev Blocks all operations when vault is insolvent
     */
    function _requireVaultSolvency() internal view {
        if (_isVaultInsolvent()) {
            revert("Cannot operate when vault is insolvent");
        }
    }

    /**
     * @dev Get the current exchange rate scaled to RAY precision
     * @return Current exchange rate in RAY format (1e27 = 1.0)
     */
    function _currentRateRay() internal view virtual returns (uint256) {
        uint256 exchangeRate = IYieldSkimmingStrategy(address(this)).getCurrentExchangeRate();
        uint256 exchangeRateDecimals = IYieldSkimmingStrategy(address(this)).decimalsOfExchangeRate();

        // Convert directly to RAY (27 decimals) to avoid precision loss
        if (exchangeRateDecimals == 27) {
            return exchangeRate;
        } else if (exchangeRateDecimals < 27) {
            return exchangeRate * 10 ** (27 - exchangeRateDecimals);
        } else {
            return exchangeRate / 10 ** (exchangeRateDecimals - 27);
        }
    }

    /**
     * @dev Simulates how many dragon shares the lazy burn would remove from totalSupply.
     *      Used by maxWithdraw/maxRedeem view functions to reflect post-burn pricing.
     * @return burnAmount Number of dragon shares that would be burned (0 if no burn would occur)
     */
    function _simulateDragonBurnAmount() internal view returns (uint256 burnAmount) {
        StrategyData storage S = _strategyStorage();
        if (!S.enableBurning || !_isVaultInsolvent()) return 0;

        uint256 dragonBalance = _balanceOf(S, S.dragonRouter);
        if (dragonBalance == 0) return 0;

        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();
        uint256 currentRate = _currentRateRay();
        uint256 currentVaultValue = S.totalAssets.mulDiv(currentRate, WadRayMath.RAY);
        uint256 totalDebt = YS.totalDebtOwedToUserInAssetValue + YS.dragonRouterDebtInAssetValue;

        if (currentVaultValue >= totalDebt) return 0;

        return Math.min(totalDebt - currentVaultValue, dragonBalance);
    }

    /**
     * @dev Lazily burns dragon shares when the vault is insolvent, so that user exits
     *      are not diluted by stale junior capital in the totalSupply denominator.
     *      Only mutates state when burning is enabled AND the vault is currently insolvent.
     * @param S Strategy storage pointer
     * @param YS Yield skimming storage pointer
     */
    function _applyDragonLossProtectionIfNeeded(StrategyData storage S, YieldSkimmingStorage storage YS) internal {
        if (!S.enableBurning) return;
        // Only burn when the vault is insolvent (can't cover user debt).
        // This is the condition that triggers the pro-rata fallback in _convertToAssets,
        // which is where dragon shares in totalSupply cause dilution.
        if (!_isVaultInsolvent()) return;

        uint256 currentRate = _currentRateRay();
        uint256 currentVaultValue = S.totalAssets.mulDiv(currentRate, WadRayMath.RAY);
        uint256 totalDebt = YS.totalDebtOwedToUserInAssetValue + YS.dragonRouterDebtInAssetValue;

        if (currentVaultValue < totalDebt) {
            _handleDragonLossProtection(S, YS, totalDebt - currentVaultValue, currentRate);
        }
    }

    /**
     * @dev Internal function to handle loss protection by burning dragon shares
     * @param S Strategy storage pointer
     * @param YS Yield skimming storage pointer
     * @param lossValue Loss amount in underlying-asset value terms
     * @param currentRate Current exchange rate in RAY format
     * @return loss Loss amount in asset terms for reporting
     */
    function _handleDragonLossProtection(
        StrategyData storage S,
        YieldSkimmingStorage storage YS,
        uint256 lossValue,
        uint256 currentRate
    ) internal returns (uint256 loss) {
        uint256 dragonBalance = _balanceOf(S, S.dragonRouter);

        // Report the total loss in assets (gross loss before dragon protection)
        // Handle division by zero case when currentRate is 0
        if (currentRate > 0) {
            loss = lossValue.mulDiv(WadRayMath.RAY, currentRate);
        } else {
            // If rate is 0, total loss is all assets
            loss = S.totalAssets;
        }

        if (dragonBalance > 0 && S.enableBurning) {
            uint256 dragonBurn = Math.min(lossValue, dragonBalance);
            _burn(S, S.dragonRouter, dragonBurn);

            // Saturating subtraction: dragon-balance and dragon-debt should stay in sync,
            // but if accounting drifts (e.g. balance > debt) the raw `-=` would underflow
            // and brick loss protection. Match the defensive pattern used in redeem/withdraw.
            YS.dragonRouterDebtInAssetValue = YS.dragonRouterDebtInAssetValue > dragonBurn
                ? YS.dragonRouterDebtInAssetValue - dragonBurn
                : 0;

            emit DonationBurned(S.dragonRouter, dragonBurn, currentRate.rayToWad());
        }
    }

    /**
     * @notice Finalizes the dragon router change with proper debt accounting migration
     * @dev Migrates debt tracking when dragon router changes to maintain correct accounting.
     *      The solvency check runs AFTER debt migration so that:
     *      - Migrations that would restore solvency (new dragon holds user shares whose
     *        conversion to dragon debt drops user debt below vault value) are allowed.
     *      - Migrations that would create insolvency (old dragon balance becoming user
     *        debt pushes user debt above vault value) are blocked.
     *      A pre-migration check inspecting the old state misclassifies both directions.
     */
    function finalizeDragonRouterChange() external override {
        StrategyData storage S = _strategyStorage();
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();

        require(S.pendingDragonRouter != address(0), "no pending change");
        require(block.timestamp >= S.dragonRouterChangeTimestamp + DRAGON_ROUTER_COOLDOWN, "cooldown not elapsed");

        address oldDragonRouter = S.dragonRouter;
        address newDragonRouter = S.pendingDragonRouter;

        // Burn any stale junior loss buffer before snapshotting balances so a
        // dust transfer to the old dragon cannot decide migration accounting.
        if (S.enableBurning) {
            _applyDragonLossProtectionIfNeeded(S, YS);
        }

        // Get balances before changing the router
        uint256 oldDragonBalance = _balanceOf(S, oldDragonRouter);
        uint256 newDragonBalance = _balanceOf(S, newDragonRouter);

        // Migrate debt accounting:
        // 1. Old dragon router's balance becomes user debt
        if (oldDragonBalance > 0) {
            YS.totalDebtOwedToUserInAssetValue += oldDragonBalance;
            if (YS.dragonRouterDebtInAssetValue >= oldDragonBalance) {
                YS.dragonRouterDebtInAssetValue -= oldDragonBalance;
            } else {
                YS.dragonRouterDebtInAssetValue = 0;
            }
        }

        // 2. New dragon router's balance (if any) becomes dragon debt
        if (newDragonBalance > 0) {
            YS.dragonRouterDebtInAssetValue += newDragonBalance;
            if (YS.totalDebtOwedToUserInAssetValue >= newDragonBalance) {
                YS.totalDebtOwedToUserInAssetValue -= newDragonBalance;
            } else {
                YS.totalDebtOwedToUserInAssetValue = 0;
            }
        }

        // Post-migration solvency check: only enforced when burning is enabled
        // (mirrors the gating used by _requireDragonSolvency / _maxDragonRedeemableShares).
        if (S.enableBurning) {
            require(!_isVaultInsolvent(), "Router change would cause insolvency");
        }

        // Now call the parent implementation to actually change the router
        S.dragonRouter = newDragonRouter;
        S.pendingDragonRouter = address(0);
        S.dragonRouterChangeTimestamp = 0;
        emit UpdateDragonRouter(newDragonRouter);
    }

    function _strategyYieldSkimmingStorage() internal pure returns (YieldSkimmingStorage storage S) {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = YIELD_SKIMMING_STORAGE_SLOT;
        assembly {
            S.slot := slot
        }
    }
}
