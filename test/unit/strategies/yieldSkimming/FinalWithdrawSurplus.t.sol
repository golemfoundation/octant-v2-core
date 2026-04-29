// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.8.18;

import { BaseStrategy, ERC20 } from "src/core/BaseStrategy.sol";
import { ITokenizedStrategy } from "src/core/interfaces/ITokenizedStrategy.sol";
import { MockYieldSourceSkimming } from "test/mocks/core/tokenized-strategies/MockYieldSourceSkimming.sol";
import { Setup } from "./utils/Setup.sol";

contract YieldSkimmingFinalWithdrawSurplusTest is Setup {
    bytes32 internal constant TOKENIZED_STRATEGY_STORAGE =
        keccak256(abi.encode(uint256(keccak256("octant.tokenized.strategy.storage")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 internal constant TOTAL_ASSETS_SLOT = bytes32(uint256(TOKENIZED_STRATEGY_STORAGE) + 9);

    function test_finalWithdrawZeroValueSurplusFreesBeforeDragonTransfer() public {
        MockDeployedSkimmingStrategy deployedStrategy = new MockDeployedSkimmingStrategy(
            address(yieldSource),
            management,
            keeper,
            emergencyAdmin,
            donationAddress,
            address(implementation)
        );

        address alice = makeAddr("alice");
        uint256 initialAssets = 100e18;
        uint256 withdrawalAssets = 200e18;
        uint256 trackedAssets = withdrawalAssets + 1;

        yieldSource.mint(alice, initialAssets);

        vm.prank(alice);
        yieldSource.approve(address(deployedStrategy), initialAssets);

        vm.prank(alice);
        ITokenizedStrategy(address(deployedStrategy)).deposit(initialAssets, alice);

        deployedStrategy.updateExchangeRate(5e17);
        deployedStrategy.setDeployedAssets(trackedAssets);
        vm.store(address(deployedStrategy), TOTAL_ASSETS_SLOT, bytes32(trackedAssets));

        uint256 dragonBalanceBefore = yieldSource.balanceOf(donationAddress);

        vm.prank(alice);
        uint256 withdrawn = ITokenizedStrategy(address(deployedStrategy)).redeem(initialAssets, alice, alice, MAX_BPS);

        assertEq(withdrawn, withdrawalAssets, "withdrawn assets");
        assertEq(yieldSource.balanceOf(alice), withdrawalAssets, "receiver assets");
        assertEq(yieldSource.balanceOf(donationAddress) - dragonBalanceBefore, 1, "dragon surplus");
        assertEq(ITokenizedStrategy(address(deployedStrategy)).totalAssets(), 0, "tracked assets");
        assertEq(ITokenizedStrategy(address(deployedStrategy)).totalSupply(), 0, "total supply");
        assertEq(yieldSource.balanceOf(address(deployedStrategy)), 0, "idle assets");
        assertEq(deployedStrategy.deployedAssets(), 0, "deployed assets");
    }
}

contract MockDeployedSkimmingStrategy is BaseStrategy {
    address public yieldSource;
    uint256 public deployedAssets;
    uint256 private exchangeRate = 1e18;

    constructor(
        address _yieldSource,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _donationAddress,
        address _tokenizedStrategyAddress
    )
        BaseStrategy(
            _yieldSource,
            "Deployed Test Strategy",
            "dtsSYMBOL",
            _management,
            _keeper,
            _emergencyAdmin,
            _donationAddress,
            false,
            _tokenizedStrategyAddress
        )
    {
        yieldSource = _yieldSource;
        ERC20(_yieldSource).approve(_yieldSource, type(uint256).max);
    }

    function getCurrentExchangeRate() public view returns (uint256) {
        return exchangeRate;
    }

    function updateExchangeRate(uint256 newExchangeRate) external {
        exchangeRate = newExchangeRate;
    }

    function decimalsOfExchangeRate() public pure returns (uint256) {
        return 18;
    }

    function setDeployedAssets(uint256 newDeployedAssets) external {
        deployedAssets = newDeployedAssets;
    }

    function _deployFunds(uint256 amount) internal override {
        if (amount == 0) return;

        deployedAssets += amount;
        ERC20(yieldSource).transfer(address(0xdead), amount);
    }

    function _freeFunds(uint256 amount) internal override {
        uint256 freed = amount < deployedAssets ? amount : deployedAssets;
        if (freed == 0) return;

        deployedAssets -= freed;
        MockYieldSourceSkimming(yieldSource).mint(address(this), freed);
    }

    function _harvestAndReport() internal view override returns (uint256) {
        return ITokenizedStrategy(address(this)).totalAssets();
    }
}
