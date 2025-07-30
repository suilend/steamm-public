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
use sui::dynamic_field as df;
use suilend::decimal::{Decimal, Self};
use suilend::lending_market::LendingMarket;
use std::type_name::{Self};
use std::option::{none, some};
use steamm::bank::Bank;
use steamm::events::emit_event;
use steamm::fixed_point64::{Self, FixedPoint64};
use steamm::utils::decimal_to_fixedpoint64;
use steamm::omm::{quote_swap_impl as quote_swap_with_no_slippage};
use pyth::i64::{Self};
use steamm::global_admin::GlobalAdmin;

// ===== Constants =====

const CURRENT_VERSION: u16 = 5;

/// 10^10, scales USD values to avoid precision loss.
/// In the limit, pool balances can be less than 1$, therefore we scale the dollar
/// amount to be be able to handle decimal values
const SCALE: u256 = 10000000000;
const A_PRECISION: u256 = 100; // Scales the Amplifier for better precision
const LIMIT: u64 = 255; // Limit newton-raphson iterations

// ===== Errors =====
const EInvalidBankType: u64 = 0;
const EInvalidOracleIndex: u64 = 1;
const EInvalidOracleRegistry: u64 = 2;
const EInvalidDecimalsDifference: u64 = 3;
const EInvalidZ: u64 = 4;
const EInvalidPrice: u64 = 5;

/// Flag to indicate that the pool has been updated
public struct UpdateFlag has copy, drop, store {}

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

    let mut pool = pool::new<B_A, B_B, OracleQuoterV2, LpType>(
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

    let pool_uid = pool.uid_mut();
    df::add(pool_uid, UpdateFlag {}, 0);

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

    let quoter = pool.quoter();

    let decimals_a = quoter.decimals_a;
    let decimals_b = quoter.decimals_b; 

    let price_a = oracle_decimal_to_decimal(oracle_price_update_a.price());
    let price_b = oracle_decimal_to_decimal(oracle_price_update_b.price());

    let price_uncertainty_ratio_a = price_uncertainty_ratio(oracle_price_update_a);
    let price_uncertainty_ratio_b = price_uncertainty_ratio(oracle_price_update_b);

    let (bank_total_funds_a, total_btoken_supply_a) = bank_a.get_btoken_ratio(lending_market, clock);
    let btoken_ratio_a = bank_total_funds_a.div(total_btoken_supply_a);

    let (bank_total_funds_b, total_btoken_supply_b) = bank_b.get_btoken_ratio(lending_market, clock);
    let btoken_ratio_b = bank_total_funds_b.div(total_btoken_supply_b);

    let underlying_reserve_a = decimal::from(pool.balance_amount_a()).mul(btoken_ratio_a);
    let underlying_reserve_b = decimal::from(pool.balance_amount_b()).mul(btoken_ratio_b);
    
    let usd_reserve_a = underlying_reserve_a.mul(price_a).div(decimal::from(10_u64.pow(decimals_a)));
    let usd_reserve_b = underlying_reserve_b.mul(price_b).div(decimal::from(10_u64.pow(decimals_b)));

    try_update_or_noop(pool, usd_reserve_a, usd_reserve_b);

    let quote = quote_swap_(
        pool,
        price_a,
        price_b,
        price_uncertainty_ratio_a,
        price_uncertainty_ratio_b,
        btoken_ratio_a,
        btoken_ratio_b,
        underlying_reserve_a,
        underlying_reserve_b,
        amount_in, 
        a2b,
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
    assert!(oracle_price_update_a.oracle_registry_id() == pool.quoter().oracle_registry_id, EInvalidOracleRegistry);
    assert!(oracle_price_update_a.oracle_index() == pool.quoter().oracle_index_a, EInvalidOracleIndex);
    assert!(oracle_price_update_b.oracle_registry_id() == pool.quoter().oracle_registry_id, EInvalidOracleRegistry);
    assert!(oracle_price_update_b.oracle_index() == pool.quoter().oracle_index_b, EInvalidOracleIndex);

    let price_a = oracle_decimal_to_decimal(oracle_price_update_a.price());
    let price_b = oracle_decimal_to_decimal(oracle_price_update_b.price());

    let price_uncertainty_ratio_a = price_uncertainty_ratio(oracle_price_update_a);
    let price_uncertainty_ratio_b = price_uncertainty_ratio(oracle_price_update_b);

    let (bank_total_funds_a, total_btoken_supply_a) = bank_a.get_btoken_ratio(lending_market, clock);
    let btoken_ratio_a = bank_total_funds_a.div(total_btoken_supply_a);

    let (bank_total_funds_b, total_btoken_supply_b) = bank_b.get_btoken_ratio(lending_market, clock);
    let btoken_ratio_b = bank_total_funds_b.div(total_btoken_supply_b);

    let underlying_reserve_a = decimal::from(pool.balance_amount_a()).mul(btoken_ratio_a);
    let underlying_reserve_b = decimal::from(pool.balance_amount_b()).mul(btoken_ratio_b);

    quote_swap_(
        pool, 
        price_a,
        price_b,
        price_uncertainty_ratio_a,
        price_uncertainty_ratio_b,
        btoken_ratio_a,
        btoken_ratio_b,
        underlying_reserve_a,
        underlying_reserve_b,
        amount_in, 
        a2b,
    )
}

fun quote_swap_<B_A, B_B, LpType: drop>(
    pool: &Pool<B_A, B_B, OracleQuoterV2, LpType>,
    price_a: Decimal,
    price_b: Decimal,
    price_uncertainty_ratio_a: u64,
    price_uncertainty_ratio_b: u64,
    btoken_ratio_a: Decimal,
    btoken_ratio_b: Decimal,
    underlying_reserve_a: Decimal,
    underlying_reserve_b: Decimal,
    // Amount in (btoken)
    amount_in: u64,
    a2b: bool,
): SwapQuote {
    let quoter = pool.quoter();
    let decimals_a = quoter.decimals_a;
    let decimals_b = quoter.decimals_b;

    let amount_out = if (a2b) {
        let underlying_amount_in = decimal::from(amount_in).mul(btoken_ratio_a);
        let underlying_reserve_in = underlying_reserve_a;
        let underlying_reserve_out = underlying_reserve_b;

        let amount_out_underlying = if (!is_latest(pool.uid())) {
            get_swap_output(
                underlying_amount_in, // input_a
                underlying_reserve_in, // reserve_a
                underlying_reserve_out, // reserve_b
                price_a, // price_a
                price_b, // price_b
                decimals_a as u64, // decimals_a
                decimals_b as u64, // decimals_b
                quoter.amp,
                true, // a2b
            )
        } else {
            get_swap_output_v2(
                underlying_amount_in.floor(), // input_a
                underlying_reserve_in.floor(), // reserve_a
                underlying_reserve_out.floor(), // reserve_b
                price_a, // price_a
                price_b, // price_b
                decimals_a, // decimals_a
                decimals_b, // decimals_b
                quoter.amp,
                true, // a2b
            )
        };

        let mut amount_out = decimal::from(amount_out_underlying).div(btoken_ratio_b).floor();

        if (amount_out >= pool.balance_amount_b()) {
            amount_out = 0
        };

        amount_out
    } else {
        let underlying_amount_in = decimal::from(amount_in).mul(btoken_ratio_b);
        let underlying_reserve_in = underlying_reserve_b;
        let underlying_reserve_out = underlying_reserve_a;

        let amount_out_underlying = if (!is_latest(pool.uid())) {
            get_swap_output(
                underlying_amount_in, // input_b
                underlying_reserve_out, // reserve_a
                underlying_reserve_in, // reserve_b
                price_a, // price_a
                price_b, // price_b
                decimals_a as u64, // decimals_a
                decimals_b as u64, // decimals_b
                quoter.amp,
                false, // a2b
            )
        } else {
            get_swap_output_v2(
                underlying_amount_in.floor(), // input_b
                underlying_reserve_out.floor(), // reserve_a
                underlying_reserve_in.floor(), // reserve_b
                price_a, // price_a
                price_b, // price_b
                decimals_a, // decimals_a
                decimals_b, // decimals_b
                quoter.amp,
                false, // a2b
            )
        };

        let mut amount_out = decimal::from(amount_out_underlying).div(btoken_ratio_a).floor();

        if (amount_out >= pool.balance_amount_a()) {
            amount_out = 0;
        };

        amount_out
    };

    if (!is_latest(pool.uid())) {
        let amount_out_with_no_slippage = if (a2b) {
            quote_swap_with_no_slippage(
                amount_in,
                decimals_a,
                decimals_b,
                price_a,
                price_b,
                btoken_ratio_a,
                btoken_ratio_b,
            )
        } else {
            quote_swap_with_no_slippage(
                amount_in,
                decimals_b,
                decimals_a,
                price_b,
                price_a,
                btoken_ratio_b,
                btoken_ratio_a,
            )
        };

        assert!(amount_out < amount_out_with_no_slippage, EInvalidPrice);
    };

    pool.get_quote(amount_in, amount_out, a2b, some(price_uncertainty_ratio_a.max(price_uncertainty_ratio_b)))
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
    let z = z.min(z_upper_bound);

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

#[allow(unused_let_mut)] // false-positive
fun get_swap_output_v2(
    // Amount in (underlying)
    amount_in: u64,
    // Amount X (underlying)
    reserve_x: u64,
    // Amount Y (underlying)
    reserve_y: u64,
    // Price X (underlying)
    price_x: Decimal,
    // Price Y (underlying)
    price_y: Decimal,
    decimals_x: u8,
    decimals_y: u8,
    amplifier: u64,
    x2y: bool,
): u64 {
    let (price_x_integer_part, price_x_decimal_part_inverted) = split_price(price_x);
    let (price_y_integer_part, price_y_decimal_part_inverted) = split_price(price_y);
    
    // We avoid using Decimal and use u256 instead to increase the overflow limit
    // Reserves are in USD value and scaled by 10^10
    let scaled_usd_reserve_x = {
        let scaled_reserve = (reserve_x as u256) * SCALE;
        let scaled_reserve_usd = to_usd(scaled_reserve, price_x_integer_part, price_x_decimal_part_inverted);
        scaled_reserve_usd / (10_u64.pow(decimals_x) as u256)
    };
    
    let scaled_usd_reserve_y = {
        let scaled_reserve = (reserve_y as u256) * SCALE;
        let scaled_reserve_usd = to_usd(scaled_reserve, price_y_integer_part, price_y_decimal_part_inverted);

        scaled_reserve_usd / (10_u64.pow(decimals_y) as u256)
    };

    // We follow the Curve convention where the amplifier is actually defined as
    // A * n^(n-1) * A_PRECISION => A * 2^1 * A_PRECISION 
    let scaled_amp = (amplifier * 2) as u256 * A_PRECISION;
    let d = get_d(scaled_usd_reserve_x, scaled_usd_reserve_y, scaled_amp);

    let scaled_amount_in = amount_in as u256 * SCALE;

    let mut delta_out = if (x2y) {
        let scaled_usd_amount_in = to_usd(scaled_amount_in, price_x_integer_part, price_x_decimal_part_inverted) / (10_u64.pow(decimals_x) as u256);
        let scaled_usd_reserve_out_after_trade = get_y(scaled_usd_reserve_x + scaled_usd_amount_in, scaled_amp, d);
        let scaled_reserve_out_after_trade = from_usd(scaled_usd_reserve_out_after_trade, price_y_integer_part, price_y_decimal_part_inverted);

        let reserve_out_after_trade = (scaled_reserve_out_after_trade * (10_u64.pow(decimals_y) as u256) / (SCALE as u256)) as u64;

        reserve_y - reserve_out_after_trade

    } else {
        let scaled_usd_amount_in = to_usd(scaled_amount_in, price_y_integer_part, price_y_decimal_part_inverted) / (10_u64.pow(decimals_y) as u256);
        let scaled_usd_reserve_out_after_trade = get_y(scaled_usd_reserve_y + scaled_usd_amount_in, scaled_amp, d);
        let scaled_reserve_out_after_trade = from_usd(scaled_usd_reserve_out_after_trade, price_x_integer_part, price_x_decimal_part_inverted);

        let reserve_out_after_trade = (scaled_reserve_out_after_trade * (10_u64.pow(decimals_x) as u256) / (SCALE as u256)) as u64;

        reserve_x - reserve_out_after_trade
    };

    // Protect against up roundings
    if (delta_out > 0) {
        delta_out = delta_out - 1;
    };

    delta_out
}

/// We split the price into integer and decimal part, instead of using Decimal type
/// This allows us to operate with larger integer values. In order to deal with 
/// the decimal part only using u256, we invert the decimal part
/// 
/// We return option for the decimal part because in cases where there is no decimal part
/// inverting it would result in division by zero
fun split_price(price: Decimal): (u256, Option<u256>) {
    let price_integer_part = price.floor() as u256;
    let price_decimal_part = price.sub(decimal::from(price.floor()));

    if (price_decimal_part == decimal::from(0)) {
        (price_integer_part, none())
        
    } else {
        let price_decimal_part_inverted = decimal::from(1).div(price_decimal_part).floor() as u256;
        (price_integer_part, some(price_decimal_part_inverted))
    }
}

/// Converts a unit amount into a USD amount
fun to_usd(amount: u256, price_integer_part: u256, price_decimal_part_inverted: Option<u256>): u256 {
    // R * (p_int + p_dec);
    // R * p_int + R * p_dec
    // R * p_int + R / (1 / p_dec)
    if (price_decimal_part_inverted.is_some()) {
        (amount * price_integer_part) + (amount / price_decimal_part_inverted.destroy_some())
    } else {
        price_decimal_part_inverted.destroy_none();
        (amount * price_integer_part)
    }
}

/// Converts a USD amount into a unit amount
fun from_usd(usd_amount: u256, price_integer_part: u256, price_decimal_part_inverted: Option<u256>): u256 {
    // let q = 1 / p_dec
    // R_usd = R * (p_int + p_dec)
    // R_usd = R * (p_int + 1/q)
    // R_usd = R * [ (p_int * q + 1) / q ]
    // R = R_usd * q / (p_int * q + 1)
    if (price_decimal_part_inverted.is_some()) {
        let price_decimal_part_inverted = price_decimal_part_inverted.destroy_some();
        usd_amount *  price_decimal_part_inverted / (price_integer_part * price_decimal_part_inverted + 1)
    } else {
        usd_amount / price_integer_part
    }
}

fun price_uncertainty_ratio(oracle_price_update: OraclePriceUpdate): u64 {
    let conf = oracle_price_update.metadata().pyth().get_price().get_conf();
    let price_mag = i64::get_magnitude_if_positive(&oracle_price_update.metadata().pyth().get_price().get_price());

    conf * 10_000 / price_mag
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
#[allow(unused_assignment)] // false-positive
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

fun get_d(
    reserve_a: u256,
    reserve_b: u256,
    // This is the amplifier scaled by A_PRECISION
    amp: u256,
): u256 {
    // D invariant calculation in non-overflowing integer operations
    // iteratively
    // A * sum(x_i) * n**n + D = A * D * n**n + D**(n+1) / (n**n * prod(x_i))
    //
    // Converging solution:
    // D[j+1] = (A * n**n * sum(x_i) - D[j]**(n+1) / (n**n prod(x_i))) / (A * n**n - 1)

    let sum = reserve_a + reserve_b;
    let ann = amp * 2;

    // initial guess
    let mut d = sum;

    let mut limit = LIMIT;

    while(limit > 0) {
        let mut d_p = d;
        d_p = d_p * d / reserve_a;
        d_p = d_p * d / reserve_b;
        d_p = d_p / 4;

        let d_prev = d;

        // (Ann * S / A_PRECISION + D_P * _n_coins) * D / ((Ann - A_PRECISION) * D / A_PRECISION + (_n_coins + 1) * D_P)
        d = (
            ((ann * sum / A_PRECISION) + d_p * 2) *
            d / (
                ((ann - A_PRECISION) * d / A_PRECISION) + 
                (3 * d_p)
            )
        );

        if (d > d_prev) {
            if (d - d_prev <= 1) {
                return d
            };
        } else {
            if (d_prev - d <= 1) {
                return d
            };
        };

        limit = limit - 1;
    };


    abort 0
}

// Output reserve after subtract swap output
#[allow(unused_assignment)] // false-positive
fun get_y(
    reserve_in: u256,
    amp: u256,
    d: u256,
): u256 {
    let ann = amp * 2;

    let sum = reserve_in; // Reserve out is outside the summation as it is the unknown var
    let mut c = d.pow(2) / (2 * reserve_in);
    c = c * d * A_PRECISION / (ann * 2);

    let b = sum + d * A_PRECISION / ann;
    let mut y_prev = 0;
    let mut y = d;

    let mut limit = LIMIT;

    while (limit > 0) {
        y_prev = y;
        y = (y*y + c) / (2 * y + b - d);

        if (y > y_prev) {
            if (y - y_prev <= 1) {
                return y
            };
        } else {
            if (y_prev - y <= 1) {
                return y
            };
        };

        limit = limit - 1;
    };

    abort 0
}

fun try_update_or_noop<B_A, B_B, LpType: drop>(
    pool: &mut Pool<B_A, B_B, OracleQuoterV2, LpType>,
    reserve_a_usd: Decimal,
    reserve_b_usd: Decimal
) {
    let pool_uid = pool.uid_mut();

    if (is_latest(pool_uid)) {
        return
    };

    // Calculate the ratio (using 100 as base for percentage)
    let ratio_a = (reserve_a_usd.mul(decimal::from(100))).div(reserve_a_usd.add(reserve_b_usd));
    
    // Check if ratio is between 40:60 and 60:40
    // This means ratio_a should be between 40 and 60
    let update = ratio_a.ge(decimal::from(40)) && ratio_a.le(decimal::from(60));

    if (update) {
        df::add(pool_uid, UpdateFlag {}, 0);

        let new_amp = match (pool.quoter().amp) {
            20 => 50,
            30 => 100,
            1000 => 1000,
            _ => pool.quoter().amp
        };

        pool.quoter_mut().amp = new_amp;
    };
}

fun is_latest(
    _pool_uid: &UID,
): bool {
    // df::exists_(pool_uid, UpdateFlag {})
    false
}

public fun pause_pool<B_A, B_B, LpType: drop>(
    pool: &mut Pool<B_A, B_B, OracleQuoterV2, LpType>,
    admin: &GlobalAdmin,
) {
    pool.quoter_mut().version.assert_version_and_upgrade(CURRENT_VERSION);
    pool.pause_pool(admin)
}

public fun resume_pool<B_A, B_B, LpType: drop>(
    pool: &mut Pool<B_A, B_B, OracleQuoterV2, LpType>,
    admin: &GlobalAdmin,
) {
    pool.quoter_mut().version.assert_version_and_upgrade(CURRENT_VERSION);
    pool.resume_pool(admin)
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
public fun use_legacy_for_testing<B_A, B_B, LpType: drop>(pool: &mut Pool<B_A, B_B, OracleQuoterV2, LpType>) {
    let pool_uid = pool.uid_mut();
    
    df::remove<UpdateFlag, u64>(pool_uid, UpdateFlag {});
}


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
fun test_get_d_upper_threshold() {
    let d = get_d(1_000_000_000_000_000_000_000, 1_000_000_000_000_000_000_000, 100_000); // 100 billion USD = 2000000000000000000000
    assert!(d < 8740834812604276470692694_u256, 0);
    let _ = get_y(1_000_000_000_000_000_000_000, 100_000 as u256, d);
    
    let d = get_d(1_00_00_00_000_000_000_000_000_000_000_000_000_000, 1_00_00_00_000_000_000_000_000_000_000_000_000_000, 100_000); // 100 septilion USD
    let _ = get_y(1_00_00_00_000_000_000_000_000_000_000_000_000_000, 100_000 as u256, d);
}

#[test]
fun test_scaled_d() {
    // use std::debug::print;
    use sui::test_utils::assert_eq;

    // Tests that scaling the reserves leads to the linear scaling of the D value
    let upscale = 10_u256.pow(10);

    assert_eq(get_d(1000000 * upscale, 1000000 * upscale, 20000), 2000000 * upscale);
    assert_eq(get_d(646604101554903 * upscale, 430825829860939 * upscale, 10000) / upscale, 1077207198258876);
    assert_eq(get_d(208391493399283 * upscale, 381737267304454 * upscale, 6000) / upscale, 589673027554751);
    assert_eq(get_d(357533698368810 * upscale, 292279113116023 * upscale, 200000) / upscale, 649811157409887);
    assert_eq(get_d(640219149077469 * upscale, 749346581809482 * upscale, 6000) / upscale, 1389495058454884);
    assert_eq(get_d(796587650933232 * upscale, 263696548289376 * upscale, 20000) / upscale, 1059395029204629);
    assert_eq(get_d(645814702742123 * upscale, 941346843035970 * upscale, 6000) / upscale, 1586694700461120);
    assert_eq(get_d(36731011531180 * upscale, 112244514819796 * upscale, 6000) / upscale, 148556820223757);
    assert_eq(get_d(638355455638005 * upscale, 144419816425350 * upscale, 20000) / upscale, 781493318669443);
    assert_eq(get_d(747070395683716 * upscale, 583370126767355 * upscale, 200000) / upscale, 1330435412150341);
    assert_eq(get_d(222152880197132 * upscale, 503754962483370 * upscale, 10000) / upscale, 725272897710721);

    assert_eq(get_d(30000000000000, 10000000000000, 200), 38041326932308);
}

// TODO: test max difference in y is 1
#[test]
fun test_scaled_y() {
    // use std::debug::print;
    use sui::test_utils::assert_eq;

    // Tests that scaling the reserves leads to the linear scaling of the y value
    let upscale = 10_u256.pow(10);

    assert_eq(get_y(1010000 * upscale, 20000, 20000000000000000) / upscale, 990000);
    assert_eq(get_y(1045311940606135 * upscale, 10000, 10772071982588769824152384) / upscale, 54125279774978);
    assert_eq(get_y(628789391533719 * upscale, 6000, 5896730275547517949493925) / upscale, 12102396904252);
    assert_eq(get_y(664497701537459 * upscale, 200000, 6498111574098870651550508) / upscale, 1571656363072);
    assert_eq(get_y(1241196069415337 * upscale, 6000, 13894950584548846774266673) / upscale, 164151111358319);
    assert_eq(get_y(1207464631415294 * upscale, 20000, 10593950292046298598329699) / upscale, 3978315032067);
    assert_eq(get_y(1326030781815325 * upscale, 6000, 15866947004611206299166769) / upscale, 270631769558979);
    assert_eq(get_y(596549235149733 * upscale, 6000, 1485568202237573366871425) / upscale, 25485695510);
    assert_eq(get_y(1412549409240877 * upscale, 20000, 7814933186694435312564255) / upscale, 333436412241);
    assert_eq(get_y(966973926501573 * upscale, 200000, 13304354121503417159337232) / upscale, 363547559872801);
    assert_eq(get_y(468614952287735 * upscale, 10000, 7252728977107214865224066) / upscale, 256991438480111);

    // simulating a trade buy sui sell 1000 usdc; 
    // sui bought: 15.4696173902$ worth of sui
    // sui bought in units: ~5.15653913006666666667
    // This makes sense because the pool has more sui than usdc and the amplifier is 1
    assert_eq(get_y((10000000000000 + 100000000000), 1 * 2 * A_PRECISION, 38041326932308), 29845303826098); // sui reserve after trade: 2984.5303826098
    assert_eq(get_y((30000000000000 + 51565391310), 1 * 2 * A_PRECISION, 38041326932308), 9966843369867); // usdc reserve after trade: 996.
}

#[test]
fun test_get_d() {
    // use std::debug::print;
    use sui::test_utils::assert_eq;

    // Expected values generated from curve stable swap contract
    assert_eq(get_d(1000000, 1000000, 20000), 2000000);
    assert_eq(get_d(646604101554903, 430825829860939, 10000), 1077207198258876);
    assert_eq(get_d(208391493399283, 381737267304454, 6000), 589673027554751);
    assert_eq(get_d(357533698368810, 292279113116023, 200000), 649811157409887);
    assert_eq(get_d(640219149077469, 749346581809482, 6000), 1389495058454884);
    assert_eq(get_d(796587650933232, 263696548289376, 20000), 1059395029204629);
    assert_eq(get_d(645814702742123, 941346843035970, 6000), 1586694700461120);
    assert_eq(get_d(36731011531180, 112244514819796, 6000), 148556820223757);
    assert_eq(get_d(638355455638005, 144419816425350, 20000), 781493318669443);
    assert_eq(get_d(747070395683716, 583370126767355, 200000), 1330435412150341);
    assert_eq(get_d(222152880197132, 503754962483370, 10000), 725272897710721);
}

#[test]
fun test_get_y() {
    // use std::debug::print;
    use sui::test_utils::assert_eq;

    // Expected values generated from curve stable swap contract
    // D values are generated from the results of the previous test
    assert_eq(get_y(1010000, 20000, 2000000), 990000);
    assert_eq(get_y(1045311940606135, 10000, 1077207198258876), 54125279774978);
    assert_eq(get_y(628789391533719, 6000, 589673027554751), 12102396904252);
    assert_eq(get_y(664497701537459, 200000, 649811157409887), 1571656363072);
    assert_eq(get_y(1241196069415337, 6000, 1389495058454884), 164151111358319);
    assert_eq(get_y(1207464631415294, 20000, 1059395029204629), 3978315032067);
    assert_eq(get_y(1326030781815325, 6000, 1586694700461120), 270631769558978);
    assert_eq(get_y(596549235149733, 6000, 148556820223757), 25485695510);
    assert_eq(get_y(1412549409240877, 20000, 781493318669443), 333436412241);
    assert_eq(get_y(966973926501573, 200000, 1330435412150341), 363547559872801);
    assert_eq(get_y(468614952287735, 10000, 725272897710721), 256991438480111);
}

#[test]
fun test_get_y_path_indepencence_amp_20() {
    let reserve = 1000000;
    let amp = 20 * A_PRECISION;
    let amount_in = 10000;

    let balance_out = get_y(reserve + amount_in, amp, get_d(reserve, reserve, amp));
    let delta = reserve - balance_out;

    let split = 16;
    let amount_in = amount_in / split;
    let mut total_delta = 0;
    let mut current_reserve_in = reserve;
    let mut current_reserve_out = reserve;
    let mut swaps = 0;

    while (swaps < split) {
        let balance_out = get_y(current_reserve_in + amount_in, amp, get_d(current_reserve_in, current_reserve_out, amp));
        let delta = current_reserve_out - balance_out;
        total_delta = total_delta + delta;
        current_reserve_out = balance_out;
        current_reserve_in = current_reserve_in + amount_in;

        swaps = swaps + 1; 
    };

    sui::test_utils::assert_eq(delta, total_delta);
}

#[test]
fun test_get_y_path_indepencence_amp_30() {
    let reserve = 1000000;
    let amp = 30 * A_PRECISION;
    let amount_in = 10000;

    let balance_out = get_y(reserve + amount_in, amp, get_d(reserve, reserve, amp));
    let delta = reserve - balance_out;

    let split = 16;
    let amount_in = amount_in / split;
    let mut total_delta = 0;
    let mut current_reserve_in = reserve;
    let mut current_reserve_out = reserve;
    let mut swaps = 0;

    while (swaps < split) {
        let balance_out = get_y(current_reserve_in + amount_in, amp, get_d(current_reserve_in, current_reserve_out, amp));
        let delta = current_reserve_out - balance_out - 1;
        total_delta = total_delta + delta;
        current_reserve_out = balance_out;
        current_reserve_in = current_reserve_in + amount_in;

        swaps = swaps + 1; 
    };

    assert!(delta >= total_delta, 0);
}

#[test]
fun test_get_y_path_indepencence_amp_100() {
    let reserve = 1000000;
    let amp = 100 * A_PRECISION;
    let amount_in = 10000;

    let balance_out = get_y(reserve + amount_in, amp, get_d(reserve, reserve, amp));
    let delta = reserve - balance_out;

    let split = 16;
    let amount_in = amount_in / split;
    let mut total_delta = 0;
    let mut current_reserve_in = reserve;
    let mut current_reserve_out = reserve;
    let mut swaps = 0;

    while (swaps < split) {
        let balance_out = get_y(current_reserve_in + amount_in, amp, get_d(current_reserve_in, current_reserve_out, amp));
        let delta = current_reserve_out - balance_out - 1;
        total_delta = total_delta + delta;
        current_reserve_out = balance_out;
        current_reserve_in = current_reserve_in + amount_in;

        swaps = swaps + 1; 
    };

    assert!(delta >= total_delta, 0);
}

#[test]
fun test_get_y_path_indepencence_amp_1000() {
    let reserve = 1000000;
    let amp = 1000 * A_PRECISION;
    let amount_in = 10000;

    let balance_out = get_y(reserve + amount_in, amp, get_d(reserve, reserve, amp));
    let delta = reserve - balance_out;

    let split = 16;
    let amount_in = amount_in / split;
    let mut total_delta = 0;
    let mut current_reserve_in = reserve;
    let mut current_reserve_out = reserve;
    let mut swaps = 0;

    while (swaps < split) {
        let balance_out = get_y(current_reserve_in + amount_in, amp, get_d(current_reserve_in, current_reserve_out, amp));
        let delta = current_reserve_out - balance_out - 1;
        total_delta = total_delta + delta;
        current_reserve_out = balance_out;
        current_reserve_in = current_reserve_in + amount_in;

        swaps = swaps + 1; 
    };

    assert!(delta >= total_delta, 0);
}

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

    let amount_out = get_swap_output(
        decimal::from(1), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1,
        true, // a2b
    );

    assert_eq(amount_out, 0); // Rounds down from 0.99 to 0

    let amount_out = get_swap_output(
        decimal::from(10), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1,
        true, // a2b
    );
    
    assert_eq(amount_out, 9); // Rounds down from 9.99 to 9
    
    let amount_out = get_swap_output(
        decimal::from(100), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 99); // Rounds down from 9.99 to 9
    
    let amount_out = get_swap_output(
        decimal::from(1_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 951);


    // === Higher slippage ===

    let amount_out = get_swap_output(
        decimal::from(10_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1,
        true, // a2b
    );

    assert_eq(amount_out, 6321);

    // === Even Higher slippage ===

    let amount_out = get_swap_output(
        decimal::from(100_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1,
        true, // a2b
    );

    assert_eq(amount_out, 9999);
    
    // === Insane slippage ===

    let amount_out = get_swap_output(
        decimal::from(1_000_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1,
        true, // a2b
    );

    assert_eq(amount_out, 9999);
}

#[test]
fun test_quote_swap_impl_amp_10() {
    use sui::test_utils::assert_eq;

    let amount_out = get_swap_output(
        decimal::from(1), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        10,
        true, // a2b
    );

    assert_eq(amount_out, 0); // Rounds down from 0.99 to 0

    let amount_out = get_swap_output(
        decimal::from(10), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        10,
        true, // a2b
    );

    assert_eq(amount_out, 9); // Rounds down from 9.99 to 9
    
    let amount_out = get_swap_output(
        decimal::from(100), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        10,
        true, // a2b
    );

    assert_eq(amount_out, 99); // Rounds down from 9.99 to 9
    
    let amount_out = get_swap_output(
        decimal::from(1_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        10,
        true, // a2b
    );

    assert_eq(amount_out, 994);

    // === Higher slippage ===

    let amount_out = get_swap_output(
        decimal::from(10_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        10,
        true, // a2b
    );

    assert_eq(amount_out, 8776);

    // === Even Higher slippage ===

    let amount_out = get_swap_output(
        decimal::from(100_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        10, // amplifier
        true, // a2b
    );

    assert_eq(amount_out, 9999);
    
    // === Insane slippage ===

    let amount_out = get_swap_output(
        decimal::from(1_000_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        10,
        true, // a2b
    );

    assert_eq(amount_out, 9999);
}

#[test]
fun test_quote_swap_impl_amp_100() {
    use sui::test_utils::assert_eq;

    let amount_out = get_swap_output(
        decimal::from(1), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        100,
        true, // a2b
    );

    assert_eq(amount_out, 0); // Rounds down from 0.99 to 0

    let amount_out = get_swap_output(
        decimal::from(10), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        100,
        true, // a2b
    );

    assert_eq(amount_out, 9); // Rounds down from 9.99 to 9
    
    let amount_out = get_swap_output(
        decimal::from(100), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        100,
        true, // a2b
    );

    assert_eq(amount_out, 99); // Rounds down from 9.99 to 9
    
    let amount_out = get_swap_output(
        decimal::from(1_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        100,
        true, // a2b
    );

    assert_eq(amount_out, 999);

    // === Higher slippage ===

    let amount_out = get_swap_output(
        decimal::from(10_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        100,
        true, // a2b
    );

    assert_eq(amount_out, 9734);

    // === Even Higher slippage ===

    let amount_out = get_swap_output(
        decimal::from(100_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        100,
        true, // a2b
    );

    assert_eq(amount_out, 9999); // note: should be 999
    
    // === Insane slippage ===

    let amount_out = get_swap_output(
        decimal::from(1_000_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        100,
        true, // a2b
    );

    assert_eq(amount_out, 9999); // note: should be 999
}

#[test]
fun test_quote_swap_impl_amp_1000() {
    use sui::test_utils::assert_eq;

    let amount_out = get_swap_output(
        decimal::from(1), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1000,
        true, // a2b
    );

    assert_eq(amount_out, 0); // Rounds down from 0.99 to 0

    let amount_out = get_swap_output(
        decimal::from(10), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1000,
        true, // a2b
    );

    assert_eq(amount_out, 9); // Rounds down from 9.99 to 9
    
    let amount_out = get_swap_output(
        decimal::from(100), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1000,
        true, // a2b
    );

    assert_eq(amount_out, 99); // Rounds down from 9.99 to 9

    let amount_out = get_swap_output(
        decimal::from(1_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1000,
        true, // a2b
    );

    assert_eq(amount_out, 999);


    // === Higher slippage ===

    let amount_out = get_swap_output(
        decimal::from(10_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1000,
        true, // a2b
    );

    assert_eq(amount_out, 9955);

    // === Even Higher slippage ===

    let amount_out = get_swap_output(
        decimal::from(100_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1000,
        true, // a2b
    );

    assert_eq(amount_out, 9999);
    
    // === Insane slippage ===

    let amount_out = get_swap_output(
        decimal::from(1_000_000), // input_a
        decimal::from(10_000), // reserve_a
        decimal::from(10_000), // reserve_b
        decimal::from(1), // price_a
        decimal::from(1), // price_b
        9, // decimals_a
        9, // decimals_b
        1000,
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

