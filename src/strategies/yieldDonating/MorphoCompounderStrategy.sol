// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";

/**
 * @title MorphoCompounderStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Yield-donating strategy that compounds rewards from a Morpho vault
 * @dev Deposits assets into a Morpho compounder vault (e.g., Morpho Steakhouse) to earn yield
 *
 *      YIELD FLOW:
 *      1. Deposits assets into Morpho compounder vault
 *      2. Vault compounds yield automatically via Morpho markets
 *      3. On report, profit is minted as shares to donation address
 *
 *      META-VAULT INFLATION ISSUE:
 *      - When compounderVault is a meta-vault (e.g., Morpho → SteakHouse),
 *        maxDeposit chains through multiple vaults
 *      - If underlying vaults have duplicate markets in supply queues,
 *        maxDeposit may overstate actual capacity
 *      - This can cause deposits to temporarily revert but is not a critical issue
 *
 *      LOSS HANDLING:
 *      - Accepts 100% loss on withdrawals to prevent revert cascades
 *      - MultistrategyVault enforces actual loss limits via updateDebt
 *
 * @custom:security Morpho vault convertToAssets must be manipulation-resistant
 */
contract MorphoCompounderStrategy is BaseHealthCheck {
    using SafeERC20 for IERC20;

    /// @notice Address of the Morpho compounder vault this strategy deposits into
    /// @dev Must implement ITokenizedStrategy and use the same asset as this strategy
    address public immutable compounderVault;

    /**
     * @notice Initializes the Morpho compounder strategy
     * @dev Validates asset matches Morpho vault's asset and approves max allowance
     * @param _compounderVault Address of the Morpho compounder vault to deposit into
     * @param _asset Address of the underlying asset (must match compounder vault's asset)
     * @param _name Strategy display name (e.g., "Octant Morpho USDC Strategy")
     * @param _symbol Strategy symbol (e.g., "osMorphoUSDC")
     * @param _management Address with management permissions
     * @param _keeper Address authorized to call report() and tend()
     * @param _emergencyAdmin Address authorized for emergency shutdown
     * @param _donationAddress Address receiving minted profit shares
     * @param _enableBurning True to enable loss protection via share burning
     * @param _tokenizedStrategyAddress Address of TokenizedStrategy implementation contract
     */
    constructor(
        address _compounderVault,
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
        BaseHealthCheck(
            _asset,
            _name,
            _symbol,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        )
    {
        // make sure asset is Morpho's asset
        require(ITokenizedStrategy(_compounderVault).asset() == _asset, "Asset mismatch with compounder vault");
        IERC20(_asset).forceApprove(_compounderVault, type(uint256).max);
        compounderVault = _compounderVault;
    }

    /**
     * @notice Returns maximum additional assets that can be deposited
     * @dev Queries compounder vault's maxDeposit and subtracts idle balance
     *
     *      META-VAULT INFLATION:
     *      When compounderVault is Morpho Steakhouse or similar meta-vault,
     *      maxDeposit may be inflated if underlying SteakHouse USDC has duplicate
     *      markets in its supplyQueue. Deposits may temporarily revert.
     *
     * @return limit Maximum additional deposit amount in asset base units
     */
    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        // NOTE: When compounderVault points to certain vaults (like Morpho Steakhouse USDC Compounder),
        // the maxDeposit value may be inflated due to duplicate markets in underlying vault's supplyQueue.
        // This is because maxDeposit chains through: this strategy → Morpho Steakhouse → SteakHouse USDC,
        // and SteakHouse USDC's maxDeposit may overstate capacity when duplicate markets exist.
        uint256 vaultLimit = ITokenizedStrategy(compounderVault).maxDeposit(address(this));
        uint256 idleBalance = IERC20(asset).balanceOf(address(this));
        return vaultLimit > idleBalance ? vaultLimit - idleBalance : 0;
    }

    /**
     * @notice Returns maximum assets withdrawable without expected loss
     * @dev Sums idle balance and compounder vault's maxWithdraw
     * @return limit Maximum withdrawal amount in asset base units
     */
    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + ITokenizedStrategy(compounderVault).maxWithdraw(address(this));
    }

    /**
     * @dev Deposits idle assets into Morpho compounder vault
     * @param _amount Amount of assets to deploy in asset base units
     */
    function _deployFunds(uint256 _amount) internal override {
        ITokenizedStrategy(compounderVault).deposit(_amount, address(this));
    }

    /**
     * @dev Withdraws assets from Morpho compounder vault
     * @param _amount Amount of assets to withdraw in asset base units
     * @custom:security maxLoss set to 100% (10_000 BPS) to prevent revert cascades
     *                  MultistrategyVault enforces actual loss limits via updateDebt
     */
    function _freeFunds(uint256 _amount) internal override {
        ITokenizedStrategy(compounderVault).withdraw(_amount, address(this), address(this), 10_000);
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
     * @return _totalAssets Sum of compounder vault value and idle assets in asset base units
     */
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        // Get strategy's share balance in the compounder vault
        uint256 shares = ITokenizedStrategy(compounderVault).balanceOf(address(this));
        uint256 vaultAssets = ITokenizedStrategy(compounderVault).convertToAssets(shares);

        // Include idle funds as per BaseStrategy specification
        uint256 idleAssets = IERC20(asset).balanceOf(address(this));

        _totalAssets = vaultAssets + idleAssets;

        return _totalAssets;
    }
}
