// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC4626Payable } from "./IERC4626Payable.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IHats } from "./IHats.sol";

/**
 * @title ITokenizedStrategy (Zodiac Core)
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for Zodiac-integrated tokenized strategies with Hats Protocol roles
 * @dev Combines ERC4626Payable, ERC20Permit with Zodiac and Hats-specific functionality
 */
interface ITokenizedStrategy is IERC4626Payable, IERC20Permit {
    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Information about a user's share lockup
    /// @param lockupTime Timestamp when shares were locked (seconds)
    /// @param unlockTime Timestamp when shares can be unlocked (seconds)
    /// @param lockedShares Amount of shares locked in share base units
    /// @param isRageQuit True if this is a rage quit lockup (emergency exit)
    struct LockupInfo {
        uint256 lockupTime;
        uint256 unlockTime;
        uint256 lockedShares;
        bool isRageQuit;
    }

    /// @notice Complete storage structure for a tokenized strategy
    /// @dev Stored at BASE_STRATEGY_STORAGE slot to prevent collisions
    /// @param asset ERC20 underlying asset used by the strategy
    /// @param operator Address authorized for Safe module operations (Zodiac)
    /// @param dragonRouter Address receiving profit shares (donation address)
    /// @param decimals Number of decimals for strategy shares (matches asset)
    /// @param name Strategy share token name (ERC20 metadata)
    /// @param totalSupply Total strategy shares issued (ERC20)
    /// @param nonces EIP-2612 permit nonces per address
    /// @param balances Strategy share balances per address (ERC20)
    /// @param allowances ERC20 allowances: owner => spender => amount
    /// @param voluntaryLockups Lockup information per user address
    /// @param totalAssets Total assets managed (prevents PPS manipulation via airdrops)
    /// @param keeper Address authorized to call report() and tend()
    /// @param lastReport Timestamp of last report() call (uint96 for gas savings)
    /// @param management Main admin address (sets all configurable variables)
    /// @param pendingManagement Address pending to take over management role
    /// @param emergencyAdmin Address for emergency operations (shutdown, emergency withdraw)
    /// @param entered Reentrancy guard flag (1=not entered, 2=entered)
    /// @param shutdown Strategy shutdown status (true blocks deposits)
    /// @param minimumLockupDuration Minimum time shares must be locked (seconds)
    /// @param rageQuitCooldownPeriod Cooldown period before rage quit completes (seconds)
    /// @param REGEN_GOVERNANCE Address controlling regenerative finance parameters
    /// @param HATS Hats Protocol contract for role management
    /// @param KEEPER_HAT Hats Protocol hat ID for keeper role
    /// @param MANAGEMENT_HAT Hats Protocol hat ID for management role
    /// @param EMERGENCY_ADMIN_HAT Hats Protocol hat ID for emergency admin role
    /// @param REGEN_GOVERNANCE_HAT Hats Protocol hat ID for regen governance role
    /// @param hatsInitialized Flag indicating Hats Protocol integration is set up
    struct StrategyData {
        ERC20 asset;
        address operator;
        address dragonRouter;
        uint8 decimals;
        string name;
        uint256 totalSupply;
        mapping(address => uint256) nonces;
        mapping(address => uint256) balances;
        mapping(address => mapping(address => uint256)) allowances;
        mapping(address => LockupInfo) voluntaryLockups;
        uint256 totalAssets;
        address keeper;
        uint96 lastReport;
        address management;
        address pendingManagement;
        address emergencyAdmin;
        uint8 entered;
        bool shutdown;
        uint256 minimumLockupDuration;
        uint256 rageQuitCooldownPeriod;
        address REGEN_GOVERNANCE;
        IHats HATS;
        uint256 KEEPER_HAT;
        uint256 MANAGEMENT_HAT;
        uint256 EMERGENCY_ADMIN_HAT;
        uint256 REGEN_GOVERNANCE_HAT;
        bool hatsInitialized;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when strategy is permanently shut down
    event StrategyShutdown();

    /// @notice Emitted when a new tokenized strategy is initialized
    /// @param strategy Address of the deployed strategy
    /// @param asset Address of the underlying asset
    /// @param apiVersion API version of the strategy implementation
    event NewTokenizedStrategy(address indexed strategy, address indexed asset, string apiVersion);

    /// @notice Emitted after profit/loss reporting
    /// @param profit Profit generated in asset base units
    /// @param loss Loss incurred in asset base units
    /// @param protocolFees Protocol fees charged in asset base units
    /// @param performanceFees Performance fees charged in asset base units
    event Reported(uint256 profit, uint256 loss, uint256 protocolFees, uint256 performanceFees);

    /// @notice Emitted when keeper address is updated
    /// @param newKeeper New keeper address
    event UpdateKeeper(address indexed newKeeper);

    /// @notice Emitted when management address is updated
    /// @param newManagement New management address
    event UpdateManagement(address indexed newManagement);

    /// @notice Emitted when emergency admin address is updated
    /// @param newEmergencyAdmin New emergency admin address
    event UpdateEmergencyAdmin(address indexed newEmergencyAdmin);

    /// @notice Emitted when pending management address is set
    /// @param newPendingManagement New pending management address
    event UpdatePendingManagement(address indexed newPendingManagement);

    /**
     * @notice Emitted when Hats Protocol integration is set up
     */
    event HatsProtocolSetup(
        address indexed hats,
        uint256 indexed keeperHat,
        uint256 indexed managementHat,
        uint256 emergencyAdminHat,
        uint256 regenGovernanceHat
    );

    /*//////////////////////////////////////////////////////////////
                           INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function initialize(
        address _asset,
        string memory _name,
        address _owner,
        address _management,
        address _keeper,
        address _dragonRouter,
        address _regenGovernance
    ) external;

    /*//////////////////////////////////////////////////////////////
                        KEEPERS FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows keeper to maintain the strategy
     * @dev Can be used for operations like compounding or regular maintenance
     */
    function tend() external;

    /**
     * @notice Reports profit or loss for the strategy
     * @return _profit Amount of profit generated
     * @return _loss Amount of loss incurred
     */
    function report() external returns (uint256 _profit, uint256 _loss);

    /*//////////////////////////////////////////////////////////////
                            SETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets a new pending management address
     * @param _pendingManagement Address to become pending management
     */
    function setPendingManagement(address _pendingManagement) external;

    /**
     * @notice Allows pending management to accept and become active management
     */
    function acceptManagement() external;

    /**
     * @notice Sets a new keeper address
     * @param _keeper Address authorized to call report/tend
     */
    function setKeeper(address _keeper) external;

    /**
     * @notice Sets a new emergency admin address
     * @param _emergencyAdmin Address authorized for emergency operations
     */
    function setEmergencyAdmin(address _emergencyAdmin) external;

    /**
     * @notice Updates the strategy token name
     * @param _newName New strategy token name
     */
    function setName(string calldata _newName) external;

    /**
     * @notice Shuts down the strategy, preventing further deposits
     */
    function shutdownStrategy() external;

    /**
     * @notice Allows emergency withdrawal of assets from yield source
     * @param _amount Amount of assets to withdraw in asset base units
     */
    function emergencyWithdraw(uint256 _amount) external;

    /*//////////////////////////////////////////////////////////////
                            HATS PROTOCOL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets up Hats Protocol integration for role management
     * @dev Can only be called by management
     * @param _hats Address of Hats Protocol contract
     * @param _keeperHat Hat ID for keeper role
     * @param _managementHat Hat ID for management role
     * @param _emergencyAdminHat Hat ID for emergency admin role
     * @param _regenGovernanceHat Hat ID for regen governance role
     */
    function setupHatsProtocol(
        address _hats,
        uint256 _keeperHat,
        uint256 _managementHat,
        uint256 _emergencyAdminHat,
        uint256 _regenGovernanceHat
    ) external;

    /*//////////////////////////////////////////////////////////////
                    NON-STANDARD 4626 OPTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraws assets from the strategy, allowing a specified maximum loss
     * @param assets Amount of assets to withdraw in asset base units
     * @param receiver Address receiving withdrawn assets
     * @param owner Address whose shares are being burned
     * @param maxLoss Maximum acceptable loss in basis points (10000 = 100%)
     * @return Actual amount of shares burned in share base units
     */
    function withdraw(uint256 assets, address receiver, address owner, uint256 maxLoss) external returns (uint256);

    /**
     * @notice Redeems shares from the strategy, allowing a specified maximum loss
     * @param shares Amount of shares to redeem in share base units
     * @param receiver Address receiving withdrawn assets
     * @param owner Address whose shares are being burned
     * @param maxLoss Maximum acceptable loss in basis points (10000 = 100%)
     * @return Actual amount of assets withdrawn in asset base units
     */
    function redeem(uint256 shares, address receiver, address owner, uint256 maxLoss) external returns (uint256);

    /**
     * @notice Gets the maximum amount of assets that can be withdrawn
     * @param owner Address of share owner
     * @param maxLoss Maximum acceptable loss in basis points
     * @return Maximum assets that can be withdrawn in asset base units
     */
    function maxWithdraw(address owner, uint256 maxLoss) external view returns (uint256);

    /**
     * @notice Gets the maximum amount of shares that can be redeemed
     * @param owner Address of share owner
     * @param maxLoss Maximum acceptable loss in basis points
     * @return Maximum shares that can be redeemed in share base units
     */
    function maxRedeem(address owner, uint256 maxLoss) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        MODIFIER HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if the sender is authorized as management
     * @param _sender Address to validate
     */
    function requireManagement(address _sender) external view;

    /**
     * @notice Checks if the sender is authorized as keeper or management
     * @param _sender Address to validate
     */
    function requireKeeperOrManagement(address _sender) external view;

    /**
     * @notice Checks if the sender is authorized for emergency actions
     * @param _sender Address to validate
     */
    function requireEmergencyAuthorized(address _sender) external view;

    /**
     * @notice Require a caller is `regenGovernance`.
     * @dev Is left public so that it can be used by the Strategy.
     *
     * When the Strategy calls this the msg.sender would be the
     * address of the strategy so we need to specify the sender.
     *
     * @param _sender Address to validate for regen governance permissions
     */
    function requireRegenGovernance(address _sender) external view;

    /*//////////////////////////////////////////////////////////////
                            GETTERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the API version of the strategy implementation
     * @return String representing the API version
     */
    function apiVersion() external view returns (string memory);

    /**
     * @notice Returns the current price per share
     * @return Price per share value
     */
    function pricePerShare() external view returns (uint256);

    /**
     * @notice Returns the operator address for the strategy
     * @return Operator address
     */
    function operator() external view returns (address);

    /**
     * @notice Returns the Dragon Router address
     * @return Dragon Router address
     */
    function dragonRouter() external view returns (address);

    /**
     * @notice Returns the current management address
     * @return Management address
     */
    function management() external view returns (address);

    /**
     * @notice Returns the name of the strategy
     * @return Strategy token name
     */
    function name() external view returns (string memory);

    /**
     * @notice Returns the pending management address
     * @return Pending management address
     */
    function pendingManagement() external view returns (address);

    /**
     * @notice Returns the current keeper address
     * @return Keeper address
     */
    function keeper() external view returns (address);

    /**
     * @notice Returns the emergency admin address
     * @return Emergency admin address
     */
    function emergencyAdmin() external view returns (address);

    /**
     * @notice Returns the timestamp of the last report
     * @return Last report timestamp in seconds
     */
    function lastReport() external view returns (uint256);

    /**
     * @notice Returns the Hats Protocol address
     * @return Hats Protocol contract address
     */
    function hats() external view returns (address);

    /**
     * @notice Returns the keeper hat ID
     * @return Keeper hat ID
     */
    function keeperHat() external view returns (uint256);

    /**
     * @notice Returns the management hat ID
     * @return Management hat ID
     */
    function managementHat() external view returns (uint256);

    /**
     * @notice Returns the emergency admin hat ID
     * @return Emergency admin hat ID
     */
    function emergencyAdminHat() external view returns (uint256);

    /**
     * @notice Returns the regen governance hat ID
     * @return Regen governance hat ID
     */
    function regenGovernanceHat() external view returns (uint256);

    /**
     * @notice Checks if the strategy is currently shutdown
     * @return True if the strategy is shutdown, false otherwise
     */
    function isShutdown() external view returns (bool);
}
