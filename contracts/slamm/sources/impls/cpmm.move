/// Constant-Product AMM Hook implementation
module slamm::cpmm {
    use sui::coin::Coin;
    use slamm::global_admin::GlobalAdmin;
    use slamm::registry::{Registry};
    use slamm::math::{safe_mul_div_u64};
    use slamm::quote::{Self, SwapQuote};
    use slamm::bank::Bank;
    use slamm::pool::{Self, Pool, PoolCap, SwapResult};

    // ===== Constants =====

    const CURRENT_VERSION: u16 = 1;

    // ===== Errors =====

    const EIncorrectVersion: u64 = 0;
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
        version: u16,
    }

    // ===== Public Methods =====

    public fun new<A, B, W: drop>(
        _witness: W,
        registry: &mut Registry,
        swap_fee_bps: u64,
        ctx: &mut TxContext,
    ): (Pool<A, B, Hook<W>, State>, PoolCap<A, B, Hook<W>>) {
        let inner = State { version: CURRENT_VERSION };

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
        assert_version_and_upgrade(self);
        let k0 = k(self);

        let quote = quote_swap(self, amount_in, a2b);

        let response = self.swap(
            Hook<W> {},
            bank_a,
            bank_b,
            coin_a,
            coin_b,
            quote,
            min_amount_out,
            ctx,
        );

        // Recompute invariant
        assert_invariant_does_not_decrease(self, k0);

        response
    }

    public fun quote_swap<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
    ): SwapQuote {
        let (reserve_a, reserve_b) = self.reserves();
        let inputs = self.compute_fees(amount_in);

        let amount_out = if (a2b) {
            // IN: A && OUT: B
            quote_swap_(
                reserve_b, // reserve_out
                reserve_a, // reserve_in
                inputs.amount_in_net(), // amount_in net of fees
            )
        } else {
            // IN: B && OUT: A
            quote_swap_(
                reserve_a, // reserve_out
                reserve_b, // reserve_in
                inputs.amount_in_net(), // amount_in net of fees
            )
        };

        quote::swap_quote(
            inputs,
            amount_out,
            a2b,
        )
    }

    // ===== View Functions =====
    
    public fun k<A, B, W: drop>(self: &Pool<A, B, Hook<W>, State>): u128 {
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
        assert!(self.inner().version < CURRENT_VERSION, EIncorrectVersion);
        self.inner_mut().version = CURRENT_VERSION;
    }

    fun assert_version<A, B, W>(
        self: &Pool<A, B, Hook<W>, State>,
    ) {
            assert!(self.inner().version == CURRENT_VERSION, EIncorrectVersion);
    }

    fun assert_version_and_upgrade<A, B, W>(
        self: &mut Pool<A, B, Hook<W>, State>,
    ) {
        if (self.inner().version < CURRENT_VERSION) {
            self.inner_mut().version = CURRENT_VERSION;
        };
        assert_version(self);
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
