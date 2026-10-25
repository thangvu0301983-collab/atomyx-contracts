# Recycling Ledger operations

How a real collected batch of waste becomes a Recycling Ledger entry in the Reclaim Vault
(`0xE031C733817b09228B8D443c5770F5864899377D`) and a reward paid to its collector.

## Rules the contract enforces

- Only the attester can record a batch: material, weight in grams, and the evidence hash.
- A batch can be paid only by the guardian, only after a 24-hour public review, never once voided, and in total at
  most `grams × maxWeiPerKg / 1000` (0.0002 ETH per kg at launch).
- Rewards come only from the Recycling Rewards pool (20% of creator fees).

## Rules this process adds

- Every batch has three weighings, at the Point, at sorting and at the recycler, each with a photo of the scale.
  If they differ by more than 5%, the batch is held and not recorded. The recorded weight is the lowest of the three.
- A recycler receipt or weighbridge ticket is required.
- The reward goes to the collector's own wallet, never to a team wallet.
- The evidence file is published in this repository before the batch is recorded. The on-chain evidence hash is
  `keccak256` of that file's exact bytes, so anyone can check an entry.

## Steps

1. Copy `draft-template.json`, fill it in with the real batch, and run:
   `node ledger/batch.mjs prepare my-batch.json`
   This validates the batch, writes `ledger/batches/<id>.json` and prints the `recordBatch` inputs.
2. Commit and push `ledger/batches/<id>.json`.
3. Call `recordBatch` on the vault's Blockscout *Write contract* tab, signed by the attester, with the printed inputs.
4. During the 24-hour review, anyone can check the published evidence; the guardian voids the batch (`voidBatch`) if
   it is wrong.
5. After 24 hours, run `node ledger/batch.mjs status <id>`. It checks the on-chain hash against the file and prints
   the `payReward` inputs. The guardian signs `payReward`.
6. Announce the batch and the payment transaction.

`batch.mjs` only reads the chain. It never signs or sends a transaction. `ETH_RPC_URL` overrides the default RPC.
