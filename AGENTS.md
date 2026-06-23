# AGENTS.md

Guidance for AI coding agents working on this repository.

## Commands

```bash
yarn build                # compile (skips test/ and script/)
yarn build:contracts      # compile + combine proxy ABIs
forge test                # run all tests
yarn test:ci              # run tests with JUnit output
yarn lint                 # solhint linting
yarn format:check         # prettier format check
yarn format               # prettier format fix
yarn coverage             # forge coverage (lcov)
yarn coverage:summary     # forge coverage (summary table)
```

## Directory layout

| Directory | Contents |
|-----------|----------|
| `src/` | Production Solidity contracts |
| `script/` | Foundry/bash scripts: `.s.sol` in subdirectories, bash `.sh` at root level |
| `scripts/` | Node.js tooling (e.g. `sol-semver.mjs` for Solidity semver checks) |
| `test/unit/` | Unit tests |
| `test/integration/` | Integration tests (forked mainnet) |
| `test/kontrol/` | Kontrol formal verification tests |
| `verification/` | Formal verification support (Kontrol K definitions) |
| `dependencies/` | Soldeer-managed dependencies |

**Note the singular vs plural:** `script/` holds Foundry/bash scripts; `scripts/` holds Node.js tooling. They are distinct directories.

## Key references

- [CONTRIBUTING.md](CONTRIBUTING.md): coding conventions, PR guidelines, NatSpec standards, testing patterns
- [.github/code-review.md](.github/code-review.md): security and quality review standards
- [script/README.md](script/README.md): script directory structure and shell utility documentation

## Conventions

- Foundry toolchain (`forge`, `cast`, `anvil`); Soldeer for dependency management
- Conventional commits: `type(scope): message`
- Solidity `^0.8.25`; compiled with solc `0.8.33` (pinned in `foundry.toml`); optimizer enabled
- AGPL-3.0-or-later license for original code; preserve upstream licenses for ported/adapted code
- NatSpec required on all public/external functions; use `@inheritdoc` for overrides
- Tests follow Arrange-Act-Assert pattern
