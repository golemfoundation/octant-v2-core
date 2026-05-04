// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { YieldForwarder } from "src/core/YieldForwarder.sol";

import { KontrolTest } from "test/kontrol/KontrolTest.k.sol";
import { MockForwarderStrategy } from "test/kontrol/MockForwarderStrategy.k.sol";
import "test/kontrol/SharedStateSlots.k.sol";

/**
 * @title YFSetup
 * @notice Symbolic setup for formal verification of YieldForwarder
 * @dev Deploys YieldForwarder with concrete role addresses and a MockForwarderStrategy
 *      with symbolic relevant slots. Unlike strategy proofs (where the CUT's storage is
 *      symbolic), here the forwarder is stateless (immutables + ReentrancyGuard) and the
 *      mock dependency exposes only a small controlled state surface.
 */
contract YFSetup is KontrolTest {
    YieldForwarder public forwarder;
    MockForwarderStrategy public mockStrategy;

    address internal _receiver;
    address internal _keeper;

    function setUp() public virtual {
        // Concrete role addresses (avoid symbolic branching on prank)
        _receiver = makeAddr("RECEIVER");
        _keeper = makeAddr("KEEPER");

        // Deploy mock strategy
        mockStrategy = new MockForwarderStrategy();

        // Deploy YieldForwarder with concrete immutables
        forwarder = new YieldForwarder(_receiver, _keeper);

        // Restore concrete asset address (needed for SYF safeTransfer path)
        // Using address(0xA55E7) as a deterministic mock asset address
        _storeAddress(address(mockStrategy), MFS_ASSET_SLOT, address(0xA55E7));
        _storeAddress(address(mockStrategy), MFS_EXPECTED_BALANCE_OF_ACCOUNT_SLOT, address(forwarder));

        // Set symbolic share balance, redeem return, and ERC-4626 guards
        uint256 shareBalance = freshUInt256Bounded();
        _storeUInt256(address(mockStrategy), MFS_SHARE_BALANCE_SLOT, shareBalance);

        uint256 redeemReturn = freshUInt256Bounded();
        _storeUInt256(address(mockStrategy), MFS_REDEEM_RETURN_SLOT, redeemReturn);

        uint256 maxRedeem = freshUInt256Bounded();
        _storeUInt256(address(mockStrategy), MFS_MAX_REDEEM_SLOT, maxRedeem);

        uint256 convertibleAssets = freshUInt256Bounded();
        _storeUInt256(address(mockStrategy), MFS_CONVERT_TO_ASSETS_SLOT, convertibleAssets);
        _storeAddress(address(mockStrategy), MFS_EXPECTED_MAX_REDEEM_OWNER_SLOT, address(forwarder));

        uint256 redeemShares = shareBalance < maxRedeem ? shareBalance : maxRedeem;
        _storeUInt256(address(mockStrategy), MFS_EXPECTED_CONVERT_TO_ASSETS_SHARES_SLOT, redeemShares);

        // Clear argument capture slots (so we can detect if redeem was called)
        _storeUInt256(address(mockStrategy), MFS_LAST_SHARES_SLOT, 0);
        _storeAddress(address(mockStrategy), MFS_LAST_RECEIVER_SLOT, address(0));
        _storeAddress(address(mockStrategy), MFS_LAST_REPORT_CALLER_SLOT, address(0));
        _storeAddress(address(mockStrategy), MFS_LAST_OWNER_SLOT, address(0));
        _storeUInt256(address(mockStrategy), MFS_LAST_MAX_LOSS_SLOT, 0);

        // ============================================
        // SET FORWARDER REENTRANCY GUARD TO NOT_ENTERED
        // ============================================
        _storeUInt256(address(forwarder), RG_STATUS_SLOT, RG_NOT_ENTERED);
    }
}
