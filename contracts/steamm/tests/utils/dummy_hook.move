#[test_only]
module steamm::dummy_hook {
    use sui::coin::Coin;
    use steamm::registry::{Registry};
    use steamm::quote::SwapQuote;
    use steamm::pool::{Self, Pool, PoolCap, SwapResult};

    public struct DummyQuoter<phantom W> has store {}

    // ===== Public Methods =====

    public fun new_no_fees<A, B, W: drop>(
        _witness: W,
        registry: &mut Registry,
        swap_fee_bps: u64,
        ctx: &mut TxContext,
    ): (Pool<A, B, DummyQuoter<W>>, PoolCap<A, B, DummyQuoter<W>>) {
        let quoter = DummyQuoter {};

        let (mut pool, pool_cap) = pool::new<A, B, DummyQuoter<W>>(
            registry,
            swap_fee_bps,
            quoter,
            ctx,
        );

        pool.no_protocol_fees_for_testing();
        pool.no_redemption_fees_for_testing();

        (pool, pool_cap)
    }
    
    public fun new<A, B, W: drop>(
        _witness: W,
        registry: &mut Registry,
        swap_fee_bps: u64,
        ctx: &mut TxContext,
    ): (Pool<A, B, DummyQuoter<W>>, PoolCap<A, B, DummyQuoter<W>>) {
        let quoter = DummyQuoter {};

        let (pool, pool_cap) = pool::new<A, B, DummyQuoter<W>>(
            registry,
            swap_fee_bps,
            quoter,
            ctx,
        );

        (pool, pool_cap)
    }

    public fun swap<A, B, W: drop>(
        pool: &mut Pool<A, B, DummyQuoter<W>>,
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

    public fun quote_swap<A, B, W: drop>(
        pool: &Pool<A, B, DummyQuoter<W>>,
        amount_in: u64,
        a2b: bool,
    ): SwapQuote {
        let amount_out = amount_in;

        pool.get_quote(amount_in, amount_out, a2b)
    }
}
