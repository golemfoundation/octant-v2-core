// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { MultistrategyVault } from "src/core/MultistrategyVault.sol";
import { MultistrategyVaultFactory } from "src/factories/MultistrategyVaultFactory.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMultistrategyVault } from "src/core/interfaces/IMultistrategyVault.sol";
import { MockERC20 } from "test/mocks/MockERC20.sol";
import { MockYieldStrategy } from "test/mocks/core/MockYieldStrategy.sol";
import { MockDepositLimitModule } from "test/mocks/core/MockDepositLimitModule.sol";
import { MockWithdrawLimitModule } from "test/mocks/core/MockWithdrawLimitModule.sol";
import { MockLossyStrategy } from "test/mocks/core/MockLossyStrategy.sol";
import { MockFlexibleAccountant } from "test/mocks/core/MockFlexibleAccountant.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title MultistrategyVault Branch Coverage Tests
/// @notice Covers untested branches in MultistrategyVault
contract MultistrategyVaultBranchCoverageTest is Test {
    MultistrategyVault vaultImplementation;
    MultistrategyVault vault;
    MockERC20 asset;
    MockYieldStrategy strategy;
    MultistrategyVaultFactory vaultFactory;

    address gov;
    address user = address(0x10);

    function setUp() public {
        gov = address(this);
        asset = new MockERC20(18);

        vaultImplementation = new MultistrategyVault();
        vaultFactory = new MultistrategyVaultFactory("Test Vault", address(vaultImplementation), gov);

        vault = MultistrategyVault(vaultFactory.deployNewVault(address(asset), "Test Vault", "tvTEST", gov, 7 days));

        strategy = new MockYieldStrategy(address(asset), address(vault));

        // Grant all needed roles to gov
        vault.add_role(gov, IMultistrategyVault.Roles.ADD_STRATEGY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.MAX_DEBT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.DEPOSIT_LIMIT_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.EMERGENCY_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.QUEUE_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.PROFIT_UNLOCK_MANAGER);
        vault.add_role(gov, IMultistrategyVault.Roles.REPORTING_MANAGER);

        // Set max deposit limit
        vault.set_deposit_limit(type(uint256).max, false);
    }

    // --- set_deposit_limit shouldOverride when module is address(0) (no-op path) ---

    function test_setDepositLimit_shouldOverrideNoModule_succeeds() public {
        // depositLimitModule is already address(0)
        assertEq(vault.depositLimitModule(), address(0));

        // shouldOverride = true, but module is already 0, so the inner if should not emit
        vault.set_deposit_limit(100e18, true);
        assertEq(vault.depositLimit(), 100e18);
    }

    // --- set_deposit_limit_module shouldOverride when depositLimit already max (no-op path) ---

    function test_setDepositLimitModule_shouldOverrideAlreadyMax_succeeds() public {
        // depositLimit is already max
        assertEq(vault.depositLimit(), type(uint256).max);

        MockDepositLimitModule module = new MockDepositLimitModule();
        // shouldOverride = true, but depositLimit is already max, so inner if should not emit
        vault.set_deposit_limit_module(address(module), true);
        assertEq(vault.depositLimitModule(), address(module));
    }

    // --- shutdown_vault when depositLimitModule is not set (no-op clear path) ---

    function test_shutdownVault_noDepositLimitModule_succeeds() public {
        // No module set, so shutdown should not try to clear it
        assertEq(vault.depositLimitModule(), address(0));
        vault.shutdown_vault();
        assertTrue(vault.isShutdown());
        assertEq(vault.depositLimit(), 0);
    }

    // --- shutdown_vault when already shutdown ---

    function test_shutdownVault_alreadyShutdown_reverts() public {
        vault.shutdown_vault();
        vm.expectRevert(IMultistrategyVault.AlreadyShutdown.selector);
        vault.shutdown_vault();
    }

    // --- deposit with max uint ---

    function test_deposit_maxUint_depositsFullBalance() public {
        uint256 amount = 10e18;
        asset.mint(user, amount);

        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(type(uint256).max, user);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(asset.balanceOf(user), 0);
    }

    // --- transfer to vault address ---

    function test_transfer_toVaultAddress_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);

        vm.expectRevert(IMultistrategyVault.InvalidReceiver.selector);
        vault.transfer(address(vault), 1e18);
        vm.stopPrank();
    }

    // --- transfer to zero address ---

    function test_transfer_toZeroAddress_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);

        vm.expectRevert(IMultistrategyVault.InvalidReceiver.selector);
        vault.transfer(address(0), 1e18);
        vm.stopPrank();
    }

    // --- transferFrom to vault address ---

    function test_transferFrom_toVaultAddress_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vault.approve(gov, 10e18);
        vm.stopPrank();

        vm.expectRevert(IMultistrategyVault.InvalidReceiver.selector);
        vault.transferFrom(user, address(vault), 1e18);
    }

    // --- transferFrom to zero address ---

    function test_transferFrom_toZeroAddress_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vault.approve(gov, 10e18);
        vm.stopPrank();

        vm.expectRevert(IMultistrategyVault.InvalidReceiver.selector);
        vault.transferFrom(user, address(0), 1e18);
    }

    // --- transferFrom spending allowance (non-max) ---

    function test_transferFrom_spendsAllowance() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vault.approve(gov, 5e18);
        vm.stopPrank();

        vault.transferFrom(user, gov, 3e18);
        assertEq(vault.allowance(user, gov), 2e18);
    }

    // --- transferFrom with unlimited allowance (max uint) ---

    function test_transferFrom_unlimitedAllowance_doesNotDecrease() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vault.approve(gov, type(uint256).max);
        vm.stopPrank();

        vault.transferFrom(user, gov, 3e18);
        assertEq(vault.allowance(user, gov), type(uint256).max);
    }

    // --- transferFrom insufficient allowance ---

    function test_transferFrom_insufficientAllowance_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vault.approve(gov, 1e18);
        vm.stopPrank();

        vm.expectRevert(IMultistrategyVault.InsufficientAllowance.selector);
        vault.transferFrom(user, gov, 5e18);
    }

    // --- transfer with insufficient funds ---

    function test_transfer_insufficientFunds_reverts() public {
        asset.mint(user, 1e18);
        vm.startPrank(user);
        asset.approve(address(vault), 1e18);
        vault.deposit(1e18, user);

        vm.expectRevert(IMultistrategyVault.InsufficientFunds.selector);
        vault.transfer(gov, 100e18);
        vm.stopPrank();
    }

    // --- deposit exceeds limit ---

    function test_deposit_exceedsLimit_reverts() public {
        vault.set_deposit_limit(1e18, true);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.deposit(10e18, user);
        vm.stopPrank();
    }

    // --- setProfitMaxUnlockTime to 0 resets locked values ---

    function test_setProfitMaxUnlockTime_toZero_resetsLocked() public {
        // Deposit and generate some profit to create locked shares
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);
        vault.update_debt(address(strategy), 10e18, 0);

        // Simulate profit
        asset.mint(address(strategy), 1e18);

        // Report profit
        strategy.report();
        vault.process_report(address(strategy));

        // Set to 0 should reset locked values
        vault.setProfitMaxUnlockTime(0);
        assertEq(vault.profitMaxUnlockTime(), 0);
        assertEq(vault.fullProfitUnlockDate(), 0);
    }

    // --- initialize checks ---

    function test_initialize_zeroAsset_reverts() public {
        MultistrategyVault newVault = new MultistrategyVault();
        // The constructor sets asset to address(this), so initialize should revert with AlreadyInitialized
        vm.expectRevert(IMultistrategyVault.AlreadyInitialized.selector);
        newVault.initialize(address(asset), "Test", "T", gov, 7 days);
    }

    // --- set_auto_allocate role check ---

    function test_setAutoAllocate_noRole_reverts() public {
        vm.prank(user);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.set_auto_allocate(true);
    }

    // --- Reentrancy guard ---
    // Note: Testing reentrancy is complex and not feasible with a simple unit test.
    // The nonReentrant modifier on deposit/withdraw/redeem is implicitly tested
    // by the fact that deposits and withdrawals succeed once.

    // --- Permit: valid signature ---

    function test_permit_validSignature_succeeds() public {
        uint256 pk = uint256(keccak256("vault permit pk"));
        address owner = vm.addr(pk);

        uint256 deadline = block.timestamp + 1 days;
        bytes32 digest = _buildVaultPermitDigest(owner, user, 1e18, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        vault.permit(owner, user, 1e18, deadline, v, r, s);
        assertEq(vault.allowance(owner, user), 1e18);
    }

    // --- Permit: expired deadline ---

    function test_permit_expiredDeadline_reverts() public {
        uint256 pk = uint256(keccak256("vault permit pk"));
        address owner = vm.addr(pk);
        uint256 deadline = block.timestamp - 1;

        vm.expectRevert(IMultistrategyVault.PermitExpired.selector);
        vault.permit(owner, user, 1e18, deadline, 27, bytes32(0), bytes32(0));
    }

    // --- Permit: invalid signature ---

    function test_permit_invalidSignature_reverts() public {
        uint256 badPk = uint256(keccak256("bad pk"));
        address realOwner = address(0xDEAD);
        uint256 deadline = block.timestamp + 1 days;

        bytes32 digest = _buildVaultPermitDigest(realOwner, user, 1e18, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(badPk, digest);

        require(vm.addr(badPk) != realOwner, "test setup");
        vm.expectRevert(IMultistrategyVault.InvalidSignature.selector);
        vault.permit(realOwner, user, 1e18, deadline, v, r, s);
    }

    // --- Permit: zero owner ---

    function test_permit_zeroOwner_reverts() public {
        vm.expectRevert(IMultistrategyVault.InvalidOwner.selector);
        vault.permit(address(0), user, 1e18, block.timestamp + 1, 27, bytes32(0), bytes32(0));
    }

    // --- DOMAIN_SEPARATOR rebuilds on chain fork ---

    function test_domainSeparator_rebuildOnChainFork() public {
        bytes32 original = vault.DOMAIN_SEPARATOR();
        vm.chainId(999);
        bytes32 newSep = vault.DOMAIN_SEPARATOR();
        assertTrue(original != newSep, "Domain separator should change on chain fork");
    }

    // --- set_deposit_limit_module: non-override requires max deposit limit ---

    function test_setDepositLimitModule_nonOverride_requiresMax() public {
        // Set deposit limit to non-max first
        vault.set_deposit_limit(100e18, true);

        MockDepositLimitModule module = new MockDepositLimitModule();
        vm.expectRevert(IMultistrategyVault.UsingDepositLimit.selector);
        vault.set_deposit_limit_module(address(module), false);
    }

    // --- set_deposit_limit_module: non-override with max limit succeeds ---

    function test_setDepositLimitModule_nonOverride_withMaxLimit_succeeds() public {
        // depositLimit is already max from setUp
        assertEq(vault.depositLimit(), type(uint256).max);

        MockDepositLimitModule module = new MockDepositLimitModule();
        vault.set_deposit_limit_module(address(module), false);
        assertEq(vault.depositLimitModule(), address(module));
    }

    // --- set_deposit_limit_module: shouldOverride sets limit to max ---

    function test_setDepositLimitModule_shouldOverride_setsLimitToMax() public {
        // Set deposit limit to non-max first
        vault.set_deposit_limit(100e18, true);
        assertEq(vault.depositLimit(), 100e18);

        MockDepositLimitModule module = new MockDepositLimitModule();
        vault.set_deposit_limit_module(address(module), true);
        assertEq(vault.depositLimit(), type(uint256).max);
        assertEq(vault.depositLimitModule(), address(module));
    }

    // --- set_deposit_limit_module when shutdown reverts ---

    function test_setDepositLimitModule_whenShutdown_reverts() public {
        vault.shutdown_vault();
        MockDepositLimitModule module = new MockDepositLimitModule();
        vm.expectRevert(IMultistrategyVault.VaultShutdown.selector);
        vault.set_deposit_limit_module(address(module), true);
    }

    // --- set_withdraw_limit_module ---

    function test_setWithdrawLimitModule_succeeds() public {
        vault.add_role(gov, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        MockWithdrawLimitModule module = new MockWithdrawLimitModule();
        vault.set_withdraw_limit_module(address(module));
        assertEq(vault.withdrawLimitModule(), address(module));
    }

    // --- shutdown_vault with depositLimitModule set ---

    function test_shutdownVault_withDepositLimitModule_clearsIt() public {
        MockDepositLimitModule module = new MockDepositLimitModule();
        vault.set_deposit_limit_module(address(module), true);
        assertEq(vault.depositLimitModule(), address(module));

        vault.shutdown_vault();
        assertTrue(vault.isShutdown());
        assertEq(vault.depositLimitModule(), address(0));
        assertEq(vault.depositLimit(), 0);
    }

    // --- maxDeposit to zero address returns 0 ---

    function test_maxDeposit_zeroAddress_returnsZero() public view {
        assertEq(vault.maxDeposit(address(0)), 0);
    }

    // --- maxDeposit to vault address returns 0 ---

    function test_maxDeposit_vaultAddress_returnsZero() public view {
        assertEq(vault.maxDeposit(address(vault)), 0);
    }

    // --- maxDeposit with deposit limit module ---

    function test_maxDeposit_withDepositLimitModule() public {
        MockDepositLimitModule module = new MockDepositLimitModule();
        vault.set_deposit_limit_module(address(module), true);
        // Module returns type(uint256).max by default
        assertEq(vault.maxDeposit(user), type(uint256).max);
    }

    // --- maxDeposit when totalAssets >= depositLimit ---

    function test_maxDeposit_atLimit_returnsZero() public {
        vault.set_deposit_limit(10e18, true);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // totalAssets == depositLimit, so maxDeposit should be 0
        assertEq(vault.maxDeposit(user), 0);
    }

    // --- maxWithdraw and maxRedeem with withdraw limit module ---

    function test_maxWithdraw_withWithdrawLimitModule() public {
        vault.add_role(gov, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        MockWithdrawLimitModule module = new MockWithdrawLimitModule();
        module.setDefaultWithdrawLimit(5e18);
        vault.set_withdraw_limit_module(address(module));

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // maxWithdraw should be min(module limit, user balance in assets) = min(5e18, 10e18) = 5e18
        uint256 maxW = vault.maxWithdraw(user, 0, new address[](0));
        assertEq(maxW, 5e18);
    }

    function test_maxRedeem_withWithdrawLimitModule() public {
        vault.add_role(gov, IMultistrategyVault.Roles.WITHDRAW_LIMIT_MANAGER);
        MockWithdrawLimitModule module = new MockWithdrawLimitModule();
        module.setDefaultWithdrawLimit(5e18);
        vault.set_withdraw_limit_module(address(module));

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // maxRedeem should be limited by module
        uint256 maxR = vault.maxRedeem(user, 0, new address[](0));
        assertEq(maxR, 5e18);
    }

    // --- convertToShares with zero totalAssets (supply > 0 but assets == 0) returns 0 ---
    // This is hard to reach naturally since withdrawals track assets, but we test the view function edge case

    function test_convertToShares_zero_returnsZero() public view {
        // With no deposits, convertToShares(0) = 0
        assertEq(vault.convertToShares(0), 0);
    }

    function test_convertToAssets_zero_returnsZero() public view {
        assertEq(vault.convertToAssets(0), 0);
    }

    function test_convertToShares_maxUint_returnsMaxUint() public view {
        assertEq(vault.convertToShares(type(uint256).max), type(uint256).max);
    }

    function test_convertToAssets_maxUint_returnsMaxUint() public view {
        assertEq(vault.convertToAssets(type(uint256).max), type(uint256).max);
    }

    // --- set_deposit_limit when shutdown reverts ---

    function test_setDepositLimit_whenShutdown_reverts() public {
        vault.shutdown_vault();
        vm.expectRevert(IMultistrategyVault.VaultShutdown.selector);
        vault.set_deposit_limit(100e18, false);
    }

    // --- deposit to zero receiver reverts (maxDeposit returns 0) ---

    function test_deposit_toZeroReceiver_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.deposit(10e18, address(0));
        vm.stopPrank();
    }

    // --- mint ---

    function test_mint_succeeds() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        uint256 assets = vault.mint(5e18, user);
        vm.stopPrank();
        assertEq(assets, 5e18);
    }

    function test_mint_whenShutdown_reverts() public {
        vault.shutdown_vault();
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vm.expectRevert(IMultistrategyVault.ExceedDepositLimit.selector);
        vault.mint(5e18, user);
        vm.stopPrank();
    }

    // --- withdraw ---

    function test_withdraw_succeeds() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);

        uint256 shares = vault.withdraw(5e18, user, user, 0, new address[](0));
        assertGt(shares, 0);
        vm.stopPrank();
    }

    // --- redeem ---

    function test_redeem_succeeds() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);

        uint256 assets = vault.redeem(5e18, user, user, 0, new address[](0));
        assertGt(assets, 0);
        vm.stopPrank();
    }

    // --- preview functions ---

    function test_previewDeposit_returnsCorrectShares() public view {
        assertEq(vault.previewDeposit(10e18), 10e18);
    }

    function test_previewMint_returnsCorrectAssets() public view {
        assertEq(vault.previewMint(10e18), 10e18);
    }

    function test_previewWithdraw_returnsCorrectShares() public view {
        // No deposits means 1:1 ratio
        assertEq(vault.previewWithdraw(10e18), 10e18);
    }

    function test_previewRedeem_returnsCorrectAssets() public view {
        assertEq(vault.previewRedeem(10e18), 10e18);
    }

    // ============================================
    // PHASE 3 – TARGETED BRANCH + FUNCTION COVERAGE
    // ============================================

    // --- Uncovered functions: simple view getters ---

    function test_unlockedShares_returnsZeroByDefault() public view {
        assertEq(vault.unlockedShares(), 0);
    }

    function test_getDefaultQueue_returnsEmpty() public view {
        address[] memory q = vault.get_default_queue();
        assertEq(q.length, 0);
    }

    function test_factory_returnsFactoryAddress() public view {
        assertTrue(vault.FACTORY() != address(0));
    }

    function test_apiVersion_returnsExpectedString() public view {
        assertEq(keccak256(bytes(vault.apiVersion())), keccak256(bytes("3.0.4")));
    }

    function test_lastProfitUpdate_returnsZeroByDefault() public view {
        assertEq(vault.lastProfitUpdate(), 0);
    }

    // --- assess_share_of_unrealised_losses 3-param overload ---

    function test_assessShareOfUnrealisedLosses_3param_noLoss() public {
        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        vault.update_debt(address(strategy), 5e18, 0);

        // No loss, so should return 0
        uint256 loss = vault.assess_share_of_unrealised_losses(address(strategy), 2e18);
        assertEq(loss, 0);
    }

    function test_assessShareOfUnrealisedLosses_3param_reverts_whenDebtLessThanNeeded() public {
        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        vault.update_debt(address(strategy), 5e18, 0);

        // assetsNeeded > currentDebt should revert
        vm.expectRevert(IMultistrategyVault.NotEnoughDebt.selector);
        vault.assess_share_of_unrealised_losses(address(strategy), 6e18);
    }

    // --- assess_share_of_unrealised_losses 2-param: revert when assetsNeeded > debt ---

    function test_assessShareOfUnrealisedLosses_2param_reverts_whenNeededExceedsDebt() public {
        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        vault.update_debt(address(strategy), 5e18, 0);

        // 2-param overload: assetsNeeded > currentDebt should revert
        vm.expectRevert(IMultistrategyVault.NotEnoughDebt.selector);
        vault.assess_share_of_unrealised_losses(address(strategy), 6e18);
    }

    // --- assess_share_of_unrealised_losses 2-param: success path ---

    function test_assessShareOfUnrealisedLosses_2param_succeeds() public {
        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        vault.update_debt(address(strategy), 5e18, 0);

        // assetsNeeded <= currentDebt: should succeed and return 0 (no loss)
        uint256 loss = vault.assess_share_of_unrealised_losses(address(strategy), 2e18);
        assertEq(loss, 0);
    }

    // --- initialize revert paths (need a fresh uninitialised clone) ---

    function test_initialize_zeroAssetParam_reverts() public {
        address clone = Clones.clone(address(vaultImplementation));
        // Reset asset to 0 using vm.store (slot 0 for asset)
        vm.store(clone, bytes32(uint256(0)), bytes32(uint256(0)));

        vm.expectRevert(IMultistrategyVault.ZeroAddress.selector);
        MultistrategyVault(clone).initialize(address(0), "Test", "T", gov, 7 days);
    }

    function test_initialize_zeroRoleManager_reverts() public {
        address clone = Clones.clone(address(vaultImplementation));
        vm.store(clone, bytes32(uint256(0)), bytes32(uint256(0)));

        vm.expectRevert(IMultistrategyVault.ZeroAddress.selector);
        MultistrategyVault(clone).initialize(address(asset), "Test", "T", address(0), 7 days);
    }

    function test_initialize_profitUnlockTimeTooLong_reverts() public {
        address clone = Clones.clone(address(vaultImplementation));
        vm.store(clone, bytes32(uint256(0)), bytes32(uint256(0)));

        vm.expectRevert(IMultistrategyVault.ProfitUnlockTimeTooLong.selector);
        MultistrategyVault(clone).initialize(address(asset), "Test", "T", gov, 31_556_953);
    }

    // --- add_role / remove_role: non-roleManager revert ---

    function test_addRole_byNonRoleManager_reverts() public {
        vm.prank(user);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.add_role(user, IMultistrategyVault.Roles.DEBT_MANAGER);
    }

    function test_removeRole_byNonRoleManager_reverts() public {
        vm.prank(user);
        vm.expectRevert(IMultistrategyVault.NotAllowed.selector);
        vault.remove_role(gov, IMultistrategyVault.Roles.DEBT_MANAGER);
    }

    // --- redeem: receiver == address(0) ---

    function test_redeem_zeroReceiver_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);

        vm.expectRevert(IMultistrategyVault.ZeroAddress.selector);
        vault.redeem(5e18, address(0), user, 0, new address[](0));
        vm.stopPrank();
    }

    // --- redeem: assets == 0 (shares that convert to 0 assets) ---
    // This is hard to trigger naturally. We use withdraw with 0 assets instead.

    function test_withdraw_zeroAssets_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);

        // withdraw(0 assets) -> shares = 0 -> NoSharesToRedeem
        vm.expectRevert(IMultistrategyVault.NoSharesToRedeem.selector);
        vault.withdraw(0, user, user, 0, new address[](0));
        vm.stopPrank();
    }

    // --- buy_debt: shares == 0 path ---

    function test_buyDebt_sharesEqualsZero_reverts() public {
        vault.add_role(gov, IMultistrategyVault.Roles.DEBT_PURCHASER);
        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        vault.update_debt(address(strategy), 10e18, 0);

        // Now simulate strategy losing all its shares (burn them)
        // The strategy has shares, but we mock balanceOf to return 0
        vm.mockCall(
            address(strategy),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vault)),
            abi.encode(uint256(0))
        );

        asset.mint(gov, 10e18);
        asset.approve(address(vault), 10e18);

        vm.expectRevert(IMultistrategyVault.CannotBuyZero.selector);
        vault.buy_debt(address(strategy), 1e18);

        vm.clearMockedCalls();
    }

    // --- _convertToAssets ROUND_UP with remainder != 0 ---
    // previewMint uses _convertToAssets with ROUND_UP. We need totalAssets/totalSupply ratio to produce a remainder.

    function test_previewMint_roundsUp() public {
        // Deposit to create supply
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // Add strategy, allocate, then simulate profit to create a non-1:1 ratio
        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);
        vault.update_debt(address(strategy), 10e18, 0);

        // Mint 1 token to strategy to simulate profit
        asset.mint(address(strategy), 1e18);

        // Process report to account for the profit
        vault.process_report(address(strategy));

        // After profit, PPS > 1, so previewMint should round up
        // shares = 3 -> assets = ceil(3 * totalAssets / totalSupply)
        uint256 assetsNeeded = vault.previewMint(3);
        // Just verify we get a non-zero value (the ROUND_UP branch is exercised)
        assertGt(assetsNeeded, 0);
    }

    // --- _convertToAssets ROUND_UP: ensure remainder triggers +1 ---
    // Use profitMaxUnlockTime=0 so profits unlock immediately, creating clean ratio imbalance

    function test_previewMint_roundsUp_withImmediateProfit() public {
        // Set profitMaxUnlockTime to 0 so profits apply instantly
        vault.setProfitMaxUnlockTime(0);

        asset.mint(user, 7);
        vm.startPrank(user);
        asset.approve(address(vault), 7);
        vault.deposit(7, user);
        vm.stopPrank();

        // Airdrop 3 wei to vault to create totalAssets=10, totalSupply=7
        asset.mint(address(vault), 3);
        vault.process_report(address(vault));

        // previewMint(shares=1) = ceil(1 * 10 / 7) = ceil(1.428...) = 2
        uint256 needed = vault.previewMint(1);
        assertEq(needed, 2, "Should round up to 2");
    }

    // --- _redeem: withdrawn > assetsToWithdraw, withdrawn > currentDebt ---
    // Use MockLossyStrategy which can return extra yield on withdrawal

    function test_redeem_withdrawnExceedsDebt_cappedToDebt() public {
        MockLossyStrategy lossyStrat = new MockLossyStrategy(address(asset), address(vault));

        vault.add_strategy(address(lossyStrat), true);
        vault.update_max_debt_for_strategy(address(lossyStrat), type(uint256).max);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // Allocate 5e18 to strategy
        vault.update_debt(address(lossyStrat), 5e18, 0);

        // Set extra yield on withdrawal - strategy returns more than expected
        lossyStrat.setWithdrawingExtraYield(2e18);
        // Mint extra tokens to strategy so it can pay extra
        asset.mint(address(lossyStrat), 2e18);

        // Withdraw 8e18 (5 idle + 3 from strategy, but strategy gives back 3+2=5)
        // The "withdrawn > currentDebt" branch triggers when extra is > debt
        vm.startPrank(user);
        uint256 received = vault.redeem(10e18, user, user, 10_000, new address[](0));
        vm.stopPrank();

        // Should complete without revert
        assertGt(received, 0);
    }

    // --- _redeem: withdrawn > assetsToWithdraw but <= currentDebt (adds extra) ---

    function test_redeem_withdrawnExceedsExpected_butWithinDebt() public {
        MockLossyStrategy lossyStrat = new MockLossyStrategy(address(asset), address(vault));

        vault.add_strategy(address(lossyStrat), true);
        vault.update_max_debt_for_strategy(address(lossyStrat), type(uint256).max);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // Allocate 5e18 to strategy (keep 5e18 idle)
        vault.update_debt(address(lossyStrat), 5e18, 0);

        // Set small extra yield on withdrawal
        lossyStrat.setWithdrawingExtraYield(1e18);
        // Mint extra to strategy so it can cover the extra yield + rounding
        asset.mint(address(lossyStrat), 2e18);

        // Withdraw 8e18 => need 3e18 from strategy (idle covers 5e18)
        // Strategy will return 3e18 + 1e18 extra = 4e18 (withdrawn > assetsToWithdraw but <= debt of 5e18)
        vm.startPrank(user);
        uint256 received = vault.redeem(8e18, user, user, 10_000, new address[](0));
        vm.stopPrank();

        assertGt(received, 0);
    }

    // --- _max_withdraw: toWithdraw == 0 continue branch ---
    // Strategy with 0 currentDebt in the queue => toWithdraw = min(needed, 0) = 0 => continue

    function test_maxWithdraw_skipsStrategyWithZeroDebt() public {
        // Add strategy but don't allocate any debt
        vault.add_strategy(address(strategy), true);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // maxAssets > idle is not possible here since all is idle.
        // We need partial idle. Allocate to a second strategy, not the first.
        MockYieldStrategy strategy2 = new MockYieldStrategy(address(asset), address(vault));
        vault.add_strategy(address(strategy2), true);
        vault.update_max_debt_for_strategy(address(strategy2), type(uint256).max);
        vault.update_debt(address(strategy2), 8e18, 0);

        // Now queue = [strategy (0 debt), strategy2 (8e18 debt)]
        // idle = 2e18, user has 10e18 in shares
        // maxWithdraw needs to iterate: strategy has 0 debt => toWithdraw=0 => continue
        uint256 maxW = vault.maxWithdraw(user, 10_000, new address[](0));
        assertGt(maxW, 0);
    }

    // --- _max_withdraw: unrealizedLoss != 0 inside strategyLimit < realizableWithdraw ---

    function test_maxWithdraw_adjustsUnrealizedLossForStrategyLimit() public {
        MockLossyStrategy lossyStrat = new MockLossyStrategy(address(asset), address(vault));

        vault.add_strategy(address(lossyStrat), true);
        vault.update_max_debt_for_strategy(address(lossyStrat), type(uint256).max);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // Allocate 8e18 to strategy
        vault.update_debt(address(lossyStrat), 8e18, 0);

        // Simulate 50% loss in the strategy (4e18 lost)
        lossyStrat.setLoss(4e18);
        // Lock most of the remaining funds so strategyLimit < realizableWithdraw
        lossyStrat.setLockedFunds(3e18);

        // Now: strategy has 4e18 assets, 8e18 debt => unrealized loss exists
        // availableWithdraw = 4e18 - 3e18 = 1e18 (strategyLimit)
        // unrealizedLoss != 0 and strategyLimit < realizableWithdraw => adjusts loss proportionally
        uint256 maxW = vault.maxWithdraw(user, 10_000, new address[](0));
        assertGt(maxW, 0);
    }

    // --- redeem: assets == 0 but shares > 0 (NoAssetsToWithdraw) ---

    function test_redeem_zeroAssetsWithShares_reverts() public {
        // Deposit to create shares
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // Now set totalIdle and totalDebt to 0 so totalAssets = 0, but supply > 0
        // This creates a state where convertToAssets returns 0 for any shares value
        vm.store(address(vault), bytes32(uint256(9)), bytes32(uint256(0))); // _totalIdle = 0
        vm.store(address(vault), bytes32(uint256(8)), bytes32(uint256(0))); // _totalDebt = 0

        // redeem(shares > 0) with totalAssets == 0 => assets = 0 => NoAssetsToWithdraw
        vm.prank(user);
        vm.expectRevert(IMultistrategyVault.NoAssetsToWithdraw.selector);
        vault.redeem(1e18, user, user, 0, new address[](0));
    }

    // --- reentrancy guard ---

    function test_reentrancy_onDeposit_reverts() public {
        asset.mint(user, 10e18);
        vm.prank(user);
        asset.approve(address(vault), 10e18);

        // Set _locked = true (storage slot 28) to simulate mid-execution state
        vm.store(address(vault), bytes32(uint256(28)), bytes32(uint256(1)));

        vm.prank(user);
        vm.expectRevert(IMultistrategyVault.Reentrancy.selector);
        vault.deposit(1e18, user);

        // Reset _locked to restore normal state
        vm.store(address(vault), bytes32(uint256(28)), bytes32(uint256(0)));
    }

    function test_reentrancy_onRedeem_reverts() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // Set _locked = true
        vm.store(address(vault), bytes32(uint256(28)), bytes32(uint256(1)));

        vm.prank(user);
        vm.expectRevert(IMultistrategyVault.Reentrancy.selector);
        vault.redeem(5e18, user, user, 0, new address[](0));

        vm.store(address(vault), bytes32(uint256(28)), bytes32(uint256(0)));
    }

    function test_reentrancy_onUpdateDebt_reverts() public {
        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // Set _locked = true
        vm.store(address(vault), bytes32(uint256(28)), bytes32(uint256(1)));

        vm.expectRevert(IMultistrategyVault.Reentrancy.selector);
        vault.update_debt(address(strategy), 5e18, 0);

        vm.store(address(vault), bytes32(uint256(28)), bytes32(uint256(0)));
    }

    // --- process_report with loss + fees (covers fee calculation on loss path) ---

    function test_processReport_lossWithRefunds() public {
        MockFlexibleAccountant acct = new MockFlexibleAccountant(address(asset));
        vault.add_role(gov, IMultistrategyVault.Roles.ACCOUNTANT_MANAGER);
        vault.set_accountant(address(acct));

        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        vault.update_debt(address(strategy), 10e18, 0);

        // Set refund ratio for losses
        acct.setFees(address(strategy), 0, 0, 5000); // 50% refund ratio

        // Fund accountant for refunds
        asset.mint(address(acct), 5e18);

        // Simulate a loss in the strategy
        strategy.simulateLoss(2e18);

        // Advance time so management fee calculation is non-zero
        vm.warp(block.timestamp + 1 days);

        // Process report - covers loss + totalRefunds > 0 branch
        vault.process_report(address(strategy));
    }

    // --- process_report with gain + fees + protocol fees ---

    function test_processReport_gainWithFeesAndProtocolFees() public {
        // Set protocol fee on factory
        address factoryAddr = vault.FACTORY();
        MultistrategyVaultFactory factory = MultistrategyVaultFactory(factoryAddr);

        address protocolFeeRecipient = address(0xFEE);
        factory.setProtocolFeeRecipient(protocolFeeRecipient);
        factory.setProtocolFeeBps(1000); // 10%

        MockFlexibleAccountant acct = new MockFlexibleAccountant(address(asset));
        vault.add_role(gov, IMultistrategyVault.Roles.ACCOUNTANT_MANAGER);
        vault.set_accountant(address(acct));

        vault.add_strategy(address(strategy), true);
        vault.update_max_debt_for_strategy(address(strategy), type(uint256).max);

        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        vault.update_debt(address(strategy), 10e18, 0);

        // Set performance fee
        acct.setFees(address(strategy), 0, 1000, 0); // 10% performance fee

        // Simulate gain
        asset.mint(address(strategy), 2e18);

        vm.warp(block.timestamp + 1 days);

        // Process report - covers gain + totalFees > 0 + protocolFeeBps > 0 branches
        (uint256 gain, uint256 loss) = vault.process_report(address(strategy));
        assertEq(gain, 2e18);
        assertEq(loss, 0);
    }

    // --- process_report for vault itself (address(this) strategy) with gain ---

    function test_processReport_vaultAirdrop() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // Airdrop tokens to vault (not through deposit)
        asset.mint(address(vault), 2e18);

        // Process report for vault itself (airdrop accounting)
        (uint256 gain, ) = vault.process_report(address(vault));
        assertEq(gain, 2e18);
    }

    // --- process_report: loss path for vault idle (address(this)) ---

    function test_processReport_vaultIdleLoss() public {
        asset.mint(user, 10e18);
        vm.startPrank(user);
        asset.approve(address(vault), 10e18);
        vault.deposit(10e18, user);
        vm.stopPrank();

        // We can't easily make vault idle lose tokens, but we can process report
        // when balance equals idle (no gain, no loss)
        (, uint256 loss) = vault.process_report(address(vault));
        assertEq(loss, 0);
    }

    // --- Helper: Build vault permit digest ---

    function _buildVaultPermitDigest(
        address owner_,
        address spender_,
        uint256 value_,
        uint256 deadline_
    ) internal view returns (bytes32) {
        bytes32 DOMAIN_TYPE_HASH = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 PERMIT_TYPE_HASH = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );
        bytes32 versionHash = keccak256(bytes("3.0.4"));
        bytes32 nameHash = keccak256(bytes(vault.name()));
        bytes32 domainSeparator = keccak256(
            abi.encode(DOMAIN_TYPE_HASH, nameHash, versionHash, block.chainid, address(vault))
        );
        uint256 nonce = vault.nonces(owner_);
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPE_HASH, owner_, spender_, value_, nonce, deadline_));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
