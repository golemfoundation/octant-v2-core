// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title IBaseStrategy (Zodiac Core)
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for strategy lifecycle hooks in zodiac-core variant
 * @dev Defines callbacks required by zodiac TokenizedStrategy implementation
 *
 *      LIFECYCLE FLOW:
 *      1. deployFunds() - Called when strategy receives assets
 *      2. tendThis() - Periodic maintenance without harvesting
 *      3. harvestAndReport() - Harvest rewards and report profit/loss
 *      4. adjustPosition() - Rebalance after report
 *      5. liquidatePosition() - Free assets for withdrawals
 *      6. shutdownWithdraw() - Emergency withdrawal when shutdown
 */
interface IBaseStrategy {
    /*//////////////////////////////////////////////////////////////
                            STRATEGY ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy assets into the underlying protocol
    /// @param _assets Amount of assets to deploy in asset base units
    function deployFunds(uint256 _assets) external;

    /// @notice Free a specific amount of assets from the underlying protocol
    /// @param _amount Amount of assets to free in asset base units
    function freeFunds(uint256 _amount) external;

    /// @notice Perform non-harvest maintenance on the strategy position
    /// @param _totalIdle Current idle assets in the strategy in asset base units
    function tendThis(uint256 _totalIdle) external;

    /// @notice Emergency withdrawal during strategy shutdown
    /// @param _amount Amount of assets to withdraw in asset base units
    function shutdownWithdraw(uint256 _amount) external;

    /// @notice Adjust strategy position to meet debt requirements
    /// @param _debtOutstanding Amount of debt to repay in asset base units
    function adjustPosition(uint256 _debtOutstanding) external;

    /// @notice Liquidate position to free assets for withdrawal
    /// @param _amountNeeded Amount of assets needed in asset base units
    /// @return _liquidatedAmount Actual amount liquidated in asset base units
    /// @return _loss Loss incurred during liquidation in asset base units
    function liquidatePosition(uint256 _amountNeeded) external returns (uint256 _liquidatedAmount, uint256 _loss);

    /// @notice Harvest rewards and report total assets
    /// @return Total assets under management in asset base units
    function harvestAndReport() external returns (uint256);

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the target address for this strategy (usually a vault or protocol)
    /// @return Target protocol address
    function target() external view returns (address);

    /// @notice Get the tokenized strategy wrapper address
    /// @return TokenizedStrategy wrapper address
    function tokenizedStrategyAddress() external view returns (address);

    /// @notice Get the strategy owner address
    /// @return Owner address
    function owner() external view returns (address);

    /// @notice Get the avatar (Gnosis Safe) address if applicable
    /// @return Avatar address
    function avatar() external view returns (address);

    /// @notice Get maximum delay between harvest reports
    /// @return Maximum report delay in seconds
    function maxReportDelay() external view returns (uint256);

    /// @notice Get the TokenizedStrategy implementation address
    /// @return Implementation address
    function tokenizedStrategyImplementation() external view returns (address);

    /// @notice Get available deposit limit for an owner
    /// @param _owner Address to check deposit limit for
    /// @return Available deposit limit in asset base units
    function availableDepositLimit(address _owner) external view returns (uint256);

    /// @notice Get available withdrawal limit for an owner
    /// @param _owner Address to check withdrawal limit for
    /// @return Available withdrawal limit in asset base units
    function availableWithdrawLimit(address _owner) external view returns (uint256);

    /// @notice Check if harvest should be called
    /// @return True if harvest should be triggered
    function harvestTrigger() external view returns (bool);

    /// @notice Check if tend should be called
    /// @return shouldTend True if tend should be triggered
    /// @return callData Optional calldata for tend operation
    function tendTrigger() external view returns (bool shouldTend, bytes memory callData);
}
