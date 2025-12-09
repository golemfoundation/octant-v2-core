// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title IPSM
 * @author Dai Foundation; modified by [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @custom:origin https://github.com/sky-ecosystem/dss-psm
 * @notice Interface for MakerDAO Peg Stability Module (PSM)
 * @dev Used for stable swaps between DAI and other stablecoins at a fixed 1:1 rate with fees
 *      PSM allows instant conversion with configurable fees (tin/tout)
 */
interface IPSM {
    /// @notice Sell gem tokens to receive DAI
    /// @param usr Address to receive the DAI
    /// @param gemAmt Amount of gem tokens to sell in gem token base units
    function sellGem(address usr, uint256 gemAmt) external;

    /// @notice Buy gem tokens with DAI
    /// @param usr Address to receive the gem tokens
    /// @param gemAmt Amount of gem tokens to buy in gem token base units
    function buyGem(address usr, uint256 gemAmt) external;

    /// @notice Returns the fee charged when selling gem tokens (fee-in)
    /// @return Fee in basis points (e.g., 100 = 1%)
    function tin() external view returns (uint256);

    /// @notice Returns the fee charged when buying gem tokens (fee-out)
    /// @return Fee in basis points (e.g., 100 = 1%)
    function tout() external view returns (uint256);
}

/**
 * @title IExchange
 * @author Dai Foundation (Sky Protocol); modified by [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @custom:origin https://github.com/sky-ecosystem/usds
 * @notice Interface for DAI/USDS exchange contract
 * @dev Bidirectional conversion between DAI and USDS at 1:1 rate
 *      Part of Sky Protocol's upgrade path from DAI to USDS
 */
interface IExchange {
    /// @notice Convert DAI to USDS at 1:1 rate
    /// @param usr Address to receive the USDS
    /// @param wad Amount of DAI to convert in DAI base units (18 decimals)
    function daiToUsds(address usr, uint256 wad) external;

    /// @notice Convert USDS to DAI at 1:1 rate
    /// @param usr Address to receive the DAI
    /// @param wad Amount of USDS to convert in USDS base units (18 decimals)
    function usdsToDai(address usr, uint256 wad) external;
}
