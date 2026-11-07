# BatchDistributeHook

A PancakeSwap Infinity CL hook that lets pool operators **push** tokens to up to 200 recipients in a single transaction by routing transfers through [Spraay](https://spraay.app)'s on-chain batch contract.

## Push vs. pull distribution

PancakeSwap's existing reward flows are **pull-based**. Farms, CAKE emissions, veCAKE rewards and `donate()` all credit value to a position, and each LP or staker has to claim it themselves. This scales well for large, open sets of participants, but it has drawbacks for smaller, targeted programs:

- Every recipient pays gas to claim, so small rewards often go unclaimed.
- Recipients who are not LPs (contributors, market makers, community members, partner treasuries) cannot be paid through the pool at all.
- Every program needs a claim UI and someone to tell recipients to use it.

`BatchDistributeHook` adds a **push** model next to these flows. The pool operator works out the recipient list off-chain (for example from a liquidity snapshot, volume, or a contributor list) and delivers everything in one call. Recipients do nothing and pay no gas. Each distribution is tied on-chain to the Infinity pool it belongs to.

|                     | Pull (farms / `donate`)        | Push (`BatchDistributeHook`)            |
| ------------------- | ------------------------------ | --------------------------------------- |
| Who pays gas        | Each recipient, on claim       | The operator, once per batch            |
| Eligible recipients | Positions in the pool          | Any address                             |
| Allocation logic    | On-chain (pro-rata, in range)  | Off-chain, decided by the operator      |
| Recipient action    | Claim                          | None                                    |
| Best for            | Open, continuous incentives    | Targeted payouts, airdrops, revenue shares |

The two models work together. A pool can keep its farm or donations running while the operator uses this hook for one-off or targeted payouts.

## How it works

```
operator ──batchDistribute(poolId, token, recipients, amounts)──▶ BatchDistributeHook
                                                                    │ 1. check operator, pool, ≤200 recipients
                                                                    │ 2. quote amount + Spraay fee
                                                                    │ 3. pull exactly that from operator
                                                                    │ 4. approve Spraay for exactly that
                                                                    ▼
                                                   Spraay.sprayToken / sprayETH / sprayEqual
                                                                    │
                                              ┌──────────┬──────────┼──────────┬──────────┐
                                              ▼          ▼          ▼          ▼          ▼
                                          recipient₁ recipient₂    ...    recipient₂₀₀  fee recipient
```

- **Non-custodial.** The hook holds no funds between calls. Each call pulls exactly `amount + fee` from the operator, approves Spraay for exactly that amount, and Spraay uses all of it. Excess native currency is refunded in the same transaction.
- **Pool-attributed.** `afterInitialize` registers every pool created with this hook, and distributions must reference a registered `PoolId`. `afterDonate` emits `PoolDonation`, so indexers can see pull-side and push-side incentives for the same pool.
- **No effect on swaps or liquidity.** Only `afterInitialize` and `afterDonate` are registered, so swaps and liquidity changes in the pool cost no extra gas.

### Hook permissions

| Callback          | Enabled | Purpose                                   |
| ----------------- | ------- | ----------------------------------------- |
| `afterInitialize` | ✅      | Register the pool for distributions       |
| `afterDonate`     | ✅      | Emit `PoolDonation` for indexing          |
| everything else   | ❌      |                                           |

## Interface

```solidity
// token == address(0) distributes the native currency (BNB / ETH)
function batchDistribute(PoolId poolId, address token, address[] calldata recipients, uint256[] calldata amounts)
    external payable;                                   // → Spraay.sprayToken / sprayETH

function batchDistributeEqual(PoolId poolId, address token, address[] calldata recipients, uint256 amountEach)
    external payable;                                   // → Spraay.sprayEqual

function quoteTotalCost(uint256 totalAmount) external view returns (uint256); // amount + Spraay fee

// owner only
function setSpraayContract(address newSpraay) external;
function setOperator(address operator, bool allowed) external;
function rescueTokens(address token, address to, uint256 amount) external;
```

**Roles:**

- **Owner** (`Ownable2Step`) manages operators, can point the hook at a new Spraay deployment, and can recover tokens sent to the hook by mistake. The owner is not automatically an operator.
- **Operators** trigger distributions and fund them.

**Funding a distribution:**

- **ERC-20:** `approve(hook, quoteTotalCost(sum(amounts)))`, then call `batchDistribute`.
- **Native:** send `msg.value >= quoteTotalCost(sum(amounts))`. The hook refunds any excess.

## Spraay fee

Spraay charges `feeBps` (currently **30 bps = 0.3%**) **on top of** the distributed amount. Recipients receive exactly the amounts specified, and the operator pays `total + total * feeBps / 10_000`. The hook reads the fee from Spraay at call time through `calculateTotalCost`, so a fee change on Spraay's side needs no change to the hook. Spraay caps `feeBps` at 500.

## Deployments

| Chain     | Spraay (`SprayContract`)                     | CLPoolManager                                |
| --------- | -------------------------------------------- | -------------------------------------------- |
| BNB Chain | `0x3093a2951FB77b3beDfB8BA20De645F7413432C1` | `0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b` |
| Base      | `0x4B1d57EBFaBDF3F21F30f210a1d95f649E9edD4c` | `0xa0FfB9c1CE1Fe56963B0321B32E7A0302114058b` |

Both Spraay contracts are verified on Sourcify (exact match) and have identical source. The addresses are also available in Solidity via `SpraayAddresses.sol` and in `script/config/{bsc,base}-mainnet.json`.

```sh
SCRIPT_CONFIG=bsc-mainnet HOOK_OWNER=<owner> HOOK_OPERATOR=<operator> PRIVATE_KEY=<key> \
forge script script/06_DeployBatchDistributeHook.s.sol:DeployBatchDistributeHookScript \
    --rpc-url $RPC_URL --broadcast --slow
```

The script deploys through PancakeSwap's Create3Factory when the deployer is whitelisted on it. Otherwise it deploys directly.

## Tests

```sh
forge test --match-contract BatchDistributeHookTest

# against the live Spraay + Infinity deployments
RPC_BSC_MAINNET=<bsc rpc> RPC_BASE_MAINNET=<base rpc> forge test --match-contract BatchDistributeHookForkTest
```

The unit tests use `test/pool-cl/helpers/MockSpraay.sol`, a copy of the verified Spraay source in which only the import paths and the contract name are changed.

## Limitations

- Fee-on-transfer and rebasing tokens are not supported, because Spraay pulls the exact gross amount.
- Each call is limited to 200 recipients (Spraay's `MAX_RECIPIENTS`). Larger lists must be split across several calls.
- In a native distribution, a recipient contract that rejects the payment makes the whole batch revert. Spraay does not skip failed recipients.
- Allocation is trusted to the operator. The hook enforces who can distribute, not who should receive.
