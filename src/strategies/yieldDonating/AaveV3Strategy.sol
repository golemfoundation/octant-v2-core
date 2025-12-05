// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { BaseHealthCheck } from "src/strategies/periphery/BaseHealthCheck.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IPool {
    /// @notice Supplies an asset to the Aave pool
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    /// @notice Withdraws an asset from the Aave pool
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken {
    /// @notice Returns the address of the underlying asset
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

interface IPoolDataProvider {
    /// @notice Returns the supply and borrow caps for a reserve
    function getReserveCaps(address asset) external view returns (uint256 supplyCap, uint256 borrowCap);

    /// @notice Returns the total aToken supply for a specific asset
    function getATokenTotalSupply(address asset) external view returns (uint256);
}

interface IPoolAddressesProvider {
    /// @notice Returns the address of the Pool contract
    function getPool() external view returns (address);
    /// @notice Returns the address of the PoolDataProvider contract
    function getPoolDataProvider() external view returns (address);
}

/**
 * @title AaveV3Strategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Yield-donating strategy that earns yield from Aave V3
 * @dev Deposits assets into Aave V3 lending pool to earn interest
 *
 *      YIELD FLOW:
 *      1. Deposits assets into Aave V3 pool
 *      2. Receives aTokens that automatically accrue interest
 *      3. On report, profit is minted as shares to donation address
 *
 *      DEPOSIT/WITHDRAW LIMITS:
 *      - Aave V3 has supply caps per asset that limit total deposits
 *      - Strategy checks available capacity before deposits
 *      - Withdrawals limited by available liquidity in the pool
 *
 * @custom:security Aave pool must be trusted and not manipulatable
 */
contract AaveV3Strategy is BaseHealthCheck {
    using SafeERC20 for IERC20;

    /// @notice Address of the Aave V3 addresses provider
    IPoolAddressesProvider public immutable addressesProvider;

    /// @notice Address of the Aave V3 pool
    IPool public immutable pool;

    /// @notice Address of the pool data provider
    IPoolDataProvider public immutable dataProvider;

    /// @notice Address of the aToken for the underlying asset
    address public immutable aToken;

    /**
     * @notice Initializes the Aave V3 strategy
     * @dev Sets up connections to Aave V3 pool and approves max allowance
     * @param _addressesProvider Address of Aave V3 addresses provider
     * @param _aToken Address of the aToken corresponding to the asset
     * @param _asset Address of the underlying asset
     * @param _name Strategy display name (e.g., "Octant Aave V3 USDC Strategy")
     * @param _management Address with management permissions
     * @param _keeper Address authorized to call report() and tend()
     * @param _emergencyAdmin Address authorized for emergency shutdown
     * @param _donationAddress Address receiving minted profit shares
     * @param _enableBurning True to enable loss protection via share burning
     * @param _tokenizedStrategyAddress Address of TokenizedStrategy implementation contract
     */
    constructor(
        address _addressesProvider,
        address _aToken,
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
        addressesProvider = IPoolAddressesProvider(_addressesProvider);
        pool = IPool(addressesProvider.getPool());
        dataProvider = IPoolDataProvider(addressesProvider.getPoolDataProvider());
        aToken = _aToken;

        // verify asset that aToken is the correct one
        require(IAToken(aToken).UNDERLYING_ASSET_ADDRESS() == _asset, "Asset mismatch with aToken");

        // Approve Aave pool to spend our asset
        IERC20(_asset).forceApprove(address(pool), type(uint256).max);
    }

    /**
     * @notice Returns maximum additional assets that can be deposited
     * @dev Checks Aave V3 supply cap and subtracts current supply
     * @return limit Maximum additional deposit amount in asset base units
     */
    function availableDepositLimit(address /*_owner*/) public view override returns (uint256) {
        (uint256 supplyCap, ) = dataProvider.getReserveCaps(address(asset));

        // If supply cap is 0, it means unlimited
        if (supplyCap == 0) {
            return type(uint256).max;
        }

        // Get current total supply in the pool
        uint256 totalSupply = dataProvider.getATokenTotalSupply(address(asset));

        // Cap is in whole tokens, need to adjust for decimals
        uint256 supplyCapScaled = supplyCap * 10 ** IERC20Metadata(address(asset)).decimals();

        if (supplyCapScaled > totalSupply) {
            uint256 availableCapacity = supplyCapScaled - totalSupply;
            uint256 idleBalance = IERC20(address(asset)).balanceOf(address(this));

            // Safely subtract idle balance to avoid underflow
            if (availableCapacity <= idleBalance) {
                return 0;
            } else {
                return availableCapacity - idleBalance;
            }
        } else {
            return 0;
        }
    }

    /**
     * @notice Returns maximum assets withdrawable without expected loss
     * @dev Sums idle balance and aToken balance
     * @return limit Maximum withdrawal amount in asset base units
     */
    function availableWithdrawLimit(address /*_owner*/) public view override returns (uint256) {
        // Get our aToken balance which represents our deposited assets
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));
        uint256 idleBalance = IERC20(address(asset)).balanceOf(address(this));

        return aTokenBalance + idleBalance;
    }

    /**
     * @dev Deposits idle assets into Aave V3 pool
     * @param _amount Amount of assets to deploy in asset base units
     */
    function _deployFunds(uint256 _amount) internal override {
        pool.supply(address(asset), _amount, address(this), 0);
    }

    /**
     * @dev Withdraws assets from Aave V3 pool
     * @param _amount Amount of assets to withdraw in asset base units
     */
    function _freeFunds(uint256 _amount) internal override {
        pool.withdraw(address(asset), _amount, address(this));
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
     * @return _totalAssets Sum of aToken balance and idle assets in asset base units
     */
    function _harvestAndReport() internal view override returns (uint256 _totalAssets) {
        // aTokens have 1:1 value with underlying asset
        uint256 aTokenBalance = IERC20(aToken).balanceOf(address(this));

        // Include idle funds as per BaseStrategy specification
        uint256 idleAssets = IERC20(address(asset)).balanceOf(address(this));

        _totalAssets = aTokenBalance + idleAssets;

        return _totalAssets;
    }
}
