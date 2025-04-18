module steamm::utils;

use std::string::{Self, String, substring};
use std::ascii::{Self};
use std::type_name;
use suilend::decimal::{Self, Decimal};
use steamm::fixed_point64::{Self as fp64, FixedPoint64};
use oracles::oracle_decimal::{OracleDecimal};

const WAD: u256 = 1000000000000000000;
const SCALE_64: u256 = 18446744073709551616;
const MAX_U128: u256 = 340282366920938463463374607431768211455;

const EOutOfRange: u64 = 1;

public(package) fun get_type_reflection<T>(): String {
    let t = string::utf8(ascii::into_bytes(
        type_name::into_string(type_name::get<T>())
    ));

    let delimiter = string::utf8(b"::");
    let package_delimiter_index = string::index_of(&t, &delimiter);
    let tail = substring(&t, package_delimiter_index + 2, string::length(&t));
    let module_delimiter_index = string::index_of(&tail, &delimiter);

    let type_name = substring(&tail, module_delimiter_index + 2, string::length(&tail));

    type_name
}


public(package) fun decimal_to_fixedpoint64(d: Decimal): FixedPoint64 {
    let decimal_value: u256 = decimal::to_scaled_val(d);

    // Note: It's safe to upscale the decimal value, given that
    // the maximum value inside a decimal type is MAX_U64 * WAD which is
    // roughly ≈ 1.844 × 10^37
    //
    // Multiplying it by 2^64 (SCALE_64) gives us a value of 3.4 × 10^56 which
    // is smaller than MAX_U256 (1.1579 × 10^77)
    let scaled_value: u256 = (decimal_value * SCALE_64) / WAD;
    assert!(scaled_value <= MAX_U128, EOutOfRange);
    fp64::from_raw_value(scaled_value as u128)
}

public(package) fun oracle_decimal_to_decimal(price: OracleDecimal): Decimal {
    if (price.is_expo_negative()) {
        decimal::from_u128(price.base()).div(decimal::from(10u64.pow(price.expo() as u8)))
    } else {
        decimal::from_u128(price.base()).mul(decimal::from(10u64.pow(price.expo() as u8)))
    }
}