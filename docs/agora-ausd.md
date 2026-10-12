# Agora AUSD

AUSD is a first-class dollar in waterlemon, alongside USDC. Every path that
moves or records dollars (on-ramp, sends, the feed, agent allowances,
off-ramp) works with AUSD without a special case.

## Token model

Internally a dollar asset is one config entry. The app, API and indexer all
read from the same table:

```ts
export const DOLLARS = {
  USDC: { address: USDC_ADDRESS, decimals: 6, symbol: 'USDC' },
  AUSD: { address: AUSD_ADDRESS, decimals: 6, symbol: 'AUSD' },
} as const;
```

AUSD is a standard 6-decimal ERC-20, so it follows the same code path as
USDC everywhere:

| Layer              | What changes for AUSD                                                  |
| ------------------ | ---------------------------------------------------------------------- |
| QuickNode filter   | AUSD's address is in `TOKENS`, so its `Transfer` logs are delivered    |
| Indexer            | Its own cursor in `chain_cursors`; transfers keyed by token address    |
| Balance projection | Per-token balances, reconciled against Multicall3 `balanceOf` reads   |
| API                | `GET /v1/balance` returns each dollar plus a combined USD total        |
| App                | Encodes `transfer` against the AUSD address compiled into the app      |
| AllowanceModule    | `token` is a field of each allowance, so an agent can be granted AUSD  |

## Flows

### Hold and see a combined balance

The home screen shows one dollar total, the sum of the USDC and AUSD
balances (both pegged 1:1, both 6 decimals). The breakdown is one tap away.
Each balance comes from the indexer's projection and is checked by the
Multicall3 reconciler, so the total never mixes indexed and guessed values.

### Send and receive AUSD

The sender picks the asset in the amount sheet. The app builds
`AUSD.transfer(recipient, amount)` as a sponsored user operation (see
[privy.md](privy.md#gas-sponsorship)), and the indexer turns the resulting
`Transfer` into a *sent* entry for one user and a *received* entry for the
other. The flow is the same as USDC; only the token address differs.

### Agent allowances in AUSD

[`AllowanceModule`](../contracts/src/AllowanceModule.sol) is token-agnostic.
Each allowance stores its own `token` address, and `spend()` encodes
`token.transfer(payee, amount)` through the account's ERC-7579 executor
path. Granting an agent "50 AUSD per day" is:

```solidity
// executed by the user's account in a sponsored user operation
module.createAllowance(id, CreateAllowanceParams({
    spender: agent,
    token: AUSD,
    cap: 50e6,          // 6 decimals
    period: 1 days,     // cap resets every day
    expiresAt: 0,       // no end date
    unrestricted: true, // any payee
    payees: new address[](0)
}));
```

The module's per-account delegated cap counts AUSD and USDC allowances
together, so no combination of grants can expose more than the account's
ceiling.

### On-ramp and off-ramp

Privy's funding flow takes the asset as a parameter, so buying AUSD by card
is the USDC flow with `asset: 'AUSD'`. Cash-out sends AUSD to the provider's
deposit address the same way. See [privy.md](privy.md#4-funding-on-ramp-and-off-ramp).

## Indexing

Adding a dollar is a config change, not a code change:

1. Add the address to the dollar table.
2. Regenerate the Streams filter (`stream:filter`) and paste it into the
   Stream. The worker refuses to drain against a filter that doesn't match
   its config (`filter-mismatch`).
3. Deploy. The new token's cursor starts at the configured start block, and
   the reconciler includes it in its next Multicall3 pass.
