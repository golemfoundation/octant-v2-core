// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.25;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { ERC4626Fees } from "@openzeppelin/contracts/mocks/docs/ERC4626Fees.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";

import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ERC4626Strategy } from "src/strategies/yieldDonating/ERC4626Strategy.sol";
import { YearnV3Strategy } from "src/strategies/yieldDonating/YearnV3Strategy.sol";
import { MorphoCompounderStrategy } from "src/strategies/yieldDonating/MorphoCompounderStrategy.sol";
import { SeedHelpers } from "./utils/SeedHelpers.sol";

/// @notice ERC4626 target vault that charges an exit fee, so `previewRedeem(shares)` < `convertToAssets(shares)`.
/// @dev Uses OpenZeppelin's docs-level ERC4626Fees reference to keep fee accounting EIP-4626 compliant.
contract ExitFeeVaultMock is ERC4626Fees {
    uint256 private immutable _exitFeeBps;

    constructor(
        IERC20 underlying_,
        string memory name_,
        string memory symbol_,
        uint256 exitFeeBps_
    ) ERC20(name_, symbol_) ERC4626(underlying_) {
        _exitFeeBps = exitFeeBps_;
    }

    function _exitFeeBasisPoints() internal view override returns (uint256) {
        return _exitFeeBps;
    }

    function _exitFeeRecipient() internal view override returns (address) {
        return address(this);
    }
}

/// @title Bailsec #54 -- `_harvestAndReport` must net out target-vault exit fees
/// @notice Pre-fix the yield-donating strategies valued their target-vault positions via
///         `convertToAssets`, which overstates totalAssets by the target vault's exit fee.
///         Post-fix they use `previewRedeem`, the EIP-4626 view required to reflect any exit-fee
///         policy. Exercised across `ERC4626Strategy`, `YearnV3Strategy`, and
///         `MorphoCompounderStrategy`; `SparkStrategy` inherits the fix from `ERC4626Strategy`.
contract BailsecPreviewRedeemTest is SeedHelpers {
    ERC20Mock internal asset;
    YieldDonatingTokenizedStrategy internal implementation;
    ExitFeeVaultMock internal targetVault;

    address internal management = address(0xA1);
    address internal keeper = address(0xA2);
    address internal emergencyAdmin = address(0xA3);
    address internal donationAddress = address(0xA4);
    address internal user = address(0xBEEF);

    uint256 internal constant EXIT_FEE_BPS = 500; // 5%
    uint256 internal constant DEPOSIT_AMOUNT = 1_000 ether;

    function setUp() public {
        asset = new ERC20Mock();
        targetVault = new ExitFeeVaultMock(IERC20(address(asset)), "Exit Fee Vault", "EFV", EXIT_FEE_BPS);
        implementation = new YieldDonatingTokenizedStrategy();
    }

    function _depositThenReport(address strategyAddr) internal {
        _seedMinimumPosition(strategyAddr, asset, management);

        asset.mint(user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        asset.approve(strategyAddr, DEPOSIT_AMOUNT);
        ITokenizedStrategy(strategyAddr).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();

        // Post-fix, _harvestAndReport returns previewRedeem which is strictly less than the deposit
        // because of the exit fee. The default lossLimitRatio is zero, so the health check would
        // veto any loss; disable it for this report.
        vm.prank(management);
        (bool ok, ) = strategyAddr.call(abi.encodeWithSignature("setDoHealthCheck(bool)", false));
        require(ok, "setDoHealthCheck failed");

        vm.prank(keeper);
        ITokenizedStrategy(strategyAddr).report();
    }

    function _assertTotalAssetsMatchesPreviewRedeem(address strategyAddr) internal view {
        uint256 vaultShares = targetVault.balanceOf(strategyAddr);
        uint256 idle = asset.balanceOf(strategyAddr);
        uint256 expected = targetVault.previewRedeem(vaultShares) + idle;
        uint256 convertValue = targetVault.convertToAssets(vaultShares) + idle;

        assertLt(expected, convertValue, "mock invariant: previewRedeem < convertToAssets");
        assertEq(
            ITokenizedStrategy(strategyAddr).totalAssets(),
            expected,
            "totalAssets must equal previewRedeem-based valuation (net of exit fee)"
        );
    }

    function test_bailsec_54_ERC4626Strategy_harvestUsesPreviewRedeem() public {
        ERC4626Strategy strategy = new ERC4626Strategy(
            address(targetVault),
            address(asset),
            "Octant ERC4626 Bailsec",
            "osBailsecE",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
        _depositThenReport(address(strategy));
        _assertTotalAssetsMatchesPreviewRedeem(address(strategy));
    }

    function test_bailsec_54_YearnV3Strategy_harvestUsesPreviewRedeem() public {
        YearnV3Strategy strategy = new YearnV3Strategy(
            address(targetVault),
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
        _depositThenReport(address(strategy));
        _assertTotalAssetsMatchesPreviewRedeem(address(strategy));
    }

    function test_bailsec_54_MorphoCompounderStrategy_harvestUsesPreviewRedeem() public {
        MorphoCompounderStrategy strategy = new MorphoCompounderStrategy(
            address(targetVault),
            address(asset),
            "Octant Morpho Bailsec",
            "osBailsecM",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
        _depositThenReport(address(strategy));
        _assertTotalAssetsMatchesPreviewRedeem(address(strategy));
    }
}
