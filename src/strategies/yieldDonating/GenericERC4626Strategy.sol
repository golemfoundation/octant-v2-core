// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title GenericERC4626Strategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Yield-donating strategy that compounds rewards from any ERC4626-compliant vault
 * @dev Deposits assets into an ERC4626 vault to earn yield which is donated via
 *      BaseHealthCheck's profit minting mechanism
 *
 *      YIELD FLOW:
 *      1. Deposits assets into ERC4626 vault
 *      2. Vault generates yield through its specific strategies
 *      3. On report, profit is minted as shares to donation address
 *
 *      COMPATIBILITY:
 *      - Works with any standard ERC4626 vault (Spark, Yearn v3, etc.)
 *      - Vault must have manipulation-resistant convertToAssets implementation
 *
 * @custom:security ERC4626 vault convertToAssets must be manipulation-resistant
 */
contract GenericERC4626Strategy is BaseHealthCheck {
    using SafeERC20 for IERC20;

    /// @notice Address of the ERC4626 vault this strategy deposits into
    /// @dev Must implement IERC4626 interface and use the same asset as this strategy
    address public immutable targetVault;

    /**
     * @notice Initializes the Generic ERC4626 strategy
     * @dev Validates asset matches target vault's asset and approves max allowance
     * @param _targetVault Address of the ERC4626 vault this strategy deposits into
     * @param _asset Address of the underlying asset (must match target vault's asset)
     * @param _name Strategy display name (e.g., "Octant ERC4626 Strategy")
     * @param _management Address with management permissions
     * @param _keeper Address authorized to call report() and tend()
     * @param _emergencyAdmin Address authorized for emergency shutdown
     * @param _donationAddress Address receiving minted profit shares
     * @param _enableBurning True to enable loss protection via share burning
     * @param _tokenizedStrategyAddress Address of TokenizedStrategy implementation contract
     */
    constructor(
        address _targetVault,
        address _asset,
        string memory _name,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        bool _enableBurning,
        address _tokenizedStrategyAddress
    )
        BaseHealthCheck(
            _asset,
            _name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        )
    {
        // make sure asset is target vault's asset
        require(IERC4626(_targetVault).asset() == _asset, "Asset mismatch with target vault");
        IERC20(_asset).forceApprove(_targetVault, type(uint256).max);
        targetVault = _targetVault;
    }

    /**
     * @notice Returns maximum additional assets that can be deposited
     * @dev Queries target vault's maxDeposit and subtracts idle balance
     * @return limit Maximum additional deposit amount in asset base units
     */
    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        uint256 vaultLimit = IERC4626(targetVault).maxDeposit(address(this));
        uint256 idleBalance = IERC20(asset).balanceOf(address(this));
        return vaultLimit > idleBalance ? vaultLimit - idleBalance : 0;
    }

    /**
     * @notice Returns maximum assets withdrawable without expected loss
     * @dev Sums idle balance and target vault's maxWithdraw
     * @return limit Maximum withdrawal amount in asset base units
     */
    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + IERC4626(targetVault).maxWithdraw(address(this));
    }

    /**
     * @dev Deposits idle assets into ERC4626 vault
     * @param _amount Amount of assets to deploy in asset base units
     */
    function _deployFunds(uint256 _amount) internal override {
        IERC4626(targetVault).deposit(_amount, address(this));
    }

    /**
     * @dev Withdraws assets from ERC4626 vault
     * @param _amount Amount of assets to withdraw in asset base units
     */
    function _freeFunds(uint256 _amount) internal override {
        // Withdraw the requested amount from the vault
        IERC4626(targetVault).withdraw(_amount, address(this), address(this));
    }

    /**
     * @dev Emergency withdrawal after strategy shutdown
     * @param _amount Amount of assets to withdraw in asset base units
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        _freeFunds(_amount);
    }

    /**
     * @dev Reports current total assets under management
     * @return _totalAssets Sum of target vault value and idle assets in asset base units
     */
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        // get strategy's balance in the vault (shares)
        uint256 shares = IERC4626(targetVault).balanceOf(address(this));
        uint256 vaultAssets = IERC4626(targetVault).convertToAssets(shares);

        uint256 idleAssets = IERC20(asset).balanceOf(address(this));

        _totalAssets = vaultAssets + idleAssets;

        return _totalAssets;
    }
}
