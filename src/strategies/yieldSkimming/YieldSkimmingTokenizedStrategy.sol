// SPDX-License-Identifier: MIT
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
 * @author octant.finance
 * @notice A specialized version of TokenizedStrategy designed for yield-bearing tokens
 * like mETH whose value appreciates over time.
 * @dev This strategy implements a yield skimming mechanism by:
 *      - Recognizing appreciation of the underlying asset during report()
 *      - Diluting existing shares by minting new ones to dragonRouter
 *      - Using a modified asset-to-shares conversion that accounts for dilution
 *      - Calling report() during deposits to ensure up-to-date exchange rates
 */
contract YieldSkimmingTokenizedStrategy is TokenizedStrategy {
    using Math for uint256;
    using WadRayMath for uint256;
    using SafeERC20 for ERC20;

    /// @dev Storage for yield skimming strategy
    struct YieldSkimmingStorage {
        uint256 totalUserDebtInAssetValue; // Track ETH value owed to users only
        uint256 lastReportedRate; // Track the last reported rate
        uint256 dragonRouterDebtInAssetValue; // Track the ETH value owed to dragon router
    }

    // exchange rate storage slot
    bytes32 private constant YIELD_SKIMMING_STORAGE_SLOT = keccak256("octant.yieldSkimming.exchangeRate");

    /// @dev Event emitted when harvest is performed
    event Harvest(address indexed caller, uint256 currentRate);

    /// @dev Events for donation tracking
    event DonationMinted(address indexed dragonRouter, uint256 amount, uint256 exchangeRate);
    event DonationBurned(address indexed dragonRouter, uint256 amount, uint256 exchangeRate);

    /**
     * @notice Deposit assets into the strategy with value debt tracking
     * @dev Implements deposit protection and tracks ETH value debt
     * @param assets The amount of assets to deposit
     * @param receiver The address to receive the shares
     * @return shares The amount of shares minted (1 share = 1 ETH value)
     */
    function deposit(uint256 assets, address receiver) external override nonReentrant returns (uint256 shares) {
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

        // Issue shares based on value (1 share = 1 ETH value)
        shares = assets.mulDiv(currentRate, WadRayMath.RAY);
        require(shares != 0, "ZERO_SHARES");

        // Update value debt
        YS.totalUserDebtInAssetValue += shares;

        // Call internal deposit to handle transfers and minting
        _deposit(S, receiver, assets, shares);

        return shares;
    }

    /**
     * @notice Mint exact shares from the strategy with value debt tracking
     * @dev Implements insolvency protection and tracks ETH value debt
     * @param shares The amount of shares to mint
     * @param receiver The address to receive the shares
     * @return assets The amount of assets deposited (1 share = 1 ETH value)
     */
    function mint(uint256 shares, address receiver) external override nonReentrant returns (uint256 assets) {
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

        // Calculate assets needed based on value (1 share = 1 ETH value)
        assets = shares.mulDiv(WadRayMath.RAY, currentRate, Math.Rounding.Ceil);
        require(assets != 0, "ZERO_ASSETS");

        // Update value debt
        YS.totalUserDebtInAssetValue += shares;

        // Call internal deposit to handle transfers and minting
        _deposit(S, receiver, assets, shares);

        return assets;
    }

    /**
     * @notice Redeem shares from the strategy with default maxLoss
     * @dev Wrapper that calls the full redeem function with MAX_BPS maxLoss
     * @param shares The amount of shares to redeem
     * @param receiver The address to receive the assets
     * @param owner The address whose shares are being redeemed
     * @return assets The amount of assets returned
     */
    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        return redeem(shares, receiver, owner, MAX_BPS);
    }

    /**
     * @notice Redeem shares from the strategy with value debt tracking
     * @dev Shares represent ETH value (1 share = 1 ETH value)
     * @param shares The amount of shares to redeem
     * @param receiver The address to receive the assets
     * @param owner The address whose shares are being redeemed
     * @param maxLoss The maximum acceptable loss in basis points
     * @return assets The amount of assets returned
     */
    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss
    ) public override nonReentrant returns (uint256 assets) {
        StrategyData storage S = _strategyStorage();
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();

        // Dragon cannot withdraw during insolvency - must protect users
        _requireDragonSolvency(owner);

        // Calculate actual value returned for debt tracking (before redemption)
        uint256 valueToReturn = shares; // 1 share = 1 ETH value (regardless of actual assets received)

        // Validate inputs and check limits (replaces super.redeem validation)
        require(shares <= _maxRedeem(S, owner), "ERC4626: redeem more than max");
        require((assets = _convertToAssets(S, shares, Math.Rounding.Floor)) != 0, "ZERO_ASSETS");
        assets = _withdraw(S, receiver, owner, assets, shares, maxLoss);

        // Update value debt after successful redemption (only for users)
        if (owner != S.dragonRouter) {
            YS.totalUserDebtInAssetValue = YS.totalUserDebtInAssetValue > valueToReturn
                ? YS.totalUserDebtInAssetValue - valueToReturn
                : 0;
        } else {
            YS.dragonRouterDebtInAssetValue = YS.dragonRouterDebtInAssetValue > valueToReturn
                ? YS.dragonRouterDebtInAssetValue - valueToReturn
                : 0;
        }

        // if vault is empty, reset all debts to 0
        if (_totalSupply(S) == 0) {
            YS.totalUserDebtInAssetValue = 0;
            YS.dragonRouterDebtInAssetValue = 0;
        }

        // Check solvency after withdrawal and debt update to prevent dragon from making vault insolvent
        _requireDragonSolvency(owner);

        return assets;
    }

    /**
     * @notice Withdraw assets from the strategy with value debt tracking
     * @dev Calculates shares needed for the asset amount requested
     * @param assets The amount of assets to withdraw
     * @param receiver The address to receive the assets
     * @param owner The address whose shares are being redeemed
     * @param maxLoss The maximum acceptable loss in basis points
     * @return shares The amount of shares burned
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss
    ) public override nonReentrant returns (uint256 shares) {
        StrategyData storage S = _strategyStorage();
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();

        // Dragon cannot withdraw during insolvency - must protect users
        _requireDragonSolvency(owner);

        // Validate inputs and check limits (replaces super.withdraw validation)
        require(assets <= _maxWithdraw(S, owner), "ERC4626: withdraw more than max");
        require((shares = _convertToShares(S, assets, Math.Rounding.Ceil)) != 0, "ZERO_SHARES");

        // Calculate actual value returned for debt tracking (before withdrawal)
        uint256 valueToReturn = shares; // 1 share = 1 ETH value
        _withdraw(S, receiver, owner, assets, shares, maxLoss);

        // Update value debt after successful withdrawal (only for users)
        if (owner != S.dragonRouter) {
            YS.totalUserDebtInAssetValue = YS.totalUserDebtInAssetValue > valueToReturn
                ? YS.totalUserDebtInAssetValue - valueToReturn
                : 0;
        } else {
            YS.dragonRouterDebtInAssetValue = YS.dragonRouterDebtInAssetValue > valueToReturn
                ? YS.dragonRouterDebtInAssetValue - valueToReturn
                : 0;
        }

        // if vault is empty, reset all debts to 0
        if (_totalSupply(S) == 0) {
            YS.totalUserDebtInAssetValue = 0;
            YS.dragonRouterDebtInAssetValue = 0;
        }

        // Check solvency after withdrawal and debt update to prevent dragon from making vault insolvent
        _requireDragonSolvency(owner);

        return shares;
    }

    /**
     * @notice Withdraw assets from the strategy with default maxLoss
     * @dev Wrapper that calls the full withdraw function with 0 maxLoss
     * @param assets The amount of assets to withdraw
     * @param receiver The address to receive the assets
     * @param owner The address whose shares are being redeemed
     * @return shares The amount of shares burned
     */
    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256 shares) {
        return withdraw(assets, receiver, owner, 0);
    }

    /**
     * @notice Get the maximum amount of assets that can be deposited by a user
     * @dev Returns 0 for dragon router as they cannot deposit
     * @param receiver The address that would receive the shares
     * @return The maximum deposit amount
     */
    function maxDeposit(address receiver) public view override returns (uint256) {
        StrategyData storage S = _strategyStorage();
        if (receiver == S.dragonRouter) {
            return 0;
        }
        return super.maxDeposit(receiver);
    }

    /**
     * @notice Get the maximum amount of shares that can be minted by a user
     * @dev Returns 0 for dragon router as they cannot mint
     * @param receiver The address that would receive the shares
     * @return The maximum mint amount
     */
    function maxMint(address receiver) public view override returns (uint256) {
        StrategyData storage S = _strategyStorage();
        if (receiver == S.dragonRouter) {
            return 0;
        }
        return super.maxMint(receiver);
    }

    /**
     * @notice Get the maximum amount of assets that can be withdrawn by a user
     * @dev Returns 0 for dragon router during insolvency
     * @param owner The address whose shares would be burned
     * @return The maximum withdraw amount
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

        return baseMaxWithdraw;
    }

    /**
     * @notice Get the maximum amount of shares that can be redeemed by a user
     * @dev Returns 0 for dragon router during insolvency
     * @param owner The address whose shares would be burned
     * @return The maximum redeem amount
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        StrategyData storage S = _strategyStorage();

        // Get base max redeem from parent
        uint256 baseMaxRedeem = super.maxRedeem(owner);

        // Apply dragon-specific restrictions
        if (owner == S.dragonRouter) {
            uint256 dragonMaxRedeem = _maxDragonRedeemableShares();
            return Math.min(baseMaxRedeem, dragonMaxRedeem);
        }

        return baseMaxRedeem;
    }

    /**
     * @notice Get the total ETH value debt owed to users
     * @return The total user debt in asset value
     */
    function getTotalUserDebtInAssetValue() external view returns (uint256) {
        return _strategyYieldSkimmingStorage().totalUserDebtInAssetValue;
    }

    /**
     * @notice Get the total ETH value debt owed to dragon router
     * @return The total dragon router debt in asset value
     */
    function getDragonRouterDebtInAssetValue() external view returns (uint256) {
        return _strategyYieldSkimmingStorage().dragonRouterDebtInAssetValue;
    }

    /**
     * @notice Get the total ETH value debt owed to both users and dragon router combined
     * @return The total debt in asset value (users + dragon router)
     */
    function getTotalValueDebtInAssetValue() external view returns (uint256) {
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();
        return YS.totalUserDebtInAssetValue + YS.dragonRouterDebtInAssetValue;
    }

    /**
     * @notice Transfer shares with dragon solvency protection
     * @dev Allows dragon transfers when solvent, blocks during insolvency
     * @param to The address to transfer shares to
     * @param amount The amount of shares to transfer
     * @return success Whether the transfer succeeded
     */
    function transfer(address to, uint256 amount) external override returns (bool success) {
        StrategyData storage S = _strategyStorage();

        // Prevent dragon router from transferring to itself
        if (msg.sender == S.dragonRouter && to == S.dragonRouter) {
            revert("Dragon cannot transfer to itself");
        }

        // Handle debt rebalancing when dragon is involved
        if (msg.sender == S.dragonRouter || to == S.dragonRouter) {
            _rebalanceDebtOnDragonTransfer(msg.sender, to, amount);
        }

        // Use base contract logic for actual transfer
        _transfer(S, msg.sender, to, amount);

        _requireDragonSolvency(msg.sender);

        return true;
    }

    /**
     * @notice Transfer shares from one address to another with dragon solvency protection
     * @dev Allows dragon transfers when solvent, blocks during insolvency
     * @param from The address to transfer shares from
     * @param to The address to transfer shares to
     * @param amount The amount of shares to transfer
     * @return success Whether the transfer succeeded
     */
    function transferFrom(address from, address to, uint256 amount) external override returns (bool success) {
        StrategyData storage S = _strategyStorage();

        // Prevent dragon router from transferring to itself
        if (from == S.dragonRouter && to == S.dragonRouter) {
            revert("Dragon cannot transfer to itself");
        }

        // Handle debt rebalancing when dragon is involved
        if (from == S.dragonRouter || to == S.dragonRouter) {
            _rebalanceDebtOnDragonTransfer(from, to, amount);
        }

        // Use base contract logic for actual transfer
        _spendAllowance(S, from, msg.sender, amount);
        _transfer(S, from, to, amount);

        _requireDragonSolvency(from);

        return true;
    }

    /**
     * @inheritdoc TokenizedStrategy
     * @dev Overrides report to handle yield appreciation and loss recovery using value debt approach.
     *
     * Health check effectiveness depends on report() frequency. Exchange rate checks
     * become less effective over time if reports are infrequent, as profit limits may be exceeded.
     * Management should ensure regular reporting or adjust profit/loss ratios based on expected frequency.
     *
     * Key behaviors:
     * 1. **Value Debt Tracking**: Compares current total value (assets * exchange rate) vs total debt (user debt + dragon router debt combined)
     * 2. **Profit Capture**: When current value exceeds total debt, mints shares to dragonRouter and increases dragon debt accordingly
     * 3. **Loss Protection**: When current value is less than total debt, burns dragon shares (up to available balance) and reduces dragon debt
     * 4. **Insolvency Handling**: If dragon buffer insufficient for losses, remaining shortfall is handled through proportional asset distribution during withdrawals, not by modifying debt balances
     *
     * @return profit The profit in assets (converted from underlying asset value appreciation)
     * @return loss The loss in assets (converted from underlying asset value depreciation)
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
        // Compare current value to user debt only (dragon shares are pure profit buffer)

        if (currentValue > YS.totalUserDebtInAssetValue + YS.dragonRouterDebtInAssetValue) {
            // Yield captured! Mint profit shares to dragon
            uint256 profitValue = currentValue - YS.totalUserDebtInAssetValue - YS.dragonRouterDebtInAssetValue;

            uint256 profitShares = profitValue; // 1 share = 1 ETH value

            // Convert profit value to assets for reporting
            profit = profitValue.mulDiv(WadRayMath.RAY, currentRate);

            _mint(S, S.dragonRouter, profitShares);

            // update the dragon value debt
            YS.dragonRouterDebtInAssetValue += profitValue;

            emit DonationMinted(S.dragonRouter, profitShares, currentRate.rayToWad());
        } else if (currentValue < YS.totalUserDebtInAssetValue + YS.dragonRouterDebtInAssetValue) {
            // Loss - burn dragon shares first
            uint256 lossValue = YS.totalUserDebtInAssetValue + YS.dragonRouterDebtInAssetValue - currentValue;

            // Handle loss protection through dragon burning
            loss = _handleDragonLossProtection(S, YS, lossValue, currentRate);
        }

        // Update last report timestamp
        S.lastReport = uint96(block.timestamp);
        YS.lastReportedRate = currentRate;
        emit Harvest(msg.sender, currentRate.rayToWad());
        emit Reported(profit, loss);

        return (profit, loss);
    }

    /**
     * @notice Get the last reported rate
     * @return The last reported rate
     */
    function getLastRateRay() external view returns (uint256) {
        return _strategyYieldSkimmingStorage().lastReportedRate;
    }

    /**
     * @notice Check if the vault is currently insolvent
     * @return isInsolvent True if vault cannot cover user value debt and dragon router debt
     */
    function isVaultInsolvent() external view returns (bool) {
        return _isVaultInsolvent();
    }

    /**
     * @dev Internal deposit function that handles asset transfers and share minting
     * @param S The strategy data storage
     * @param receiver The address that will receive the minted shares
     * @param assets The amount of assets being deposited
     * @param shares The amount of shares to mint
     */
    function _deposit(StrategyData storage S, address receiver, uint256 assets, uint256 shares) internal override {
        // Cache storage variables used more than once.
        ERC20 _asset = S.asset;

        _asset.safeTransferFrom(msg.sender, address(this), assets);

        // We can deploy the full loose balance currently held.
        IBaseStrategy(address(this)).deployFunds(_asset.balanceOf(address(this)));

        // Adjust total Assets.
        S.totalAssets += assets;

        // mint shares
        _mint(S, receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @dev Converts assets to shares using value debt approach with solvency awareness
     * @param S Strategy storage
     * @param assets The amount of assets to convert
     * @param rounding The rounding mode for division
     * @return The amount of shares (1 share = 1 ETH value)
     */
    function _convertToShares(
        StrategyData storage S,
        uint256 assets,
        Math.Rounding rounding
    ) internal view virtual override returns (uint256) {
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
     * @param shares The amount of shares to convert
     * @param rounding The rounding mode for division
     * @return The amount of assets user would actually receive
     */
    function _convertToAssets(
        StrategyData storage S,
        uint256 shares,
        Math.Rounding rounding
    ) internal view virtual override returns (uint256) {
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
     * @dev Rebalances debt tracking when dragon transfers shares in or out
     */
    function _rebalanceDebtOnDragonTransfer(address from, address to, uint256 transferAmount) internal {
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();
        StrategyData storage S = _strategyStorage();

        // Direct transfer: shares represent ETH value 1:1 in this system
        if (from == S.dragonRouter) {
            // Dragon sends shares: dragon loses debt obligation, users gain debt obligation
            require(YS.dragonRouterDebtInAssetValue >= transferAmount, "Insufficient dragon debt");
            YS.dragonRouterDebtInAssetValue -= transferAmount;
            YS.totalUserDebtInAssetValue += transferAmount;
        } else if (to == S.dragonRouter) {
            // User sends shares to dragon: users lose debt obligation, dragon gains debt obligation
            require(YS.totalUserDebtInAssetValue >= transferAmount, "Insufficient user debt");
            YS.totalUserDebtInAssetValue -= transferAmount;
            YS.dragonRouterDebtInAssetValue += transferAmount;
        }
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
     * @dev Blocks all operations when vault is insolvent
     */
    function _requireVaultSolvency() internal view {
        if (_isVaultInsolvent()) {
            revert("Cannot operate when vault is insolvent");
        }
    }

    /**
     * @dev Get the current exchange rate scaled to RAY precision
     * @return The current exchange rate in RAY format (1e27)
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
     * @dev Internal function to handle loss protection by burning dragon shares
     * @param S Strategy storage pointer
     * @param YS Yield skimming storage pointer
     * @param lossValue The loss amount in ETH value terms
     * @param currentRate The current exchange rate in RAY format
     * @return loss The loss amount in asset terms for reporting
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

            // update the dragon value debt
            YS.dragonRouterDebtInAssetValue -= dragonBurn;

            emit DonationBurned(S.dragonRouter, dragonBurn, currentRate.rayToWad());
        }
    }

    /**
     * @notice Finalizes the dragon router change with proper debt accounting migration
     * @dev Migrates debt tracking when dragon router changes to maintain correct accounting
     */
    function finalizeDragonRouterChange() external override {
        StrategyData storage S = _strategyStorage();
        YieldSkimmingStorage storage YS = _strategyYieldSkimmingStorage();

        require(S.pendingDragonRouter != address(0), "no pending change");
        require(block.timestamp >= S.dragonRouterChangeTimestamp + DRAGON_ROUTER_COOLDOWN, "cooldown not elapsed");

        address oldDragonRouter = S.dragonRouter;
        address newDragonRouter = S.pendingDragonRouter;

        // Get balances before changing the router
        uint256 oldDragonBalance = _balanceOf(S, oldDragonRouter);
        uint256 newDragonBalance = _balanceOf(S, newDragonRouter);

        // Migrate debt accounting:
        // 1. Old dragon router's balance becomes user debt
        if (oldDragonBalance > 0) {
            YS.totalUserDebtInAssetValue += oldDragonBalance;
            if (YS.dragonRouterDebtInAssetValue >= oldDragonBalance) {
                YS.dragonRouterDebtInAssetValue -= oldDragonBalance;
            } else {
                YS.dragonRouterDebtInAssetValue = 0;
            }
        }

        // 2. New dragon router's balance (if any) becomes dragon debt
        if (newDragonBalance > 0) {
            YS.dragonRouterDebtInAssetValue += newDragonBalance;
            if (YS.totalUserDebtInAssetValue >= newDragonBalance) {
                YS.totalUserDebtInAssetValue -= newDragonBalance;
            } else {
                YS.totalUserDebtInAssetValue = 0;
            }
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
