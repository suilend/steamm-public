/// Fixed Range Constant-Sum AMM Hook implementation
module slamm::smm {
    use sui::coin::Coin;
    use slamm::{
        global_admin::GlobalAdmin,
        registry::{Registry},
        quote::SwapQuote,
        bank::Bank,
        pool::{Self, Pool, PoolCap, SwapResult, Intent},
        version::{Self, Version},
    };
    use suilend::decimal::{Self, Decimal};

    // ===== Constants =====

    const CURRENT_VERSION: u16 = 1;

    // ===== Errors =====

    const EInvariantViolation: u64 = 1;
    const EInvalidReserveRatio: u64 = 2;

    /// Hook type for the constant-sum AMM implementation. Serves as both
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

    /// Constant-Sum AMM specific state. We do not store the invariant,
    /// instead we compute it at runtime.
    public struct State has store {
        upper_reserve_ratio: Decimal,
        lower_reserve_ratio: Decimal,
        version: Version,
    }

    // ===== Public Methods =====

    public fun new<A, B, W: drop>(
        _witness: W,
        registry: &mut Registry,
        swap_fee_bps: u64,
        upper_reserve_ratio_bps: u64,
        lower_reserve_ratio_bps: u64,
        ctx: &mut TxContext,
    ): (Pool<A, B, Hook<W>, State>, PoolCap<A, B, Hook<W>>) {
        let inner = State {
            version: version::new(CURRENT_VERSION),
            upper_reserve_ratio: decimal::from(upper_reserve_ratio_bps).div(decimal::from(10_000)),
            lower_reserve_ratio: decimal::from(lower_reserve_ratio_bps).div(decimal::from(10_000)),
        };

        let (pool, pool_cap) = pool::new<A, B, Hook<W>, State>(
            Hook<W> {},
            registry,
            swap_fee_bps,
            inner,
            ctx,
        );

        (pool, pool_cap)
    }

    public fun swap<A, B, W: drop, P>(
        self: &mut Pool<A, B, Hook<W>, State>,
        bank_a: &mut Bank<P, A>,
        bank_b: &mut Bank<P, B>,
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

    public fun execute_swap<A, B, W: drop, P>(
        self: &mut Pool<A, B, Hook<W>, State>,
        bank_a: &mut Bank<P, A>,
        bank_b: &mut Bank<P, B>,
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
        assert_reserve_ratio(self);
        assert_invariant_does_not_decrease(self, k0);

        response
    }

    public fun quote_swap<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
    ): SwapQuote {
        let amount_out = amount_in;

        let output = self.compute_fees_on_output(amount_out);

        output.to_quote(
            amount_in,
            a2b,
        )
    }
    
    // ===== Assert Functions =====

    fun check_reserve_ratio<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
    ): bool {
        let a = decimal::from(self.reserve_a());
        let b = decimal::from(self.reserve_b());
        let ratio = a.div(b);

        ratio.le(self.inner().upper_reserve_ratio) && ratio.ge(self.inner().lower_reserve_ratio)
    }
    
    fun assert_reserve_ratio<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
    ) {
        assert!(check_reserve_ratio(self), EInvalidReserveRatio);
    }
    
    
    // ===== View Functions =====
    
    public fun k<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): u128 {
        let (reserve_a, reserve_b) = self.reserves();
        ((reserve_a as u128) + (reserve_b as u128))
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
    
    public(package) fun assert_invariant_does_not_decrease<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>, k0: u128) {
        let k1 = k(self);
        assert!(k1 >= k0, EInvariantViolation);
    }
}
