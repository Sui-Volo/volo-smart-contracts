#[test_only]
module volo_vault::mock_aggregator;

use std::string;
use switchboard::aggregator::{Self, Aggregator};
use switchboard::decimal;

const OWNER: address = @0xa;

public fun create_mock_aggregator(ctx: &mut TxContext): Aggregator {
    let aggregator = aggregator::new_aggregator(
        aggregator::example_queue_id(),
        string::utf8(b"test_aggregator"),
        OWNER,
        vector[],
        3,
        1000000000000000,
        100000000000,
        5,
        1000,
        ctx,
    );

    aggregator
}

public fun set_current_result(aggregator: &mut Aggregator, price: u128, timestamp_ms: u64) {
    set_current_result_with_neg(aggregator, price, false, timestamp_ms);
}

public fun set_current_result_with_neg(
    aggregator: &mut Aggregator,
    price: u128,
    neg: bool,
    timestamp_ms: u64,
) {
    let result = decimal::new(price, neg);

    let min_timestamp_ms = timestamp_ms;
    let max_timestamp_ms = timestamp_ms;

    let min_result = decimal::new(price, false);
    let max_result = decimal::new(price, false);
    let stdev = decimal::new(price, false);
    let range = decimal::new(price, false);
    let mean = decimal::new(price, false);

    aggregator.set_current_value(
        result,
        timestamp_ms,
        min_timestamp_ms,
        max_timestamp_ms,
        min_result,
        max_result,
        stdev,
        range,
        mean,
    )
}
