// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/**
 * @title ERC4626Strategy
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
 *      INTEGRATOR WARNING — per-target audit required:
 *      ERC-4626 compliance is a spec-level claim. Several production vaults that
 *      advertise conformance still have edge cases that break the semantics this
 *      strategy relies on (in particular `availableDepositLimit` /
 *      `availableWithdrawLimit`, which trust the target vault's `maxDeposit` /
 *      `maxWithdraw` at face value):
 *        - MetaMorpho-style vaults can return `maxDeposit == 0` as a normal
 *          operating state while their curator reallocates liquidity across
 *          markets. Deposits must be expected to fail with "deposit more than
 *          max" during those windows even though the strategy code is correct.
 *        - Euler-V2-style vaults' `max*` values can be inaccurate once hooks are
 *          installed on the vault — the vault's own documentation notes that
 *          "some hook configurations may cause the vault to not be fully
 *          ERC-4626 compliant".
 *      Every target vault MUST be studied and audited individually before this
 *      strategy is deployed against it. Do not treat ERC-4626 conformance as a
 *      blanket security guarantee.
 *
 *      FEE-CHARGING TARGET VAULTS — NOT SUPPORTED:
 *      Do NOT deploy against a target ERC-4626 vault that charges an
 *      entry/deposit or withdrawal/exit fee. Deposit accounting credits the
 *      full pre-fee amount; new depositors can exit before the next `report()`
 *      and drain existing users.
 *
 * @custom:security ERC4626 vault convertToAssets must be manipulation-resistant
 * @custom:security Target vault must be audited individually before deployment
 * @custom:security Target vault must NOT charge entry/deposit or withdrawal/exit fees
 */
contract ERC4626Strategy is BaseHealthCheck {
    using SafeERC20 for IERC20;

    /// @notice Address of the ERC4626 vault this strategy deposits into
    /// @dev Must implement IERC4626 interface and use the same asset as this strategy
    address public immutable targetVault;

    /**
     * @notice Initializes the ERC4626 strategy
     * @dev Validates asset matches target vault's asset. Approval is issued
     *      per-deposit inside {_deployFunds} and explicitly cleared after the
     *      target vault call, so no standing allowance against the external
     *      (upgradeable) target vault exists between calls.
     * @param _targetVault Address of the ERC4626 vault this strategy deposits into
     * @param _asset Address of the underlying asset (must match target vault's asset)
     * @param _name Strategy display name (e.g., "Octant ERC4626 Strategy")
     * @param _symbol Strategy token symbol (e.g., "osERC4626")
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
        // make sure asset is target vault's asset
        require(IERC4626(_targetVault).asset() == _asset, "Asset mismatch with target vault");
        targetVault = _targetVault;
    }

    /**
     * @notice Returns maximum additional assets that can be deposited
     * @dev Queries target vault's maxDeposit and subtracts idle balance
     * @return limit Maximum additional deposit amount in asset base units
     */
    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        uint256 vaultLimit = IERC4626(targetVault).maxDeposit(address(this));
        // Preserve the ERC-4626 "infinite capacity" sentinel; subtracting the
        // idle balance would clobber `type(uint256).max` into `uint256.max - idle`,
        // which `TokenizedStrategy._maxMint` no longer recognises as unbounded
        // and routes through `_convertToShares` (risking mulDiv overflow off
        // 1:1 PPS).
        if (vaultLimit == type(uint256).max) return type(uint256).max;
        uint256 idleBalance = IERC20(asset).balanceOf(address(this));
        return vaultLimit > idleBalance ? vaultLimit - idleBalance : 0;
    }

    /**
     * @notice Returns maximum assets withdrawable without expected loss
     * @dev Sums idle balance and target vault's maxWithdraw
     * @return limit Maximum withdrawal amount in asset base units
     */
    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        uint256 idle = IERC20(asset).balanceOf(address(this));
        uint256 vaultMax = IERC4626(targetVault).maxWithdraw(address(this));
        if (vaultMax > type(uint256).max - idle) return type(uint256).max;
        return idle + vaultMax;
    }

    /**
     * @dev Deposits idle assets into ERC4626 vault
     * @param _amount Amount of assets to deploy in asset base units
     */
    function _deployFunds(uint256 _amount) internal override {
        IERC20(asset).forceApprove(targetVault, _amount);
        // Assert the target vault credited shares. A zero-share outcome (e.g., high PPS combined
        // with a tiny deposit, or a misbehaving downstream vault) would consume the asset without
        // recognising a position, silently stranding funds.
        uint256 shares = IERC4626(targetVault).deposit(_amount, address(this));
        require(shares > 0, "ERC4626Strategy: zero shares minted");
        IERC20(asset).forceApprove(targetVault, 0);
    }

    /**
     * @dev Withdraws assets from ERC4626 vault
     * @param _amount Amount of assets to withdraw in asset base units
     * @custom:security `withdraw` returns shares burned, not assets received.
     *                  `TokenizedStrategy._withdraw` measures the post-call
     *                  asset balance and applies the caller's max-loss limit.
     */
    function _freeFunds(uint256 _amount) internal override {
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
        // EIP-4626 requires previewRedeem to reflect any exit-fee policy the target vault enforces;
        // convertToAssets returns the gross value and would overstate totalAssets for fee-charging vaults.
        uint256 vaultAssets = IERC4626(targetVault).previewRedeem(shares);

        uint256 idleAssets = IERC20(asset).balanceOf(address(this));

        if (vaultAssets > type(uint256).max - idleAssets) return type(uint256).max;
        _totalAssets = vaultAssets + idleAssets;

        return _totalAssets;
    }
}
