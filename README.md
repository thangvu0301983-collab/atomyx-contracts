# ATOMYX contracts

ATOMYX ($ATMX) is a Proof-of-Recycling network for the United States and Europe: drop-off points with IoT scales,
AI sorting stations and partner recyclers. This repository holds the exact sources of the $ATMX launch graph for the
[Programmable](https://programmable.market) Ethereum Custom Launch, and ATOMYX's Reclaim Vault.

## Launch graph (`protected/`)

Programmable requires every new native-ETH launch to use its sealed launch-protection package v1
(`@programmable/launch` 4.1.7). $ATMX uses that package unchanged, plus one ATOMYX contract:

| Target | Contract | Role |
|---|---|---|
| `initializer` | `ProtectedNativeInitializerV1` (Programmable) | USD 15,000 opening floor on the Chainlink ETH/USD feed, 100% of supply as one locked position, the capped opening buy |
| `token` | `ProtectedLaunchTokenV1` (Programmable) | $ATMX, 1,000,000,000 fixed supply; 2% receive cap per wallet for 300 seconds |
| `hook` | `ProtectedNative30HookV1` (Programmable) | 0.30% platform fee + fixed 2.5% creator fee on buys and sells; 99% opening buy fee decaying to normal in 30 seconds; 2% per-buyer cap for 300 seconds |
| `vault` | `src/ReclaimVault.sol` (ATOMYX) | The hook's immutable creator-fee recipient |

Only one value differs from Programmable's own helper output: the creator-fee recipient is the Reclaim Vault instead
of the launch wallet.

## Reclaim Vault (`src/ReclaimVault.sol`)

- **Split.** `distribute()`, callable by anyone, pays 80% of new creator fees to the project treasury wallet
  (team, development, operations and marketing) and keeps 20% in the vault as the Recycling Rewards pool.
- **Recycling Ledger.** The attester records each waste batch once: a unique batch id, the material (0 PET, 1 HDPE,
  2 PP, 3 other plastic, 4 metal, 5 paper, 6 glass, 7 e-waste), the weight in grams and the hash of its
  three-checkpoint weighing evidence.
- **Rewards.** The guardian pays rewards in ETH from the pool only against a recorded batch, only after a 24-hour
  public review, never for a voided batch, and in total at most `grams × maxWeiPerKg / 1000` per batch.
  `maxWeiPerKg` is 0.0002 ETH at launch and can never exceed 0.001 ETH. The guardian can void a batch before it is
  paid.
- **Timelocks.** Changing the treasury wallet, the attester, the reward cap or the guardian takes a 48-hour public
  timelock with no immediate exception; a treasury change distributes pending fees to the old treasury first.
  There is no other way to move ETH out of the vault. Reentrancy-guarded; no immutables.

The ledger records the attester's claims; it does not by itself prove physical recycling. The drop-off points,
sorting stations and recycling partners are planned and not yet operating; nothing in the launch graph depends on them.

## Build and test

Foundry, solc 0.8.26, optimizer 1000, `cancun`, no via-IR, no CBOR metadata. Dependencies are vendored in `lib/`.

```bash
forge test --no-match-contract AtomyxExactVersionForkTest
```

`test/ReclaimVault.t.sol` covers the split, the ledger rules, the review period and weight cap, the pool limit,
voiding, the hard maximum, every timelock, reentrancy and zero addresses, with fuzzing of the split and of batch caps.

## Packing the Programmable request

`programmable/build-protected.mjs` reproduces Programmable's `buildProtectedEthereumLaunchV1` with the Reclaim Vault as
the fourth target, writes `protected/` and `protected/protected-launch.config.json`, and verifies every predicted
address with the CLI library. The project description (`programmable/description.txt`) states who holds each vault
role; the build fills that part from the role addresses' on-chain code (ordinary wallet or smart-contract wallet).

## Exact-version execution evidence

Reviewer summary: [docs/EXACT-VERSION-EVIDENCE.md](docs/EXACT-VERSION-EVIDENCE.md).

`programmable/pack-exact.mjs` packs the request together with execution evidence for that exact request:

1. `build-protected.mjs` writes `protected/` (nonce, permit window and opening tick pinned by `LAUNCH_NONCE`,
   `VALID_AFTER`, `DEADLINE`, `START_TICK`), and the CLI packs `protected/launch.json`.
2. `export-exact-fixture.mjs` turns that `launch.json` into `test/fixtures/exact-launch.json`: the Router's graph
   targets with resolved init code and initializer calldata, in deployment order, plus the route namespace and nonce.
3. `forge test` runs everything. `test/AtomyxExactVersion.fork.t.sol` deploys those exact targets through
   Programmable's GraphFactory on a mainnet fork (pinned by `FORK_BLOCK`), called as the 24h Router with the launch
   wallet as `tx.origin`, and asserts each target's CREATE2 address and runtime code hash. Scenarios: the bound
   initial buy; twelve protection scenarios; four swap quadrants at three sizes; a second user over a year; liquidity
   custody; callback authentication; fee backing, refunds and claims into the Reclaim Vault and its 80/20 split;
   the Recycling Ledger on the deployed vault; and the exact 0.30% platform fee on every route.
4. `collect-exact-evidence.mjs` writes `evidence/exact-version.json` (no target addresses) and
   `evidence/forge-tests.json`, which the next build packs as attestation evidence.

The loop repeats until the regenerated evidence is byte-identical to the packed evidence.
`programmable/evidence-page.mjs` then writes the reviewer page from the packed evidence.

On Windows run the CLI with `node --import programmable/win-dir-fsync-shim.mjs <cli>`.

## License

ATOMYX sources: MIT. Vendored dependencies keep their own licenses.
