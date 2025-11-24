# GitHub Copilot Instructions - Octant V2 Core

**Purpose**: High-level principles and philosophy for secure DeFi development.

**For detailed review checklists**: See [code-review.md](code-review.md)
**For contribution workflow**: See [CONTRIBUTING.md](../CONTRIBUTING.md)

---

## Philosophy

These guidelines exist to empower you to build secure, efficient, and maintainable DeFi infrastructure. We value:

- **Simplicity**: Solve problems in the simplest way to reduce audit costs and cognitive load
- **Security First**: User funds are sacred - every line must defend them
- **Explicit Over Implicit**: Clear code is correct code. No magic, no assumptions
- **Standards Compliance**: Follow established patterns (ERC-4626, CEI) unless there's compelling reason not to

Think critically. Question patterns. But remember: in DeFi, creativity in security patterns often leads to exploits. Innovation belongs in architecture, not in reinventing access control or error handling.

---

## Core Principles

### Security-First Development

**User funds are sacred.** Every line of code must defend them. When in doubt between gas optimization and security, choose security. Audit costs dwarf development costs - write code that's trivial to audit.

**Critical invariants:**
- Assets never disappear without explicit user action
- Share value never decreases except through reported losses
- Access control is explicit, never inferred
- State changes are atomic and complete

### The CEI Pattern (Checks-Effects-Interactions)

This is non-negotiable in DeFi:
1. **Checks**: Validate all inputs and preconditions
2. **Effects**: Update all state variables
3. **Interactions**: Only then make external calls

Violating this pattern is the #1 cause of exploits. State must be consistent before any external interaction.

### ERC-4626 Rounding Direction

Wrong rounding direction can drain entire vaults:
- **Deposits/mints**: Round DOWN shares (user gets less, vault protected)
- **Withdrawals/redeems**: Round UP shares (user pays more, vault protected)

This is not optional. This is survival.

### Mathematical Correctness

Conversions must be mathematical inverses:
- If `shares = convertToShares(assets)`, then `assets ≈ convertToAssets(shares)`
- Asymmetric conversions create arbitrage opportunities
- Multi-step decimal conversions (27→18→27) lose precision catastrophically

Test conversion symmetry in every vault implementation.

---

## What Matters Most

### 1. Asset Safety
- All asset movements emit events
- Balance changes recorded before external calls
- No silent transfers, burns, or misaccounting
- Idle assets included in `totalAssets`

### 2. Access Control
- Privileged functions have explicit role checks
- Use `Ownable2Step`, `AccessControl`, Safe modules, or Hats
- Never bare `msg.sender == admin` checks
- Role escalation impossible

### 3. Reentrancy Protection
- `ReentrancyGuard` on all value-moving flows
- Update state before external calls
- Strategy callbacks are untrusted
- Debt/allocation updated atomically

### 4. State Consistency
- Validate all state transitions explicitly
- No implicit state assumptions
- Accumulated state considered (`totalAssets + lossAmount`)
- Configuration changes not applied retroactively

### 5. External Protocol Integration
- Handle paused/reverted external calls gracefully
- Don't assume external protocols always succeed
- Parameter mismatches between checks and execution
- Decimal precision in conversions

---

## Architecture Overview

### Core Contracts
**Vaults and Strategies** - Multi-strategy vaults allocate assets across yield strategies. Each strategy implements `_deployFunds()`, `_freeFunds()`, and `_harvestAndReport()`. Critical: idle assets must be accounted for, debt updated atomically, and conversions must be mathematical inverses.

### Strategy Types
**Yield Donating** - All yield goes to beneficiary. Track baseline assets, donate profit on harvest.

**Yield Skimming** - Retain baseline yield rate, donate excess. More complex accounting with time-based expected returns.

### Dragon Protocol
**Safe Modules** - Execute arbitrary code through Gnosis Safe with full permissions. This is extremely powerful and dangerous. Every input must be validated rigorously. Use allowlists, never blocklists. Module calls can reenter.

### Access Control Patterns
**Allowlist/Blocklist** - `AccessMode` enum determines who can call. Prefer allowlists for high-value operations.

**Passport System** - Track active status, expiration, and granular permissions per address.

**Role Bitmasks** - Efficient multi-role management using bitwise operations.

## Domain Terms

- **Dragon Protocol**: Safe module for cross-protocol DeFi operations
- **RegenStaker**: Regenerative staking with delegation
- **Allowset/Blockset**: Access control lists (`AccessMode` enum)
- **Lockup**: Token locking with time-based unlock
- **Debt Management**: Strategy allocation and rebalancing
- **Profit Unlocking**: Gradual profit distribution
- **Rage Quit**: Emergency exit with penalty

---

## Quick Reference

**Standards**: ERC-4626 (vaults), EIP-1167 (minimal proxies)

**Philosophy**: "Solve things in simplest way to reduce audit costs"

**Key Files**:
- [code-review.md](code-review.md) - Comprehensive review checklist (all domains)
- [CONTRIBUTING.md](../CONTRIBUTING.md) - Contribution workflow and standards

**Config**: See `foundry.toml`
