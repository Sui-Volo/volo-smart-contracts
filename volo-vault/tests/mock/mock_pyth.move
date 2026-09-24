#[test_only]
module volo_vault::mock_pyth;

use sui::package;
use sui::test_utils;

use pyth_pro_compatible::data_source;
use pyth_pro_compatible::i64;
use pyth_pro_compatible::price;
use pyth_pro_compatible::price_feed;
use pyth_pro_compatible::price_identifier;
use pyth_pro_compatible::price_info::{Self, PriceInfoObject};
use pyth_pro_compatible::state::{Self, State};
use wormhole_simple_majority::external_address;

// Pyth's own staleness gate. The vault oracle applies its own `update_interval` on top, and
// most tests want that one to be the binding constraint, so the default mock state is
// deliberately permissive; `create_state_with_threshold` exercises Pyth's gate directly.
const DEFAULT_STALE_PRICE_THRESHOLD_SECS: u64 = 1_000_000_000;
const BASE_UPDATE_FEE: u64 = 1;

// Real mainnet feed ids, so the tests pin the same constants the contract does.
const SUI_USD_PRICE_ID: address =
    @0x23d7315113f5b1d3ba7a83604c44b94d79f4fd69af77f804fc7f920a6dc65744;
const VSUI_SUI_RATE_PRICE_ID: address =
    @0x77a89fd7818905d056d1ba2a841868ad932fd32260a98a2205c5db28e02ea736;
const USDC_USD_PRICE_ID: address =
    @0xeaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a;
const BTC_USD_PRICE_ID: address =
    @0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;

public fun sui_usd_price_id(): address { SUI_USD_PRICE_ID }

public fun vsui_sui_rate_price_id(): address { VSUI_SUI_RATE_PRICE_ID }

public fun usdc_usd_price_id(): address { USDC_USD_PRICE_ID }

public fun btc_usd_price_id(): address { BTC_USD_PRICE_ID }

public fun create_state(ctx: &mut TxContext): State {
    create_state_with_threshold(DEFAULT_STALE_PRICE_THRESHOLD_SECS, ctx)
}

public fun create_state_with_threshold(
    stale_price_threshold_secs: u64,
    ctx: &mut TxContext,
): State {
    let upgrade_cap = package::test_publish(object::id_from_address(@0xbeef), ctx);
    let governance_data_source = data_source::new_data_source_for_test(
        1,
        external_address::default(),
    );

    state::new_state_for_test(
        upgrade_cap,
        governance_data_source,
        stale_price_threshold_secs,
        BASE_UPDATE_FEE,
        ctx,
    )
}

// A PriceInfoObject holding `price_magnitude * 10^-expo_magnitude` at `timestamp_secs`.
// Pyth crypto feeds publish a positive mantissa and a negative exponent; the `_signed`
// variant exists so tests can feed the oracle malformed values on purpose.
public fun create_price_info_object(
    price_id: address,
    price_magnitude: u64,
    expo_magnitude: u64,
    timestamp_secs: u64,
    ctx: &mut TxContext,
): PriceInfoObject {
    create_price_info_object_signed(
        price_id,
        price_magnitude,
        false,
        expo_magnitude,
        true,
        timestamp_secs,
        ctx,
    )
}

public fun create_price_info_object_signed(
    price_id: address,
    price_magnitude: u64,
    price_negative: bool,
    expo_magnitude: u64,
    expo_negative: bool,
    timestamp_secs: u64,
    ctx: &mut TxContext,
): PriceInfoObject {
    let identifier = price_identifier::from_byte_vec(price_id.to_bytes());
    let pyth_price = price::new(
        i64::new(price_magnitude, price_negative),
        0,
        i64::new(expo_magnitude, expo_negative),
        timestamp_secs,
    );
    let feed = price_feed::new(identifier, pyth_price, pyth_price);
    let info = price_info::new_price_info(timestamp_secs, timestamp_secs, feed);

    price_info::new_price_info_object_for_test(info, ctx)
}

// Same as create_price_info_object but with a caller-supplied confidence interval.
// The default constructors hardcode conf = 0, which hides any missing conf check in the
// oracle; this variant lets a test feed a wide-confidence (degraded) print on purpose.
public fun create_price_info_object_with_conf(
    price_id: address,
    price_magnitude: u64,
    conf: u64,
    expo_magnitude: u64,
    timestamp_secs: u64,
    ctx: &mut TxContext,
): PriceInfoObject {
    let identifier = price_identifier::from_byte_vec(price_id.to_bytes());
    let pyth_price = price::new(
        i64::new(price_magnitude, false),
        conf,
        i64::new(expo_magnitude, true),
        timestamp_secs,
    );
    let feed = price_feed::new(identifier, pyth_price, pyth_price);
    let info = price_info::new_price_info(timestamp_secs, timestamp_secs, feed);

    price_info::new_price_info_object_for_test(info, ctx)
}

public fun destroy_price_info_object(price_info_object: PriceInfoObject) {
    price_info::destroy(price_info_object)
}

public fun destroy_state(pyth_state: State) {
    std::unit_test::destroy(pyth_state)
}
