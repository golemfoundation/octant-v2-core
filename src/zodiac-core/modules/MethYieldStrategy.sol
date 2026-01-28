// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { DragonBaseStrategy } from "src/zodiac-core/vaults/DragonBaseStrategy.sol";
import { IERC4626Payable } from "src/zodiac-core/interfaces/IERC4626Payable.sol";
import { IMantleStaking } from "src/zodiac-core/interfaces/IMantleStaking.sol";
import { ITokenizedStrategy } from "src/zodiac-core/interfaces/ITokenizedStrategy.sol";
import { IMethYieldStrategy } from "src/zodiac-core/interfaces/IMethYieldStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { WadRayMath } from "src/utils/libs/Maths/WadRay.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title MethYieldStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice A strategy that manages mETH (Mantle liquid staked ETH) and captures yield from its appreciation
 * @dev This strategy tracks the ETH value of mETH deposits and captures yield as mETH appreciates in value.
 *      The strategy works with YieldBearingDragonTokenizedStrategy to properly handle the yield accounting.
 */
contract MethYieldStrategy is DragonBaseStrategy, IMethYieldStrategy {
    using WadRayMath for uint256;
    using SafeERC20 for IERC20;

    /// @dev The Mantle staking contract that provides exchange rate information
    IMantleStaking public immutable MANTLE_STAKING = IMantleStaking(0xe3cBd06D7dadB3F4e6557bAb7EdD924CD1489E8f);

    /// @dev The ETH value of 1 mETH at the last harvest, scaled by 1e18
    uint256 internal lastReportedExchangeRate;

    /// @dev Initialize function, will be triggered when a new proxy is deployed
    /// @param initializeParams Parameters of initialization encoded
    function setUp(bytes memory initializeParams) public override initializer {
        (address _owner, bytes memory data) = abi.decode(initializeParams, (address, bytes));

        (
            address _tokenizedStrategyImplementation,
            address _management,
            address _keeper,
            address _dragonRouter,
            uint256 _maxReportDelay,
            address _regenGovernance,
            address _mETH
        ) = abi.decode(data, (address, address, address, address, uint256, address, address));
        // Effects
        __Ownable_init(msg.sender);
        string memory _name = "Octant mETH Yield Strategy";

        setAvatar(_owner);
        setTarget(_owner);
        transferOwnership(_owner);

        // Initialize the exchange rate on setup
        lastReportedExchangeRate = _getCurrentExchangeRate();

        // Interactions
        __BaseStrategy_init(
            _tokenizedStrategyImplementation,
            _mETH,
            _owner,
            _management,
            _keeper,
            _dragonRouter,
            _maxReportDelay,
            _name,
            _regenGovernance
        );
    }

    /**
     * @notice Returns the last reported mETH to ETH exchange rate
     * @return Exchange rate with 18 decimals precision
     */
    function getLastReportedExchangeRate() public view returns (uint256) {
        return lastReportedExchangeRate;
    }

    /**
     * @notice No funds deployment needed as mETH already generates yield
     * @param _amount Amount to deploy (ignored in this strategy)
     * @dev This is a passive strategy, so no deployment action is needed
     */
    function _deployFunds(uint256 _amount) internal override {
        // No action needed - mETH is already a yield-bearing asset
        // This function is required by the interface but doesn't need implementation
    }

    /**
     * @notice Emergency withdrawal function to transfer mETH tokens to emergency admin
     * @param _amount Amount of mETH to withdraw in emergency
     * @dev Simple transfer of tokens to the emergency admin address
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        // Transfer the mETH tokens to the emergency admin
        address emergencyAdmin = ITokenizedStrategy(address(this)).emergencyAdmin();
        IERC20(asset).safeTransfer(emergencyAdmin, _amount);
    }

    /**
     * @notice No funds to free as we're just transferring mETH tokens
     * @param _amount Amount to free (ignored in this strategy)
     * @dev Withdrawal is handled by the TokenizedStrategy layer
     */
    function _freeFunds(uint256 _amount) internal override {
        // No action needed - we just need to transfer mETH tokens
        // Withdrawal is handled by the TokenizedStrategy layer
    }

    /**
     * @notice Captures yield by calculating the increase in ETH value based on exchange rate changes
     * @return profitInMeth Profit in mETH terms calculated from exchange rate appreciation
     * @dev Uses ray math for precise calculations and converts ETH profit to mETH
     */
    function _harvestAndReport() internal virtual override returns (uint256) {
        uint256 currentExchangeRate = _getCurrentExchangeRate();

        // Get the current balance of mETH in the strategy
        uint256 mEthBalance = IERC20(asset).balanceOf(address(this));

        // Calculate the profit in ETH terms
        uint256 deltaExchangeRate = currentExchangeRate > lastReportedExchangeRate
            ? currentExchangeRate - lastReportedExchangeRate
            : 0; // Only capture positive yield (shouldn't happen)

        uint256 profitInEth = (mEthBalance.rayMul(deltaExchangeRate)).rayDiv(1e18);

        // Calculate the profit in mETH terms
        uint256 profitInMeth = (profitInEth.rayMul(1e18)).rayDiv(currentExchangeRate);

        // Update the exchange rate for the next harvest
        lastReportedExchangeRate = currentExchangeRate;

        return profitInMeth;
    }

    /**
     * @notice No tending needed as mETH already generates yield
     * @dev This strategy is passive and doesn't require tending
     */
    function _tend(uint256 /*_idle*/) internal override {
        // No action needed - mETH is already a yield-bearing asset
    }

    /**
     * @notice Gets the current exchange rate from the Mantle staking contract
     * @return Current exchange rate (mETH to ETH ratio, scaled by 1e18)
     * @dev Uses the Mantle staking contract as the authoritative source for exchange rates
     */
    function _getCurrentExchangeRate() internal view virtual returns (uint256) {
        // Calculate the exchange rate by determining how much ETH 1e18 mETH is worth
        return MANTLE_STAKING.mETHToETH(1e18);
    }

    /**
     * @notice Always returns false as no tending is needed
     * @return Always false as tending is not required
     * @dev This strategy is passive and doesn't require tending
     */
    function _tendTrigger() internal pure override returns (bool) {
        return false;
    }
}
