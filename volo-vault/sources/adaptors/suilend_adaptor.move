module volo_vault::suilend_adaptor;

use std::ascii::String;
use sui::clock::Clock;
use suilend::lending_market::{LendingMarket, ObligationOwnerCap as SuilendObligationOwnerCap};
use suilend::obligation::{Obligation};
use suilend::reserve::{Self};
use volo_vault::vault::Vault;

const DECIMAL: u256 = 1_000_000_000;

// @dev Need to update the price of the reserve before calling this function
//      Update function: lending_market::refresh_reserve_price
//          public fun refresh_reserve_price<P>(
//              lending_market: &mut LendingMarket<P>,
//              reserve_array_index: u64,
//              clock: &Clock,
//              price_info: &PriceInfoObject,
//           )

// Obligation type is type of suilend lending_market
// e.g. Obligation<suilend::main_market>
public fun update_suilend_position_value<PrincipalCoinType, ObligationType>(
    vault: &mut Vault<PrincipalCoinType>,
    lending_market: &mut LendingMarket<ObligationType>,
    clock: &Clock,
    asset_type: String,
) {
    let obligation_cap = vault.get_defi_asset_inner<
        PrincipalCoinType,
        SuilendObligationOwnerCap<ObligationType>,
    >(
        asset_type,
    );

    suilend_compound_interest(obligation_cap, lending_market, clock);
    let usd_value = parse_suilend_obligation(obligation_cap, lending_market, clock);

    vault.finish_update_asset_value(asset_type, usd_value, clock.timestamp_ms());
}

public(package) fun parse_suilend_obligation<ObligationType>(
    obligation_cap: &SuilendObligationOwnerCap<ObligationType>,
    lending_market: &LendingMarket<ObligationType>,
    clock: &Clock,
): u256 {
    let obligation = lending_market.obligation(obligation_cap.obligation_id());

    let mut total_deposited_value_usd = 0;
    let mut total_borrowed_value_usd = 0;
    let reserves = lending_market.reserves();

    obligation.deposits().do_ref!(|deposit| {
        let deposit_reserve = &reserves[deposit.reserve_array_index()];

        deposit_reserve.assert_price_is_fresh(clock);

        let market_value = reserve::ctoken_market_value(
            deposit_reserve,
            deposit.deposited_ctoken_amount(),
        );
        total_deposited_value_usd = total_deposited_value_usd + market_value.to_scaled_val();
    });

    obligation.borrows().do_ref!(|borrow| {
        let borrow_reserve = &reserves[borrow.reserve_array_index()];

        borrow_reserve.assert_price_is_fresh(clock);

        let cumulative_borrow_rate = borrow.cumulative_borrow_rate();
        let new_cumulative_borrow_rate = reserve::cumulative_borrow_rate(borrow_reserve);

        let new_borrowed_amount = borrow
            .borrowed_amount()
            .mul(new_cumulative_borrow_rate.div(cumulative_borrow_rate));

        let market_value = reserve::market_value(
            borrow_reserve,
            new_borrowed_amount,
        );

        total_borrowed_value_usd = total_borrowed_value_usd + market_value.to_scaled_val();
    });

    if (total_deposited_value_usd < total_borrowed_value_usd) {
        return 0
    };
    (total_deposited_value_usd - total_borrowed_value_usd) / DECIMAL
}

fun suilend_compound_interest<ObligationType>(
    obligation_cap: &SuilendObligationOwnerCap<ObligationType>,
    lending_market: &mut LendingMarket<ObligationType>,
    clock: &Clock,
) {
    let obligation = lending_market.obligation(obligation_cap.obligation_id());
    let reserve_array_indices = get_reserve_array_indicies(obligation);

    reserve_array_indices.do_ref!(|reserve_array_index| {
        lending_market.compound_interest(*reserve_array_index, clock);
    });
}

fun get_reserve_array_indicies<ObligationType>(
    obligation: &Obligation<ObligationType>,
): vector<u64> {
    let mut array_indices = vector::empty<u64>();

    obligation.deposits().do_ref!(|deposit| {
        vector::push_back(&mut array_indices, deposit.reserve_array_index());
    });

    obligation.borrows().do_ref!(|borrow| {
        vector::push_back(&mut array_indices, borrow.reserve_array_index());
    });

    array_indices
}
