// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import { ERC4626Strategy } from "./ERC4626Strategy.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { TokenizedStrategy } from "src/core/TokenizedStrategy.sol";

/**
 * @title SparkStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Specialized yield-donating strategy for Spark Protocol ERC4626 vaults
 * @dev Extends ERC4626Strategy with additional functionality to sweep airdropped tokens
 *      to the dragon router address. This is specifically designed for Spark Protocol
 *      which may airdrop governance tokens or other rewards to strategy addresses.
 *
 *      ADDITIONAL FEATURES:
 *      - Airdrop token sweep functionality for tokens sent to strategy
 *      - Only allows sweeping tokens that are not the main asset or vault shares
 *      - Swept tokens are sent to the dragon router (donation address)
 *      - Callable by both keepers and management for operational flexibility
 *
 * @custom:security Only sweep tokens that are not critical to strategy operation
 */
contract SparkStrategy is ERC4626Strategy {
    using SafeERC20 for IERC20;

    /// @notice Emitted when tokens are swept from the strategy
    /// @param token Address of the token that was swept
    /// @param amount Amount of tokens swept
    /// @param recipient Address that received the swept tokens
    event TokenSwept(address indexed token, uint256 amount, address indexed recipient);

    /**
     * @notice Initializes the Spark strategy
     * @dev Validates asset matches target vault's asset and approves max allowance
     * @param _targetVault Address of the Spark ERC4626 vault this strategy deposits into
     * @param _asset Address of the underlying asset (must match target vault's asset)
     * @param _name Strategy display name (e.g., "Spark USDC Strategy")
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
        ERC4626Strategy(
            _targetVault,
            _asset,
            _name,
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            _enableBurning,
            _tokenizedStrategyAddress
        )
    {}

    /**
     * @notice Sweeps airdropped tokens to the dragon router address
     * @dev Can only be called by keepers or management. Protects against sweeping
     *      critical tokens (asset and vault shares) that are needed for strategy operation.
     * @param _token Address of the token to sweep
     *
     * @custom:security This function:
     * - Only allows sweeping of non-critical tokens
     * - Transfers entire balance to dragon router
     * - Can be called by both keepers and management for operational flexibility
     * - Emits event for transparency
     */
    function sweepAirdrop(address _token) external onlyKeepers {
        // Safety checks: prevent sweeping critical tokens
        require(_token != address(asset), "SparkStrategy: Cannot sweep main asset");
        require(_token != targetVault, "SparkStrategy: Cannot sweep vault shares");

        // Get token balance and dragon router address
        uint256 balance = IERC20(_token).balanceOf(address(this));
        address dragon = TokenizedStrategy.dragonRouter();

        // Only proceed if there's a balance to sweep
        require(balance > 0, "SparkStrategy: No balance to sweep");
        require(dragon != address(0), "SparkStrategy: Invalid dragon router");

        // Transfer all tokens to dragon router
        IERC20(_token).safeTransfer(dragon, balance);

        emit TokenSwept(_token, balance, dragon);
    }
}
