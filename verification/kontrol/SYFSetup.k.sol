// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { SwappingYieldForwarder } from "src/core/SwappingYieldForwarder.sol";

import { KontrolTest } from "test/kontrol/KontrolTest.k.sol";
import { TestERC20 } from "test/kontrol/TestERC20.k.sol";
import { MockForwarderStrategy } from "test/kontrol/MockForwarderStrategy.k.sol";
import { MockForwarderSwapper } from "test/kontrol/MockForwarderSwapper.k.sol";
import "test/kontrol/SharedStateSlots.k.sol";

/**
 * @title SYFSetup
 * @notice Symbolic setup for formal verification of SwappingYieldForwarder
 * @dev Deploys SwappingYieldForwarder with concrete role addresses, a MockForwarderStrategy
 *      with symbolic storage, a MockForwarderSwapper with symbolic swap return, and a real
 *      TestERC20 for the underlying asset (required for safeTransfer in the swap path).
 *
 *      The forwarder's ERC20 balance is pre-loaded to simulate tokens received from redeem().
 *      The mock redeem() does not actually transfer tokens, so we write the balance directly.
 */
contract SYFSetup is KontrolTest {
    SwappingYieldForwarder public syfForwarder;
    MockForwarderStrategy public mockStrategy;
    MockForwarderSwapper public mockSwapper;
    TestERC20 public sourceAsset;
    TestERC20 public targetAsset;

    address internal _receiver;
    address internal _keeper;

    function setUp() public virtual {
        // Concrete role addresses
        _receiver = makeAddr("RECEIVER");
        _keeper = makeAddr("KEEPER");

        // Deploy real ERC20s (needed for safeTransfer in swap path)
        sourceAsset = new TestERC20();
        targetAsset = new TestERC20();

        // Deploy mocks
        mockStrategy = new MockForwarderStrategy();
        mockSwapper = new MockForwarderSwapper();

        // Deploy SwappingYieldForwarder with concrete immutables. The mock strategy
        // doubles as the vault reference; its symbolic management() is not exercised
        // in the current proofs (they don't call setSwapper).
        syfForwarder = new SwappingYieldForwarder(
            _receiver,
            _keeper,
            address(targetAsset),
            address(mockSwapper),
            address(mockStrategy)
        );

        // ============================================
        // MAKE MOCK STRATEGY STORAGE SYMBOLIC
        // ============================================
        kevm.symbolicStorage(address(mockStrategy));

        // Restore concrete asset address to the real ERC20
        _storeAddress(address(mockStrategy), MFS_ASSET_SLOT, address(sourceAsset));
        _storeAddress(address(mockStrategy), MFS_EXPECTED_BALANCE_OF_ACCOUNT_SLOT, address(syfForwarder));

        // Set symbolic share balance and redeem return
        uint256 shareBalance = freshUInt256Bounded();
        _storeUInt256(address(mockStrategy), MFS_SHARE_BALANCE_SLOT, shareBalance);

        uint256 redeemReturn = freshUInt256Bounded();
        _storeUInt256(address(mockStrategy), MFS_REDEEM_RETURN_SLOT, redeemReturn);

        // Clear argument capture slots
        _storeUInt256(address(mockStrategy), MFS_LAST_SHARES_SLOT, 0);
        _storeAddress(address(mockStrategy), MFS_LAST_RECEIVER_SLOT, address(0));
        _storeAddress(address(mockStrategy), MFS_LAST_REPORT_CALLER_SLOT, address(0));
        _storeAddress(address(mockStrategy), MFS_LAST_OWNER_SLOT, address(0));
        _storeUInt256(address(mockStrategy), MFS_LAST_MAX_LOSS_SLOT, 0);

        // ============================================
        // MAKE MOCK SWAPPER STORAGE SYMBOLIC
        // ============================================
        kevm.symbolicStorage(address(mockSwapper));

        // Set symbolic swap return
        uint256 swapReturn = freshUInt256Bounded();
        _storeUInt256(address(mockSwapper), MSWP_RETURN_SLOT, swapReturn);

        // Clear argument capture slots
        _storeAddress(address(mockSwapper), MSWP_LAST_RECEIVER_SLOT, address(0));
        _storeAddress(address(mockSwapper), MSWP_LAST_TOKEN_IN_SLOT, address(0));
        _storeAddress(address(mockSwapper), MSWP_LAST_TOKEN_OUT_SLOT, address(0));
        _storeUInt256(address(mockSwapper), MSWP_LAST_AMOUNT_IN_SLOT, 0);
        _storeUInt256(address(mockSwapper), MSWP_LAST_MIN_AMOUNT_OUT_SLOT, 0);

        // ============================================
        // PRE-LOAD FORWARDER ERC20 BALANCE
        // ============================================
        // The mock redeem() doesn't transfer actual tokens, so we pre-load the
        // forwarder's balance in sourceAsset to equal redeemReturn. This simulates
        // the tokens the forwarder would receive from a real redeem() call.
        //
        // Also set totalSupply >= balance to satisfy ERC20 invariants.
        _storeMappingUInt256(
            address(sourceAsset),
            ERC20_BALANCES_SLOT,
            uint256(uint160(address(syfForwarder))),
            0,
            redeemReturn
        );
        // Set totalSupply to redeemReturn (slot 2 for OZ ERC20)
        _storeUInt256(address(sourceAsset), 2, redeemReturn);

        // ============================================
        // SET FORWARDER REENTRANCY GUARD TO NOT_ENTERED
        // ============================================
        _storeUInt256(address(syfForwarder), RG_STATUS_SLOT, RG_NOT_ENTERED);
    }
}
