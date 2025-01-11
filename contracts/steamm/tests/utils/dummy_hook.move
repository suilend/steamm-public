#[test_only]
module steamm::dummy_hook;

use steamm::pool::{Self, Pool, PoolCap, SwapResult};
use steamm::quote::SwapQuote;
use steamm::registry::Registry;
use sui::coin::{Coin, TreasuryCap, CoinMetadata};

public struct DummyQuoter has store {}

// ===== Public Methods =====

public fun new_no_fees<A, B, LpType: drop>(
    lp_treasury: TreasuryCap<LpType>,
    meta_a: &CoinMetadata<A>,
    meta_b: &CoinMetadata<B>,
    meta_lp: &CoinMetadata<LpType>,
    registry: &mut Registry,
    swap_fee_bps: u64,
    ctx: &mut TxContext,
): (Pool<A, B, DummyQuoter, LpType>, PoolCap<A, B, DummyQuoter, LpType>) {
    let quoter = DummyQuoter {};

    let (mut pool, pool_cap) = pool::new<A, B, DummyQuoter, LpType>(
        lp_treasury,
        meta_a,
        meta_b,
        meta_lp,
        registry,
        swap_fee_bps,
        quoter,
        ctx,
    );

    pool.no_protocol_fees_for_testing();
    pool.no_redemption_fees_for_testing();

    (pool, pool_cap)
}

public fun new<A, B, LpType: drop>(
    lp_treasury: TreasuryCap<LpType>,
    meta_a: &CoinMetadata<A>,
    meta_b: &CoinMetadata<B>,
    meta_lp: &CoinMetadata<LpType>,
    registry: &mut Registry,
    swap_fee_bps: u64,
    ctx: &mut TxContext,
): (Pool<A, B, DummyQuoter, LpType>, PoolCap<A, B, DummyQuoter, LpType>) {
    let quoter = DummyQuoter {};

    let (pool, pool_cap) = pool::new<A, B, DummyQuoter, LpType>(
        lp_treasury,
        meta_a,
        meta_b,
        meta_lp,
        registry,
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
