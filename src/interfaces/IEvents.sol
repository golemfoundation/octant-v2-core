// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title IEvents
 * @author Yearn.finance; adapted by [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Standard events for strategy and vault operations
 * @dev Shared event definitions across strategy implementations
 * @custom:origin https://github.com/yearn/tokenized-strategy/blob/master/src/interfaces/IEvents.sol
 */
interface IEvents {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a strategy is shutdown
    event StrategyShutdown();

    /**
     * @notice Emitted on the initialization of any new strategy
     * @param strategy Address of the newly initialized strategy
     * @param asset Address of the underlying asset
     * @param apiVersion API version string of the strategy
     */
    event NewTokenizedStrategy(address indexed strategy, address indexed asset, string apiVersion);

    /**
     * @notice Emitted when the strategy reports profit or loss with fee distribution
     * @param profit Profit generated
     * @param loss Loss incurred
     * @param protocolFees Protocol fees paid
     * @param performanceFees Performance fees paid
     */
    event Reported(uint256 profit, uint256 loss, uint256 protocolFees, uint256 performanceFees);

    /**
     * @notice Emitted when the performance fee recipient address is updated
     * @param newPerformanceFeeRecipient New performance fee recipient address
     */
    event UpdatePerformanceFeeRecipient(address indexed newPerformanceFeeRecipient);

    /**
     * @notice Emitted when the keeper address is updated
     * @param newKeeper New keeper address
     */
    event UpdateKeeper(address indexed newKeeper);

    /**
     * @notice Emitted when the performance fee is updated
     * @param newPerformanceFee New performance fee in basis points
     */
    event UpdatePerformanceFee(uint16 newPerformanceFee);

    /**
     * @notice Emitted when the management address is updated
     * @param newManagement New management address
     */
    event UpdateManagement(address indexed newManagement);

    /**
     * @notice Emitted when the emergency admin address is updated
     * @param newEmergencyAdmin New emergency admin address
     */
    event UpdateEmergencyAdmin(address indexed newEmergencyAdmin);

    /**
     * @notice Emitted when the profit max unlock time is updated
     * @param newProfitMaxUnlockTime New profit unlock time in seconds
     */
    event UpdateProfitMaxUnlockTime(uint256 newProfitMaxUnlockTime);

    /**
     * @notice Emitted when the pending management address is updated
     * @param newPendingManagement New pending management address
     */
    event UpdatePendingManagement(address indexed newPendingManagement);

    /**
     * @notice Emitted when the allowance of a spender for an owner is set
     * @param owner Address of the token owner
     * @param spender Address of the spender
     * @param value New allowance amount
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @notice Emitted when tokens are moved from one account to another
     * @param from Address tokens are transferred from
     * @param to Address tokens are transferred to
     * @param value Amount of tokens transferred
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @notice Emitted when caller has exchanged assets for shares
     * @param caller Address that initiated the deposit
     * @param owner Address that receives the shares
     * @param assets Amount of assets deposited
     * @param shares Amount of shares minted
     */
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);

    /**
     * @notice Emitted when caller has exchanged shares for assets
     * @param caller Address that initiated the withdrawal
     * @param receiver Address that receives the assets
     * @param owner Address whose shares are burned
     * @param assets Amount of assets withdrawn
     * @param shares Amount of shares burned
     */
    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
}
