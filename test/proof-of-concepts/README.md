# Octant V2 Security Proof of Concepts

This directory contains proof-of-concept demonstrations for security findings from the TrustSec and Spearbit/Cantina audits. Each test provides concrete evidence of vulnerabilities, architectural validations, or behavioral analysis.

## Test Categories

### 🔴 Critical Vulnerabilities (Exploitable)
Tests that demonstrate actual security vulnerabilities requiring immediate patches.

#### `LIN001_TimestampStalenessExploit.t.sol`
- **Finding**: LinearAllowance timestamp staleness exploitation
- **Mechanism**: Conditional timestamp updates enable retroactive allowance calculations
- **Location**: `src/zodiac-core/modules/LinearAllowanceSingletonForGnosisSafe.sol:231`
- **Severity**: High - Enables systematic fund drainage
- **Impact**: Direct financial loss through timestamp manipulation

#### `REG006_GovernanceExploit.t.sol`
- **Finding**: MaxBumpTip governance extraction vulnerability
- **Mechanism**: Admin can extract unclaimed rewards by manipulating earning power
- **Location**: `dependencies/staker-1.0.1/src/Staker.sol:297`
- **Severity**: Medium - Governance attack vector
- **Impact**: Admin can extract user rewards through parameter manipulation

#### `REG007_WithdrawalLockupDemo.t.sol`
- **Finding**: RegenStakerWithoutDelegateSurrogateVotes withdrawal lockup
- **Mechanism**: Missing self-approval causes transferFrom to fail for contract-to-user transfers
- **Location**: `src/regen/RegenStakerWithoutDelegateSurrogateVotes.sol:111-117`
- **Severity**: High - User funds permanently stuck
- **Impact**: Complete loss of user deposits

#### `REG008_CompoundAllowsetBypassDemo.t.sol`
- **Finding**: CompoundRewards allowset bypass vulnerability
- **Mechanism**: Missing depositor allowset check when claimer calls compoundRewards
- **Location**: `src/regen/RegenStakerBase.sol:590-647`
- **Severity**: High - Access control bypass
- **Impact**: Circumvents allowset restrictions for delisted users

### 🟡 Architecture Validations (Educational)
Tests that validate correct system behavior and design decisions.

#### `REG001_DelegateeAllowsetDemo.t.sol`
- **Finding**: Delegatee allowset architecture analysis (NOT A VULNERABILITY)
- **Status**: Justified - Correct separation of protocol vs external governance
- **Severity**: N/A - Architecture validation
- **Purpose**: Demonstrates proper delegation design
- **Test Coverage**: 6 tests proving security properties

#### `REG003_ComprehensiveProductionProof.t.sol`
- **Finding**: Mathematical precision documentation error
- **Mechanism**: Documentation incorrectly states shorter durations increase error
- **Location**: `src/regen/RegenStakerBase.sol:278`
- **Severity**: Info - Documentation correction needed
- **Purpose**: Mathematical proof of actual precision characteristics

## Quick Reference

| Finding | Type | Severity | Exploitable | Fund Risk |
|---------|------|----------|-------------|-----------|
| LIN-001 | Exploit | High | ✅ | Direct Loss |
| REG-006 | Exploit | Medium | ✅ | Governance Risk |
| REG-007 | Demo | High | ✅ | Permanent Lock |
| REG-008 | Demo | High | ✅ | Access Bypass |
| REG-001 | Demo | N/A | ❌ | None |
| REG-003 | Demo | Info | ❌ | None |

## Test Execution

### Run All Proof of Concepts
```bash
forge test --match-path "test/proof-of-concepts/*.sol" -vv
```

### Run by Category
```bash
# Critical vulnerabilities only
forge test --match-test "(LIN001|REG00[678])" -vv

# Architecture validations only  
forge test --match-test "(REG001|REG003)" -vv
```

### Run Individual Tests
```bash
# Specific proof of concept
forge test --match-contract "REG007WithdrawalLockupDemoTest" -vv
```

## Expected Behavior

### Exploits (Should Demonstrate Attacks)
- **LIN001**: Shows successful timestamp manipulation and fund extraction
- **REG006**: Demonstrates admin reward extraction through earning power manipulation
- **REG007**: Proves deposits succeed but withdrawals fail permanently
- **REG008**: Shows allowset bypass through claimer mechanism

### Demonstrations (Should Pass/Validate)
- **REG001**: All tests pass showing correct delegatee architecture
- **REG003**: Mathematical proofs validate precision characteristics

## Security Impact Summary

### Immediate Action Required
1. **PATCH-001**: Fix LIN-001 timestamp staleness (High priority)
2. **PATCH-007**: Fix REG-007 withdrawal lockup (High priority)  
3. **PATCH-008**: Fix REG-008 allowset bypass (High priority)

### Governance Review Required
4. **PATCH-002**: Fix REG-006 governance asymmetry (Medium priority)

### Documentation Updates
5. **PATCH-003**: Correct REG-003 precision documentation (Info priority)

## Development Guidelines

### Adding New Proof of Concepts
1. Use descriptive naming: `[FindingID]_[ShortDescription][Type].t.sol`
2. Include clear vulnerability description in contract comments
3. Provide concise, focused tests without excessive logging
4. Follow existing patterns for exploits vs demonstrations

### Code Standards
- Use named imports: `import {Contract} from "path/Contract.sol"`
- Follow naming conventions: `ContractNameTest`
- Minimize console output and focus on assertions
- Include severity and impact information in comments

---

*Last Updated: 2025-07-28*  
*Comprehensive security proof of concepts for Octant V2 audit findings*