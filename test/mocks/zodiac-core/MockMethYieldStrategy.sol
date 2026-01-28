// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.18;

import { MethYieldStrategy } from "src/zodiac-core/modules/MethYieldStrategy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IMantleStaking } from "src/zodiac-core/interfaces/IMantleStaking.sol";
import { IERC4626Payable } from "src/zodiac-core/interfaces/IERC4626Payable.sol";

/**
 * @title MockMethYieldStrategy
 * @notice Mock version of MethYieldStrategy for testing
 */
contract MockMethYieldStrategy is MethYieldStrategy {
    // Storage slot for mock addresses
    bytes32 private constant MOCK_STORAGE_POSITION = keccak256("mock.meth.strategy.storage");

    // Storage struct
    struct MockStorage {
        address mockMantleStaking;
        address mockMethToken;
    }

    // Real addresses (for reference)
    address public constant REAL_MANTLE_STAKING = 0xe3cBd06D7dadB3F4e6557bAb7EdD924CD1489E8f;

    /**
     * @dev Get the mock storage struct
     */
    function _mockStorage() private pure returns (MockStorage storage ms) {
        bytes32 position = MOCK_STORAGE_POSITION;
        assembly {
            ms.slot := position
        }
    }

    /**
     * @notice Get the mock Mantle staking address
     */
    function mockMantleStaking() external view returns (address) {
        return _mockStorage().mockMantleStaking;
    }

    /**
     * @notice Get the mock mETH token address
     */
    function mockMethToken() external view returns (address) {
        return _mockStorage().mockMethToken;
    }

    /**
     * @notice Set mock addresses for testing
     * @param _mockMantleStaking Mock address for Mantle staking
     * @param _mockMethToken Mock address for mETH token
     */
    function setMockAddresses(address _mockMantleStaking, address _mockMethToken) external {
        MockStorage storage ms = _mockStorage();
        ms.mockMantleStaking = _mockMantleStaking;
        ms.mockMethToken = _mockMethToken;
    }

    /**
     * @dev Override the internal _getCurrentExchangeRate function to use our mock
     */
    function _getCurrentExchangeRate() internal view override returns (uint256) {
        MockStorage storage ms = _mockStorage();
        if (ms.mockMantleStaking != address(0)) {
            // Call our mock contract instead of the real one
            return IMantleStaking(ms.mockMantleStaking).mETHToETH(1e18);
        }
        return MANTLE_STAKING.mETHToETH(1e18);
    }
}
