// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { BaseYieldSkimmingHealthCheck } from "src/strategies/periphery/BaseYieldSkimmingHealthCheck.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title BaseYieldSkimmingStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Abstract base for yield skimming strategies tracking exchange rate appreciation
 * @dev Extends BaseYieldSkimmingHealthCheck with common logic for appreciating assets
 *
 *      STRATEGY PATTERN:
 *      - Assets appreciate via exchange rate (e.g., stETH, rETH)
 *      - No active deployment needed (assets appreciate in place)
 *      - Harvest simply reports current value based on rate
 *      - Derived contracts implement _getCurrentExchangeRate()
 *
 *      MINIMAL IMPLEMENTATION REQUIRED:
 *      ```solidity
 *      function _getCurrentExchangeRate() internal view override returns (uint256) {
 *          // Return current rate from yield source
 *          return yieldSource.getExchangeRate();
 *      }
 *
 *      function decimalsOfExchangeRate() public view override returns (uint256) {
 *          return 18; // or whatever precision the rate uses
 *      }
 *      ```
 *
 *      EXAMPLES:
 *      - LidoStrategy: Uses stETH/ETH exchange rate
 *      - RocketPoolStrategy: Uses rETH/ETH exchange rate
 *
 * @custom:security Exchange rate must be manipulation-resistant
 */
abstract contract BaseYieldSkimmingStrategy is BaseYieldSkimmingHealthCheck {
    using SafeERC20 for IERC20;

    constructor(
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    )
        BaseYieldSkimmingHealthCheck(
            _asset,
            _name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        )
    {}

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Returns current asset balance held by strategy
     * @dev For skimming strategies, this is typically the full balance as nothing is deployed
     * @return balance Asset balance in asset base units
     */
    function balanceOfAsset() public view returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /**
     * @notice Returns current exchange rate from yield source
     * @dev Public wrapper for _getCurrentExchangeRate()
     * @return rate Current exchange rate (in decimals specified by decimalsOfExchangeRate())
     */
    function getCurrentExchangeRate() public view returns (uint256) {
        return _getCurrentExchangeRate();
    }

    /**
     * @notice Returns decimal precision of exchange rate
     * @dev Must be implemented by derived contracts
     * @return decimals Number of decimals used by exchange rate (e.g., 18, 27)
     */
    function decimalsOfExchangeRate() public view virtual returns (uint256);

    // ============================================
    // REQUIRED OVERRIDES - NO-OP FOR SKIMMING
    // ============================================

    /**
     * @notice No-op for skimming strategies
     * @dev Assets appreciate in place, no deployment needed
     * @param _amount Amount requested to deploy (ignored)
     */
    function _deployFunds(uint256 _amount) internal override {
        // No action needed - assets appreciate via exchange rate
    }

    /**
     * @notice No-op for skimming strategies
     * @dev Assets already liquid, no withdrawal needed
     * @param _amount Amount requested to free (ignored)
     */
    function _freeFunds(uint256 _amount) internal override {
        // No action needed - assets are always liquid
    }

    /**
     * @notice Reports current asset value based on exchange rate
     * @dev Simply returns current totalAssets (appreciation already reflected)
     *      No active harvesting needed - value increases automatically
     * @return _totalAssets Current total assets (idle balance for skimming strategies)
     */
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        // Return the actual balance of assets held by this strategy
        _totalAssets = IERC4626(address(this)).totalAssets();
    }

    /**
     * @notice Returns current exchange rate from yield source
     * @dev Must be implemented by derived contracts (e.g., Lido, RocketPool)
     *      Should return manipulation-resistant rate from trusted source
     * @return rate Current exchange rate (in decimals specified by decimalsOfExchangeRate())
     */
    function _getCurrentExchangeRate() internal view virtual returns (uint256);
}
