// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.25;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ERC4626Strategy } from "src/strategies/yieldDonating/ERC4626Strategy.sol";
import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { SeedHelpers } from "./utils/SeedHelpers.sol";

/// @notice 4626-shaped vault used by the branch-coverage tests below.
/// @dev    Implements only the surface exercised by `_deployFunds` and
///         `availableDepositLimit`. Advertises `type(uint256).max` capacity
///         for `maxDeposit` and credits 1:1 shares on deposit so a single
///         instance can drive both the exact-approval lifecycle and the
///         unbounded-sentinel branches.
contract UnboundedVaultMock {
    address public immutable asset;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    uint256 public pullBps = 10_000;

    constructor(address underlying) {
        asset = underlying;
    }

    function setPullBps(uint256 _pullBps) external {
        pullBps = _pullBps;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        uint256 pulled = (assets * pullBps) / 10_000;
        IERC20(asset).transferFrom(msg.sender, address(this), pulled);
        shares = pulled;
        balanceOf[receiver] += shares;
        totalSupply += shares;
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }
}

/// @title  Branch coverage for ERC4626Strategy and MorphoCompounderStrategy
/// @notice Exercises shared ERC-4626-lineage branches not reached by the
///         generic yield-donating unit suite (which uses MockStrategy):
///
///         1. `_deployFunds` issues a per-deposit `forceApprove(_amount)` and
///            clears the allowance after the target call. No standing max allowance
///            or residual under-pull allowance against the external (upgradeable)
///            target vault is left over from construction.
///         2. `availableDepositLimit` short-circuits when the target vault
///            advertises `type(uint256).max`, preserving the ERC-4626
///            "infinite capacity" sentinel that `TokenizedStrategy._maxMint`
///            keys off (the pre-fix subtraction clobbered the sentinel into
///            `uint256.max - idle`, routing through `_convertToShares` and
///            risking a mulDiv overflow once PPS drifts off 1:1).
contract ERC4626BranchCoverageTest is SeedHelpers {
    ERC20Mock internal asset;
    YieldDonatingTokenizedStrategy internal implementation;
    UnboundedVaultMock internal targetVault;

    address internal management = address(0xA1);
    address internal keeper = address(0xA2);
    address internal emergencyAdmin = address(0xA3);
    address internal donationAddress = address(0xA4);
    address internal user = address(0xBEEF);

    uint256 internal constant DEPOSIT_AMOUNT = 1_000 ether;
    uint256 internal constant IDLE_SEED = 1 ether;

    function setUp() public {
        asset = new ERC20Mock();
        targetVault = new UnboundedVaultMock(address(asset));
        implementation = new YieldDonatingTokenizedStrategy();
    }

    // ─── Deployment helpers ───────────────────────────────────────────

    function _deployERC4626Strategy() internal returns (ERC4626Strategy) {
        return
            new ERC4626Strategy(
                address(targetVault),
                address(asset),
                "Octant ERC4626 Test",
                "osERC4626Test",
                management,
                keeper,
                emergencyAdmin,
                donationAddress,
                false,
                address(implementation)
            );
    }

    function _deployMorphoStrategy() internal returns (MorphoCompounderStrategy) {
        return
            new MorphoCompounderStrategy(
                address(targetVault),
                address(asset),
                "Octant Morpho Test",
                "osMorphoTest",
                management,
                keeper,
                emergencyAdmin,
                donationAddress,
                false,
                address(implementation)
            );
    }

    // ─── Behavioural assertions (shared across strategies) ────────────

    function _assertExactApprovalLifecycle(address strategyAddr) internal {
        // Constructor must NOT leave a standing max-approval against the external vault.
        assertEq(
            asset.allowance(strategyAddr, address(targetVault)),
            0,
            "constructor leaked a standing allowance against the target vault"
        );
        _seedMinimumPosition(strategyAddr, asset, management);

        // Deposit routes through `_deployFunds`, which approves exactly the
        // deposit amount and clears allowance after the vault call.
        asset.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        asset.approve(strategyAddr, DEPOSIT_AMOUNT);
        ITokenizedStrategy(strategyAddr).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();

        assertEq(
            asset.allowance(strategyAddr, address(targetVault)),
            0,
            "_deployFunds left a non-zero allowance after deposit"
        );
    }

    function _assertResidualApprovalClearedOnUnderPull(address strategyAddr) internal {
        _seedMinimumPosition(strategyAddr, asset, management);
        targetVault.setPullBps(5_000);

        asset.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        asset.approve(strategyAddr, DEPOSIT_AMOUNT);
        ITokenizedStrategy(strategyAddr).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();

        assertEq(
            asset.allowance(strategyAddr, address(targetVault)),
            0,
            "_deployFunds left residual allowance when target under-pulled"
        );
        assertEq(
            asset.balanceOf(strategyAddr),
            DEPOSIT_AMOUNT / 2,
            "mock invariant: unpulled assets remain idle on the strategy"
        );
    }

    function _assertMaxMintSentinel(address strategyAddr) internal {
        _seedMinimumPosition(strategyAddr, asset, management);

        // Seed a non-zero idle balance so we exercise the subtraction branch;
        // without this the pre-fix code path would coincidentally return the
        // sentinel because `max - 0 == max`.
        asset.mint(strategyAddr, IDLE_SEED);

        assertEq(
            ITokenizedStrategy(strategyAddr).maxMint(user),
            type(uint256).max,
            "maxMint sentinel clobbered by idle-balance subtraction on unbounded vault"
        );
        assertEq(
            ITokenizedStrategy(strategyAddr).maxDeposit(user),
            type(uint256).max,
            "maxDeposit sentinel clobbered by idle-balance subtraction on unbounded vault"
        );
    }

    // ─── Exact-amount approval in `_deployFunds` ──────────────────────

    /// @notice ERC4626Strategy._deployFunds approves exactly `_amount`; no standing allowance.
    function test_erc4626_deployFunds_usesExactApproval() public {
        _assertExactApprovalLifecycle(address(_deployERC4626Strategy()));
    }

    /// @notice MorphoCompounderStrategy._deployFunds approves exactly `_amount`; no standing allowance.
    function test_morphoCompounder_deployFunds_usesExactApproval() public {
        _assertExactApprovalLifecycle(address(_deployMorphoStrategy()));
    }

    /// @notice ERC4626Strategy._deployFunds clears residual allowance if the target under-pulls.
    function test_erc4626_deployFunds_clearsResidualApprovalOnUnderPull() public {
        _assertResidualApprovalClearedOnUnderPull(address(_deployERC4626Strategy()));
    }

    /// @notice MorphoCompounderStrategy._deployFunds clears residual allowance if the target under-pulls.
    function test_morphoCompounder_deployFunds_clearsResidualApprovalOnUnderPull() public {
        _assertResidualApprovalClearedOnUnderPull(address(_deployMorphoStrategy()));
    }

    // ─── Unbounded-capacity sentinel in `availableDepositLimit` ───────

    /// @notice ERC4626Strategy.availableDepositLimit preserves the unbounded-capacity sentinel.
    function test_erc4626_availableDepositLimit_preservesUnboundedSentinel() public {
        _assertMaxMintSentinel(address(_deployERC4626Strategy()));
    }

    /// @notice MorphoCompounderStrategy.availableDepositLimit preserves the unbounded-capacity sentinel.
    function test_morphoCompounder_availableDepositLimit_preservesUnboundedSentinel() public {
        _assertMaxMintSentinel(address(_deployMorphoStrategy()));
    }
}
