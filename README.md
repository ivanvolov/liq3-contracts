# BondVault

Fixed-term deposit positions as NFTs, with a Lido-style withdrawal queue.
One contract, deployed once per asset (a bond series); a token staking series
is the same contract configured with a never-maturing term.

## How it works

- `deposit(amount, duration)` pulls the series asset from the caller, forwards
  it straight to a custody wallet (the vault never holds principal; a
  balance-delta check rejects fee-on-transfer assets) and mints an ERC-721
  position with the terms copied in at mint. The terms grid is
  `mapping(duration => aprBps)` — the duration is the term's identity,
  `setTerm(duration, apr)` runs the whole grid, APR 0 means no such term, and
  grid rewrites only affect future positions.
- Exit is a three-step queue keyed by the tokenId (one request per position,
  ever): `requestWithdraw` → `fundAndApproveClaim` (operator; pulls the cash
  off the treasury's standing ERC-20 allowance in the same transaction, so
  approval without delivered money is impossible) → `claim` (also the ERC-5725
  entrypoint). Early exit pays the principal, exactly; at/after maturity
  principal + the APR written in the position, plus whatever extra the operator
  funds, bounded to [base, base × (1 + bonus cap)]. The position NFT stays
  transferable through the queue; the payout goes to the owner at claim time
  and the NFT is burned.
- Exit windows are read at withdraw time, so a window change moves the whole
  queue — already-filed requests included — and both windows are hard-capped
  at 30 days.
- A matured position can `roll` (or autoroll via a standing, rate-floored
  permission the operator executes) into a new term: old NFT burned, new one
  minted with earned interest compounded into the principal.
- Staking series: `setTerm(type(uint32).max, 1)` — the term never matures, so
  every exit is "early" and refunds exactly the staked amount; the 1-bps APR is
  an unreachable marker (0 would mean "no term").

## Standards

ERC-721 (OpenZeppelin), ERC-5725 claim interface (id `0xbd3a202b`, verified
against the EIP and asserted in tests; one documented deviation — `claim` pays
the current owner, never `msg.sender`), ERC-7540 naming for queue states.
UUPS proxies (OpenZeppelin upgradeable bases + initializers), `AccessControl`,
`Pausable` (pause stops money-in only; the exit pipeline is never pausable),
`ReentrancyGuard` on token-moving functions, `SafeERC20` (tested against USDT
no-return/approve-race semantics).

## Roles

- `DEFAULT_ADMIN` — a multisig behind a `TimelockController`: upgrades,
  treasury and custody addresses, rescue (capped by the funded-claim float).
- `MANAGER` — the multisig directly: terms grid, min deposit, windows, bonus
  cap, unpause; role-admin of the two hot keys, so a leaked key is revocable
  without the timelock.
- `OPERATOR` — a bot hot key: `fundAndApproveClaim` and `executeAutoRoll`,
  both bounded onchain.
- `PAUSER` — emergency money-in stop.

## Layout

```
src/BondVault.sol              the flows: deposit, exit queue, rolling, ERC-5725
src/base/BondVaultParams.sol   params, storage, setters, roles
src/interfaces/                errors, events, structs; the verified IERC5725
src/libraries/TermMath.sol     simple pro-rata interest, ACT/365
script/Deploy.s.sol            one-series deploy: timelock + proxy + role handover
test/                          unit, flow, fuzz, invariant and staking-series suites
```

## Dev

```
make build        # forge build
make test         # forge test
make coverage     # line coverage on src/
make deploy-sim   # one-series deploy simulation with dummy env
```

Foundry (solc 0.8.26), OpenZeppelin v5.1 + v5.1-upgradeable as git submodules.
Post-deploy: the multisig sets the grid and min deposit, and the treasury Safe
grants the vault its asset allowance — that allowance is the funding pipe.
