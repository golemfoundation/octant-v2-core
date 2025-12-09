// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { Enum } from "@gnosis.pm/safe-contracts/contracts/common/Enum.sol";
import { IAvatar } from "zodiac/interfaces/IAvatar.sol";
import { ZeroAddress, ReentrancyGuard__ReentrantCall, TokenizedStrategy__NotOperator, TokenizedStrategy__NotManagement, TokenizedStrategy__NotKeeperOrManagement, TokenizedStrategy__NotRegenGovernance, TokenizedStrategy__NotEmergencyAuthorized, TokenizedStrategy__AlreadyInitialized, TokenizedStrategy__DepositMoreThanMax, TokenizedStrategy__InvalidMaxLoss, TokenizedStrategy__MintToZeroAddress, TokenizedStrategy__BurnFromZeroAddress, TokenizedStrategy__ApproveFromZeroAddress, TokenizedStrategy__ApproveToZeroAddress, TokenizedStrategy__InsufficientAllowance, TokenizedStrategy__PermitDeadlineExpired, TokenizedStrategy__InvalidSigner, TokenizedStrategy__NotSelf, TokenizedStrategy__TransferFailed, TokenizedStrategy__NotPendingManagement, TokenizedStrategy__StrategyNotInShutdown, TokenizedStrategy__TooMuchLoss, TokenizedStrategy__HatsAlreadyInitialized, TokenizedStrategy__InvalidHatsAddress } from "src/errors.sol";

import { IBaseStrategy } from "src/zodiac-core/interfaces/IBaseStrategy.sol";
import { IHats } from "src/zodiac-core/interfaces/IHats.sol";
import { ITokenizedStrategy } from "src/zodiac-core/interfaces/ITokenizedStrategy.sol";
import { IERC4626Payable } from "src/zodiac-core/interfaces/IERC4626Payable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { NATIVE_TOKEN } from "src/constants.sol";

/**
 * @title TokenizedStrategy (Zodiac Vaults Variant)
 * @author Yearn.finance (original TokenizedStrategy v3.0.4); modified by [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Abstract vault-specific tokenized strategy with Zodiac and Hats integration
 * @dev Golem modifications: Zodiac integration, Hats Protocol, ETH support, regen governance
 *
 *      ARCHITECTURE:
 *      - Core ERC4626 vault logic from Yearn V3 TokenizedStrategy
 *      - Extended with Zodiac module patterns for Safe integration
 *      - Adds Hats Protocol role-based access control
 *      - Supports native ETH alongside ERC20 assets
 *      - Integrates regen governance for lockup/rage quit mechanics
 *
 *      See DragonTokenizedStrategy.sol for complete vault implementation
 *
 * @custom:security Zodiac module with Hats Protocol role management
 * @custom:origin https://github.com/yearn/tokenized-strategy
 */
abstract contract TokenizedStrategy is ITokenizedStrategy {
    using Math for uint256;
    using SafeERC20 for ERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice API version this TokenizedStrategy implements
    string internal constant API_VERSION = "1.0.0";

    /// @notice Reentrancy guard state: entered
    uint8 internal constant ENTERED = 2;
    /// @notice Reentrancy guard state: not entered
    uint8 internal constant NOT_ENTERED = 1;

    /// @notice Basis points denominator for fee calculations
    uint256 internal constant MAX_BPS = 10_000;

    /// @notice Minimum lockup duration
    uint256 internal constant RANGE_MINIMUM_LOCKUP_DURATION = 30 days;
    /// @notice Maximum lockup duration
    uint256 internal constant RANGE_MAXIMUM_LOCKUP_DURATION = 3650 days;
    /// @notice Minimum rage quit cooldown period
    uint256 internal constant RANGE_MINIMUM_RAGE_QUIT_COOLDOWN_PERIOD = 30 days;
    /// @notice Maximum rage quit cooldown period
    uint256 internal constant RANGE_MAXIMUM_RAGE_QUIT_COOLDOWN_PERIOD = 3650 days;

    /**
     * @dev Custom storage slot for StrategyData struct (EIP-1967-style deterministic slot)
     * @dev Updates delegatecall to this slot in the calling contract's storage
     */
    bytes32 internal constant BASE_STRATEGY_STORAGE =
        bytes32(uint256(keccak256("octant.tokenized.strategy.storage")) - 1);

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOperator() {
        if (msg.sender != _strategyStorage().operator) revert TokenizedStrategy__NotOperator();
        _;
    }

    /**
     * @dev Require that the call is coming from the strategies management.
     */
    modifier onlyManagement() {
        requireManagement(msg.sender);
        _;
    }

    /**
     * @dev Require that the call is coming from either the strategies
     * management or the keeper.
     */
    modifier onlyKeepers() {
        requireKeeperOrManagement(msg.sender);
        _;
    }

    /**
     * @dev Require that the call is coming from either the strategies
     * management or the emergencyAdmin.
     */
    modifier onlyEmergencyAuthorized() {
        requireEmergencyAuthorized(msg.sender);
        _;
    }

    /**
     * @dev Require that the call is coming from the regen governance.
     */
    modifier onlyRegenGovernance() {
        requireRegenGovernance(msg.sender);
        _;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     * Placed over all state changing functions for increased safety.
     */
    modifier nonReentrant() {
        StrategyData storage S = _strategyStorage();
        // On the first call to nonReentrant, `entered` will be false (2)
        if (S.entered == ENTERED) revert ReentrancyGuard__ReentrantCall();

        // Any calls to nonReentrant after this point will fail
        S.entered = ENTERED;

        _;

        // Reset to false (1) once call has finished.
        S.entered = NOT_ENTERED;
    }

    /*//////////////////////////////////////////////////////////////
                            DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _strategyStorage().management = address(1);
    }

    /*//////////////////////////////////////////////////////////////
                          INITIALIZATION
    //////////////////////////////////////////////////////////////*/
    /**
     * @notice Initializes the tokenized strategy with configuration parameters
     * @dev Sets up vault with asset, roles, and governance addresses
     * @param _asset Address of the underlying ERC20 asset
     * @param _name Name of the strategy share token
     * @param _owner Address that will own the strategy (operator)
     * @param _management Address with management privileges
     * @param _keeper Address authorized to call report/tend
     * @param _dragonRouter Address of dragon router for profit distribution
     * @param _regenGovernance Address of regen governance for lockup controls
     */
    function initialize(
        address _asset,
        string memory _name,
        address _owner,
        address _management,
        address _keeper,
        address _dragonRouter,
        address _regenGovernance
    ) external virtual {
        // Initialize the strategy
        __TokenizedStrategy_init(_asset, _name, _owner, _management, _keeper, _dragonRouter, _regenGovernance);
    }

    /*//////////////////////////////////////////////////////////////
                      ERC4626 WRITE METHODS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposits assets into the vault and mints shares to receiver
     * @dev Virtual function to be implemented by derived contracts
     * @param assets Amount of assets to deposit in asset base units
     * @param receiver Address to receive the minted shares
     * @return shares Amount of shares minted in share base units
     */
    function deposit(
        uint256 assets,
        address receiver
    ) external payable virtual nonReentrant onlyOperator returns (uint256 shares) {}

    /**
     * @notice Mints exact amount of shares to receiver by depositing required assets
     * @dev Virtual function to be implemented by derived contracts
     * @param shares Amount of shares to mint in share base units
     * @param receiver Address to receive the minted shares
     * @return assets Amount of assets deposited in asset base units
     */
    function mint(
        uint256 shares,
        address receiver
    ) external payable virtual nonReentrant onlyOperator returns (uint256 assets) {}

    /**
     * @notice Withdraws exact amount of assets by burning owner's shares
     * @dev Wrapper that defaults to zero max loss tolerance
     * @param assets Amount of assets to withdraw in asset base units
     * @param receiver Address to receive withdrawn assets
     * @param owner Address whose shares will be burned
     * @return shares Amount of shares burned in share base units
     */
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        return withdraw(assets, receiver, owner, 0);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        // We default to not limiting a potential loss.
        return redeem(shares, receiver, owner, MAX_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                        PROFIT REPORTING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Reports profit/loss for the strategy
     * @dev Virtual function to be implemented by derived contracts. Called by keepers to update vault state
     * @return profit Profit generated in asset base units
     * @return loss Loss incurred in asset base units
     */
    function report() external virtual nonReentrant onlyKeepers returns (uint256 profit, uint256 loss) {}

    /*//////////////////////////////////////////////////////////////
                            TENDING
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Performs maintenance operations on the strategy
     * @dev Tends strategy with current loose balance. Called by keepers between reports
     */
    function tend() external nonReentrant onlyKeepers {
        ERC20 _asset = _strategyStorage().asset;
        uint256 _balance = address(_asset) == NATIVE_TOKEN ? address(this).balance : _asset.balanceOf(address(this));
        // Tend the strategy with the current loose balance.
        IBaseStrategy(address(this)).tendThis(_balance);
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY SHUTDOWN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Shuts down the strategy, preventing further deposits
     * @dev Can only be called by emergency authorized addresses
     */
    function shutdownStrategy() external onlyEmergencyAuthorized {
        _strategyStorage().shutdown = true;

        emit StrategyShutdown();
    }

    /**
     * @notice Emergency withdrawal of assets from yield source
     * @dev Requires strategy to be in shutdown state. Only callable by emergency authorized
     * @param amount Amount of assets to withdraw in asset base units
     */
    function emergencyWithdraw(uint256 amount) external nonReentrant onlyEmergencyAuthorized {
        // Make sure the strategy has been shutdown.
        if (!_strategyStorage().shutdown) revert TokenizedStrategy__StrategyNotInShutdown();

        // Withdraw from the yield source.
        IBaseStrategy(address(this)).shutdownWithdraw(amount);
    }

    /*//////////////////////////////////////////////////////////////
                        SETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets a new pending management address
     * @dev Pending management must call acceptManagement() to become active
     * @param _management Address to set as pending management
     */
    function setPendingManagement(address _management) external onlyManagement {
        if (_management == address(0)) revert ZeroAddress();
        _strategyStorage().pendingManagement = _management;

        emit UpdatePendingManagement(_management);
    }

    /**
     * @notice Allows pending management to accept and become active management
     * @dev Can only be called by the pending management address
     */
    function acceptManagement() external {
        StrategyData storage S = _strategyStorage();
        if (msg.sender != S.pendingManagement) revert TokenizedStrategy__NotPendingManagement();
        S.management = msg.sender;
        S.pendingManagement = address(0);

        emit UpdateManagement(msg.sender);
    }

    /**
     * @notice Sets a new keeper address
     * @dev Only callable by management
     * @param _keeper Address authorized to call report() and tend()
     */
    function setKeeper(address _keeper) external onlyManagement {
        _strategyStorage().keeper = _keeper;

        emit UpdateKeeper(_keeper);
    }

    /**
     * @notice Sets a new emergency admin address
     * @dev Only callable by management
     * @param _emergencyAdmin Address authorized for emergency operations
     */
    function setEmergencyAdmin(address _emergencyAdmin) external onlyManagement {
        _strategyStorage().emergencyAdmin = _emergencyAdmin;

        emit UpdateEmergencyAdmin(_emergencyAdmin);
    }

    /**
     * @notice Updates the strategy token name
     * @dev Only callable by management
     * @param _name New name for the strategy share token
     */
    function setName(string calldata _name) external virtual onlyManagement {
        _strategyStorage().name = _name;
    }

    /**
     * @notice Sets up Hats Protocol integration for role management
     * @dev Can only be called once. Only callable by management
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
    ) external onlyManagement {
        StrategyData storage S = _strategyStorage();
        if (S.hatsInitialized) revert TokenizedStrategy__HatsAlreadyInitialized();
        if (_hats == address(0)) revert TokenizedStrategy__InvalidHatsAddress();

        S.HATS = IHats(_hats);
        S.KEEPER_HAT = _keeperHat;
        S.MANAGEMENT_HAT = _managementHat;
        S.EMERGENCY_ADMIN_HAT = _emergencyAdminHat;
        S.REGEN_GOVERNANCE_HAT = _regenGovernanceHat;
        S.hatsInitialized = true;

        emit HatsProtocolSetup(_hats, _keeperHat, _managementHat, _emergencyAdminHat, _regenGovernanceHat);
    }

    /**
     * @notice Approves spender via EIP-2612 permit signature
     * @dev Implements gasless approval using off-chain signature
     * @param _owner Address of token owner
     * @param _spender Address to approve
     * @param _value Amount to approve in share base units
     * @param _deadline Signature deadline timestamp
     * @param _v Signature v parameter
     * @param _r Signature r parameter
     * @param _s Signature s parameter
     */
    function permit(
        address _owner,
        address _spender,
        uint256 _value,
        uint256 _deadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external virtual {
        if (_deadline < block.timestamp) revert TokenizedStrategy__PermitDeadlineExpired();

        // Unchecked because the only math done is incrementing
        // the owner's nonce which cannot realistically overflow.
        unchecked {
            bytes32 digest = keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    DOMAIN_SEPARATOR(),
                    keccak256(
                        abi.encode(
                            keccak256(
                                "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                            ),
                            _owner,
                            _spender,
                            _value,
                            _strategyStorage().nonces[_owner]++,
                            _deadline
                        )
                    )
                )
            );

            (address recoveredAddress, , ) = ECDSA.tryRecover(digest, _v, _r, _s);
            if (recoveredAddress != _owner) {
                revert TokenizedStrategy__InvalidSigner();
            }

            _approve(_strategyStorage(), recoveredAddress, _spender, _value);
        }
    }

    /**
     * @notice Approves spender to transfer shares on behalf of msg.sender
     * @dev Standard ERC20 approve function
     * @param spender Address to approve
     * @param amount Amount to approve in share base units
     * @return True if approval succeeded
     */
    function approve(address spender, uint256 amount) external virtual returns (bool) {
        _approve(_strategyStorage(), msg.sender, spender, amount);
        return true;
    }

    /**
     * @notice Transfers shares from one address to another using allowance
     * @dev Virtual function to be implemented by derived contracts. Standard ERC20 transferFrom
     * @param from Address to transfer from
     * @param to Address to transfer to
     * @param amount Amount to transfer in share base units
     * @return True if transfer succeeded
     */
    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {}

    /**
     * @notice Transfers shares to another address
     * @dev Virtual function to be implemented by derived contracts. Standard ERC20 transfer
     * @param to Address to transfer to
     * @param amount Amount to transfer in share base units
     * @return True if transfer succeeded
     */
    function transfer(address to, uint256 amount) external virtual returns (bool) {}

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL 4626 VIEW METHODS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns total assets managed by the vault
     * @return Total assets in asset base units
     */
    function totalAssets() external view returns (uint256) {
        return _totalAssets(_strategyStorage());
    }

    /**
     * @notice Returns total supply of strategy shares
     * @return Total shares in share base units
     */
    function totalSupply() external view returns (uint256) {
        return _totalSupply(_strategyStorage());
    }

    /**
     * @notice Converts asset amount to equivalent share amount
     * @param assets Amount of assets in asset base units
     * @return Equivalent shares in share base units
     */
    function convertToShares(uint256 assets) external view returns (uint256) {
        return _convertToShares(_strategyStorage(), assets, Math.Rounding.Floor);
    }

    /**
     * @notice Converts share amount to equivalent asset amount
     * @param shares Amount of shares in share base units
     * @return Equivalent assets in asset base units
     */
    function convertToAssets(uint256 shares) external view returns (uint256) {
        return _convertToAssets(_strategyStorage(), shares, Math.Rounding.Floor);
    }

    /**
     * @notice Simulates shares returned for depositing given assets
     * @param assets Amount of assets to simulate in asset base units
     * @return Expected shares to be minted in share base units
     */
    function previewDeposit(uint256 assets) external view returns (uint256) {
        return _convertToShares(_strategyStorage(), assets, Math.Rounding.Floor);
    }

    /**
     * @notice Simulates assets required for minting given shares
     * @param shares Amount of shares to simulate in share base units
     * @return Expected assets required in asset base units
     */
    function previewMint(uint256 shares) external view returns (uint256) {
        return _convertToAssets(_strategyStorage(), shares, Math.Rounding.Ceil);
    }

    /**
     * @notice Simulates shares required for withdrawing given assets
     * @param assets Amount of assets to simulate in asset base units
     * @return Expected shares to be burned in share base units
     */
    function previewWithdraw(uint256 assets) external view returns (uint256) {
        return _convertToShares(_strategyStorage(), assets, Math.Rounding.Ceil);
    }

    /**
     * @notice Simulates assets returned for redeeming given shares
     * @param shares Amount of shares to simulate in share base units
     * @return Expected assets to be withdrawn in asset base units
     */
    function previewRedeem(uint256 shares) external view returns (uint256) {
        return _convertToAssets(_strategyStorage(), shares, Math.Rounding.Floor);
    }

    /**
     * @notice Returns maximum assets that can be deposited by receiver
     * @param receiver Address that would receive the shares
     * @return Maximum assets that can be deposited in asset base units
     */
    function maxDeposit(address receiver) external view returns (uint256) {
        return _maxDeposit(_strategyStorage(), receiver);
    }

    /**
     * @notice Returns maximum shares that can be minted for receiver
     * @param receiver Address that would receive the shares
     * @return Maximum shares that can be minted in share base units
     */
    function maxMint(address receiver) external view returns (uint256) {
        return _maxMint(_strategyStorage(), receiver);
    }

    /**
     * @notice Returns maximum assets that can be withdrawn by owner
     * @dev Virtual function to be implemented by derived contracts
     * @param owner Address of share owner
     * @return Maximum assets that can be withdrawn in asset base units
     */
    function maxWithdraw(address owner) external view virtual returns (uint256) {}

    /**
     * @notice Returns maximum assets that can be withdrawn by owner with loss tolerance
     * @dev Virtual function to be implemented by derived contracts
     * @param owner Address of share owner
     * @return Maximum assets that can be withdrawn in asset base units
     */
    function maxWithdraw(address owner, uint256 /*maxLoss*/) external view virtual override returns (uint256) {}

    /**
     * @notice Returns maximum shares that can be redeemed by owner
     * @param owner Address of share owner
     * @return Maximum shares that can be redeemed in share base units
     */
    function maxRedeem(address owner) external view returns (uint256) {
        return _maxRedeem(_strategyStorage(), owner);
    }

    /**
     * @notice Returns maximum shares that can be redeemed by owner with loss tolerance
     * @param owner Address of share owner
     * @return Maximum shares that can be redeemed in share base units
     */
    function maxRedeem(address owner, uint256 /*maxLoss*/) external view returns (uint256) {
        return _maxRedeem(_strategyStorage(), owner);
    }

    /*//////////////////////////////////////////////////////////////
                        GETTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the underlying asset token address
     * @return Address of the underlying ERC-20 asset
     */
    function asset() external view returns (address) {
        return address(_strategyStorage().asset);
    }

    /**
     * @notice Returns the current management address
     * @return Management address
     */
    function management() external view returns (address) {
        return _strategyStorage().management;
    }

    /**
     * @notice Returns the pending management address
     * @return Pending management address
     */
    function pendingManagement() external view returns (address) {
        return _strategyStorage().pendingManagement;
    }

    /**
     * @notice Returns the operator address
     * @return Operator address
     */
    function operator() external view returns (address) {
        return _strategyStorage().operator;
    }

    /**
     * @notice Returns the dragon router address
     * @return Dragon router address
     */
    function dragonRouter() external view returns (address) {
        return _strategyStorage().dragonRouter;
    }

    /**
     * @notice Returns the keeper address
     * @return Keeper address
     */
    function keeper() external view returns (address) {
        return _strategyStorage().keeper;
    }

    /**
     * @notice Returns the emergency admin address
     * @return Emergency admin address
     */
    function emergencyAdmin() external view returns (address) {
        return _strategyStorage().emergencyAdmin;
    }

    /**
     * @notice Returns the timestamp of the last report
     * @return Last report timestamp in seconds
     */
    function lastReport() external view returns (uint256) {
        return uint256(_strategyStorage().lastReport);
    }

    /**
     * @notice Returns the Hats Protocol address
     * @return Hats Protocol contract address
     */
    function hats() external view returns (address) {
        return address(_strategyStorage().HATS);
    }

    /**
     * @notice Returns the keeper hat ID
     * @return Keeper hat ID
     */
    function keeperHat() external view returns (uint256) {
        return _strategyStorage().KEEPER_HAT;
    }

    /**
     * @notice Returns the management hat ID
     * @return Management hat ID
     */
    function managementHat() external view returns (uint256) {
        return _strategyStorage().MANAGEMENT_HAT;
    }

    /**
     * @notice Returns the emergency admin hat ID
     * @return Emergency admin hat ID
     */
    function emergencyAdminHat() external view returns (uint256) {
        return _strategyStorage().EMERGENCY_ADMIN_HAT;
    }

    /**
     * @notice Returns the regen governance hat ID
     * @return Regen governance hat ID
     */
    function regenGovernanceHat() external view returns (uint256) {
        return _strategyStorage().REGEN_GOVERNANCE_HAT;
    }

    /**
     * @notice Returns the current price per share
     * @return Price per share value with asset decimals precision
     */
    function pricePerShare() external view returns (uint256) {
        StrategyData storage S = _strategyStorage();
        return _convertToAssets(S, 10 ** S.decimals, Math.Rounding.Floor);
    }

    /**
     * @notice Checks if the strategy is currently shutdown
     * @return True if the strategy is shutdown, false otherwise
     */
    function isShutdown() external view returns (bool) {
        return _strategyStorage().shutdown;
    }

    /*//////////////////////////////////////////////////////////////
                        ERC20 METHODS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the name of the strategy token
     * @return Strategy token name
     */
    function name() external view returns (string memory) {
        return _strategyStorage().name;
    }

    /**
     * @notice Returns the symbol of the strategy token
     * @dev Prefixes asset symbol with "dgn" (dragon)
     * @return Strategy token symbol
     */
    function symbol() external view returns (string memory) {
        return string(abi.encodePacked("dgn", _strategyStorage().asset.symbol()));
    }

    /**
     * @notice Returns the number of decimals for the strategy token
     * @return Number of decimals (matches underlying asset)
     */
    function decimals() external view returns (uint8) {
        return _strategyStorage().decimals;
    }

    /**
     * @notice Returns the share balance of an account
     * @param account Address to query balance for
     * @return Share balance in share base units
     */
    function balanceOf(address account) external view returns (uint256) {
        return _balanceOf(_strategyStorage(), account);
    }

    /**
     * @notice Returns the allowance of spender for owner's shares
     * @param _owner Address of token owner
     * @param _spender Address of spender
     * @return Allowance in share base units
     */
    function allowance(address _owner, address _spender) external view returns (uint256) {
        return _allowance(_strategyStorage(), _owner, _spender);
    }

    /**
     * @notice Returns the current nonce for EIP-2612 permit
     * @param _owner Address to query nonce for
     * @return Current nonce value
     */
    function nonces(address _owner) external view returns (uint256) {
        return _strategyStorage().nonces[_owner];
    }

    /**
     * @notice Returns the API version of the strategy implementation
     * @return String representing the API version
     */
    function apiVersion() external pure returns (string memory) {
        return API_VERSION;
    }

    /**
     * @notice Withdraws exact amount of assets by burning shares with loss tolerance
     * @dev Virtual function to be implemented by derived contracts
     * @param assets Amount of assets to withdraw in asset base units
     * @param receiver Address to receive withdrawn assets
     * @param owner Address whose shares will be burned
     * @param maxLoss Maximum acceptable loss in basis points (10000 = 100%)
     * @return shares Amount of shares burned in share base units
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner,
        uint256 maxLoss
    ) public virtual nonReentrant returns (uint256 shares) {}

    function redeem(
        uint256 shares,
        address receiver,
        address owner,
        uint256 maxLoss
    ) public virtual nonReentrant returns (uint256) {}

    /*//////////////////////////////////////////////////////////////
                        MODIFIER HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Checks if the sender is authorized as management
     * @dev Used by onlyManagement modifier. Checks direct address or Hats Protocol role
     * @param _sender Address to validate
     */
    function requireManagement(address _sender) public view {
        StrategyData storage S = _strategyStorage();
        if (_sender != S.management && !_isHatsWearer(S, _sender, S.MANAGEMENT_HAT)) {
            revert TokenizedStrategy__NotManagement();
        }
    }

    /**
     * @notice Checks if the sender is authorized as keeper or management
     * @dev Used by onlyKeepers modifier. Checks direct address or Hats Protocol role
     * @param _sender Address to validate
     */
    function requireKeeperOrManagement(address _sender) public view {
        StrategyData storage S = _strategyStorage();
        if (
            _sender != S.keeper &&
            _sender != S.management &&
            !_isHatsWearer(S, _sender, S.KEEPER_HAT) &&
            !_isHatsWearer(S, _sender, S.MANAGEMENT_HAT)
        ) revert TokenizedStrategy__NotKeeperOrManagement();
    }

    /**
     * @notice Checks if the sender is authorized for emergency actions
     * @dev Used by onlyEmergencyAuthorized modifier. Checks direct address or Hats Protocol role
     * @param _sender Address to validate
     */
    function requireEmergencyAuthorized(address _sender) public view {
        StrategyData storage S = _strategyStorage();
        if (
            _sender != S.emergencyAdmin &&
            _sender != S.management &&
            !_isHatsWearer(S, _sender, S.EMERGENCY_ADMIN_HAT) &&
            !_isHatsWearer(S, _sender, S.MANAGEMENT_HAT)
        ) revert TokenizedStrategy__NotEmergencyAuthorized();
    }

    /**
     * @notice Checks if the sender is authorized as regen governance
     * @dev Used by onlyRegenGovernance modifier. Checks direct address or Hats Protocol role
     * @param _sender Address to validate
     */
    function requireRegenGovernance(address _sender) public view {
        StrategyData storage S = _strategyStorage();
        if (_sender != S.REGEN_GOVERNANCE && !_isHatsWearer(S, _sender, S.REGEN_GOVERNANCE_HAT)) {
            revert TokenizedStrategy__NotRegenGovernance();
        }
    }

    /**
     * @notice Returns the EIP-712 domain separator for permit signatures
     * @return bytes32 domain separator hash
     */
    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256("Dragon Vault"),
                    keccak256(bytes(API_VERSION)),
                    block.chainid,
                    address(this)
                )
            );
    }

    /**
     * @dev Internal initialization function
     */
    function __TokenizedStrategy_init(
        address _asset,
        string memory _name,
        address _operator,
        address _management,
        address _keeper,
        address _dragonRouter,
        address _regenGovernance
    ) internal {
        // Cache storage pointer.
        StrategyData storage S = _strategyStorage();

        // Make sure we aren't initialized.
        if (S.management != address(0)) revert TokenizedStrategy__AlreadyInitialized();

        // Set the strategy's underlying asset.
        S.asset = ERC20(_asset);

        S.operator = _operator;
        S.dragonRouter = _dragonRouter;

        // Set the Strategy Tokens name.
        S.name = _name;
        // Set decimals based off the `asset`.
        S.decimals = _asset == NATIVE_TOKEN ? 18 : ERC20(_asset).decimals();

        S.lastReport = uint96(block.timestamp);

        // Set the default management address. Can't be 0.
        if (_management == address(0)) revert ZeroAddress();
        S.management = _management;
        // Set the keeper address
        S.keeper = _keeper;

        S.REGEN_GOVERNANCE = _regenGovernance;
        S.minimumLockupDuration = 90 days;
        S.rageQuitCooldownPeriod = 90 days;

        // Emit event to signal a new strategy has been initialized.
        emit NewTokenizedStrategy(address(this), _asset, API_VERSION);
    }

    /**
     * @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     *
     */
    function _mint(StrategyData storage S, address account, uint256 amount) internal {
        if (account == address(0)) revert TokenizedStrategy__MintToZeroAddress();

        S.totalSupply += amount;
        unchecked {
            S.balances[account] += amount;
        }
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Destroys `amount` tokens from `account`, reducing the
     * total supply.
     *
     * Emits a {Transfer} event with `to` set to the zero address.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     * - `account` must have at least `amount` tokens.
     */
    function _burn(StrategyData storage S, address account, uint256 amount) internal {
        if (account == address(0)) revert TokenizedStrategy__BurnFromZeroAddress();

        S.balances[account] -= amount;
        unchecked {
            S.totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(StrategyData storage S, address _owner, address _spender, uint256 amount) internal {
        if (_owner == address(0)) revert TokenizedStrategy__ApproveFromZeroAddress();
        if (_spender == address(0)) revert TokenizedStrategy__ApproveToZeroAddress();

        S.allowances[_owner][_spender] = amount;
        emit Approval(_owner, _spender, amount);
    }

    /**
     * @dev Updates `owner` s allowance for `spender` based on spent `amount`.
     *
     * Does not update the allowance amount in case of infinite allowance.
     * Revert if not enough allowance is available.
     *
     * Might emit an {Approval} event.
     */
    function _spendAllowance(StrategyData storage S, address _owner, address _spender, uint256 amount) internal {
        uint256 currentAllowance = _allowance(S, _owner, _spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) revert TokenizedStrategy__InsufficientAllowance();
            unchecked {
                _approve(S, _owner, _spender, currentAllowance - amount);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL 4626 WRITE METHODS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Function to be called during {deposit} and {mint}.
     *
     * This function handles all logic including transfers,
     * minting and accounting.
     *
     * We do all external calls before updating any internal
     * values to prevent view reentrancy issues from the token
     * transfers or the _deployFunds() calls.
     */
    function _deposit(StrategyData storage S, address receiver, uint256 assets, uint256 shares) internal nonReentrant {
        // Cache storage variables used more than once.
        ERC20 _asset = S.asset;
        address target = IBaseStrategy(address(this)).target();
        if (target == address(0)) revert TokenizedStrategy__NotOperator();

        if (msg.sender == target || msg.sender == S.operator) {
            uint256 previousBalance;
            if (address(_asset) == NATIVE_TOKEN) {
                previousBalance = address(this).balance;
                IAvatar(target).execTransactionFromModule(address(this), assets, "", Enum.Operation.Call);
                //slither-disable-next-line incorrect-equality
                require(address(this).balance == previousBalance + assets, TokenizedStrategy__DepositMoreThanMax());
            } else {
                previousBalance = _asset.balanceOf(address(this));
                IAvatar(target).execTransactionFromModule(
                    address(_asset),
                    0,
                    abi.encodeWithSignature("transfer(address,uint256)", address(this), assets),
                    Enum.Operation.Call
                );
                //slither-disable-next-line incorrect-equality
                require(
                    _asset.balanceOf(address(this)) == previousBalance + assets,
                    TokenizedStrategy__TransferFailed()
                );
            }
        } else {
            if (address(_asset) == NATIVE_TOKEN) {
                require(msg.value >= assets, TokenizedStrategy__DepositMoreThanMax());
            } else {
                require(_asset.transferFrom(msg.sender, address(this), assets), TokenizedStrategy__TransferFailed());
            }
        }

        // We can deploy the full loose balance currently held.
        IBaseStrategy(address(this)).deployFunds(
            address(_asset) == NATIVE_TOKEN ? address(this).balance : _asset.balanceOf(address(this))
        );

        // Adjust total Assets.
        S.totalAssets += assets;

        // mint shares
        _mint(S, receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @dev To be called during {redeem} and {withdraw}.
     *
     * This will handle all logic, transfers and accounting
     * in order to service the withdraw request.
     *
     * If we are not able to withdraw the full amount needed, it will
     * be counted as a loss and passed on to the user.
     */
    // solhint-disable-next-line code-complexity
    function _withdraw(
        StrategyData storage S,
        address receiver,
        address _owner,
        uint256 assets,
        uint256 shares,
        uint256 maxLoss
    ) internal virtual returns (uint256) {
        if (receiver == address(0)) revert ZeroAddress();
        if (maxLoss > MAX_BPS) revert TokenizedStrategy__InvalidMaxLoss();

        // Spend allowance if applicable.
        if (msg.sender != _owner) {
            _spendAllowance(S, _owner, msg.sender, shares);
        }

        // Cache `asset` since it is used multiple times..
        ERC20 _asset = S.asset;

        uint256 idle = address(_asset) == NATIVE_TOKEN ? address(this).balance : _asset.balanceOf(address(this));
        uint256 loss = 0;
        // Check if we need to withdraw funds.
        if (idle < assets) {
            // Tell Strategy to free what we need.
            unchecked {
                IBaseStrategy(address(this)).freeFunds(assets - idle);
            }

            // Return the actual amount withdrawn. Adjust for potential under withdraws.
            idle = address(_asset) == NATIVE_TOKEN ? address(this).balance : _asset.balanceOf(address(this));

            // If we didn't get enough out then we have a loss.
            if (idle < assets) {
                unchecked {
                    loss = assets - idle;
                }
                // If a non-default max loss parameter was set.
                if (maxLoss < MAX_BPS) {
                    // Make sure we are within the acceptable range.
                    if (loss > (assets * maxLoss) / MAX_BPS) revert TokenizedStrategy__TooMuchLoss();
                }
                // Lower the amount to be withdrawn.
                assets = idle;
            }
        }

        // Update assets based on how much we took.
        S.totalAssets -= (assets + loss);

        _burn(S, _owner, shares);

        if (address(S.asset) == NATIVE_TOKEN) {
            (bool success, ) = receiver.call{ value: assets }("");
            if (!success) revert TokenizedStrategy__TransferFailed();
        } else {
            // Transfer the amount of underlying to the receiver.
            _asset.safeTransfer(receiver, assets);
        }

        emit Withdraw(msg.sender, receiver, _owner, assets, shares);

        // Return the actual amount of assets withdrawn.
        return assets;
    }

    /// @dev Internal implementation of {allowance}.
    function _allowance(StrategyData storage S, address _owner, address _spender) internal view returns (uint256) {
        return S.allowances[_owner][_spender];
    }

    /// @dev Internal implementation of {balanceOf}.
    function _balanceOf(StrategyData storage S, address account) internal view returns (uint256) {
        return S.balances[account];
    }

    function _onlySelf() internal view {
        if (msg.sender != address(this)) revert TokenizedStrategy__NotSelf();
    }

    /**
     * @dev Base function to check if an address wears a specific hat
     * @param S Storage pointer
     * @param _wearer Address to check
     * @param _hatId Hat ID to verify
     * @return bool True if wearer has the hat, false otherwise
     */
    function _isHatsWearer(StrategyData storage S, address _wearer, uint256 _hatId) internal view returns (bool) {
        if (!S.hatsInitialized) return false;
        try S.HATS.isWearerOfHat(_wearer, _hatId) returns (bool isWearer) {
            return isWearer;
        } catch {
            return false;
        }
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL 4626 VIEW METHODS
    //////////////////////////////////////////////////////////////*/

    /// @dev Internal implementation of {totalAssets}.
    function _totalAssets(StrategyData storage S) internal view returns (uint256) {
        return S.totalAssets;
    }

    /// @dev Internal implementation of {totalSupply}.
    function _totalSupply(StrategyData storage S) internal view returns (uint256) {
        return S.totalSupply;
    }

    /// @dev Internal implementation of {convertToShares}.
    function _convertToShares(
        StrategyData storage S,
        uint256 assets,
        Math.Rounding _rounding
    ) internal view virtual returns (uint256) {
        // Saves an extra SLOAD if values are non-zero.
        uint256 totalSupply_ = _totalSupply(S);
        // If supply is 0, PPS = 1.
        if (totalSupply_ == 0) return assets;

        uint256 totalAssets_ = _totalAssets(S);
        // If assets are 0 but supply is not PPS = 0.
        if (totalAssets_ == 0) return 0;

        return assets.mulDiv(totalSupply_, totalAssets_, _rounding);
    }

    /// @dev Internal implementation of {convertToAssets}.
    function _convertToAssets(
        StrategyData storage S,
        uint256 shares,
        Math.Rounding _rounding
    ) internal view virtual returns (uint256) {
        // Saves an extra SLOAD if totalSupply() is non-zero.
        uint256 supply = _totalSupply(S);

        return supply == 0 ? shares : shares.mulDiv(_totalAssets(S), supply, _rounding);
    }

    /// @dev Internal implementation of {maxDeposit}.
    function _maxDeposit(StrategyData storage S, address receiver) internal view returns (uint256) {
        // Cannot deposit when shutdown or to the strategy.
        if (S.shutdown || receiver == address(this)) return 0;

        return IBaseStrategy(address(this)).availableDepositLimit(receiver);
    }

    /// @dev Internal implementation of {maxMint}.
    function _maxMint(StrategyData storage S, address receiver) internal view virtual returns (uint256 maxMint_) {
        // Cannot mint when shutdown or to the strategy.
        if (S.shutdown || receiver == address(this)) return 0;

        maxMint_ = IBaseStrategy(address(this)).availableDepositLimit(receiver);
        if (maxMint_ != type(uint256).max) {
            maxMint_ = _convertToShares(S, maxMint_, Math.Rounding.Floor);
        }
    }

    /// @dev Internal implementation of {maxWithdraw}.
    function _maxWithdraw(StrategyData storage S, address _owner) internal view virtual returns (uint256 maxWithdraw_) {
        // Get the max the owner could withdraw currently.
        maxWithdraw_ = IBaseStrategy(address(this)).availableWithdrawLimit(_owner);

        // If there is no limit enforced.
        if (maxWithdraw_ == type(uint256).max) {
            // Saves a min check if there is no withdrawal limit.
            maxWithdraw_ = _convertToAssets(S, _balanceOf(S, _owner), Math.Rounding.Floor);
        } else {
            maxWithdraw_ = Math.min(_convertToAssets(S, _balanceOf(S, _owner), Math.Rounding.Floor), maxWithdraw_);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            STORAGE GETTER
    //////////////////////////////////////////////////////////////*/

    /// @dev Internal implementation of {maxRedeem}.
    function _maxRedeem(StrategyData storage S, address _owner) internal view virtual returns (uint256 maxRedeem_) {}

    /**
     * @dev will return the actual storage slot where the strategy
     * specific `StrategyData` struct is stored for both read
     * and write operations.
     *
     * This loads just the slot location, not the full struct
     * so it can be used in a gas efficient manner.
     */
    function _strategyStorage() internal pure returns (StrategyData storage S) {
        // Since STORAGE_SLOT is a constant, we have to put a variable
        // on the stack to access it from an inline assembly block.
        bytes32 slot = BASE_STRATEGY_STORAGE;
        assembly ("memory-safe") {
            S.slot := slot
        }
    }
}
