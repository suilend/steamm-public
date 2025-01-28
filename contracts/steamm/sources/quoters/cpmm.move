/// Constant-Product AMM Quoter implementation
module steamm::cpmm;

use std::option::none;
use steamm::global_admin::GlobalAdmin;
use steamm::math::{safe_mul_div, checked_mul_div_up};
use steamm::pool::{Self, Pool, PoolCap, SwapResult, assert_liquidity};
use steamm::quote::SwapQuote;
use steamm::version::{Self, Version};
use sui::coin::{Coin, TreasuryCap, CoinMetadata};

// ===== Constants =====

const CURRENT_VERSION: u16 = 1;

// ===== Errors =====

const EInvariantViolation: u64 = 1;
const EZeroInvariant: u64 = 2;

/// Constant-Product AMM specific state. We do not store the invariant,
/// instead we compute it at runtime.
public struct CpQuoter has store {
    version: Version,
    offset: u64,
}

// ===== Public Methods =====
/// Initializes and returns a new AMM Pool along with its associated PoolCap.
/// The pool is initialized with zero balances for both coin types `A` and `B`,
/// specified protocol fees, and the provided swap fee. The pool's LP supply
/// object is initialized at zero supply.
///
/// # Arguments
///
/// * `meta_a` - Coin metadata for coin type A
/// * `meta_b` - Coin metadata for coin type B
/// * `meta_lp` - Coin metadata for the LP token
/// * `lp_treasury` - Treasury capability for minting LP tokens
/// * `swap_fee_bps` - Swap fee in basis points
/// * `offset` - Offset value for the constant product formula
/// * `ctx` - Transaction context
///
/// # Returns
///
/// A tuple containing:
/// - `Pool<A, B, CpQuoter, LpType>`: The created AMM pool object.
/// - `PoolCap<A, B, CpQuoter, LpType>`: The associated pool capability object.
///
/// # Panics
///
/// This function will panic if `swap_fee_bps` is greater than or equal to
/// `SWAP_FEE_DENOMINATOR`
public fun new<A, B, LpType: drop>(
    meta_a: &CoinMetadata<A>,
    meta_b: &CoinMetadata<B>,
    meta_lp: &mut CoinMetadata<LpType>,
    lp_treasury: TreasuryCap<LpType>,
    swap_fee_bps: u64,
    offset: u64,
    ctx: &mut TxContext,
): (Pool<A, B, CpQuoter, LpType>, PoolCap<A, B, CpQuoter, LpType>) {
    let quoter = CpQuoter { version: version::new(CURRENT_VERSION), offset };

    let (pool, pool_cap) = pool::new<A, B, CpQuoter, LpType>(
        meta_a,
        meta_b,
        meta_lp,
        lp_treasury,
        swap_fee_bps,
        quoter,
        ctx,
    );

    (pool, pool_cap)
}

/// Executes a swap between coin A and coin B in the constant product AMM pool.
/// The swap direction is determined by the `a2b` parameter, where true indicates
/// swapping from coin A to coin B, and false indicates swapping from coin B to coin A.
///
/// # Arguments
///
/// * `pool` - The AMM pool to execute the swap in
/// * `coin_a` - Coin A to be swapped
/// * `coin_b` - Coin B to be swapped
/// * `a2b` - Direction of the swap (true = A->B, false = B->A)
/// * `amount_in` - Amount of input coin to swap
/// * `min_amount_out` - Minimum output amount for slippage protection
/// * `ctx` - Transaction context
///
/// # Returns
///
/// `SwapResult`: An object containing details of the executed swap,
/// including input and output amounts, fees, and the direction of the swap.
///
/// # Panics
///
/// This function will panic if:
/// - The pool version is not current
/// - The swap violates the constant product invariant
/// - The output amount is less than min_amount_out
public fun swap<A, B, LpType: drop>(
    pool: &mut Pool<A, B, CpQuoter, LpType>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    a2b: bool,
    amount_in: u64,
    min_amount_out: u64,
    ctx: &mut TxContext,
): SwapResult {
    pool.quoter_mut().version.assert_version_and_upgrade(CURRENT_VERSION);

    let quote = quote_swap(pool, amount_in, a2b);
    let k0 = k(pool, offset(pool));

    let response = pool.swap(
        coin_a,
        coin_b,
        quote,
        min_amount_out,
        ctx,
    );

    // Recompute invariant
    check_invariance(pool, k0, offset(pool));

    response
}

/// Quotes a swap in a constant product AMM pool. The quote is computed using the
/// constant product formula (x + dx)(y - dy) = k, where x and y are the reserves
/// plus an offset, dx is the input amount, and dy is the output amount.
/// The offset is used to prevent price manipulation when reserves are low.
/// After computing the output amount, fees are added on top.
///
/// # Arguments
///
/// * `pool` - The AMM pool to quote the swap for
/// * `amount_in` - Amount of input coin to swap
/// * `a2b` - Direction of the swap (true = A->B, false = B->A)
///
/// # Returns
///
/// `SwapQuote`: A quote object containing the input amount, output amount,
/// swap direction and fees to be charged.
public fun quote_swap<A, B, LpType: drop>(
    pool: &Pool<A, B, CpQuoter, LpType>,
    amount_in: u64,
    a2b: bool,
): SwapQuote {
    let (reserve_a, reserve_b) = pool.balance_amounts();

    let amount_out = quote_swap_impl(
        reserve_a,
        reserve_b,
        amount_in,
        pool.quoter().offset,
        a2b,
    );

    pool.get_quote(amount_in, amount_out, a2b)
}

public(package) fun quote_swap_impl(
    reserve_a: u64,
    reserve_b: u64,
    amount_in: u64,
    offset: u64,
    a2b: bool,
): u64 {
    if (a2b) {
        let amount_out = quote_swap_(
            amount_in,
            reserve_a,
            reserve_b,
            offset,
            a2b,
        );

        assert_liquidity(reserve_b, amount_out);
        return amount_out
    } else {
        let amount_out = quote_swap_(
            amount_in,
            reserve_b,
            reserve_a,
            offset,
            a2b,
        );

        assert_liquidity(reserve_a, amount_out);
        return amount_out
    }
}

// ===== View Functions =====

public fun offset<A, B, LpType: drop>(pool: &Pool<A, B, CpQuoter, LpType>): u64 {
    pool.quoter().offset
}

public fun k<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
    offset: u64,
): u128 {
    let (total_funds_a, total_funds_b) = pool.balance_amounts();
    ((total_funds_a as u128) * ((total_funds_b + offset) as u128))
}

// ===== Versioning =====

entry fun migrate<A, B, LpType: drop>(
    pool: &mut Pool<A, B, CpQuoter, LpType>,
    _admin: &GlobalAdmin,
) {
    pool.quoter_mut().version.migrate_(CURRENT_VERSION);
}

// ===== Package Functions =====

public(package) fun check_invariance<A, B, Quoter: store, LpType: drop>(
    pool: &Pool<A, B, Quoter, LpType>,
    k0: u128,
    offset: u64,
) {
    let k1 = k(pool, offset);
    assert!(k1 > 0, EZeroInvariant);
    assert!(k1 >= k0, EInvariantViolation);
}

#[test_only]
public(package) fun max_amount_in_on_a2b<A, B, LpType: drop>(
    pool: &Pool<A, B, CpQuoter, LpType>,
): Option<u64> {
    let (reserve_in, reserve_out) = pool.balance_amounts();
    let offset = offset(pool);

    if (offset == 0) {
        return none()
    };

    checked_mul_div_up(reserve_out, reserve_in, offset) // max_amount_in
}

// ===== Private Functions =====

fun quote_swap_(amount_in: u64, reserve_in: u64, reserve_out: u64, offset: u64, a2b: bool): u64 {
    // if a2b == true, a is input, b is output
    let (reserve_in_, reserve_out_) = if (a2b) {
        (reserve_in, reserve_out + offset)
    } else {
        (reserve_in + offset, reserve_out)
    };

    safe_mul_div(reserve_out_, amount_in, reserve_in_ + amount_in) // amount_out
}

// ===== Tests =====

#[test_only]
use sui::test_utils::assert_eq;

#[test]
fun test_swap_a_for_b() {
    let delta_quote = quote_swap_(1000000000, 50000000000, 50000000000, 0, false);
    assert_eq(delta_quote, 980392156);

    let delta_quote = quote_swap_(1000000000, 1095387779115020, 9999005960552740, 0, false);
    assert_eq(delta_quote, 9128271305);

    let delta_quote = quote_swap_(1000000000, 7612534772798660, 1029168250865450, 0, false);
    assert_eq(delta_quote, 135193880);

    let delta_quote = quote_swap_(1000000000, 5686051292328860, 2768608899383570, 0, false);
    assert_eq(delta_quote, 486912317);

    let delta_quote = quote_swap_(1000000000, 9283788821706570, 440197283258732, 0, false);
    assert_eq(delta_quote, 47415688);

    let delta_quote = quote_swap_(1000000000, 9313530357314980, 7199199355268960, 0, false);
    assert_eq(delta_quote, 772982779);

    let delta_quote = quote_swap_(1000000000, 1630712284783210, 6273576615700410, 0, false);
    assert_eq(delta_quote, 3847136510);

    let delta_quote = quote_swap_(1000000000, 9284728716079420, 5196638254543900, 0, false);
    assert_eq(delta_quote, 559697310);

    let delta_quote = quote_swap_(1000000000, 4632243184772740, 1128134431179110, 0, false);
    assert_eq(delta_quote, 243539499);
}
