// SPDX-License-Identifier: AGPL-3.0-or-later

pragma solidity ^0.8.25;

import { ITransformer } from "./ITransformer.sol";
import { ISplitChecker } from "./ISplitChecker.sol";
/**
 * @title IDragonRouter
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for DragonRouter - yield distribution and split management module
 * @dev Zodiac module that receives strategy yields, splits them per configured allocations,
 *      and enables users to claim with optional token transformation
 *
 *      CORE FUNCTIONALITY:
 *      - Receives profit shares from strategies (minted as shares)
 *      - Splits yield per configured Split (recipients + allocations)
 *      - Enables permissionless claims with optional swaps via transformers
 *      - Burns its own shares in strategies when losses occur (loss protection)
 *
 *      SPLIT MECHANISM:
 *      - Split defines recipients[] and allocations[] (e.g., OPEX, Metapool, GrantRounds)
 *      - fundFromSource() updates assetPerShare globally
 *      - Users claim their pro-rata share via claimSplit()
 *      - Supports multi-strategy: one router can manage multiple strategies
 *
 *      USER FEATURES:
 *      - setTransformer(): Swap claimed assets via ITransformer (e.g., DAI → ETH)
 *      - setClaimAutomation(): Allow permissionless bot claims on user's behalf
 *      - balanceOf(): Query claimable balance per strategy
 *
 *      GOVERNANCE:
 *      - Owner can add/remove strategies
 *      - Update split with cooldown protection (splitDelay)
 *      - Modify metapool, opexVault, split checker addresses
 *
 *      SECURITY:
 *      - Split changes require cooldown period (prevents rapid rug)
 *      - SplitChecker validates all splits (OPEX limits, metapool minimum)
 *      - Two-step role changes for critical addresses
 *
 * @custom:security Loss protection via strategy share burning (first-loss capital)
 * @custom:security Split validation enforced via ISplitChecker
 */
interface IDragonRouter {
    /*//////////////////////////////////////////////////////////////
                            STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct StrategyData {
        address asset;
        uint256 assetPerShare;
        uint256 totalAssets;
        uint256 totalShares;
    }

    struct UserData {
        uint256 assets;
        uint256 userAssetPerShare;
        uint256 splitPerShare;
        Transformer transformer;
        bool allowBotClaim;
    }

    struct Transformer {
        ITransformer transformer;
        address targetToken;
    }

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a strategy is added to the router
    /// @param strategy Strategy address added
    event StrategyAdded(address indexed strategy);
    /// @notice Emitted when a strategy is removed from the router
    /// @param strategy Strategy address removed
    event StrategyRemoved(address indexed strategy);
    /// @notice Emitted when metapool address is updated
    /// @param oldMetapool Previous metapool address
    /// @param newMetapool New metapool address
    event MetapoolUpdated(address oldMetapool, address newMetapool);
    /// @notice Emitted when opex vault address is updated
    /// @param oldOpexVault Previous opex vault address
    /// @param newOpexVault New opex vault address
    event OpexVaultUpdated(address oldOpexVault, address newOpexVault);
    /// @notice Emitted when cooldown period is updated
    /// @param oldPeriod Previous cooldown period in seconds
    /// @param newPeriod New cooldown period in seconds
    event CooldownPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    /// @notice Emitted when split delay is updated
    /// @param oldDelay Previous split delay in seconds
    /// @param newDelay New split delay in seconds
    event SplitDelayUpdated(uint256 oldDelay, uint256 newDelay);
    /// @notice Emitted when split checker contract is updated
    /// @param oldChecker Previous split checker address
    /// @param newChecker New split checker address
    event SplitCheckerUpdated(address oldChecker, address newChecker);
    /// @notice Emitted when user sets a transformer for their claims
    /// @param user User setting the transformer
    /// @param strategy Strategy for which transformer is set
    /// @param transformer Transformer contract address
    /// @param targetToken Token to transform into
    event UserTransformerSet(address indexed user, address indexed strategy, address transformer, address targetToken);
    /// @notice Emitted when split is claimed
    /// @param caller Address that triggered the claim
    /// @param owner Owner of the claimed split
    /// @param strategy Strategy from which split is claimed
    /// @param amount Amount claimed in asset base units
    event SplitClaimed(address indexed caller, address indexed owner, address indexed strategy, uint256 amount);
    /// @notice Emitted when user toggles claim automation
    /// @param user User toggling automation
    /// @param strategy Strategy for which automation is toggled
    /// @param enabled Whether automation is enabled
    event ClaimAutomationSet(address indexed user, address indexed strategy, bool enabled);
    /// @notice Emitted when strategy is funded with new assets
    /// @param strategy Strategy being funded
    /// @param assetPerShare Assets per share after funding in asset base units
    /// @param totalAssets Total assets after funding in asset base units
    event Funded(address indexed strategy, uint256 assetPerShare, uint256 totalAssets);
    /// @notice Emitted when user's split data is updated
    /// @param recipient User whose split is updated
    /// @param strategy Strategy for which split is updated
    /// @param assets User's claimable assets in asset base units
    /// @param userAssetPerShare User's asset per share in asset base units
    /// @param splitPerShare Split per share
    event UserSplitUpdated(
        address indexed recipient,
        address indexed strategy,
        uint256 assets,
        uint256 userAssetPerShare,
        uint256 splitPerShare
    );
    /// @notice Emitted when split configuration is set
    /// @param assetPerShare Assets per share in asset base units
    /// @param totalAssets Total assets in asset base units
    /// @param totalShares Total shares in share base units
    /// @param lastSetSplitTime Timestamp when split was last set
    event SplitSet(uint256 assetPerShare, uint256 totalAssets, uint256 totalShares, uint256 lastSetSplitTime);

    /*//////////////////////////////////////////////////////////////
                            CUSTOM ERRORS
    //////////////////////////////////////////////////////////////*/

    error AlreadyAdded();
    error StrategyNotDefined();
    error InvalidAmount();
    error ZeroAddress();
    error ZeroAssetAddress();
    error NoShares();
    error CooldownPeriodNotPassed();
    error TransferFailed();
    error NotAllowed();

    /*//////////////////////////////////////////////////////////////
                            FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds a new strategy to the router
     * @param _strategy Strategy address to add
     */
    function addStrategy(address _strategy) external;

    /**
     * @notice Removes a strategy from the router
     * @param _strategy Strategy address to remove
     */
    function removeStrategy(address _strategy) external;

    /**
     * @notice Updates the metapool address
     * @param _metapool New metapool address
     */
    function setMetapool(address _metapool) external;

    /**
     * @notice Updates the opex vault address
     * @param _opexVault New opex vault address
     */
    function setOpexVault(address _opexVault) external;

    /**
     * @notice Updates the split delay
     * @param _splitDelay Split delay in seconds
     */
    function setSplitDelay(uint256 _splitDelay) external;

    /**
     * @notice Updates the split checker contract address
     * @param _splitChecker Split checker contract address
     */
    function setSplitChecker(address _splitChecker) external;

    /**
     * @notice Allows a user to set their transformer for split withdrawals
     * @param strategy Strategy address to set transformer for
     * @param transformer Transformer contract address
     * @param targetToken Token address to transform into
     */
    function setTransformer(address strategy, address transformer, address targetToken) external;

    /**
     * @notice Allows a user to enable/disable permissionless claims on their behalf
     * @param strategy Strategy address to configure
     * @param enable True to allow bot claims, false to restrict to user only
     */
    function setClaimAutomation(address strategy, bool enable) external;

    /**
     * @notice Updates the cooldown period
     * @param _cooldownPeriod Cooldown period in seconds
     */
    function setCooldownPeriod(uint256 _cooldownPeriod) external;

    /**
     * @notice Distributes new splits to all shareholders
     * @param strategy Strategy address to fund from
     * @param amount Amount of tokens to distribute in asset base units
     */
    function fundFromSource(address strategy, uint256 amount) external;

    /**
     * @notice Sets the split for the router
     * @param _split Split configuration (recipients and allocations)
     */
    function setSplit(ISplitChecker.Split memory _split) external;

    /**
     * @notice Initializer function, triggered when a new proxy is deployed
     * @param initializeParams Parameters of initialization encoded
     */
    function setUp(bytes memory initializeParams) external;

    /**
     * @notice Allows claiming available split with optional transformation
     * @param _user User address to claim for
     * @param _strategy Strategy address to claim from
     * @param _amount Amount to claim in asset base units
     */
    function claimSplit(address _user, address _strategy, uint256 _amount) external;

    /**
     * @notice Returns the balance of a user for a given strategy
     * @param _user User address
     * @param _strategy Strategy address
     * @return User balance for the strategy in asset base units
     */
    function balanceOf(address _user, address _strategy) external view returns (uint256);
}
