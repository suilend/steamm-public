module slamm::pool {
    // use std::debug::print;

    use sui::balance::{Self, Balance, Supply};
    use sui::coin::{Self, Coin};
    use sui::transfer::public_transfer;
    use slamm::events::emit_event;
    use slamm::global_config::{GlobalConfig, get_fees};
    use sui::math;
    use slamm::math::{safe_mul_div_u64};
    use sui::tx_context::sender;

    public struct LP<phantom A, phantom B, phantom W: drop> has copy, drop {}

    const MINIMUM_LIQUIDITY: u64 = 10;

    public struct Pool<phantom A, phantom B, phantom W: drop> has key, store {
        id: UID,
        reserve_a: Balance<A>,
        reserve_b: Balance<B>,
        a_fees: Balance<A>,
        b_fees: Balance<B>,
        lp_supply: Supply<LP<A, B, W>>,
        k: u128,
    }

    // ===== Public Methods =====

    public fun init_pool<A, B, W: drop>(
        _witness: W,
        global_config: &GlobalConfig,
        coin_a: Coin<A>,
        coin_b: Coin<B>,
        ctx: &mut TxContext,
    ): (Pool<A, B, W>, Coin<LP<A, B, W>>) {
        global_config.assert_not_paused();

        let lp_supply = balance::create_supply(LP<A, B, W>{});

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
            lp_supply,
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

    public fun deposit_liquidity<A, B, W: drop>(
        self: &mut Pool<A, B, W>,
        global_config: &GlobalConfig,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        ideal_a: u64,
        ideal_b: u64,
        min_a: u64,
        min_b: u64,
        ctx:  &mut TxContext,
    ): (Coin<LP<A, B, W>>, DepositResult) {
        global_config.assert_not_paused();

        // 1. Compute token deposits and delta lp tokens
        let (deposit_a, deposit_b, lp_tokens) = quote_deposit_(
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
            coin_a.balance_mut().split(deposit_a)
        );
        
        self.reserve_b.join(
            coin_b.balance_mut().split(deposit_b)
        );

        // 3. Recompute invariant
        self.update_invariant_assert_increase();

        // 4. Emit event
        emit_event(
            DepositLiquidityEvent {
                user: sender(ctx),
                pool_id: object::id(self),
                lp_minted: lp_tokens,
                a_deposited: deposit_a,
                b_deposited: deposit_b,
            }
        );

        // 4. Mint LP Tokens
        let lp_coins = coin::from_balance(
            self.lp_supply.increase_supply(lp_tokens),
            ctx
        );

        (lp_coins, DepositResult {
            deposit_a,
            deposit_b,
            mint_lp: lp_tokens,
        })
    }

    public fun redeem_liquidity<A, B, W: drop>(
        self: &mut Pool<A, B, W>,
        global_config: &GlobalConfig,
        lp_tokens: Coin<LP<A, B, W>>,
        min_a: u64,
        min_b: u64,
        ctx:  &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        global_config.assert_not_paused();

        let lp_burn = lp_tokens.value();

        // 1. Compute amounts to withdraw
        let (withdraw_a, withdraw_b) = quote_redeem_(
            self.reserve_a.value(),
            self.reserve_b.value(),
            self.lp_supply.supply_value(),
            lp_burn,
            min_a,
            min_b,
        );

        // 2. Burn LP Tokens
        self.lp_supply.decrease_supply(
            lp_tokens.into_balance()
        );

        // 3. Prepare tokens to send
        let base_tokens = coin::from_balance(
            self.reserve_a.split(withdraw_a),
            ctx,
        );
        let quote_tokens = coin::from_balance(
            self.reserve_b.split(withdraw_b),
            ctx,
        );

        // 4. Recompute invariant
        self.update_invariant_assert_decrease();

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

    public fun swap<A, B, W: drop>(
        self: &mut Pool<A, B, W>,
        global_config: &GlobalConfig,
        token_a: &mut Coin<A>,
        token_b: &mut Coin<B>,
        amount_in: u64,
        min_amount_out: u64,
        a2b: bool,
        ctx: &mut TxContext,
    ): SwapResult {
        global_config.assert_not_paused();

        let swap = quote_swap(
            self,
            global_config,
            amount_in,
            a2b,
        );

        let net_amount_in = swap.amount_in - swap.fees;

        if (a2b) {
            // IN: A && OUT: B
            assert!(swap.amount_out >= min_amount_out, 0);

            // Transfers fees in
            self.a_fees.join(
                token_a.balance_mut().split(swap.fees)
            );
            
            // Transfers amount in
            self.reserve_a.join(
                token_a.balance_mut().split(net_amount_in)
            );

            // Transfers amount out
            token_b.balance_mut().join(
                self.reserve_b.split(swap.amount_out)
            );
        } else {
            // IN: B && OUT: A
            assert!(swap.amount_out >= min_amount_out, 0);

            // Transfers fees in
            self.b_fees.join(
                token_b.balance_mut().split(swap.fees)
            );
            
            // Transfers amount in
            self.reserve_b.join(
                token_b.balance_mut().split(net_amount_in)
            );

            // Transfers amount out
            token_a.balance_mut().join(
                self.reserve_a.split(swap.amount_out)
            );
        };

        // Recompute invariant
        self.update_invariant_assert_increase();
        
        // 5. Emit event
        emit_event(
            SwapEvent {
                user: sender(ctx),
                pool_id: object::id(self),
                amount_in: amount_in,
                amount_out: swap.amount_out,
                fees: swap.fees,
                a2b,
            }
        );

        swap
    }

    public fun quote_redeem<A, B, W: drop>(
        self: &mut Pool<A, B, W>,
        lp_tokens: u64,
        min_a: u64,
        min_b: u64,
    ): RedeemResult {
        // 1. Compute amounts to withdraw
        let (withdraw_a, withdraw_b) = quote_redeem_(
            self.reserve_a.value(),
            self.reserve_b.value(),
            self.lp_supply.supply_value(),
            lp_tokens,
            min_a,
            min_b,
        );

        RedeemResult {
            withdraw_a,
            withdraw_b,
            burn_lp: lp_tokens,
        }
    }

    // ===== View & Getters =====

    public fun reserves<A, B, W: drop>(self: &Pool<A, B, W>): (u64, u64) {
        (self.reserve_a.value(), self.reserve_b.value())
    }
    
    public fun fees<A, B, W: drop>(self: &Pool<A, B, W>,): (u64, u64) {
        (self.a_fees.value(), self.b_fees.value())
    }
    
    public fun lp_supply<A, B, W: drop>(self: &Pool<A, B, W>,): u64 {
        self.lp_supply.supply_value()
    }
    
    public fun k<A, B, W: drop>(self: &Pool<A, B, W>,): u128 {
        self.k
    }

    public fun quote_swap<A, B, W: drop>(
        self: &Pool<A, B, W>,
        global_config: &GlobalConfig,
        amount_in: u64,
        a2b: bool,
    ): SwapResult {
        let (swap_fee_numerator, swap_fee_denominator) = get_fees(global_config);
        let fees = safe_mul_div_u64(amount_in, swap_fee_numerator, swap_fee_denominator);
        let net_amount_in = amount_in - fees;

        let amount_out = if (a2b) {
            // IN: A && OUT: B
            quote_swap_(
                self.reserve_b.value(), // reserve_out
                self.reserve_a.value(), // reserve_in
                net_amount_in, // amount_in
            )
        } else {
            // IN: B && OUT: A
            quote_swap_(
                self.reserve_a.value(), // reserve_out
                self.reserve_b.value(), // reserve_in
                net_amount_in, // amount_in
            )
        };

        SwapResult {
            amount_in,
            amount_out,
            fees,
            a2b,
        }
    }

    public fun quote_deposit<A, B, W: drop>(
        self: &mut Pool<A, B, W>,
        ideal_a: u64,
        ideal_b: u64,
        min_a: u64,
        min_b: u64,
    ): DepositResult {
        let (deposit_a, deposit_b, lp_tokens) = quote_deposit_(
            self.reserve_a.value(),
            self.reserve_b.value(),
            self.lp_supply.supply_value(),
            ideal_a,
            ideal_b,
            min_a,
            min_b,
        );

        DepositResult {
            deposit_a,
            deposit_b,
            mint_lp: lp_tokens,
        }
    }

    public fun minimum_liquidity(): u64 { MINIMUM_LIQUIDITY }

    // ===== Private Functions =====

    fun quote_deposit_(
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

    fun quote_redeem_(
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

    fun quote_swap_(
        reserve_out: u64,
        reserve_in: u64,
        amount_in: u64
    ): u64 {
        safe_mul_div_u64(reserve_out, amount_in, reserve_in + amount_in) // amount_out
    }

    fun update_invariant<A, B, W: drop>(self: &mut Pool<A, B, W>) {
        self.k = (self.reserve_a.value() as u128) * (self.reserve_b.value() as u128);
    }
    
    fun update_invariant_assert_increase<A, B, W: drop>(self: &mut Pool<A, B, W>) {
        let k0 = self.k;
        self.update_invariant();
        assert!(self.k > k0, 0);
    }
    
    fun update_invariant_assert_decrease<A, B, W: drop>(self: &mut Pool<A, B, W>) {
        let k0 = self.k;
        self.update_invariant();
        assert!(self.k < k0, 0);
    }

    // ===== Events =====

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
    
    public struct SwapEvent has copy, drop {
        user: address,
        pool_id: ID,
        amount_in: u64,
        amount_out: u64,
        fees: u64,
        a2b: bool,
    }

    // ===== Results =====

    public struct SwapResult has drop {
        amount_in: u64,
        amount_out: u64,
        fees: u64,
        a2b: bool,
    }

    public struct DepositResult has drop {
        deposit_a: u64,
        deposit_b: u64,
        mint_lp: u64,
    }
    
    public struct RedeemResult has drop {
        withdraw_a: u64,
        withdraw_b: u64,
        burn_lp: u64
    }

    public fun amount_in(self: &SwapResult): u64 { self.amount_in }
    public fun amount_out(self: &SwapResult): u64 { self.amount_out }
    public fun swap_fees(self: &SwapResult): u64 { self.fees }
    public fun a2b(self: &SwapResult): bool { self.a2b }
    public fun deposit_a(self: &DepositResult): u64 { self.deposit_a }
    public fun deposit_b(self: &DepositResult): u64 { self.deposit_b }
    public fun mint_lp(self: &DepositResult): u64 { self.mint_lp }
    public fun withdraw_a(self: &RedeemResult): u64 { self.withdraw_a }
    public fun withdraw_b(self: &RedeemResult): u64 { self.withdraw_a }
    public fun burn_lp(self: &RedeemResult): u64 { self.burn_lp }
    
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

    // TODO: add back
    #[test]
    fun test_deposit_liquidity_inner() {
        let (delta_a, delta_b, lp_tokens) = quote_deposit_(
            50_000_000, // reserve_a
            50_000_000, // reserve_b
            1_000_000_000, // lp_supply
            50_000_000, // max_base
            250_000_000, // max_quote,
            0, // min_a
            0, // min_b
        );

        assert_eq(delta_a, 50_000_000);
        assert_eq(delta_b, 50_000_000);
        assert_eq(lp_tokens, 1_000_000_000);
        
        let (delta_, delta_b, lp_tokens) = quote_deposit_(
            995904078539, // reserve_a
            433683167230, // reserve_b
            1_000_000_000, // lp_supply
            993561515, // max_base
            4685420547, // max_quote,
            0, // min_a
            0, // min_b
        );

        assert_eq(delta_, 993561515);
        assert_eq(delta_b, 432663058);
        assert_eq(lp_tokens, 997647);
        
        
        let (delta_, delta_b, lp_tokens) = quote_deposit_(
            431624541156, // reserve_a
            136587560238, // reserve_b
            1_000_000_000, // lp_supply
            167814009, // max_base
            5776084236, // max_quote,
            0, // min_a
            0, // min_b
        );

        assert_eq(delta_, 167814009);
        assert_eq(delta_b, 53104733);
        assert_eq(lp_tokens, 388796);
	
        
        let (delta_, delta_b, lp_tokens) = quote_deposit_(
            814595492359, // reserve_a
            444814121159, // reserve_b
            1_000_000_000, // lp_supply
            5792262291, // max_base
            6821001626, // max_quote,
            0, // min_a
            0, // min_b
        );

        assert_eq(delta_, 5792262291);
        assert_eq(delta_b, 3162895062);
        assert_eq(lp_tokens, 7110599);
        
        let (delta_, delta_b, lp_tokens) = quote_deposit_(
            6330406121, // reserve_a
            45207102784, // reserve_b
            1_000_000_000, // lp_supply
            1432889520, // max_base
            1335572325, // max_quote,
            0, // min_a
            0, // min_b
        );

        assert_eq(delta_, 187021832);
        assert_eq(delta_b, 1335572325);
        assert_eq(lp_tokens, 29543417);

        let (delta_, delta_b, lp_tokens) = quote_deposit_(420297244854, 316982205287, 6_606_760_618_411_090, 4995214965, 3570130297, 0, 0);

        assert_eq(delta_, 4733754458);
        assert_eq(delta_b, 3570130297);
        assert_eq(lp_tokens, 74411105267193);

        let (delta_, delta_b, lp_tokens) = quote_deposit_(413062764570, 603795453491, 1_121_070_850_572_460, 1537859755, 8438693476, 0, 0);

        assert_eq(delta_, 1537859755);
        assert_eq(delta_b, 2247970061);
        assert_eq(lp_tokens, 4173820279327);

        let (delta_, delta_b, lp_tokens) = quote_deposit_(307217683947, 761385620952, 4_042_886_943_071_790, 3998100768, 108790920, 0, 0);

        assert_eq(delta_, 43896934);
        assert_eq(delta_b, 108790920);
        assert_eq(lp_tokens, 577669680434);

        let (delta_, delta_b, lp_tokens) = quote_deposit_(42698336282, 948435467841, 2_431_942_296_016_960, 6236994835, 8837546234, 0, 0);

        assert_eq(delta_, 397864202);
        assert_eq(delta_b, 8837546234);
        assert_eq(lp_tokens, 22660901223983);

        let (delta_, delta_b, lp_tokens) = quote_deposit_(861866936755, 638476503150, 244_488_474_179_102, 886029611, 7520096624, 0, 0);

        assert_eq(delta_, 886029611);
        assert_eq(delta_b, 656376365);
        assert_eq(lp_tokens, 251342774830);
    }
    
    #[test]
    fun test_redeem_liquidity_inner() {
        let (base_withdraw, quote_withdraw) = quote_redeem_(
            50_000_000, // reserve_a
            50_000_000, // reserve_b
            1_000_000_000, // lp_supply
            542816471, // lp_tokens
            0, // min_base
            0, // min_quote
        );

        assert_eq(base_withdraw, 27140823);
        assert_eq(quote_withdraw, 27140823);

        let (base_withdraw, quote_withdraw) = quote_redeem_(995904078539, 433683167230, 1000000000, 389391649, 0, 0);
        assert_eq(quote_withdraw, 168872603631);
        assert_eq(base_withdraw, 387796731388);

        let (base_withdraw, quote_withdraw) = quote_redeem_(431624541156, 136587560238, 1000000000, 440552590, 0, 0);
        assert_eq(base_withdraw, 190153309513);
        assert_eq(quote_withdraw, 60174003424);

        let (base_withdraw, quote_withdraw) = quote_redeem_(814595492359, 444814121159, 1000000000, 996613035, 0, 0);
        assert_eq(base_withdraw, 811836485937);
        assert_eq(quote_withdraw, 443307551299);

        let (base_withdraw, quote_withdraw) = quote_redeem_(6330406121, 45207102784, 1000000000, 12810274, 0, 0);
        assert_eq(base_withdraw, 81094236);
        assert_eq(quote_withdraw, 579115373);

        let (base_withdraw, quote_withdraw) = quote_redeem_(420297244854, 316982205287, 6606760618411090, 2045717643009200, 0, 0);
        assert_eq(base_withdraw, 130140857035);
        assert_eq(quote_withdraw, 98150383724);

        let (base_withdraw, quote_withdraw) = quote_redeem_(413062764570, 603795453491, 1121070850572460, 551538827364816, 0, 0);
        assert_eq(base_withdraw, 203216551998);
        assert_eq(quote_withdraw, 297052265890);

        let (base_withdraw, quote_withdraw) = quote_redeem_(307217683947, 761385620952, 4042886943071790, 2217957798004580, 0, 0);
        assert_eq(base_withdraw, 168541902702);
        assert_eq(quote_withdraw, 417701805432);

        let (base_withdraw, quote_withdraw) = quote_redeem_(42698336282, 948435467841, 2431942296016960, 59368562297754, 0, 0);
        assert_eq(base_withdraw, 1042351556);
        assert_eq(quote_withdraw, 23153201558);

        let (base_withdraw, quote_withdraw) = quote_redeem_(861866936755, 638476503150, 244488474179102, 129992518389093, 0, 0);
        assert_eq(base_withdraw, 458247588158);
        assert_eq(quote_withdraw, 339472725065);
    }
}
