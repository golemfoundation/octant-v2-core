// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.25;

interface IPool {
    /// @notice Supplies an asset to the Aave pool
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    /// @notice Withdraws an asset from the Aave pool
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    /// @notice Returns the projected liquidity index for a reserve, accounting for the
    ///         accrual since `lastUpdateTimestamp` - this is the `nextLiquidityIndex`
    ///         Aave's own `validateSupply` uses, so it matches the cap check exactly.
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}

/// @dev Slim view of `IPoolDataProvider.getReserveData` that only decodes the first
///      three return slots (`unbacked`, `accruedToTreasuryScaled`, `totalAToken`).
///      The cap path needs only `accruedToTreasuryScaled` and `totalAToken`; reading
///      the full 12-slot tuple trips a stack-too-deep on the ABI decoder under the
///      `forge coverage` build profile (viaIR + optimizer disabled). Same underlying
///      contract, narrower signature.
interface IPoolDataProviderSlim {
    /// @notice Returns the first three reserve data fields needed for supply-cap accounting
    function getReserveData(
        address asset
    ) external view returns (uint256 unbacked, uint256 accruedToTreasuryScaled, uint256 totalAToken);
}

interface IPoolDataProvider {
    /// @notice Returns the supply and borrow caps for a reserve
    function getReserveCaps(address asset) external view returns (uint256 borrowCap, uint256 supplyCap);

    /// @notice Returns the total aToken supply for a specific asset
    function getATokenTotalSupply(address asset) external view returns (uint256);

    /// @notice Returns the token addresses of a reserve
    function getReserveTokensAddresses(
        address asset
    ) external view returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress);

    /// @notice Returns reserve configuration flags including isActive and isFrozen
    function getReserveConfigurationData(
        address asset
    )
        external
        view
        returns (
            uint256 decimals,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus,
            uint256 reserveFactor,
            bool usageAsCollateralEnabled,
            bool borrowingEnabled,
            bool stableBorrowRateEnabled,
            bool isActive,
            bool isFrozen
        );

    /// @notice Returns whether the reserve is paused (governance/risk admin emergency switch)
    function getPaused(address asset) external view returns (bool);

    /// @notice Returns full reserve data including totalAToken and accruedToTreasuryScaled.
    /// @dev `accruedToTreasuryScaled` is treasury-bound reserve that consumes supply-cap
    ///      headroom in `ValidationLogic.validateSupply` but is missing from
    ///      `getATokenTotalSupply`. We add it conservatively to the cap denominator.
    function getReserveData(
        address asset
    )
        external
        view
        returns (
            uint256 unbacked,
            uint256 accruedToTreasuryScaled,
            uint256 totalAToken,
            uint256 totalStableDebt,
            uint256 totalVariableDebt,
            uint256 liquidityRate,
            uint256 variableBorrowRate,
            uint256 stableBorrowRate,
            uint256 averageStableBorrowRate,
            uint256 liquidityIndex,
            uint256 variableBorrowIndex,
            uint40 lastUpdateTimestamp
        );
}

interface IPoolAddressesProvider {
    /// @notice Returns the address of the Pool contract
    function getPool() external view returns (address);
    /// @notice Returns the address of the PoolDataProvider contract
    function getPoolDataProvider() external view returns (address);
}
