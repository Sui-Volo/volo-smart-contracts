// ^(v1.1 upgrade - new)
module volo_vault::zo_adaptor;

use std::ascii::String;
use std::type_name;
use sui::clock::Clock;
use volo_vault::vault::Vault;
use volo_vault::vault_oracle::OracleConfig;
use volo_vault::vault_utils;
use zo_staking::pool::{CredentialV2, Pool};

const SCALE_FACTOR: u128 = 1_000_000_000_000_000_000;
const MAX_LOCK_DURATION: u64 = 365 * 24 * 60 * 60; // 1 year (in seconds)

const ERR_INVALID_LOCK_DURATION: u64 = 9_001;

public fun update_zo_position_value<PrincipalCoinType, StakeCoinType, RewardCoinType>(
    vault: &mut Vault<PrincipalCoinType>,
    config: &OracleConfig,
    clock: &Clock,
    asset_type: String,
    pool: &mut Pool<StakeCoinType, RewardCoinType>,
    // credential: &CredentialV2<StakeCoinType, RewardCoinType>,
) {
    let now = clock.timestamp_ms();
    let now_in_seconds = now / 1_000;

    let credential = vault.get_defi_asset_inner<PrincipalCoinType, CredentialV2<StakeCoinType, RewardCoinType>>(asset_type);

    let lock_until = credential.credential_v2_lock_until();
    if (lock_until >= now_in_seconds) {
        assert!(lock_until - now_in_seconds < MAX_LOCK_DURATION, ERR_INVALID_LOCK_DURATION);
    };

    let usd_value = get_zo_position_value(pool, credential, config, clock);
    vault.finish_update_asset_value(asset_type, usd_value, now);
}

public fun get_zo_position_value<StakeCoinType, RewardCoinType>(
    pool: &Pool<StakeCoinType, RewardCoinType>,
    credential: &CredentialV2<StakeCoinType, RewardCoinType>,
    config: &OracleConfig,
    clock: &Clock,
): u256 {
    let pending_reward_per_share =
        pool.pool_acc_reward_per_share() - credential.credential_v2_acc_reward_per_share();
    let reward_amount =
        (
            ((pending_reward_per_share as u256) * (credential.credential_v2_staked_amount() as u256)) / (SCALE_FACTOR as u256),
        ) as u128;

    let reward_token_type_string = type_name::into_string(
        type_name::with_defining_ids<RewardCoinType>(),
    );
    let reward_token_price = config.get_normalized_asset_price(clock, reward_token_type_string);

    let reward_token_value = vault_utils::mul_with_oracle_price(
        reward_amount as u256,
        reward_token_price,
    );

    let stake_token_type_string = type_name::into_string(
        type_name::with_defining_ids<StakeCoinType>(),
    );
    let stake_token_price = config.get_normalized_asset_price(clock, stake_token_type_string);

    let stake_token_value = vault_utils::mul_with_oracle_price(
        credential.credential_v2_stake_ref().value() as u256,
        stake_token_price,
    );

    reward_token_value + stake_token_value
}