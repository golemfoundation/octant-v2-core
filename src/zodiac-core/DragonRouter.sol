// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ITokenizedStrategy } from "src/zodiac-core/interfaces/ITokenizedStrategy.sol";
import { ITransformer } from "src/zodiac-core/interfaces/ITransformer.sol";
import { IDragonRouter } from "src/zodiac-core/interfaces/IDragonRouter.sol";
import { LinearAllowanceExecutor } from "src/zodiac-core/LinearAllowanceExecutor.sol";
import { ISplitChecker } from "src/zodiac-core/interfaces/ISplitChecker.sol";
import { IAddressSet } from "src/utils/IAddressSet.sol";
import { AccessMode, NATIVE_TOKEN } from "src/constants.sol";

/**
 * @title Dragon Router
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Zodiac module managing yield distribution splits with transformer support
 * @dev This contract manages the distribution of ERC20 tokens among shareholders,
 * with the ability to transform the split token into another token upon withdrawal,
 * and allows authorized pushers to directly distribute splits.
 */
contract DragonRouter is AccessControlUpgradeable, ReentrancyGuardUpgradeable, LinearAllowanceExecutor, IDragonRouter {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Precision used for split accounting (WAD, 1e18)
    /// @dev All per-share split values are scaled by this precision
    uint256 private constant SPLIT_PRECISION = 1e18;
    /// @notice Role identifier for Octant governance actions
    bytes32 public constant GOVERNANCE_ROLE = keccak256("OCTANT_GOVERNANCE_ROLE");
    /// @notice Role identifier for Regen governance actions
    bytes32 public constant REGEN_GOVERNANCE_ROLE = keccak256("REGEN_GOVERNANCE_ROLE");
    /// @notice Role identifier authorized to fund and distribute splits
    bytes32 public constant SPLIT_DISTRIBUTOR_ROLE = keccak256("SPLIT_DISTRIBUTOR_ROLE");

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Minimal time required between consecutive split updates (seconds)
    uint256 public coolDownPeriod;
    /// @notice Delay applied to splits before they take effect (seconds)
    uint256 public splitDelay;
    /// @notice Contract used to validate split configurations
    ISplitChecker public splitChecker;
    /// @notice Address receiving operational expenses share
    address public opexVault;
    /// @notice Address of the metapool used in distribution
    address public metapool;
    /// @notice Current split configuration (recipients, allocations, total)
    /// @dev Allocations are scaled by {SPLIT_PRECISION}
    ISplitChecker.Split public split;
    /// @notice Timestamp when split was last updated (seconds)
    uint256 public lastSetSplitTime;
    /// @notice List of strategies this router can pull funds from
    address[] public strategies;

    /*//////////////////////////////////////////////////////////////
                            MAPPINGS
    //////////////////////////////////////////////////////////////*/

    /// @notice Per-strategy accounting data (asset, per-share values, totals)
    mapping(address strategy => StrategyData data) public strategyData;
    /// @notice Per-user per-strategy accounting and preferences (transformer, splits)
    mapping(address user => mapping(address strategy => UserData data)) public userData;

    /// @notice Receive native ETH (used by transformers or direct funding)
    receive() external payable override {}

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Adds a new yield strategy to the router
     */
    function addStrategy(address _strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        StrategyData memory _stratData = strategyData[_strategy];
        if (_stratData.asset != address(0)) revert AlreadyAdded();

        address asset = ITokenizedStrategy(_strategy).asset();

        // check if asset is different from address(0)
        if (asset == address(0)) revert ZeroAssetAddress();

        for (uint256 i = 0; i < split.recipients.length; i++) {
            userData[split.recipients[i]][_strategy].splitPerShare = split.allocations[i];
        }

        _stratData.totalShares = split.totalAllocations;
        _stratData.asset = asset;

        strategies.push(_strategy);

        emit StrategyAdded(_strategy);
    }

    /**
     * @notice Removes a yield strategy from the router
     */
    function removeStrategy(address _strategy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        StrategyData storage _stratData = strategyData[_strategy];
        if (_stratData.asset == address(0)) revert StrategyNotDefined();

        for (uint256 i = 0; i < strategies.length; i++) {
            if (strategies[i] == _strategy) {
                strategies[i] = strategies[strategies.length - 1];
                strategies.pop();
                break;
            }
        }

        for (uint256 i = 0; i < split.recipients.length; i++) {
            UserData storage _userData = userData[split.recipients[i]][_strategy];
            uint256 claimableAssets = _claimableAssets(_userData, _strategy);
            _userData.assets += claimableAssets;
            _userData.userAssetPerShare = 0;
            _userData.splitPerShare = 0;
        }

        delete strategyData[_strategy];

        emit StrategyRemoved(_strategy);
    }

    /**
     * @notice Updates the metapool address for yield aggregation
     */
    function setMetapool(address _metapool) external onlyRole(GOVERNANCE_ROLE) {
        _setMetapool(_metapool);
    }

    /**
     * @notice Updates the operational expenses vault address
     */
    function setOpexVault(address _opexVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setOpexVault(_opexVault);
    }

    /**
     * @notice Updates the delay applied before splits take effect
     */
    function setSplitDelay(uint256 _splitDelay) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setSplitDelay(_splitDelay);
    }

    /**
     * @notice Updates the split checker contract used for validation
     */
    function setSplitChecker(address _splitChecker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setSplitChecker(_splitChecker);
    }

    /**
     * @notice Configures a transformer to convert assets during split claims
     */
    function setTransformer(address strategy, address transformer, address targetToken) external {
        if (balanceOf(msg.sender, strategy) == 0) revert NoShares();
        userData[msg.sender][strategy].transformer = Transformer(ITransformer(transformer), targetToken);

        emit UserTransformerSet(msg.sender, strategy, transformer, targetToken);
    }

    /**
     * @notice Enables or disables automated bot claiming for user splits
     */
    function setClaimAutomation(address strategy, bool enable) external {
        userData[msg.sender][strategy].allowBotClaim = enable;
        emit ClaimAutomationSet(msg.sender, strategy, enable);
    }

    /**
     * @notice Updates the minimum time required between consecutive split updates
     */
    function setCooldownPeriod(uint256 _cooldownPeriod) external onlyRole(REGEN_GOVERNANCE_ROLE) {
        _setCooldownPeriod(_cooldownPeriod);
    }

    /// @inheritdoc LinearAllowanceExecutor
    /// @dev Only DEFAULT_ADMIN_ROLE can manage the address set
    function assignModuleAddressSet(IAddressSet addressSet) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _assignModuleAddressSet(addressSet);
    }

    /// @inheritdoc LinearAllowanceExecutor
    /// @dev Only DEFAULT_ADMIN_ROLE can manage the access mode
    function setModuleAccessMode(AccessMode mode) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _setModuleAccessMode(mode);
    }

    /**
     * @notice Withdraws assets from strategy and distributes them according to split configuration
     */
    /// @custom:security Only SPLIT_DISTRIBUTOR_ROLE; reentrancy protected
    /// @dev `amount` is in underlying asset base units
    function fundFromSource(address strategy, uint256 amount) external onlyRole(SPLIT_DISTRIBUTOR_ROLE) nonReentrant {
        StrategyData storage data = strategyData[strategy];
        if (data.asset == address(0)) revert ZeroAddress();

        // False positive: marked nonReentrant
        //slither-disable-next-line reentrancy-no-eth
        ITokenizedStrategy(strategy).withdraw(amount, address(this), address(this), 0);

        // Update per-share accumulator scaled by SPLIT_PRECISION (WAD)
        data.assetPerShare += (amount * SPLIT_PRECISION) / data.totalShares;
        data.totalAssets += amount;
        emit Funded(strategy, data.assetPerShare, data.totalAssets);
    }

    /**
     * @notice Updates the revenue split configuration for all recipients
     */
    /// @custom:security Only DEFAULT_ADMIN_ROLE
    /// @dev Allocations must sum to `totalAllocations` and are scaled by SPLIT_PRECISION
    function setSplit(ISplitChecker.Split memory _split) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (block.timestamp - lastSetSplitTime < coolDownPeriod) revert CooldownPeriodNotPassed();
        splitChecker.checkSplit(_split, opexVault, metapool);
        uint256 strategiesLength = strategies.length;
        for (uint256 i = 0; i < strategiesLength; i++) {
            StrategyData storage data = strategyData[strategies[i]];

            /// @dev updates old splitters
            uint256 splitRecipientsLength = split.recipients.length;
            for (uint256 j = 0; j < splitRecipientsLength; j++) {
                UserData memory _userData = userData[split.recipients[j]][strategies[i]];
                uint256 claimableAssets = _claimableAssets(_userData, strategies[i]);
                _userData.assets += claimableAssets;
                _userData.userAssetPerShare = 0;
                _userData.splitPerShare = 0;
                userData[split.recipients[j]][strategies[i]] = _userData;
                emit UserSplitUpdated(
                    split.recipients[j],
                    strategies[i],
                    _userData.assets,
                    _userData.userAssetPerShare,
                    _userData.splitPerShare
                );
            }

            /// @dev assign to new splitters
            for (uint256 j = 0; j < _split.recipients.length; j++) {
                userData[_split.recipients[j]][strategies[i]].splitPerShare = _split.allocations[j];
                emit UserSplitUpdated(
                    _split.recipients[j],
                    strategies[i],
                    userData[_split.recipients[j]][strategies[i]].assets,
                    userData[_split.recipients[j]][strategies[i]].userAssetPerShare,
                    _split.allocations[j]
                );
            }

            data.assetPerShare = 0;
            data.totalAssets = 0;
            data.totalShares = _split.totalAllocations;
        }

        split = _split;
        lastSetSplitTime = block.timestamp;
        emit SplitSet(0, 0, _split.totalAllocations, lastSetSplitTime);
    }

    /**
     * @notice Claims and transfers a user's split allocation from a strategy
     */
    /// @custom:security Reentrancy protected; requires opt-in for automation or self-claim
    /// @dev `_amount` is in underlying asset base units
    function claimSplit(address _user, address _strategy, uint256 _amount) external nonReentrant {
        if (_amount == 0 || balanceOf(_user, _strategy) < _amount) revert InvalidAmount();
        if (!(userData[_user][_strategy].allowBotClaim || msg.sender == _user)) revert NotAllowed();

        _updateUserSplit(_user, _strategy, _amount);

        _transferSplit(_user, _strategy, _amount);

        emit SplitClaimed(msg.sender, _user, _strategy, _amount);
    }

    /**
     * @notice Returns the total claimable balance for a user from a specific strategy
     */
    function balanceOf(address _user, address _strategy) public view returns (uint256) {
        UserData memory _userData = userData[_user][_strategy];

        return _userData.assets + _claimableAssets(_userData, _strategy);
    }

    /**
     * @notice Emergency withdraw function for accumulated allowance funds
     * @dev Only admin can withdraw funds. Supports both ETH and ERC20 tokens.
     * @param token Address of token to withdraw (use NATIVE_TOKEN for ETH)
     * @param amount Amount to withdraw in token base units
     * @param to Destination address for withdrawn funds
     */
    /// @custom:security Only DEFAULT_ADMIN_ROLE; emits transfer via SafeERC20 for ERC20 path
    function withdraw(
        address token,
        uint256 amount,
        address payable to
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(to != address(0), "DragonRouter: cannot withdraw to zero address");

        if (token == NATIVE_TOKEN) {
            require(address(this).balance >= amount, "DragonRouter: insufficient ETH balance");
            //slither-disable-next-line arbitrary-send-eth
            (bool success, ) = to.call{ value: amount }("");
            require(success, "DragonRouter: ETH transfer failed");
        } else {
            IERC20 tokenContract = IERC20(token);
            uint256 contractBalance = tokenContract.balanceOf(address(this));
            require(contractBalance >= amount, "DragonRouter: insufficient token balance");
            //slither-disable-next-line arbitrary-send-erc20
            tokenContract.safeTransfer(to, amount);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the router via proxy setup
    /// @dev Owner of this module will be the Safe multisig that calls setUp
    /// @param initializeParams ABI-encoded (owner,address[] strategies,address governance,address regenGov,address splitChecker,address opexVault,address metapool)
    function setUp(bytes memory initializeParams) public initializer {
        coolDownPeriod = 30 days;
        (address _owner, bytes memory data) = abi.decode(initializeParams, (address, bytes));

        (
            address[] memory _strategies,
            address _governance,
            address _regen_governance,
            address _splitChecker,
            address _opexVault,
            address _metapool
        ) = abi.decode(data, (address[], address, address, address, address, address));

        __AccessControl_init();
        __ReentrancyGuard_init();

        _setSplitChecker(_splitChecker);
        _setMetapool(_metapool);
        _setOpexVault(_opexVault);

        for (uint256 i = 0; i < _strategies.length; i++) {
            strategyData[_strategies[i]].asset = ITokenizedStrategy(_strategies[i]).asset();
            strategyData[_strategies[i]].totalShares = SPLIT_PRECISION;
            userData[_metapool][_strategies[i]].splitPerShare = SPLIT_PRECISION;
        }

        split.recipients = [_metapool];
        split.allocations = [SPLIT_PRECISION];
        split.totalAllocations = SPLIT_PRECISION;

        strategies = _strategies;
        _grantRole(DEFAULT_ADMIN_ROLE, _owner);
        _grantRole(GOVERNANCE_ROLE, _governance);
        _grantRole(REGEN_GOVERNANCE_ROLE, _regen_governance);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to update a user's split accounting snapshot
     * @param _user Address of user
     * @param _strategy Address of strategy
     * @param _amount Amount of split claimed in underlying base units
     */
    function _updateUserSplit(address _user, address _strategy, uint256 _amount) internal {
        UserData storage _userData = userData[_user][_strategy];
        _userData.assets = balanceOf(_user, _strategy) - _amount;
        _userData.userAssetPerShare = strategyData[_strategy].assetPerShare;
        emit UserSplitUpdated(_user, _strategy, _userData.assets, _userData.userAssetPerShare, _userData.splitPerShare);
    }

    /**
     * @notice Internal function to set the cooldown period
     * @param _cooldownPeriod New cooldown period (seconds)
     */
    function _setCooldownPeriod(uint256 _cooldownPeriod) internal {
        emit CooldownPeriodUpdated(coolDownPeriod, _cooldownPeriod);
        coolDownPeriod = _cooldownPeriod;
    }

    /**
     * @notice Internal function to set the split checker contract
     * @param _splitChecker New split checker contract address
     * @dev Validates the new address is not zero
     */
    function _setSplitChecker(address _splitChecker) internal {
        if (_splitChecker == address(0)) revert ZeroAddress();
        emit SplitCheckerUpdated(address(splitChecker), _splitChecker);
        splitChecker = ISplitChecker(_splitChecker);
    }

    /**
     * @notice Internal function to set the metapool address
     * @param _metapool New metapool address
     * @dev Validates the new address is not zero
     */
    function _setMetapool(address _metapool) internal {
        if (_metapool == address(0)) revert ZeroAddress();
        emit MetapoolUpdated(metapool, _metapool);

        metapool = _metapool;
    }

    /**
     * @notice Internal function to set the split delay
     * @param _splitDelay New split delay (seconds)
     */
    function _setSplitDelay(uint256 _splitDelay) internal {
        emit SplitDelayUpdated(splitDelay, _splitDelay);
        splitDelay = _splitDelay;
    }

    /**
     * @notice Internal function to set the opex vault address
     * @param _opexVault New opex vault address
     * @dev Validates the new address is not zero
     */
    function _setOpexVault(address _opexVault) internal {
        if (_opexVault == address(0)) revert ZeroAddress();
        emit OpexVaultUpdated(opexVault, _opexVault);

        opexVault = _opexVault;
    }

    /**
     * @notice Internal function to transfer split to a user, applying transformation if set
     * @param _user Address of user to receive split
     * @param _strategy Address of strategy whose assets to transform
     * @param _amount Amount of split to transfer in underlying base units
     */
    function _transferSplit(address _user, address _strategy, uint256 _amount) internal {
        Transformer memory userTransformer = userData[_user][_strategy].transformer;
        address _asset = strategyData[_strategy].asset;
        if (address(userTransformer.transformer) != address(0)) {
            IERC20(_asset).approve(address(userTransformer.transformer), _amount);
            uint256 _transformedAmount = _asset == NATIVE_TOKEN
                ? userTransformer.transformer.transform{ value: _amount }(_asset, userTransformer.targetToken, _amount)
                : userTransformer.transformer.transform(_asset, userTransformer.targetToken, _amount);
            if (userTransformer.targetToken == NATIVE_TOKEN) {
                // False positive: User balance is checked before sending
                //slither-disable-next-line arbitrary-send-eth
                (bool success, ) = _user.call{ value: _transformedAmount }("");
                if (!success) revert TransferFailed();
            } else {
                IERC20(userTransformer.targetToken).safeTransfer(_user, _transformedAmount);
            }
        } else {
            if (_asset == NATIVE_TOKEN) {
                (bool success, ) = _user.call{ value: _amount }("");
                if (!success) revert TransferFailed();
            } else {
                IERC20(_asset).safeTransfer(_user, _amount);
            }
        }
    }

    /**
     * @notice Internal function to calculate the claimable assets for a user from a split
     * @param _userData User data snapshot
     * @param _strategy Strategy address
     * @return claimable Amount of assets claimable (underlying base units)
     */
    function _claimableAssets(UserData memory _userData, address _strategy) internal view returns (uint256) {
        StrategyData memory _stratData = strategyData[_strategy];
        return
            (_userData.splitPerShare *
                _stratData.totalShares *
                (_stratData.assetPerShare - _userData.userAssetPerShare)) / SPLIT_PRECISION;
    }
}
