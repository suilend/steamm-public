/// Oracle AMM Hook implementation
module slamm::omm {
    use sui::coin::Coin;
    use sui::clock::{Self, Clock};
    use slamm::global_admin::GlobalAdmin;
    use slamm::registry::{Registry};
    use slamm::math::{safe_mul_div_u64};
    use slamm::quote::{Self, SwapQuote};
    use slamm::bank::Bank;
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
        clock: &Clock,
        ctx: &mut TxContext,
    ): (Pool<A, B, Hook<W>, State>, PoolCap<A, B, Hook<W>>) {
        let inner = State {
            version: version::new(CURRENT_VERSION),
            price_info_a: from_price_feed(price_feed_a, clock),
            price_info_b: from_price_feed(price_feed_b, clock),
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
        // TODO
        self.inner().assert_price_is_fresh(clock);

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
        // TODO
        self.inner().assert_price_is_fresh(clock);

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
        // TODO
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

    public fun quote_swap<A, B, W: drop>(
        self: &Pool<A, B, Hook<W>, State>,
        amount_in: u64,
        a2b: bool,
    ): SwapQuote {
        // TODO
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

    fun get_oracle_output_amount(
        amount_in: u64,
        input_price: Decimal,
        output_price: Decimal
    ): Decimal {
        decimal::from(amount_in).mul(input_price).div(output_price)
    }

    // fun price(
    //     input_price: &Price,
    //     output_price: &Price
    // ): Fraction {

    //     let (input_price, input_expo, input_expo_is_negative) = unwrap_price(input_price);
    //     let (output_price, output_expo, output_expo_is_negative) = unwrap_price(output_price);

    //     // Combine exponent = Exponent A - Exponent B
    //     let (combined_expo, combined_expo_is_negative) = if (!input_expo_is_negative) {
    //         if (!output_expo_is_negative) {
    //             if (input_expo >= output_expo) {
    //                 (input_expo - output_expo, false)
    //             } else {
    //                 (output_expo- input_expo, true)
    //             }
    //         } else {
    //             (input_expo + output_expo, false)
    //         }
    //     } else {
    //         if (!output_expo_is_negative) {
    //             (input_expo + output_expo, true)
    //         } else {
    //             if (output_expo>= input_expo) {
    //                 (output_expo - input_expo, false)
    //             } else {
    //                 (input_expo - output_expo, true)
    //             }
    //         }
    //     };

    //     Fraction {
    //         numerator: input_price,
    //         denominator: output_price,
    //         exponent: combined_expo,
    //         is_exponent_negative: combined_expo_is_negative,
    //     }
    // }
    
    // fun unwrap_price(
    //     price_obj: &Price,
    // ): (u64, u64, bool) {

    //     let price = price_obj.get_price().get_magnitude_if_positive();
    //     let exponent = price_obj.get_expo();

    //     let is_expo_negative = exponent.get_is_negative();

    //     let expo = if (is_expo_negative) {
    //         exponent.get_magnitude_if_negative()
    //     } else {
    //         exponent.get_magnitude_if_positive()
    //     };
            
    //     (price, expo, is_expo_negative)

    // }
    
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
