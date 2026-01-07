// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.25;

import { BaseYieldSkimmingStrategy } from "src/strategies/yieldSkimming/BaseYieldSkimmingStrategy.sol";

interface IWstETH {
    /// @notice Returns the amount of stETH per wstETH token
    function stEthPerToken() external view returns (uint256);
}

/**
 * @title LidoStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Yield skimming strategy for Lido wstETH (wrapped staked ETH)
 * @dev Captures yield from stETH appreciation by tracking wstETH exchange rate
 *
 *      LIDO MECHANISM:
 *      - wstETH is a wrapper around rebasing stETH
 *      - Exchange rate: wstETH → stETH increases as staking rewards accrue
 *      - 1 wstETH = stEthPerToken() stETH
 *      - Rate increases ~3-5% annually from ETH staking rewards
 *
 *      YIELD CAPTURE:
 *      - User deposits 100 wstETH at rate 1.0
 *      - Rate increases to 1.05 (5% staking rewards)
 *      - Vault value: 105 stETH
 *      - Profit: Strategy shares worth 5 stETH value minted to dragon router
 *
 *      EXCHANGE RATE SOURCE:
 *      - Calls wstETH.stEthPerToken()
 *      - Oracle-free (uses Lido's accounting)
 *      - Cannot be manipulated
 *      - 18 decimal precision
 *
 * @custom:security Exchange rate from Lido wstETH (trusted source)
 * @custom:security Slashing risk: ETH validators can be slashed, reducing rate
 */
contract LidoStrategy is BaseYieldSkimmingStrategy {
    /**
     * @param _asset Address of the underlying asset (wstETH)
     * @param _name Strategy name
     * @param _symbol Strategy symbol
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
        string memory _symbol,
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
            _symbol,
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
     * @dev wstETH uses 18 decimal precision for stEthPerToken()
     * @return decimals Always returns 18
     */
    function decimalsOfExchangeRate() public pure override returns (uint256) {
        return 18;
    }

    /**
     * @notice Returns current wstETH → stETH exchange rate
     * @dev Queries Lido's wstETH contract for current rate
     *      Rate increases as staking rewards accrue to stETH
     * @return rate Amount of stETH per 1 wstETH (18 decimal precision)
     * @custom:security Rate from Lido protocol (manipulation-resistant)
     */
    function _getCurrentExchangeRate() internal view override returns (uint256) {
        // Call the stEthPerToken function on the wstETH contract
        return IWstETH(address(asset)).stEthPerToken();
    }
}
