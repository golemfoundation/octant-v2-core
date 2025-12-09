// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

/**
 * @title IStaking
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for Sky Protocol staking contract (0x0650CAF159C5A49f711e8169D4336ECB9b950275)
 * @dev Supports stake, withdraw, and reward claiming operations
 *      Custom interface for interacting with Sky Protocol's USDS staking vault
 */
interface IStaking {
    /// @notice Returns the address of the token accepted for staking
    /// @return Address of staking token (USDS)
    function stakingToken() external view returns (address);

    /// @notice Returns the address of the token distributed as rewards
    /// @return Address of rewards token
    function rewardsToken() external view returns (address);

    /// @notice Returns whether staking is currently paused
    /// @return True if staking is paused, false if active
    function paused() external view returns (bool);

    /// @notice Returns unclaimed rewards for an account
    /// @param account Address to check rewards for
    /// @return Amount of unclaimed rewards in rewards token base units
    function earned(address account) external view returns (uint256);

    /// @notice Stakes tokens with an optional referral code
    /// @param _amount Amount to stake in staking token base units
    /// @param _referral Referral code for tracking (0 for no referral)
    function stake(uint256 _amount, uint16 _referral) external;

    /// @notice Withdraws staked tokens
    /// @param _amount Amount to withdraw in staking token base units
    function withdraw(uint256 _amount) external;

    /// @notice Claims all earned rewards
    /// @dev Transfers rewards token to caller
    function getReward() external;
}

/**
 * @title IReferral
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for referral tracking in Sky protocol
 * @dev Custom interface for Sky Protocol referral contract integration
 */
interface IReferral {
    /// @notice Records a deposit with referral tracking
    /// @param amount Amount deposited in token base units
    /// @param user Address of the user making the deposit
    /// @param referralCode Referral code for attribution
    function deposit(uint256 amount, address user, uint16 referralCode) external;
}

/**
 * @title ISkyCompounder
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Interface for Sky compounder strategy management functions
 * @dev Configuration interface for UniswapV2/V3 swap settings and MEV protection
 */
interface ISkyCompounder {
    /// @notice Emitted when claim rewards setting is updated
    /// @param claimRewards True if rewards should be claimed automatically
    event ClaimRewardsUpdated(bool claimRewards);

    /// @notice Emitted when Uniswap V3 swap settings are updated
    /// @param useUniV3 True if Uniswap V3 should be used
    /// @param rewardToBase Fee tier for reward to base token swap in basis points
    /// @param baseToAsset Fee tier for base to asset token swap in basis points
    event UniV3SettingsUpdated(bool useUniV3, uint24 rewardToBase, uint24 baseToAsset);

    /// @notice Emitted when minimum amount to sell is updated
    /// @param minAmountToSell Minimum token amount to trigger swap in token base units
    event MinAmountToSellUpdated(uint256 minAmountToSell);

    /// @notice Emitted when base token is updated
    /// @param base Address of new base token
    /// @param useUniV3 True if Uniswap V3 should be used
    /// @param rewardToBase Fee tier for reward to base token swap in basis points
    /// @param baseToAsset Fee tier for base to asset token swap in basis points
    event BaseTokenUpdated(address base, bool useUniV3, uint24 rewardToBase, uint24 baseToAsset);

    /// @notice Emitted when referral code is updated
    /// @param referral New referral code
    event ReferralUpdated(uint16 referral);

    /// @notice Emitted when minimum amount out is updated
    /// @param minAmountOut Minimum output amount for swaps in token base units
    event MinAmountOutUpdated(uint256 minAmountOut);

    // Management functions

    /// @notice Sets whether rewards should be claimed automatically during harvest
    /// @param _claimRewards True to auto-claim rewards, false to skip
    /// @custom:security Only management or governance can call
    function setClaimRewards(bool _claimRewards) external;

    /// @notice Configures Uniswap V3 usage and fee tiers for swaps
    /// @param _useUniV3 True to use Uniswap V3, false for V2
    /// @param _rewardToBase Fee tier for reward→base swap in basis points (e.g., 3000 = 0.3%)
    /// @param _baseToAsset Fee tier for base→asset swap in basis points
    /// @custom:security Only management or governance can call
    function setUseUniV3andFees(bool _useUniV3, uint24 _rewardToBase, uint24 _baseToAsset) external;

    /// @notice Sets minimum token amount required to trigger a swap
    /// @param _minAmountToSell Minimum amount in token base units
    /// @custom:security Only management or governance can call
    function setMinAmountToSell(uint256 _minAmountToSell) external;

    /// @notice Updates the base token used in swap routes and optionally configures UniswapV3 settings
    /// @param _base Address of new base token (USDS, DAI, USDC, or WETH)
    /// @param _useUniV3 True to use Uniswap V3, false for V2
    /// @param _rewardToBase Fee tier for reward→base swap in basis points
    /// @param _baseToAsset Fee tier for base→asset swap in basis points
    /// @custom:security Only management or governance can call
    function setBase(address _base, bool _useUniV3, uint24 _rewardToBase, uint24 _baseToAsset) external;

    /// @notice Updates the referral code used for staking
    /// @param _referral New referral code (0 for no referral)
    /// @custom:security Only management or governance can call
    function setReferral(uint16 _referral) external;

    /// @notice Sets minimum output amount for swaps (MEV protection)
    /// @param _minAmountOut Minimum output amount in token base units (0 to disable)
    /// @custom:security Only management or governance can call
    function setMinAmountOut(uint256 _minAmountOut) external;
}
