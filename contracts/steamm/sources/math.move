module steamm::math;

use std::option::{none, some};
use std::u64::min;
use suilend::decimal::Decimal;

const MAX_U64: u128 = 18_446_744_073_709_551_615u128;

// Result of operation exceeds maximum u64 value
const EMathOverflow: u64 = 0;
// Attempted division by zero
const EDivideByZero: u64 = 1;
// Both arguments to min_non_zero function are zero
const EInvalidMinArgs: u64 = 2;

public(package) fun abs_diff(x: Decimal, y: Decimal): Decimal {
    if (x.ge(y)) {
        x.sub(y)
    } else {
        y.sub(x)
    }
}

public(package) fun safe_mul_div(x: u64, y: u64, z: u64): u64 {
    assert!(z > 0, EDivideByZero);
    let res = (x as u128) * (y as u128) / (z as u128);
    assert!(res <= MAX_U64, EMathOverflow);
    res as u64
}

public(package) fun safe_mul_div_up(x: u64, y: u64, z: u64): u64 {
    assert!(z > 0, EDivideByZero);
    let res = std::macros::num_divide_and_round_up!((x as u128) * (y as u128), (z as u128));
    assert!(res <= MAX_U64, EMathOverflow);
    res as u64
}

public(package) fun checked_mul_div(x: u64, y: u64, z: u64): Option<u64> {
    if (z == 0) { return none() };

    let res = (x as u128) * (y as u128) / (z as u128);

    if (res > MAX_U64) { return none() };

    some(res as u64)
}

public(package) fun checked_mul_div_up(x: u64, y: u64, z: u64): Option<u64> {
    if (z == 0) { return none() };
    let res = std::macros::num_divide_and_round_up!((x as u128) * (y as u128), (z as u128));
    if (res > MAX_U64) { return none() };
    some(res as u64)
}

public(package) fun min_non_zero(x: u64, y: u64): u64 {
    assert!(!(x == 0 && y == 0), EInvalidMinArgs);

    if (x == 0) {
        return y
    };

    if (y == 0) {
        return x
    };

    min(x, y)
}

#[test_only]
use sui::test_utils::assert_eq;

#[test]
fun test_safe_mul_div_round() {
    let a = safe_mul_div(300, 1, 7);
    assert_eq(a, 42);

    let b = safe_mul_div_up(300, 1, 7);
    assert_eq(b, 43);

    let c = safe_mul_div(100, 2, 50);
    let d = safe_mul_div_up(100, 2, 50);

    assert_eq(c, 4);
    assert_eq(c, d);
}
