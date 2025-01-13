#[test_only]
module steamm::dummy_quoter;

use steamm::pool::{Self, Pool, PoolCap, SwapResult};
use steamm::quote::SwapQuote;
use sui::coin::{Coin, TreasuryCap, CoinMetadata};

public struct DummyQuoter has store {}

// ===== Public Methods =====

public fun new<A, B, LpType: drop>(
    meta_a: &CoinMetadata<A>,
    meta_b: &CoinMetadata<B>,
    meta_lp: &mut CoinMetadata<LpType>,
    lp_treasury: TreasuryCap<LpType>,
    swap_fee_bps: u64,
    ctx: &mut TxContext,
): (Pool<A, B, DummyQuoter, LpType>, PoolCap<A, B, DummyQuoter, LpType>) {
    let quoter = DummyQuoter {};

    let (pool, pool_cap) = pool::new<A, B, DummyQuoter, LpType>(
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

public fun swap<A, B, LpType: drop>(
    pool: &mut Pool<A, B, DummyQuoter, LpType>,
    coin_a: &mut Coin<A>,
    coin_b: &mut Coin<B>,
    a2b: bool,
    amount_in: u64,
    min_amount_out: u64,
    ctx: &mut TxContext,
): SwapResult {
    let quote = quote_swap(pool, amount_in, a2b);

    let response = pool.swap(
        coin_a,
        coin_b,
        quote,
        min_amount_out,
        ctx,
    );

    response
}

public fun quote_swap<A, B, LpType: drop>(
    pool: &Pool<A, B, DummyQuoter, LpType>,
    amount_in: u64,
    a2b: bool,
): SwapQuote {
    let amount_out = amount_in;

    pool.get_quote(amount_in, amount_out, a2b)
}
