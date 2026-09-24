#[test_only]
module volo_vault::mock_cetus;

use std::ascii::String;
use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use volo_vault::vault::Vault;
use volo_vault::vault_oracle::{Self, OracleConfig};
use volo_vault::vault_utils;

public struct MockCetusPosition<phantom CoinTypeA, phantom CoinTypeB> has key, store {
    id: UID,
    coin_type_a: TypeName,
    coin_type_b: TypeName,
    token_a_amount: u64,
    token_b_amount: u64,
}

public fun update_mock_cetus_position_value<PrincipalCoinType, CoinA, CoinB>(
    vault: &mut Vault<PrincipalCoinType>,
    config: &OracleConfig,
    clock: &Clock,
    asset_type: String,
) {
    let cetus_position = vault.get_defi_asset_inner<PrincipalCoinType, MockCetusPosition<CoinA, CoinB>>(
        asset_type,
    );

    let usd_value = calculate_cetus_position_value(cetus_position, config, clock);

    vault.finish_update_asset_value(asset_type, usd_value, clock.timestamp_ms());
}

public fun create_mock_position<CoinTypeA, CoinTypeB>(
    ctx: &mut TxContext,
): MockCetusPosition<CoinTypeA, CoinTypeB> {
    let position = MockCetusPosition {
        id: object::new(ctx),
        coin_type_a: type_name::with_defining_ids<CoinTypeA>(),
        coin_type_b: type_name::with_defining_ids<CoinTypeB>(),
        token_a_amount: 0,
        token_b_amount: 0,
    };
    position
}

public fun calculate_cetus_position_value<CoinTypeA, CoinTypeB>(
    position: &MockCetusPosition<CoinTypeA, CoinTypeB>,
    config: &OracleConfig,
    clock: &Clock,
): u256 {
    let type_name_a = type_name::with_defining_ids<CoinTypeA>().into_string();
    let type_name_b = type_name::with_defining_ids<CoinTypeB>().into_string();

    let amount_a = position.token_a_amount;
    let amount_b = position.token_b_amount;

    // Oracle price has 18 decimals
    let price_a = vault_oracle::get_normalized_asset_price(config, clock, type_name_a);
    let price_b = vault_oracle::get_normalized_asset_price(config, clock, type_name_b);

    let value_a = vault_utils::mul_with_oracle_price(amount_a as u256, price_a);
    let value_b = vault_utils::mul_with_oracle_price(amount_b as u256, price_b);

    value_a + value_b
}

public fun set_token_amount<CoinTypeA, CoinTypeB>(
    position: &mut MockCetusPosition<CoinTypeA, CoinTypeB>,
    amount_a: u64,
    amount_b: u64,
) {
    position.token_a_amount = amount_a;
    position.token_b_amount = amount_b;
}

public fun amount_a<CoinTypeA, CoinTypeB>(position: &MockCetusPosition<CoinTypeA, CoinTypeB>): u64 {
    position.token_a_amount
}

public fun amount_b<CoinTypeA, CoinTypeB>(position: &MockCetusPosition<CoinTypeA, CoinTypeB>): u64 {
    position.token_b_amount
}
