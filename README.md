# taifoon-contracts

Solidity for coordinating with the Taifoon layer from a contract: the interfaces of the deployed modules, a call-site library
(`TaifoonCoord`), the payment scheme's on-chain fee rule and leg check, the envelope hashes the coord pipe uses, the addresses and where
each module is deployed, and one example (`examples/agent-job`).

```bash
forge install taifoon-io/taifoon-contracts
```

```solidity
import {TaifoonCoord} from "taifoon-contracts/src/coord/sdk/TaifoonCoord.sol";
import {TaifoonAddresses} from "taifoon-contracts/src/coord/sdk/TaifoonAddresses.sol";

address verifier = TaifoonAddresses.requireLive(block.chainid, TaifoonAddresses.Module.Verifier); // reverts NotLive where absent
```

## Where each piece is deployed

The economy modules have one address on every EVM chain (`src/coord/sdk/Deployments.sol`); this table is where each has been deployed,
read from the address registry when this package was generated. `TaifoonAddresses.isLive(chainId, module)` answers the same on chain.

| chain | Anchor | Lambda | Verifier | TsulDonut | PaymentChannel | Workflow | Assurance hook | Jev V5 adapter | Jev decision log |
|---|---|---|---|---|---|---|---|---|---|
| Gnosis (100) | — | — | — | yes | — | — | — | — | — |
| Monad (143) | — | — | — | — | — | — | yes | — | yes |
| Robinhood Chain (4663) | — | — | — | — | — | — | yes | — | — |
| Arc (5042) | — | — | — | — | — | — | yes | — | yes |
| Base (8453) | yes | yes | yes | yes | yes | yes | yes | yes | yes |
| Taifoon devnet (36927) | yes | yes | yes | yes | yes | yes | — | — | — |
| Arbitrum One (42161) | — | — | — | — | — | — | yes | — | yes |
| Taifoon mainnet (3692781) | yes | yes | yes | yes | yes | yes | — | — | — |

| constant | address |
|---|---|
| `ANCHOR` | `0x457D583b3A409D6DC8421ca6d3FB67ceb94718ad` |
| `LAMBDA` | `0x6701257d271fFC7C214d7dEBb72c3C6996b293e8` |
| `VERIFIER` | `0xD00892925F085b366d82B8B577B1b303B7b1b3f9` |
| `TSUL_DONUT` | `0xBB14351B345d8D518A605EDD0406723a88A18787` |
| `VAULT` | `0x3574999dd4c96eB73Bd6e11D4177010C83E14f5b` |
| `SAFE` | `0x14C4274110F1c183Eec6095F3E6547790A258fae` |
| `PAYMENT_CHANNEL` | `0x78009091C0EE2fc3a259995A19425FC94a6988d1` |
| `WORKFLOW` | `0x5F7ddB935D8C2e85BbA502De7c91b14b31CB17bE` |

## What is in it

| path | what |
|---|---|
| `src/coord/sdk/interface.sol` | the deployed modules' interfaces (verifier, anchor, payment channel, workflow, quote, TsulDonut) |
| `src/interfaces/` | Jev's decision log, Jev's V5 evaluator seat, the assurance hook's job view |
| `src/coord/sdk/TaifoonCoord.sol` | one call site per capability: prove an order, open/settle a channel, register/advance a workflow, `listPriceOf` / `feeOf` / `checkLegs` (the payment scheme's fee rule and Σ legs), `distributionFor` |
| `src/coord/sdk/TaifoonAddresses.sol` | where each module has landed, per chain; per-chain addresses of the assurance hook and Jev |
| `src/lib/TaifoonEnvelope.sol` | the envelope digests of the coord pipe (keccak256 of canonical JSON), tested against the pipe's own vectors |
| `examples/agent-job` | hire an agent through a reseller, pay the legs when Jev decides or a proof lands |

The module sources under `src/v5`, `src/lib` and `src/coord` are the deployed contracts' code (no proxies; the council Safe owns
them). The assurance hooks are upgradeable proxies owned by the same Safe; only their job view is here.

## Test

```bash
forge install foundry-rs/forge-std@v1.15.0 --no-git
forge test                                   # unit + the 43 envelope vectors + invariants
BASE_RPC_URL=https://mainnet.base.org forge test --match-contract AgentJobBaseForkTest   # against Base: the live Jev log and V5
```

## The API next to it

The same jobs, proofs and envelopes are read and streamed through the coordination API at `https://coord.taifoon.dev/v1`
(a free key: `curl -X POST https://coord.taifoon.dev/v1/register`), its MCP server `https://coord.taifoon.dev/mcp`, and the CLI
`npx @taifoon/cli`. Pricing: https://www.taifoon.io/pricing

Generated from the Taifoon coord layer sources; changes go there, not here (see `GENERATED.json`).
