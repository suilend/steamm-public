module slamm::pool {
    use sui::balance::{Self, Balance, Supply};
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::transfer::public_transfer;
    use slamm::events::emit_event;
    use sui::math;
    use sui::tx_context::sender;

    const MINIMUM_LIQUIDITY: u64 = 10;

    public struct InitPoolEvent has copy, drop {
        creator: address,
        pool_id: ID,
        lp_minted: u64,
        a_deposited: u64,
        b_deposited: u64,
    }
    
    public struct DepositLiquidityEvent has copy, drop {
        user: address,
        pool_id: ID,
        lp_minted: u64,
        a_deposited: u64,
        b_deposited: u64,
    }
    
    public struct RedeemLiquidityEvent has copy, drop {
        user: address,
        pool_id: ID,
        lp_burned: u64,
        a_withdrawn: u64,
        b_withdrwan: u64,
    }

    public struct Pool<phantom A, phantom B, phantom LP> has key, store {
        id: UID,
        reserve_a: Balance<A>,
        reserve_b: Balance<B>,
        a_fees: Balance<A>,
        b_fees: Balance<B>,
        lp_supply: Supply<LP>,
        swap_fee_numerator: u64,
        swap_fee_denominator: u64,
        k: u128,
    }

    fun update_invariant<A, B, LP>(self: &mut Pool<A, B, LP>) {
        self.k = (self.reserve_a.value() as u128) * (self.reserve_b.value() as u128);
    }
    
    fun update_invariant_assert_increase<A, B, LP>(self: &mut Pool<A, B, LP>) {
        let k0 = self.k;
        self.update_invariant();
        assert!(self.k > k0, 0);
    }
    
    fun update_invariant_assert_decrease<A, B, LP>(self: &mut Pool<A, B, LP>) {
        let k0 = self.k;
        self.update_invariant();
        assert!(self.k < k0, 0);
    }

    public fun init_pool<A, B, LP>(
        lp_treasury_cap: TreasuryCap<LP>,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        swap_fee_numerator: u64,
        swap_fee_denominator: u64,
        ctx: &mut TxContext,
    ): (Pool<A, B, LP>, Coin<LP>) {
        assert!(lp_treasury_cap.supply_immut().supply_value() == 0, 0);

        let liquidity_a = coin_a.value();
        let liquidity_b = coin_b.value();

        // 1. Compute k
        let k = (liquidity_a as u128) * (liquidity_b as u128);

        // 2. Init pool
        let mut pool = Pool {
            id: object::new(ctx),
            reserve_a: coin_a.into_balance(),
            reserve_b: coin_b.into_balance(),
            a_fees: balance::zero(),
            b_fees: balance::zero(),
            lp_supply: lp_treasury_cap.treasury_into_supply(),
            swap_fee_numerator,
            swap_fee_denominator,
            k,
        };

        // 3. Compute LP tokens
        let delta_lp = lp_tokens_to_mint(
            0,
            0,
            pool.lp_supply.supply_value(),
            pool.reserve_a.value(),
            pool.reserve_b.value(),
        );

        // 4. Lock minimum liquidity - prevents inflation attack
        let balance_lp_locked = balance::increase_supply(&mut pool.lp_supply, MINIMUM_LIQUIDITY);
        public_transfer(coin::from_balance(balance_lp_locked, ctx), @0x0);

        // 5. Mint net LP tokens
        let lp_tokens = coin::from_balance(
            pool.lp_supply.increase_supply(delta_lp - MINIMUM_LIQUIDITY),
            ctx
        );

        // 6. Emit event
        emit_event(
            InitPoolEvent {
                creator: sender(ctx),
                pool_id: object::id(&pool),
                lp_minted: delta_lp,
                a_deposited: liquidity_a,
                b_deposited: liquidity_b,
            }
        );

        (pool, lp_tokens)
    }

    public fun deposit_liquidity<A, B, LP>(
        self: &mut Pool<A, B, LP>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        ideal_a: u64,
        ideal_b: u64,
        min_a: u64,
        min_b: u64,
        ctx:  &mut TxContext,
    ): Coin<LP> {
        // 1. Compute token deposits and delta lp tokens
        let (delta_a, delta_b, delta_lp) = deposit_liquidity_inner(
            self.reserve_a.value(),
            self.reserve_b.value(),
            self.lp_supply.supply_value(),
            ideal_a,
            ideal_b,
            min_a,
            min_b,
        );

        // 2. Add liquidity to pool
        self.reserve_a.join(
            coin_a.balance_mut().split(delta_a)
        );
        
        self.reserve_b.join(
            coin_b.balance_mut().split(delta_b)
        );

        // 3. Recompute invariant
        self.update_invariant_assert_increase();

        // 4. Emit event
        emit_event(
            DepositLiquidityEvent {
                user: sender(ctx),
                pool_id: object::id(self),
                lp_minted: delta_lp,
                a_deposited: delta_a,
                b_deposited: delta_b,
            }
        );

        // 4. Mint LP Tokens
        coin::from_balance(
            self.lp_supply.increase_supply(delta_lp),
            ctx
        )
    }
    
    fun deposit_liquidity_inner(
        reserve_a: u64,
        reserve_b: u64,
        lp_supply: u64,
        ideal_a: u64,
        ideal_b: u64,
        min_a: u64,
        min_b: u64
    ): (u64, u64, u64) {
        let (delta_a, delta_b) = tokens_to_deposit(
            reserve_a,
            reserve_b,
            ideal_a,
            ideal_b,
            min_a,
            min_b,
        );

        // 8. Compute new LP Tokens
        let delta_lp = lp_tokens_to_mint(
            reserve_a,
            reserve_b,
            lp_supply,
            delta_a,
            delta_b,
        );

        (delta_a, delta_b, delta_lp)
    }

    fun lp_tokens_to_mint(
        reserve_a: u64,
        reserve_b: u64,
        lp_supply: u64,
        amount_a: u64,
        amount_b: u64
    ): u64 {
        if (lp_supply == 0) {
            (math::sqrt_u128((amount_a as u128) * (amount_b as u128)) as u64)
        } else {
            math::min(
                safe_mul_div_u64(amount_a, lp_supply, reserve_a),
                safe_mul_div_u64(amount_b, lp_supply, reserve_b)
            )
        }
    }

    fun tokens_to_deposit(
        reserve_a: u64,
        reserve_b: u64,
        ideal_a: u64,
        ideal_b: u64,
        min_a: u64,
        min_b: u64
    ): (u64, u64) {
        if(reserve_a == 0 && reserve_b == 0) {
            (ideal_a, ideal_b)
        } else {
            let b_star = safe_mul_div_u64(ideal_a, reserve_b, reserve_a);
            if (b_star <= ideal_b) {
                assert!(b_star >= min_b, 0);
                (ideal_a, b_star)
            } else {
                let a_star = safe_mul_div_u64(ideal_b, reserve_a, reserve_b);
                assert!(a_star <= ideal_a, 0);
                assert!(a_star >= min_a, 0);
                (a_star, ideal_b)
            } 
        }
    }


    public fun redeem_liquidity<A, B, LP>(
        self: &mut Pool<A, B, LP>,
        lp_tokens: Coin<LP>,
        min_base: u64,
        min_quote: u64,
        ctx:  &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        let lp_burn = lp_tokens.value();

        // 1. Compute amounts to withdraw
        let (withdraw_a, withdraw_b) = redeem_liquidity_inner(
            self.reserve_a.value(),
            self.reserve_b.value(),
            self.lp_supply.supply_value(),
            lp_burn,
            min_base,
            min_quote,
        );

        // 2. Burn LP Tokens
        self.lp_supply.decrease_supply(
            lp_tokens.into_balance()
        );

        // 3. Recompute invariant
        self.update_invariant_assert_decrease();

        // 4. Prepare tokens to send
        let base_tokens = coin::from_balance(
            self.reserve_a.split(withdraw_a),
            ctx,
        );
        let quote_tokens = coin::from_balance(
            self.reserve_b.split(withdraw_b),
            ctx,
        );

        // 5. Emit event
        emit_event(
            RedeemLiquidityEvent {
                user: sender(ctx),
                pool_id: object::id(self),
                lp_burned: lp_burn,
                a_withdrawn: withdraw_a,
                b_withdrwan: withdraw_b,
            }
        );

        (base_tokens, quote_tokens)
    }

    public fun reserves<A, B, LP>(self: &mut Pool<A, B, LP>,): (u64, u64) {
        (self.reserve_a.value(), self.reserve_b.value())
    }

    fun redeem_liquidity_inner(
        reserve_a: u64,
        reserve_b: u64,
        lp_supply: u64,
        lp_tokens: u64,
        min_a: u64,
        min_b: u64,
    ): (u64, u64) {
        // 1. Compute the amount of tokens the user is allowed to
        // receive for each reserve, via the lp ratio

        let withdraw_a = safe_mul_div_u64(reserve_a, lp_tokens, lp_supply);
        let withdraw_b = safe_mul_div_u64(reserve_b, lp_tokens, lp_supply);

        // 2. Assert slippage
        assert!(withdraw_a >= min_a, 0);
        assert!(withdraw_b >= min_b, 0);

        (withdraw_a, withdraw_b)
    }

    public fun swap<A, B, LP>(
        self: &mut Pool<A, B, LP>,
        token_a: &mut Coin<A>,
        token_b: &mut Coin<B>,
        amount_in: u64,
        min_amount_out: u64,
        a2b: bool,
    ) {
        if (a2b) {
            // IN: A && OUT: B
            let net_amount_in = safe_mul_div_u64(amount_in, self.swap_fee_numerator, self.swap_fee_denominator);

            let amount_out = get_amount_out(
                self.reserve_b.value(), // reserve_out
                self.reserve_a.value(), // reserve_in
                net_amount_in, // amount_in
            );

            assert!(amount_out >= min_amount_out, 0);

            // Transfers fees in
            self.a_fees.join(
                token_a.balance_mut().split(amount_in - net_amount_in)
            );
            
            // Transfers amount in
            self.reserve_a.join(
                token_a.balance_mut().split(net_amount_in)
            );

            // Transfers amount out
            token_b.balance_mut().join(
                self.reserve_b.split(amount_out)
            );
        } else {
            // IN: B && OUT: A
            let net_amount_in = safe_mul_div_u64(amount_in, self.swap_fee_numerator, self.swap_fee_denominator);

            let amount_out = get_amount_out(
                self.reserve_a.value(), // reserve_out
                self.reserve_b.value(), // reserve_in
                net_amount_in, // amount_in
            );

            assert!(amount_out >= min_amount_out, 0);

            // Transfers fees in
            self.b_fees.join(
                token_b.balance_mut().split(amount_in - net_amount_in)
            );
            
            // Transfers amount in
            self.reserve_b.join(
                token_b.balance_mut().split(net_amount_in)
            );

            // Transfers amount out
            token_a.balance_mut().join(
                self.reserve_a.split(amount_out)
            );
        }
    }

    public fun safe_mul_div_u64(x: u64, y: u64, z: u64): u64 {
        ((x as u128) * (y as u128) / (z as u128) as u64)
    }

    public fun get_amount_out(
        reserve_out: u64,
        reserve_in: u64,
        amount_in: u64
    ): u64 {
        safe_mul_div_u64(reserve_out, amount_in, reserve_in + amount_in)
    }

    use std::debug::print;
    #[test_only]
    use sui::test_utils::assert_eq;

    #[test]
    fun test_swap_base_for_quote() {
        let delta_quote = get_amount_out(50000000000, 50000000000, 1000000000);
        assert_eq(delta_quote, 980392156);

        let delta_quote = get_amount_out(9999005960552740, 1095387779115020, 1000000000);
        assert_eq(delta_quote, 9128271305);

        let delta_quote = get_amount_out(1029168250865450, 7612534772798660, 1000000000);
        assert_eq(delta_quote, 135193880);
        	
        let delta_quote = get_amount_out(2768608899383570, 5686051292328860, 1000000000);
        assert_eq(delta_quote, 486912317);

        let delta_quote = get_amount_out(440197283258732, 9283788821706570, 1000000000);
        assert_eq(delta_quote, 47415688);

        let delta_quote = get_amount_out(7199199355268960, 9313530357314980, 1000000000);
        assert_eq(delta_quote, 772982779);

        let delta_quote = get_amount_out(6273576615700410, 1630712284783210, 1000000000);
        assert_eq(delta_quote, 3847136510);

        let delta_quote = get_amount_out(5196638254543900, 9284728716079420, 1000000000);
        assert_eq(delta_quote, 559697310);

        let delta_quote = get_amount_out(1128134431179110, 4632243184772740, 1000000000);
        assert_eq(delta_quote, 243539499);
    }

    // TODO: add back
    // #[test]
    // fun test_deposit_liquidity_inner() {
    //     let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(
    //         50_000_000, // reserve_a
    //         50_000_000, // reserve_b
    //         1_000_000_000, // lp_supply
    //         50_000_000, // max_base
    //         250_000_000, // max_quote,
    //     );

    //     assert_eq(base_deposit, 50_000_000);
    //     assert_eq(quote_deposit, 50_000_000);
    //     assert_eq(lp_tokens, 1_000_000_000);
        
    //     let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(
    //         995904078539, // reserve_a
    //         433683167230, // reserve_b
    //         1_000_000_000, // lp_supply
    //         993561515, // max_base
    //         4685420547, // max_quote,
    //     );

    //     assert_eq(base_deposit, 993561515);
    //     assert_eq(quote_deposit, 2281601039);
    //     assert_eq(lp_tokens, 997647);
        
        
    //     let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(
    //         431624541156, // reserve_a
    //         136587560238, // reserve_b
    //         1_000_000_000, // lp_supply
    //         167814009, // max_base
    //         5776084236, // max_quote,
    //     );

    //     assert_eq(base_deposit, 167814009);
    //     assert_eq(quote_deposit, 530301914);
    //     assert_eq(lp_tokens, 388796);
	
        
    //     let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(
    //         814595492359, // reserve_a
    //         444814121159, // reserve_b
    //         1_000_000_000, // lp_supply
    //         5792262291, // max_base
    //         6821001626, // max_quote,
    //     );

    //     assert_eq(base_deposit, 3724643546);
    //     assert_eq(quote_deposit, 6821001626);
    //     assert_eq(lp_tokens, 4572384);
        
    //     let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(
    //         6330406121, // reserve_a
    //         45207102784, // reserve_b
    //         1_000_000_000, // lp_supply
    //         1432889520, // max_base
    //         1335572325, // max_quote,
    //     );

    //     assert_eq(base_deposit, 1432889520);
    //     assert_eq(quote_deposit, 200649279);
    //     assert_eq(lp_tokens, 226350330);

    //     let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(420297244854, 316982205287, 6_606_760_618_411_090, 4995214965, 3570130297);

    //     assert_eq(base_deposit, 2692541501);
    //     assert_eq(quote_deposit, 3570130297);
    //     assert_eq(lp_tokens, 42324753183722);

    //     let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(413062764570, 603795453491, 1_121_070_850_572_460, 1537859755, 8438693476);

    //     assert_eq(base_deposit, 1537859755);
    //     assert_eq(quote_deposit, 1052065891);
    //     assert_eq(lp_tokens, 4173820279815);

    //     let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(307217683947, 761385620952, 4_042_886_943_071_790, 3998100768, 108790920);

    //     assert_eq(base_deposit, 269619382);
    //     assert_eq(quote_deposit, 108790920);
    //     assert_eq(lp_tokens, 3548105255799);

    //     let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(42698336282, 948435467841, 2_431_942_296_016_960, 6236994835, 8837546234);

    //     assert_eq(base_deposit, 6236994835);
    //     assert_eq(quote_deposit, 280788004);
    //     assert_eq(lp_tokens, 355236593742180);

    //     let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(861866936755, 638476503150, 244_488_474_179_102, 886029611, 7520096624);

    //     assert_eq(base_deposit, 886029611);
    //     assert_eq(quote_deposit, 1196034032);
    //     assert_eq(lp_tokens, 251342775123);
    // }
    
    #[test]
    fun test_redeem_liquidity_inner() {
        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(
            50_000_000, // reserve_a
            50_000_000, // reserve_b
            1_000_000_000, // lp_supply
            542816471, // lp_tokens
            0, // min_base
            0, // min_quote
        );

        assert_eq(base_withdraw, 27140823);
        assert_eq(quote_withdraw, 27140823);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(995904078539, 433683167230, 1000000000, 389391649, 0, 0);
        assert_eq(quote_withdraw, 168872603631);
        assert_eq(base_withdraw, 387796731388);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(431624541156, 136587560238, 1000000000, 440552590, 0, 0);
        assert_eq(base_withdraw, 190153309513);
        assert_eq(quote_withdraw, 60174003424);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(814595492359, 444814121159, 1000000000, 996613035, 0, 0);
        assert_eq(base_withdraw, 811836485937);
        assert_eq(quote_withdraw, 443307551299);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(6330406121, 45207102784, 1000000000, 12810274, 0, 0);
        assert_eq(base_withdraw, 81094236);
        assert_eq(quote_withdraw, 579115373);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(420297244854, 316982205287, 6606760618411090, 2045717643009200, 0, 0);
        assert_eq(base_withdraw, 130140857035);
        assert_eq(quote_withdraw, 98150383724);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(413062764570, 603795453491, 1121070850572460, 551538827364816, 0, 0);
        assert_eq(base_withdraw, 203216551998);
        assert_eq(quote_withdraw, 297052265890);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(307217683947, 761385620952, 4042886943071790, 2217957798004580, 0, 0);
        assert_eq(base_withdraw, 168541902702);
        assert_eq(quote_withdraw, 417701805432);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(42698336282, 948435467841, 2431942296016960, 59368562297754, 0, 0);
        assert_eq(base_withdraw, 1042351556);
        assert_eq(quote_withdraw, 23153201558);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(861866936755, 638476503150, 244488474179102, 129992518389093, 0, 0);
        assert_eq(base_withdraw, 458247588158);
        assert_eq(quote_withdraw, 339472725065);
    }
}
