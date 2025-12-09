// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";

/**
 * @title YearnV3Strategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Yield-donating strategy that compounds rewards from a Yearn v3 vault
 * @dev Deposits assets into a Yearn v3 vault to earn yield, which is donated via
 *      BaseHealthCheck's profit minting mechanism
 *
 *      YIELD FLOW:
 *      1. Deposits assets into Yearn v3 vault
 *      2. Vault generates yield from its strategies
 *      3. On report, profit is minted as shares to donation address
 *
 *      META-VAULT CONSIDERATION:
 *      - If Yearn vault deposits into meta-vaults (e.g., Morpho → SteakHouse),
 *        maxDeposit may be inflated due to duplicate markets in supply queues
 *      - This can cause temporary deposit DoS but doesn't affect withdrawals
 *
 *      LOSS HANDLING:
 *      - Accepts 100% loss on withdrawals to prevent revert cascades
 *      - MultistrategyVault performs actual loss validation via updateDebt
 *
 * @custom:security Yearn vault convertToAssets must be manipulation-resistant
 */
contract YearnV3Strategy is BaseHealthCheck {
    using SafeERC20 for IERC20;

    /// @notice Address of the Yearn v3 vault this strategy deposits into
    /// @dev Must implement ITokenizedStrategy and use the same asset as this strategy
    address public immutable yearnVault;

    /**
     * @notice Initializes the Yearn v3 strategy
     * @dev Validates asset matches Yearn vault's asset and approves max allowance
     * @param _yearnVault Address of the Yearn v3 vault this strategy deposits into
     * @param _asset Address of the underlying asset (must match Yearn vault's asset)
     * @param _name Strategy display name (e.g., "Octant Yearn USDC Strategy")
     * @param _management Address with management permissions
     * @param _keeper Address authorized to call report() and tend()
     * @param _emergencyAdmin Address authorized for emergency shutdown
     * @param _donationAddress Address receiving minted profit shares
     * @param _enableBurning True to enable loss protection via share burning
     * @param _tokenizedStrategyAddress Address of TokenizedStrategy implementation contract
     */
    constructor(
        address _yearnVault,
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
        // make sure asset is Yearn vault's asset
        require(ITokenizedStrategy(_yearnVault).asset() == _asset, "Asset mismatch with compounder vault");
        IERC20(_asset).forceApprove(_yearnVault, type(uint256).max);
        yearnVault = _yearnVault;
    }

    /**
     * @notice Returns maximum additional assets that can be deposited
     * @dev Queries Yearn vault's maxDeposit and subtracts idle balance
     *
     *      META-VAULT WARNING:
     *      When Yearn vault points to meta-vaults (e.g., Morpho → SteakHouse),
     *      maxDeposit may be inflated if underlying vaults have duplicate markets.
     *      This can cause deposits to revert temporarily but doesn't indicate an issue.
     *
     * @return limit Maximum additional deposit amount in asset base units
     */
    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        // NOTE: If the yearnVault is a meta-vault that deposits into other vaults (e.g., Morpho Steakhouse),
        // the maxDeposit value may be inflated when the underlying chain reaches vaults with duplicate
        // markets in their supplyQueue (like SteakHouse USDC). This could cause temporary DoS for deposits
        uint256 vaultLimit = ITokenizedStrategy(yearnVault).maxDeposit(address(this));
        uint256 idleBalance = IERC20(asset).balanceOf(address(this));
        return vaultLimit > idleBalance ? vaultLimit - idleBalance : 0;
    }

    /**
     * @notice Returns maximum assets withdrawable without expected loss
     * @dev Sums idle balance and Yearn vault's maxWithdraw
     * @return limit Maximum withdrawal amount in asset base units
     */
    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this)) + ITokenizedStrategy(yearnVault).maxWithdraw(address(this));
    }

    /**
     * @dev Deposits idle assets into Yearn v3 vault
     * @param _amount Amount of assets to deploy in asset base units
     */
    function _deployFunds(uint256 _amount) internal override {
        ITokenizedStrategy(yearnVault).deposit(_amount, address(this));
    }

    /**
     * @dev Withdraws assets from Yearn v3 vault
     * @param _amount Amount of assets to withdraw in asset base units
     * @custom:security maxLoss set to 100% (10_000 BPS) to prevent revert cascades
     *                  MultistrategyVault enforces actual loss limits via updateDebt
     */
    function _freeFunds(uint256 _amount) internal override {
        // NOTE: maxLoss is set to 10_000 (100%) to ensure withdrawals don't revert when the Yearn vault
        // has unrealized losses. This is necessary because:
        // 1. When the TokenizedStrategy needs funds, it calls freeFunds() to withdraw from the underlying Yearn vault
        // 2. Without accepting losses here, any slippage/loss in Yearn would cause the withdrawal to fail
        // 3. The MultistrategyVault performs its own loss checks after withdrawal via updateDebt's maxLoss parameter
        // This allows the strategy to always provide liquidity while loss protection is enforced at the vault level.
        ITokenizedStrategy(yearnVault).withdraw(_amount, address(this), address(this), 10_000);
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
     * @return _totalAssets Sum of Yearn vault value and idle assets in asset base units
     */
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        // get strategy's balance in the vault
        uint256 shares = ITokenizedStrategy(yearnVault).balanceOf(address(this));
        uint256 vaultAssets = ITokenizedStrategy(yearnVault).convertToAssets(shares);

        uint256 idleAssets = IERC20(asset).balanceOf(address(this));

        _totalAssets = vaultAssets + idleAssets;

        return _totalAssets;
    }
}
