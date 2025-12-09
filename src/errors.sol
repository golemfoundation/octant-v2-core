// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.25;

// Centralized custom errors for gas-efficient reverts across Octant contracts.
// Using custom errors saves ~50 bytes per error vs require(condition, "string").

error Unauthorized();
error ZeroAddress();
error ReentrancyGuard__ReentrantCall();
error ZeroShares();
error ZeroAssets();
error ERC20InsufficientBalance();
error AlreadyInitialized();

error NotInAllowset(address user);
error InBlockset(address user);

error TokenizedStrategy__NotEmergencyAuthorized();
error TokenizedStrategy__NotKeeperOrManagement();
error TokenizedStrategy__NotOperator();
error TokenizedStrategy__NotManagement();
error TokenizedStrategy__NotRegenGovernance();
error TokenizedStrategy__AlreadyInitialized();
error TokenizedStrategy__DepositMoreThanMax();
error TokenizedStrategy__MintMoreThanMax();
error TokenizedStrategy__InvalidMaxLoss();
error TokenizedStrategy__TransferFromZeroAddress();
error TokenizedStrategy__TransferToZeroAddress();
error TokenizedStrategy__TransferToStrategy();
error TokenizedStrategy__MintToZeroAddress();
error TokenizedStrategy__BurnFromZeroAddress();
error TokenizedStrategy__ApproveFromZeroAddress();
error TokenizedStrategy__ApproveToZeroAddress();
error TokenizedStrategy__InsufficientAllowance();
error TokenizedStrategy__PermitDeadlineExpired();
error TokenizedStrategy__InvalidSigner();
error TokenizedStrategy__TransferFailed();
error TokenizedStrategy__NotSelf();
error TokenizedStrategy__WithdrawMoreThanMax();
error TokenizedStrategy__RedeemMoreThanMax();
error TokenizedStrategy__NotPendingManagement();
error TokenizedStrategy__StrategyNotInShutdown();
error TokenizedStrategy__TooMuchLoss();
error TokenizedStrategy__HatsAlreadyInitialized();
error TokenizedStrategy__InvalidHatsAddress();
error DragonTokenizedStrategy__ReceiverHasExistingShares();

error DragonTokenizedStrategy__VaultSharesNotTransferable();
error DragonTokenizedStrategy__PerformanceFeeIsAlwaysZero();
error DragonTokenizedStrategy__PerformanceFeeDisabled();
error DragonTokenizedStrategy__ZeroLockupDuration();
error DragonTokenizedStrategy__InsufficientLockupDuration();
error DragonTokenizedStrategy__DepositMoreThanMax();
error DragonTokenizedStrategy__MintMoreThanMax();
error DragonTokenizedStrategy__WithdrawMoreThanMax();
error DragonTokenizedStrategy__RedeemMoreThanMax();
error DragonTokenizedStrategy__SharesStillLocked();
error DragonTokenizedStrategy__InvalidLockupDuration();
error DragonTokenizedStrategy__InvalidRageQuitCooldownPeriod();
error DragonTokenizedStrategy__RageQuitInProgress();
error DragonTokenizedStrategy__StrategyInShutdown();
error DragonTokenizedStrategy__NoSharesToRageQuit();
error DragonTokenizedStrategy__SharesAlreadyUnlocked();
error DragonTokenizedStrategy__LockupDurationTooShort();
error DragonTokenizedStrategy__MaxUnlockIsAlwaysZero();
error DragonTokenizedStrategy__NoOperation();
error DragonTokenizedStrategy__InvalidReceiver();

error BaseStrategy__NotSelf();
