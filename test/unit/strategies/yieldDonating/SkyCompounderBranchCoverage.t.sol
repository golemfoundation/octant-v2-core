// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import { ERC20Mock } from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import { SkyCompounderStrategy } from "src/strategies/yieldDonating/SkyCompounderStrategy.sol";
import { YieldDonatingTokenizedStrategy } from "src/strategies/yieldDonating/YieldDonatingTokenizedStrategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SeedHelpers } from "./utils/SeedHelpers.sol";

/// @title Inline mock staking contract for SkyCompounder tests
contract MockStaking is ERC20 {
    bool public paused;
    address public stakingToken;
    address public rewardsToken;

    mapping(address => uint256) public earned;

    constructor(address _stakingToken, address _rewardsToken) ERC20("MockStaking", "MSK") {
        stakingToken = _stakingToken;
        rewardsToken = _rewardsToken;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function stake(uint256 _amount, uint16) external {
        ERC20(stakingToken).transferFrom(msg.sender, address(this), _amount);
        _mint(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) external {
        _burn(msg.sender, _amount);
        ERC20(stakingToken).transfer(msg.sender, _amount);
    }

    function getReward() external {
        // no-op in test
    }
}

/// @title SkyCompounderStrategy branch coverage tests
/// @notice Covers 4 uncovered branches + 1 uncovered function (setMinAmountOut)
contract SkyCompounderBranchCoverageTest is SeedHelpers {
    // USDS address hardcoded in SkyCompounderStrategy
    address constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;

    YieldDonatingTokenizedStrategy public implementation;
    ERC20Mock public rewardsToken;
    MockStaking public staking;

    address management = address(0x1);
    address keeper = address(0x2);
    address emergencyAdmin = address(0x3);
    address donationAddress = address(0x4);

    function setUp() public {
        // Use the implementation directly (not via proxy) for strategies that need
        // to call functions post-deployment (delegatecall pattern requires direct impl)
        implementation = new YieldDonatingTokenizedStrategy();
        rewardsToken = new ERC20Mock();

        // Deploy mock staking with USDS as staking token
        staking = new MockStaking(USDS, address(rewardsToken));

        // Deploy USDS bytecode at the hardcoded address so the strategy's asset works
        ERC20Mock template = new ERC20Mock();
        vm.etch(USDS, address(template).code);
    }

    /// @dev Helper to deploy a valid SkyCompounderStrategy
    function _deployStrategy() internal returns (SkyCompounderStrategy) {
        return
            new SkyCompounderStrategy(
                address(staking),
                "Test SkyComp",
                "tsSKY",
                management,
                keeper,
                emergencyAdmin,
                donationAddress,
                false,
                address(implementation)
            );
    }

    /// @notice Constructor reverts when staking is paused (line 88)
    function test_constructor_stakingPaused_reverts() public {
        staking.setPaused(true);

        vm.expectRevert("paused");
        new SkyCompounderStrategy(
            address(staking),
            "Test SkyComp",
            "tsSKY",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
    }

    /// @notice Constructor reverts when stakingToken != USDS (line 89)
    function test_constructor_wrongStakingToken_reverts() public {
        // Deploy mock staking with wrong staking token
        MockStaking badStaking = new MockStaking(address(0xBEEF), address(rewardsToken));

        vm.expectRevert("!stakingToken");
        new SkyCompounderStrategy(
            address(badStaking),
            "Test SkyComp",
            "tsSKY",
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            false,
            address(implementation)
        );
    }

    /// @notice setBase with USDS triggers the `if (_base == USDS)` TRUE path (line 139)
    function test_setBase_USDS_path() public {
        SkyCompounderStrategy strategy = _deployStrategy();

        vm.prank(management);
        strategy.setBase(USDS, false, 0, 0);

        // Verify base was set (base is a public variable from UniswapV3Swapper)
        assertEq(strategy.base(), USDS, "Base should be USDS");
    }

    /// @notice setMinAmountOut covers the uncovered function (line 175)
    function test_setMinAmountOut() public {
        SkyCompounderStrategy strategy = _deployStrategy();

        vm.prank(management);
        strategy.setMinAmountOut(1000);

        assertEq(strategy.minAmountOut(), 1000, "minAmountOut should be set");
    }

    /// @notice _harvestAndReport when isShutdown() == true takes the shutdown path (line 256)
    function test_harvestAndReport_shutdownPath() public {
        SkyCompounderStrategy strategy = _deployStrategy();
        _seedMinimumPosition(address(strategy), ERC20Mock(USDS), management);

        // Mint USDS to deposit
        ERC20Mock(USDS).mint(address(this), 100e18);
        ERC20Mock(USDS).approve(address(strategy), 100e18);
        ITokenizedStrategy(address(strategy)).deposit(100e18, address(this));

        // Shutdown the strategy
        vm.prank(emergencyAdmin);
        ITokenizedStrategy(address(strategy)).shutdownStrategy();

        // Report should use the shutdown path (line 256-257)
        vm.prank(management);
        ITokenizedStrategy(address(strategy)).report();
    }
}
