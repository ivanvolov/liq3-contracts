.PHONY: build test coverage fuzz invariant fmt deploy-sim

build:
	forge build

test:
	forge test -vv

coverage:
	forge coverage --no-match-coverage "(test|script)"

fuzz:
	forge test --match-path "test/Fuzz.t.sol" -vv

invariant:
	forge test --match-path "test/Invariant.t.sol" -vv

fmt:
	forge fmt

# simulation only; add --broadcast --rpc-url ... for a real deployment.
# deploys ONE series (one asset) — run once per asset.
deploy-sim:
	MULTISIG=0x1111111111111111111111111111111111111111 \
	OPERATOR_BOT=0x2222222222222222222222222222222222222222 \
	PAUSER=0x3333333333333333333333333333333333333333 \
	ASSET=0x5555555555555555555555555555555555555555 \
	CUSTODY=0x6666666666666666666666666666666666666666 \
	WBT=0x4444444444444444444444444444444444444444 \
	forge script script/Deploy.s.sol
