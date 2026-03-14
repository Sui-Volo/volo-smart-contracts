#[allow(deprecated_usage)]
module volo_vault::cetus_adaptor;

use cetusclmm::pool::Pool as CetusPool;
use cetusclmm::position::Position as CetusPosition;
use std::ascii::String;
use std::type_name::{get, into_string};
use std::u256::pow;
use sui::clock::Clock;
use volo_vault::vault::Vault;
use volo_vault::vault_oracle::{Self, OracleConfig};
use volo_vault::vault_utils;

const DECIMAL: u256 = 1_000_000_000_000_000_000;

const SLIPPAGE_BASE: u256 = 10_000; // 10000 = 100%

const ERR_INVALID_POOL_PRICE: u64 = 6_001;

public fun update_cetus_position_value<PrincipalCoinType, CoinA, CoinB>(
    vault: &mut Vault<PrincipalCoinType>,
    config: &OracleConfig,
    clock: &Clock,
    asset_type: String,
    pool: &mut CetusPool<CoinA, CoinB>,
) {
    let cetus_position = vault.get_defi_asset_inner<PrincipalCoinType, CetusPosition>(asset_type);
    let usd_value = calculate_cetus_position_value(pool, cetus_position, config, clock);

    vault.finish_update_asset_value(asset_type, usd_value, clock.timestamp_ms());
}

// Calculate the usd value of a cetus position (coinA value + coinB value)
public fun calculate_cetus_position_value<CoinTypeA, CoinTypeB>(
    pool: &mut CetusPool<CoinTypeA, CoinTypeB>,
    position: &CetusPosition,
    config: &OracleConfig,
    clock: &Clock,
): u256 {
    let position_id = object::id(position);

    let (amount_a, amount_b) = pool.get_position_amounts(position_id);

    let type_name_a = into_string(get<CoinTypeA>());
    let type_name_b = into_string(get<CoinTypeB>());

    let decimals_a = config.coin_decimals(type_name_a);
    let decimals_b = config.coin_decimals(type_name_b);

    // Oracle price has 18 decimals
    let price_a = vault_oracle::get_asset_price(config, clock, type_name_a);
    let price_b = vault_oracle::get_asset_price(config, clock, type_name_b);
    let relative_price_from_oracle = price_a * DECIMAL / price_b;

    // e.g. For SUI-USDC Pool, decimal_a = 9, decimal_b = 6
    // pool price = 3e18
    // price_a = 3e18
    // price_b = 1e18
    // relative_price_from_oracle = 3e18 * 1e18 / 1e18 = 3e18

    // pool price = price_a / price_b (not consider decimals)
    let pool_price = sqrt_price_x64_to_price(pool.current_sqrt_price(), decimals_a, decimals_b);
    let slippage = config.dex_slippage();
    assert!(
        (pool_price.diff(relative_price_from_oracle) * DECIMAL  / relative_price_from_oracle) < (DECIMAL  * slippage / SLIPPAGE_BASE),
        ERR_INVALID_POOL_PRICE,
    );

    let normalized_price_a = vault_oracle::get_normalized_asset_price(config, clock, type_name_a);
    let normalized_price_b = vault_oracle::get_normalized_asset_price(config, clock, type_name_b);

    let value_a = vault_utils::mul_with_oracle_price(amount_a as u256, normalized_price_a);
    let value_b = vault_utils::mul_with_oracle_price(amount_b as u256, normalized_price_b);

    value_a + value_b
}

// Calculate a price between coinA and coinB with DECIMALS precision
fun sqrt_price_x64_to_price(sqrt_price_x64: u128, decimals_a: u8, decimals_b: u8): u256 {
    let sqrt_price_u256_with_decimals = (sqrt_price_x64 as u256) * DECIMAL / pow(2, 64);
    let price_u256_with_decimals =
        sqrt_price_u256_with_decimals * sqrt_price_u256_with_decimals / DECIMAL;

    if (decimals_a > decimals_b) {
        price_u256_with_decimals * pow(10, (decimals_a - decimals_b))
    } else {
        price_u256_with_decimals / pow(10, (decimals_b - decimals_a))
    }
}
