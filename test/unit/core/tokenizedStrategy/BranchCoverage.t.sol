// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldSource } from "test/mocks/core/MockYieldSource.sol";
import { MockStrategy as MockBaseStrategy } from "test/mocks/core/MockBaseStrategy.sol";
import { MockIlliquidStrategy } from "test/mocks/core/tokenized-strategies/MockIlliquidStrategy.sol";
import { MockTokenizedStrategyWithLoss } from "test/mocks/core/MockTokenizedStrategyWithLoss.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { TokenizedStrategy__InvalidSigner } from "src/errors.sol";

/// @title TokenizedStrategy Branch Coverage Tests
/// @notice Covers untested branches in TokenizedStrategy
contract TokenizedStrategyBranchCoverageTest is Test {
    MockBaseStrategy strategy;
    MockERC20 asset;
    MockYieldSource yieldSource;
    YieldDonatingTokenizedStrategy implementation;

    address management;
    address keeper;
    address emergencyAdmin;
    address user = address(0x10);
    address spender = address(0x20);

    function setUp() public {
        management = address(this);
        keeper = address(0x2);
        emergencyAdmin = address(0x3);

        asset = new MockERC20(18);
        yieldSource = new MockYieldSource(address(asset));
        implementation = new YieldDonatingTokenizedStrategy();
        strategy = new MockBaseStrategy(address(asset), address(yieldSource), address(implementation));

        // Give user some assets
        asset.mint(user, 100e18);
        asset.mint(address(this), 100e18);
    }

    // --- Permit with invalid signer ---

    function test_permit_invalidSigner_reverts() public {
        uint256 badPk = uint256(keccak256("bad key"));
        address badSigner = vm.addr(badPk);
        address realOwner = address(0xDEAD);
        uint256 deadline = block.timestamp + 1 days;

        // Build digest in a helper to avoid stack-too-deep
        bytes32 digest = _buildPermitDigest(realOwner, spender, 1e18, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badPk, digest);

        // badSigner != realOwner => should revert
        require(badSigner != realOwner, "test setup: signer must differ from owner");
        vm.expectRevert(TokenizedStrategy__InvalidSigner.selector);
        ITokenizedStrategy(address(strategy)).permit(realOwner, spender, 1e18, deadline, v, r, s);
    }

    function _buildPermitDigest(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 deadline_
    ) internal view returns (bytes32) {
        bytes32 EIP712DOMAIN_TYPEHASH = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 PERMIT_TYPEHASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 VERSION_HASH = keccak256(bytes("1.0.0"));
        bytes32 nameHash = keccak256(bytes(ITokenizedStrategy(address(strategy)).name()));
        bytes32 domainSeparator = keccak256(
            abi.encode(EIP712DOMAIN_TYPEHASH, nameHash, VERSION_HASH, block.chainid, address(strategy))
        );
        uint256 nonce = ITokenizedStrategy(address(strategy)).nonces(owner_);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender_, value_, nonce, deadline_));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    // --- Permit with expired deadline ---

    function test_permit_expiredDeadline_reverts() public {
        uint256 pk = uint256(keccak256("owner pk"));
        address owner = vm.addr(pk);
        uint256 deadline = block.timestamp - 1; // already expired

        vm.expectRevert("ERC20: PERMIT_DEADLINE_EXPIRED");
        ITokenizedStrategy(address(strategy)).permit(owner, spender, 1e18, deadline, 27, bytes32(0), bytes32(0));
    }

    // --- DOMAIN_SEPARATOR on chain fork ---

    function test_domainSeparator_rebuildOnChainFork() public {
        bytes32 original = ITokenizedStrategy(address(strategy)).DOMAIN_SEPARATOR();

        // Change chain id
        vm.chainId(999);

        bytes32 newSep = ITokenizedStrategy(address(strategy)).DOMAIN_SEPARATOR();
        assertTrue(original != newSep, "Domain separator should change on chain fork");
    }

    // --- Deposit with max uint ---

    function test_deposit_maxUint_depositsFullBalance() public {
        uint256 amount = 10e18;
        asset.mint(user, amount);

        vm.startPrank(user);
        asset.approve(address(strategy), type(uint256).max);
        uint256 shares = ITokenizedStrategy(address(strategy)).deposit(type(uint256).max, user);
        vm.stopPrank();

        assertGt(shares, 0, "Should have received shares");
        assertEq(asset.balanceOf(user), 0, "Should have deposited full balance");
    }

    // --- Dragon router change flow ---

    function test_setDragonRouter_sameAddress_reverts() public {
        address currentRouter = ITokenizedStrategy(address(strategy)).dragonRouter();
        vm.expectRevert("same dragon router");
        ITokenizedStrategy(address(strategy)).setDragonRouter(currentRouter);
    }

    function test_setDragonRouter_zeroAddress_reverts() public {
        vm.expectRevert("ZERO ADDRESS");
        ITokenizedStrategy(address(strategy)).setDragonRouter(address(0));
    }

    function test_finalizeDragonRouterChange_noPending_reverts() public {
        vm.expectRevert("no pending change");
        ITokenizedStrategy(address(strategy)).finalizeDragonRouterChange();
    }

    function test_finalizeDragonRouterChange_cooldownNotElapsed_reverts() public {
        address newRouter = address(0x999);
        ITokenizedStrategy(address(strategy)).setDragonRouter(newRouter);

        vm.expectRevert("cooldown not elapsed");
        ITokenizedStrategy(address(strategy)).finalizeDragonRouterChange();
    }

    function test_finalizeDragonRouterChange_succeeds() public {
        address newRouter = address(0x999);
        ITokenizedStrategy(address(strategy)).setDragonRouter(newRouter);

        // Warp past cooldown (14 days)
        vm.warp(block.timestamp + 14 days + 1);

        ITokenizedStrategy(address(strategy)).finalizeDragonRouterChange();
        assertEq(ITokenizedStrategy(address(strategy)).dragonRouter(), newRouter);
    }

    function test_cancelDragonRouterChange_noPending_reverts() public {
        vm.expectRevert("no pending change");
        ITokenizedStrategy(address(strategy)).cancelDragonRouterChange();
    }

    function test_cancelDragonRouterChange_succeeds() public {
        address newRouter = address(0x999);
        ITokenizedStrategy(address(strategy)).setDragonRouter(newRouter);

        ITokenizedStrategy(address(strategy)).cancelDragonRouterChange();
        assertEq(ITokenizedStrategy(address(strategy)).pendingDragonRouter(), address(0));
    }

    // --- setPendingManagement / acceptManagement ---

    function test_setPendingManagement_zeroAddress_reverts() public {
        vm.expectRevert("ZERO ADDRESS");
        ITokenizedStrategy(address(strategy)).setPendingManagement(address(0));
    }

    function test_acceptManagement_notPending_reverts() public {
        vm.prank(user);
        vm.expectRevert("!pending");
        ITokenizedStrategy(address(strategy)).acceptManagement();
    }

    function test_acceptManagement_succeeds() public {
        ITokenizedStrategy(address(strategy)).setPendingManagement(user);

        vm.prank(user);
        ITokenizedStrategy(address(strategy)).acceptManagement();
        assertEq(ITokenizedStrategy(address(strategy)).management(), user);
    }

    // --- setKeeper zero address ---

    function test_setKeeper_zeroAddress_reverts() public {
        vm.expectRevert("ZERO ADDRESS");
        ITokenizedStrategy(address(strategy)).setKeeper(address(0));
    }

    // --- setEmergencyAdmin zero address ---

    function test_setEmergencyAdmin_zeroAddress_reverts() public {
        vm.expectRevert("ZERO ADDRESS");
        ITokenizedStrategy(address(strategy)).setEmergencyAdmin(address(0));
    }

    // --- shutdownStrategy + emergencyWithdraw ---

    function test_emergencyWithdraw_notShutdown_reverts() public {
        vm.expectRevert("not shutdown");
        ITokenizedStrategy(address(strategy)).emergencyWithdraw(0);
    }

    function test_emergencyWithdraw_afterShutdown_succeeds() public {
        ITokenizedStrategy(address(strategy)).shutdownStrategy();
        // Should not revert
        ITokenizedStrategy(address(strategy)).emergencyWithdraw(0);
    }

    // --- Withdraw with maxLoss > MAX_BPS ---

    function test_withdraw_maxLossExceedsMaxBps_reverts() public {
        // First deposit
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);

        // Withdraw with maxLoss > 10000
        vm.expectRevert("exceeds MAX_BPS");
        ITokenizedStrategy(address(strategy)).withdraw(1e18, user, user, 10001);
        vm.stopPrank();
    }

    // --- Withdraw to zero receiver ---

    function test_withdraw_zeroReceiver_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);

        vm.expectRevert("ZERO ADDRESS");
        ITokenizedStrategy(address(strategy)).withdraw(1e18, address(0), user, 0);
        vm.stopPrank();
    }

    // --- Transfer to zero address ---

    function test_transfer_toZeroAddress_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);

        vm.expectRevert("ERC20: transfer to the zero address");
        ITokenizedStrategy(address(strategy)).transfer(address(0), 1e18);
        vm.stopPrank();
    }

    // --- Transfer to strategy address ---

    function test_transfer_toStrategyAddress_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);

        vm.expectRevert("ERC20 transfer to strategy");
        ITokenizedStrategy(address(strategy)).transfer(address(strategy), 1e18);
        vm.stopPrank();
    }

    // --- setName updates domain separator ---

    function test_setName_updatesDomainSeparator() public {
        bytes32 before_ = ITokenizedStrategy(address(strategy)).DOMAIN_SEPARATOR();

        ITokenizedStrategy(address(strategy)).setName("New Name");

        bytes32 after_ = ITokenizedStrategy(address(strategy)).DOMAIN_SEPARATOR();
        assertTrue(before_ != after_, "Domain separator should change with name");
    }

    // --- Deposit when shutdown ---

    function test_deposit_whenShutdown_reverts() public {
        ITokenizedStrategy(address(strategy)).shutdownStrategy();

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        vm.expectRevert("ERC4626: deposit more than max");
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        vm.stopPrank();
    }

    // --- Mint when shutdown ---

    function test_mint_whenShutdown_reverts() public {
        ITokenizedStrategy(address(strategy)).shutdownStrategy();

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        vm.expectRevert("ERC4626: mint more than max");
        ITokenizedStrategy(address(strategy)).mint(10e18, user);
        vm.stopPrank();
    }

    // --- Role checks ---

    function test_onlyManagement_reverts() public {
        vm.prank(user);
        vm.expectRevert("!management");
        ITokenizedStrategy(address(strategy)).setKeeper(address(0x999));
    }

    function test_onlyKeepers_reverts() public {
        vm.prank(user);
        vm.expectRevert("!keeper");
        ITokenizedStrategy(address(strategy)).tend();
    }

    function test_onlyEmergencyAuthorized_reverts() public {
        vm.prank(user);
        vm.expectRevert("!emergency authorized");
        ITokenizedStrategy(address(strategy)).shutdownStrategy();
    }

    // --- transferFrom with allowance ---

    function test_transferFrom_insufficientAllowance_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        vm.stopPrank();

        vm.prank(spender);
        vm.expectRevert("ERC20: insufficient allowance");
        ITokenizedStrategy(address(strategy)).transferFrom(user, spender, 1e18);
    }

    function test_transferFrom_withAllowance_succeeds() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        ITokenizedStrategy(address(strategy)).approve(spender, 5e18);
        vm.stopPrank();

        vm.prank(spender);
        ITokenizedStrategy(address(strategy)).transferFrom(user, spender, 5e18);
        assertEq(ITokenizedStrategy(address(strategy)).balanceOf(spender), 5e18);
    }

    // --- Withdraw on behalf with allowance ---

    function test_withdraw_onBehalf_spendsAllowance() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        ITokenizedStrategy(address(strategy)).approve(spender, type(uint256).max);
        vm.stopPrank();

        vm.prank(spender);
        ITokenizedStrategy(address(strategy)).withdraw(1e18, spender, user, 0);
    }

    // --- Permit valid signature succeeds ---

    function test_permit_validSignature_succeeds() public {
        uint256 pk = uint256(keccak256("owner pk"));
        address owner = vm.addr(pk);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = _buildPermitDigest(owner, spender, 1e18, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        ITokenizedStrategy(address(strategy)).permit(owner, spender, 1e18, deadline, v, r, s);
        assertEq(ITokenizedStrategy(address(strategy)).allowance(owner, spender), 1e18);
    }

    // --- setEnableBurning ---

    function test_setEnableBurning_succeeds() public {
        // Default is false from MockBaseStrategy constructor
        assertFalse(ITokenizedStrategy(address(strategy)).enableBurning());

        ITokenizedStrategy(address(strategy)).setEnableBurning(true);
        assertTrue(ITokenizedStrategy(address(strategy)).enableBurning());

        ITokenizedStrategy(address(strategy)).setEnableBurning(false);
        assertFalse(ITokenizedStrategy(address(strategy)).enableBurning());
    }

    function test_setEnableBurning_nonManagement_reverts() public {
        vm.prank(user);
        vm.expectRevert("!management");
        ITokenizedStrategy(address(strategy)).setEnableBurning(true);
    }

    // --- maxDeposit to strategy address returns 0 ---

    function test_maxDeposit_toStrategyAddress_returnsZero() public view {
        assertEq(ITokenizedStrategy(address(strategy)).maxDeposit(address(strategy)), 0);
    }

    // --- maxMint to strategy address returns 0 ---

    function test_maxMint_toStrategyAddress_returnsZero() public view {
        assertEq(ITokenizedStrategy(address(strategy)).maxMint(address(strategy)), 0);
    }

    // --- maxDeposit when shutdown returns 0 ---

    function test_maxDeposit_whenShutdown_returnsZero() public {
        ITokenizedStrategy(address(strategy)).shutdownStrategy();
        assertEq(ITokenizedStrategy(address(strategy)).maxDeposit(user), 0);
    }

    // --- maxMint when shutdown returns 0 ---

    function test_maxMint_whenShutdown_returnsZero() public {
        ITokenizedStrategy(address(strategy)).shutdownStrategy();
        assertEq(ITokenizedStrategy(address(strategy)).maxMint(user), 0);
    }

    // --- redeem with maxLoss ---

    function test_redeem_defaultMaxLoss_succeeds() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);

        // Default redeem (no maxLoss param) should accept any loss
        uint256 assets = ITokenizedStrategy(address(strategy)).redeem(5e18, user, user);
        assertGt(assets, 0);
        vm.stopPrank();
    }

    // --- redeem with explicit maxLoss ---

    function test_redeem_withMaxLoss_succeeds() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);

        uint256 assets = ITokenizedStrategy(address(strategy)).redeem(5e18, user, user, 10000);
        assertGt(assets, 0);
        vm.stopPrank();
    }

    // --- withdraw default (no maxLoss) ---

    function test_withdraw_defaultMaxLoss_succeeds() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);

        uint256 shares = ITokenizedStrategy(address(strategy)).withdraw(5e18, user, user);
        assertGt(shares, 0);
        vm.stopPrank();
    }

    // --- withdraw on behalf with non-max allowance spends it ---

    function test_withdraw_onBehalf_nonMaxAllowance_spendsIt() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        ITokenizedStrategy(address(strategy)).approve(spender, 5e18);
        vm.stopPrank();

        vm.prank(spender);
        ITokenizedStrategy(address(strategy)).withdraw(1e18, spender, user, 0);

        // Allowance should have decreased
        uint256 remaining = ITokenizedStrategy(address(strategy)).allowance(user, spender);
        assertLt(remaining, 5e18);
    }

    // --- transferFrom with max allowance does not decrease ---

    function test_transferFrom_maxAllowance_doesNotDecrease() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        ITokenizedStrategy(address(strategy)).approve(spender, type(uint256).max);
        vm.stopPrank();

        vm.prank(spender);
        ITokenizedStrategy(address(strategy)).transferFrom(user, spender, 1e18);
        assertEq(ITokenizedStrategy(address(strategy)).allowance(user, spender), type(uint256).max);
    }

    // --- Mint with max uint ---

    function test_mint_maxUint_whenShutdown_reverts() public {
        ITokenizedStrategy(address(strategy)).shutdownStrategy();
        vm.startPrank(user);
        vm.expectRevert("ERC4626: mint more than max");
        ITokenizedStrategy(address(strategy)).mint(1, user);
        vm.stopPrank();
    }

    // --- pricePerShare view ---

    function test_pricePerShare_initiallyOne() public view {
        uint256 pps = ITokenizedStrategy(address(strategy)).pricePerShare();
        assertEq(pps, 1e18, "Initial PPS should be 1e18");
    }

    // --- maxWithdraw with maxLoss param ---

    function test_maxWithdraw_withMaxLoss() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        vm.stopPrank();

        // The overloaded maxWithdraw that takes maxLoss should also work
        uint256 maxW = ITokenizedStrategy(address(strategy)).maxWithdraw(user, 0);
        assertEq(maxW, 10e18);
    }

    // --- maxRedeem with maxLoss param ---

    function test_maxRedeem_withMaxLoss() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        vm.stopPrank();

        uint256 maxR = ITokenizedStrategy(address(strategy)).maxRedeem(user, 0);
        assertEq(maxR, 10e18);
    }

    // --- redeem more than max reverts ---

    function test_redeem_moreThanMax_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);

        vm.expectRevert("ERC4626: redeem more than max");
        ITokenizedStrategy(address(strategy)).redeem(100e18, user, user, 10000);
        vm.stopPrank();
    }

    // --- withdraw more than max reverts ---

    function test_withdraw_moreThanMax_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);

        vm.expectRevert("ERC4626: withdraw more than max");
        ITokenizedStrategy(address(strategy)).withdraw(100e18, user, user, 0);
        vm.stopPrank();
    }

    // --- redeem on behalf spends allowance ---

    function test_redeem_onBehalf_spendsAllowance() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        ITokenizedStrategy(address(strategy)).approve(spender, 5e18);
        vm.stopPrank();

        vm.prank(spender);
        ITokenizedStrategy(address(strategy)).redeem(3e18, spender, user, 10000);

        uint256 remaining = ITokenizedStrategy(address(strategy)).allowance(user, spender);
        assertEq(remaining, 2e18);
    }

    // --- API version ---

    function test_apiVersion_returns100() public view {
        string memory version = ITokenizedStrategy(address(strategy)).apiVersion();
        assertEq(keccak256(bytes(version)), keccak256(bytes("1.0.0")));
    }

    // --- getter functions ---

    function test_getters_returnCorrectValues() public view {
        assertEq(ITokenizedStrategy(address(strategy)).management(), address(this));
        assertEq(ITokenizedStrategy(address(strategy)).keeper(), address(this));
        assertEq(ITokenizedStrategy(address(strategy)).emergencyAdmin(), address(this));
        assertTrue(ITokenizedStrategy(address(strategy)).lastReport() > 0);
        assertFalse(ITokenizedStrategy(address(strategy)).isShutdown());
    }

    // --- setName to empty string ---

    function test_setName_succeeds() public {
        ITokenizedStrategy(address(strategy)).setName("Updated Name");
        assertEq(ITokenizedStrategy(address(strategy)).name(), "Updated Name");
    }

    // ================================================================
    // Phase 3: Additional branch coverage tests
    // ================================================================

    /// @dev Storage slot for StrategyData.asset (BASE_STRATEGY_STORAGE + 3)
    /// mappings at offsets 0,1,2 (nonces, balances, allowances), asset at offset 3
    bytes32 internal constant ASSET_SLOT =
        bytes32(uint256(0x4df8983d84042631e7325fb5ba31b73b056fa9890e796c4c95fbf1e6d76eba03));

    /// @dev Deploy a fresh MockTokenizedStrategyWithLoss with asset slot cleared
    ///      so that initialize() can be called on it.
    function _freshLossImpl() internal returns (MockTokenizedStrategyWithLoss impl) {
        impl = new MockTokenizedStrategyWithLoss();
        // The constructor sets asset = ERC20(address(1)). Clear it so initialize works.
        vm.store(address(impl), ASSET_SLOT, bytes32(0));
    }

    // --- setKeeper and setEmergencyAdmin success paths (lines 1379,1392) ---

    function test_setKeeper_succeeds() public {
        address newKeeper = address(0x42);
        ITokenizedStrategy(address(strategy)).setKeeper(newKeeper);
        assertEq(ITokenizedStrategy(address(strategy)).keeper(), newKeeper);
    }

    function test_setEmergencyAdmin_succeeds() public {
        address newAdmin = address(0x43);
        ITokenizedStrategy(address(strategy)).setEmergencyAdmin(newAdmin);
        assertEq(ITokenizedStrategy(address(strategy)).emergencyAdmin(), newAdmin);
    }

    // --- management calling keeper-gated function (line 430, branch 1) ---

    function test_tend_calledByManagement_succeeds() public {
        // Set keeper to a different address, then call tend() as management
        ITokenizedStrategy(address(strategy)).setKeeper(address(0x42));
        // Now call tend() as management (address(this)) — hits the || S.management path
        ITokenizedStrategy(address(strategy)).tend();
    }

    // --- Mint success path (lines 685, branch 0 & 1) ---

    function test_mint_succeeds() public {
        asset.mint(user, 50e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 50e18);
        uint256 assets = ITokenizedStrategy(address(strategy)).mint(10e18, user);
        vm.stopPrank();

        assertGt(assets, 0, "Should have deposited assets");
        assertEq(ITokenizedStrategy(address(strategy)).balanceOf(user), 10e18);
    }

    // --- Deposit zero amount => ZERO_SHARES (line 660, branch 0) ---

    function test_deposit_zeroAmount_reverts() public {
        vm.startPrank(user);
        asset.approve(address(strategy), type(uint256).max);
        vm.expectRevert("ZERO_SHARES");
        ITokenizedStrategy(address(strategy)).deposit(0, user);
        vm.stopPrank();
    }

    // --- Withdraw zero shares (line 727, branch 0) ---

    function test_withdraw_zeroAmount_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);

        vm.expectRevert("ZERO_SHARES");
        ITokenizedStrategy(address(strategy)).withdraw(0, user, user, 0);
        vm.stopPrank();
    }

    // --- Redeem zero assets (line 769, branch 0) ---
    // totalAssets == 0 while totalSupply > 0 => _convertToAssets returns 0

    function test_redeem_zeroAssets_reverts() public {
        MockTokenizedStrategyWithLoss lossImpl = _freshLossImpl();
        lossImpl.initialize(
            address(asset),
            "Loss Strategy",
            "LOSS",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );

        // Mint shares directly (totalSupply > 0, totalAssets == 0)
        lossImpl.mintShares(user, 10e18);

        vm.prank(user);
        vm.expectRevert("ZERO_ASSETS");
        lossImpl.redeem(5e18, user, user, 10000);
    }

    // --- Mint zero assets => ZERO_ASSETS (line 685, branch 0) ---

    function test_mint_zeroAssets_reverts() public {
        MockTokenizedStrategyWithLoss lossImpl = _freshLossImpl();
        lossImpl.initialize(
            address(asset),
            "Loss Strategy",
            "LOSS",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );

        // totalSupply > 0 but totalAssets == 0 => _convertToAssets returns 0
        lossImpl.mintShares(user, 10e18);

        vm.prank(user);
        vm.expectRevert("ZERO_ASSETS");
        lossImpl.mint(1e18, user);
    }

    // --- _convertToShares when totalAssets == 0 (line 961, branch 0) ---

    function test_convertToShares_totalAssetsZero_returnsZero() public {
        MockTokenizedStrategyWithLoss lossImpl = _freshLossImpl();
        lossImpl.initialize(
            address(asset),
            "Loss Strategy",
            "LOSS",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );

        lossImpl.mintShares(user, 10e18);

        uint256 shares = lossImpl.convertToShares(1e18);
        assertEq(shares, 0, "convertToShares should return 0 when totalAssets == 0");
    }

    // --- maxMint with limited deposit (line 995, branch 0) ---

    function test_maxMint_withLimitedDeposit() public {
        MockTokenizedStrategyWithLoss lossImpl = _freshLossImpl();
        lossImpl.initialize(
            address(asset),
            "Limited Strategy",
            "LIM",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );

        lossImpl.setAvailableDepositLimit(100e18);

        uint256 maxMintAmount = lossImpl.maxMint(user);
        assertEq(maxMintAmount, 100e18);
    }

    // --- maxWithdraw with limited withdraw (line 1006, branch 1) ---

    function test_maxWithdraw_withLimitedWithdraw() public {
        MockYieldSource illiqYS = new MockYieldSource(address(asset));
        MockIlliquidStrategy illiqStrat = new MockIlliquidStrategy(
            address(asset),
            address(illiqYS),
            address(this),
            address(this),
            address(this),
            address(0x99),
            address(implementation)
        );

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(illiqStrat), 10e18);
        ITokenizedStrategy(address(illiqStrat)).deposit(10e18, user);
        vm.stopPrank();

        uint256 maxW = ITokenizedStrategy(address(illiqStrat)).maxWithdraw(user);
        // Illiquid deploys half, idle = 5e18. availableWithdrawLimit = idle.
        assertLe(maxW, 10e18);
        assertGt(maxW, 0);
    }

    // --- maxRedeem with limited withdraw (line 1020, branch 1) ---

    function test_maxRedeem_withLimitedWithdraw() public {
        MockYieldSource illiqYS = new MockYieldSource(address(asset));
        MockIlliquidStrategy illiqStrat = new MockIlliquidStrategy(
            address(asset),
            address(illiqYS),
            address(this),
            address(this),
            address(this),
            address(0x99),
            address(implementation)
        );

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(illiqStrat), 10e18);
        ITokenizedStrategy(address(illiqStrat)).deposit(10e18, user);
        vm.stopPrank();

        uint256 maxR = ITokenizedStrategy(address(illiqStrat)).maxRedeem(user);
        assertLe(maxR, 10e18);
        assertGt(maxR, 0);
    }

    // --- Withdrawal with loss path (lines 1106, 1111, 1113) ---

    function test_withdraw_withLoss_exceedsTolerance_reverts() public {
        // MockIlliquidStrategy._freeFunds does nothing => loss on withdraw
        MockYieldSource illiqYS = new MockYieldSource(address(asset));
        MockIlliquidStrategy illiqStrat = new MockIlliquidStrategy(
            address(asset),
            address(illiqYS),
            address(this),
            address(this),
            address(this),
            address(0x99),
            address(implementation)
        );

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(illiqStrat), 10e18);
        ITokenizedStrategy(address(illiqStrat)).deposit(10e18, user);

        // maxWithdraw limits us, but we can use the 4-param withdraw to request
        // an amount within maxWithdraw. The illiquid strategy deploys half (5e18)
        // to the yield source, keeping 5e18 idle.
        // After deposit, idle = 5e18, so maxWithdraw = min(convertToAssets(balance), 5e18) = 5e18.
        // We need to create a scenario where idle < requested after freeFunds.
        // The illiquid strategy's _freeFunds does nothing, so requesting the full
        // maxWithdraw should still work (idle=5e18, request=5e18 => no loss).
        //
        // To test loss: we need to reduce idle balance below what's expected.
        // Let's drain some idle tokens from the strategy after deposit.
        vm.stopPrank();

        // Drain 4e18 from strategy idle (leaving 1e18 idle, 5e18 in yield source)
        // Use vm.prank as the strategy to transfer tokens out
        vm.prank(address(illiqStrat));
        asset.transfer(address(0xdead), 4e18);

        // Now idle=1e18, totalAssets still tracked as 10e18, shares=10e18
        // maxWithdraw = min(convertToAssets(10e18), availableWithdrawLimit)
        // availableWithdrawLimit = asset.balanceOf(strategy) = 1e18
        // So maxWithdraw = 1e18
        // But internally: withdraw(1e18,...) => idle=1e18 >= assets=1e18 => no loss
        // We need idle < requested. Let's use redeem instead which gives us more control.

        // Actually let me construct this differently using MockTokenizedStrategyWithLoss
        // where freeFunds reduces mockTotalAssets but doesn't actually transfer tokens back
        MockTokenizedStrategyWithLoss lossImpl = _freshLossImpl();
        lossImpl.initialize(
            address(asset),
            "Loss Strategy",
            "LOSS",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );

        // Give strategy some idle tokens and set up accounting
        asset.mint(address(lossImpl), 10e18);
        lossImpl.mintShares(user, 10e18);
        lossImpl.setupTestScenario(0, 10e18, 0);

        // Now drain 8e18 from the strategy, leaving only 2e18 idle
        vm.prank(address(lossImpl));
        asset.transfer(address(0xdead), 8e18);

        // idle=2e18, totalAssets=10e18, shares=10e18
        // freeFunds will try to free more but mockTotalAssets tracking reduces
        // After freeFunds: idle might still be 2e18 if nothing is actually freed
        // withdraw(5e18,...) => idle(2e18) < assets(5e18) => call freeFunds(3e18)
        // freeFunds reduces mockTotalAssets but doesn't transfer real tokens
        // After freeFunds: idle still 2e18 < assets(5e18) => loss = 3e18
        // maxLoss=0 => require(3e18 <= (5e18 * 0) / 10000) => require(3e18 <= 0) => revert

        vm.prank(user);
        vm.expectRevert("too much loss");
        lossImpl.withdraw(5e18, user, user, 0);
    }

    function test_withdraw_withLoss_withinTolerance_succeeds() public {
        MockTokenizedStrategyWithLoss lossImpl = _freshLossImpl();
        lossImpl.initialize(
            address(asset),
            "Loss Strategy",
            "LOSS",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );

        asset.mint(address(lossImpl), 10e18);
        lossImpl.mintShares(user, 10e18);
        lossImpl.setupTestScenario(0, 10e18, 0);

        // Drain 8e18, leaving 2e18 idle
        vm.prank(address(lossImpl));
        asset.transfer(address(0xdead), 8e18);

        // withdraw(5e18) => idle=2e18 < 5e18 => freeFunds(3e18) => still 2e18 idle
        // loss = 3e18, maxLoss=10000 (100%) => 3e18 <= (5e18 * 10000)/10000 = 5e18 => OK
        vm.prank(user);
        lossImpl.withdraw(5e18, user, user, 10000);

        // User should have received 2e18 (the idle amount)
        assertEq(asset.balanceOf(user), 100e18 + 2e18); // user had 100e18 from setUp
    }

    function test_redeem_withLoss_defaultMaxLoss_succeeds() public {
        MockTokenizedStrategyWithLoss lossImpl = _freshLossImpl();
        lossImpl.initialize(
            address(asset),
            "Loss Strategy",
            "LOSS",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );

        asset.mint(address(lossImpl), 10e18);
        lossImpl.mintShares(user, 10e18);
        lossImpl.setupTestScenario(0, 10e18, 0);

        // Drain 5e18, leaving 5e18 idle
        vm.prank(address(lossImpl));
        asset.transfer(address(0xdead), 5e18);

        // Redeem all shares via 3-param version (maxLoss=MAX_BPS)
        vm.prank(user);
        uint256 assets = lossImpl.redeem(10e18, user, user);
        // Should succeed but return less than deposited (loss accepted)
        assertLt(assets, 10e18, "Should have received less due to loss");
    }

    // --- Initialize already initialized (line 591, branch 0) ---

    function test_initialize_alreadyInitialized_reverts() public {
        vm.expectRevert("initialized");
        ITokenizedStrategy(address(strategy)).initialize(
            address(asset),
            "Dup",
            "DUP",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );
    }

    // --- Initialize with zero addresses (lines 606, 610, 614, 618) ---

    function test_initialize_zeroManagement_reverts() public {
        MockTokenizedStrategyWithLoss impl = _freshLossImpl();
        vm.expectRevert("ZERO ADDRESS");
        impl.initialize(address(asset), "Test", "TST", address(0), address(this), address(this), address(0x99), false);
    }

    function test_initialize_zeroKeeper_reverts() public {
        MockTokenizedStrategyWithLoss impl = _freshLossImpl();
        vm.expectRevert("ZERO ADDRESS");
        impl.initialize(address(asset), "Test", "TST", address(this), address(0), address(this), address(0x99), false);
    }

    function test_initialize_zeroEmergencyAdmin_reverts() public {
        MockTokenizedStrategyWithLoss impl = _freshLossImpl();
        vm.expectRevert("ZERO ADDRESS");
        impl.initialize(address(asset), "Test", "TST", address(this), address(this), address(0), address(0x99), false);
    }

    function test_initialize_zeroDragonRouter_reverts() public {
        MockTokenizedStrategyWithLoss impl = _freshLossImpl();
        vm.expectRevert("ZERO ADDRESS");
        impl.initialize(address(asset), "Test", "TST", address(this), address(this), address(this), address(0), false);
    }

    // --- Deposit to strategy address returns 0 in maxDeposit => reverts (line 984) ---

    function test_deposit_toStrategyAddress_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        vm.expectRevert("ERC4626: deposit more than max");
        ITokenizedStrategy(address(strategy)).deposit(1e18, address(strategy));
        vm.stopPrank();
    }

    // --- Mint to strategy address returns 0 in maxMint => reverts (line 992) ---

    function test_mint_toStrategyAddress_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        vm.expectRevert("ERC4626: mint more than max");
        ITokenizedStrategy(address(strategy)).mint(1e18, address(strategy));
        vm.stopPrank();
    }

    // --- Report profit path (YieldDonating report) ---

    function test_report_profitPath_mintsSharesToDragonRouter() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        vm.stopPrank();

        // Simulate yield: mint extra tokens to the yield source
        asset.mint(address(yieldSource), 2e18);

        ITokenizedStrategy(address(strategy)).report();

        address dr = ITokenizedStrategy(address(strategy)).dragonRouter();
        uint256 dragonShares = ITokenizedStrategy(address(strategy)).balanceOf(dr);
        assertGt(dragonShares, 0, "Dragon router should have received profit shares");
    }

    // --- Report loss path (YieldDonating report) ---

    function test_report_lossPath_noProfit() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        vm.stopPrank();

        // Simulate loss: burn tokens from the yield source by sending to dead address
        // simulateLoss transfers from yield source to msg.sender (strategy) which doesn't reduce total
        // Instead, directly burn from yield source
        vm.prank(address(yieldSource));
        asset.transfer(address(0xdead), 2e18);

        ITokenizedStrategy(address(strategy)).report();

        uint256 ta = ITokenizedStrategy(address(strategy)).totalAssets();
        assertLt(ta, 10e18, "Total assets should have decreased due to loss");
    }

    // --- Report loss path with burning enabled ---

    function test_report_lossPath_withBurning() public {
        ITokenizedStrategy(address(strategy)).setEnableBurning(true);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        vm.stopPrank();

        // Generate profit first so dragon router has shares to burn
        asset.mint(address(yieldSource), 2e18);
        ITokenizedStrategy(address(strategy)).report();

        address dr = ITokenizedStrategy(address(strategy)).dragonRouter();
        uint256 dragonSharesBefore = ITokenizedStrategy(address(strategy)).balanceOf(dr);
        assertGt(dragonSharesBefore, 0, "Dragon should have shares from profit");

        // Now simulate a loss by burning from yield source
        vm.prank(address(yieldSource));
        asset.transfer(address(0xdead), 1e18);

        ITokenizedStrategy(address(strategy)).report();

        uint256 dragonSharesAfter = ITokenizedStrategy(address(strategy)).balanceOf(dr);
        assertLt(dragonSharesAfter, dragonSharesBefore, "Dragon shares should have been burned");
    }

    // --- Report zero-profit zero-loss path (loss==0 branch in YieldDonating) ---

    function test_report_noChange_noProfitNoLoss() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        vm.stopPrank();

        ITokenizedStrategy(address(strategy)).report();

        uint256 ta = ITokenizedStrategy(address(strategy)).totalAssets();
        assertEq(ta, 10e18, "Total assets should remain unchanged");
    }

    // --- Withdraw where idle >= assets (no freeFunds needed, line 1096 false) ---

    function test_withdraw_idleSufficient_noFreeFundsNeeded() public {
        MockTokenizedStrategyWithLoss lossImpl = _freshLossImpl();
        lossImpl.initialize(
            address(asset),
            "Idle Strategy",
            "IDLE",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );

        asset.mint(address(lossImpl), 10e18);
        lossImpl.mintShares(user, 10e18);
        lossImpl.setupTestScenario(0, 10e18, 0);

        vm.prank(user);
        lossImpl.withdraw(5e18, user, user, 0);

        assertEq(asset.balanceOf(user), 100e18 + 5e18); // user had 100e18 from setUp
    }

    // --- Redeem on behalf with max allowance doesn't decrease ---

    function test_redeem_onBehalf_maxAllowance_doesNotDecrease() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        ITokenizedStrategy(address(strategy)).approve(spender, type(uint256).max);
        vm.stopPrank();

        vm.prank(spender);
        ITokenizedStrategy(address(strategy)).redeem(3e18, spender, user, 10000);

        assertEq(ITokenizedStrategy(address(strategy)).allowance(user, spender), type(uint256).max);
    }

    // --- emergencyAdmin can shutdown (line 442 || branch) ---

    function test_shutdownStrategy_byEmergencyAdmin() public {
        // Set a different emergencyAdmin to truly test the || branch (not management)
        ITokenizedStrategy(address(strategy)).setEmergencyAdmin(address(0x55));
        vm.prank(address(0x55));
        ITokenizedStrategy(address(strategy)).shutdownStrategy();
        assertTrue(ITokenizedStrategy(address(strategy)).isShutdown());
    }

    // --- emergencyAdmin can emergency withdraw ---

    function test_emergencyWithdraw_byEmergencyAdmin() public {
        ITokenizedStrategy(address(strategy)).setEmergencyAdmin(address(0x55));
        ITokenizedStrategy(address(strategy)).shutdownStrategy();

        vm.prank(address(0x55));
        ITokenizedStrategy(address(strategy)).emergencyWithdraw(0);
    }

    // --- Keeper (not management) calls report ---

    function test_report_calledByKeeper_succeeds() public {
        address newKeeper = address(0x77);
        ITokenizedStrategy(address(strategy)).setKeeper(newKeeper);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(strategy), 10e18);
        ITokenizedStrategy(address(strategy)).deposit(10e18, user);
        vm.stopPrank();

        vm.prank(newKeeper);
        ITokenizedStrategy(address(strategy)).report();
    }

    // --- maxMint with limited deposit converting shares (line 995) ---

    function test_maxMint_limitedDeposit_convertsToShares() public {
        MockTokenizedStrategyWithLoss lossImpl = _freshLossImpl();
        lossImpl.initialize(
            address(asset),
            "Lim Strategy",
            "LIM",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );

        // Set up supply and assets with different PPS
        lossImpl.mintShares(address(0xAA), 10e18);
        lossImpl.setupTestScenario(0, 20e18, 0); // PPS = 2

        lossImpl.setAvailableDepositLimit(10e18);

        uint256 maxMintAmount = lossImpl.maxMint(user);
        // PPS=2, 10e18 assets = 5e18 shares
        assertEq(maxMintAmount, 5e18, "maxMint should convert limited deposit to shares");
    }

    // --- maxWithdraw with limited withdraw (MockTokenizedStrategyWithLoss) ---

    function test_maxWithdraw_limitedWithdrawLimit() public {
        MockTokenizedStrategyWithLoss lossImpl = _freshLossImpl();
        lossImpl.initialize(
            address(asset),
            "Lim Strategy",
            "LIM",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );

        lossImpl.mintShares(user, 10e18);
        lossImpl.setupTestScenario(0, 10e18, 0);

        lossImpl.setAvailableWithdrawLimit(5e18);

        uint256 maxW = lossImpl.maxWithdraw(user);
        assertEq(maxW, 5e18, "maxWithdraw should be capped by withdraw limit");
    }

    // --- maxRedeem with limited withdraw (MockTokenizedStrategyWithLoss) ---

    function test_maxRedeem_limitedWithdrawLimit() public {
        MockTokenizedStrategyWithLoss lossImpl = _freshLossImpl();
        lossImpl.initialize(
            address(asset),
            "Lim Strategy",
            "LIM",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );

        lossImpl.mintShares(user, 10e18);
        lossImpl.setupTestScenario(0, 10e18, 0);

        lossImpl.setAvailableWithdrawLimit(5e18);

        uint256 maxR = lossImpl.maxRedeem(user);
        assertEq(maxR, 5e18, "maxRedeem should be capped by withdraw limit in shares");
    }

    // --- Withdraw with non-default maxLoss < MAX_BPS and loss within tolerance (line 1111 true, 1113 true) ---

    function test_withdraw_withLoss_nonDefaultMaxLoss_withinTolerance() public {
        MockTokenizedStrategyWithLoss lossImpl = _freshLossImpl();
        lossImpl.initialize(
            address(asset),
            "Loss Strategy",
            "LOSS",
            address(this),
            address(this),
            address(this),
            address(0x99),
            false
        );

        asset.mint(address(lossImpl), 10e18);
        lossImpl.mintShares(user, 10e18);
        lossImpl.setupTestScenario(0, 10e18, 0);

        // Drain 1e18, leaving 9e18 idle
        vm.prank(address(lossImpl));
        asset.transfer(address(0xdead), 1e18);

        // withdraw(10e18,...) => idle=9e18 < 10e18 => freeFunds(1e18) => still 9e18
        // loss = 1e18, maxLoss = 1000 (10%)
        // require(1e18 <= (10e18 * 1000) / 10000) => require(1e18 <= 1e18) => OK
        vm.prank(user);
        lossImpl.withdraw(10e18, user, user, 1000);
    }

    // --- approve(address(0), ...) hits _approve spender-zero check (line 1701) ---

    function test_approve_zeroSpender_reverts() public {
        vm.prank(user);
        vm.expectRevert("ERC20: approve to the zero address");
        ITokenizedStrategy(address(strategy)).approve(address(0), 1e18);
    }

    // --- transferFrom(address(0), ..., 0) hits _approve owner-zero check (line 1700) ---

    function test_transferFrom_fromZeroAddress_reverts() public {
        // transferFrom(address(0), to, 0):
        //   _spendAllowance(0x0, msg.sender, 0) => allowance=0 != max => _approve(0x0, ...) =>
        //   require(owner != address(0)) reverts with "ERC20: approve from the zero address"
        vm.prank(user);
        vm.expectRevert("ERC20: approve from the zero address");
        ITokenizedStrategy(address(strategy)).transferFrom(address(0), user, 0);
    }
}
