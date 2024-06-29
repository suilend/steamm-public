module slamm::pool {
    use sui::tx_context::sender;
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance, Supply};
    use slamm::events::emit_event;
    use slamm::registry::{Registry};
    use slamm::math::{safe_mul_div_u64};
    use slamm::global_admin::GlobalAdmin;
    use slamm::fees::{Self, Fees, FeeData};
    
    public use fun slamm::cpmm::deposit_liquidity as Pool.cpmm_deposit;
    public use fun slamm::cpmm::redeem_liquidity as Pool.cpmm_redeem;
    public use fun slamm::cpmm::swap as Pool.cpmm_swap;
    public use fun slamm::cpmm::quote_swap as Pool.cpmm_quote_swap;
    public use fun slamm::cpmm::quote_deposit as Pool.cpmm_quote_deposit;
    public use fun slamm::cpmm::quote_redeem as Pool.cpmm_quote_redeem;
    public use fun slamm::cpmm::k as Pool.cpmm_k;

    // Consts
    const SWAP_FEE_NUMERATOR: u64 = 200;
    const SWAP_FEE_DENOMINATOR: u64 = 10_000;

    // Error codes
    const EFeeAbove100Percent: u64 = 0;
    const ESwapExceedsSlippage: u64 = 1;
    const EOutputAExceedsLiquidity: u64 = 2;
    const EOutputBExceedsLiquidity: u64 = 3;

    /// Marker type for the LP coins of a pool. There can only be one
    /// pool per type, albeit given the permissionless aspect of the pool
    /// creation, we allow for pool creators to export their own types. The creator's
    /// type is not explicitly expressed in the generic types of this struct,
    /// instead the hooks types in our implementations follow the `Hook<phantom W>`
    /// schema. This has the advantage that we do not require an extra generic
    /// type on the `LP` as well as on the `Pool`
    public struct LP<phantom A, phantom B, phantom Hook: drop> has copy, drop {}

    public struct PoolCap<phantom A, phantom B, phantom Hook: drop> {
        id: UID,
        pool_id: ID,
    }

    public struct Pool<phantom A, phantom B, phantom Hook: drop, State: store> has key, store {
        id: UID,
        inner: State,
        reserve_a: Balance<A>,
        reserve_b: Balance<B>,
        lp_supply: Supply<LP<A, B, Hook>>,
        protocol_fees: Fees<A, B>,
        pool_fees: FeeData,
        trading_data: TradingData,
    }

    public struct TradingData has store {
        // swap a2b
        swap_a_in_amount: u128,
        swap_b_out_amount: u128,
        // swap b2a
        swap_a_out_amount: u128,
        swap_b_in_amount: u128,
    }
    
    // ===== Public Methods =====

    public(package) fun new<A, B, Hook: drop, State: store>(
        _witness: Hook,
        registry: &mut Registry,
        swap_fee_bps: u64,
        inner: State,
        ctx: &mut TxContext,
    ): (Pool<A, B, Hook, State>, PoolCap<A, B, Hook>) {
        assert!(swap_fee_bps < SWAP_FEE_DENOMINATOR, EFeeAbove100Percent);

        let lp_supply = balance::create_supply(LP<A, B, Hook>{});

        let pool = Pool {
            id: object::new(ctx),
            inner,
            reserve_a: balance::zero(),
            reserve_b: balance::zero(),
            protocol_fees: fees::new(SWAP_FEE_NUMERATOR, SWAP_FEE_DENOMINATOR),
            pool_fees: fees::new_(swap_fee_bps, SWAP_FEE_DENOMINATOR),
            lp_supply,
            trading_data: TradingData {
                swap_a_in_amount: 0,
                swap_b_out_amount: 0,
                swap_a_out_amount: 0,
                swap_b_in_amount: 0,
            },
        };

        registry.add_amm(&pool);

        // Create pool cap
        let pool_cap = PoolCap {
            id: object::new(ctx),
            pool_id: pool.id.uid_to_inner(),
        };


        // Emit event
        emit_event(
            NewPoolResult {
                creator: sender(ctx),
                pool_id: object::id(&pool),
            }
        );

        (pool, pool_cap)
    }

    public fun swap<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _witness: Hook,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        amount_in: u64,
        amount_out: u64,
        min_amount_out: u64,
        a2b: bool,
        ctx: &mut TxContext,
    ): SwapResult {
        assert!(amount_out > min_amount_out, ESwapExceedsSlippage);
        
        let (protocol_fee_num, protocol_fee_denom) = self.protocol_fees.fee_ratio();
        let (admin_fee_num, admin_fee_denom) = self.pool_fees.fee_ratio();
        
        let protocol_fees = safe_mul_div_u64(amount_in, protocol_fee_num, protocol_fee_denom);
        let pool_fees = safe_mul_div_u64(amount_in, admin_fee_num, admin_fee_denom);

        if (a2b) {
            assert!(amount_out < self.reserve_b.value(), EOutputBExceedsLiquidity);
            let mut balance_in = coin_a.balance_mut().split(amount_in);

            // Transfers protocol fees in
            self.protocol_fees.deposit_a(balance_in.split(protocol_fees));
            
            // Account pool fees in
            self.pool_fees.increment_fee_a(pool_fees);

            // Transfers amount in
            self.reserve_a.join(balance_in);
        
            // Transfers amount out
            coin_b.balance_mut().join(self.reserve_b.split(amount_out));
        } else {
            assert!(amount_out < self.reserve_a.value(), EOutputAExceedsLiquidity);
            let mut balance_in = coin_b.balance_mut().split(amount_in);

            // Transfers protocol fees in
            self.protocol_fees.deposit_b(balance_in.split(protocol_fees));
            
            // Account pool fees in
            self.pool_fees.increment_fee_b(pool_fees);

            // Transfers amount in
            self.reserve_b.join(balance_in);
        
            // Transfers amount out
            coin_a.balance_mut().join(self.reserve_a.split(amount_out));
        };

        // Emit event
        let result = SwapResult {
            user: sender(ctx),
            pool_id: object::id(self),
            amount_in,
            amount_out,
            protocol_fees,
            pool_fees,
            a2b,
        };

        emit_event(result);

        result
    }

    public fun deposit_liquidity<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _witness: Hook,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        lp_to_mint: u64,
        ctx:  &mut TxContext,
    ): (Coin<LP<A, B, Hook>>, DepositResult) {
        let deposit_a = balance_a.value();
        let deposit_b = balance_b.value();
        
        // 1. Add liquidity to pool
        self.reserve_a.join(balance_a);
        self.reserve_b.join(balance_b);

        // 2. Mint LP Tokens
        let lp_coins = coin::from_balance(
            self.lp_supply.increase_supply(lp_to_mint),
            ctx
        );

        // 4. Emit event
        let result = DepositResult {
            user: sender(ctx),
            pool_id: object::id(self),
            deposit_a,
            deposit_b,
            mint_lp: lp_to_mint,
        };
        
        emit_event(result);

        (lp_coins, result)
    }
    
    public fun redeem_liquidity<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _witness: Hook,
        withdraw_a: u64,
        withdraw_b: u64,
        lp_tokens: Coin<LP<A, B, Hook>>,
        ctx:  &mut TxContext,
    ): (Coin<A>, Coin<B>, RedeemResult) {
        let lp_burn = lp_tokens.value();

        // 1. Burn LP Tokens
        self.lp_supply.decrease_supply(
            lp_tokens.into_balance()
        );

        // 2. Prepare tokens to send
        let base_tokens = coin::from_balance(
            self.reserve_a.split(withdraw_a),
            ctx,
        );
        let quote_tokens = coin::from_balance(
            self.reserve_b.split(withdraw_b),
            ctx,
        );

        // 3. Emit events
        let result = RedeemResult {
            user: sender(ctx),
            pool_id: object::id(self),
            withdraw_a,
            withdraw_b,
            burn_lp: lp_burn,
        };

        emit_event(result);

        (base_tokens, quote_tokens, result)
    }

    public fun net_amount_in<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>, amount_in: u64): (u64, u64, u64) {
        let (protocol_fee_num, protocol_fee_denom) = self.protocol_fees.fee_ratio();
        let (pool_fee_num, pool_fee_denom) = self.pool_fees.fee_ratio();
        
        let protocol_fees = safe_mul_div_u64(amount_in, protocol_fee_num, protocol_fee_denom);
        let pool_fees = safe_mul_div_u64(amount_in, pool_fee_num, pool_fee_denom);
        let net_amount_in = amount_in - protocol_fees - pool_fees;

        (net_amount_in, protocol_fees, pool_fees)
    }

    // ===== View & Getters =====
    
    public fun reserves<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): (u64, u64) {
        (self.reserve_a.value(), self.reserve_b.value())
    }
    
    public fun protocol_fees<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): &Fees<A, B> {
        &self.protocol_fees
    }
    
    public fun pool_fees<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): &FeeData {
        &self.pool_fees
    }
    
    public fun lp_supply_val<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): u64 {
        self.lp_supply.supply_value()
    }

    // ===== Package functions =====

    public(package) fun inner<A, B, Hook: drop, State: store>(
        pool: &Pool<A, B, Hook, State>,
    ): &State {
        &pool.inner
    }
    
    public(package) fun inner_mut<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ): &mut State {
        &mut self.inner
    }

    // ===== Admin endpoints =====

    public fun collect_protol_fees<A, B, Hook: drop, State: store>(
        _global_admin: &GlobalAdmin,
        self: &mut Pool<A, B, Hook, State>,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {

        let (fees_a, fees_b) = self.protocol_fees.withdraw();

        (
            coin::from_balance(fees_a, ctx),
            coin::from_balance(fees_b, ctx)
        )
    }
    

    // ===== Results/Events =====

    public struct NewPoolResult has copy, drop, store {
        creator: address,
        pool_id: ID,
    }
    
    public struct SwapResult has copy, drop, store {
        user: address,
        pool_id: ID,
        amount_in: u64,
        amount_out: u64,
        protocol_fees: u64,
        pool_fees: u64,
        a2b: bool,
    }
    
    public struct DepositResult has copy, drop, store {
        user: address,
        pool_id: ID,
        deposit_a: u64,
        deposit_b: u64,
        mint_lp: u64,
    }
    
    public struct RedeemResult has copy, drop, store {
        user: address,
        pool_id: ID,
        withdraw_a: u64,
        withdraw_b: u64,
        burn_lp: u64,
    }

    public use fun swap_result_user as SwapResult.user;
    public use fun swap_result_pool_id as SwapResult.pool_id;
    public use fun swap_result_amount_in as SwapResult.amount_in;
    public use fun swap_result_amount_out as SwapResult.amount_out;
    public use fun swap_result_net_amount_in as SwapResult.net_amount_in;
    public use fun swap_result_protocol_fees as SwapResult.protocol_fees;
    public use fun swap_result_pool_fees as SwapResult.pool_fees;
    public use fun swap_result_a2b as SwapResult.a2b;

    public use fun deposit_result_user as DepositResult.user;
    public use fun deposit_result_pool_id as DepositResult.pool_id;
    public use fun deposit_result_deposit_a as DepositResult.deposit_a;
    public use fun deposit_result_deposit_b as DepositResult.deposit_b;
    public use fun deposit_result_mint_lp as DepositResult.mint_lp;

    public use fun redeem_result_user as RedeemResult.user;
    public use fun redeem_result_pool_id as RedeemResult.pool_id;
    public use fun redeem_result_withdraw_a as RedeemResult.withdraw_a;
    public use fun redeem_result_withdraw_b as RedeemResult.withdraw_b;
    public use fun redeem_result_burn_lp as RedeemResult.burn_lp;

    public fun swap_result_user(self: &SwapResult): address { self.user }
    public fun swap_result_pool_id(self: &SwapResult): ID { self.pool_id }
    public fun swap_result_amount_in(self: &SwapResult): u64 { self.amount_in }
    public fun swap_result_amount_out(self: &SwapResult): u64 { self.amount_out }
    public fun swap_result_net_amount_in(self: &SwapResult): u64 { self.amount_in - self.protocol_fees - self.pool_fees}
    public fun swap_result_protocol_fees(self: &SwapResult): u64 { self.protocol_fees }
    public fun swap_result_pool_fees(self: &SwapResult): u64 { self.pool_fees }
    public fun swap_result_a2b(self: &SwapResult): bool { self.a2b }

    public fun deposit_result_user(self: &DepositResult): address { self.user }
    public fun deposit_result_pool_id(self: &DepositResult): ID { self.pool_id }
    public fun deposit_result_deposit_a(self: &DepositResult): u64 { self.deposit_a }
    public fun deposit_result_deposit_b(self: &DepositResult): u64 { self.deposit_b }
    public fun deposit_result_mint_lp(self: &DepositResult): u64 { self.mint_lp }

    public fun redeem_result_user(self: &RedeemResult): address { self.user }
    public fun redeem_result_pool_id(self: &RedeemResult): ID { self.pool_id }
    public fun redeem_result_withdraw_a(self: &RedeemResult): u64 { self.withdraw_a }
    public fun redeem_result_withdraw_b(self: &RedeemResult): u64 { self.withdraw_a }
    public fun redeem_result_burn_lp(self: &RedeemResult): u64 { self.burn_lp }

    // ===== Test-Only =====

    #[test_only]
    public(package) fun reserve_a_mut_for_testing<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ): &mut Balance<A> {
        &mut self.reserve_a
    }
    
    #[test_only]
    public(package) fun reserve_b_mut_for_testing<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ): &mut Balance<A> {
        &mut self.reserve_a
    }
    
    #[test_only]
    public(package) fun lp_supply_mut_for_testing<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ): &mut Supply<LP<A, B, Hook>> {
        &mut self.lp_supply
    }
    
    #[test_only]
    public(package) fun protocol_fees_mut_for_testing<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ): &mut Fees<A, B> {
        &mut self.protocol_fees
    }
    
    #[test_only]
    public(package) fun pool_fees_mut_for_testing<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ): &mut FeeData {
        &mut self.pool_fees
    }
}
