module volo_vault::vault_utils;

use std::ascii::String as AsciiString;
use std::string;
use std::type_name;
use sui::table::{Self, Table};
use sui::vec_map::VecMap;

const DECIMALS: u256 = 1_000_000_000; // 10^9
const ORACLE_DECIMALS: u256 = 1_000_000_000_000_000_000; // 10^18

// Combina a TypeName with an ID to generate its unique name
// E.g. NaviAccountCap1, NaviAccountCap2, etc.
#[allow(deprecated_usage)]
public fun parse_key<T>(idx: u8): AsciiString {
    let type_name_string_ascii = type_name::get<T>().into_string();
    let mut type_name_string = string::from_ascii(type_name_string_ascii);

    type_name_string.append(idx.to_string());
    type_name_string.to_ascii()
}

// mul with decimals
public fun mul_d(v1: u256, v2: u256): u256 {
    v1 * v2 / DECIMALS
}

// div with decimals
public fun div_d(v1: u256, v2: u256): u256 {
    v1 * DECIMALS / v2
}

public fun decimals(): u256 {
    DECIMALS
}

public fun to_decimals(v: u256): u256 {
    v * DECIMALS
}

public fun to_oracle_price_decimals(v: u256): u256 {
    v * ORACLE_DECIMALS
}

public fun from_oracle_price_decimals(v: u256): u256 {
    v / ORACLE_DECIMALS
}

public fun from_decimals(v: u256): u256 {
    v / DECIMALS
}

public fun clone_vecmap_table<T0: copy + drop + store, T1: copy + store>(
    t: &VecMap<T0, T1>,
    ctx: &mut TxContext,
): Table<T0, T1> {
    let mut t1 = table::new<T0, T1>(ctx);
    let keys = t.keys();
    let mut i = keys.length();
    while (i > 0) {
        let k = keys.borrow(i - 1);
        let v = *t.get(k);
        t1.add(*k, v);
        i = i - 1;
    };
    t1
}

// Asset USD Value = Asset Balance * Oracle Price
public fun mul_with_oracle_price(v1: u256, v2: u256): u256 {
    v1 * v2 / ORACLE_DECIMALS
}

// Asset Balance = Asset USD Value / Oracle Price
public fun div_with_oracle_price(v1: u256, v2: u256): u256 {
    v1 * ORACLE_DECIMALS / v2
}