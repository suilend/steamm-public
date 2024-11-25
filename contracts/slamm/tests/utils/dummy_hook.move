#[test_only]
module slamm::dummy_hook {
    use sui::coin::Coin;
    use slamm::registry::{Registry};
    use slamm::quote::SwapQuote;
    use slamm::bank::Bank;
    use slamm::pool::{Self, Pool, PoolCap, SwapResult, Intent};

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

    public fun swap<A, B, W: drop, P>(
        self: &mut Pool<A, B, DummyQuoter<W>>,
        bank_a: &mut Bank<P, A>,
        bank_b: &mut Bank<P, B>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        amount_in: u64,
        min_amount_out: u64,
        a2b: bool,
        ctx: &mut TxContext,
    ): SwapResult {
        let intent = intent_swap(
            self,
            amount_in,
            a2b,
        );

        let result = execute_swap(
            self,
            bank_a,
            bank_b,
            intent,
            coin_a,
            coin_b,
            min_amount_out,
            ctx
        );

        result
    }

    public fun intent_swap<A, B, W: drop>(
        self: &mut Pool<A, B, DummyQuoter<W>>,
        amount_in: u64,
        a2b: bool,
    ): Intent<A, B, DummyQuoter<W>> {
        let quote = quote_swap(self, amount_in, a2b);

        quote.as_intent(self)
    }

    public fun execute_swap<A, B, W: drop, P>(
        self: &mut Pool<A, B, DummyQuoter<W>>,
        bank_a: &mut Bank<P, A>,
        bank_b: &mut Bank<P, B>,
        intent: Intent<A, B, DummyQuoter<W>>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        min_amount_out: u64,
        ctx: &mut TxContext,
    ): SwapResult {
        let response = self.swap(
            bank_a,
            bank_b,
            coin_a,
            coin_b,
            intent,
            min_amount_out,
            ctx,
        );

        response
    }

    public fun quote_swap<A, B, W: drop>(
        self: &Pool<A, B, DummyQuoter<W>>,
        amount_in: u64,
        a2b: bool,
    ): SwapQuote {
        let amount_out = amount_in;

        self.get_quote(amount_in, amount_out, a2b)
    }
}
