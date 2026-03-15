.PHONY: build
build:
	forge build

.PHONY: unit
unit:
	forge test --no-match-path "*Integration*.sol"

.PHONY: integration
integration:
	forge test --match-path "*Integration*.sol"

.PHONY: test
test: unit integration

.PHONY: gas
gas:
	forge snapshot --match-path 'test/gas/**'

.PHONY: gas-diff
gas-diff:
	forge snapshot --diff .gas-snapshot --match-path 'test/gas/**'

.PHONY: kontrol
kontrol:
	kontrol build && kontrol prove --workers 8
