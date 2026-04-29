// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.25;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { YearnV3Strategy } from "src/strategies/yieldDonating/YearnV3Strategy.sol";
import { SeedHelpers } from "./utils/SeedHelpers.sol";

/// @notice Minimal Yearn-v3-shaped vault that mints 1:1 shares and pulls exactly `assets`.
/// @dev Exposes just enough `ITokenizedStrategy` surface for the constructor + deposit + deploy
///      flow; does not model real yield, fees, or withdrawals.
contract PassthroughVaultMock {
    address public immutable asset;

    mapping(address => uint256) private _shares;

    constructor(address underlying) {
        asset = underlying;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256) {
        IERC20(asset).transferFrom(msg.sender, address(this), assets);
        _shares[receiver] += assets;
        return assets;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _shares[owner];
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares;
    }
}

/// @notice Yearn-v3-shaped vault that intentionally pulls less than approved.
/// @dev Models a broken or hostile target upgrade that returns non-zero shares
///      without consuming the full allowance. The strategy must still clear the
///      residual approval after the call.
contract UnderPullVaultMock {
    address public immutable asset;
    uint256 public immutable pullBps;

    mapping(address => uint256) private _shares;

    constructor(address underlying, uint256 _pullBps) {
        asset = underlying;
        pullBps = _pullBps;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = (assets * pullBps) / 10_000;
        IERC20(asset).transferFrom(msg.sender, address(this), shares);
        _shares[receiver] += shares;
    }

    function balanceOf(address owner) external view returns (uint256) {
        return _shares[owner];
    }

    function maxDeposit(address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return 0;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares;
    }
}

/// @title Bailsec #50 / #60 -- `YearnV3Strategy` must not hold a standing max approval on its target
/// @notice Pre-fix the constructor granted `type(uint256).max` on the asset to the Yearn vault,
///         exposing the full idle balance to any hostile upgrade of the (upgradeable-proxy) vault.
///         Post-fix the allowance is granted per-deploy in `_deployFunds` and explicitly cleared
///         after the vault call, even if the target under-pulls.
contract BailsecExactApprovalYearnV3Test is SeedHelpers {
    ERC20Mock internal asset;
    YieldDonatingTokenizedStrategy internal implementation;
    PassthroughVaultMock internal yearnVault;
    YearnV3Strategy internal strategy;

    address internal management = address(0xA1);
    address internal keeper = address(0xA2);
    address internal emergencyAdmin = address(0xA3);
    address internal donationAddress = address(0xA4);
    address internal user = address(0xBEEF);

    uint256 internal constant DEPOSIT_AMOUNT = 1_000 ether;

    function setUp() public {
        asset = new ERC20Mock();
        yearnVault = new PassthroughVaultMock(address(asset));
        implementation = new YieldDonatingTokenizedStrategy();

        strategy = new YearnV3Strategy(
            address(yearnVault),
            address(asset),
            "Octant Yearn Bailsec",
            "osBailsecY",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
    }

    function test_bailsec_60_constructorLeavesNoStandingApproval() public view {
        // Pre-fix this is `type(uint256).max`; post-fix the constructor no longer approves the vault.
        assertEq(
            asset.allowance(address(strategy), address(yearnVault)),
            0,
            "constructor must not leave a standing approval to the target vault"
        );
    }

    function test_bailsec_60_deployFundsLeavesZeroAllowance() public {
        _seedMinimumPosition(address(strategy), asset, management);

        asset.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        asset.approve(address(strategy), DEPOSIT_AMOUNT);
        ITokenizedStrategy(address(strategy)).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();

        // Post-fix `_deployFunds` forceApproves exactly `_amount` and the vault pulls the full amount,
        // so the resulting allowance is zero. Pre-fix the constructor approved `type(uint256).max` and
        // the vault's pull only consumed `_amount`, leaving (max - amount) as a standing claim.
        assertEq(
            asset.allowance(address(strategy), address(yearnVault)),
            0,
            "allowance to the target vault must settle to zero after _deployFunds"
        );
    }

    function test_bailsec_60_deployFundsClearsResidualAllowanceIfVaultUnderPulls() public {
        uint256 pullBps = 5_000;
        UnderPullVaultMock underPullVault = new UnderPullVaultMock(address(asset), pullBps);
        YearnV3Strategy underPullStrategy = new YearnV3Strategy(
            address(underPullVault),
            address(asset),
            "Octant Yearn Bailsec UnderPull",
            "osBailsecYUP",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
        _seedMinimumPosition(address(underPullStrategy), asset, management);

        asset.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        asset.approve(address(underPullStrategy), DEPOSIT_AMOUNT);
        ITokenizedStrategy(address(underPullStrategy)).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();

        assertEq(
            asset.allowance(address(underPullStrategy), address(underPullVault)),
            0,
            "residual allowance must be cleared even if the target vault under-pulls"
        );
        assertEq(
            asset.balanceOf(address(underPullStrategy)),
            (DEPOSIT_AMOUNT + MINIMUM_PROTOCOL_POSITION / 2) / 2,
            "mock invariant: unpulled assets remain idle on the strategy"
        );
    }
}
