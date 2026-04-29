// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { AaveV3Strategy } from "src/strategies/yieldDonating/AaveV3Strategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { IMockStrategy } from "test/mocks/core/IMockStrategy.sol";
import { SeedHelpers } from "./utils/SeedHelpers.sol";

/// @title MockPool that pulls funds via transferFrom (so the allowance check is meaningful)
contract PullingMockPool {
    uint256 public amountToPull = type(uint256).max;

    function setAmountToPull(uint256 _amountToPull) external {
        amountToPull = _amountToPull;
    }

    function supply(address asset, uint256 amount, address /*onBehalfOf*/, uint16 /*referralCode*/) external {
        uint256 pullAmount = amountToPull == type(uint256).max ? amount : amountToPull;
        IERC20(asset).transferFrom(msg.sender, address(this), pullAmount);
    }

    function withdraw(address, uint256, address) external pure returns (uint256) {
        return 0;
    }
}

contract MockDataProvider {
    address public aToken;

    constructor(address _aToken) {
        aToken = _aToken;
    }

    function getReserveTokensAddresses(
        address
    ) external view returns (address aTokenAddress, address stableDebtTokenAddress, address variableDebtTokenAddress) {
        return (aToken, address(0), address(0));
    }

    function getReserveCaps(address) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function getATokenTotalSupply(address) external pure returns (uint256) {
        return 0;
    }

    function getReserveConfigurationData(
        address
    ) external pure returns (uint256, uint256, uint256, uint256, uint256, bool, bool, bool, bool, bool) {
        return (0, 0, 0, 0, 0, false, false, false, true, false); // isActive=true, isFrozen=false
    }

    function getPaused(address) external pure returns (bool) {
        return false;
    }
}

contract MockAddressesProvider {
    address public pool;
    address public dataProvider;

    constructor(address _pool, address _dataProvider) {
        pool = _pool;
        dataProvider = _dataProvider;
    }

    function getPool() external view returns (address) {
        return pool;
    }

    function getPoolDataProvider() external view returns (address) {
        return dataProvider;
    }
}

/// @notice Issue 50 -- the Aave pool is an upgradeable proxy controlled by external
///         governance. A constructor-time `forceApprove(pool, type(uint256).max)` lets a
///         hostile upgrade pull every idle token from the strategy at any time. The fix
///         removes the standing approval, approves exactly the deploy amount inside
///         `_deployFunds`, and clears the approval after `pool.supply`.
contract AaveV3ApprovalHygieneTest is SeedHelpers {
    AaveV3Strategy internal strategy;
    ERC20Mock internal asset;
    PullingMockPool internal pool;
    ERC20Mock internal aToken;

    address internal management = address(0x1);
    address internal keeper = address(0x2);
    address internal emergencyAdmin = address(0x3);
    address internal donationAddress = address(0x4);
    address internal alice = address(0xA);

    function setUp() public {
        asset = new ERC20Mock();
        aToken = new ERC20Mock();
        pool = new PullingMockPool();
        MockDataProvider dp = new MockDataProvider(address(aToken));
        MockAddressesProvider provider = new MockAddressesProvider(address(pool), address(dp));

        // Tokenized strategy implementation lives at its own address; the strategy's
        // BaseStrategy fallback delegatecalls into it directly (no proxy).
        YieldDonatingTokenizedStrategy impl = new YieldDonatingTokenizedStrategy();

        strategy = new AaveV3Strategy(
            address(provider),
            address(0), // rewardsController not exercised in approval tests
            address(asset),
            "Test Aave",
            "tsAAVE",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(impl)
        );
    }

    /// @notice Constructor must NOT pre-approve the pool. Pre-fix this assertion
    ///         fails with `allowance == type(uint256).max`.
    function test_constructor_doesNotPreApprovePool() public view {
        assertEq(
            asset.allowance(address(strategy), address(pool)),
            0,
            "constructor must not grant standing approval to upgradeable pool"
        );
    }

    /// @notice After deposit the per-call approval must be fully consumed by
    ///         `pool.supply`, leaving zero residual allowance.
    function test_deposit_leavesZeroAllowance() public {
        uint256 amount = 100 ether;
        _seedMinimumPosition(address(strategy), asset, management);

        asset.mint(alice, amount);

        vm.startPrank(alice);
        asset.approve(address(strategy), amount);
        IMockStrategy(address(strategy)).deposit(amount, alice);
        vm.stopPrank();

        assertEq(
            asset.allowance(address(strategy), address(pool)),
            0,
            "post-deposit allowance must be zero (pool consumed exactly the approved amount)"
        );
    }

    /// @notice Even if a broken pool pulls less than approved, the strategy must clear
    ///         the residual allowance after the external call.
    function test_deposit_clearsResidualAllowanceWhenPoolPullsLess() public {
        uint256 amount = 100 ether;
        _seedMinimumPosition(address(strategy), asset, management);

        asset.mint(alice, amount);
        pool.setAmountToPull(amount - 1);

        vm.startPrank(alice);
        asset.approve(address(strategy), amount);
        IMockStrategy(address(strategy)).deposit(amount, alice);
        vm.stopPrank();

        assertEq(asset.allowance(address(strategy), address(pool)), 0, "residual allowance must be cleared");
        assertEq(asset.balanceOf(address(strategy)), 1, "unpulled asset remains idle on the strategy");
    }
}
