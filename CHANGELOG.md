# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0-develop.9](https://github.com/golemfoundation/octant-v2-core/compare/1.2.0-develop.8..1.2.0-develop.9) - 2026-05-01

### Bug Fixes

- **(tokenized-strategy)** bailsec #8 emit emergency withdraw event - ([b53eaae](https://github.com/golemfoundation/octant-v2-core/commit/b53eaae7350737f3cea110c4f661117f1a0ef7ec)) - Ferit

### Miscellaneous Tasks

- **(tokenized-strategy)** bump API_VERSION to 1.1.0 - ([1e38f80](https://github.com/golemfoundation/octant-v2-core/commit/1e38f8010157c270c37ad2be54c02e8be4d4df57)) - Ferit


## [1.2.0-develop.8](https://github.com/golemfoundation/octant-v2-core/compare/1.2.0-develop.7..1.2.0-develop.8) - 2026-05-01

### CI/CD

- **(kontrol)** hide prove status bar - ([2fe1b80](https://github.com/golemfoundation/octant-v2-core/commit/2fe1b807e88073fdf6eac0d56bf2c576db6e36d2)) - Ferit

### Testing

- **(kontrol)** assert forwarder guard arguments - ([96a603f](https://github.com/golemfoundation/octant-v2-core/commit/96a603f3e27576ac7f019b87d36308a47d1c6a05)) - Ferit
- **(kontrol)** fix yield skimming storage slot - ([67f57b0](https://github.com/golemfoundation/octant-v2-core/commit/67f57b0b9f7a08e3054c76772ab3dd4c3519b9cc)) - Ferit
- **(kontrol)** fix forwarder redeem guard proofs - ([56038db](https://github.com/golemfoundation/octant-v2-core/commit/56038db62e17e0157c247b4080f313ef9902bd2b)) - Ferit


## [1.2.0-develop.7](https://github.com/golemfoundation/octant-v2-core/compare/1.2.0-develop.6..1.2.0-develop.7) - 2026-04-29

### CI/CD

- restore Kontrol PR check - ([df79ddf](https://github.com/golemfoundation/octant-v2-core/commit/df79ddf33f925b46ac3b6bb234b5396ebc19c699)) - Ferit


## [1.2.0-develop.6](https://github.com/golemfoundation/octant-v2-core/compare/1.2.0-develop.5..1.2.0-develop.6) - 2026-04-27

### Testing

- tighten SSR accrual tests to fail on stripped drip() - ([8206f58](https://github.com/golemfoundation/octant-v2-core/commit/8206f58417a7173e7a37e0f93e2d7b052f17f2b2)) - Maxime
- add Spark sUSDS savings rate vault integration tests - ([e71a18a](https://github.com/golemfoundation/octant-v2-core/commit/e71a18a7ee65b166597791df7c7a5dc85126c717)) - Maxime


## [1.2.0-develop.5](https://github.com/golemfoundation/octant-v2-core/compare/1.2.0-develop.4..1.2.0-develop.5) - 2026-04-27

### Bug Fixes

- **(aave)** add RewardsController claim and airdrop sweep paths - ([935cde8](https://github.com/golemfoundation/octant-v2-core/commit/935cde8b4ca23e3a480a961e223d85832c44972f)) - skimaharvey
- **(aave)** re-read dataProvider on every call to track Aave rotations - ([984e94c](https://github.com/golemfoundation/octant-v2-core/commit/984e94c65d11f8d267560444d0abd4debf2c7308)) - skimaharvey
- **(aave)** include accruedToTreasury in deposit cap headroom - ([a7c7328](https://github.com/golemfoundation/octant-v2-core/commit/a7c7328d0fc17eba5ca5670914c3919f9556f124)) - skimaharvey
- **(aave)** short-circuit limits when reserve is paused or frozen - ([67e9b15](https://github.com/golemfoundation/octant-v2-core/commit/67e9b151ab3ac6824c035589d8d01430dca3098e)) - skimaharvey
- **(aave)** clear pool approval after each supply - ([57ea2d6](https://github.com/golemfoundation/octant-v2-core/commit/57ea2d6b6e477b64d8018ef5c340456db0daa408)) - skimaharvey
- **(ci)** retry semver build with unversioned overlays - ([2557801](https://github.com/golemfoundation/octant-v2-core/commit/25578019ca8a062952b55467d8c352ab3246a478)) - Maxime Viard
- **(swapping-forwarder)** reuse inherited token forwarding - ([7fd969d](https://github.com/golemfoundation/octant-v2-core/commit/7fd969dbcfeee0d7e747090e4eb9a8ebc5def00c)) - Maxime Viard

### Documentation

- **(aave)** clarify emergencyWithdraw depends on Aave pool state - ([c87d90b](https://github.com/golemfoundation/octant-v2-core/commit/c87d90b1f6114648ec552d54f29f44eba386bd36)) - skimaharvey
- **(aave)** note withdraw dust revert in withdraw limit - ([62873aa](https://github.com/golemfoundation/octant-v2-core/commit/62873aa3c0975a3f0eafbcf13a12ba4eb5d3c774)) - skimaharvey
- **(aave)** note deposit dust revert in deposit limit - ([57ed4d5](https://github.com/golemfoundation/octant-v2-core/commit/57ed4d5713a690f7f0b0c6b8ba5f8b5b87a6b7eb)) - skimaharvey


## [1.2.0-develop.4](https://github.com/golemfoundation/octant-v2-core/compare/1.2.0-develop.3..1.2.0-develop.4) - 2026-04-27

### Bug Fixes

- remove duplicate audit PDF with incorrect name - ([ded547a](https://github.com/golemfoundation/octant-v2-core/commit/ded547a51e4e4883b1428f9099f16c681e3c4083)) - Maxime

### Documentation

- add Cantina review fixes audit report - ([c30bea1](https://github.com/golemfoundation/octant-v2-core/commit/c30bea149e00c189e18000985290f29832049893)) - Maxime


## [1.2.0-develop.3](https://github.com/golemfoundation/octant-v2-core/compare/1.2.0-develop.2..1.2.0-develop.3) - 2026-04-26

### Bug Fixes

- **(yield-skim)** burn old dragon dust before migration - ([bc9fc1e](https://github.com/golemfoundation/octant-v2-core/commit/bc9fc1efb7a17ebfa6bcb2528f1d01cd97f72c87)) - skimaharvey
- **(yield-skim)** post-migration solvency check in finalizeDragonRouterChange - ([27f8e29](https://github.com/golemfoundation/octant-v2-core/commit/27f8e29e65c918a3e766db2c877d9b8214441fdf)) - skimaharvey
- **(yield-skim)** saturate dragon-debt subtraction in loss protection - ([3e9555e](https://github.com/golemfoundation/octant-v2-core/commit/3e9555ecbfc69547730943f0d2db98e3d7517eee)) - skimaharvey
- **(yield-skim)** conform YIELD_SKIMMING_STORAGE_SLOT to ERC-7201 - ([c38082d](https://github.com/golemfoundation/octant-v2-core/commit/c38082d627bfbc19a4849a05315537d7683c2e51)) - skimaharvey

### Documentation

- **(yield-skim)** clarify Reported.loss is gross shortfall, not a delta - ([98cb0ad](https://github.com/golemfoundation/octant-v2-core/commit/98cb0ad2cbdfa340e11ac647579c6c1eb7977f8a)) - skimaharvey
- **(yield-skim)** clarify share value is underlying-asset units, not native ETH - ([df5db0c](https://github.com/golemfoundation/octant-v2-core/commit/df5db0ccd8b31fa26bf27cc92977a765c9677ccb)) - skimaharvey


## [1.2.0-develop.2](https://github.com/golemfoundation/octant-v2-core/compare/1.2.0-develop.1..1.2.0-develop.2) - 2026-04-26

### Bug Fixes

- **(ci)** retry semver build with unversioned overlays - ([db71381](https://github.com/golemfoundation/octant-v2-core/commit/db7138154c6457e4572896f079140582389d4f69)) - Maxime Viard
- **(swapping-forwarder)** reuse inherited token forwarding - ([3f14672](https://github.com/golemfoundation/octant-v2-core/commit/3f146728d09d09b6ba75bcdf1f438deadd375eeb)) - Maxime Viard
- **(yield-donating)** bailsec #55 #57 revert on zero shares minted by target vault - ([e4ccd7e](https://github.com/golemfoundation/octant-v2-core/commit/e4ccd7e95afed3cb5a07648ef606dc1386dade46)) - Maxime
- **(yield-donating)** bailsec #54 use previewRedeem instead of convertToAssets - ([7943f26](https://github.com/golemfoundation/octant-v2-core/commit/7943f26d20035ec31b0e059351f7c7181146957a)) - Maxime
- **(yield-donating)** bailsec #52 preserve uint256.max sentinel in availableDepositLimit - ([f15e6dd](https://github.com/golemfoundation/octant-v2-core/commit/f15e6ddf614a38dfadc1dba834aed63c2a1d4b5c)) - Maxime
- **(yield-donating)** bailsec #60 exact-amount approval in _deployFunds - ([2335365](https://github.com/golemfoundation/octant-v2-core/commit/2335365bcd6d9df0d2c11d733d74fbf75a6f1615)) - skimaharvey

### Documentation

- **(erc4626)** warn that target vaults require per-vault security review - ([33bc87d](https://github.com/golemfoundation/octant-v2-core/commit/33bc87d828a48069ff1955596ebed4962728e03c)) - Maxime
- **(yearn-v3-strategy)** bailsec #59 document hardcoded maxLoss in _emergencyWithdraw - ([a54273b](https://github.com/golemfoundation/octant-v2-core/commit/a54273beec221becac07a876422445500556bd79)) - Maxime


## [1.2.0-develop.1](https://github.com/golemfoundation/octant-v2-core/compare/backup/pr418-pre-surgery..1.2.0-develop.1) - 2026-04-24

### Bug Fixes

- **(curve-swapper)** cantina #1 enforce zero-residue invariant - ([d82fcca](https://github.com/golemfoundation/octant-v2-core/commit/d82fccab76a8c9d91fdae94f4b7830bab70ed0de)) - skimaharvey
- **(privileged)** gate deposits by caller only - ([4c0e83d](https://github.com/golemfoundation/octant-v2-core/commit/4c0e83d5963f2d7bc5de52dd95adafde8e96d8aa)) - Maxime
- **(privileged)** skip no-op writes and events - ([59fd35a](https://github.com/golemfoundation/octant-v2-core/commit/59fd35a39b9c9a5112a5aca7992b2443ea5eeaf5)) - Maxime
- **(psm-swapper)** bailsec #70 compute exact psm charge and pull minimum - ([fd44d30](https://github.com/golemfoundation/octant-v2-core/commit/fd44d30b1907dc5ad310e4ed0966f929dd290197)) - skimaharvey
- **(semver)** downgrade storage layout changes from major to minor - ([b21a545](https://github.com/golemfoundation/octant-v2-core/commit/b21a545c434282f572b3caf96836dd66e8948ae8)) - Ferit
- **(semver)** address review feedback from PR #394 - ([a72dd70](https://github.com/golemfoundation/octant-v2-core/commit/a72dd70844ba88809ce27f8ec56b443253c93521)) - Ferit
- **(semver)** scope discovery to contracts declaring API_VERSION - ([3d96e7d](https://github.com/golemfoundation/octant-v2-core/commit/3d96e7de90435ac8104d5a1d4a17b99b7219d4e1)) - Ferit
- **(semver)** normalize renamed lock ids and ignore comment contracts - ([a135211](https://github.com/golemfoundation/octant-v2-core/commit/a13521155a8ac1e654a9771c242b694760b85a9c)) - Ferit
- **(semver)** handle renames and honor explicit contract scope - ([a5698da](https://github.com/golemfoundation/octant-v2-core/commit/a5698da10b2c5af49e8fd1c67601f22ea18d055c)) - Ferit
- **(semver)** tighten workflow triggers and ABI/version edge checks - ([1b5e7c0](https://github.com/golemfoundation/octant-v2-core/commit/1b5e7c0588886a64b50c45902db565d173ce0232)) - Ferit
- **(semver)** handle merge-base and tuple/deletion discovery edge cases - ([e68d9ad](https://github.com/golemfoundation/octant-v2-core/commit/e68d9ad86b3f1367828f8604d0bebef8a7856454)) - Ferit
- **(semver)** treat event anonymity changes as breaking - ([2a1b170](https://github.com/golemfoundation/octant-v2-core/commit/2a1b1703528cea8ce20a5d4a9b339b8a60bf42d4)) - Ferit
- **(semver)** analyze deleted contracts as breaking changes - ([851a0f1](https://github.com/golemfoundation/octant-v2-core/commit/851a0f1b29dd4ebb4c9fd84c853221512c60ff36)) - Ferit
- **(semver)** enforce API_VERSION on changed contracts - ([e375644](https://github.com/golemfoundation/octant-v2-core/commit/e37564491ecc1480682d95c7c2f77737c8d0e7b2)) - Ferit
- **(sol-semver)** harden contract and lock validation - ([90b2332](https://github.com/golemfoundation/octant-v2-core/commit/90b2332fa595db5edd72743f0642b22d31f804be)) - Ferit
- **(swappers)** validate conversionFactor != 0 for BUY_GEM route - ([b9a9d70](https://github.com/golemfoundation/octant-v2-core/commit/b9a9d700bde01dc82a08f3c77d66fbbba0a4c190)) - Maxime
- **(swapping-forwarder)** clear swapper allowance after swap - ([8c5bc4c](https://github.com/golemfoundation/octant-v2-core/commit/8c5bc4c7b5d7009036b62d4bad6aeddf1207b7dc)) - skimaharvey
- **(swapping-forwarder)** add authorized forwardToken - ([a4d2f2b](https://github.com/golemfoundation/octant-v2-core/commit/a4d2f2ba90c151e6037ce30c4fead5d5a006bbd6)) - skimaharvey
- **(swapping-forwarder)** bailsec #68 require caller-supplied deadline - ([d4d463c](https://github.com/golemfoundation/octant-v2-core/commit/d4d463cfa89f53891b041be2127eb912984c5b5b)) - skimaharvey
- **(swapping-forwarder)** bailsec #61 #62 mirror maxRedeem cap and ZERO_ASSETS skip - ([5e0cf2d](https://github.com/golemfoundation/octant-v2-core/commit/5e0cf2d93ff60f8ac07cf465baf299922e5f7a37)) - skimaharvey
- **(uniswap-v3-swapper)** bailsec #73 #74 return leftover and zero router approval - ([fd52181](https://github.com/golemfoundation/octant-v2-core/commit/fd52181025ffcf9c5ffbbeac66f0594d07a9b2f4)) - skimaharvey
- **(uniswap-v4-swapper)** initialize unused base - ([bf6a1d8](https://github.com/golemfoundation/octant-v2-core/commit/bf6a1d850260a45585cac3fd5b4e741ef106faf4)) - skimaharvey
- **(uniswap-v4-swapper)** return unused base on second-hop partial fill - ([cf380bc](https://github.com/golemfoundation/octant-v2-core/commit/cf380bc01015bf631ff9834902e43fce828fe54c)) - skimaharvey
- **(uniswap-v4-swapper)** bailsec #76 take unused tokenin back via unlockcallback - ([77356cc](https://github.com/golemfoundation/octant-v2-core/commit/77356cc1dcedf7461615bfc120bff10ef706561a)) - skimaharvey
- **(yield-donate)** skip zero-share donation event - ([3e847c4](https://github.com/golemfoundation/octant-v2-core/commit/3e847c42f9e1545ba3a87fd5db7d4edbd354490a)) - Maxime
- **(yield-forwarder)** skip zero-asset redeem - ([3108012](https://github.com/golemfoundation/octant-v2-core/commit/3108012621fffb6c42909a8fc4c4bbb6691a1f81)) - skimaharvey
- **(yield-forwarder)** cap shares at strategy.maxRedeem - ([5dd7682](https://github.com/golemfoundation/octant-v2-core/commit/5dd76827a49f3a66a1bb4d3c2893a48ddc67d616)) - Maxime
- **(yield-forwarder)** add authorized forwardToken - ([28d1886](https://github.com/golemfoundation/octant-v2-core/commit/28d1886ddef51edddc1416fe959bc0b4376d8b7e)) - Maxime
- **(yield-skim)** mirror gates in preview functions - ([cd5009e](https://github.com/golemfoundation/octant-v2-core/commit/cd5009e85335d70ba8bcc486746c5731c2375fd4)) - Maxime
- simulate lazy burn in maxWithdraw/maxRedeem for ERC4626 compliance - ([dbca1e5](https://github.com/golemfoundation/octant-v2-core/commit/dbca1e52f9a64e0f2d556b60ab324136fccf012a)) - Maxime
- burn dragon shares before pricing user exits during insolvency - ([475a69f](https://github.com/golemfoundation/octant-v2-core/commit/475a69f54311cb30fb64b93c94757e67e11c52cc)) - Maxime
- lint solidity scripts with script-specific solhint config - ([0163706](https://github.com/golemfoundation/octant-v2-core/commit/0163706261cc2657654c651204557673dbf3e69e)) - Ferit
- exclude script/ from solhint lint glob - ([12e8263](https://github.com/golemfoundation/octant-v2-core/commit/12e82639b746cd0c09385455757c4ac49ade423f)) - Ferit
- tighten semver API version detection - ([0908bbc](https://github.com/golemfoundation/octant-v2-core/commit/0908bbc66be389319c4aa81fd7461cae30326c8e)) - Ferit
- use USDC/DAI V4 pool for multi-hop integration tests - ([9b06074](https://github.com/golemfoundation/octant-v2-core/commit/9b06074353ea79ffca004197fb72d0801a71c278)) - Maxime
- use existing V4 pool params for multi-hop integration tests - ([feac1b3](https://github.com/golemfoundation/octant-v2-core/commit/feac1b388abeff7a8d63c2804c62b737d493539d)) - Maxime
- update fork block to resolve V4 pool and RPC archive errors - ([c003c95](https://github.com/golemfoundation/octant-v2-core/commit/c003c95bf7767a9904ab0210f2f13453206d8cb5)) - Maxime
- tighten forwarder kontrol coverage - ([d06bf4b](https://github.com/golemfoundation/octant-v2-core/commit/d06bf4bef54698d96235fe109bf41de6f822ca75)) - Ferit
- use sentinel values to strengthen zero-share passthrough proofs - ([f83e85c](https://github.com/golemfoundation/octant-v2-core/commit/f83e85cdd0c7278d9a6c2e9e04adc17aeda9a622)) - Ferit
- emit event on zero-asset redeem in SwappingYieldForwarder - ([efd86d3](https://github.com/golemfoundation/octant-v2-core/commit/efd86d367d1030cad4a151bf1354275fc77ee28a)) - Maxime
- enforce 1:1 invariant for DaiUsds converter routes - ([066bb86](https://github.com/golemfoundation/octant-v2-core/commit/066bb86210443f799d12de98b309140a2f2bebf8)) - Maxime
- validate token-index consistency in CurveSwapper constructor - ([b6817bc](https://github.com/golemfoundation/octant-v2-core/commit/b6817bc0673436fba3777f2952fa2bb789e01a00)) - Maxime
- address review findings - ([c2837a3](https://github.com/golemfoundation/octant-v2-core/commit/c2837a3fb476625c684fc2ceac1fd3d657f782ca)) - Maxime

### CI/CD

- update packages and shared actions version(s) [skip ci] - ([da77e32](https://github.com/golemfoundation/octant-v2-core/commit/da77e32a3c2607a6ad5d36d0ec930e86d4743021)) - Michał Kluczek
- update runners reference and production GH environment  [skip ci] - ([e0cb8e9](https://github.com/golemfoundation/octant-v2-core/commit/e0cb8e9bd3d5a61be70450059272bc81f444901a)) - Michał Kluczek
- optimize jobs and fix internal actions access for shared runners [skip ci] - ([1023043](https://github.com/golemfoundation/octant-v2-core/commit/1023043cb7897cf4ef1c3bafaac09ef6a82fb24e)) - Michał Kluczek
- CICD workflows revamp [skip ci] - ([e51f422](https://github.com/golemfoundation/octant-v2-core/commit/e51f422582cf5bfcf3281337c33bac8e886a663e)) - Michał Kluczek
- add VERSION date check for develop-to-main PRs - ([9bd7caf](https://github.com/golemfoundation/octant-v2-core/commit/9bd7caff4f053ed8c3056d9262bb8a51db7fd396)) - Ferit
- set safe.directory for merge-base in semver check - ([fbf0986](https://github.com/golemfoundation/octant-v2-core/commit/fbf0986a6c5a397fa29a1f6015aff2f44a164324)) - Ferit

### Documentation

- **(periphery)** fix harvestAndReport NatSpec typo - ([12716f7](https://github.com/golemfoundation/octant-v2-core/commit/12716f7db0500bfabfb253f7383f34000a2a5513)) - Maxime
- **(swappers)** remove audit labels from comments - ([cb3c45f](https://github.com/golemfoundation/octant-v2-core/commit/cb3c45f5d05604312413a92ab7bc03f587d4510e)) - skimaharvey
- **(tokenized-strategy)** document unsupported token accounting - ([2176b20](https://github.com/golemfoundation/octant-v2-core/commit/2176b2053e676e222bd2ee9e18acce0c6405b281)) - Maxime
- **(tokenized-strategy)** fix lastReport timestamp comment - ([520ff43](https://github.com/golemfoundation/octant-v2-core/commit/520ff43f21de081881d98b6693eb9e5b018a015a)) - Maxime
- **(tokenized-strategy)** document permit frontrun grief - ([3bdd8d6](https://github.com/golemfoundation/octant-v2-core/commit/3bdd8d6668e8187bc916595f35b4bc98baa0ee3f)) - Maxime
- **(yield-donate)** document terminal-state recovery - ([5fef432](https://github.com/golemfoundation/octant-v2-core/commit/5fef432efb63962da0c0798b47e0a98ee59a70d1)) - Maxime
- **(yield-donate)** document keeper timing trust - ([3c1123b](https://github.com/golemfoundation/octant-v2-core/commit/3c1123b9d4de70908d53823eda6b9fda06b7a9d7)) - Maxime
- **(yield-forwarder)** bailsec #66 migration cooldown note - ([9887ba7](https://github.com/golemfoundation/octant-v2-core/commit/9887ba7f2ae0ef95f757e4df216becd0c1167b31)) - Maxime
- **(yield-forwarder)** bailsec #65 keeper-only API operational note - ([6c22d9b](https://github.com/golemfoundation/octant-v2-core/commit/6c22d9bdfe377b1137e228296ba4e3b73dc736bf)) - Maxime
- **(yield-forwarder)** document enableBurning incompatibility with YieldForwarder dragonRouter - ([18b291c](https://github.com/golemfoundation/octant-v2-core/commit/18b291c0cf89626080b68e38a548d40edfec08aa)) - Maxime
- consolidate docs/ into doc/ directory - ([b2535d8](https://github.com/golemfoundation/octant-v2-core/commit/b2535d8ab801f5f5f3303ec6d986eafff3ac7e08)) - Ferit
- introduce ADR practice with template and contributing guidelines - ([34f2b5c](https://github.com/golemfoundation/octant-v2-core/commit/34f2b5c3b57d62910f40aa82c21e3caeed16f365)) - Ferit

### Features

- **(semver)** auto-discover changed versioned contracts - ([2f469bc](https://github.com/golemfoundation/octant-v2-core/commit/2f469bcba75cc1e659c63440c856dbacc7e0ac55)) - Ferit
- **(swapping-forwarder)** bailsec #67 admin-settable slippage floor - ([7d15ab0](https://github.com/golemfoundation/octant-v2-core/commit/7d15ab07ea314a8a9696c7f189a40f8112db0142)) - skimaharvey
- **(swapping-forwarder)** bailsec #72 #75 admin-settable swapper via vault management - ([2fd5f3e](https://github.com/golemfoundation/octant-v2-core/commit/2fd5f3eb52fa7eb9200c11978ea85275a40f91bf)) - skimaharvey
- add semantic version checks for contracts - ([b135ee5](https://github.com/golemfoundation/octant-v2-core/commit/b135ee5f0735e6612eda975b4eb3ea1d40b13a2d)) - Ferit
- add Kontrol formal verification proofs for YieldForwarder and SwappingYieldForwarder - ([53f5546](https://github.com/golemfoundation/octant-v2-core/commit/53f5546dd0318184e7fbb16a7dda58d077e6a8d2)) - Ferit
- add UniswapV4SwapperAdapter and tests - ([6f2f26a](https://github.com/golemfoundation/octant-v2-core/commit/6f2f26a481c50fb7cac08dace9a5decb61a6a079)) - Maxime
- add SwappingYieldForwarder and pluggable ISwapper adapters - ([8f0510e](https://github.com/golemfoundation/octant-v2-core/commit/8f0510ea190c3acafcff6c8e0234e5dceae17710)) - Maxime
- add YieldForwarder and YieldForwarderFactory contracts - ([09bb01c](https://github.com/golemfoundation/octant-v2-core/commit/09bb01c4254346d44fa4ce66791f2bfc3452019f)) - Maxime

### Miscellaneous Tasks

- update allocation mechanism deployment address in staging. - ([40fd832](https://github.com/golemfoundation/octant-v2-core/commit/40fd832ae7d3908b80c6238332a66aba78bc6040)) - GiFTED

### Refactor

- **(semver)** align on API_VERSION across contracts and checks - ([992a252](https://github.com/golemfoundation/octant-v2-core/commit/992a252b29dfa6de023cc291f21eb949142bbd50)) - Ferit
- **(semver)** enforce VERSION constant only - ([26b3214](https://github.com/golemfoundation/octant-v2-core/commit/26b32140c68e692c7966b11d5108bbd8b3b660f4)) - Ferit
- **(semver)** use contract-declared versions only - ([c681d5d](https://github.com/golemfoundation/octant-v2-core/commit/c681d5d6403d882361b2b0a8654d8567630b6dd0)) - Ferit
- **(swappers)** cantina #2 iswapper pull-pattern migration - ([bf343b9](https://github.com/golemfoundation/octant-v2-core/commit/bf343b99161aee6ab70c36f83c0ce80ed3645d69)) - skimaharvey
- **(version)** remove API_VERSION compatibility surface - ([076c070](https://github.com/golemfoundation/octant-v2-core/commit/076c070c629053d65324d4f9c32c8bc7b95d4d19)) - Ferit
- consolidate scripts/ into script/ and codify convention - ([0c74dd7](https://github.com/golemfoundation/octant-v2-core/commit/0c74dd777c12e290b262c57af57350217aab92d0)) - Ferit
- update Nouns proposal for keeper-gated YieldForwarder - ([46c8318](https://github.com/golemfoundation/octant-v2-core/commit/46c83186ffe5833599b5df6ef793b6032d2b4e8d)) - Maxime
- add keeper-gated report+forward flow to YieldForwarder - ([53f720e](https://github.com/golemfoundation/octant-v2-core/commit/53f720e28b123914688922a86f558b87e6c9a3ff)) - Maxime
- replace PaymentSplitter with YieldForwarder in Nouns DAO proposal - ([70a22e8](https://github.com/golemfoundation/octant-v2-core/commit/70a22e860e4913e31056d07da4661a275f05625f)) - Maxime

### Styling

- fix prettier formatting in UniswapV4 swapper files - ([a798a2e](https://github.com/golemfoundation/octant-v2-core/commit/a798a2e30aa8e8739ff378e42a6104805df4fe9f)) - Maxime
- apply prettier to regen consolidated test files - ([0cd1480](https://github.com/golemfoundation/octant-v2-core/commit/0cd1480c7854daf385f0c38782ff9a365f91ef52)) - Ferit

### Testing

- **(kontrol)** support swapping forwarder redeem guards - ([79ffca7](https://github.com/golemfoundation/octant-v2-core/commit/79ffca7919aaea26f3e7e07ba570beb94c9c2a1b)) - skimaharvey
- **(kpk)** pin fork block for vault deposits - ([a2ebb4a](https://github.com/golemfoundation/octant-v2-core/commit/a2ebb4a3f7d7e00e67b07a441e1f599c816438d7)) - Maxime
- update integration test expectations for lazy dragon burn - ([26e758b](https://github.com/golemfoundation/octant-v2-core/commit/26e758bd9f2f0aafd5630b7d5363e2e16cf87f63)) - Maxime
- add KPK Gearbox V3 WETH/wstETH integration tests - ([cdb6749](https://github.com/golemfoundation/octant-v2-core/commit/cdb674943b58f6b98a57fb3a07730f0b87b98d88)) - Maxime
- add KPK USDC/ETH Prime vault integration tests - ([1625510](https://github.com/golemfoundation/octant-v2-core/commit/1625510f22231f3fe654c15f5feaaf3d24f9f735)) - Maxime
- add swapper unit tests for 100% coverage - ([43dfb53](https://github.com/golemfoundation/octant-v2-core/commit/43dfb53146a823941e45c97a870b19e1ca7e684c)) - Maxime
- add swapper integration tests (PSM, Curve, Uniswap V3) - ([9cea7cc](https://github.com/golemfoundation/octant-v2-core/commit/9cea7cc5216488edf59dc8af0b7c4187b38d72c7)) - Maxime
- add SwappingYieldForwarder unit tests - ([6c8e9b6](https://github.com/golemfoundation/octant-v2-core/commit/6c8e9b67e5704330c197bb9376d9bf0bb2c61b2c)) - Maxime
- integrate YieldForwarder tests with real vault infrastructure - ([2cf0f19](https://github.com/golemfoundation/octant-v2-core/commit/2cf0f19021fbb0fa0b78772aea07a3f477d7c8f2)) - Maxime
- update tests for keeper-gated YieldForwarder design - ([dd14f1d](https://github.com/golemfoundation/octant-v2-core/commit/dd14f1da7beb8544b591e0df2ef1aeca678e754d)) - Maxime
- add YieldForwarder and YieldForwarderFactory unit tests - ([82dcb76](https://github.com/golemfoundation/octant-v2-core/commit/82dcb76ad051271d3e11f0c20fb48e93a27da2fa)) - Maxime
- fold regen same-token protection into base suite - ([43ad5fd](https://github.com/golemfoundation/octant-v2-core/commit/43ad5fd2c36e99e664e8cebacd5a1d2ebb5c059d)) - Ferit
- consolidate regen staker base suites further - ([e806156](https://github.com/golemfoundation/octant-v2-core/commit/e806156b94502d4d180023505f225d6cbb6c57ae)) - Ferit
- further consolidate regen test suites - ([4247ddd](https://github.com/golemfoundation/octant-v2-core/commit/4247ddd132dbaee5840c42f256f1d77eccdc9b7a)) - Ferit
- consolidate RegenStaker tests into unit/regen with coherent naming - ([12d823f](https://github.com/golemfoundation/octant-v2-core/commit/12d823f806b2bbcad5b7bddbdbfe3682a2b4d84b)) - Ferit




## [1.2.0-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v1.1.0-develop.0...v1.2.0-develop.0) (2026-03-02)


### Features

* add new contracts to DeployedAddresses helper ([dd3a18a](https://github.com/golemfoundation/octant-v2-core/commit/dd3a18a9224e720966b2914f02217f1fe4224018))
* add tenderly support for BatchScript helper ([8b220d7](https://github.com/golemfoundation/octant-v2-core/commit/8b220d7478e308010588e3693f0e1352ce2579cd))
* Regen Staker staging deployment script ([46b6da0](https://github.com/golemfoundation/octant-v2-core/commit/46b6da094f3c262313ba9cfbb46f576969841bc5))


### Bug Fixes

* preserve sepolia allocation factory and export reused allowsets ([06ef06f](https://github.com/golemfoundation/octant-v2-core/commit/06ef06f33804a388320e000ec4b2a2e101afeed9))
* use pinned bytecode constants in DeployRegenStaker script ([88c5ad3](https://github.com/golemfoundation/octant-v2-core/commit/88c5ad31b26e5675a7a08b319c6c19eed0714a28))

## [1.1.0-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v1.0.0-develop.0...v1.1.0-develop.0) (2026-02-27)


### Features

* add Codex config to use copilot-instructions.md ([2219bae](https://github.com/golemfoundation/octant-v2-core/commit/2219bae38fd861befdbe1c1838b79bb4ccb94b52))
* add Etherscan and Sourcify source code verification script ([8b8e036](https://github.com/golemfoundation/octant-v2-core/commit/8b8e0367fbb0217ed9e0f33bd33dc60c9c0b6a6c))
* add Etherscan and Sourcify source code verification script ([1b84eae](https://github.com/golemfoundation/octant-v2-core/commit/1b84eae4be50ad313dc031d60dced79bce1a4262))
* add maxWithdraw/maxRedeem overrides with custody support ([86677b4](https://github.com/golemfoundation/octant-v2-core/commit/86677b4ee05fc79021fd0282daa8a7550476e9fd))
* add regen staker deployment scripts ([#348](https://github.com/golemfoundation/octant-v2-core/issues/348)) ([a32216e](https://github.com/golemfoundation/octant-v2-core/commit/a32216e9995f18c7a1dd8a8c6dcb227fbb7687bf))
* add RegenStaker infra to deployment script ([24779e9](https://github.com/golemfoundation/octant-v2-core/commit/24779e9eb2acc8019c40a8dd484d1455998c092b))
* add reproducible protocol deployment script ([dd5555b](https://github.com/golemfoundation/octant-v2-core/commit/dd5555b5cd0b3e30d3983291dead2327b0ac3dc1))
* add yearnV3Factory to DeployYieldSkimmingStrategiesAndFactories ([5da08ff](https://github.com/golemfoundation/octant-v2-core/commit/5da08ff1fecdfa762da3aaaa720c46fd863fece1))
* allow salt overrides for safe deploy scripts ([b4ae9b2](https://github.com/golemfoundation/octant-v2-core/commit/b4ae9b210fa3f08f0715125aa063c8adb0b48115))
* block setEarningPowerCalculator during active reward periods ([0363976](https://github.com/golemfoundation/octant-v2-core/commit/0363976f8aa158c5d79255fce5ea0ceb797929ef))
* create AaveV3CompounderStrategy ([d7c4c33](https://github.com/golemfoundation/octant-v2-core/commit/d7c4c330f84dfc26061bc5e7357f45f429589675))
* create AaveV3StrategyFactory ([006e4dd](https://github.com/golemfoundation/octant-v2-core/commit/006e4ddd2247000b2fa4da9b347f8e353926528d))
* create GenericERC4626Strategy ([2c17f68](https://github.com/golemfoundation/octant-v2-core/commit/2c17f68abc50641ade715ca7a4376b1ab8ff20bb))
* create GenericERC4626StrategyFactory ([61cd03d](https://github.com/golemfoundation/octant-v2-core/commit/61cd03d76a84de3126b714f94a4747d1526a5168))
* create KeeperBotGuard ([c2cc38e](https://github.com/golemfoundation/octant-v2-core/commit/c2cc38e93e0443ab624fb90b11a620c17b6f2e42))
* create SparkStrategy ([76d1ae1](https://github.com/golemfoundation/octant-v2-core/commit/76d1ae1b8b92aa763716d533a06a2eb1d28b4fc3))
* create SparkStrategyFactory ([63bc2fa](https://github.com/golemfoundation/octant-v2-core/commit/63bc2faf43d7a943184833617ab01b840fa266e9))
* create verif scripts for Morpho and Sky strats ([5efbd22](https://github.com/golemfoundation/octant-v2-core/commit/5efbd22efb38c808faca5a6e88df4c7dc285dfaa))
* create WhitelistedYieldDonatingTokenizedStrategy ([aa286fc](https://github.com/golemfoundation/octant-v2-core/commit/aa286fc3ffe2cb02876118aec8b58289e828d7f7))
* create WhitelistedYieldSkimmingTokenizedStrategy ([fddb3af](https://github.com/golemfoundation/octant-v2-core/commit/fddb3afd3570aeef8dc8cd774ce3599151e7538c))
* **deploy:** add deterministic deployment scripts for AddressSet and RegenStakerFactory ([100f221](https://github.com/golemfoundation/octant-v2-core/commit/100f221199cc6b72acc3b9deeca2a1411129736c))
* **factories:** unify computeStrategyAddress ABI with vault/asset pa… ([#358](https://github.com/golemfoundation/octant-v2-core/issues/358)) ([271770c](https://github.com/golemfoundation/octant-v2-core/commit/271770c7c06e0f776a0e0877c10e496aaf787be3))
* **factory:** add salt-based deployment functions to PaymentSplitterFactory ([22a6dd8](https://github.com/golemfoundation/octant-v2-core/commit/22a6dd89e37f7727857f7469f892ae2c2edcf5f2))
* **factory:** add salt-based PaymentSplitter deployment ([b1ab9c3](https://github.com/golemfoundation/octant-v2-core/commit/b1ab9c3f99e9a06536e5feba5aee86c0ab46baaf))
* improve safe deploy scripts and track factory deployments ([6e38887](https://github.com/golemfoundation/octant-v2-core/commit/6e3888715e2fd14dbec379647ea89269a4cb7183))
* move staker allowset/blockset to post-construction assignment ([90a6b5b](https://github.com/golemfoundation/octant-v2-core/commit/90a6b5bda152b5db8c28a2d8104f2e0dcc91dde6))
* **nouns:** add getProposalTransactions() with governance flow test ([5a9346d](https://github.com/golemfoundation/octant-v2-core/commit/5a9346d3110994fa8fece2973e13dcb87864b7df))
* **nouns:** convert TARGET_ETH_VALUE to wstETH at current exchange rate ([99c90ee](https://github.com/golemfoundation/octant-v2-core/commit/99c90eefad38f9d8213e054cf1f7b14d2c9279a8))
* octant qf mechanism deploymment unit tests & refactor factory address prediction hashing. ([b1be99b](https://github.com/golemfoundation/octant-v2-core/commit/b1be99b683ca5be0f0a289c3d8dcdd6a0e90f631))
* parameterize DeployProtocol with env vars for Safe, salts, and addresses ([c5b6b0b](https://github.com/golemfoundation/octant-v2-core/commit/c5b6b0b7e124a7b0a4051862139f2c048f64d143))
* pass symbol to strategies ([351280e](https://github.com/golemfoundation/octant-v2-core/commit/351280e41bd09ba61eb7f1d0523f39e76858b55b))
* populate expected addresses and enforce strict deployment assertions ([cc0c83a](https://github.com/golemfoundation/octant-v2-core/commit/cc0c83a621dcef8e8b4e56e05e92f13a8cfd9232))
* retire Dragon Kontrol tests, add YieldSkimming and ERC4626 proofs ([dfcce78](https://github.com/golemfoundation/octant-v2-core/commit/dfcce78f2ad21196bd1ad77ea7163391189784c2))
* retire DragonTokenizedStrategy and related unused contracts ([c26a8e2](https://github.com/golemfoundation/octant-v2-core/commit/c26a8e2278eb32d11f16aecc7d921a394beafb93))
* **shutter:** add Shutter DAO proposal infrastructure with V1 contracts ([80a39dc](https://github.com/golemfoundation/octant-v2-core/commit/80a39dc2c753dd038254cfe7055f226dce876734))
* update allocation factory to include octant qf mechanism deployment ([8173343](https://github.com/golemfoundation/octant-v2-core/commit/81733434666918f55964eb83e227778ffa239991))


### Bug Fixes

* _buildDomainSeparator in TokenizedStrategy ([b624c69](https://github.com/golemfoundation/octant-v2-core/commit/b624c690dd5bf297888ab26abeeb76edfa8fdc9a))
* address Copilot review comments on ERC4626BaseTest ([0826311](https://github.com/golemfoundation/octant-v2-core/commit/08263118e588be1723d235e758af622f923138bc))
* address PR review comments on Kontrol proofs ([11fe8e9](https://github.com/golemfoundation/octant-v2-core/commit/11fe8e9846175fa6f8359b0c21d9ae0c41a6a087))
* adjust formatting in the allocation mechanism factory test. ([ea85e79](https://github.com/golemfoundation/octant-v2-core/commit/ea85e79b94bf89700cbe26e83080cd227c0ac685))
* align Kontrol YS tests with _isVaultInsolvent definition ([17356b9](https://github.com/golemfoundation/octant-v2-core/commit/17356b9f671b9996f89130360c07c4a95b7921e4))
* assert deployment results before Safe tx submission ([7ceea7b](https://github.com/golemfoundation/octant-v2-core/commit/7ceea7ba1c943e6804e59e9c64da520024e6a2ee))
* check pool liquidity in availableWithdrawLimit ([6119638](https://github.com/golemfoundation/octant-v2-core/commit/611963884df9ab4c5d2f6fa42a36b234e9e725cc))
* **ci:** increase Kontrol prove workers to 4 and timeout to 240 min ([b9ca02f](https://github.com/golemfoundation/octant-v2-core/commit/b9ca02f6554aef780b89435e287476df57e5ea48))
* **ci:** remove conflicting typing.py backport in Kontrol container ([0bb2fb8](https://github.com/golemfoundation/octant-v2-core/commit/0bb2fb8c2014110e7c3df0ee9739acb28ecb2484))
* **ci:** run Kontrol container as root for workspace permissions ([6e3d708](https://github.com/golemfoundation/octant-v2-core/commit/6e3d708cc9ac1c4bf10d9e907884efb64d5aa1ac))
* **ci:** set PYTHONPATH for Kontrol modules when running as root ([e1d351d](https://github.com/golemfoundation/octant-v2-core/commit/e1d351d96c16843f79b4f02f259b13337b1b4718))
* **ci:** set XDG_CACHE_HOME for kdist artifact lookup in Kontrol container ([43bdc23](https://github.com/golemfoundation/octant-v2-core/commit/43bdc2314a76d21d3348ed32b6f70a2cd260e62b))
* **ci:** set XDG_DATA_HOME for K framework build artifacts in Kontrol container ([e610120](https://github.com/golemfoundation/octant-v2-core/commit/e6101209210b9782d686e79e0826a64e5b003002))
* **ci:** use correct Docker Hub image for Kontrol CI job ([edb0a74](https://github.com/golemfoundation/octant-v2-core/commit/edb0a74cb09ed4146a88ac3d991303566e1c49de))
* code formatting ([55623b2](https://github.com/golemfoundation/octant-v2-core/commit/55623b2437ebd37675d6518651b214a791602834))
* coverage issues ([a4e365c](https://github.com/golemfoundation/octant-v2-core/commit/a4e365c1835e6fffe84ec432b344d2da23ec647c))
* deployed sepolia address checksum ([b529011](https://github.com/golemfoundation/octant-v2-core/commit/b529011c32a0af6794d772191174ba9de51ee844))
* derive aToken from pool registry instead of constructor param ([f44c91b](https://github.com/golemfoundation/octant-v2-core/commit/f44c91b98efc8e25101edc8b6d46d3b6d4b72062))
* disable warnings on forge doc ([b630ad6](https://github.com/golemfoundation/octant-v2-core/commit/b630ad60f2102458485d4814e086c1124cbd6cf6))
* **docs:** update plan.html section heading to reflect parameter-based workflow ([7fe4c5f](https://github.com/golemfoundation/octant-v2-core/commit/7fe4c5f1eb43af32a7bccf718360a9629d320774))
* fallback permit name hash ([d31f58b](https://github.com/golemfoundation/octant-v2-core/commit/d31f58bc2aa75a8ab39de4ee4580b31eece3c257))
* fallback permit name hash ([4ba6dea](https://github.com/golemfoundation/octant-v2-core/commit/4ba6deacca1ca1a8e27900550717dc311cb48456))
* guard max deposit/mint at zero rate ([ba77df5](https://github.com/golemfoundation/octant-v2-core/commit/ba77df52eab139369ff6e3595d1b25e48cf7d04d))
* improve transfer solvency checks ([c956b68](https://github.com/golemfoundation/octant-v2-core/commit/c956b68be510c183e71ca117cb13cb91b8dc6fa3))
* l23 add _requireDragonSolvency to finalizeDragonRouterChange ([f5aa567](https://github.com/golemfoundation/octant-v2-core/commit/f5aa5674b3e404dba508615e037276f053c7b4fd))
* m-18 update _isVaultInsolvent ([f16c796](https://github.com/golemfoundation/octant-v2-core/commit/f16c79651e4d6311c3523779ca9220656ff03119))
* mark _loadSaltOverride as view ([#351](https://github.com/golemfoundation/octant-v2-core/issues/351)) ([b63d8d0](https://github.com/golemfoundation/octant-v2-core/commit/b63d8d0940634008598726fec866ec2e464dbe5b))
* overflow bug in ERC4626Strategy ([a65b031](https://github.com/golemfoundation/octant-v2-core/commit/a65b0315ea0daada42d6b74e3db792de570fb0ba))
* overflow guard in YearnV3 and MorphoCompounder strategies ([3149c13](https://github.com/golemfoundation/octant-v2-core/commit/3149c135b41af30ae015cf6e724e18e806548a2b))
* prevent Foundry vm.ffi hex-decoding of timestamp output ([520e040](https://github.com/golemfoundation/octant-v2-core/commit/520e040fdf5b4db5a5c4f5ea626ec6d0d4d9facd))
* r-33 remove duplicate functions ([6b801d0](https://github.com/golemfoundation/octant-v2-core/commit/6b801d09a88653f8475e1d675d569a0d87179c8b))
* resolve rebase conflicts and compilation errors after rebasing onto develop ([661c2d6](https://github.com/golemfoundation/octant-v2-core/commit/661c2d645d3187efa942623983148ad87f698a40))
* restore Management to Treasury, fix Transaction 2 formatting ([f049325](https://github.com/golemfoundation/octant-v2-core/commit/f049325aa3a7ba50551a4db6e5ec2d392801c557))
* **shutter:** address audit findings and Decent UI compatibility ([d406539](https://github.com/golemfoundation/octant-v2-core/commit/d4065397d0deb3f874cd28bd476ae374c9af1f42))
* sync plan.html discrepancies with README.md ([40f1c3d](https://github.com/golemfoundation/octant-v2-core/commit/40f1c3d8df3aa83e59cf8d48c533870facc9d293))
* **test:** change condition from <= to < ([84725f5](https://github.com/golemfoundation/octant-v2-core/commit/84725f591bf80bd90d1703abfcb39232f254dbb5))
* **test:** pin fork block for SkyCompounder tests ([19cf836](https://github.com/golemfoundation/octant-v2-core/commit/19cf8360d292c71b52ccb15170fd1cade56c43da))
* **tokenized-strategy:** align permit domain ([7357855](https://github.com/golemfoundation/octant-v2-core/commit/7357855ebf015aba67682c60be671135dca902d2))
* **tokenized-strategy:** lock name for permit domain ([f1e9563](https://github.com/golemfoundation/octant-v2-core/commit/f1e956362a5af03fe06b4a87d702725bec71ca59))
* Transaction 4 heading level h4 to h3 ([f639e83](https://github.com/golemfoundation/octant-v2-core/commit/f639e83f3d8897a65ae8b3a1c5bda49821dae42b))
* update eth safe api url ([#347](https://github.com/golemfoundation/octant-v2-core/issues/347)) ([bf7d0f9](https://github.com/golemfoundation/octant-v2-core/commit/bf7d0f910473de0bc01c14ea1ae93fcd57ad25c8))
* update imports and tests after zodiac-core retirement rebase ([1a17ed7](https://github.com/golemfoundation/octant-v2-core/commit/1a17ed725bdc8019037d2b08deca74e21215c6ec))
* use Ceil rounding for loss-to-shares conversion in TestTokenizedStrategy ([1aa7692](https://github.com/golemfoundation/octant-v2-core/commit/1aa76928ef14416fce73232a77cf59c3acaa9511))
* use Floor rounding for dragon loss share burn (OSU-1492) ([3b04659](https://github.com/golemfoundation/octant-v2-core/commit/3b04659c97ca9eb33c5ae142cd6f04fc84764ad6))
* **vault:** align permit domain ([5d40a41](https://github.com/golemfoundation/octant-v2-core/commit/5d40a412e120a973f230ffc0a2765fba86937065))
* **vault:** lock name and cache permit domain ([d23667a](https://github.com/golemfoundation/octant-v2-core/commit/d23667a597c2f71a772d5af79af996ab7beb1b0e))
* **yieldskimming:** block finalize during insolvency ([4022739](https://github.com/golemfoundation/octant-v2-core/commit/4022739687ddf1bd66bbb9844ef74b4857ffb83f))
* **zodiac-core:** allow max deposit and mint ([2a4f14b](https://github.com/golemfoundation/octant-v2-core/commit/2a4f14bc4647ba748734c7b4fb8442bec3aa3fa9))

## [1.0.0-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.9.0-develop.0...v1.0.0-develop.0) (2026-01-05)


### ⚠ BREAKING CHANGES

* **shutter:** fix payment splitter revert, add robust delegation tests, and update gas limits per EIP-7825

### Features

* **shutter:** add calldata generator script for DAO proposal ([c846167](https://github.com/golemfoundation/octant-v2-core/commit/c8461671f1abb5218a8fea3c23c22309c2387d60))
* **shutter:** add Shutter DAO 0x36 integration guide and tests ([d57d583](https://github.com/golemfoundation/octant-v2-core/commit/d57d5830d4ed524ab3f101d97c6dd6f201c52b6d))
* **shutter:** add test mode to calldata generator script ([7fedffe](https://github.com/golemfoundation/octant-v2-core/commit/7fedffedd03f67b0eacb39ae46f20731516eff9c))
* **shutter:** batch all 4 ops using CREATE2 address precomputation ([17875fe](https://github.com/golemfoundation/octant-v2-core/commit/17875fe167989a212b131b6c52d2be5d643bcb49))
* **shutter:** set PaymentSplitter Factory mainnet address ([05697e5](https://github.com/golemfoundation/octant-v2-core/commit/05697e59285f5bba1beb4999c9726ee7d7ec2557))


### Bug Fixes

* **shutter:** align test execution path with script and update docs ([4237547](https://github.com/golemfoundation/octant-v2-core/commit/423754783372a77e45677b415d2173cb6906bef5))
* **shutter:** align tests with source of truth using factory deployment ([d9d1287](https://github.com/golemfoundation/octant-v2-core/commit/d9d12870ee0658b3b0975bfa6be702d97c35af0e))
* **shutter:** capture strategy address from return value instead of CREATE2 prediction ([6b8d099](https://github.com/golemfoundation/octant-v2-core/commit/6b8d0998de229348ba9bc45664c59db8faddf019))
* **shutter:** delegatecall multisend in integration tests ([ddf9adf](https://github.com/golemfoundation/octant-v2-core/commit/ddf9adfe78920aa400db35b7727052dbebde504f))
* **shutter:** use Treasury as roleManager per documentation ([8588007](https://github.com/golemfoundation/octant-v2-core/commit/85880071a3cd4e26a33624a90d4c01a8203e73aa))
* **test:** remove unused import to satisfy deny_warnings ([f0c8e02](https://github.com/golemfoundation/octant-v2-core/commit/f0c8e024513b0331cbaf35638c3ad8a6c5279b52))
* **test:** remove zero-share payee from PaymentSplitter setup to prevent revert ([78f3c5b](https://github.com/golemfoundation/octant-v2-core/commit/78f3c5b2a536a723fc7fcd73377731ecbb8d3a05))
* **test:** resolve compilation errors and stack depth issues ([ddf38af](https://github.com/golemfoundation/octant-v2-core/commit/ddf38af8582a09a0720fc1d1ebeec9b949bafa6e))
* **test:** use ERC1967Proxy for PaymentSplitter deployment ([9d96b82](https://github.com/golemfoundation/octant-v2-core/commit/9d96b82ff9fc29ccd24421922fe7963855fdf803))


### Documentation

* **shutter:** fix payment splitter revert, add robust delegation tests, and update gas limits per EIP-7825 ([8d328eb](https://github.com/golemfoundation/octant-v2-core/commit/8d328eb5d9dbb0818856024b5e91fb1825e040b3))

## [0.9.0-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.8.0-develop.0...v0.9.0-develop.0) (2025-12-05)


### Features

* add centralized network-aware address registry ([3901fa4](https://github.com/golemfoundation/octant-v2-core/commit/3901fa4264fb32541ed9de14ff64d41a14c231de))
* add deployment logic for all contracts ([401e1b8](https://github.com/golemfoundation/octant-v2-core/commit/401e1b817f858bc59b7b0b5adbfb358a00f7c130))


### Bug Fixes

* **scripts:** patch the multisend contract addres for safe tx batching ([e96904e](https://github.com/golemfoundation/octant-v2-core/commit/e96904e8d98bf56905d3b1b29a6976c82cceb85c))

## [0.8.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.1.2...v0.8.0) (2025-11-20)


### Features

* add cancelRegenGovernance ([45c936b](https://github.com/golemfoundation/octant-v2-core/commit/45c936b00f587cfa6cccd6f5959a801f9c6ba9ac))
* add cancelRegenGovernance to IMultistrategyLockedVault ([b2e535e](https://github.com/golemfoundation/octant-v2-core/commit/b2e535efca4e461aec506b9f0122fea93e08152c))
* add ERC1271 support to TAM (Cantina 125) ([#287](https://github.com/golemfoundation/octant-v2-core/issues/287)) ([c0ca82e](https://github.com/golemfoundation/octant-v2-core/commit/c0ca82eb22bebb416c9dc992679daebcaffa74bb))
* **regen:** enable withdrawals when paused for user protection ([#307](https://github.com/golemfoundation/octant-v2-core/issues/307)) ([456b7a4](https://github.com/golemfoundation/octant-v2-core/commit/456b7a43cb81c70d11e4a15d3dab21535179cd7d))


### Bug Fixes

* add maxLoss parameters to Morpho freeFund (Cantina 336) ([#264](https://github.com/golemfoundation/octant-v2-core/issues/264)) ([b3c8fb3](https://github.com/golemfoundation/octant-v2-core/commit/b3c8fb3928a8a9fa9dee46830b8e0c0702de2eb3))
* **cantina-259:** disable delegation in RegenStakerWithoutDelegateSurrogateVotes ([#291](https://github.com/golemfoundation/octant-v2-core/issues/291)) ([651d96b](https://github.com/golemfoundation/octant-v2-core/commit/651d96bb34a92ff42d10ccd4243295083edfff54)), closes [#259](https://github.com/golemfoundation/octant-v2-core/issues/259)
* expose reward schedule metadata (Cantina 359) ([#300](https://github.com/golemfoundation/octant-v2-core/issues/300)) ([7602b06](https://github.com/golemfoundation/octant-v2-core/commit/7602b069d9b5df64e001265ff09768c62313f0d6))
* **factory:** use Clones library for deterministic deploys ([e05ebfd](https://github.com/golemfoundation/octant-v2-core/commit/e05ebfdf81ad04da418ed9e6c6d4cac012101e2b))
* **guards:** initialize ownable state in anti loophole guard ([12aa730](https://github.com/golemfoundation/octant-v2-core/commit/12aa730d0f3389229471428fda4dd3bc5d6e67e8))
* **multistrategy:** add two-step governance transfer ([03487b1](https://github.com/golemfoundation/octant-v2-core/commit/03487b1d5f8871b46e0fe62c5f1015077955a852))
* **multistrategy:** enforce grace window for cooldown cancellation ([8b03ba3](https://github.com/golemfoundation/octant-v2-core/commit/8b03ba36d6dc7f5c57d934d9a76261fab74005ca))
* pause regen rewards when pool idle (Cantina 283 Option 1) ([#280](https://github.com/golemfoundation/octant-v2-core/issues/280)) ([0ef749f](https://github.com/golemfoundation/octant-v2-core/commit/0ef749f495a978d075df6813b1121591dcb79369))
* **permits:** leverage OpenZeppelin ECDSA helper ([534f959](https://github.com/golemfoundation/octant-v2-core/commit/534f959857c44f1b27a89250d2b474818b6c713d))
* prevent DoS in MultiStrategyVault when YieldSkimming strategy is insolvent ([96ebf6d](https://github.com/golemfoundation/octant-v2-core/commit/96ebf6d9a2ef41ed0cc02c2bfb8fad6284dac770))
* **regen:** allow zero-deposit signup contributions ([b2e5b50](https://github.com/golemfoundation/octant-v2-core/commit/b2e5b50b9d716059283d6f00772c5f5e5afec446))
* **regen:** eliminate fee collection to prevent dust accumulation and simplify code ([#283](https://github.com/golemfoundation/octant-v2-core/issues/283)) ([eb1d444](https://github.com/golemfoundation/octant-v2-core/commit/eb1d444579e3804d8c01a15989aa96d7a6f30ceb)), closes [#564](https://github.com/golemfoundation/octant-v2-core/issues/564) [/github.com/golemfoundation/octant-v2-core/pull/283#discussion_r2423688515](https://github.com/golemfoundation//github.com/golemfoundation/octant-v2-core/pull/283/issues/discussion_r2423688515)
* **regen:** pause bump earning power when halted ([466fdb6](https://github.com/golemfoundation/octant-v2-core/commit/466fdb6a322f6497303543f3649e61fb1f6a2251))
* **yield-donating:** emit donation events in shares ([62b7132](https://github.com/golemfoundation/octant-v2-core/commit/62b7132bca7ac7b27024c271d052502b6e05b06c))

## [0.7.2-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.7.1-develop.0...v0.7.2-develop.0) (2025-09-25)

## [0.7.1-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.7.0-develop.0...v0.7.1-develop.0) (2025-09-24)


### Bug Fixes

* **natspec:** revert to unnamed returns in BaseStrategy and adjust [@return](https://github.com/return) tags accordingly ([40b2c0b](https://github.com/golemfoundation/octant-v2-core/commit/40b2c0ba785c1e648193342a0458e631b07dc20a))

## [0.7.0-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.6.0-develop.0...v0.7.0-develop.0) (2025-09-09)


### Features

* add event emissions for health check state changes ([60873e5](https://github.com/golemfoundation/octant-v2-core/commit/60873e5310749293cd6e5bbed41426a01000d1c6))
* add Tallying proposal state for post-voting period ([2a7fac9](https://github.com/golemfoundation/octant-v2-core/commit/2a7fac9a7a90ad1773bab1a27dd59343392985a4))
* **allocation:** enhance custom distribution with asset tracking ([28809f6](https://github.com/golemfoundation/octant-v2-core/commit/28809f68bdeabec0f68d99d44df64217edf72e0e))
* combine QuadraticVotingMechanism and TokenizedAllocationMechanism abis ([61904a5](https://github.com/golemfoundation/octant-v2-core/commit/61904a547b90de258e3fb864f29b5d3ea865e9de))
* combine strategy proxy abis ([84f5759](https://github.com/golemfoundation/octant-v2-core/commit/84f5759f2a06775a802678ac35f4189645c6035f))
* **factories:** add deposit during loss parameter to strategy factories ([97cf37f](https://github.com/golemfoundation/octant-v2-core/commit/97cf37ffc91b62dbe3aeafc9a98a155b9120bd25))
* **factories:** implement secure deterministic deployment to prevent front-running ([2295b18](https://github.com/golemfoundation/octant-v2-core/commit/2295b18670c1f950bfd27c3cf8081950cf3f7871))
* **factories:** implement secure deterministic deployment to prevent front-running ([16f0aa3](https://github.com/golemfoundation/octant-v2-core/commit/16f0aa3b38b07b7ee2482f0610f9b0fac23d49a0))
* **healthcheck:** add events for health check state changes ([021060c](https://github.com/golemfoundation/octant-v2-core/commit/021060cfadeed9ac76cd4345de973da7b22dc417))
* make pricePerShare public and add robust claiming logic ([6c6ea9c](https://github.com/golemfoundation/octant-v2-core/commit/6c6ea9cba32f9db5e1381783115b32ab28d1372d))
* **mechanisms:** enable multiple signups for quadratic funding ([82e2dd8](https://github.com/golemfoundation/octant-v2-core/commit/82e2dd848bde91b2972606d84dcef62c1eb6f6bd))
* REG-022 add reverse surrogate lookup capability ([#49](https://github.com/golemfoundation/octant-v2-core/issues/49)) ([72a8f76](https://github.com/golemfoundation/octant-v2-core/commit/72a8f769ce90c681786f6055e4bcc0ab10a5c607))
* **security:** add recipient verification to prevent reorganization attacks ([d0cf578](https://github.com/golemfoundation/octant-v2-core/commit/d0cf57812feb40ddac884da9e77d1129284d034d))
* **strategy:** add configurable MEV protection to swaps ([efac32b](https://github.com/golemfoundation/octant-v2-core/commit/efac32bbb0695f25e9f3a15453d9366efaacff2d))
* **strategy:** add donation tracking events and OpenZeppelin Math ([02c88fa](https://github.com/golemfoundation/octant-v2-core/commit/02c88fa98de72710d7da7b5a08f307d541d9ad76))
* **strategy:** add getCurrentRateRay method for standardized exchange rate conversion ([778ceee](https://github.com/golemfoundation/octant-v2-core/commit/778ceee1e780e231d0d76a2e706648bd3ec0bfc4))
* **strategy:** add granular maxLoss control to redeem function ([c4a18c7](https://github.com/golemfoundation/octant-v2-core/commit/c4a18c778e514f8227cb38294533e159e450e728))
* **strategy:** introduce value debt tracking and insolvency protection ([301ecfa](https://github.com/golemfoundation/octant-v2-core/commit/301ecfa9403d4ce7ca59a4077e7edf9b37d3203d))
* **vault:** enhance rage quit functionality with granular controls ([806fbd0](https://github.com/golemfoundation/octant-v2-core/commit/806fbd09982b2f866c97d2159a690b463e3d938e))
* **vault:** implement two-step cooldown period change mechanism ([3291d9f](https://github.com/golemfoundation/octant-v2-core/commit/3291d9f6f9c36103fac501451f6f417c1aa3a944))


### Bug Fixes

* add driprates to ArrayLengthsMismatch ([f6f3dde](https://github.com/golemfoundation/octant-v2-core/commit/f6f3ddebdb9dc0ee69c54b4c9f1813a61cbb6e83))
* add missing nonReentrant to notifyRewardAmount ([84ea3a9](https://github.com/golemfoundation/octant-v2-core/commit/84ea3a9ead237a88615ebe2b002e3fe617423573))
* add to ci release ([8046c10](https://github.com/golemfoundation/octant-v2-core/commit/8046c10c4ffa802145b9db373d50eab7b2b73912))
* adjust available deposit limit calculation to account for idle balance ([bd83b98](https://github.com/golemfoundation/octant-v2-core/commit/bd83b9813f38a15a483746ef663b4c9a834dc044))
* **allocation:** handle token decimal conversions for asset-share scaling ([b1bb718](https://github.com/golemfoundation/octant-v2-core/commit/b1bb718127f69bda05e69df2321240354e87ab3d))
* **allowance:** atomically update dripRatePerDay and lastBookedAtInSeconds to prevent timing issues ([a72fa9e](https://github.com/golemfoundation/octant-v2-core/commit/a72fa9ef231db5ba0da85ab9cccb524ee24ca999))
* **factories:** post-implementation improvements and fixes ([7147164](https://github.com/golemfoundation/octant-v2-core/commit/71471646cd812cb5f3672d043bdd6d119822a25b))
* install forge deps in docker container ([eb1e750](https://github.com/golemfoundation/octant-v2-core/commit/eb1e7501c41aa4196af494bb2077296df3585615))
* install soldeer deps in release ([b0f3a5e](https://github.com/golemfoundation/octant-v2-core/commit/b0f3a5ea6e2f2568e2369839f0ece1bc581b12bb))
* LIN-002: Remove redundant conditional return statement ([e2ea11f](https://github.com/golemfoundation/octant-v2-core/commit/e2ea11fda73e240722da43a75d136a75300b08ee))
* LIN-003: Use abi.encodeCall for better type safety ([34b3fbc](https://github.com/golemfoundation/octant-v2-core/commit/34b3fbcbd428fe71723de81b1aa193c50bdcf280))
* prevent dragon router transfers to self ([dba8398](https://github.com/golemfoundation/octant-v2-core/commit/dba83982d3cf6edbcef4fe828cb05bf8bf2b5376))
* prevent registration of zero address in allocation mechanism ([7e9f658](https://github.com/golemfoundation/octant-v2-core/commit/7e9f6582971e3fe26288a1c64171b8f0c760a1de))
* **qv:** normalize token decimals in alpha calculation ([7d405ea](https://github.com/golemfoundation/octant-v2-core/commit/7d405ea3a713f15956fd0b20e9cd776602b0d862))
* **qv:** return zero funding for cancelled proposals ([874c506](https://github.com/golemfoundation/octant-v2-core/commit/874c50628c65fcb011c81bc35f18417e9cddfb34))
* rebalance debt on dragon transfers inwards ([d9c6573](https://github.com/golemfoundation/octant-v2-core/commit/d9c65733897e5c72aaa30d8ff8260b4aa088f2c9))
* **regen:** enforce owner whitelist in compoundRewards and add tests ([#51](https://github.com/golemfoundation/octant-v2-core/issues/51)) ([44637ca](https://github.com/golemfoundation/octant-v2-core/commit/44637ca835d0a00ab9e4ddaf2cf2285b400e88db))
* **regen:** REG-006 (OSU-920) add governance protection to setMaxBumpTip ([#30](https://github.com/golemfoundation/octant-v2-core/issues/30)) ([99b1ff9](https://github.com/golemfoundation/octant-v2-core/commit/99b1ff9ea3c35bdc127a292d77469aeeccd222c7))
* **regen:** REG-013 (OSU-946) unify reward period boundary checks for consistency ([fb3686c](https://github.com/golemfoundation/octant-v2-core/commit/fb3686c221358b0be0668abe8efe60aa366c0cb5))
* **regen:** REG-014 (OSU-947) align balance check with original Staker ([dc2aad3](https://github.com/golemfoundation/octant-v2-core/commit/dc2aad3590ce26dd074aa4241f7373f6684c059c))
* **regen:** REG-015 (OSU-948) zero amount handling consistency ([2c2bcc6](https://github.com/golemfoundation/octant-v2-core/commit/2c2bcc68232a68ebb2c0c6d01d1f7b66a92f92ba))
* **regen:** REG-016 (OSU-949) prevent fee collection on zero benefit scenarios ([#31](https://github.com/golemfoundation/octant-v2-core/issues/31)) ([0051429](https://github.com/golemfoundation/octant-v2-core/commit/005142950e270572ac21f18fbc9562fdcca48026))
* **regen:** REG-017 (OSU-950) standardize compound event emission patterns ([af38193](https://github.com/golemfoundation/octant-v2-core/commit/af381939cad136d1af44e409c61db0c396774327))
* **regen:** REG-018 align surrogate transfer patterns via unified hook ([#12](https://github.com/golemfoundation/octant-v2-core/issues/12)) ([081fadc](https://github.com/golemfoundation/octant-v2-core/commit/081fadcffe72c7a5e57975e2321b61dbe6dd4b3d))
* **regen:** REG-020 (OSU-953) remove transfer skip logic for ERC20 consistency ([232d60e](https://github.com/golemfoundation/octant-v2-core/commit/232d60e98fcb865fbbaa4353f509769422cda5ba))
* **regen:** REG-023 (OSU-956) Same-token protection with security improvements ([d68a69c](https://github.com/golemfoundation/octant-v2-core/commit/d68a69ccc3d0a6336cba8c09e86cb84c028e7e17))
* **regen:** REG-024 add missing event emissions and prevent whitelist conflicts ([#28](https://github.com/golemfoundation/octant-v2-core/issues/28)) ([3269764](https://github.com/golemfoundation/octant-v2-core/commit/3269764d257a4c78b141607b6d1d0a5a4774eab1))
* **regen:** REG-029 (OSU-983) add reentrancy protection to bumpEarningPower ([#33](https://github.com/golemfoundation/octant-v2-core/issues/33)) ([1a096a0](https://github.com/golemfoundation/octant-v2-core/commit/1a096a0250a3ab7fa35bf42167560dc2838ab71e))
* **regen:** REG-036 account for _remainingReward and totalUnspentRewards in balance validation ([5cfbcf0](https://github.com/golemfoundation/octant-v2-core/commit/5cfbcf09d02c84b3b55f7f3ae3fd4c3853b168e4))
* **regen:** REG-036 add asset validation in contribute to prevent token mismatch ([#62](https://github.com/golemfoundation/octant-v2-core/issues/62)) ([ba3c5e5](https://github.com/golemfoundation/octant-v2-core/commit/ba3c5e5b826d1d35ec77a8d95b8f53e66868f352)), closes [#39](https://github.com/golemfoundation/octant-v2-core/issues/39)
* remove foreign command from postinstall script ([0724b47](https://github.com/golemfoundation/octant-v2-core/commit/0724b47b1c1c92ef709c37eb8f646e23c1d63181))
* remove unecessary allowance ([a66c09d](https://github.com/golemfoundation/octant-v2-core/commit/a66c09dbe2adf9274c931a6fe63848285f02019f))
* return zero for preview redeem outside redemption period ([dc8a2f1](https://github.com/golemfoundation/octant-v2-core/commit/dc8a2f1124b42095d6a2fc239e4ca802c7cfa42b))
* **security:** add reinitialization protection ([f370c1f](https://github.com/golemfoundation/octant-v2-core/commit/f370c1fc3c027910eac64def375b611a11d5ef14))
* **security:** clear unused approvals in UniswapV3Swapperrefactor ([0745cf7](https://github.com/golemfoundation/octant-v2-core/commit/0745cf7e1a2343c486e61313ea2b3c98a85066f3))
* **security:** OSU-1030 TRST-R-25 add whitelist validation to prevent arbitrary external calls ([#66](https://github.com/golemfoundation/octant-v2-core/issues/66)) ([8b03adc](https://github.com/golemfoundation/octant-v2-core/commit/8b03adcd9099f1db30654723d7d72d66e49065a5))
* **strategy:** include asset balance in total assets calculation ([68fff58](https://github.com/golemfoundation/octant-v2-core/commit/68fff5879fe624a99197164e6d9511b164c9f7fd))
* **strategy:** include idle assets in total asset calculation ([774a354](https://github.com/golemfoundation/octant-v2-core/commit/774a354d5b01912b9eae5ce63ea6b081b7ab4724))
* **strategy:** prevent deployment of funds when staking is paused ([37112f9](https://github.com/golemfoundation/octant-v2-core/commit/37112f9815cd46cb21eeedd85038e97980a6101d))
* unify StrategyDeploy event emission to use _management across all factories ([0e612cb](https://github.com/golemfoundation/octant-v2-core/commit/0e612cb47043ad229ad79d84ff51f87c1aa1d2ba))
* **vault:** add reentrancy guard to processReport ([666654e](https://github.com/golemfoundation/octant-v2-core/commit/666654e84e7778e344b2a5526337d2c627e616d9))
* **vault:** prevent vault from adding itself as strategy ([5c2406e](https://github.com/golemfoundation/octant-v2-core/commit/5c2406ea1a436d37fb0c7f805640494eccfc6ef9))
* **yield-skimming:** migrate debt accounting on dragon router change ([a5401a0](https://github.com/golemfoundation/octant-v2-core/commit/a5401a0d814d09ed71f9c931d1f5c435e9786bd2))


### Reverts

* Revert "fix(security): prevent whitelist circumvention via delegation" ([b56e7e6](https://github.com/golemfoundation/octant-v2-core/commit/b56e7e6078f7954ecf4de7ac3310cf9d0d27e614))

## [0.6.0-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.5.11-develop.0...v0.6.0-develop.0) (2025-07-16)


### Features

* add missing admin and user functions to RegenStakerWithoutDelegateSurrogateVotes ([1469e8a](https://github.com/golemfoundation/octant-v2-core/commit/1469e8a103e20c029174b1edab735aefd2751f2a))
* add missing contribute function to RegenStakerWithoutDelegateSurrogateVotes ([1b239d1](https://github.com/golemfoundation/octant-v2-core/commit/1b239d141b33f17bd5258b1bc3e221a9ab9e70c1))
* **allocation:** add token sweep functionality after grace period ([057681f](https://github.com/golemfoundation/octant-v2-core/commit/057681fdf8bd216ab57f1029d1e76029cee61f77))
* implement two-step ownership transfer to prevent permanent lock ([a7624a2](https://github.com/golemfoundation/octant-v2-core/commit/a7624a2a5e16d47ab3825ceef5d85cc7ddfdc7ed))
* improve RegenStaker contribute function security and API ([4929e06](https://github.com/golemfoundation/octant-v2-core/commit/4929e066a2df03e6b7f441f20eb2bf33d4c149f1))
* introduce signUpOnBehalf ([666e9e6](https://github.com/golemfoundation/octant-v2-core/commit/666e9e65bf0115a4d7733b12d3f0b2e757715173))
* **qf:** add optimal alpha calculation for 1:1 share ratio ([bc4d340](https://github.com/golemfoundation/octant-v2-core/commit/bc4d34012b9fbde492e8affddc05bcb0cb8fb936))
* **qf:** implement whitelist-controlled quadratic funding mechanism ([3b845e3](https://github.com/golemfoundation/octant-v2-core/commit/3b845e3404523d792d1149412ac53d832d4c4d88))
* **strategy:** add optimal alpha calculation for quadratic funding ([a17ee53](https://github.com/golemfoundation/octant-v2-core/commit/a17ee53ce42ce6b5bf1e710d517876499695e544))
* **voting:** restrict proposal creation to keeper/management roles ([7092582](https://github.com/golemfoundation/octant-v2-core/commit/7092582a38b1e76af108a983f72d5c40f23cf254))


### Bug Fixes

* address final audit finding in _claimReward ([fe4c3f5](https://github.com/golemfoundation/octant-v2-core/commit/fe4c3f5f347864b731dfce03160089ffa4958489))
* **auth:** restrict hook access to delegatecall only ([31336ab](https://github.com/golemfoundation/octant-v2-core/commit/31336ab843585c3786cae7a3027f6a9ad2152b09))
* **funding:** update total funding calculation to use weighted formula ([1e32fe8](https://github.com/golemfoundation/octant-v2-core/commit/1e32fe8146866b8a4e373d43a388c374a11817f7))
* onlyRegenGovernance in MultistrategyLockedVault ([206d7d3](https://github.com/golemfoundation/octant-v2-core/commit/206d7d345d7d5c8c7fa2852e05307eccfac46320))
* prevent ETH permanent fund loss by rejecting ETH deposits ([4ce82fc](https://github.com/golemfoundation/octant-v2-core/commit/4ce82fc0a8a68238c8a9798fa6936b21363605f4))
* prevent share dilution attack through delayed proposal queueing ([d435b13](https://github.com/golemfoundation/octant-v2-core/commit/d435b13466446454b002ac1baaff8975b8b9df79))
* prevent zero voting power registration from decimal scaling ([76ddbde](https://github.com/golemfoundation/octant-v2-core/commit/76ddbde8a4d3530d8bc13a58a6fcba843dcdd622))
* **ProperQF:** resolve overflow in quadratic calculations for 18-decimal token ([541fbc7](https://github.com/golemfoundation/octant-v2-core/commit/541fbc781d7f8ec5a2372e8126daa7524fdca5b5))
* refine zero voting power check to allow zero-deposit registrations ([d76a03a](https://github.com/golemfoundation/octant-v2-core/commit/d76a03af19d3b249f85d66c8ff4fed9784832b2b))
* remove balance adjustment in _withdraw for accurate previewRedeem ([8936b91](https://github.com/golemfoundation/octant-v2-core/commit/8936b914f71ac1cc0f1e285a87ede6d11c69f050))
* **security:** prevent whitelist circumvention via delegation ([1a0c922](https://github.com/golemfoundation/octant-v2-core/commit/1a0c922fea29c7bb1bfb95d89a8fe2f826bd09d7))


### Reverts

* Revert "Revert "refactor(QuadraticVoting): simplify _availableWithdrawLimit"" ([1226206](https://github.com/golemfoundation/octant-v2-core/commit/12262067758007f3334475f6de90ec519f7b4892))
* Revert "refactor(QuadraticVoting): simplify _availableWithdrawLimit" ([941e84d](https://github.com/golemfoundation/octant-v2-core/commit/941e84dd457279fe3ea126a2de7561cea39fd8b5))

## [0.5.11-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.5.10-develop.0...v0.5.11-develop.0) (2025-07-10)

## [0.5.10-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.5.9-develop.0...v0.5.10-develop.0) (2025-07-10)

## [0.5.9-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.5.8-develop.0...v0.5.9-develop.0) (2025-07-09)

## [0.5.8-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.5.7-develop.0...v0.5.8-develop.0) (2025-07-09)

## [0.5.7-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.5.6-develop.0...v0.5.7-develop.0) (2025-07-09)

## [0.5.6-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.5.5-develop.0...v0.5.6-develop.0) (2025-07-09)

## [0.5.5-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.5.4-develop.0...v0.5.5-develop.0) (2025-07-09)

## [0.5.4-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.5.3-develop.0...v0.5.4-develop.0) (2025-07-09)

## [0.5.3-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.5.2-develop.0...v0.5.3-develop.0) (2025-07-09)

## [0.5.2-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.5.1-develop.0...v0.5.2-develop.0) (2025-07-09)

## [0.5.1-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.5.0-develop.0...v0.5.1-develop.0) (2025-07-08)


### Bug Fixes

* prevent CREATE3 front-running attacks in strategy factories ([c3653ee](https://github.com/golemfoundation/octant-v2-core/commit/c3653ee94d9aa150adf28e07b61ff0b3024e6831))
* use decimalsOfExchangeRate for proper exchange rate scaling ([60638e9](https://github.com/golemfoundation/octant-v2-core/commit/60638e9f33672fe83a7cd619ab15ca2602c02a9a))

## [0.5.0-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.4.0-develop.0...v0.5.0-develop.0) (2025-07-03)


### Features

* add enableBurning flag to TokenizedStrategy ([952397e](https://github.com/golemfoundation/octant-v2-core/commit/952397e11d54980919ab422664ad71d5d30881c9))
* add loss tracker to TokenizedStrategy ([dd6dfd4](https://github.com/golemfoundation/octant-v2-core/commit/dd6dfd440764085ac59d0b69dbebf6f26d15dc6a))
* create BaseYieldSkimmingStrategy ([bcc94d2](https://github.com/golemfoundation/octant-v2-core/commit/bcc94d2352311856c8ad14f0323864a029d023b5))
* create IYieldSkimmingStrategy interface ([7875aa6](https://github.com/golemfoundation/octant-v2-core/commit/7875aa665f55cfc6b611cd6be469cbed22b19ced))
* ERC20SafeApproveLib ([ad52b9a](https://github.com/golemfoundation/octant-v2-core/commit/ad52b9a8eff38d7518396a5aa567c4b9ed577b4d))
* **events:** add donation tracking events for transparent yield flow monitoring ([829109c](https://github.com/golemfoundation/octant-v2-core/commit/829109c075f1ecc0a14a85b840dd7182ea47aecc))
* implement burning logic in yield strategies ([00f9ba1](https://github.com/golemfoundation/octant-v2-core/commit/00f9ba11bf40e4a53e81fa3bc4c2cdf541abf866))
* remove ERC20SafeLib after consolidating safe operations ([1256147](https://github.com/golemfoundation/octant-v2-core/commit/125614793ab4322b1597938bc8f374f66fc8e201))
* **security:** implement constructor-based bytecode canonicalization for RegenStakerFactory ([f476b26](https://github.com/golemfoundation/octant-v2-core/commit/f476b266c1c1fe3c7083b9e6d065ba2b4d8ad963))
* **strategies:** implement loss tracking mechanism for yield skimming strategies ([ef5f87b](https://github.com/golemfoundation/octant-v2-core/commit/ef5f87b693b10c468f7645a9be9da9631b6532f9))
* update BaseStrategy to pass enableBurning parameter ([eca769a](https://github.com/golemfoundation/octant-v2-core/commit/eca769a5b869ccb029b0ea86d882e5526ac702ea))
* update concrete strategies for enableBurning parameter ([bb9c019](https://github.com/golemfoundation/octant-v2-core/commit/bb9c0192787cbe5c829889081d52657e4a79f97a))
* update health check classes for enableBurning parameter ([8b475b8](https://github.com/golemfoundation/octant-v2-core/commit/8b475b8651cafb17fdab83d844eba0436f06beb3))
* update LidoStrategy with BaseYieldSkimming ([72ee74c](https://github.com/golemfoundation/octant-v2-core/commit/72ee74cd2f3122fda00d5366ff3534ed0a223d19))
* update MorphoCompounderStrategy with BaseYieldSkimming ([6810af7](https://github.com/golemfoundation/octant-v2-core/commit/6810af77b833316620115de49f5b9e814370ed46))
* update RocketPoolStrategy with BaseYieldSkimming ([125c2bb](https://github.com/golemfoundation/octant-v2-core/commit/125c2bbc93c1d411da30612ddf4d59e916ab4606))
* update strategy factories to include enableBurning parameter ([5d73d2e](https://github.com/golemfoundation/octant-v2-core/commit/5d73d2ea4b8ca0d5a07106931a23104916c29a05))


### Bug Fixes

* **rounding:** resolve share calculation inconsistency in withdrawal operations ([4e5b727](https://github.com/golemfoundation/octant-v2-core/commit/4e5b727d97e626aeaf69a450d57c2ae8ade8a538))
* **security:** remove inappropriate Yearn governance control from yield skimming strategies ([c81abcd](https://github.com/golemfoundation/octant-v2-core/commit/c81abcd323da5f25e4a93d8d82169ec861ba8063))
* use actual deposit amount in debt calculation ([b84d3a6](https://github.com/golemfoundation/octant-v2-core/commit/b84d3a6284fd746499876a98e94415f0d5a8e5e7))
* **yield-skimming:** implement proper _harvestAndReport return value in BaseYieldSkimmingStrategy ([7a3e024](https://github.com/golemfoundation/octant-v2-core/commit/7a3e024eb273579bb4ccca202af5402280dbf170))


### Reverts

* Revert "chore: add dry-run deployment of staging env to PR and push pipelines" ([a6a2c5b](https://github.com/golemfoundation/octant-v2-core/commit/a6a2c5b192c59a2f0fe85238632564f7f4acf6c6))

## [0.4.0-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.3.0-develop.1...v0.4.0-develop.0) (2025-06-27)


### Features

* **regen:** enhance factory for vanity address generation and document precision implications ([c433d8b](https://github.com/golemfoundation/octant-v2-core/commit/c433d8ba56c173ce97dd9804f41dab8f6ca040fe))
* **strategies:** add availableWithdrawLimit to SkyCompounderStrategy ([8d553c5](https://github.com/golemfoundation/octant-v2-core/commit/8d553c53b9f015f4e1cad2b9e420f61bdc1c5fd9))


### Bug Fixes

* **regen:** check if allocation mechanism is whitelisted ([93a15b0](https://github.com/golemfoundation/octant-v2-core/commit/93a15b0bc0b463c32b48e90e0f6cff919dffb02a))
* **regen:** don't avoid zero amount for notify reward ([5420356](https://github.com/golemfoundation/octant-v2-core/commit/54203561ca7bcd7701b688e3e3131cfe64be68c8))
* **regen:** don't start whitelists enabled ([a4f350b](https://github.com/golemfoundation/octant-v2-core/commit/a4f350bbca2faab420e8d90ebc2b3524a6fff205))
* **regen:** factory ([a2209c6](https://github.com/golemfoundation/octant-v2-core/commit/a2209c6e1e5bd9c20e12291ffb1dc4453612a845))
* **strategies:** correct type mismatch in MorphoCompounderStrategy emergency withdraw ([d062222](https://github.com/golemfoundation/octant-v2-core/commit/d06222282c7deef4e3d758f29a7ee0e213aabfe4))
* **strategies:** improve loss protection rounding in YieldDonatingTokenizedStrategy ([5be1def](https://github.com/golemfoundation/octant-v2-core/commit/5be1def7497ed6f48f8f01c39841388f0f9abfb4))

## [0.3.0-develop.1](https://github.com/golemfoundation/octant-v2-core/compare/v0.3.0-develop.0...v0.3.0-develop.1) (2025-06-23)


### Features

* **allowance:** add abstract executor with test implementation ([e15ae52](https://github.com/golemfoundation/octant-v2-core/commit/e15ae523395f4f6b2b38a553a38edcd3cfe9d05c))
* **allowance:** add abstract executor with test implementation ([ac14cf4](https://github.com/golemfoundation/octant-v2-core/commit/ac14cf48463c541d5eb39640c2873a2f420e5e91))
* **allowance:** add emergency revoke allowance functionality ([ee6011f](https://github.com/golemfoundation/octant-v2-core/commit/ee6011f39e23fc54c036077e5321a450691aa806))
* **allowance:** add emergency revoke allowance functionality ([24c13c1](https://github.com/golemfoundation/octant-v2-core/commit/24c13c16119216a34b7e47c0d3776daf684af79c))
* **auth:** add EIP712 signature support for signup and voting ([b3d28f0](https://github.com/golemfoundation/octant-v2-core/commit/b3d28f0f3d5119709da1b4e2acac80d4d908176e))
* create BaseYieldSkimmingHealthCheck ([a12a6a5](https://github.com/golemfoundation/octant-v2-core/commit/a12a6a51b4026e3a77b61aed8e0853d1e32a597e))
* create BaseYieldSkimmingStrategy ([d424a39](https://github.com/golemfoundation/octant-v2-core/commit/d424a39e2155f235c8d1e4501085849df121899f))
* create batch functions in LinearAllowanceSingletonForGnosisSafe ([afce643](https://github.com/golemfoundation/octant-v2-core/commit/afce643ce4a409045b562663cb4e8a45a6a0af2c))
* create getMaxWithdrawableAmount() in LinearAllowanceSingletonForGnosisSafe ([86f7c74](https://github.com/golemfoundation/octant-v2-core/commit/86f7c7491ea34f62d88d16a422d92797687ecf39))
* create RocketPoolStrategy ([d9b80ed](https://github.com/golemfoundation/octant-v2-core/commit/d9b80edc84ec5b881a0117db1a87fdda3649e915))
* create RocketPoolStrategyVaultFactory ([317ee74](https://github.com/golemfoundation/octant-v2-core/commit/317ee74ae16dc5b7e8b419e6ba74f0be9c5b23e6))
* **husky:** add slither check ([3e3b45b](https://github.com/golemfoundation/octant-v2-core/commit/3e3b45b28b63afd33c2455cddcbaa7da645e85e1))
* introduce 2 steps donationAddress change ([3804d4a](https://github.com/golemfoundation/octant-v2-core/commit/3804d4a61b586f0aaa72d050b8794c70b608d2c6))
* **mechanisms:** implement tokenized allocation pattern using Yearn V3 style proxy ([61f0740](https://github.com/golemfoundation/octant-v2-core/commit/61f074060b274284ce77c669627b16a9116ff48b))
* **regen:** compounding ([8bdf9cd](https://github.com/golemfoundation/octant-v2-core/commit/8bdf9cde2da773254952adf047eaff6d58814c80))
* **security:** add zero address validation for allowance module ([19663f4](https://github.com/golemfoundation/octant-v2-core/commit/19663f470eb82714579da8e75d42aa229c361d60))


### Bug Fixes

* **allowance:** check post condition of beneficiary as a signal of success ([595ee3f](https://github.com/golemfoundation/octant-v2-core/commit/595ee3f8e2ccc5d21a1be2fa45ab2c589f3dc994))
* **allowance:** fix all the findings and more, refactor and cleanup ([877efef](https://github.com/golemfoundation/octant-v2-core/commit/877efef01398400869bbdbce1eadc269a9b11f9f))
* **allowance:** handle uint160 overflow in drip rate calculation ([da33177](https://github.com/golemfoundation/octant-v2-core/commit/da33177c64605ad4a12b2ee00fab9744e8803e74))
* **allowance:** linter ([87f497a](https://github.com/golemfoundation/octant-v2-core/commit/87f497a193267c5d0e13da3844d64500430c03ef))
* **allowance:** prevent precision loss and zero transfer exploits ([f0e86e4](https://github.com/golemfoundation/octant-v2-core/commit/f0e86e4ad0766a0593bc82caeaa0846b02c71755))
* **allowance:** rebase issues about data types ([d4a21d8](https://github.com/golemfoundation/octant-v2-core/commit/d4a21d8ece020f474411cde77b7224223c339d77))
* **allowance:** struct packing and drip rate ceiling ([dc7be4c](https://github.com/golemfoundation/octant-v2-core/commit/dc7be4ce1e35a5c79e511a62cdcf47fa93700ca7))
* **test:** cast to correct type ([fd3caf9](https://github.com/golemfoundation/octant-v2-core/commit/fd3caf925b98a0fafe0712efe616f35ae89865bd))

## [0.3.0-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.2.5-develop.0...v0.3.0-develop.0) (2025-06-11)


### Features

* add payee naming and on-chain splitter lookup ([10df4ff](https://github.com/golemfoundation/octant-v2-core/commit/10df4ff925a5b6ce1770e3c141107ba1a840accd))
* add payee naming and on-chain splitter tracking ([52c3fb6](https://github.com/golemfoundation/octant-v2-core/commit/52c3fb64c75d75d0536f6d1e549a5ff4ecd405ab))
* **core:** add quadratic funding impact strategy ([0b0b354](https://github.com/golemfoundation/octant-v2-core/commit/0b0b3549fa40385355e948e70971be3adb8eb3f3))
* create DeployPaymentSplitter ([b412cc1](https://github.com/golemfoundation/octant-v2-core/commit/b412cc1bc99535f315400f836b36a682ed5d0da8))
* create DeployPaymentSplitterFactory ([7fcd6e6](https://github.com/golemfoundation/octant-v2-core/commit/7fcd6e6002d1ad14a7cc9ec18ee7d91c8734bb6a))
* create ILockedVault interface ([1c625d5](https://github.com/golemfoundation/octant-v2-core/commit/1c625d5732dbc6f6113d1ed33ef6762d5d4c2c71))
* create Lido strategy ([664bbe8](https://github.com/golemfoundation/octant-v2-core/commit/664bbe8ca2f34205d785962c498e570f1c240b2e))
* create LidoTest ([0cc47cd](https://github.com/golemfoundation/octant-v2-core/commit/0cc47cdf87c2f345a43a7b071860f3faf59d48d6))
* create LidoVaultFactory ([bb1db5d](https://github.com/golemfoundation/octant-v2-core/commit/bb1db5d2f2c0b4470412745b27fa839b4334977c))
* create MorphoCompounder ([fc3ed97](https://github.com/golemfoundation/octant-v2-core/commit/fc3ed97881c299eab0ef4ffc1bbbed7cb33807b1))
* create PaymentSplitterFactory ([b3ef3bb](https://github.com/golemfoundation/octant-v2-core/commit/b3ef3bb28804c98e00592babb2853f9c2f8e16e7))
* create Vault deployment script ([f68b6de](https://github.com/golemfoundation/octant-v2-core/commit/f68b6de7afc7e432b7d5c0d45d9e9a6e9c9c5e89))
* create VaultFactory ([5659cfb](https://github.com/golemfoundation/octant-v2-core/commit/5659cfbc0be643b904e38bc1bdd832bc48c599e0))
* create VaultFactory deployment script ([dbc1986](https://github.com/golemfoundation/octant-v2-core/commit/dbc19866a93129ca9d904bfe886d689aea53a7cb))
* create yield donating vault factory ([9501eee](https://github.com/golemfoundation/octant-v2-core/commit/9501eee5b14928b5a963cf9b3023a28bdce973f4))
* create YieldDonating MorphoCompounderStrategy ([413c6b0](https://github.com/golemfoundation/octant-v2-core/commit/413c6b01292e1c87c20bdec54c30d569a9a6fc0b))
* create YieldDonating MorphoCompounderStrategyVaultFactory ([ecb6294](https://github.com/golemfoundation/octant-v2-core/commit/ecb6294101280d25712156bc1caad83f2453b2e3))
* implement tokenized impact strategy with quadratic funding mechanism ([c4c816e](https://github.com/golemfoundation/octant-v2-core/commit/c4c816e97d0d2762f33973af461d614d8c3f5e55))
* initialize yearn v3 tokenized strategy contracts ([61af67b](https://github.com/golemfoundation/octant-v2-core/commit/61af67b82ad2c02e50b85118741f638f2a1907ea))
* **interfaces:** add smart contract interfaces for multiuser strategies ([3934cfd](https://github.com/golemfoundation/octant-v2-core/commit/3934cfd88388782fa75ee7d8b4498425b8413318))
* make grace period configurable ([d9b6b7c](https://github.com/golemfoundation/octant-v2-core/commit/d9b6b7c6dbcae74d26319823fa88dc86f0660979))
* make PaymentSplitter initializable ([27ec473](https://github.com/golemfoundation/octant-v2-core/commit/27ec473f7cf840a0d63e35fb72cf644b9fd0cbba))
* **mechanism:** add owner-only quorum updates and improve code formatting ([c296777](https://github.com/golemfoundation/octant-v2-core/commit/c296777112ff065643251dc9dfdb78c5a4a7efa3))
* **mechanism:** add start block parameter to QV mechanism ([09c0517](https://github.com/golemfoundation/octant-v2-core/commit/09c0517f68ef4f19187eb9cb8160e8244cbb077c))
* **mechanism:** add startBlock parameter to SimpleVotingMechanism ([0d7b205](https://github.com/golemfoundation/octant-v2-core/commit/0d7b205d3537d5b07733f0174f16362fc991f457))
* **mechanism:** implement quadratic voting allocation mechanism ([5d3a7e5](https://github.com/golemfoundation/octant-v2-core/commit/5d3a7e58bfb3dbbbfeafd51788e07fd1bae3ee6f))
* multi strategy vault ([b5d7dea](https://github.com/golemfoundation/octant-v2-core/commit/b5d7deab0d84a7071a98794377a7fa7ef8ffa8a9))
* **multiuser-strategy:** clean up new multiuser strategy base and lib contracts ([54acb54](https://github.com/golemfoundation/octant-v2-core/commit/54acb545b37ddb1dd30e8c6744c9748d418f3fb7))
* mvp LockedVault ([96fa7bc](https://github.com/golemfoundation/octant-v2-core/commit/96fa7bcaf04f9273230454e412791aac5afc9c20))
* pass tokenized strategy to constructor ([66bf06c](https://github.com/golemfoundation/octant-v2-core/commit/66bf06c9841b4c8b27c6c8ad8efe7ec59b80243e))
* **periphery:** import and adjust periphery contracts so we can use them with DragonTokenizedStrategy ([44328ea](https://github.com/golemfoundation/octant-v2-core/commit/44328eaf82796b21f85909c3fb0d74e8199e0650))
* **periphery:** import and adjust periphery contracts so we can use them with DragonTokenizedStrategy ([b6d56bd](https://github.com/golemfoundation/octant-v2-core/commit/b6d56bd169707a4b74099ce8d60f5195afdf6366))
* port PaymentSplitter ([39bf73e](https://github.com/golemfoundation/octant-v2-core/commit/39bf73e725bb51655e688bec032b670263a9fab0))
* **regen:** contribute function ([afdf9a5](https://github.com/golemfoundation/octant-v2-core/commit/afdf9a5df96aaf7897d650e0f7fa37d949728580))
* **regen:** new tests and refactorings ([44ddddd](https://github.com/golemfoundation/octant-v2-core/commit/44dddddd41fd4f697fac800ae78c28a6798de53e))
* **regen:** pausable withdraw and claimRewards ([c6f41d4](https://github.com/golemfoundation/octant-v2-core/commit/c6f41d4c8fa40283b6ac5307f6e9c367ff809393))
* **regen:** pause and tests ([3b59a0a](https://github.com/golemfoundation/octant-v2-core/commit/3b59a0a771fcf984d9d843ffdc1ba4c8cdd901bd))
* **regenstaker:** contribute with signature ([c62bebb](https://github.com/golemfoundation/octant-v2-core/commit/c62bebb0629588f773a41a68ace32ea82a16fc68))
* **regenstakerfactory:** implement with create3 ([3cf0cd8](https://github.com/golemfoundation/octant-v2-core/commit/3cf0cd82bcb82223887b9d2c46cacf2282ade637))
* **regenstakerfactory:** implement with create3 ([246a3ab](https://github.com/golemfoundation/octant-v2-core/commit/246a3abfd28186cc0233b9dd9d2e4dc203513797))
* **regenstaker:** toggleable minimum staking amount ([1ca1de4](https://github.com/golemfoundation/octant-v2-core/commit/1ca1de48c52c210a6d7e5222b9b4e221185ea087))
* **regenstaker:** variable reward duration, fixes, doc updates, and tests ([3dbd152](https://github.com/golemfoundation/octant-v2-core/commit/3dbd152b062d81b4e55a385f5f131828387349e2))
* **regen:** staking, license, whitelists and epc ([e7efcdf](https://github.com/golemfoundation/octant-v2-core/commit/e7efcdfb2a8273b56798b34275ad791fd67c9cc0))
* **regen:** staking, license, whitelists and epc ([3b840af](https://github.com/golemfoundation/octant-v2-core/commit/3b840afc568201c82df687d1e5757c0fa99e51d9))
* **strategy:** add yield skimming tokenized strategy implementation ([cd8ede6](https://github.com/golemfoundation/octant-v2-core/commit/cd8ede61094ba9c2fdc8aa348c389fe5edc9f645))
* **strategy:** implement yield donating tokenized strategy ([f455ce0](https://github.com/golemfoundation/octant-v2-core/commit/f455ce012c62cfb8bcac705e8d6d1852453a3205))
* **strategy:** implement YieldDonating strategy with tests and deployment ([9b5d49a](https://github.com/golemfoundation/octant-v2-core/commit/9b5d49a0d58a4ae1062597106c64e4694e92b943))
* **strategy:** multi user dragon tokenized strategy without profit locking, etc ([00cdf16](https://github.com/golemfoundation/octant-v2-core/commit/00cdf164bac1dbc760b611f3567a5d0938dafdbb))
* use mininal proxies for PaymentSplitterFactory ([5ce97fa](https://github.com/golemfoundation/octant-v2-core/commit/5ce97fa71f9626e9a5fb3dc31f37f5be4daa5c15))
* **voting:** add start block and restrict proposal cancellation ([b286392](https://github.com/golemfoundation/octant-v2-core/commit/b28639216953d2e63f68dfffc63ad261090d079d))
* **voting:** implement proper quadratic funding algorithm ([d7520c5](https://github.com/golemfoundation/octant-v2-core/commit/d7520c5ee8d50f592efc88ca609d4705ee85de8d))
* **yield-skimming:** dragon strategy variants for yield skimming variant ([030740b](https://github.com/golemfoundation/octant-v2-core/commit/030740b3bc5cea4cc7fd83faceb8bc5d6e9ea6dd))


### Bug Fixes

* align debt calculation with Vault.py ([0d924c6](https://github.com/golemfoundation/octant-v2-core/commit/0d924c68db4f2909d3042c7b1ba474ac1c9365c0))
* avoid reentrancy issue ([24b4ccc](https://github.com/golemfoundation/octant-v2-core/commit/24b4ccc95195c56820c09d7c8e512aa768c7e255))
* compiling issue in Vault ([b11d3b9](https://github.com/golemfoundation/octant-v2-core/commit/b11d3b9634b3b71fd80a5f474d9d949381f54199))
* **epc:** incorrect comparison between new and old earning power ([c6789ab](https://github.com/golemfoundation/octant-v2-core/commit/c6789abdade3de29ad62d5736a7a0dda7ce244fb))
* **factory:** add emergency admin to strategy constructor ([ac3efbb](https://github.com/golemfoundation/octant-v2-core/commit/ac3efbbebab9e0d5aff56ede649890a2d1014fae))
* initialize function in Vault ([3d6d7a0](https://github.com/golemfoundation/octant-v2-core/commit/3d6d7a04e2d19a6aa743de3e1d6a14e88c25610a))
* issues with roles bitmasks ([526575d](https://github.com/golemfoundation/octant-v2-core/commit/526575de479600ad2089e6e89b1c51f12bca6498))
* **regen:** prevent stake on behalf and permit and staked when paused ([9411e30](https://github.com/golemfoundation/octant-v2-core/commit/9411e30bdadd8120ea9c5b6d2eaaf4d5806744ba))
* **regen:** prevent stake on behalf and permit and staked when paused ([b87a76a](https://github.com/golemfoundation/octant-v2-core/commit/b87a76a2bb08f4af6664ac154cdf71c9600a2171))
* **regenstaker:** admin should be the owner of the all whitelisting contracts ([f217f9f](https://github.com/golemfoundation/octant-v2-core/commit/f217f9f7f460f82380001bec7beb8272cd8a0b23))
* **regenstaker:** admin should be the owner of the all whitelisting contracts ([081759f](https://github.com/golemfoundation/octant-v2-core/commit/081759ffa6e52634eff92c4077123b7b0f7ef6a2))
* **regenstakerfactory:** sal, event, natspec, tests ([12526bf](https://github.com/golemfoundation/octant-v2-core/commit/12526bf6eecb59df6d7197b9ea3878b0d7910dc3))
* **regenstaker:** prevent stake amount reaching below threshold through withdraw and contribute ([a41018c](https://github.com/golemfoundation/octant-v2-core/commit/a41018cd12a26dd9d21a025aa8024c7579440c07))
* **regenstaker:** prevent stake amount reaching below threshold through withdraw and contribute ([d6cf318](https://github.com/golemfoundation/octant-v2-core/commit/d6cf3187d0106d45e801e763cfb4b147ed06f85d))
* **regenstaker:** prevent stake amount reaching below threshold through withdraw and contribute ([bb8f57b](https://github.com/golemfoundation/octant-v2-core/commit/bb8f57b88a87696bba2c229d3cc305357c8db999))
* shadowed declarations in Vault.sol ([e5f1fb9](https://github.com/golemfoundation/octant-v2-core/commit/e5f1fb95ce28f21aa505531277ea116a9da78e9b))
* **strategy:** squash bugs and clean up integration to new base contracts ([60e495d](https://github.com/golemfoundation/octant-v2-core/commit/60e495d658d176a46ac3f71e8256354c0eca52ff))
* **strategy:** squash bugs and clean up integration to new base contracts ([28b41e4](https://github.com/golemfoundation/octant-v2-core/commit/28b41e4a440953f1d42cb789813b547c6887e39b))
* **test:** relax tolerance and bound minimum reward by Staker's limit ([d988257](https://github.com/golemfoundation/octant-v2-core/commit/d98825763ba92fc07eae5536540e13e6a7ac84e9))
* **test:** relax tolerance and bound minimum reward by Staker's limit ([cde1f1b](https://github.com/golemfoundation/octant-v2-core/commit/cde1f1b644f7d2ca22cb54f77cbd10ff329cbab2))
* **test:** relax tolerance and bound minimum reward by Staker's limit ([109073e](https://github.com/golemfoundation/octant-v2-core/commit/109073e07fffc9e820d5b3fb3d5367f8a4f57cc2))
* YieldSkimmingTokenizedStrategy dealing with totalAsset ([8eebac0](https://github.com/golemfoundation/octant-v2-core/commit/8eebac07fc51d1615782c2a603693a0aff30511c))

## [0.2.5-develop.0](https://github.com/golemfoundation/octant-v2-core/compare/v0.2.4-0...v0.2.5-develop.0) (2025-04-30)


### Bug Fixes

* add starting block to deployment logs and output file ([ba9631d](https://github.com/golemfoundation/octant-v2-core/commit/ba9631deacef50eb3b6dbeb793a39d1237b194c9))
* cache-array-length ([257aa32](https://github.com/golemfoundation/octant-v2-core/commit/257aa32dab873d81444de9aa4ec2eb75d8ac719f))
* divide-before-multiply ([b11dc40](https://github.com/golemfoundation/octant-v2-core/commit/b11dc40a42cb61e00b51383112a477074b4e16a3))
* ignore false positives ([07887dc](https://github.com/golemfoundation/octant-v2-core/commit/07887dcf50677ece59fcdd670ab2e59d948d1289))
* ignore unused-return ([793977c](https://github.com/golemfoundation/octant-v2-core/commit/793977c3e85009c8daf67dd0da153796dbbccaa5))
* incorrect-equality ([052b52c](https://github.com/golemfoundation/octant-v2-core/commit/052b52c70c7189d844cf57b3be05f560798370f1))
* pipeline token ([fa85fa9](https://github.com/golemfoundation/octant-v2-core/commit/fa85fa980d76e20aad2e85d77ee6f164713f9a0c))
* reentrancy-no-eth ([d6d2c36](https://github.com/golemfoundation/octant-v2-core/commit/d6d2c360e5ff76d88c2cbbdf899d2ae2284ef7e8))
* state-variables-that-could-be-declared-immutable ([492f9ad](https://github.com/golemfoundation/octant-v2-core/commit/492f9ad8e549537749f97a41ca2838c862b16874))
* uninitialized-local-variables ([893c82f](https://github.com/golemfoundation/octant-v2-core/commit/893c82fae62f6d11c0a4bc0b6335a6be1c07e849))
* var-read-using-this ([39142fe](https://github.com/golemfoundation/octant-v2-core/commit/39142fe9516970db657bb117e0620ca2d50f1f50))
