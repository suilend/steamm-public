/// Oracle AMM Hook implementation
module slamm::omm {
    // use std::debug::print;
    use sui::coin::Coin;
    use sui::clock::{Self, Clock};
    use slamm::global_admin::GlobalAdmin;
    use slamm::registry::{Registry};
    use slamm::math::safe_mul_div_up;
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

    const EPriceIdentifierMismatch: u64 = 1;
    const EInvalidPrice: u64 = 2;
    const EPriceStale: u64 = 3;
    const EPriceInfoIsZero: u64 = 4;

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
        reference_price: Decimal,
        ema: Ema,
        last_update_ms: u64,
        filter_period: u64,
        decay_period: u64,
        fee_control: Decimal,
    }

    public struct Ema has store {
        reference_val: Decimal,
        accumulator: Decimal,
        reduction_factor: Decimal,
        max_accumulator: Decimal,
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
        fee_control_bps: u64,
        reduction_factor_bps: u64,
        max_vol_accumulated_bps: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Pool<A, B, Hook<W>, State>, PoolCap<A, B, Hook<W>>) {
        let price_info_a = from_price_feed(price_feed_a, clock);
        let price_info_b = from_price_feed(price_feed_b, clock);
        let reference_price = new_instant_price_oracle_(&price_info_a, &price_info_b);
        
        let inner = State {
            version: version::new(CURRENT_VERSION),
            price_info_a,
            price_info_b,
            ema: Ema {
                reference_val: decimal::from(0),
                accumulator: decimal::from(0),
                reduction_factor: decimal::from(reduction_factor_bps).div(decimal::from(BPS)),
                max_accumulator: decimal::from(max_vol_accumulated_bps).div(decimal::from(BPS)),
            },
            reference_price,
            last_update_ms: clock.timestamp_ms(),
            filter_period,
            decay_period,
            fee_control: decimal::from(fee_control_bps).div(decimal::from(BPS)),
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
        self.inner_mut().version.assert_version_and_upgrade(CURRENT_VERSION);

        let (quote, reference_price, reference_vol, vol_accumulator, last_update_ms) = quote_swap_impl(
            self, amount_in, a2b, clock.timestamp_ms()
        );
        
        // Update parameters
        self.inner_mut().ema.accumulator = vol_accumulator;
        self.inner_mut().reference_price = reference_price;
        self.inner_mut().ema.reference_val = reference_vol;
        self.inner_mut().last_update_ms = last_update_ms;

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

        let k0 = cpmm::k(self);

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
        cpmm::assert_invariant_does_not_decrease(self, k0);

        response
    }

    public(package) fun quote_swap_impl<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
        current_ms: u64,
    ): (SwapQuote, Decimal, Decimal, Decimal, u64) {
        self.inner().assert_price_is_fresh_(current_ms);
        quote_swap_(self, amount_in, a2b, current_ms)
    }
    
    fun quote_swap_<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
        current_ms: u64,
    ): (SwapQuote, Decimal, Decimal, Decimal, u64) {
        self.inner().assert_price_is_fresh_(current_ms);
        let (reserve_a, reserve_b) = self.reserves();

        // Update price and vol reference depending on timespan ellapsed
        let (reference_price, reference_vol, last_update_ms) = get_updated_references(self, current_ms);

        let amount_out = cpmm::quote_swap_impl(
            reserve_a,
            reserve_b,
            amount_in,
            a2b,
            0, // TODO: confirm if offset feature should be offered in this hook
            0, // TODO: confirm if offset feature should be offered in this hook
        );

        let swap_outputs = self.compute_fees_on_output(amount_out);

        let mut quote = swap_outputs.to_quote(amount_in, a2b);

        let new_instant_price_internal = new_instant_price_internal(self, &quote);
        let new_instant_price_oracle = new_instant_price_oracle(self);

        let vol_accumulator = self.inner().new_volatility_accumulator(
            reference_price,
            reference_vol,
            new_instant_price_internal,
            new_instant_price_oracle
        );

        let variable_fee = vol_accumulator.pow(2).mul(self.inner().fee_control).div(decimal::from(100));

        let total_variable_fee = decimal::from(quote.amount_out()).mul(variable_fee).ceil();
        let (protocol_fee_num, protocol_fee_denom) = self.protocol_fees().fee_ratio();

        let protocol_fees = safe_mul_div_up(total_variable_fee, protocol_fee_num, protocol_fee_denom);
        let pool_fees = total_variable_fee - protocol_fees;

        quote.add_output_fees(protocol_fees, pool_fees);

        (quote, reference_price, reference_vol, vol_accumulator, last_update_ms)
    }
    
    public fun compute_variable_fee_rate(
        vol_accumulator: Decimal,
        fee_control: Decimal,
    ): Decimal {
        vol_accumulator.pow(2).mul(fee_control).div(decimal::from(100))
    }
    
    public fun quote_swap<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
        clock: &Clock,
    ): SwapQuote {
        let (quote, _, _, _, _) = quote_swap_impl(self, amount_in, a2b, clock.timestamp_ms());

        quote
    }

    public fun new_instant_price_internal<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        quote: &SwapQuote
    ): Decimal {
        let (a, b) = if (quote.a2b()) {
            (
                self.reserve_a() + quote.amount_in(),
                self.reserve_b() - quote.amount_out_net_of_protocol_fees()
            )
        } else {
            (
                self.reserve_a() - quote.amount_out_net_of_protocol_fees(),
                self.reserve_b() + quote.amount_in(),
            )
        };

        decimal::from(a).div(decimal::from(b))
    }
    
    public fun instant_price_internal<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
    ): Decimal {
        decimal::from(self.reserve_a()).div(decimal::from(self.reserve_b()))
    }
    
    public fun new_instant_price_oracle<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>
    ): Decimal {
        new_instant_price_oracle_(
            &self.inner().price_info_a,
            &self.inner().price_info_b,
        )
    }
    
    public fun new_instant_price_oracle_(
        price_info_a: &PriceInfo,
        price_info_b: &PriceInfo,
    ): Decimal {
        assert!(price_info_a.price.gt(decimal::from(0)), EPriceInfoIsZero);
        assert!(price_info_b.price.gt(decimal::from(0)), EPriceInfoIsZero);
        
        get_oracle_price(
            price_info_a.price,
            price_info_b.price,
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

    // ===== Getter Functions =====

    public fun price_info_a(self: &State): &PriceInfo { &self.price_info_a }
    public fun price_info_b(self: &State): &PriceInfo { &self.price_info_b }
    public fun ema(self: &State): &Ema { &self.ema }
    public fun reference_val(self: &Ema): Decimal { self.reference_val }
    public fun accumulator(self: &Ema): Decimal { self.accumulator }
    public fun reduction_factor(self: &Ema): Decimal { self.reduction_factor }
    public fun max_accumulator(self: &Ema): Decimal { self.max_accumulator }
    public fun reference_price(self: &State): Decimal { self.reference_price }
    public fun last_update_ms(self: &State): u64 { self.last_update_ms }
    public fun filter_period(self: &State): u64 { self.filter_period }
    public fun decay_period(self: &State): u64 { self.decay_period }
    public fun fee_control(self: &State): Decimal { self.fee_control }

    // ===== Assert Functions =====

    // make sure we are using the latest published price on sui
    public fun assert_price_is_fresh(
        self: &State,
        clock: &Clock,
    ) {
        assert_price_is_fresh_(self, clock.timestamp_ms());
    }
    
    fun assert_price_is_fresh_(
        self: &State,
        current_ms: u64,
    ) {
        let cur_time_s = current_ms / 1000;

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

    fun get_updated_references<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        current_ms: u64,
    ): (Decimal, Decimal, u64) {
        let state = self.inner();
        let time_elapsed = current_ms - state.last_update_ms;

        if (time_elapsed >= state.filter_period && time_elapsed <= state.decay_period) {
            let reduction_factor = self.inner().ema.reduction_factor;
            let vol_accumulated = self.inner().ema.accumulator;

            let reference_val = vol_accumulated.mul(reduction_factor);
            let reference_price = new_instant_price_oracle(self);
            return (reference_price, reference_val, current_ms)
        };

        if (time_elapsed > state.decay_period) {
            let reference_val = decimal::from(0);
            let reference_price = new_instant_price_oracle(self);
            return (reference_price, reference_val, current_ms)
        };

        // Ths is kept here to make it more readable
        // if (time_elapsed < state.filter_period)
        return (self.inner().reference_price, self.inner().ema.reference_val, state.last_update_ms)
    }

    fun new_volatility_accumulator(
        self: &State,
        reference_price: Decimal,
        reference_vol: Decimal,
        new_price_internal: Decimal,
        new_price_oracle: Decimal,
    ): Decimal {
        let vol_acc = new_volatility_accumulator_(
            reference_price,
            reference_vol,
            new_price_internal,
            new_price_oracle,
        );

        if (vol_acc.lt(self.ema.max_accumulator)) { vol_acc } else { self.ema.max_accumulator }
    }
    
    fun new_volatility_accumulator_(
        reference_price: Decimal,
        reference_vol: Decimal,
        new_price_internal: Decimal,
        new_price_oracle: Decimal,
    ): Decimal {
        let price_diff_rate = decimal::max(
            compute_price_diff_rate(reference_price, new_price_internal),
            compute_price_diff_rate(reference_price, new_price_oracle)
        );

        reference_vol.add(price_diff_rate)
    }
    
    fun compute_price_diff_rate(
        reference_price: Decimal,
        new_price: Decimal,
    ): Decimal {
        let average_price = reference_price.add(new_price).div(decimal::from(2));

        if (new_price.ge(reference_price)) {
            new_price.sub(reference_price).div(average_price)
        } else {
            reference_price.sub(new_price).div(average_price)
        }
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

    // ===== Test-only functions =====


    #[test_only]
    public(package) fun quote_swap_for_testing<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
        current_ms: u64,
    ): (SwapQuote, Decimal, Decimal, Decimal, u64) {
        quote_swap_(
            self,
            amount_in,
            a2b,
            current_ms,
        )

    }
    
    #[test_only]
    public(package) fun set_oracle_price_as_hypothetical_internal_reserves<A, B, W: drop>(
        self: &mut Pool<A, B, Hook<W>, State>,
        reserve_a: u64,
        reserve_b: u64,
        clock: &Clock,
    ) {
        self.inner_mut().price_info_a.price = decimal::from(reserve_a);
        self.inner_mut().price_info_a.smoothed_price = decimal::from(reserve_a);
        self.inner_mut().price_info_b.price = decimal::from(reserve_b);
        self.inner_mut().price_info_b.smoothed_price = decimal::from(reserve_b);
        self.inner_mut().price_info_b.price_last_update_timestamp_s = clock.timestamp_ms() / 1_000;
        self.inner_mut().price_info_a.price_last_update_timestamp_s = clock.timestamp_ms() / 1_000;
    }
    
    #[test_only]
    public(package) fun set_oracle_price_as_internal_for_testing<A, B, W: drop>(
        self: &mut Pool<A, B, Hook<W>, State>,
        clock: &Clock,
    ) {
        let reserve_a = self.reserve_a();
        let reserve_b = self.reserve_b();
        set_oracle_price_as_hypothetical_internal_reserves(self, reserve_a, reserve_b, clock)
    }
    
    #[test_only]
    use sui::test_utils::assert_eq;

    #[test]
    fun test_vol_accumulator() {
        assert_eq(
            compute_price_diff_rate(
                decimal::from(4), decimal::from(2)
            ),
            decimal::from_scaled_val(666666666666666666) // 66%..
        );

        let vol_acc = new_volatility_accumulator_(
            decimal::from(4),
            decimal::from_percent(20), // reference_vol = 20%
            decimal::from(2),
            decimal::from(3),
        );

        assert_eq(vol_acc, decimal::from_scaled_val(866666666666666666)); // 20% + 66%

        assert_eq(
            compute_price_diff_rate(
                decimal::from(4), decimal::from(3)
            ),
            decimal::from_scaled_val(285714285714285714) // 28.57%..
        );
        
        let vol_acc = new_volatility_accumulator_(
            decimal::from(4),
            decimal::from_percent(20), // reference_vol = 20%
            decimal::from(4),
            decimal::from(3),
        );

        assert_eq(vol_acc, decimal::from_scaled_val(485714285714285714));
    }
    
    #[test]
    fun test_get_oracle_price() {
        let price = get_oracle_price(
            decimal::from(110),
            decimal::from(2),
        );

        assert_eq(price, decimal::from(55));
        
        let price = get_oracle_price(
            decimal::from(2),
            decimal::from(110),
        );

        assert_eq(price, decimal::from_scaled_val(18181818181818181_u256)); // 0.0181...
    }
    
    #[test]
    fun test_compute_price_diff() {

        // Relative Deviation = (1.50 - 1) / 1.25 = 40%
        assert_eq(
            compute_price_diff_rate(
                decimal::from(1), decimal::from(15).div(decimal::from(10))
            ),
            decimal::from_scaled_val(400000000000000000) // 40%..
        );
        
        // Relative Deviation = (0.667 - 1) / 0.833 = 40%
        // Where 0.667 = 1 / 1.5, in other words the inverse price
        assert_eq(
            compute_price_diff_rate(
                decimal::from(1), decimal::from(1).div(
                    decimal::from(15).div(decimal::from(10)
                ))
            ),
            decimal::from_scaled_val(400000000000000000) // 40%..
        );
    }
    
    #[test]
    fun test_compute_variable_fee_rate() {

        assert_eq(
            compute_variable_fee_rate(
                decimal::from_percent(90), decimal::from(1)
            ),
            decimal::from_scaled_val(8100000000000000) // 0.0081..
        );
    }
}
