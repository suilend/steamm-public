/// Oracle AMM Hook implementation
module slamm::omm {
    use std::option::none;
    use sui::coin::Coin;
    use sui::math;
    use sui::clock::{Self, Clock};
    use slamm::global_admin::GlobalAdmin;
    use slamm::registry::{Registry};
    use slamm::math::{safe_mul_div_u64};
    use slamm::quote::SwapQuote;
    use slamm::bank::Bank;
    use slamm::cpmm;
    use slamm::pool::{Self, Pool, PoolCap, SwapResult, Intent};
    use slamm::version::{Self, Version};
    use pyth::price_info::{PriceInfoObject};
    use suilend::decimal::{Self, Decimal};
    use suilend::oracles;
    use pyth::price_identifier::{PriceIdentifier};
    // use pyth::price::Price;

    // ===== Constants =====

    const CURRENT_VERSION: u16 = 1;
    const PRICE_STALENESS_THRESHOLD_S: u64 = 0;
    const BPS: u64 = 10_000;

    // ===== Errors =====

    const EInvariantViolation: u64 = 1;
    const EPriceIdentifierMismatch: u64 = 2;
    const EInvalidPrice: u64 = 3;
    const EPriceStale: u64 = 4;

    /// Hook type for the Oracle AMM implementation. Serves as both
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

    /// Oracle AMM specific state. We do not store the invariant,
    /// instead we compute it at runtime.
    public struct State has store {
        version: Version,
        price_info_a: PriceInfo,
        price_info_b: PriceInfo,
        reference_vol: u64,
        vol_accumulated: u64,
        reference_price_point: Option<Decimal>,
        last_trade_ts: u64,
        filter_period: u64,
        decay_period: u64,
        fee_control: u64,
        reduction_factor: u64,
        max_vol_accumulated: u64,
    }

    public struct PriceInfo has store {
        price_identifier: PriceIdentifier,
        price: Decimal,
        smoothed_price: Decimal,
        price_last_update_timestamp_s: u64,
    }

    // ===== Public Methods =====

    public fun new<A, B, W: drop>(
        _witness: W,
        registry: &mut Registry,
        swap_fee_bps: u64,
        price_feed_a: &PriceInfoObject,
        price_feed_b: &PriceInfoObject,
        filter_period: u64,
        decay_period: u64,
        fee_control: u64,
        reduction_factor: u64,
        max_vol_accumulated: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Pool<A, B, Hook<W>, State>, PoolCap<A, B, Hook<W>>) {
        let inner = State {
            version: version::new(CURRENT_VERSION),
            price_info_a: from_price_feed(price_feed_a, clock),
            price_info_b: from_price_feed(price_feed_b, clock),
            reference_vol: 0,
            vol_accumulated: 0,
            reference_price_point: none(),
            last_trade_ts: clock.timestamp_ms(),
            filter_period,
            decay_period,
            fee_control,
            reduction_factor,
            max_vol_accumulated,
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

    public fun swap<A, B, W: drop>(
        self: &mut Pool<A, B, Hook<W>, State>,
        bank_a: &mut Bank<A>,
        bank_b: &mut Bank<B>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        amount_in: u64,
        min_amount_out: u64,
        a2b: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): SwapResult {
        self.inner_mut().version.assert_version_and_upgrade(CURRENT_VERSION);

        let intent = intent_swap(
            self,
            amount_in,
            a2b,
            clock,
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
        clock: &Clock,
    ): Intent<A, B, Hook<W>> {
        self.inner().assert_price_is_fresh(clock);
        self.inner_mut().version.assert_version_and_upgrade(CURRENT_VERSION);
        
        // When we init the pool the reference price is not set so
        // in the first swap this option is filled
        set_reference_price_if_none(self);

        // Update price and vol reference depending on timespan ellapsed
        update_references(self, clock);

        let (quote, vol_accumulator) = quote_swap_(self, amount_in, a2b);
        
        // Update the volatility accumulator - always
        self.inner_mut().vol_accumulated = vol_accumulator;

        // Update last_trade_ts
        self.inner_mut().last_trade_ts = clock.timestamp_ms();

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

    public fun quote_swap_<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
    ): (SwapQuote, u64) {
        let (reserve_a, reserve_b) = self.reserves();

        let amount_out = cpmm::quote_swap_impl(
            reserve_a,
            reserve_b,
            amount_in,
            a2b,
        );

        let swap_outputs = self.compute_fees_on_output(amount_out);

        let mut quote = swap_outputs.to_quote(amount_in, a2b);

        let new_instant_price_internal = new_instant_price_internal(self, &quote);
        let new_instant_price_oracle = new_instant_price_oracle(self);

        let vol_accumulator = self.inner().updated_volatility_accumulator(
            new_instant_price_internal,
            new_instant_price_oracle
        );

        let variable_fee = (vol_accumulator * vol_accumulator) * self.inner().fee_control / 100; // TODO: control for bps

        let total_variable_fee = safe_mul_div_u64(quote.amount_out(), variable_fee, 10_000);
        let (protocol_fee_num, protocol_fee_denom) = self.protocol_fees().fee_ratio();

        let protocol_fees = safe_mul_div_u64(total_variable_fee, protocol_fee_num, protocol_fee_denom);
        let pool_fees = total_variable_fee - protocol_fees;

        quote.add_output_fees(protocol_fees, pool_fees);

        (quote, vol_accumulator)
    }
    
    public fun quote_swap<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
    ): SwapQuote {
        let (quote, _) = quote_swap_(self, amount_in, a2b);

        quote
    }

    public fun new_instant_price_internal<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        quote: &SwapQuote
    ): Decimal {
        let (a, b) = if (quote.a2b()) {
            (
                self.reserve_a() + quote.amount_in_net_of_protocol_fees(),
                self.reserve_b() - quote.amount_out_net_of_protocol_fees()
            )
        } else {
            (
                self.reserve_a() - quote.amount_out_net_of_protocol_fees(),
                self.reserve_b() + quote.amount_in_net_of_protocol_fees(),
            )
        };

        decimal::from(a).div(decimal::from(b))
    }
    
    public fun new_instant_price_oracle<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>
    ): Decimal {

        get_oracle_price(
            self.inner().price_info_a.price,
            self.inner().price_info_b.price
        )
    }

    /// Cache the price from pyth onto the state object. this needs to be done
    /// before swapping
    public fun refresh_reserve_prices<A, B, W: drop>(
        self: &mut Pool<A, B, Hook<W>, State>,
        price_feed_a: &PriceInfoObject,
        price_feed_b: &PriceInfoObject,
        clock: &Clock,
    ) {
        self.inner_mut().version.assert_version_and_upgrade(CURRENT_VERSION);

        self.inner_mut().price_info_a.update_price(price_feed_a, clock);
        self.inner_mut().price_info_b.update_price(price_feed_b, clock);
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
        self.inner_mut().version.migrate_(CURRENT_VERSION);
    }

    // ===== Assert Functions =====

    // make sure we are using the latest published price on sui
    public fun assert_price_is_fresh(
        self: &State,
        clock: &Clock,
    ) {
        let cur_time_s = clock::timestamp_ms(clock) / 1000;
        assert!(
            cur_time_s - self.price_info_a.price_last_update_timestamp_s <= PRICE_STALENESS_THRESHOLD_S, 
            EPriceStale
        );
        
        assert!(
            cur_time_s - self.price_info_b.price_last_update_timestamp_s <= PRICE_STALENESS_THRESHOLD_S, 
            EPriceStale
        );
    }
    
    
    // ===== Private Functions =====

    fun update_references<A, B, W: drop>(
        self: &mut Pool<A, B, Hook<W>, State>,
        clock: &Clock,
    ) {
        let state = self.inner();
        let time_elapsed = clock.timestamp_ms() - state.last_trade_ts;

        // Ths is kept here to make it more readable
        if (time_elapsed < state.filter_period) {
            return
        };

        if (time_elapsed >= state.filter_period && time_elapsed <= state.decay_period) {
            let reduction_factor = self.inner().reduction_factor;
            let vol_accumulated = self.inner().vol_accumulated;

            self.inner_mut().reference_vol = vol_accumulated * reduction_factor / BPS;
            set_reference_price(self);

            return
        };

        if (time_elapsed > state.decay_period) {
            self.inner_mut().reference_vol = 0;
            set_reference_price(self);
        }
    }

    fun set_reference_price<A, B, W: drop>(
        self: &mut Pool<A, B, Hook<W>, State>,
    ) {
        let instant_price = new_instant_price_oracle(self);

        self.inner_mut().reference_price_point.fill(instant_price);
    }
    
    fun set_reference_price_if_none<A, B, W: drop>(
        self: &mut Pool<A, B, Hook<W>, State>,
    ) {
        if (self.inner().reference_price_point.is_none()) {
            set_reference_price(self);
        }
    }

    fun updated_volatility_accumulator(
        self: &State,
        new_price_internal: Decimal,
        new_price_oracle: Decimal,
    ): u64 {
        let price_diff_bps = math::max(
            self.compute_price_diff_bps(new_price_internal),
            self.compute_price_diff_bps(new_price_oracle)
        );
        self.reference_vol + price_diff_bps
    }
    
    fun compute_price_diff_bps(
        self: &State,
        new_price: Decimal,
    ): u64 {
        let reference_price = *self.reference_price_point.borrow();

        if (new_price.ge(reference_price)) {
            new_price.sub(reference_price).div(reference_price).floor() * BPS
        } else {
            reference_price.sub(new_price).div(reference_price).floor() * BPS
        }
    }

    fun assert_invariant_does_not_decrease<A, B, W: drop>(self: &Pool<A, B, Hook<W>, State>, k0: u128) {
        let k1 = k(self);
        assert!(k1 >= k0, EInvariantViolation);
    }

    fun from_price_feed(
        price_feed: &PriceInfoObject,
        clock: &Clock,
    ): PriceInfo {
        let (mut price, smoothed_price, price_identifier) = oracles::get_pyth_price_and_identifier(price_feed, clock);

        PriceInfo {
            price_identifier,
            price: option::extract(&mut price),
            smoothed_price,
            price_last_update_timestamp_s: clock::timestamp_ms(clock) / 1000,
        }
    }

    fun update_price(
        self: &mut PriceInfo,
        price_feed: &PriceInfoObject,
        clock: &Clock,
    ) {
        let (mut price, smoothed_price, price_identifier) = oracles::get_pyth_price_and_identifier(price_feed, clock);
        assert!(price_identifier == self.price_identifier, EPriceIdentifierMismatch);
        assert!(option::is_some(&price), EInvalidPrice);

        self.price = option::extract(&mut price);
        self.smoothed_price = smoothed_price;
        self.price_last_update_timestamp_s = clock::timestamp_ms(clock) / 1000;
    }

    #[allow(unused_function)]
    fun get_oracle_output_amount(
        amount_in: u64,
        input_price: Decimal,
        output_price: Decimal
    ): u64 {
        decimal::from(amount_in).mul(input_price).div(output_price).floor()
    }
    
    fun get_oracle_price(
        price_a: Decimal,
        price_b: Decimal
    ): Decimal {
        price_a.div(price_b)
    }
}
