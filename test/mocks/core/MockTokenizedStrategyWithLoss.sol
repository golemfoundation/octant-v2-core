// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { TokenizedStrategy, Math } from "src/core/TokenizedStrategy.sol";
import { IBaseStrategy } from "src/core/interfaces/IBaseStrategy.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockTokenizedStrategyWithLoss
 * @notice A mock implementation of TokenizedStrategy that allows testing loss scenarios
 * @dev This mock implements the BaseStrategy interface and provides methods to simulate losses
 */
contract MockTokenizedStrategyWithLoss is TokenizedStrategy, IBaseStrategy {
    using Math for uint256;

    // Mock state variables for testing
    uint256 public mockTotalAssets;
    uint256 public mockAvailableDepositLimit = type(uint256).max;
    uint256 public mockAvailableWithdrawLimit = type(uint256).max;
    bool public shouldRevertOnHarvest;

    constructor() TokenizedStrategy() {
        mockAvailableDepositLimit = type(uint256).max;
        mockAvailableWithdrawLimit = type(uint256).max;
    }

    /**
     * @dev Initialize the strategy with loss control capabilities
     */
    function initialize(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _management,
        address _keeper,
        address _emergencyAdmin,
        address _dragonRouter,
        bool _enableBurning
    ) public override {
        super.initialize(_asset, _name, _symbol, _management, _keeper, _emergencyAdmin, _dragonRouter, _enableBurning);
        mockTotalAssets = 0;
        mockAvailableDepositLimit = type(uint256).max;
        mockAvailableWithdrawLimit = type(uint256).max;
    }

    /* =============== BASESTRATEGY INTERFACE IMPLEMENTATION =============== */

    function harvestAndReport() external view override returns (uint256) {
        if (shouldRevertOnHarvest) {
            revert("Mock harvest failure");
        }
        return mockTotalAssets;
    }

    function availableDepositLimit(address) external view override returns (uint256) {
        return mockAvailableDepositLimit;
    }

    function availableWithdrawLimit(address) external view override returns (uint256) {
        return mockAvailableWithdrawLimit;
    }

    function deployFunds(uint256 _amount) external override {
        // Mock implementation - just track the amount
        mockTotalAssets += _amount;
    }

    function freeFunds(uint256 _amount) external override {
        // Mock implementation - just track the amount
        if (_amount > mockTotalAssets) {
            mockTotalAssets = 0;
        } else {
            mockTotalAssets -= _amount;
        }
    }

    function shutdownWithdraw(uint256) external override {
        // Mock implementation - do nothing
    }

    function tendThis(uint256) external override {
        // Mock implementation - do nothing
    }

    function tendTrigger() external pure override returns (bool, bytes memory) {
        return (false, "");
    }

    function report() external pure override returns (uint256 profit, uint256 loss) {
        // Mock implementation - return no profit/loss
        return (0, 0);
    }

    /* =============== TESTING HELPER FUNCTIONS =============== */

    /**
     * @dev Set the mock total assets to simulate gains/losses
     */
    function setMockTotalAssets(uint256 _totalAssets) external {
        mockTotalAssets = _totalAssets;
    }

    /**
     * @dev Set available deposit limit for testing
     */
    function setAvailableDepositLimit(uint256 _limit) external {
        mockAvailableDepositLimit = _limit;
    }

    /**
     * @dev Set available withdraw limit for testing
     */
    function setAvailableWithdrawLimit(uint256 _limit) external {
        mockAvailableWithdrawLimit = _limit;
    }

    /**
     * @dev Control whether harvest should revert
     */
    function setShouldRevertOnHarvest(bool _shouldRevert) external {
        shouldRevertOnHarvest = _shouldRevert;
    }

    /**
     * @dev Simulate a deposit and update internal accounting
     */
    function simulateDeposit(uint256 _assets) external {
        StrategyData storage S = _strategyStorage();
        S.asset.transferFrom(msg.sender, address(this), _assets);
        mockTotalAssets += _assets;
    }

    /**
     * @dev Simulate a withdrawal and update internal accounting
     */
    function simulateWithdraw(uint256 _assets) external {
        StrategyData storage S = _strategyStorage();
        if (_assets > mockTotalAssets) {
            mockTotalAssets = 0;
        } else {
            mockTotalAssets -= _assets;
        }
        S.asset.transfer(msg.sender, _assets);
    }

    /**
     * @dev Simulate a loss by reducing total assets
     */
    function simulateLoss(uint256 _lossAmount) external {
        if (_lossAmount > mockTotalAssets) {
            _lossAmount = mockTotalAssets;
        }
        mockTotalAssets -= _lossAmount;
    }

    /**
     * @dev Simulate a gain by increasing total assets
     */
    function simulateGain(uint256 _gainAmount) external {
        mockTotalAssets += _gainAmount;
    }

    /**
     * @dev Get mock total assets (totalAssets is not virtual so we can't override it)
     */
    function getMockTotalAssets() external view returns (uint256) {
        return mockTotalAssets;
    }

    /**
     * @dev Force update the stored totalAssets to match mock
     */
    function syncTotalAssets() external {
        StrategyData storage S = _strategyStorage();
        S.totalAssets = mockTotalAssets;
    }

    /**
     * @dev Mint shares directly to an address (for testing)
     */
    function mintShares(address _to, uint256 _shares) external {
        StrategyData storage S = _strategyStorage();
        _mint(S, _to, _shares);
    }

    /**
     * @dev Burn shares directly from an address (for testing)
     */
    function burnShares(address _from, uint256 _shares) external {
        StrategyData storage S = _strategyStorage();
        _burn(S, _from, _shares);
    }

    /* =============== CONVERSION OVERRIDE =============== */

    /* =============== TESTING UTILITIES =============== */

    /**
     * @dev Create a scenario with deposits and total assets
     */
    function setupTestScenario(
        uint256, // _initialDeposits - unused
        uint256 _currentTotalAssets,
        uint256 // _lossAmount - no longer used
    ) external {
        // Set up the scenario
        mockTotalAssets = _currentTotalAssets;

        StrategyData storage S = _strategyStorage();
        S.totalAssets = _currentTotalAssets;
    }

    /**
     * @dev Reset all mock state
     */
    function resetMockState() external {
        mockTotalAssets = 0;
        mockAvailableDepositLimit = type(uint256).max;
        mockAvailableWithdrawLimit = type(uint256).max;
        shouldRevertOnHarvest = false;

        StrategyData storage S = _strategyStorage();
        S.totalAssets = 0;
    }
}
