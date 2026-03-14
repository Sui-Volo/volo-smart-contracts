module volo_vault::vault_oracle;

use std::ascii::String;
use std::u64::pow;
use sui::clock::Clock;
use sui::event::emit;
use sui::table::{Self, Table};
use switchboard::aggregator::Aggregator;

// ---------------------  Constants  ---------------------//
// const VERSION: u64 = 2;
// ^(v1.1 upgrade - new)
const VERSION: u64 = 3;

const MAX_UPDATE_INTERVAL: u64 = 1000 * 60; // 1 minute

const DEFAULT_DEX_SLIPPAGE: u256 = 100; // 1%

// ---------------------  Errors  ---------------------//
const ERR_AGGREGATOR_NOT_FOUND: u64 = 2_001;
const ERR_PRICE_NOT_UPDATED: u64 = 2_002;
const ERR_AGGREGATOR_ALREADY_EXISTS: u64 = 2_003;
const ERR_AGGREGATOR_ASSET_MISMATCH: u64 = 2_004;
const ERR_INVALID_VERSION: u64 = 2_005;

// ---------------------  Structs  ---------------------//
public struct PriceInfo has drop, store {
    aggregator: address,
    decimals: u8,
    price: u256,
    last_updated: u64,
}

public struct OracleConfig has key, store {
    id: UID,
    version: u64,
    aggregators: Table<String, PriceInfo>,
    update_interval: u64,
    dex_slippage: u256, // Pool price and oracle price slippage parameter (used in adaptors related to DEX)
}

// ---------------------  Events  ---------------------//

public struct UpdateIntervalSet has copy, drop {
    update_interval: u64,
}

public struct DexSlippageSet has copy, drop {
    dex_slippage: u256,
}

// deprecated
#[allow(unused_field)]
public struct PriceUpdated has copy, drop {
    price: u256,
    timestamp: u64,
}

public struct SwitchboardAggregatorAdded has copy, drop {
    asset_type: String,
    aggregator: address,
}

public struct SwitchboardAggregatorRemoved has copy, drop {
    asset_type: String,
    aggregator: address,
}

public struct SwitchboardAggregatorChanged has copy, drop {
    asset_type: String,
    old_aggregator: address,
    new_aggregator: address,
}

public struct OracleConfigUpgraded has copy, drop {
    oracle_config_id: address,
    version: u64,
}

public struct AssetPriceUpdated has copy, drop {
    asset_type: String,
    price: u256,
    timestamp: u64,
}

// ---------------------  Initialization  ---------------------//
fun init(ctx: &mut TxContext) {
    let config = OracleConfig {
        id: object::new(ctx),
        version: VERSION,
        aggregators: table::new(ctx),
        update_interval: MAX_UPDATE_INTERVAL,
        dex_slippage: DEFAULT_DEX_SLIPPAGE,
    };

    transfer::share_object(config);
}

public(package) fun check_version(self: &OracleConfig) {
    assert!(self.version == VERSION, ERR_INVALID_VERSION);
}

public(package) fun upgrade_oracle_config(self: &mut OracleConfig) {
    assert!(self.version < VERSION, ERR_INVALID_VERSION);
    self.version = VERSION;

    emit(OracleConfigUpgraded {
        oracle_config_id: self.id.to_address(),
        version: VERSION,
    });
}

public(package) fun set_update_interval(config: &mut OracleConfig, update_interval: u64) {
    config.check_version();

    config.update_interval = update_interval;
    emit(UpdateIntervalSet { update_interval })
}

public(package) fun set_dex_slippage(config: &mut OracleConfig, dex_slippage: u256) {
    config.check_version();

    config.dex_slippage = dex_slippage;
    emit(DexSlippageSet { dex_slippage })
}

// ---------------------  Public Functions  ---------------------//

public fun get_asset_price(config: &OracleConfig, clock: &Clock, asset_type: String): u256 {
    config.check_version();

    assert!(table::contains(&config.aggregators, asset_type), ERR_AGGREGATOR_NOT_FOUND);

    let price_info = &config.aggregators[asset_type];
    let now = clock.timestamp_ms();

    // Price must be updated within update_interval
    assert!(price_info.last_updated.diff(now) < config.update_interval, ERR_PRICE_NOT_UPDATED);

    price_info.price
}

public fun get_normalized_asset_price(
    config: &OracleConfig,
    clock: &Clock,
    asset_type: String,
): u256 {
    let price = get_asset_price(config, clock, asset_type);
    let decimals = config.aggregators[asset_type].decimals;

    // Normalize price to 9 decimals
    if (decimals < 9) {
        price * (pow(10, 9 - decimals) as u256)
    } else {
        price / (pow(10, decimals - 9) as u256)
    }
}

// ------------------ Aggregator Management ------------------//

public(package) fun add_switchboard_aggregator(
    config: &mut OracleConfig,
    clock: &Clock,
    asset_type: String,
    decimals: u8,
    aggregator: &Aggregator,
) {
    config.check_version();

    assert!(!config.aggregators.contains(asset_type), ERR_AGGREGATOR_ALREADY_EXISTS);
    let now = clock.timestamp_ms();

    let init_price = get_current_price(config, clock, aggregator);

    let price_info = PriceInfo {
        aggregator: aggregator.id().to_address(),
        decimals,
        price: init_price,
        last_updated: now,
    };
    config.aggregators.add(asset_type, price_info);

    emit(SwitchboardAggregatorAdded {
        asset_type,
        aggregator: aggregator.id().to_address(),
    });
}

public(package) fun remove_switchboard_aggregator(config: &mut OracleConfig, asset_type: String) {
    config.check_version();
    assert!(config.aggregators.contains(asset_type), ERR_AGGREGATOR_NOT_FOUND);

    emit(SwitchboardAggregatorRemoved {
        asset_type,
        aggregator: config.aggregators[asset_type].aggregator,
    });

    config.aggregators.remove(asset_type);
}

public(package) fun change_switchboard_aggregator(
    config: &mut OracleConfig,
    clock: &Clock,
    asset_type: String,
    aggregator: &Aggregator,
) {
    config.check_version();
    assert!(config.aggregators.contains(asset_type), ERR_AGGREGATOR_NOT_FOUND);

    let init_price = get_current_price(config, clock, aggregator);

    let price_info = &mut config.aggregators[asset_type];

    emit(SwitchboardAggregatorChanged {
        asset_type,
        old_aggregator: price_info.aggregator,
        new_aggregator: aggregator.id().to_address(),
    });

    price_info.aggregator = aggregator.id().to_address();
    price_info.price = init_price;
    price_info.last_updated = clock.timestamp_ms();
}

// ------------------ Price Update ------------------//

// Update price inside vault_oracle (the switchboard aggregator price must be updated first)
public fun update_price(
    config: &mut OracleConfig,
    aggregator: &Aggregator,
    clock: &Clock,
    asset_type: String,
) {
    config.check_version();

    let now = clock.timestamp_ms();
    let current_price = get_current_price(config, clock, aggregator);

    let price_info = &mut config.aggregators[asset_type];
    assert!(price_info.aggregator == aggregator.id().to_address(), ERR_AGGREGATOR_ASSET_MISMATCH);

    price_info.price = current_price;
    price_info.last_updated = now;

    emit(AssetPriceUpdated {
        asset_type,
        price: current_price,
        timestamp: now,
    })
}

// Get current price from switchboard aggregator (the price must be updated within update_interval)
public fun get_current_price(config: &OracleConfig, clock: &Clock, aggregator: &Aggregator): u256 {
    config.check_version();

    let now = clock.timestamp_ms();
    let current_result = aggregator.current_result();

    let max_timestamp = current_result.max_timestamp_ms();

    if (now >= max_timestamp) {
        assert!(now - max_timestamp < config.update_interval, ERR_PRICE_NOT_UPDATED);
    };
    current_result.result().value() as u256
}

// ------------------ Getters ------------------//

public fun update_interval(config: &OracleConfig): u64 {
    config.update_interval
}

public fun coin_decimals(config: &OracleConfig, asset_type: String): u8 {
    config.aggregators[asset_type].decimals
}

public fun dex_slippage(config: &OracleConfig): u256 {
    config.dex_slippage
}

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun set_current_price(
    config: &mut OracleConfig,
    clock: &Clock,
    asset_type: String,
    price: u256,
) {
    let price_info = &mut config.aggregators[asset_type];

    price_info.price = price;
    price_info.last_updated = clock.timestamp_ms();
}

#[test_only]
public fun set_aggregator(
    config: &mut OracleConfig,
    clock: &Clock,
    asset_type: String,
    decimals: u8,
    aggregator: address,
) {
    let price_info = PriceInfo {
        aggregator: aggregator,
        decimals,
        price: 0,
        last_updated: clock.timestamp_ms(),
    };

    config.aggregators.add(asset_type, price_info);
}
