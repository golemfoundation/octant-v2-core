// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title TestStructs
/// @notice Shared structs for strategy integration tests to avoid stack too deep errors

/// @dev Struct for multi-user test scenarios
struct TestState {
    address user1;
    address user2;
    uint256 depositAmount1;
    uint256 depositAmount2;
    uint256 initialExchangeRate;
    uint256 newExchangeRate1;
    uint256 newExchangeRate2;
    uint256 donationBalanceBefore1;
    uint256 donationBalanceAfter1;
    uint256 donationBalanceBefore2;
    uint256 donationBalanceAfter2;
    uint256 user1Shares;
    uint256 user2Shares;
    uint256 user1Assets;
    uint256 user2Assets;
    uint256 user1Profit;
    uint256 user2Profit;
    uint256 user1ProfitPercentage;
    uint256 user2ProfitPercentage;
}

/// @dev Struct for fuzz tests to avoid stack too deep
struct FuzzTestState {
    uint256 initialExchangeRate;
    uint256 profitRate;
    uint256 firstLossRate;
    uint256 secondLossRate;
    uint256 donationSharesAfterProfit;
    uint256 donationSharesAfterFirstLoss;
    uint256 donationSharesAfterSecondLoss;
    uint256 assetsReceived;
}

/// @dev Struct for profit fuzz tests
struct ProfitFuzzTestState {
    uint256 totalAssetsBefore;
    uint256 initialExchangeRate;
    uint256 newExchangeRate;
    uint256 donationAddressBalanceBefore;
    uint256 donationAddressBalanceAfter;
    uint256 totalAssetsAfter;
    uint256 sharesToRedeem;
    uint256 assetsReceived;
    uint256 donationAssetsReceived;
}

/// @dev Struct for profit/loss test data
struct ProfitLossTestData {
    address user1;
    address user2;
    uint256 depositAmount1;
    uint256 depositAmount2;
    uint256 initialRate;
    uint256 increasedRate;
    uint256 user1Shares;
    uint256 user2Shares;
    uint256 profit1;
    uint256 loss1;
    uint256 dragonShares;
    uint256 user1Assets;
    uint256 user2Assets;
    uint256 profit2;
    uint256 loss2;
    uint256 dragonSharesAfterLoss;
}

/// @dev Struct for dragon withdrawal test scenarios
struct DragonWithdrawalTestData {
    address user1;
    uint256 depositAmount;
    uint256 initialRate;
    uint256 increasedRate;
    uint256 decreasedRate;
    uint256 finalRate;
    uint256 user1Shares;
    uint256 dragonSharesAfterProfit;
    uint256 dragonAssets;
    uint256 profit1;
    uint256 loss1;
    uint256 profit2;
    uint256 loss2;
    uint256 profit3;
    uint256 loss3;
    uint256 assetsReceived;
}

/// @dev Struct for setup parameters to avoid stack too deep
struct SetupParams {
    address management;
    address keeper;
    address emergencyAdmin;
    address donationAddress;
    string vaultSharesName;
    bytes32 strategySalt;
    address implementationAddress;
    bool enableBurning;
}
