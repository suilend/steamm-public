/// AMM Pool module. It contains the core logic of the of the AMM,
/// such as the deposit and redeem logic, which is exposed and should be
/// called directly. Is also exports an intializer and swap method to be
/// called by the hook modules.
module slamm::pool {
    use sui::transfer::public_transfer;
    use sui::tx_context::sender;
    use sui::math::{sqrt_u128, min};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance, Supply};
    use slamm::events::emit_event;
    use slamm::registry::{Registry};
    use slamm::math::{safe_mul_div_u64};
    use slamm::global_admin::GlobalAdmin;
    use slamm::fees::{Self, Fees, FeeData};
    use slamm::quote::{Self, SwapQuote, DepositQuote, RedeemQuote, SwapInputs, swap_inputs};
    
    public use fun slamm::cpmm::swap as Pool.cpmm_swap;
    public use fun slamm::cpmm::quote_swap as Pool.cpmm_quote_swap;
    public use fun slamm::cpmm::k as Pool.cpmm_k;

    // ===== Constants =====

    // Protocol Fee numerator in basis points
    const SWAP_FEE_NUMERATOR: u64 = 2_000;
    const SWAP_FEE_DENOMINATOR: u64 = 10_000;
    // Minimum liquidity burned during
    // the seed depositing phase
    const MINIMUM_LIQUIDITY: u64 = 10;

    const CURRENT_VERSION: u16 = 1;

    // ===== Errors =====

    // When the package called has an outdated version
    const EIncorrectVersion: u64 = 0;
    // The pool swap fee is a percentage and therefore
    // can't surpass 100%
    const EFeeAbove100Percent: u64 = 1;
    // Occurs when the swap amount_out is below the
    // minimum amount out declared
    const ESwapExceedsSlippage: u64 = 2;
    // When the coin A output exceeds the amount of reserves
    // available
    const EOutputAExceedsLiquidity: u64 = 3;
    // When the coin B output exceeds the amount of reserves
    // available
    const EOutputBExceedsLiquidity: u64 = 4;
    // When depositing leads to a coin B deposit amount lower
    // than the min_b parameter
    const EInsufficientDepositB: u64 = 5;
    // When depositing leads to a coin A deposit amount lower
    // than the min_a parameter
    const EInsufficientDepositA: u64 = 6;
    // When the deposit max parameter ratio is invalid
    const EDepositRatioInvalid: u64 = 7;
    // The amount of coin A reedemed is below the minimum set
    const ERedeemSlippageAExceeded: u64 = 8;
    // The amount of coin B reedemed is below the minimum set
    const ERedeemSlippageBExceeded: u64 = 9;
    // Assert that the reserve to lp supply ratio updates
    // in favor of of the pool. This error should not occur
    const ELpSupplyToReserveRatioViolation: u64 = 10;
    // The swap leads to zero output amount
    const ESwapOutputAmountIsZero: u64 = 11;
    // When depositing the max deposit params cannot be zero
    const EDepositMaxParamsCantBeZero: u64 = 12;
    // The deposit ratio computed leads to a coin B deposit of zero
    const EDepositRatioLeadsToZeroB: u64 = 13;
    // The deposit ratio computed leads to a coin A deposit of zero
    const EDepositRatioLeadsToZeroA: u64 = 14;

    /// Marker type for the LP coins of a pool. There can only be one
    /// pool per type, albeit given the permissionless aspect of the pool
    /// creation, we allow for pool creators to export their own types. The creator's
    /// type is not explicitly expressed in the generic types of this struct,
    /// instead the hooks types in our implementations follow the `Hook<phantom W>`
    /// schema. This has the advantage that we do not require an extra generic
    /// type on the `LP` as well as on the `Pool`
    public struct LP<phantom A, phantom B, phantom Hook: drop> has copy, drop {}

    /// Capability object given to the pool creator
    public struct PoolCap<phantom A, phantom B, phantom Hook: drop> has key {
        id: UID,
        pool_id: ID,
    }

    /// AMM pool object. This object is the top-level object and sits at the
    /// core of the protocol. The generic types `A` and `B` correspond to the
    /// associated coin types of the AMM. The `Hook` type corresponds to the
    /// witness type of the associated hook module, whereas the `State` type
    /// corresponds the hooks state object, meant to store implementation-specific
    /// data. The pool object contains the core of the AMM logic, which all hooks
    /// rely on.
    /// 
    /// It stores the pool's liquidity, protocol fees, the lp supply object
    /// as well as the inner state of the associated Hook.
    /// 
    /// The pool object is mostly responsible to providing the liquidity depositing
    /// and withdrawal logic, which can be directly called without relying on a hook's wrapper,
    /// as well as the computation of the fees for a given swap. From a perspective of the pool
    /// module, the Pool does not rely on the hook as a trustfull oracle for computing fees.
    /// Instead the Pool will compute fees on the amount_in of the swap and therefore
    /// inform the hook on what the fees will be for the gven swap.
    /// 
    /// Moreover this object also exports an initalizer and a swap method which
    /// are meant to be called by the associated hook module.
    public struct Pool<phantom A, phantom B, phantom Hook: drop, State: store> has key, store {
        id: UID,
        inner: State,
        reserve_a: Balance<A>,
        reserve_b: Balance<B>,
        lp_supply: Supply<LP<A, B, Hook>>,
        protocol_fees: Fees<A, B>,
        pool_fees: FeeData,
        trading_data: TradingData,
        version: u16,
    }

    public struct TradingData has store {
        // swap a2b
        swap_a_in_amount: u128,
        swap_b_out_amount: u128,
        // swap b2a
        swap_a_out_amount: u128,
        swap_b_in_amount: u128,
    }
    
    // ===== Hook Methods =====

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
            version: CURRENT_VERSION,
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

    #[allow(unused_mut_parameter)]
    public(package) fun swap<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _witness: Hook,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        quote: SwapQuote,
        min_amount_out: u64,
        ctx: &mut TxContext,
    ): SwapResult {
        self.assert_version_and_upgrade();

        assert!(quote.amount_out() > 0, ESwapOutputAmountIsZero);
        assert!(quote.amount_out() >= min_amount_out, ESwapExceedsSlippage);

        if (quote.a2b()) {
            assert!(quote.amount_out() < self.reserve_b.value(), EOutputBExceedsLiquidity);
            let mut balance_in = coin_a.balance_mut().split(quote.amount_in());

            // Transfers protocol fees in
            self.protocol_fees.deposit_a(balance_in.split(quote.protocol_fees()));
            
            // Account pool fees in
            self.pool_fees.increment_fee_a(quote.pool_fees());

            // Transfers amount in
            self.reserve_a.join(balance_in);
        
            // Transfers amount out
            coin_b.balance_mut().join(self.reserve_b.split(quote.amount_out()));
            
            // Update trading data
            self.trading_data.swap_a_in_amount =
                self.trading_data.swap_a_in_amount + (quote.amount_in() as u128);

            self.trading_data.swap_b_out_amount =
                self.trading_data.swap_b_out_amount + (quote.amount_out() as u128);
        } else {
            assert!(quote.amount_out() < self.reserve_a.value(), EOutputAExceedsLiquidity);
            let mut balance_in = coin_b.balance_mut().split(quote.amount_in());

            // Transfers protocol fees in
            self.protocol_fees.deposit_b(balance_in.split(quote.protocol_fees()));
            
            // Account pool fees in
            self.pool_fees.increment_fee_b(quote.pool_fees());

            // Transfers amount in
            self.reserve_b.join(balance_in);
        
            // Transfers amount out
            coin_a.balance_mut().join(self.reserve_a.split(quote.amount_out()));

            // Update trading data
            self.trading_data.swap_a_out_amount =
                self.trading_data.swap_a_out_amount + (quote.amount_in() as u128);
            
            self.trading_data.swap_b_in_amount =
                self.trading_data.swap_b_in_amount + (quote.amount_out() as u128);
        };

        // Emit event
        let result = SwapResult {
            user: sender(ctx),
            pool_id: object::id(self),
            amount_in: quote.amount_in(),
            amount_out: quote.amount_out(),
            protocol_fees: quote.protocol_fees(),
            pool_fees: quote.pool_fees(),
            a2b: quote.a2b(),
        };

        emit_event(result);

        result
    }

    public(package) fun compute_fees<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>, amount_in: u64): SwapInputs {
        let (protocol_fee_num, protocol_fee_denom) = self.protocol_fees.fee_ratio();
        let (pool_fee_num, pool_fee_denom) = self.pool_fees.fee_ratio();
        
        let total_fees = safe_mul_div_u64(amount_in, pool_fee_num, pool_fee_denom);
        let protocol_fees = safe_mul_div_u64(total_fees, protocol_fee_num, protocol_fee_denom);
        let pool_fees = total_fees - protocol_fees;
        let net_amount_in = amount_in - protocol_fees - pool_fees;

        swap_inputs(net_amount_in, protocol_fees, pool_fees)
    }
    
    // ===== Public Methods =====

    public fun deposit_liquidity<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        max_a: u64,
        max_b: u64,
        min_a: u64,
        min_b: u64,
        ctx:  &mut TxContext,
    ): (Coin<LP<A, B, Hook>>, DepositResult) {
        self.assert_version_and_upgrade();

        let initial_lp_supply = self.lp_supply.supply_value();
        let initial_reserve_a = self.reserve_a.value();

        // Compute token deposits and delta lp tokens
        let quote = quote_deposit_impl(
            self,
            max_a,
            max_b,
            min_a,
            min_b,
        );

        let balance_a = coin_a.balance_mut().split(quote.deposit_a());
        let balance_b = coin_b.balance_mut().split(quote.deposit_b());
        
        // Add liquidity to pool
        self.reserve_a.join(balance_a);
        self.reserve_b.join(balance_b);

        // Mint LP Tokens
        let mut lp_coins = coin::from_balance(
            self.lp_supply.increase_supply(quote.mint_lp()),
            ctx
        );

        // Emit event
        let result = DepositResult {
            user: sender(ctx),
            pool_id: object::id(self),
            deposit_a: quote.deposit_a(),
            deposit_b: quote.deposit_b(),
            mint_lp: quote.mint_lp(),
        };
        
        emit_event(result);

        // Lock minimum liquidity if initial seed liquidity - prevents inflation attack
        if (quote.initial_deposit()) {
            public_transfer(lp_coins.split(MINIMUM_LIQUIDITY, ctx), @0x0);
        };

        assert_lp_supply_reserve_ratio(
            self.reserve_a.value(),
            initial_reserve_a,
            initial_lp_supply,
            self.lp_supply.supply_value(),
        );

        (lp_coins, result)
    }
    
    public fun redeem_liquidity<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        lp_tokens: Coin<LP<A, B, Hook>>,
        min_a: u64,
        min_b: u64,
        ctx:  &mut TxContext,
    ): (Coin<A>, Coin<B>, RedeemResult) {
        self.assert_version_and_upgrade();

        let initial_lp_supply = self.lp_supply.supply_value();
        let initial_reserve_a = self.reserve_a.value();
        let lp_burn = lp_tokens.value();

        // Compute amounts to withdraw
        let quote = quote_redeem_impl(
            self,
            lp_tokens.value(),
            min_a,
            min_b,
        );

        // Burn LP Tokens
        self.lp_supply.decrease_supply(
            lp_tokens.into_balance()
        );

        // Prepare tokens to send
        let base_tokens = coin::from_balance(
            self.reserve_a.split(quote.withdraw_a()),
            ctx,
        );
        let quote_tokens = coin::from_balance(
            self.reserve_b.split(quote.withdraw_b()),
            ctx,
        );

        assert_lp_supply_reserve_ratio(
            self.reserve_a.value(),
            initial_reserve_a,
            initial_lp_supply,
            self.lp_supply.supply_value(),
        );

        // Emit events
        let result = RedeemResult {
            user: sender(ctx),
            pool_id: object::id(self),
            withdraw_a: quote.withdraw_a(),
            withdraw_b: quote.withdraw_b(),
            burn_lp: lp_burn,
        };

        emit_event(result);

        (base_tokens, quote_tokens, result)
    }

    public fun quote_deposit<A, B, Hook: drop, State: store>(
        self: &Pool<A, B, Hook, State>,
        ideal_a: u64,
        ideal_b: u64,
    ): DepositQuote {
        quote_deposit_impl(
            self,
            ideal_a,
            ideal_b,
            0,
            0,
        )
    }

    public fun quote_redeem<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        lp_tokens: u64,
    ): RedeemQuote {
        quote_redeem_impl(
            self,
            lp_tokens,
            0,
            0,
        )
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
    
    public fun trading_data<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): &TradingData {
        &self.trading_data
    }

    public fun inner<A, B, Hook: drop, State: store>(
        pool: &Pool<A, B, Hook, State>,
    ): &State {
        &pool.inner
    }
    
    public fun total_swap_a_in_amount(self: &TradingData): u128 { self.swap_a_in_amount }
    public fun total_swap_b_out_amount(self: &TradingData): u128 { self.swap_b_out_amount }
    public fun total_swap_a_out_amount(self: &TradingData): u128 { self.swap_a_out_amount }
    public fun total_swap_b_in_amount(self: &TradingData): u128 { self.swap_b_in_amount }

    public fun minimum_liquidity(): u64 { MINIMUM_LIQUIDITY }

    // ===== Package functions =====
    
    public(package) fun inner_mut<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ): &mut State {
        &mut self.inner
    }

    // ===== Admin endpoints =====

    public fun collect_protocol_fees<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _global_admin: &GlobalAdmin,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        self.assert_version_and_upgrade();

        let (fees_a, fees_b) = self.protocol_fees.withdraw();

        (
            coin::from_balance(fees_a, ctx),
            coin::from_balance(fees_b, ctx)
        )
    }
    
    entry fun migrate<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _cap: &PoolCap<A, B, Hook>,
    ) {
        self.migrate_();
    }
    
    entry fun migrate_as_global_admin<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _admin: &GlobalAdmin,
    ) {
        self.migrate_();
    }

    fun migrate_<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ) {
        assert!(self.version < CURRENT_VERSION, EIncorrectVersion);
        self.version = CURRENT_VERSION;
    }

    fun assert_version<A, B, Hook: drop, State: store>(
        self: &Pool<A, B, Hook, State>,
    ) {
        assert!(self.version == CURRENT_VERSION, EIncorrectVersion);
    }

    fun assert_version_and_upgrade<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ) {
        if (self.version < CURRENT_VERSION) {
            self.version = CURRENT_VERSION;
        };
        assert_version(self);
    }
    
    // ===== Private endpoints =====

    fun quote_deposit_impl<A, B, Hook: drop, State: store>(
        self: &Pool<A, B, Hook, State>,
        ideal_a: u64,
        ideal_b: u64,
        min_a: u64,
        min_b: u64,
    ): DepositQuote {
        let is_initial_deposit = self.lp_supply_val() == 0;

        // We consider the liquidity available for trading
        // as well as the net accumulated fees, as these belong to LPs
        let (reserve_a, reserve_b) = self.reserves();

        // Compute token deposits and delta lp tokens
        let (deposit_a, deposit_b, lp_tokens) = quote_deposit_(
            reserve_a,
            reserve_b,
            self.lp_supply_val(),
            ideal_a,
            ideal_b,
            min_a,
            min_b,
        );

        quote::deposit_quote(
            is_initial_deposit,
            deposit_a,
            deposit_b,
            lp_tokens,
        )
    }

    fun quote_deposit_(
        reserve_a: u64,
        reserve_b: u64,
        lp_supply: u64,
        max_a: u64,
        max_b: u64,
        min_a: u64,
        min_b: u64
    ): (u64, u64, u64) {
        let (delta_a, delta_b) = tokens_to_deposit(
            reserve_a,
            reserve_b,
            max_a,
            max_b,
            min_a,
            min_b,
        );

        // Compute new LP Tokens
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
        max_a: u64,
        max_b: u64,
        min_a: u64,
        min_b: u64
    ): (u64, u64) {
        assert!(max_a > 0 && max_b > 0, EDepositMaxParamsCantBeZero);

        if(reserve_a == 0 && reserve_b == 0) {
            (max_a, max_b)
        } else {
            let b_star = safe_mul_div_u64(max_a, reserve_b, reserve_a);
            if (b_star <= max_b) {

                assert!(b_star > 0, EDepositRatioLeadsToZeroB);
                assert!(b_star >= min_b, EInsufficientDepositB);

                (max_a, b_star)
            } else {
                let a_star = safe_mul_div_u64(max_b, reserve_a, reserve_b);
                assert!(a_star > 0, EDepositRatioLeadsToZeroA);
                assert!(a_star <= max_a, EDepositRatioInvalid);
                assert!(a_star >= min_a, EInsufficientDepositA);
                (a_star, max_b)
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
            (sqrt_u128((amount_a as u128) * (amount_b as u128)) as u64)
        } else {
            min(
                safe_mul_div_u64(amount_a, lp_supply, reserve_a),
                safe_mul_div_u64(amount_b, lp_supply, reserve_b)
            )
        }
    }

    fun quote_redeem_impl<A, B, Hook: drop, State: store>(
        self: &Pool<A, B, Hook, State>,
        lp_tokens: u64,
        min_a: u64,
        min_b: u64,
    ): RedeemQuote {
        // We need to consider the liquidity available for trading
        // as well as the net accumulated fees, as these belong to LPs
        let (reserve_a, reserve_b) = self.reserves();

        // Compute amounts to withdraw
        let (withdraw_a, withdraw_b) = quote_redeem_(
            reserve_a,
            reserve_b,
            self.lp_supply_val(),
            lp_tokens,
            min_a,
            min_b,
        );

        quote::redeem_quote(
            withdraw_a,
            withdraw_b,
            lp_tokens,
        )
    }

    fun quote_redeem_(
        reserve_a: u64,
        reserve_b: u64,
        lp_supply: u64,
        lp_tokens: u64,
        min_a: u64,
        min_b: u64,
    ): (u64, u64) {
        // Compute the amount of tokens the user is allowed to
        // receive for each reserve, via the lp ratio
        let withdraw_a = safe_mul_div_u64(reserve_a, lp_tokens, lp_supply);
        let withdraw_b = safe_mul_div_u64(reserve_b, lp_tokens, lp_supply);

        // Assert slippage
        assert!(withdraw_a >= min_a, ERedeemSlippageAExceeded);
        assert!(withdraw_b >= min_b, ERedeemSlippageBExceeded);

        (withdraw_a, withdraw_b)
    }
    
    fun assert_lp_supply_reserve_ratio(
        final_reserve_a: u64,
        initial_reserve_a: u64,
        initial_lp_supply: u64,
        final_lp_supply: u64,
    ) {
        assert!(
            (final_reserve_a as u128) * (initial_lp_supply as u128) >=
            (initial_reserve_a as u128) * (final_lp_supply as u128),
            ELpSupplyToReserveRatioViolation
        );
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
    ): &mut Balance<B> {
        &mut self.reserve_b
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

    #[test_only]
    public(package) fun quote_deposit_test(
        reserve_a: u64,
        reserve_b: u64,
        lp_supply: u64,
        max_a: u64,
        max_b: u64,
        min_a: u64,
        min_b: u64
    ): (u64, u64, u64) {
        quote_deposit_(
            reserve_a,
            reserve_b,
            lp_supply,
            max_a,
            max_b,
            min_a,
            min_b,
        )
    }

    #[test_only]
    public(package) fun quote_redeem_test(
        reserve_a: u64,
        reserve_b: u64,
        lp_supply: u64,
        lp_tokens: u64,
        min_a: u64,
        min_b: u64,
    ): (u64, u64) {
        quote_redeem_(
            reserve_a,
            reserve_b,
            lp_supply,
            lp_tokens,
            min_a,
            min_b,
        )
    }

    #[test_only]
    public(package) fun quote_deposit_impl_test<A, B, Hook: drop, State: store>(
        self: &Pool<A, B, Hook, State>,
        ideal_a: u64,
        ideal_b: u64,
        min_a: u64,
        min_b: u64,
    ): DepositQuote {
        quote_deposit_impl(
            self,
            ideal_a,
            ideal_b,
            min_a,
            min_b,
        )
    }
}
