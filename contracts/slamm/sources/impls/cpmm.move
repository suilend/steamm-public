/// Constant-Product AMM Hook implementation
module slamm::cpmm {
    use sui::coin::Coin;
    use slamm::registry::{Registry};
    use slamm::math::{safe_mul_div_u64};
    use slamm::quote::{Self, SwapQuote};
    use slamm::pool::{Self, Pool, PoolCap, SwapResult};

    // Error codes
    const EInvariantViolation: u64 = 5;

    /// Hook type for the constant-product AMM implementation. Serves as both
    /// the hook's witness (authentication) as well as it wraps around the pool
    /// creator's witness.admin_fees
    /// 
    /// This has the advantage that we do not require an extra generic
    /// type on the `Pool` object.
    /// 
    /// Other hook implementations can decide to leverage this property and
    /// provide pathways for the inner witness contract to add further logic,
    /// therefore making the hook extendable.
    public struct Hook<phantom W> has drop {}

    /// Constant-Product AMM specific state
    public struct State has store {}

    // ===== Public Methods =====

    public fun new<A, B, W: drop>(
        _witness: W,
        registry: &mut Registry,
        swap_fee_bps: u64,
        ctx: &mut TxContext,
    ): (Pool<A, B, Hook<W>, State>, PoolCap<A, B, Hook<W>>) {
        let inner = State {};

        let (pool, pool_cap) = pool::new<A, B, Hook<W>, State>(
            Hook<W> {},
            registry,
            swap_fee_bps,
            inner,
            ctx,
        );

        (pool, pool_cap)
    }

    

    public fun swap<A, B, W: drop>(
        self: &mut Pool<A, B, Hook<W>, State>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        amount_in: u64,
        min_amount_out: u64,
        a2b: bool,
        ctx: &mut TxContext,
    ): SwapResult {
        let k0 = k(self);

        let quote = quote_swap(
            self,
            amount_in,
            a2b,
        );

        let response = self.swap(
            Hook<W> {},
            coin_a,
            coin_b,
            amount_in,
            quote.amount_out(),
            min_amount_out,
            a2b,
            ctx,
        );

        // Recompute invariant
        assert_invariant_does_not_decrease(self, k0);

        response
    }

    // ===== View & Getters =====

    public fun quote_swap<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
    ): SwapQuote {
        let (reserve_a, reserve_b) = self.reserves();
        let (net_amount_in, protocol_fees, admin_fees) = self.net_amount_in(amount_in);

        let amount_out = if (a2b) {
            // IN: A && OUT: B
            quote_swap_(
                reserve_b, // reserve_out
                reserve_a, // reserve_in
                net_amount_in, // amount_in
            )
        } else {
            // IN: B && OUT: A
            quote_swap_(
                reserve_a, // reserve_out
                reserve_b, // reserve_in
                net_amount_in, // amount_in
            )
        };

        quote::swap_quote(
            amount_in,
            amount_out,
            protocol_fees,
            admin_fees,
            a2b,
        )
    }
    
    public fun k<A, B, W: drop>(self: &Pool<A, B, Hook<W>, State>): u128 {
        let (reserve_a, reserve_b) = self.reserves();
        ((reserve_a as u128) * (reserve_b as u128))
    }

    // ===== Private Functions =====

    fun quote_swap_(
        reserve_out: u64,
        reserve_in: u64,
        amount_in: u64
    ): u64 {
        safe_mul_div_u64(reserve_out, amount_in, reserve_in + amount_in) // amount_out
    }
    
    fun assert_invariant_does_not_decrease<A, B, W: drop>(self: &Pool<A, B, Hook<W>, State>, k0: u128) {
        let k1 = k(self);
        assert!(k1 >= k0, EInvariantViolation);
    }
    
    // ===== Tests =====

    // #[test_only]
    // use sui::test_utils::assert_eq;

    // #[test]
    // fun test_swap_base_for_quote() {
    //     let delta_quote = quote_swap_(50000000000, 50000000000, 1000000000);
    //     assert_eq(delta_quote, 980392156);

    //     let delta_quote = quote_swap_(9999005960552740, 1095387779115020, 1000000000);
    //     assert_eq(delta_quote, 9128271305);

    //     let delta_quote = quote_swap_(1029168250865450, 7612534772798660, 1000000000);
    //     assert_eq(delta_quote, 135193880);
        	
    //     let delta_quote = quote_swap_(2768608899383570, 5686051292328860, 1000000000);
    //     assert_eq(delta_quote, 486912317);

    //     let delta_quote = quote_swap_(440197283258732, 9283788821706570, 1000000000);
    //     assert_eq(delta_quote, 47415688);

    //     let delta_quote = quote_swap_(7199199355268960, 9313530357314980, 1000000000);
    //     assert_eq(delta_quote, 772982779);

    //     let delta_quote = quote_swap_(6273576615700410, 1630712284783210, 1000000000);
    //     assert_eq(delta_quote, 3847136510);

    //     let delta_quote = quote_swap_(5196638254543900, 9284728716079420, 1000000000);
    //     assert_eq(delta_quote, 559697310);

    //     let delta_quote = quote_swap_(1128134431179110, 4632243184772740, 1000000000);
    //     assert_eq(delta_quote, 243539499);
    // }

    // #[test]
    // fun test_deposit_liquidity_inner() {
    //     let (delta_a, delta_b, lp_tokens) = quote_deposit_(
    //         50_000_000, // reserve_a
    //         50_000_000, // reserve_b
    //         1_000_000_000, // lp_supply
    //         50_000_000, // max_base
    //         250_000_000, // max_quote,
    //         0, // min_a
    //         0, // min_b
    //     );

    //     assert_eq(delta_a, 50_000_000);
    //     assert_eq(delta_b, 50_000_000);
    //     assert_eq(lp_tokens, 1_000_000_000);
        
    //     let (delta_, delta_b, lp_tokens) = quote_deposit_(
    //         995904078539, // reserve_a
    //         433683167230, // reserve_b
    //         1_000_000_000, // lp_supply
    //         993561515, // max_base
    //         4685420547, // max_quote,
    //         0, // min_a
    //         0, // min_b
    //     );

    //     assert_eq(delta_, 993561515);
    //     assert_eq(delta_b, 432663058);
    //     assert_eq(lp_tokens, 997647);
        
        
    //     let (delta_, delta_b, lp_tokens) = quote_deposit_(
    //         431624541156, // reserve_a
    //         136587560238, // reserve_b
    //         1_000_000_000, // lp_supply
    //         167814009, // max_base
    //         5776084236, // max_quote,
    //         0, // min_a
    //         0, // min_b
    //     );

    //     assert_eq(delta_, 167814009);
    //     assert_eq(delta_b, 53104733);
    //     assert_eq(lp_tokens, 388796);
	
        
    //     let (delta_, delta_b, lp_tokens) = quote_deposit_(
    //         814595492359, // reserve_a
    //         444814121159, // reserve_b
    //         1_000_000_000, // lp_supply
    //         5792262291, // max_base
    //         6821001626, // max_quote,
    //         0, // min_a
    //         0, // min_b
    //     );

    //     assert_eq(delta_, 5792262291);
    //     assert_eq(delta_b, 3162895062);
    //     assert_eq(lp_tokens, 7110599);
        
    //     let (delta_, delta_b, lp_tokens) = quote_deposit_(
    //         6330406121, // reserve_a
    //         45207102784, // reserve_b
    //         1_000_000_000, // lp_supply
    //         1432889520, // max_base
    //         1335572325, // max_quote,
    //         0, // min_a
    //         0, // min_b
    //     );

    //     assert_eq(delta_, 187021832);
    //     assert_eq(delta_b, 1335572325);
    //     assert_eq(lp_tokens, 29543417);

    //     let (delta_, delta_b, lp_tokens) = quote_deposit_(420297244854, 316982205287, 6_606_760_618_411_090, 4995214965, 3570130297, 0, 0);

    //     assert_eq(delta_, 4733754458);
    //     assert_eq(delta_b, 3570130297);
    //     assert_eq(lp_tokens, 74411105267193);

    //     let (delta_, delta_b, lp_tokens) = quote_deposit_(413062764570, 603795453491, 1_121_070_850_572_460, 1537859755, 8438693476, 0, 0);

    //     assert_eq(delta_, 1537859755);
    //     assert_eq(delta_b, 2247970061);
    //     assert_eq(lp_tokens, 4173820279327);

    //     let (delta_, delta_b, lp_tokens) = quote_deposit_(307217683947, 761385620952, 4_042_886_943_071_790, 3998100768, 108790920, 0, 0);

    //     assert_eq(delta_, 43896934);
    //     assert_eq(delta_b, 108790920);
    //     assert_eq(lp_tokens, 577669680434);

    //     let (delta_, delta_b, lp_tokens) = quote_deposit_(42698336282, 948435467841, 2_431_942_296_016_960, 6236994835, 8837546234, 0, 0);

    //     assert_eq(delta_, 397864202);
    //     assert_eq(delta_b, 8837546234);
    //     assert_eq(lp_tokens, 22660901223983);

    //     let (delta_, delta_b, lp_tokens) = quote_deposit_(861866936755, 638476503150, 244_488_474_179_102, 886029611, 7520096624, 0, 0);

    //     assert_eq(delta_, 886029611);
    //     assert_eq(delta_b, 656376365);
    //     assert_eq(lp_tokens, 251342774830);
    // }
    
    // #[test]
    // fun test_redeem_liquidity_inner() {
    //     let (base_withdraw, quote_withdraw) = quote_redeem_(
    //         50_000_000, // reserve_a
    //         50_000_000, // reserve_b
    //         1_000_000_000, // lp_supply
    //         542816471, // lp_tokens
    //         0, // min_base
    //         0, // min_quote
    //     );

    //     assert_eq(base_withdraw, 27140823);
    //     assert_eq(quote_withdraw, 27140823);

    //     let (base_withdraw, quote_withdraw) = quote_redeem_(995904078539, 433683167230, 1000000000, 389391649, 0, 0);
    //     assert_eq(quote_withdraw, 168872603631);
    //     assert_eq(base_withdraw, 387796731388);

    //     let (base_withdraw, quote_withdraw) = quote_redeem_(431624541156, 136587560238, 1000000000, 440552590, 0, 0);
    //     assert_eq(base_withdraw, 190153309513);
    //     assert_eq(quote_withdraw, 60174003424);

    //     let (base_withdraw, quote_withdraw) = quote_redeem_(814595492359, 444814121159, 1000000000, 996613035, 0, 0);
    //     assert_eq(base_withdraw, 811836485937);
    //     assert_eq(quote_withdraw, 443307551299);

    //     let (base_withdraw, quote_withdraw) = quote_redeem_(6330406121, 45207102784, 1000000000, 12810274, 0, 0);
    //     assert_eq(base_withdraw, 81094236);
    //     assert_eq(quote_withdraw, 579115373);

    //     let (base_withdraw, quote_withdraw) = quote_redeem_(420297244854, 316982205287, 6606760618411090, 2045717643009200, 0, 0);
    //     assert_eq(base_withdraw, 130140857035);
    //     assert_eq(quote_withdraw, 98150383724);

    //     let (base_withdraw, quote_withdraw) = quote_redeem_(413062764570, 603795453491, 1121070850572460, 551538827364816, 0, 0);
    //     assert_eq(base_withdraw, 203216551998);
    //     assert_eq(quote_withdraw, 297052265890);

    //     let (base_withdraw, quote_withdraw) = quote_redeem_(307217683947, 761385620952, 4042886943071790, 2217957798004580, 0, 0);
    //     assert_eq(base_withdraw, 168541902702);
    //     assert_eq(quote_withdraw, 417701805432);

    //     let (base_withdraw, quote_withdraw) = quote_redeem_(42698336282, 948435467841, 2431942296016960, 59368562297754, 0, 0);
    //     assert_eq(base_withdraw, 1042351556);
    //     assert_eq(quote_withdraw, 23153201558);

    //     let (base_withdraw, quote_withdraw) = quote_redeem_(861866936755, 638476503150, 244488474179102, 129992518389093, 0, 0);
    //     assert_eq(base_withdraw, 458247588158);
    //     assert_eq(quote_withdraw, 339472725065);
    // }
}
