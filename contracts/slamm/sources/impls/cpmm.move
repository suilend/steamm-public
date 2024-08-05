/// Constant-Product AMM Hook implementation
module slamm::cpmm {
    use sui::coin::Coin;
    use slamm::global_admin::GlobalAdmin;
    use slamm::registry::{Registry};
    use slamm::math::safe_mul_div;
    use slamm::quote::SwapQuote;
    use slamm::bank::Bank;
    use slamm::pool::{Self, Pool, PoolCap, SwapResult, Intent};
    use slamm::version::{Self, Version};

    // ===== Constants =====

    const CURRENT_VERSION: u16 = 1;

    // ===== Errors =====

    const EInvariantViolation: u64 = 1;

    /// Hook type for the constant-product AMM implementation. Serves as both
    /// the hook's witness (authentication) as well as it wraps around the pool
    /// creator's witness.
    /// 
    /// This has the advantage that we do not require an extra generic
    /// type on the `Pool` object.
    /// 
    /// Other hook implementations can decide to leverage this property and
    /// provide pathways for the inner witness contract to add further logic,
    /// therefore making the hook extendable.
    public struct Hook<phantom W> has drop {}

    /// Constant-Product AMM specific state. We do not store the invariant,
    /// instead we compute it at runtime.
    public struct State has store {
        version: Version,
    }

    // ===== Public Methods =====

    public fun new<A, B, W: drop>(
        _witness: W,
        registry: &mut Registry,
        swap_fee_bps: u64,
        ctx: &mut TxContext,
    ): (Pool<A, B, Hook<W>, State>, PoolCap<A, B, Hook<W>>) {
        let inner = State { version: version::new(CURRENT_VERSION) };

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
        bank_a: &mut Bank<A>,
        bank_b: &mut Bank<B>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        amount_in: u64,
        min_amount_out: u64,
        a2b: bool,
        ctx: &mut TxContext,
    ): SwapResult {
        self.inner_mut().version.assert_version_and_upgrade(CURRENT_VERSION);

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
        self: &mut Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
    ): Intent<A, B, Hook<W>> {
        self.inner_mut().version.assert_version_and_upgrade(CURRENT_VERSION);
        let quote = quote_swap(self, amount_in, a2b);

        quote.as_intent(self)
    }

    public fun execute_swap<A, B, W: drop>(
        self: &mut Pool<A, B, Hook<W>, State>,
        bank_a: &mut Bank<A>,
        bank_b: &mut Bank<B>,
        intent: Intent<A, B, Hook<W>>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        min_amount_out: u64,
        ctx: &mut TxContext,
    ): SwapResult {
        self.inner_mut().version.assert_version_and_upgrade(CURRENT_VERSION);

        let k0 = k(self);

        let response = self.swap(
            Hook<W> {},
            bank_a,
            bank_b,
            coin_a,
            coin_b,
            intent,
            min_amount_out,
            ctx,
        );

        // Recompute invariant
        assert_invariant_does_not_decrease(self, k0);

        response
    }

    // cpmm return price, take price that's best for LPs, on top we add dynamic fee
    // fees should always be computed on the output amount;

    public fun quote_swap<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
    ): SwapQuote {
        let (reserve_a, reserve_b) = self.reserves();

        let amount_out = quote_swap_impl(
            reserve_a,
            reserve_b,
            amount_in,
            a2b,
        );

        let output = self.compute_fees_on_output(amount_out);

        output.to_quote(
            amount_in,
            a2b,
        )
    }
    
    public(package) fun quote_swap_impl(
        reserve_a: u64,
        reserve_b: u64,
        amount_in: u64,
        a2b: bool,
    ): u64 {
        if (a2b) {
            // IN: A && OUT: B
            quote_swap_(
                reserve_b, // reserve_out
                reserve_a, // reserve_in
                amount_in,
            )
        } else {
            // IN: B && OUT: A
            quote_swap_(
                reserve_a, // reserve_out
                reserve_b, // reserve_in
                amount_in,
            )
        }
    }

    // ===== View Functions =====
    
    public fun k<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): u128 {
        let (reserve_a, reserve_b) = self.reserves();
        ((reserve_a as u128) * (reserve_b as u128))
    }

    // ===== Versioning =====
    
    entry fun migrate<A, B, W>(
        self: &mut Pool<A, B, Hook<W>, State>,
        _cap: &PoolCap<A, B, Hook<W>>,
    ) {
        migrate_(self);
    }
    
    entry fun migrate_as_global_admin<A, B, W>(
        self: &mut Pool<A, B, Hook<W>, State>,
        _admin: &GlobalAdmin,
    ) {
        migrate_(self);
    }

    fun migrate_<A, B, W>(
        self: &mut Pool<A, B, Hook<W>, State>,
    ) {
        self.inner_mut().version.migrate_(CURRENT_VERSION);
    }

    // ===== Private Functions =====

    fun quote_swap_(
        reserve_out: u64,
        reserve_in: u64,
        amount_in: u64
    ): u64 {
        safe_mul_div(reserve_out, amount_in, reserve_in + amount_in) // amount_out
    }
    
    public(package) fun assert_invariant_does_not_decrease<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>, k0: u128) {
        let k1 = k(self);
        assert!(k1 >= k0, EInvariantViolation);
    }
    
    // ===== Tests =====

    #[test_only]
    use sui::test_utils::assert_eq;

    #[test]
    fun test_swap_base_for_quote() {
        let delta_quote = quote_swap_(50000000000, 50000000000, 1000000000);
        assert_eq(delta_quote, 980392156);

        let delta_quote = quote_swap_(9999005960552740, 1095387779115020, 1000000000);
        assert_eq(delta_quote, 9128271305);

        let delta_quote = quote_swap_(1029168250865450, 7612534772798660, 1000000000);
        assert_eq(delta_quote, 135193880);
        	
        let delta_quote = quote_swap_(2768608899383570, 5686051292328860, 1000000000);
        assert_eq(delta_quote, 486912317);

        let delta_quote = quote_swap_(440197283258732, 9283788821706570, 1000000000);
        assert_eq(delta_quote, 47415688);

        let delta_quote = quote_swap_(7199199355268960, 9313530357314980, 1000000000);
        assert_eq(delta_quote, 772982779);

        let delta_quote = quote_swap_(6273576615700410, 1630712284783210, 1000000000);
        assert_eq(delta_quote, 3847136510);

        let delta_quote = quote_swap_(5196638254543900, 9284728716079420, 1000000000);
        assert_eq(delta_quote, 559697310);

        let delta_quote = quote_swap_(1128134431179110, 4632243184772740, 1000000000);
        assert_eq(delta_quote, 243539499);
    }
}
