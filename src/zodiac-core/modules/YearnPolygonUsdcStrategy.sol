// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import { DragonBaseStrategy, ERC20 } from "src/zodiac-core/vaults/DragonBaseStrategy.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IStrategy } from "src/zodiac-core/interfaces/IStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626Payable } from "src/zodiac-core/interfaces/IERC4626Payable.sol";

/**
 * @title YearnPolygonUsdcStrategy
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @notice Dragon strategy for Yearn Polygon USDC vault integration
 * @dev Deposits USDC into Yearn Polygon Aave V3 USDC Lender Vault for yield
 */
contract YearnPolygonUsdcStrategy is DragonBaseStrategy {
    /// @notice Yearn Polygon Aave V3 USDC Lender Vault (target vault for deposits)
    /// @dev Vault address: https://polygonscan.com/address/0x52367C8E381EDFb068E9fBa1e7E9B2C847042897
    address public constant YIELD_SOURCE = 0x52367C8E381EDFb068E9fBa1e7E9B2C847042897;

    /**
     * @notice Initialize the strategy (called once during proxy deployment)
     * @dev Owner of this module will be the safe multisig that calls setUp
     * @param initializeParams Encoded initialization parameters:
     *        - address _owner: Safe multisig that will own this module
     *        - bytes data: Nested encoded parameters:
     *            - address _tokenizedStrategyImplementation: TokenizedStrategy implementation address
     *            - address _management: Management role address
     *            - address _keeper: Keeper role address
     *            - address _dragonRouter: Dragon router address for profit routing
     *            - uint256 _maxReportDelay: Maximum time between harvest reports (seconds)
     *            - address _regenGovernance: Regen governance address
     */
    function setUp(bytes memory initializeParams) public override initializer {
        /// @dev USDC token on Polygon: https://polygonscan.com/address/0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359
        address _asset = 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359;

        (address _owner, bytes memory data) = abi.decode(initializeParams, (address, bytes));

        (
            address _tokenizedStrategyImplementation,
            address _management,
            address _keeper,
            address _dragonRouter,
            uint256 _maxReportDelay,
            address _regenGovernance
        ) = abi.decode(data, (address, address, address, address, uint256, address));
        // Effects
        __Ownable_init(msg.sender);
        string memory _name = "Octant Polygon USDC Strategy";
        setAvatar(_owner);
        setTarget(_owner);
        transferOwnership(_owner);

        // Interactions
        __BaseStrategy_init(
            _tokenizedStrategyImplementation,
            _asset,
            _owner,
            _management,
            _keeper,
            _dragonRouter,
            _maxReportDelay,
            _name,
            _regenGovernance
        );

        ERC20(_asset).approve(YIELD_SOURCE, type(uint256).max);
        IERC20(YIELD_SOURCE).approve(_owner, type(uint256).max);
    }

    /**
     * @notice Returns available deposit limit for a user
     * @dev Returns the minimum of strategy's deposit limit and Yearn vault's deposit limit
     * @param _user Address to check deposit limit for
     * @return Available deposit limit in USDC base units
     */
    function availableDepositLimit(address _user) public view override returns (uint256) {
        uint256 actualLimit = super.availableDepositLimit(_user);
        uint256 vaultLimit = IStrategy(YIELD_SOURCE).availableDepositLimit(address(this));
        return Math.min(actualLimit, vaultLimit);
    }

    /**
     * @notice Deploys idle USDC into the Yearn vault
     * @dev Deposits idle USDC into Yearn Polygon Aave V3 USDC Lender Vault
     *      Respects the vault's deposit limit to prevent reverts
     * @param _amount Amount of USDC to deploy in base units
     */
    function _deployFunds(uint256 _amount) internal override {
        uint256 limit = IStrategy(YIELD_SOURCE).availableDepositLimit(address(this));
        _amount = Math.min(_amount, limit);
        if (_amount > 0) {
            IERC4626Payable(YIELD_SOURCE).deposit(_amount, address(this));
        }
    }

    /**
     * @notice Withdraws USDC from the Yearn vault
     * @dev Withdraws USDC from Yearn vault to fulfill redemption requests
     *      Respects the vault's maxWithdraw to prevent reverts
     * @param _amount Amount of USDC to withdraw in base units
     */
    function _freeFunds(uint256 _amount) internal override {
        uint256 _withdrawAmount = Math.min(_amount, IERC4626Payable(YIELD_SOURCE).maxWithdraw(address(this)));
        IERC4626Payable(YIELD_SOURCE).withdraw(_withdrawAmount, address(this), address(this));
    }

    /**
     * @notice Harvests profit and reports total assets
     * @dev Yearn vault strategy: shares accrue yield by increasing in value.
     *      To report profit and allocate dragon router shares, we must:
     *      1. Withdraw all funds from vault (realizes profit)
     *      2. Report total assets held (includes profit)
     *      3. TokenizedStrategy mints dragon shares from profit
     *      4. _tend() re-deposits remaining funds back into vault
     * @return Total assets held by strategy in USDC base units
     */
    function _harvestAndReport() internal override returns (uint256) {
        uint256 _withdrawAmount = IERC4626Payable(YIELD_SOURCE).maxWithdraw(address(this));
        IERC4626Payable(YIELD_SOURCE).withdraw(_withdrawAmount, address(this), address(this));
        return ERC20(asset).balanceOf(address(this));
    }

    /**
     * @notice Re-deploys idle funds back into Yearn vault
     * @dev Re-deposits idle USDC back into Yearn vault after harvest
     *      Ignores the _idle parameter and checks actual balance
     */
    function _tend(uint256 /*_idle*/) internal override {
        uint256 balance = ERC20(asset).balanceOf(address(this));
        if (balance > 0) {
            IERC4626Payable(YIELD_SOURCE).deposit(balance, address(this));
        }
    }

    /**
     * @notice Emergency withdrawal from Yearn vault
     * @dev Withdraws assets from Yearn vault in emergency situations
     * @param _amount Amount of USDC to withdraw in base units
     */
    function _emergencyWithdraw(uint256 _amount) internal override {
        IERC4626Payable(YIELD_SOURCE).withdraw(_amount, address(this), address(this));
    }

    /**
     * @notice Determines if tend should be called by keeper
     * @dev Always returns true to ensure idle funds are deployed after harvest
     * @return True to trigger tend operation
     */
    function _tendTrigger() internal pure override returns (bool) {
        return true;
    }
}
