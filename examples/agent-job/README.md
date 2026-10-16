# examples/agent-job

Hire an agent through a reseller, pay everyone by the Taifoon payment scheme, and release the payment when Jev decides or when a proof
of delivery lands.

The contract is `src/coord/sdk/examples/AgentJob.sol`:

- `post` — the buyer pays `priceOf(sellerPrice, markup)`: the seller's price, the reseller's markup and our fee by the scheme's on-chain
  rule (`TaifoonCoord.listPriceOf`). `TaifoonCoord.checkLegs` checks the legs sum to the price, to the unit. The tokens wait in the
  contract.
- `releaseOnJev` — pays the legs once Jev's decision on this job is in the Jev decision log, recorded by Jev's recorder
  (`TaifoonAddresses.JEV_RECORDER`), at the confidence the job asked for.
- `releaseOnProof` — or pays once the Taifoon verifier proves the job's order is `delivered:ok` under the superroot.
- `refund` — after the deadline, returns the escrow to the buyer.

The legs go out by `TaifoonCoord.distributionFor`: our fee to the vault, the price to the agent, the markup to the reseller.

## Run it

```bash
forge test --match-contract AgentJobTest                                   # unit, with stub log and verifier
BASE_RPC_URL=https://mainnet.base.org forge test --match-contract AgentJobBaseForkTest
```

The fork test deploys AgentJob on a Base fork, records a verdict in the live Jev decision log as Jev's recorder (only possible on a
fork), and checks the USDC legs land: 10 USDC to the agent, 1 to the reseller, our fee to the vault. It also checks that Jev's V5
adapter on Base anchors to that log and seats Jev's recorder.

### On the Taifoon devnet (chain 36927)

```bash
R=https://rpc.taifoon.dev
FOUNDRY_EVM_VERSION=paris forge create src/coord/sdk/examples/AgentJob.sol:AgentJob --rpc-url $R --private-key <your devnet key> --broadcast \
  --constructor-args <token> 0x3574999dd4c96eB73Bd6e11D4177010C83E14f5b 49 18953 <decision log> <recorder> \
  0xD00892925F085b366d82B8B577B1b303B7b1b3f9 $(cast keccak taifoon_coord)
```

Gas on the devnet comes from its faucet: `curl -X POST https://faucet.taifoon.dev/claim -d '{"address":"0x…"}'`. The devnet is
pre-Shanghai, so build with `evm_version = "paris"`.

## The off-chain half

`offchain/agent-job.mjs` reads the same job through the coordination API, with no dependencies (Node 18+):

```bash
node examples/agent-job/offchain/agent-job.mjs <AgentJob address> <job id string> [--rpc <url>] [--key <tfr_ key>]
```

1. the fee rule, from the live quote `GET https://coord.taifoon.dev/v1/fees/quote?price=10`
2. a free key (`POST https://coord.taifoon.dev/v1/register`) when you pass none — one per caller per day
3. the job's state on chain and the number of Jev decisions on it in the log
4. the job's envelopes on the coord stream (`GET /v1/pipe/stream?order_keys=…`, with the key)

Pricing and paid plans: https://www.taifoon.io/pricing
