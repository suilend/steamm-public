/// Constant-Product AMM Hook implementation
module slamm::cpmm {
    use std::option::none;
    use sui::coin::Coin;
    use slamm::{
        global_admin::GlobalAdmin,
        registry::{Registry},
        quote::SwapQuote,
        bank::Bank,
        pool::{Self, Pool, PoolCap, SwapResult, Intent, assert_liquidity},
        version::{Self, Version},
        math::{safe_mul_div, checked_mul_div}
    };

    // ===== Constants =====

    const CURRENT_VERSION: u16 = 1;

    // ===== Errors =====

    const EInvariantViolation: u64 = 1;
    const EZeroInvariant: u64 = 2;

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
        offset: u64,
    }

    // ===== Public Methods =====

    /// Initializes and returns a new AMM Pool along with its associated PoolCap.
    /// The pool is initialized with zero balances for both coin types `A` and `B`,
    /// specified protocol fees, and the provided swap fee. The pool's LP supply
    /// object is initialized at zero supply and the pool is added to the `registry`.
    ///
    /// # Returns
    ///
    /// A tuple containing:
    /// - `Pool<A, B, Hook, State>`: The created AMM pool object.
    /// - `PoolCap<A, B, Hook>`: The associated pool capability object.
    ///
    /// # Panics
    ///
    /// This function will panic if `swap_fee_bps` is greater than or equal to
    /// `SWAP_FEE_DENOMINATOR`
    public fun new_with_offset<A, B, W: drop>(
        _witness: W,
        registry: &mut Registry,
        swap_fee_bps: u64,
        offset: u64,
        ctx: &mut TxContext,
    ): (Pool<A, B, Hook<W>, State>, PoolCap<A, B, Hook<W>, State>) {
        let inner = State { version: version::new(CURRENT_VERSION), offset };

        let (pool, pool_cap) = pool::new<A, B, Hook<W>, State>(
            Hook<W> {},
            registry,
            swap_fee_bps,
            inner,
            ctx,
        );

        (pool, pool_cap)
    }
    
    public fun new<A, B, W: drop>(
        witness: W,
        registry: &mut Registry,
        swap_fee_bps: u64,
        ctx: &mut TxContext,
    ): (Pool<A, B, Hook<W>, State>, PoolCap<A, B, Hook<W>, State>) {
        new_with_offset(
            witness,
            registry,
            swap_fee_bps,
            0,
            ctx,
        )
    }

    public fun intent_swap<A, B, W: drop>(
        self: &mut Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
    ): Intent<A, B, Hook<W>, State> {
        self.inner_mut().version.assert_version_and_upgrade(CURRENT_VERSION);
        let quote = quote_swap(self, amount_in, a2b);

        quote.as_intent(self)
    }

    public fun execute_swap<A, B, W: drop, P>(
        self: &mut Pool<A, B, Hook<W>, State>,
        bank_a: &mut Bank<P, A>,
        bank_b: &mut Bank<P, B>,
        intent: Intent<A, B, Hook<W>, State>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        min_amount_out: u64,
        ctx: &mut TxContext,
    ): SwapResult {
        self.inner_mut().version.assert_version_and_upgrade(CURRENT_VERSION);

        let k0 = k(self, offset(self));

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
        check_invariance(self, k0, offset(self));

        response
    }

    // cpmm return price, take price that's best for LPs, on top we add dynamic fee
    // fees should always be computed on the output amount;
    public fun quote_swap<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
    ): SwapQuote {
        let (reserve_a, reserve_b) = self.total_funds();

        let amount_out = quote_swap_impl(
            reserve_a,
            reserve_b,
            amount_in,
            self.inner().offset,
            a2b,
        );

        self.get_quote(amount_in, amount_out, a2b)
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
    
    public fun offset<A, B, W: drop>(self: &Pool<A, B, Hook<W>, State>): u64 {
        self.inner().offset
    }
    
    public fun k<A, B, Hook: drop, State: store>(
        self: &Pool<A, B, Hook, State>,
        offset: u64,
    ): u128 {
        let (total_funds_a, total_funds_b) = self.total_funds();
        ((total_funds_a as u128) * ((total_funds_b + offset) as u128))
    }

    // ===== Versioning =====
    
    entry fun migrate<A, B, W>(
        self: &mut Pool<A, B, Hook<W>, State>,
        _cap: &PoolCap<A, B, Hook<W>, State>,
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

    // ===== Package Functions =====
    
    public(package) fun check_invariance<A, B, Hook: drop, State: store>(
        self: &Pool<A, B, Hook, State>,
        k0: u128,
        offset: u64,
    ) {
        let k1 = k(self, offset);
        assert!(k1 > 0, EZeroInvariant);
        assert!(k1 >= k0, EInvariantViolation);
    }

    public(package) fun max_amount_in_on_a2b<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
    ): Option<u64> {
        let (reserve_in, reserve_out) = self.total_funds();
        let offset = offset(self);

        if (offset == 0) {
            return none()
        };
        
        checked_mul_div(reserve_out, reserve_in, offset) // max_amount_in
    }

    // ===== Private Functions =====

    fun quote_swap_(
        amount_in: u64,
        reserve_in: u64,
        reserve_out: u64,
        offset: u64,
        a2b: bool,
    ): u64 {
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
}
