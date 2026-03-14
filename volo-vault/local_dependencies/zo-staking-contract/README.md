# zo-staking-contract

A Move package that implements a generic staking pool. Users stake a coin type `S` to earn rewards paid in a coin type `R`. The pool is configured with a start time, end time, lock duration, and a reward rate. Internally the pool tracks an accumulated reward-per-share value over time and issues a `Credential<S, R>` object to each staker that represents their position.

This README explains the core user operations: `deposit`, `withdraw`, `withdraw_ptb`, `claim_rewards`, and `claim_rewards_ptb`.

## Concepts
- `Pool<S, R>`: The staking pool for stake coin `S` and reward coin `R`. It maintains `reward_rate`, `start_time`, `end_time`, `lock_duration`, `staked_amount`, and `reward_vault`.
- `Credential<S, R>`: The staker’s position object minted on deposit. It holds:
  - `lock_until`: When the position unlocks (based on `timestamp + lock_duration`).
  - `acc_reward_per_share`: Snapshot of the pool’s accumulator at deposit or last claim.
  - `stake`: The staked balance belonging to the user.
- Accumulator: `acc_reward_per_share` tracks rewards per unit of stake. It is advanced on each interaction via `refresh_pool`.
- Unlocking Rule: Withdrawing and claiming are only allowed once the current timestamp is greater than or equal to `min(lock_until, end_time)`.

## Operations

### deposit
- Signature: `public fun deposit<S, R>(pool: &mut Pool<S, R>, clock: &Clock, stake: Coin<S>, ctx: &mut TxContext)`
- Preconditions:
  - Pool is enabled.
  - Current timestamp is between `start_time` and `end_time`.
  - `stake` value is greater than 0.
- Behavior:
  - Refreshes the pool to update `acc_reward_per_share`.
  - Computes `lock_until = timestamp + lock_duration`.
  - Mints a `Credential<S, R>` to the sender with:
    - The stake moved into the credential’s `stake` balance.
    - A snapshot of the current `acc_reward_per_share`.
    - The computed `lock_until`.
  - Increases `pool.staked_amount` by the deposited amount.
  - Emits `event::deposit<S, R>(user, deposit_amount, lock_until)`.
- Result:
  - The caller receives a new `Credential<S, R>` object representing their position.

### withdraw
- Signature: `public fun withdraw<S, R>(pool: &mut Pool<S, R>, clock: &Clock, mut credential: Credential<S, R>, withdraw_amount: u64, ctx: &mut TxContext)`
- Purpose: One-call convenience to claim rewards and withdraw stake, paying both out to the user.
- Preconditions:
  - Pool version is valid.
  - Position is unlocked: `timestamp >= min(credential.lock_until, pool.end_time)`.
  - `withdraw_amount` is less than or equal to the staked amount.
- Behavior:
  - Internally calls `claim_rewards_ptb` to compute and extract reward coins from the pool.
  - Internally calls `withdraw_ptb` to extract the requested stake from the credential.
  - Pays both the reward and unstaked balance directly to the sender.
  - If the credential is now empty, it is destroyed; otherwise it is transferred back to the user.
  - Emits `event::withdraw<S, R>(user, withdraw_amount, 0)` (withdraw-only event; reward is emitted in `claim_rewards_ptb`).
- Result:
  - The caller receives both the rewards and the withdrawn stake in their account.

### withdraw_ptb
- Signature: `public fun withdraw_ptb<S, R>(pool: &mut Pool<S, R>, clock: &Clock, credential: &mut Credential<S, R>, withdraw_amount: u64, ctx: &mut TxContext): Coin<S>`
- Purpose: Programmatic Transaction Block (PTB) friendly withdraw that returns the unstaked coin so you can route or compose it within the same transaction.
- Preconditions:
  - Pool is enabled.
  - Position is unlocked: `timestamp >= min(credential.lock_until, pool.end_time)`.
  - `withdraw_amount` is less than or equal to the credential’s staked balance.
- Behavior:
  - Refreshes the pool accumulator.
  - Splits `withdraw_amount` from the credential’s `stake` balance.
  - Decreases `pool.staked_amount` by the withdrawn amount.
  - Emits `event::withdraw<S, R>(user, withdraw_amount, 0)`.
- Result:
  - Returns `Coin<S>` representing the unstaked amount. The caller can forward or combine this coin in the same PTB.

### claim_rewards
- Signature: `public fun claim_rewards<S, R>(pool: &mut Pool<S, R>, clock: &Clock, credential: &mut Credential<S, R>, ctx: &mut TxContext)`
- Purpose: One-call convenience to claim rewards and immediately pay them to the user.
- Preconditions:
  - Pool version is valid.
  - Position is unlocked: `timestamp >= min(credential.lock_until, pool.end_time)`.
- Behavior:
  - Internally calls `claim_rewards_ptb` to compute and extract the reward coin from the pool.
  - Pays the reward coin to the sender.
- Result:
  - Rewards are transferred to the user’s account; no coin is returned to the PTB.

### claim_rewards_ptb
- Signature: `public fun claim_rewards_ptb<S, R>(pool: &mut Pool<S, R>, clock: &Clock, credential: &mut Credential<S, R>, ctx: &mut TxContext): Coin<R>`
- Purpose: PTB-friendly reward claim that returns the reward coin for composition.
- Preconditions:
  - Pool is enabled.
  - Position is unlocked: `timestamp >= min(credential.lock_until, pool.end_time)`.
- Behavior:
  - Refreshes the pool accumulator.
  - Calculates pending rewards:
    - `pending = (pool.acc_reward_per_share - credential.acc_reward_per_share) * staked_amount / SCALE_FACTOR`.
  - Updates `credential.acc_reward_per_share` to the current pool accumulator.
  - Caps the reward to what’s available in `reward_vault` via `min_reward`.
  - Splits the reward from `pool.reward_vault` and emits `event::claim_reward<S, R>(user, reward_amount)`.
- Result:
  - Returns `Coin<R>` containing the claimed rewards. The caller can route this coin within the same PTB, or pay it to the user in a subsequent step.

## When to Use PTB Variants
- Use `withdraw_ptb` and `claim_rewards_ptb` when you need to:
  - Compose outputs in the same transaction (e.g., forward the unstaked or reward coin to another recipient or contract).
  - Batch multiple actions atomically in a PTB and control coin routing manually.
- Use `withdraw` and `claim_rewards` when you prefer a single call that pays out to your address without extra composition.

## Events
The pool emits the following relevant events during user operations:
- `event::deposit<S, R>(user, deposit_amount, lock_until)`
- `event::withdraw<S, R>(user, withdraw_amount, 0)`
- `event::claim_reward<S, R>(user, reward_amount)`

Administrative operations emit additional events (e.g., `set_reward_rate`, `set_lock_duration`, and versioning events), which are out of scope for this user-focused overview.

## Notes
- All time checks use seconds derived from `clock::timestamp_ms(clock) / 1000`.
- Pool interactions call `refresh_pool` to advance the accumulator; reward calculations rely on `SCALE_FACTOR` and safe math bounds.
- The pool must be enabled to accept deposits, allow PTB claims, and PTB withdrawals.
- Unlocking depends on both the `lock_duration` and the pool’s `end_time`.

