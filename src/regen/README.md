# RegenStaker

Staking contracts for regenerative finance with earning power, reward distribution, and public goods contribution.

---

## Quick Start

```solidity
// 1. Deploy via factory
RegenStakerFactory factory = RegenStakerFactory(FACTORY_ADDRESS);
address staker = factory.createStakerWithoutDelegation(params, salt, bytecode);

// 2. Stake
bytes32 depositId = regenStaker.stake(amount, delegatee, claimer);

// 3. Claim rewards
uint256 rewards = regenStaker.claimReward(depositId);

// 4. Contribute to public goods
regenStaker.contribute(depositId, mechanism, amount, deadline, v, r, s);

// 5. Withdraw
regenStaker.withdraw(depositId, amount);
```

---

## Contract Variants

### RegenStaker
For IERC20Staking tokens with voting delegation support via surrogates.

**Use when:**
- Token supports IERC20Staking (ERC20 + delegation)
- Users need to delegate voting power while staked
- Example: GLM token with governance

**Note:** First use of a delegatee deploys a surrogate (higher cost), subsequent uses reuse existing surrogates.

### RegenStakerWithoutDelegateSurrogateVotes
For standard ERC20 tokens without delegation.

**Use when:**
- Standard ERC20 without voting
- Simpler architecture preferred

---

## Core Functions

```solidity
// Staking
stake(amount, delegatee, claimer) → depositId
stakeMore(depositId, amount)
withdraw(depositId, amount)

// Rewards
claimReward(depositId) → amount
compoundRewards(depositId) → amount  // requires reward token == stake token

// Public goods
contribute(depositId, mechanism, amount, deadline, v, r, s) → amount
```

**Note:** `contribute` supports zero `amount` for signature-only registration when mechanisms allow zero-deposit signup.

---

## Parameters

### Core Config
- **Reward Duration**: 7-3000 days
- **Minimum Stake**: Token's smallest unit (e.g., 1e18 for 18-decimal)
- **Max Bump Tip**: Maximum tip for earning power updates

### Access Control (3-tier system)

#### 1. Staker Access (3 modes)

**NONE** - Open staking
```solidity
stakerAccessMode: AccessMode.NONE
```

**ALLOWSET** - Restricted to approved addresses
```solidity
stakerAccessMode: AccessMode.ALLOWSET
stakerAllowset: IAddressSet (required)
```

**BLOCKSET** - Open except blocked addresses
```solidity
stakerAccessMode: AccessMode.BLOCKSET
stakerBlockset: IAddressSet (required)
```

#### 2. Allocation Mechanism Access

**Always required** - Cannot be disabled

```solidity
allocationMechanismAllowset: IAddressSet (cannot be address(0))
```

Only trusted mechanisms. Malicious mechanisms can steal contributed funds.

---

## Deployment

### Prerequisites
- RegenEarningPowerCalculator deployed
- AddressSet contracts deployed (or use `address(0)` for NONE mode)
- Allocation mechanisms deployed and verified

### Factory Deployment

```solidity
struct CreateStakerParams {
    IERC20 rewardsToken;
    IERC20 stakeToken;                    // Must be IERC20Staking for WITH_DELEGATION variant
    address admin;                        // Use multisig
    IAddressSet stakerAllowset;           // For ALLOWSET mode (can be address(0))
    IAddressSet stakerBlockset;           // For BLOCKSET mode (can be address(0))
    AccessMode stakerAccessMode;          // NONE, ALLOWSET, or BLOCKSET
    IAddressSet allocationMechanismAllowset;  // Required, only trusted mechanisms
    IEarningPowerCalculator earningPowerCalculator;
    uint256 maxBumpTip;                   // In reward token's smallest unit
    uint256 minimumStakeAmount;           // In stake token's smallest unit
    uint256 rewardDuration;               // 7-3000 days
}

// Deploy factory with canonical bytecode hashes
RegenStakerFactory factory = new RegenStakerFactory(
    regenStakerBytecodeHash,      // WITH_DELEGATION canonical hash
    noDelegationBytecodeHash       // WITHOUT_DELEGATION canonical hash
);

// Deploy instance - pass actual bytecode (will be validated against hash)
address staker = factory.createStakerWithDelegation(
    params, 
    salt, 
    regenStakerBytecode            // Actual bytecode (validated)
);

// Or without delegation
address staker = factory.createStakerWithoutDelegation(
    params, 
    salt, 
    noDelegationBytecode           // Actual bytecode (validated)
);
```

### Post-Deployment

```solidity
// If using ALLOWSET mode
stakerAllowset.add(initialStakers);

// If using BLOCKSET mode
stakerBlockset.add(blockedAddresses);

// Required: Add only trusted mechanisms
allocationMechanismAllowset.add(trustedMechanisms);

// Set access mode
staker.setAccessMode(AccessMode.ALLOWSET);
```

---

## Claimer Permissions

When you set a claimer for a deposit, you grant specific permissions:

### What Claimers CAN Do
- Claim rewards to their address
- Compound rewards (when reward token == stake token)
- Contribute rewards to allocation mechanisms
  - **⚠️ CRITICAL: Claimer receives voting power, NOT deposit owner**

### What Claimers CANNOT Do
- Withdraw principal stake
- Call `stakeMore()` directly
- Alter deposit parameters (delegatee, claimer)

### Security Considerations

**Trust Model:**
- Claimers are trusted agents for reward management
- Claimers get voting power when contributing (intended behavior)
- Owners can revoke claimers anytime via `alterClaimer()`

**Dual-Check Architecture:**
1. Mechanism checks `msg.sender` (claimer) eligibility → claimer gets voting power
2. RegenStaker checks `deposit.owner` eligibility → prevents proxy abuse

Example: If owner is delisted from mechanism, even allowlisted claimer cannot contribute owner's rewards.

### Best Practices
1. Only designate trusted addresses as claimers
2. Monitor claimer activities (especially contributions)
3. Understand claimers receive voting power when contributing
4. Revoke claimer when no longer needed

---

## Access Control Deep Dive

### Staker Access Modes

#### NONE - Open Staking
```solidity
// Configuration
stakerAccessMode: AccessMode.NONE
stakerAllowset: address(0) or any (ignored)
stakerBlockset: address(0) or any (ignored)

// Behavior
Anyone can stake, no restrictions
```

**Use case:** Open, permissionless staking

#### ALLOWSET - Restricted Staking
```solidity
// Configuration
stakerAccessMode: AccessMode.ALLOWSET
stakerAllowset: IAddressSet (required, contains allowed addresses)
stakerBlockset: address(0) or any (ignored)

// Behavior
Only addresses in allowset can stake
Reverts with StakerNotAllowed(address) if not in allowset
```

**Use case:** KYC, whitelisted staking, compliance requirements

**Grandfathering:** Existing stakers unaffected by allowset changes

#### BLOCKSET - Open with Blocks
```solidity
// Configuration
stakerAccessMode: AccessMode.BLOCKSET
stakerAllowset: address(0) or any (ignored)
stakerBlockset: IAddressSet (required, contains blocked addresses)

// Behavior
Anyone can stake EXCEPT addresses in blockset
Reverts with StakerBlocked(address) if in blockset
```

**Use case:** Sanctions compliance, blocking bad actors

### Allocation Mechanism Allowset

**Always required, cannot be disabled**

```solidity
allocationMechanismAllowset: IAddressSet (CANNOT be address(0))
```

**Security model:**
```
User Contributes
      ↓
RegenStaker validates:
  ✓ Mechanism in allowset?
  ✓ Deposit owner eligible?
  ✓ Contributor eligible?
      ↓
Transfer to Mechanism
(CANNOT RECOVER if malicious)
```

**Before adding mechanisms:**
1. Security review completed
2. Integration tests passing
3. Governance approval obtained
4. Trust established

### Admin Functions

```solidity
// Change staker access
setStakerAllowset(IAddressSet _stakerAllowset)
setStakerBlockset(IAddressSet _stakerBlockset)
setAccessMode(AccessMode _mode)

// Change mechanism access
setAllocationMechanismAllowset(IAddressSet _allocationMechanismAllowset)
// Cannot set to address(0)
// Must be distinct from staker address sets

// Other admin
setRewardDuration(uint128 _rewardDuration)      // Cannot change during active rewards
setMinimumStakeAmount(uint128 _minimumStakeAmount)  // Grandfathers existing deposits
setMaxBumpTip(uint256 _newMaxBumpTip)          // Governance protection during active rewards
pause()     // Pauses all operations except withdrawals
unpause()   // Resumes operations
```

---

## Security

### Token Requirements
**Standard ERC20 only:**
- ✅ Standard ERC20
- ❌ Fee-on-transfer tokens
- ❌ Rebasing tokens
- ❌ Deflationary tokens

Accounting assumes `transferred amount == requested amount`. Non-standard tokens break deposits, withdrawals, or rewards.

### Pause Behavior

```solidity
staker.pause();    // Emergency only
staker.unpause();  // After resolution
```

**When paused:**
- ❌ Disabled: stake, stakeMore, claim, contribute, compound, alterDelegatee, alterClaimer
- ✅ Enabled: withdraw (user protection - always can access principal)
- 📊 Rewards: Continue accumulating (timeline unchanged)

### Allocation Mechanism Trust

**Critical security boundary:**
- Only add trusted mechanisms
- Malicious mechanisms can steal all contributed funds
- No recovery path for funds sent to bad mechanisms
- Changes affect future contributions only

### Reward Balance Validation

Contract tracks:
- `totalRewards` - All rewards ever added
- `totalClaimedRewards` - All rewards consumed (claims, compounds, contributions, tips)
- `totalStaked` - Total stake currently in contract

Validation on `notifyRewardAmount`:
```
requiredBalance = (totalRewards - totalClaimedRewards) + newAmount
currentBalance >= requiredBalance
```

Reverts with `InsufficientRewardBalance` if validation fails.

---

## Events

### User Actions
```solidity
event StakeDeposited(address indexed depositor, bytes32 indexed depositId, uint256 amount, uint256 balance, uint256 earningPower);
event RewardClaimed(bytes32 indexed depositId, address indexed claimer, uint256 amount, uint256 newEarningPower);
event RewardContributed(bytes32 indexed depositId, address indexed contributor, address indexed fundingRound, uint256 amount);
```

### Admin Actions
```solidity
event RewardScheduleUpdated(uint256 addedAmount, uint256 carryOverAmount, uint256 totalScheduledAmount, uint256 requiredBalance, uint256 duration, uint256 endTime);
event StakerAllowsetAssigned(IAddressSet indexed allowset);
event StakerBlocksetAssigned(IAddressSet indexed blockset);
event AccessModeSet(AccessMode indexed mode);
event AllocationMechanismAllowsetAssigned(IAddressSet indexed allowset);
event RewardDurationSet(uint256 newDuration);
event MinimumStakeAmountSet(uint256 newMinimumStakeAmount);
```

---

## Error Codes

| Error | Cause |
|-------|-------|
| `MinimumStakeAmountNotMet` | Stake below minimum threshold |
| `StakerNotAllowed` | Address not in allowset (ALLOWSET mode) |
| `StakerBlocked` | Address in blockset (BLOCKSET mode) |
| `NotInAllowset` | Mechanism not in allocation allowset |
| `CompoundingNotSupported` | Reward token ≠ stake token |
| `InvalidRewardDuration` | Duration outside 7-3000 day range |
| `DepositOwnerNotEligibleForMechanism` | Owner not eligible for contribution |
| `InsufficientRewardBalance` | Contract lacks rewards for notification |
| `CantAfford` | Insufficient unclaimed rewards |
| `AssetMismatch` | Mechanism expects different token |
| `ZeroOperation` | Attempted zero-value operation |
| `SurrogateNotFound` | Surrogate doesn't exist for delegatee |

---

## Common Pitfalls

### Surrogate Confusion
❌ **Wrong:** `IERC20(stakeToken).balanceOf(regenStaker)`
✅ **Right:** `regenStaker.totalStaked()`

RegenStaker moves tokens to delegation surrogates internally.

### Reward Rate Constraint
Minimum reward amount must satisfy: `rewardAmount >= rewardDuration` (in wei). This ensures the scaled reward rate is valid. For example, with 7-day duration (604,800 seconds), minimum reward is ~604,800 wei.

### Signature Replay
Always use nonces and deadlines in EIP-712 signatures to prevent replay attacks.

### Access Control Mistakes

❌ **Don't use same allowset for stakers and mechanisms:**
```solidity
params.stakerAllowset = allowset;
params.allocationMechanismAllowset = allowset; // SAME OBJECT - REVERTS
```

❌ **Don't try to disable mechanism allowset:**
```solidity
setAllocationMechanismAllowset(address(0)); // NOT ALLOWED
```

❌ **Don't add untrusted mechanisms:**
```solidity
allocationMechanismAllowset.add(untrustedMechanism); // SECURITY RISK
```

✅ **Do use distinct address sets:**
```solidity
IAddressSet stakerAllowset = new AddressSet();
IAddressSet mechanismAllowset = new AddressSet(); // Different object
```

### Claimer Voting Power
Remember: When claimer contributes, **claimer gets voting power**, not owner. This is intended behavior.

### Token Compatibility
Only standard ERC20. Non-standard tokens (fee-on-transfer, rebasing, deflationary) will break accounting.

---

## Integration Examples

### Basic Staking Flow
```solidity
// User stakes
bytes32 depositId = regenStaker.stake(
    1000 ether,
    msg.sender,  // delegatee
    msg.sender   // claimer
);

// Time passes, rewards accrue
uint256 earned = regenStaker.unclaimedReward(depositId);

// User claims
uint256 claimed = regenStaker.claimReward(depositId);
```

### Contribution Flow
```solidity
// Check earned rewards
uint256 earned = regenStaker.unclaimedReward(depositId);

// Get EIP-712 signature
(uint8 v, bytes32 r, bytes32 s) = getSignature(...);

// Contribute to allocation mechanism
regenStaker.contribute(
    depositId,
    mechanismAddress,
    earned,
    deadline,
    v, r, s
);
// Note: msg.sender receives voting power in mechanism
```

### Compound Flow
```solidity
// Only works when reward token == stake token
if (address(regenStaker.REWARD_TOKEN()) == address(regenStaker.STAKE_TOKEN())) {
    uint256 compounded = regenStaker.compoundRewards(depositId);
    // Rewards now added to principal stake
}
```

---

## Testing

### Unit Tests
`test/unit/regen/`

### Integration Tests
`test/integration/regen/`

### Test Access Control
```solidity
// Test ALLOWSET mode
staker.setAccessMode(AccessMode.ALLOWSET);
stakerAllowset.add(alice);

vm.prank(alice);
staker.stake(amount, alice, alice); // ✓ Success

vm.prank(bob);
vm.expectRevert(abi.encodeWithSelector(StakerNotAllowed.selector, bob));
staker.stake(amount, bob, bob); // ✗ Reverts

// Test BLOCKSET mode
staker.setAccessMode(AccessMode.BLOCKSET);
stakerBlockset.add(eve);

vm.prank(eve);
vm.expectRevert(abi.encodeWithSelector(StakerBlocked.selector, eve));
staker.stake(amount, eve, eve); // ✗ Reverts
```

---

## Architecture Notes

### Delegation Surrogate Pattern (RegenStaker)

**How it works:**
1. User stakes with delegatee
2. Contract deploys/fetches DelegationSurrogateVotes for delegatee (CREATE2)
3. Tokens transferred to surrogate (not main contract)
4. Surrogate delegates voting power to delegatee
5. Delegatee can vote in governance
6. On unstake, tokens withdrawn from surrogate

**Key points:**
- One surrogate per delegatee (not per user)
- Multiple users can share same surrogate
- Deterministic addresses (CREATE2)
- Surrogates only hold tokens and delegate

### Earning Power

Calculated by `IEarningPowerCalculator`:
- Determines reward distribution share
- Can be linear, quadratic, time-weighted, etc.
- Pluggable interface for custom logic
- Can be bumped with tips to incentivize updates

### Reward Streaming

Rewards stream linearly over `rewardDuration`:
- When `totalEarningPower == 0`, pause streaming (extend end time)
- When `totalEarningPower > 0`, resume streaming
- Prevents reward waste during idle periods

---

## Production Considerations

### Optimization
- Pre-deploy surrogates for popular delegatees
- Batch operations when possible
- Use longer reward durations (less frequent updates)

### Monitoring
- Watch for access control changes (events)
- Monitor reward schedule updates
- Track contribution flows to mechanisms
- Alert on pause/unpause events

### Upgrades
- RegenStaker is non-upgradeable
- To upgrade: deploy new instance, migrate users
- Consider migration incentives

### Recovery
- Admin can pause for emergencies
- Users can always withdraw (even when paused)
- No recovery for funds sent to malicious mechanisms

---

## License

AGPL-3.0-only (inherits from Staker.sol by ScopeLift)

---

## Security

See main repository for security information.

---

## Resources

- **Code**: `src/regen/RegenStaker.sol`, `src/regen/RegenStakerBase.sol`
- **Tests**: `test/integration/regen/`, `test/unit/regen/`
- **Factory**: `src/factories/RegenStakerFactory.sol`
- **Repository**: https://github.com/golemfoundation/octant-v2-core

---

## Contact

**Golem Foundation**
- Website: https://golem.foundation
- Security: security@golem.foundation

