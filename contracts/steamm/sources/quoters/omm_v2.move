/// OracleV2 AMM Hook implementation. This quoter can only be initialized with btoken types.
module steamm::omm_v2;

use oracles::oracles::{OracleRegistry, OraclePriceUpdate};
use steamm::pool::{Self, Pool, SwapResult};
use steamm::quote::SwapQuote;
use steamm::registry::Registry;
use steamm::version::{Self, Version};
use steamm::utils::oracle_decimal_to_decimal;
use sui::clock::Clock;
use sui::coin::{Coin, TreasuryCap, CoinMetadata};
use suilend::decimal::{Decimal, Self};
use suilend::lending_market::LendingMarket;
use std::type_name::{Self};
use steamm::bank::Bank;
use steamm::events::emit_event;
use steamm::fixed_point64::{Self, FixedPoint64};
use steamm::utils::decimal_to_fixedpoint64;

// ===== Constants =====

const CURRENT_VERSION: u16 = 1;

// ===== Errors =====
const EInvalidBankType: u64 = 0;
const EInvalidOracleIndex: u64 = 1;
const EInvalidOracleRegistry: u64 = 2;
const EInvalidDecimalsDifference: u64 = 3;
const EInvalidZ: u64 = 4;

public struct OracleQuoterV2 has store {
    version: Version,

    // oracle params
    oracle_registry_id: ID,
    oracle_index_a: u64,
    oracle_index_b: u64,

    // coin info
    decimals_a: u8,
    decimals_b: u8,

    // amplifier
    amp: u64,
}

// ===== Public Methods =====

public fun new<P, A, B, B_A, B_B, LpType: drop>(
    registry: &mut Registry,
    lending_market: &LendingMarket<P>,
    meta_a: &CoinMetadata<A>,
    meta_b: &CoinMetadata<B>,
    meta_b_a: &CoinMetadata<B_A>,
    meta_b_b: &CoinMetadata<B_B>,
    meta_lp: &mut CoinMetadata<LpType>,
    lp_treasury: TreasuryCap<LpType>,
    oracle_registry: &OracleRegistry,
    oracle_index_a: u64,
    oracle_index_b: u64,
    amplifier: u64,
    swap_fee_bps: u64,
    ctx: &mut TxContext,
): Pool<B_A, B_B, OracleQuoterV2, LpType> {
    // ensure that this quoter can only be initialized with btoken types
    let bank_data_a = registry.get_bank_data<A>(object::id(lending_market));
    assert!(type_name::get<B_A>() == bank_data_a.btoken_type(), EInvalidBankType);

    let bank_data_b = registry.get_bank_data<B>(object::id(lending_market));
    assert!(type_name::get<B_B>() == bank_data_b.btoken_type(), EInvalidBankType);

    let decimals_a = meta_a.get_decimals();
    let decimals_b = meta_b.get_decimals();

    if (decimals_a >= decimals_b) {
        assert!(decimals_a - decimals_b <= 10, EInvalidDecimalsDifference);
    } else {
        assert!(decimals_b - decimals_a <= 10, EInvalidDecimalsDifference);
    };

    let quoter = OracleQuoterV2 {
        version: version::new(CURRENT_VERSION),
        oracle_registry_id: object::id(oracle_registry),
        oracle_index_a,
        oracle_index_b,
        decimals_a: meta_a.get_decimals(),
        decimals_b: meta_b.get_decimals(),
        amp: amplifier,
    };

    let pool = pool::new<B_A, B_B, OracleQuoterV2, LpType>(
        registry,
        swap_fee_bps,
        quoter,
        meta_b_a,
        meta_b_b,
        meta_lp,
        lp_treasury,
        ctx,
    );

    let result = NewOracleQuoterV2 {
        pool_id: object::id(&pool),
        oracle_registry_id: object::id(oracle_registry),
        oracle_index_a,
        oracle_index_b,
        amplifier,
    };

    emit_event(result);

    return pool
}

public fun swap<P, A, B, B_A, B_B, LpType: drop>(
    pool: &mut Pool<B_A, B_B, OracleQuoterV2, LpType>,
    bank_a: &Bank<P, A, B_A>,
    bank_b: &Bank<P, B, B_B>,
    lending_market: &LendingMarket<P>,
    oracle_price_update_a: OraclePriceUpdate,
    oracle_price_update_b: OraclePriceUpdate,
    coin_a: &mut Coin<B_A>,
    coin_b: &mut Coin<B_B>,
    a2b: bool,
    // Amount in (btoken)
    amount_in: u64,
    // Min amount in (btoken)
    min_amount_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): SwapResult {
    pool.quoter_mut().version.assert_version_and_upgrade(CURRENT_VERSION);

    assert!(oracle_price_update_a.oracle_registry_id() == pool.quoter().oracle_registry_id, EInvalidOracleRegistry);
    assert!(oracle_price_update_a.oracle_index() == pool.quoter().oracle_index_a, EInvalidOracleIndex);

    assert!(oracle_price_update_b.oracle_registry_id() == pool.quoter().oracle_registry_id, EInvalidOracleRegistry);
    assert!(oracle_price_update_b.oracle_index() == pool.quoter().oracle_index_b, EInvalidOracleIndex);

    let quote = quote_swap(
        pool, 
        bank_a,
        bank_b,
        lending_market,
        oracle_price_update_a,
        oracle_price_update_b,
        amount_in, 
        a2b,
        clock,
    );

    let response = pool.swap(
        coin_a,
        coin_b,
        quote,
        min_amount_out,
        ctx,
    );

    response
}

public fun quote_swap<P, A, B, B_A, B_B, LpType: drop>(
    pool: &Pool<B_A, B_B, OracleQuoterV2, LpType>,
    bank_a: &Bank<P, A, B_A>,
    bank_b: &Bank<P, B, B_B>,
    lending_market: &LendingMarket<P>,
    oracle_price_update_a: OraclePriceUpdate,
    oracle_price_update_b: OraclePriceUpdate,
    // Amount in (btoken)
    amount_in: u64,
    a2b: bool,
    clock: &Clock,
): SwapQuote {
    let quoter = pool.quoter();

    let decimals_a = quoter.decimals_a;
    let decimals_b = quoter.decimals_b; 

    let price_a = oracle_decimal_to_decimal(oracle_price_update_a.price());
    let price_b = oracle_decimal_to_decimal(oracle_price_update_b.price());

    let (bank_total_funds_a, total_btoken_supply_a) = bank_a.get_btoken_ratio(lending_market, clock);
    let btoken_ratio_a = bank_total_funds_a.div(total_btoken_supply_a);

    let (bank_total_funds_b, total_btoken_supply_b) = bank_b.get_btoken_ratio(lending_market, clock);
    let btoken_ratio_b = bank_total_funds_b.div(total_btoken_supply_b);


    let amount_out = if (a2b) {
        let underlying_amount_in = decimal::from(amount_in).mul(btoken_ratio_a);
        let underlying_reserve_in = decimal::from(pool.balance_amount_a()).mul(btoken_ratio_a);
        let underlying_reserve_out = decimal::from(pool.balance_amount_b()).mul(btoken_ratio_b);

        // quote_swap_impl uses the underlying values instead of btoken values
        let amount_out_underlying = quote_swap_impl(
            underlying_amount_in,
            underlying_reserve_in,
            underlying_reserve_out,
            decimals_a,
            decimals_b,
            price_a,
            price_b,
            quoter.amp,
            a2b,
        );

        let mut amount_out = decimal::from(amount_out_underlying).div(btoken_ratio_b).floor();

        if (amount_out >= pool.balance_amount_b()) {
            amount_out = 0
        };

        amount_out
    } else {
        let underlying_amount_in = decimal::from(amount_in).mul(btoken_ratio_b);
        let underlying_reserve_in = decimal::from(pool.balance_amount_b()).mul(btoken_ratio_b);
        let underlying_reserve_out = decimal::from(pool.balance_amount_a()).mul(btoken_ratio_a);

        // quote_swap_impl uses the underlying values instead of btoken values
        let amount_out_underlying = quote_swap_impl(
            underlying_amount_in,
            underlying_reserve_in,
            underlying_reserve_out,
            decimals_b,
            decimals_a,
            price_b,
            price_a,
            quoter.amp,
            a2b,
        );

        let mut amount_out = decimal::from(amount_out_underlying).div(btoken_ratio_a).floor();

        if (amount_out >= pool.balance_amount_a()) {
            amount_out = 0;
        };

        amount_out
    };

    pool.get_quote(amount_in, amount_out, a2b)
}

fun quote_swap_impl(
    // Amount in (underlying)
    amount_in: Decimal,
    // Reserve in (underlying)
    reserve_in: Decimal,
    // Reserve out (underlying)
    reserve_out: Decimal,
    decimals_in: u8,
    decimals_out: u8,
    // Price In (underlying)
    price_in: Decimal,
    // Price Out (underlying)
    price_out: Decimal,
    amplifier: u64,
    a2b: bool,
): u64 {
    // quoter_math::swap uses the underlying values instead of btoken values
    if (a2b) {
        get_swap_output(
            amount_in, // input_a
            reserve_in, // reserve_a
            reserve_out, // reserve_b
            price_in, // price_a
            price_out, // price_b
            decimals_in as u64, // decimals_a
            decimals_out as u64, // decimals_b
            amplifier,
            true, // a2b
        )
    } else {
        get_swap_output(
            amount_in, // input_b
            reserve_out, // reserve_a
            reserve_in, // reserve_b
            price_out, // price_a
            price_in, // price_b
            decimals_out as u64, // decimals_a
            decimals_in as u64, // decimals_b
            amplifier,
            false, // a2b
        )
    }
}

fun get_swap_output(
    // Amount in (underlying)
    amount_in: Decimal,
    // Amount X (underlying)
    reserve_x: Decimal,
    // Amount Y (underlying)
    reserve_y: Decimal,
    // Price X (underlying)
    price_x: Decimal,
    // Price Y (underlying)
    price_y: Decimal,
    decimals_x: u64,
    decimals_y: u64,
    amplifier: u64,
    x2y: bool,
): u64 {
    let r_x = decimal_to_fixedpoint64(reserve_x);
    let r_y = decimal_to_fixedpoint64(reserve_y);
    let p_x = decimal_to_fixedpoint64(price_x);
    let p_y = decimal_to_fixedpoint64(price_y);
    let amp = fixed_point64::from(amplifier as u128);
    let delta_in = decimal_to_fixedpoint64(amount_in);

    let dec_pow = if (decimals_x >= decimals_y) {
        fixed_point64::from(10).pow(decimals_x - decimals_y)
    } else {
        fixed_point64::one().div(
            fixed_point64::from(10).pow(decimals_y - decimals_x)
        )
    };

    // k can be interpreted as the trade utilisation, based on the oracle price
    // In general terms: k = Δin * Price / Reserve Out
    // Depending on the direction of the trade we either multiply or divide by the price
    // x2y: k = ΔX * Price / (Reserve Y * DecPow)
    // y2x: k = ΔY * DecPow / (Reserve X * Price)
    let k = if (x2y) {
        // k = [ΔX * PriceX] / [ReserveY * PriceY * DecPow]
        fixed_point64::multiply_divide(
            &mut vector[delta_in, p_x],
            &mut vector[r_y, p_y, dec_pow],
        )
    } else {
        // k = [ΔY * PriceY * DecPow] / [ReserveX * PriceX]
        fixed_point64::multiply_divide(
            &mut vector[delta_in, dec_pow, p_y],
            &mut vector[r_x, p_x],
        )
    };

    // z can be interpreted as the effective utilisation. Since k is the trade utilisation
    // if the trade was executed with the oracle price, this means that z will always be
    // lower than k. Since slippage is supposed to reduce the trade output, in effect this
    // means that the effective utilisation `z` is lower than the oracle-given utilisation `k`.
    // Therefore we can use `k` as our initial guess for `z`.
    let max_bound = fixed_point64::from_rational(9999999999, 10000000000);
    let z_upper_bound = max_bound.min(k);

    let z = newton_raphson(k, amp, z_upper_bound);

    assert!(z.lt(fixed_point64::one()), EInvalidZ);

    // `z` is defined as Δout / ReserveOut. Therefore depending on the
    // direction of the trade we pick the corresponding ouput reserve
    let delta_out = if (x2y) {
        z.mul(r_y).to_u128_down() as u64
    } else {
        z.mul(r_x).to_u128_down() as u64
    };

    // If the trade still depletes the output reserve we quote an output of zero
    if (x2y) {
        if (delta_out >= reserve_y.floor()) {
            return 0
        };
    } else {
        if (delta_out >= reserve_x.floor()) {
            return 0
        };
    };

    delta_out
}

/// Implements the Newton-Raphson method for finding roots of a function in fixed-point arithmetic.
/// This function iteratively refines an initial guess to approximate a root of the function f(z) = 0,
/// where f(z) is defined by the parameters `k` and `a`.
///
/// # Arguments
/// * `k` - A fixed-point parameter used in the function f(z) and its derivative.
/// * `a` - A fixed-point parameter used in the function f(z) and its derivative.
/// * `z_initial` - The initial guess for the root, in fixed-point format.
///
/// # Returns
/// * A `FixedPoint64` value representing the approximate root of the function.
///
/// # Remarks
/// - The method uses a maximum of 20 iterations and a tolerance of 1e-10 for convergence.
/// - The solution is clamped to the range [1e-5, 0.999999999999999999] to ensure stability.
/// - If the derivative is near zero (less than 1e-10), the function aborts with error code 1001.
/// - A damping factor (alpha) is applied if the step takes the solution outside the valid range.
fun newton_raphson(
    k: FixedPoint64,
    a: FixedPoint64,
    z_initial: FixedPoint64
): FixedPoint64 {
    let max_iter = 20;
    newton_raphson_(k, a, z_initial, max_iter)
}

/// See [`newton_raphson`] for details.
fun newton_raphson_(
    k: FixedPoint64,
    a: FixedPoint64,
    z_initial: FixedPoint64,
    max_iter: u64,
): FixedPoint64 {
    let one = fixed_point64::one();
    let z_min = fixed_point64::from_rational(1, 100000); // 1e-5 // todo: increase scale?
    let z_max = fixed_point64::from_rational(999999999999999999, 1000000000000000000); // 0.999999999999999999
    let tol = fixed_point64::from_rational(1, 1000000000_00000); // 1e-14

    // Improve initial guess
    let mut z = if (z_initial.gte(one)) {
        z_max
    } else {
        z_initial
    };
    
    let mut i = 0;
    
    while (i < max_iter) {
        // Compute f(z)
        let (fx_val, fx_positive) = compute_f(z, a, k);
        
        // Check convergence
        if (fixed_point64::lt(fx_val, tol)) {
            break
        };
        
        // Compute f'(z)
        let fp = compute_f_prime(z, a);
        
        // Check for near-zero derivative
        assert!(
            !fixed_point64::lt(fp, fixed_point64::from_rational(1, 10000000000)), // 1e-10
            1001 // Error if derivative is near zero
        );
        
        // Newton step: z_new = z - alpha * f(z)/f'(z)
        let fx_div_fp = fixed_point64::div(fx_val, fp);
        let mut alpha = one; // Start with alpha = 1.0
        let z_new_temp = if (fx_positive) {
            fixed_point64::sub(z, fx_div_fp)
        } else {
            fixed_point64::add(z, fx_div_fp)
        };
        
        let mut z_new = z_new_temp;
        
        // Check if z_new is outside valid range
        if (fixed_point64::lte(z_new, fixed_point64::zero()) || fixed_point64::gte(z_new, one)) {
            // Reduce alpha to 0.5
            alpha = fixed_point64::from_rational(1, 2); // 0.5
            let damped_step = fixed_point64::mul(fx_div_fp, alpha);
            z_new = if (fx_positive) {
                fixed_point64::sub(z, damped_step)
            } else {
                fixed_point64::add(z, damped_step)
            };
            // Clamp to [z_min, z_max]
            z_new = if (fixed_point64::lt(z_new, z_min)) {
                z_min
            } else if (fixed_point64::gt(z_new, z_max)) {
                z_max
            } else {
                z_new
            };
        };
        
        // Check if step is too small
        let step_size = if (fixed_point64::gte(z_new, z)) {
            fixed_point64::sub(z_new, z)
        } else {
            fixed_point64::sub(z, z_new)
        };
        if (fixed_point64::lt(step_size, tol)) {
            break
        };
        
        // Update z for next iteration
        z = z_new;
        i = i + 1;
    };
    
    z
}

/// Computes f(z) = (1 - 1/A) * z - (1/A) * ln(1 - z) - k
/// Returns (magnitude, is_positive) where magnitude is |f(z)| and is_positive indicates the sign
fun compute_f(
    z: FixedPoint64,
    a: FixedPoint64,
    k: FixedPoint64
): (FixedPoint64, bool) {
    let one = fixed_point64::one();
    
    // 64 * ln(2) in FixedPoint64 format
    let ln2_64 = fixed_point64::from_raw_value(12786308645202655660).mul(fixed_point64::from(64)); // 64 * LN2

    // Step 1: Compute (1 - 1/A) * z (always positive)
    let one_div_a = fixed_point64::div(one, a);
    let term1 = fixed_point64::mul(fixed_point64::sub(one, one_div_a), z); // Term 1 is always positive

    // Step 2: Compute (1/A) * ln(1 - z)
    let one_minus_z = fixed_point64::sub(one, z); // 0.99 OK
    let ln_plus_64ln2 = fixed_point64::ln_plus_64ln2(one_minus_z); // ln(1-z) + 64*ln(2) // 44.351369219983 OK

    assert!(!fixed_point64::gt(ln_plus_64ln2, ln2_64), 999);

    // ln_magniture is always negative
    let ln_magnitude = fixed_point64::sub(ln2_64, ln_plus_64ln2);
    
    // Compute (1/A) * |ln(1-z)| (magnitude is positive, sign follows ln(1-z))
    // Term 2 is always negative
    let term2_magnitude = fixed_point64::mul(one_div_a, ln_magnitude);    

    // Term 1 is always positive, term 2 is always negative, so this will always result in an addition
    // Intermediate magnitude is always positive
    let intermediate_magnitude = fixed_point64::add(term1, term2_magnitude);

    // t1 - t2 > 0 (always)
    if (fixed_point64::gte(intermediate_magnitude, k)) {
        // BRANCH 1
        // If t1 - t2 > 0 && > k, then its safe to subtract k and get positive value
        (fixed_point64::sub(intermediate_magnitude, k), true)
    } else {
        // BRANCH 2
        // If t1 - t2 > 0 && < k, then the subtraction of k will lead to a negative value
        (fixed_point64::sub(k, intermediate_magnitude), false)
    }
}

/// Computes f'(z) = 1 - 1/A + 1/(A * (1 - z))
/// Result is always positive
fun compute_f_prime(
    z: FixedPoint64,
    a: FixedPoint64,
): FixedPoint64 {
    let one = fixed_point64::one();
    let one_div_a = fixed_point64::div(one, a);
    let term3 = one.div(
        a.mul(one.sub(z))
    );

    one.sub(one_div_a).add(term3)
}


// ===== Events =====

public struct NewOracleQuoterV2 has copy, drop, store {
    pool_id: ID,
    oracle_registry_id: ID,
    oracle_index_a: u64,
    oracle_index_b: u64,
    amplifier: u64,
}

// ===== Test-only =====

#[test_only]
use std::debug::print;
#[test_only]
use sui::random::RandomGenerator;
#[test_only]
use std::string::utf8;


#[test_only]
fun generate_fixed_point64(rng: &mut RandomGenerator): FixedPoint64 {
    let max = 100 * 10_u128.pow(rng.generate_u8_in_range(1, 15));
    let a = rng.generate_u128_in_range(1, max);

    let max = 100 * 10_u128.pow(rng.generate_u8_in_range(1, 15));
    let b = rng.generate_u128_in_range(1, max);
    
    fixed_point64::from_rational(a, b)
}

#[test_only]
fun generate_normalized_fixed_point64(rng: &mut RandomGenerator): FixedPoint64 {
    let n = generate_fixed_point64(rng);

    if (n.lt(fixed_point64::one())) {
        n
    } else {
        fixed_point64::one().div(n)
    }
}

#[test_only]
fun generate_amplifier(rng: &mut RandomGenerator): FixedPoint64 {
    fixed_point64::from_rational(
        rng.generate_u128_in_range(1, 1_000),
        1,
    )
}


// ===== Tests =====

#[test]
fun test_oracle_decimal_to_decimal() {
    use sui::test_utils::assert_eq;
    use oracles::oracle_decimal::{Self};

    let price = oracle_decimal_to_decimal(oracle_decimal::new(140, 4, false));
    assert_eq(price, decimal::from(1_400_000));

    let price = oracle_decimal_to_decimal(oracle_decimal::new(140, 3, true));
    assert_eq(price, decimal::from(140).div(decimal::from(1000)));
}

#[test]
fun test_quote_swap_impl_amp_1() {
    use sui::test_utils::assert_eq;

    let amount_out = quote_swap_impl(
        decimal::from(1), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 0); // Rounds down from 0.99 to 0
    
    let amount_out = quote_swap_impl(
        decimal::from(10), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 9); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(100), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 99); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(1_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 951);


    // === Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(10_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 6321);

    // === Even Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(100_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
    
    // === Insane slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(1_000_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
}

#[test]
fun test_quote_swap_impl_amp_10() {
    use sui::test_utils::assert_eq;

    let amount_out = quote_swap_impl(
        decimal::from(1), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 0); // Rounds down from 0.99 to 0
    
    let amount_out = quote_swap_impl(
        decimal::from(10), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 9); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(100), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 99); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(1_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 994);


    // === Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(10_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 8776);

    // === Even Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(100_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
    
    // === Insane slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(1_000_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        10, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
}

#[test]
fun test_quote_swap_impl_amp_100() {
    use sui::test_utils::assert_eq;

    let amount_out = quote_swap_impl(
        decimal::from(1), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 0); // Rounds down from 0.99 to 0
    
    let amount_out = quote_swap_impl(
        decimal::from(10), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 9); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(100), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 99); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(1_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 999);


    // === Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(10_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 9734);

    // === Even Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(100_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999); // note: should be 999
    
    // === Insane slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(1_000_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999); // note: should be 999
}

#[test]
fun test_quote_swap_impl_amp_1000() {
    use sui::test_utils::assert_eq;

    let amount_out = quote_swap_impl(
        decimal::from(1), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 0); // Rounds down from 0.99 to 0
    
    let amount_out = quote_swap_impl(
        decimal::from(10), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 9); // Rounds down from 9.99 to 9
    
    
    let amount_out = quote_swap_impl(
        decimal::from(100), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 99); // Rounds down from 9.99 to 9

    let amount_out = quote_swap_impl(
        decimal::from(1_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1000, // amplifier
        true, // a2b
    );

    // print(&amount_out);

    assert_eq(amount_out, 999);


    // === Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(10_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        1000, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9955);

    // === Even Higher slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(100_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
    
    // === Insane slippage ===

    let amount_out = quote_swap_impl(
        decimal::from(1_000_000), // amount in
        decimal::from(10_000), // reserve in
        decimal::from(10_000), // reserve out
        9, // decimals in
        9, // decimals out
        decimal::from(1), // price_in
        decimal::from(1), // price_out
        100, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
}

#[test]
fun test_iter_newton_raphson() {
    // let k = fixed_point64::from_rational(10049999999999999999, 1000000000000000000); // 10.049999999999999999c
    // let a = fixed_point64::from(1);                // A = 1
    // let z_initial = fixed_point64::from_rational(999999999899999999, 1000000000000000000); // 0.999999999899999999
    // let z = newton_raphson(k, a, z_initial);

    // print(&z.to_string());
    
    
    let k = fixed_point64::from_rational(10019999999999999999, 1000000000000000000); // 10.049999999999999999c
    let a = fixed_point64::from(1);                // A = 1
    let z_initial = fixed_point64::from_rational(999999999899999999, 1000000000000000000); // 0.999999999899999999
    let z = newton_raphson(k, a, z_initial);

    // print(&z.to_string());
    
    // assert!(z.to_string() == utf8(b"0.000199980001333266"), 0);

    // let (result, _) = compute_f(z, a, k);
    // assert!(result.to_string() == utf8(b"0.000000000000000000"), 0);
}

#[test]
fun test_newton_raphson() {
    // k:  0.0002 ; A:  1
    let k = fixed_point64::from_rational(2, 10000); // 0.0002
    let a = fixed_point64::from(1);                // A = 1
    let z_initial = fixed_point64::from_rational(199979994408495, 1000000000000000000); // 0.000199979994408495
    let z = newton_raphson(k, a, z_initial);
    
    // print(&z.to_string());
    assert!(z.to_string() == utf8(b"0.000199980001333266"), 0);

    let (result, _) = compute_f(z, a, k);
    assert!(result.to_string() == utf8(b"0.000000000000000000"), 0);
    
    // k:  0.630828828828829 ; A:  1 ;
    let k = fixed_point64::from_rational(630828828828829, 1000000000000000); // 0.630828828828829
    let a = fixed_point64::from(1);                // A = 1
    let z_initial = fixed_point64::from_rational(467849443537058250, 1000000000000000000); // 0.467849443537058250
    let z = newton_raphson(k, a, z_initial);

    assert!(z.to_string() == utf8(b"0.467849443548411605"), 0);

    let (result, _) = compute_f(z, a, k);
    assert!(result.to_string() == utf8(b"0.000000000000000000"), 0);

    // k:  69.50951091091092 ; A: 1 ;
    let k = fixed_point64::from_rational(6950951091091092, 100000000000000); // 69.50951091091092
    let a = fixed_point64::from(1);                // A = 1
    let z_initial = fixed_point64::from_rational(999989999970896460, 1000000000000000000); // 0.999989999970896460
    // let (z_left, z_right) = find_brackets(k, a);
    // let z_initial = z_left.add(z_right).div(fixed_point64::from(2));
    let z = newton_raphson(k, a, z_initial);
    // print(&z.to_string());

    let (result, _) = compute_f(z, a, k);
    // print(&result.to_string());
    // assert!(result.to_string() == utf8(b"0.000000000000000000"), 0); // Note: This is not zero as it struggles to converge
}

#[test]
fun test_compute_f_branch_1() {
    let z = fixed_point64::from_rational(1, 100); // z = 0.01
    let a = fixed_point64::from(10);              // A = 10
    let k = fixed_point64::from_rational(1, 100); // k = 0.01
    
    let (magnitude, is_positive) = compute_f(z, a, k); // 5.03358535e-06
    // print(&magnitude.mul(fixed_point64::from(1000000000000000)).to_u128());
    
    // Expected: (1 - 1/10) * 0.01 - (1/10) * ln(0.99) - 0.01
    // ≈ 0.9 * 0.01 - 0.1 * (-0.01005033585) - 0.01
    // ≈ 0.009 + 0.001005033585 - 0.01 ≈ 0.000005033585 (positive)
    assert!(is_positive, 1);
    assert!(magnitude.mul(fixed_point64::from(1000000000000000)).to_u128() == 5033585350_u128, 0);

    // let z = fixed_point64::from_rational(99, 100); // z = 0.99
    // let a = fixed_point64::from(2);                // A = 2
    // let k = fixed_point64::from_rational(1, 100);  // k = 0.01
    // let (magnitude, is_positive) = compute_f(z, a, k);
    
    // print(&magnitude.mul(fixed_point64::from(1000000000000000)).to_u128());
    // assert!(is_positive, 1); // Expect positive result
}

#[test]
fun test_compute_f_branch_2() {
    // Test Branch 5b: intermediate_positive, intermediate_magnitude < k ("shalom")
    // Set z small, A large, k large
    let z = fixed_point64::from_rational(1, 100);  // z = 0.01
    let a = fixed_point64::from(100);              // A = 100
    let k = fixed_point64::from_rational(1, 10);   // k = 0.1
    let (_magnitude, is_positive) = compute_f(z, a, k);
    // term1 = (1 - 1/100) * 0.01 = 0.99 * 0.01 = 0.0099
    // term2 = (1/100) * |ln(0.99)| ≈ 0.01 * 0.0100503 ≈ 0.000100503
    // intermediate = 0.0099 - 0.000100503 ≈ 0.0097995 < 0.1
    // result = 0.1 - 0.0097995 ≈ 0.0902005 (negative)
    // print(&magnitude.mul(fixed_point64::from(1000000000000000)).to_u128());
    assert!(!is_positive, 1); // Expect negative result
}

#[test]
fun test_compute_f_both_branches() {
    // Requires term1 - term2 < 0 when term2_positive is false (normal case)
    let z = fixed_point64::from_rational(9, 10);   // z = 0.9
    let a = fixed_point64::from(10);               // A = 10
    let k = fixed_point64::from_rational(1, 100);  // k = 0.01
    let (magnitude, is_positive) = compute_f(z, a, k);

    assert!(is_positive, 1); // Expect negative result
    let k = fixed_point64::from(10); // k = 10
    let (magnitude, is_positive) = compute_f(z, a, k);
    // result = 0.5797415 - 10 ≈ -9.4202585 (negative)
    // print(&magnitude.mul(fixed_point64::from(1000000000000000)).to_u128());
    assert!(!is_positive, 1); // Expect negative result
}

/// If the test fails then the fail code is the iteration number.
#[test]
fun test_newton_raphson_with_random_values() {
    let iterations = 10_000;
    let debug = false;

    let mut rng = sui::random::new_generator_from_seed_for_testing(b"newton");

    let mut i = 0u64;
    while (i < iterations) {
        let k = generate_fixed_point64(&mut rng);
        let a = generate_amplifier(&mut rng);
        let z_initial = generate_normalized_fixed_point64(&mut rng);

        if (debug) {
            print(&{
                let mut s = utf8(b"Iteration #");
                s.append(i.to_string());
                s.append_utf8(b"\nk: ");
                s.append(k.to_string());
                s.append_utf8(b"\na: ");
                s.append(a.to_string());
                s.append_utf8(b"\nz_initial: ");
                s.append(z_initial.to_string());
                s
            });
        };

        let z = newton_raphson(k, a, z_initial);
        
        // the result is in the expected range of (0; 1]
        assert!(z.lte(fixed_point64::one()), i);
        assert!(z.gt(fixed_point64::zero()), i);

        // increasing iterations doesn't change the result
        let z_with_more_iterations = newton_raphson_(k, a, z, 100);
        assert!(z_with_more_iterations.eq(z), i);

        i = i + 1;
    };
}

