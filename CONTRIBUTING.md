# Contribution Guide for Octant V2 Core

## 🌟 Our Development Philosophy

At Golem Foundation, we believe in creating maintainable, high-quality code through thoughtful collaboration. This guide outlines our expectations and best practices for contributing to the project.

## 📋 Pull Request Guidelines

### Atomic Commits
- Each commit should represent a single logical change
- Use clear, descriptive commit messages that explain *why* the change was made
- Follow the [conventional commits](https://www.conventionalcommits.org/en/v1.0.0/) format: `type(scope): message` (e.g., `fix(rewards): correct calculation for staking rewards`)
- Avoid mixing unrelated changes in a single commit

### PR Management
As PRs get bigger, time to review them scales super-linearly. And long-standing PRs create lots of merge conflict and duplicate work. It's much cheaper for the team to make small and prompt changes to codebase than big and belated changes.


- Keep PRs focused on a single feature, bug fix, or improvement
- Aim for PRs under 300 lines of code when possible
- Split large features into smaller, sequential PRs
- Include relevant tests and documentation with your changes
- Review existing PRs (if requested) before creating new ones
- Help merge ready PRs to prevent accumulation
- Set aside a time for PR reviews daily
- Rebase your branch before requesting review to ensure it's up-to-date

## 🧩 Code Quality Principles

### Simplicity First
Main time cost of developing smart-contract is audits, not development itself. By solving things in simplest, clearest way we can reduce this cost dramatically.

- Implement the simplest solution that meets requirements
- Avoid premature optimization or over-engineering
- Write self-documenting code with clear variable and function names, with clear intent
- Use comments as a last resort when things are not clear enough

### Maintainability
- Aim for high coherence and loose coupling
- Adhere to [SOLID Principles](https://hackernoon.com/solid-principles-in-smart-contract-development) so we can ensure solidity (pun intended) of our code 
- Consider future (maintenance, or other) costs in your design decisions

### Technical Debt Management
- Apply the ["Boy Scout Rule"](https://deviq.com/principles/boy-scout-rule): Leave the code better than you found it
- Address small issues before they become big problems
- Document what you stumble upon and can't address now

## 🔍 Code Review Process

### As an Author
- Self-review your code before requesting reviews
- **Write concise PR descriptions** - Focus on what changed and why, not implementation details
    - Keep under 15 lines when possible
    - Link to detailed docs if needed (don't paste them in description)
    - Use bullet points for clarity
- Be open to feedback and willing to make changes
- Use the PR description to highlight areas where you'd like specific feedback

### As a Reviewer
- Be respectful and constructive in your feedback
- Focus on the code, not the person
- Stay in the scope of the PR during your review
- Be specific, leave no room for confusion
- Try to approve ASAP when concerns are addressed
## 🛠️ Development Workflow
- We use [Gitflow](https://www.atlassian.com/git/tutorials/comparing-workflows/gitflow-workflow) as Git branching model.
- We use a pre-commit hook to automatically format, lint and test, ensuring no surprises on continuous integration run.
## 🤝 Communication
- Use clear, verbose language in all communications
- Ask questions when something isn't clear
- Share progress and blockers with the team
- Be mindful of others' time and priorities

## 🔒 Security Considerations
- Always prioritize security and only then consider gas optimizations
- Follow established security patterns for smart contracts
- Consider edge cases and potential attack vectors
- Document security assumptions and considerations

## 🧪 Testing Standards

### Test Structure (Arrange-Act-Assert)

All tests MUST follow the AAA pattern for clarity and maintainability:

```solidity
function test_deposit_MintsCorrectShares() public {
    // Arrange - Set up test state
    uint256 depositAmount = 1000e18;
    deal(address(asset), user, depositAmount);
    vm.startPrank(user);
    asset.approve(address(vault), depositAmount);

    // Act - Execute the operation being tested
    uint256 shares = vault.deposit(depositAmount, user);

    // Assert - Verify expected outcomes
    assertEq(shares, expectedShares, "Should mint correct shares");
    assertEq(vault.balanceOf(user), shares, "User should receive shares");
    assertEq(asset.balanceOf(address(vault)), depositAmount, "Vault should hold assets");
    vm.stopPrank();
}
```

**Why AAA?**
- **Arrange**: Makes test setup explicit and reproducible
- **Act**: Isolates the exact behavior being tested
- **Assert**: Clearly documents expected outcomes

### Naming Conventions

Follow these patterns for discoverability:

- **Files**: `ContractName.t.sol`, `ContractNameIntegration.t.sol`, `ContractNameInvariants.t.sol`
- **Unit Tests**: `test_functionName_Scenario()` (e.g., `test_deposit_RevertsWhenPaused()`)
- **Fuzz Tests**: `testFuzz_functionName_Scenario(uint256 x)` (e.g., `testFuzz_deposit_AlwaysMintsShares(uint256 amount)`)
- **Revert Tests**: `test_RevertWhen_condition()` (e.g., `test_RevertWhen_DepositExceedsLimit()`)

### Coverage Expectations

- Run `yarn coverage` before submitting PRs
- Check uncovered branches and add tests for critical paths
- View detailed reports with `yarn coverage:genhtml`
- Focus on security-critical functions (access control, asset handling, state transitions)

### Security Requirements

For detailed security and quality requirements (what edge cases to test, anti-patterns to avoid), see [.github/code-review.md](.github/code-review.md#testing-requirements).

---

## 📚 NatSpec Documentation Standards

**The Four Pillars**: Every NatSpec contribution must adhere to:
1. **Syntax** - Proper tag usage and formatting
2. **Semantics** - Accurate descriptions matching implementation
3. **License** - Correct SPDX identifiers and copyleft compliance
4. **Attribution** - Proper credit to original authors and sources

### Quick Reference

| Tag | Required | Example |
|-----|----------|---------|
| `@title` | YES | `@title YourContract` |
| `@author` | YES | `@author [Golem Foundation](https://golem.foundation)` |
| `@notice` | YES (functions/events) | `@notice Deposits assets and mints shares` |
| `@dev` | When needed | `@dev Uses ERC4626 with ROUND_DOWN` |
| `@param` | YES | `@param assets Amount of assets to deposit` |
| `@return` | If returns | `@return Minted shares` |
| `@inheritdoc` | For overrides | `@inheritdoc IYourInterface` |
| `@custom:security-contact` | YES | `@custom:security-contact security@golem.foundation` |
| `@custom:security` | For privileged | `@custom:security Only callable by management` |
| `@custom:origin` | For adapted code | `@custom:origin https://github.com/org/repo/blob/hash/file.sol` |
| `@custom:ported-from` | For ported code | `@custom:ported-from https://github.com/org/repo/blob/hash/file.sol` |

**Note on Errors**: Custom errors should be self-documenting through descriptive names. Do NOT add @notice tags to errors.

### Don't Repeat Yourself (DRY)

**ALWAYS use `@inheritdoc` when overriding functions from parent contracts or interfaces to avoid duplicating documentation.**

When a function overrides a parent implementation, use `@inheritdoc ParentContract` instead of duplicating the documentation. Only add additional context specific to your implementation using `@dev` tags.

**Good - Using @inheritdoc**:
```solidity
/// @inheritdoc IERC4626Payable
/// @dev Requires operator role when dragon mode is enabled
function deposit(uint256 assets, address receiver)
    external payable override returns (uint256 shares) {
    // implementation
}
```

**Bad - Duplicating parent documentation**:
```solidity
/// @notice Deposits assets into the vault and mints shares to receiver
/// @param assets Amount of assets to deposit in asset base units
/// @param receiver Address to receive minted shares
/// @return shares Amount of shares minted in share base units
/// @dev Requires operator role when dragon mode is enabled
function deposit(uint256 assets, address receiver)
    external payable override returns (uint256 shares) {
    // implementation
}
```

**When to use @inheritdoc**:
- ✅ Function overrides parent/interface function
- ✅ Documentation would be identical or nearly identical to parent
- ✅ You want to reference the canonical documentation in the interface/parent

**When NOT to use @inheritdoc**:
- ❌ Signature or behavior differs significantly from parent
- ❌ Parent contract has no documentation (document it properly instead)
- ❌ Implementation-specific nuances require full documentation

---

### License & Attribution

#### Attribution Patterns

**Original Golem Code**:
```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later

/**
 * @title YourContract
 * @author [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 */
```

**Modified External Code**:
```solidity
// SPDX-License-Identifier: GPL-3.0  // ← Preserve original license

/**
 * @author Yearn.finance; modified by [Golem Foundation](https://golem.foundation)
 * @custom:security-contact security@golem.foundation
 * @custom:origin https://github.com/yearn/[repo]/blob/[COMMIT_HASH]/path/to/file.sol
 * @notice Your description here
 */
```

**Design-Inspired (Not Derivative)**:
```solidity
// SPDX-License-Identifier: AGPL-3.0-or-later  // ← Use AGPL-3.0-or-later

/**
 * @author [Golem Foundation](https://golem.foundation)
 * @dev Design inspired by:
 *      - OpenZeppelin Governor: https://github.com/OpenZeppelin/[...]
 *      - Yearn Strategy: https://github.com/yearn/[...]
 */
```

---

### Documentation Rules

**Core Principles**:
- **Attention is scarce**: Document what's necessary and nothing more. Make it count.
- Document WHY, not WHAT (code shows what)
- Specify units ONLY when genuinely ambiguous (follow OpenZeppelin standard)
- No "The..." anti-patterns that restate names
- Keep it concise - every word must earn its place

**Common Mistakes**:

| ❌ Don't | ✅ Do |
|---------|-------|
| `@param amount The amount` | `@param amount Amount of assets to deposit` |
| `@param assets Amount of assets in asset base units` | `@param assets Amount of assets to deposit` |
| `@return The shares` | `@return Minted shares` |
| `@param deployer The deployer address` | `@param deployer Address that deployed contract` |

**Units Reference** (Only when genuinely ambiguous):

| Type | When to Specify | Format |
|------|-----------------|--------|
| **ERC4626 assets/shares** | ❌ Never (standard convention) | `@param assets Amount of assets` |
| **Multiple share types** | ✅ Always | `@param shares Proportional allocation shares (unitless)` |
| **Basis points** | ✅ Always | `@param fee Fee in basis points (10000 = 100%)` |
| **Time (ambiguous)** | ✅ When unclear | `@param duration Duration in seconds` (not blocks) |
| **Timestamps** | ❌ Never (Unix standard) | `@param timestamp Timestamp of event` |
| **Exchange rates** | ✅ Non-standard only | `@param rate Rate in RAY precision (1e27)` |

**Golden Rule**: Follow OpenZeppelin conventions - only add unit qualifiers when there's genuine ambiguity.

---

### Marking Ported vs Adapted Code

**Ported Code** = Implementation PRESERVED (we maintain but don't modify core logic)
- Tag: `@custom:ported-from <URL>`
- Example: Direct Solidity port of Vyper contract, extracted library, unmodified interface

**Adapted Code** = Implementation MODIFIED (forked, adapted, or heavily changed from upstream)
- Tag: `@custom:origin <URL>`
- Example: Forked contract with Octant-specific changes, adapted interface

**IMPORTANT**: These tags are **mutually exclusive** - use one or the other, never both.

#### How to Mark Code

**For Ported Code** (use `@custom:ported-from`):
- ✅ Keep original NatSpec documentation style
- ✅ Preserve original "The..." patterns (don't fix them)
- ✅ Only update: SPDX license, @author attribution, @custom:security-contact
- ✅ Add `@custom:ported-from <URL>` with link to original source
- ❌ Don't apply our strict NatSpec standards

**For Adapted Code** (use `@custom:origin`):
- ✅ Apply full NatSpec standards from this guide
- ✅ Fix "The..." patterns
- ✅ Add proper @author attribution noting modification (forked/adapted/modified)
- ✅ Add `@custom:origin <URL>` with link to original source

#### Examples

**Ported (Implementation Unmodified)**:
```solidity
/**
 * @title MultistrategyVault
 * @author yearn.finance; port maintained by [Golem Foundation]
 * @custom:security-contact security@golem.foundation
 * @custom:ported-from https://github.com/yearn/yearn-vaults-v3/blob/master/contracts/VaultV3.vy
 * @notice ... (preserve original documentation)
 */
```

**Extracted Library (Still Ported)**:
```solidity
/**
 * @title DebtManagementLib
 * @author yearn.finance; extracted as library by [Golem Foundation]
 * @custom:security-contact security@golem.foundation
 * @custom:ported-from https://github.com/yearn/yearn-vaults-v3/blob/master/contracts/VaultV3.vy
 * @notice ... (preserve original documentation)
 */
```

**Adapted Code (Implementation Modified)**:
```solidity
/**
 * @title TokenizedStrategy
 * @author yearn.finance; forked and modified by [Golem Foundation]
 * @custom:security-contact security@golem.foundation
 * @custom:origin https://github.com/yearn/tokenized-strategy/blob/master/src/TokenizedStrategy.sol
 * @notice Tokenized strategy with Octant-specific enhancements
 * @dev Apply our NatSpec standards - fix "The..." patterns, add units, etc.
 */
```

---

### Before You Commit

- [ ] All public/external functions have `@notice`, `@param`, `@return`
- [ ] All events have `@notice` and `@param` for each parameter
- [ ] Used `@inheritdoc` for overridden functions instead of duplicating documentation
- [ ] Ambiguous numeric params/returns specify units (follow OpenZeppelin - don't over-specify)
- [ ] Contract has `@title`, `@author`, `@custom:security-contact`
- [ ] Privileged functions have `@custom:security`
- [ ] Custom errors use self-documenting names (NO @notice tags)
- [ ] License adheres to copyleft if modifying GPL/AGPL code
- [ ] Attribution credits original authors with source links
- [ ] No TODO/FIXME in production
- [ ] No "The..." patterns that merely restate names
- [ ] `forge doc` generates clean output

---

Thank you for contributing to Octant V2 Core!
