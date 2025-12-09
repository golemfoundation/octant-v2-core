// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { BaseYieldSkimmingStrategy } from "src/strategies/yieldSkimming/BaseYieldSkimmingStrategy.sol";

interface IRocketPool {
    /// @notice Returns the rETH to ETH exchange rate
    function getExchangeRate() external view returns (uint256);
}

/**
 * @title RocketPoolStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Yield skimming strategy for RocketPool rETH
 * @dev Captures yield from rETH appreciation by tracking rETH/ETH exchange rate
 *
 *      ROCKETPOOL MECHANISM:
 *      - rETH represents staked ETH in RocketPool protocol
 *      - Exchange rate: rETH → ETH increases as staking rewards accrue
 *      - Rate starts at ~1.0 and increases over time
 *      - Different from Lido: non-rebasing, rate appreciation only
 *
 *      YIELD CAPTURE:
 *      - User deposits 100 rETH at rate 1.0
 *      - Rate increases to 1.05 (5% staking rewards)
 *      - Vault value: 105 ETH
 *      - Profit: Strategy shares worth 5 ETH value minted to dragon router
 *
 *      EXCHANGE RATE SOURCE:
 *      - Calls RocketPool.getExchangeRate()
 *      - Based on RocketPool's accounting
 *      - Cannot be manipulated
 *      - 18 decimal precision
 *
 * @custom:security Exchange rate from RocketPool (trusted source)
 * @custom:security Slashing risk: Validators can be slashed, affecting rate
 */
contract RocketPoolStrategy is BaseYieldSkimmingStrategy {
    /**
     * @param _asset Address of the underlying asset
     * @param _name Strategy name
     * @param _management Address with management role
     * @param _keeper Address with keeper role
     * @param _emergencyAdmin Address with emergency admin role
     * @param _donationAddress Address that receives donated/minted yield
     * @param _enableBurning Whether loss-protection burning from donation address is enabled
     * @param _tokenizedStrategyAddress Address of TokenizedStrategy implementation
     */
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
        BaseYieldSkimmingStrategy(
            _asset, // shares address
            _name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        )
    {}

    /**
     * @notice Returns exchange rate precision (18 decimals)
     * @dev RocketPool uses 18 decimal precision for exchange rate
     * @return decimals Always returns 18
     */
    function decimalsOfExchangeRate() public pure override returns (uint256) {
        return 18;
    }

    /**
     * @notice Returns current rETH → ETH exchange rate
     * @dev Queries RocketPool protocol for current rate
     *      Rate increases as staking rewards accrue
     * @return rate Amount of ETH per 1 rETH (18 decimal precision)
     * @custom:security Rate from RocketPool protocol (manipulation-resistant)
     */
    function _getCurrentExchangeRate() internal view override returns (uint256) {
        // Call the getExchangeRate function on the RocketPool contract
        return IRocketPool(address(asset)).getExchangeRate();
    }
}
