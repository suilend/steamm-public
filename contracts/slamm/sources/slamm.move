/// AMM Pool module. It contains the core logic of the of the AMM,
/// such as the deposit and redeem logic, which is exposed and should be
/// called directly. Is also exports an intializer and swap method to be
/// called by the hook modules.
module slamm::pool {
    use sui::clock::Clock;
    use sui::transfer::public_transfer;
    use sui::tx_context::sender;
    use sui::math::{sqrt_u128, min};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance, Supply};
    use slamm::events::emit_event;
    use slamm::version::{Self, Version};
    use slamm::registry::{Registry};
    use slamm::math::{safe_mul_div, safe_mul_div_up};
    use slamm::global_admin::GlobalAdmin;
    use slamm::fees::{Self, Fees, FeeReserve};
    use slamm::quote::{Self, SwapQuote, SwapFee, DepositQuote, RedeemQuote, SwapOutputs, swap_outputs};
    use slamm::bank::{Bank};

    use suilend::lending_market::{LendingMarket};
    
    public use fun slamm::pool::intent_quote as Intent.quote;
    public use fun slamm::cpmm::intent_swap as Pool.cpmm_intent_swap;
    public use fun slamm::cpmm::execute_swap as Pool.cpmm_execute_swap;
    public use fun slamm::cpmm::swap as Pool.cpmm_swap;
    public use fun slamm::cpmm::quote_swap as Pool.cpmm_quote_swap;
    public use fun slamm::omm::intent_swap as Pool.omm_intent_swap;
    public use fun slamm::omm::execute_swap as Pool.omm_execute_swap;
    public use fun slamm::omm::swap as Pool.omm_swap;
    public use fun slamm::omm::quote_swap as Pool.omm_quote_swap;
    public use fun slamm::smm::intent_swap as Pool.smm_intent_swap;
    public use fun slamm::smm::execute_swap as Pool.smm_execute_swap;
    public use fun slamm::smm::swap as Pool.smm_swap;
    public use fun slamm::smm::quote_swap as Pool.smm_quote_swap;
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

    // The pool swap fee is a percentage and therefore
    // can't surpass 100%
    const EFeeAbove100Percent: u64 = 1;
    // Occurs when the swap amount_out is below the
    // minimum amount out declared
    const ESwapExceedsSlippage: u64 = 2;
    // When the coin output exceeds the amount of reserves
    // available
    const EOutputExceedsLiquidity: u64 = 3;
    // When depositing leads to a coin B deposit amount lower
    // than the min_b parameter
    const EInsufficientDepositB: u64 = 4;
    // When depositing leads to a coin A deposit amount lower
    // than the min_a parameter
    const EInsufficientDepositA: u64 = 5;
    // When the deposit max parameter ratio is invalid
    const EDepositRatioInvalid: u64 = 6;
    // The amount of coin A reedemed is below the minimum set
    const ERedeemSlippageAExceeded: u64 = 7;
    // The amount of coin B reedemed is below the minimum set
    const ERedeemSlippageBExceeded: u64 = 8;
    // Assert that the reserve to lp supply ratio updates
    // in favor of of the pool. This error should not occur
    const ELpSupplyToReserveRatioViolation: u64 = 9;
    // The swap leads to zero output amount
    const ESwapOutputAmountIsZero: u64 = 10;
    // When depositing the max deposit params cannot be zero
    const EDepositMaxParamsCantBeZero: u64 = 11;
    // The deposit ratio computed leads to a coin B deposit of zero
    const EDepositRatioLeadsToZeroB: u64 = 12;
    // The deposit ratio computed leads to a coin A deposit of zero
    const EDepositRatioLeadsToZeroA: u64 = 13;
    // There cannot be two intents concurrently
    const EPoolGuarded: u64 = 14;
    // Attempting to unguard pool that is already unguarded
    const EPoolUnguarded: u64 = 15;
    const EInsufficientFunds: u64 = 16;
    const EInsufficientFundsInBank: u64 = 17;

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
        reserve_a: Reserve<A>,
        reserve_b: Reserve<B>,
        lp_supply: Supply<LP<A, B, Hook>>,
        protocol_fees: Fees<A, B>,
        pool_fees: Fees<A, B>,
        trading_data: TradingData,
        lock_guard: bool,
        version: Version,
    }

    public struct Reserve<phantom T> has store (u64)

    public struct TradingData has store {
        // swap a2b
        swap_a_in_amount: u128,
        swap_b_out_amount: u128,
        // swap b2a
        swap_a_out_amount: u128,
        swap_b_in_amount: u128,
    }

    public struct Intent<phantom A, phantom B, phantom Hook> {
        quote: SwapQuote,
    }

    public fun intent_quote<A, B, Hook>(self: &Intent<A, B, Hook>): &SwapQuote { &self.quote }
    
    // ===== Hook Methods =====

    /// Initializes and returns a new AMM Pool along with its associated PoolCap.
    /// The pool is initialized with zero reserves for both coin types `A` and `B`,
    /// specified protocol fees, and the provided swap fee. The pool's LP supply
    /// object is initialized at zero supply and the pool is added to the `registry`.
    ///
    /// This function is meant to be called by the hook module and therefore it
    /// it witness-protected.
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
            reserve_a: Reserve(0),
            reserve_b: Reserve(0),
            protocol_fees: fees::new(SWAP_FEE_NUMERATOR, SWAP_FEE_DENOMINATOR, true),
            pool_fees: fees::new(swap_fee_bps, SWAP_FEE_DENOMINATOR, false),
            lp_supply,
            trading_data: TradingData {
                swap_a_in_amount: 0,
                swap_b_out_amount: 0,
                swap_a_out_amount: 0,
                swap_b_in_amount: 0,
            },
            lock_guard: false,
            version: version::new(CURRENT_VERSION),
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

    fun deposit<T>(reserve: &mut Reserve<T>, bank: &mut Bank<T>, balance: Balance<T>) {
        reserve.0 = reserve.0 + balance.value();

        bank.reserve_mut().join(balance);
    }
    
    fun withdraw<T>(reserve: &mut Reserve<T>, bank: &mut Bank<T>, amount: u64): Balance<T> {
        assert!(amount <= bank.reserve().value(), EInsufficientFundsInBank);

        reserve.0 = reserve.0 - amount;
        bank.reserve_mut().split(amount)
    }

    /// Executes inner swap logic that is generalised accross all hooks. It takes
    /// care of fee handling, management of reserve inputs and outputs as well
    /// as slippage protections.
    /// 
    /// This function is meant to be called by the hook module and therefore it
    /// it witness-protected.
    ///
    /// # Returns
    ///
    /// `SwapResult`: An object containing details of the executed swap,
    /// including input and output amounts, fees, and the direction of the swap.
    ///
    /// # Panics
    ///
    /// This function will panic if:
    /// - `quote.amount_out()` is zero
    /// - `quote.amount_out()` is less than `min_amount_out`
    /// - if the `quote.amount_out()` exceeds the funds in the assocatied reserve
    #[allow(unused_mut_parameter)]
    public(package) fun swap<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _witness: Hook,
        bank_a: &mut Bank<A>,
        bank_b: &mut Bank<B>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        intent: Intent<A, B, Hook>,
        min_amount_out: u64,
        ctx: &mut TxContext,
    ): SwapResult {
        self.version.assert_version_and_upgrade(CURRENT_VERSION);

        let quote = self.consume(intent);

        assert!(quote.amount_out() > 0, ESwapOutputAmountIsZero);
        assert!(quote.amount_out() >= min_amount_out, ESwapExceedsSlippage);

        let (protocol_fee_a, protocol_fee_b) = self.protocol_fees.fee_muts();
        let (pool_fee_a, pool_fee_b) = self.pool_fees.fee_muts();

        if (quote.a2b()) {
            quote.swap_inner(
                // Inputs
                bank_a, // bank_in
                &mut self.reserve_a, // reserve_in
                coin_a, // coin_in
                &mut self.trading_data.swap_a_in_amount, // swap_in_amount
                // Outputs
                protocol_fee_b, // protocol_fees
                pool_fee_b, // pool_fees
                bank_b, // bank_out
                &mut self.reserve_b, // reserve_out
                coin_b, // coin_out
                &mut self.trading_data.swap_b_out_amount, // swap_out_amount
            );
        } else {
            quote.swap_inner(
                // Inputs
                bank_b, // bank_in
                &mut self.reserve_b, // reserve_in
                coin_b, // coin_in
                &mut self.trading_data.swap_b_in_amount, // swap_in_amount
                // Outputs
                protocol_fee_a, // protocol_fees
                pool_fee_a, // pool_fees
                bank_a, // bank_out
                &mut self.reserve_a, // reserve_out
                coin_a, // coin_out
                &mut self.trading_data.swap_a_out_amount, // swap_out_amount
            );
        };

        // Emit event
        let result = SwapResult {
            user: sender(ctx),
            pool_id: object::id(self),
            amount_in: quote.amount_in(),
            amount_out: quote.amount_out(),
            output_fees: *quote.output_fees(),
            a2b: quote.a2b(),
        };

        bank_a.assert_liquidity();
        bank_b.assert_liquidity();

        emit_event(result);

        result
    }
    
    // ===== Public Methods =====

    /// Adds liquidity to the AMM Pool and mints LP tokens for the depositor.
    /// In respect to the initial deposit, the first supply value `minimum_liquidity`
    /// is frozen to prevent inflation attacks. /// This function ensures that
    /// liquidity is added to the pool in a balanced manner,
    /// maintaining the pool's reserves and LP supply ratio.
    /// 
    /// # Returns
    ///
    /// A tuple containing:
    /// - `Coin<LP<A, B, Hook>>`: The minted LP tokens for the depositor.
    /// - `DepositResult`: An object containing details of the deposit, including the amounts of coins `A` and `B` deposited and the number of LP tokens minted.
    ///
    /// # Panics
    ///
    /// - If `max` params lead to an invalid ratio
    /// - If resulting deposit amounts violate slippage defined by `min` params
    /// - If results in an inconsisten reserve-to-LP supply ratio
    public fun deposit_liquidity<A, B, Hook: drop, State: store, P>(
        self: &mut Pool<A, B, Hook, State>,
        lending_market: &mut LendingMarket<P>,
        bank_a: &mut Bank<A>,
        bank_b: &mut Bank<B>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        max_a: u64,
        max_b: u64,
        min_a: u64,
        min_b: u64,
        clock: &Clock,
        ctx:  &mut TxContext,
    ): (Coin<LP<A, B, Hook>>, DepositResult) {
        self.version.assert_version_and_upgrade(CURRENT_VERSION);
        self.assert_unguarded();

        // Compute token deposits and delta lp tokens
        let quote = quote_deposit_impl(
            self,
            max_a,
            max_b,
            min_a,
            min_b,
        );

        let initial_lp_supply = self.lp_supply.supply_value();
        let initial_reserve_a = self.reserve_a();

        let balance_a = coin_a.balance_mut().split(quote.deposit_a());
        let balance_b = coin_b.balance_mut().split(quote.deposit_b());
        
        // Add liquidity to pool
        self.reserve_a.deposit(bank_a, balance_a);
        self.reserve_b.deposit(bank_b, balance_b);

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
            initial_reserve_a,
            initial_lp_supply,
            self.reserve_a(),
            self.lp_supply.supply_value(),
        );

        if (bank_a.lending().is_some()) {
            bank_a.rebalance(
                lending_market,
                clock,
                ctx
            );
        };
        
        if (bank_b.lending().is_some()) {
            bank_b.rebalance(
                lending_market,
                clock,
                ctx
            );
        };
        
        (lp_coins, result)
    }
    
    /// Redeems liquidity from the AMM Pool by burning LP tokens and
    /// withdrawing the corresponding coins `A` and `B`.
    ///
    /// Liquidity is redeemed from the pool in a balanced manner,
    /// maintaining the pool's reserves and LP supply ratio.
    ///
    /// # Returns
    ///
    /// A tuple containing:
    /// - `Coin<A>`: The withdrawn amount of coin `A`.
    /// - `Coin<B>`: The withdrawn amount of coin `B`.
    /// - `RedeemResult`: An object containing details of the redeem transaction,
    /// including the amounts of coins `A` and `B` withdrawn and the
    /// number of LP tokens burned.
    ///
    /// # Panics
    ///
    /// - If it results in an inconsistent reserve-to-LP supply ratio
    /// - If it results in withdraw amounts that violate the slippage `min` params
    public fun redeem_liquidity<A, B, Hook: drop, State: store, P>(
        self: &mut Pool<A, B, Hook, State>,
        lending_market: &mut LendingMarket<P>,
        bank_a: &mut Bank<A>,
        bank_b: &mut Bank<B>,
        lp_tokens: Coin<LP<A, B, Hook>>,
        min_a: u64,
        min_b: u64,
        clock: &Clock,
        ctx:  &mut TxContext,
    ): (Coin<A>, Coin<B>, RedeemResult) {
        self.version.assert_version_and_upgrade(CURRENT_VERSION);
        self.assert_unguarded();

        // Compute amounts to withdraw
        let quote = quote_redeem_impl(
            self,
            lp_tokens.value(),
            min_a,
            min_b,
        );

        bank_a.provision(
            lending_market,
            quote.withdraw_a(),
            clock,
            ctx
        );
        
        bank_b.provision(
            lending_market,
            quote.withdraw_b(),
            clock,
            ctx
        );

        let initial_lp_supply = self.lp_supply.supply_value();
        let initial_reserve_a = self.reserve_a();
        let lp_burn = lp_tokens.value();

        assert!(quote.burn_lp() == lp_burn, 0);

        // Burn LP Tokens
        self.lp_supply.decrease_supply(
            lp_tokens.into_balance()
        );

        // Prepare tokens to send
        let base_tokens = coin::from_balance(
            self.reserve_a.withdraw(bank_a, quote.withdraw_a()),
            ctx,
        );
        let quote_tokens = coin::from_balance(
            self.reserve_b.withdraw(bank_b, quote.withdraw_b()),
            ctx,
        );

        assert_lp_supply_reserve_ratio(
            initial_reserve_a,
            initial_lp_supply,
            self.reserve_a(),
            self.lp_supply.supply_value(),
        );

        bank_a.rebalance(
            lending_market,
            clock,
            ctx
        );
        
        bank_b.rebalance(
            lending_market,
            clock,
            ctx
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

    // ===== Public Lending functions =====
    
    public fun sync_bank<A, B, Hook: drop, P>(
        bank_a: &mut Bank<A>,
        bank_b: &mut Bank<B>,
        lending_market: &mut LendingMarket<P>,
        intent: &mut Intent<A, B, Hook>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        if (intent.quote.a2b()) {
            bank_b.provision(
                lending_market,
                intent.quote.amount_out_net_of_pool_fees(), // output amount - pool fees
                clock,
                ctx
            );
        } else {
            bank_a.provision(
                lending_market,
                intent.quote.amount_out_net_of_pool_fees(),
                clock,
                ctx
            );
        };
    }

    // ===== View & Getters =====
    
    public fun reserves<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): (u64, u64) {
        (
            self.reserve_a(),
            self.reserve_b(),
        )
    }

    public fun reserve_a<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): u64 {
        self.reserve_a.0
    }
    
    public fun reserve_b<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): u64 {
        self.reserve_b.0
    }
    
    public fun protocol_fees<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): &Fees<A, B> {
        &self.protocol_fees
    }
    
    public fun pool_fees<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): &Fees<A, B> {
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

    public(package) fun compute_fees_on_output<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>, amount_out: u64): SwapOutputs {
        let (net_amount_out, protocol_fees, pool_fees) = self.compute_fees_(amount_out);

        swap_outputs(net_amount_out, protocol_fees, pool_fees)
    }
    
    public(package) fun compute_fees_<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>, amount: u64): (u64, u64, u64) {
        let (protocol_fee_num, protocol_fee_denom) = self.protocol_fees.fee_ratio();
        let (pool_fee_num, pool_fee_denom) = self.pool_fees.fee_ratio();
        
        let total_fees = safe_mul_div_up(amount, pool_fee_num, pool_fee_denom);
        let protocol_fees = safe_mul_div_up(total_fees, protocol_fee_num, protocol_fee_denom);
        let pool_fees = total_fees - protocol_fees;
        let net_amount = amount - protocol_fees - pool_fees;

        (net_amount, protocol_fees, pool_fees)
    }
    
    public(package) fun inner_mut<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ): &mut State {
        &mut self.inner
    }
    
    public(package) fun as_intent<A, B, Hook: drop, State: store>(
        quote: SwapQuote,
        pool: &mut Pool<A, B, Hook, State>,
    ): Intent<A, B, Hook> {
        pool.guard();
        
        Intent {
            quote,
        }
    }

    fun consume<A, B, Hook: drop, State: store, >(
        pool: &mut Pool<A, B, Hook, State>,
        intent: Intent<A, B, Hook>,
    ): SwapQuote {
        pool.unguard();

        let Intent { quote } = intent;

        quote
    }

    fun guard<A, B, Hook: drop, State: store>(
        pool: &mut Pool<A, B, Hook, State>,
    ) {
        pool.assert_unguarded();
        pool.lock_guard = true
    }
    
    fun unguard<A, B, Hook: drop, State: store>(
        pool: &mut Pool<A, B, Hook, State>,
    ) {
        pool.assert_guarded();
        pool.lock_guard = false
    }

    fun assert_unguarded<A, B, Hook: drop, State: store>(
        pool: &Pool<A, B, Hook, State>,
    ) {
        assert!(pool.lock_guard == false, EPoolGuarded);
    }
    
    fun assert_guarded<A, B, Hook: drop, State: store>(
        pool: &Pool<A, B, Hook, State>,
    ) {
        assert!(pool.lock_guard == true, EPoolUnguarded);
    }

    // ===== Admin endpoints =====

    public fun collect_protocol_fees<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _global_admin: &GlobalAdmin,
        ctx: &mut TxContext,
    ): (Coin<A>, Coin<B>) {
        self.version.assert_version_and_upgrade(CURRENT_VERSION);

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
        self.version.migrate_(CURRENT_VERSION);
    }
    
    entry fun migrate_as_global_admin<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _admin: &GlobalAdmin,
    ) {
        self.version.migrate_(CURRENT_VERSION);
    }
    
    // ===== Private functions =====

    fun swap_inner<In, Out>(
        quote: &SwapQuote,
        bank_in: &mut Bank<In>,
        reserve_in: &mut Reserve<In>,
        coin_in: &mut Coin<In>,
        swap_in_amount: &mut u128,
        output_protocol_fees: &mut FeeReserve<Out>,
        output_pool_fees: &mut FeeReserve<Out>,
        bank_out: &mut Bank<Out>,
        reserve_out: &mut Reserve<Out>,
        coin_out: &mut Coin<Out>,
        swap_out_amount: &mut u128,
    ) {
        assert!(quote.amount_out() < reserve_out.0, EOutputExceedsLiquidity);
        assert!(coin_in.value() >= quote.amount_in(), EInsufficientFunds);

        let balance_in = coin_in.balance_mut().split(quote.amount_in());

        // Transfers amount in
        reserve_in.deposit(bank_in, balance_in);
        
        // Transfers amount out - post fees if any
        let out_fees = {
            let out_protocol_fees = quote.output_fees().protocol_fees();
            let out_pool_fees = quote.output_fees().pool_fees();

            output_protocol_fees.deposit(
                reserve_out.withdraw(bank_out, out_protocol_fees)
            );

            output_pool_fees.register_fee(out_pool_fees);
            
            out_protocol_fees + out_pool_fees
        };

        let net_output = quote.amount_out() - out_fees;

        // Transfers amount out
        coin_out.balance_mut().join(reserve_out.withdraw(bank_out, net_output));
            
        // Update trading data
        *swap_in_amount =
            *swap_in_amount + (quote.amount_in() as u128);

        *swap_out_amount =
            *swap_out_amount + (quote.amount_out() as u128);
    }

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
            let b_star = safe_mul_div_up(max_a, reserve_b, reserve_a);
            if (b_star <= max_b) {

                assert!(b_star > 0, EDepositRatioLeadsToZeroB);
                assert!(b_star >= min_b, EInsufficientDepositB);

                (max_a, b_star)
            } else {
                let a_star = safe_mul_div_up(max_b, reserve_a, reserve_b);
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
                safe_mul_div(amount_a, lp_supply, reserve_a),
                safe_mul_div(amount_b, lp_supply, reserve_b)
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
        let withdraw_a = safe_mul_div(reserve_a, lp_tokens, lp_supply);
        let withdraw_b = safe_mul_div(reserve_b, lp_tokens, lp_supply);

        // Assert slippage
        assert!(withdraw_a >= min_a, ERedeemSlippageAExceeded);
        assert!(withdraw_b >= min_b, ERedeemSlippageBExceeded);

        (withdraw_a, withdraw_b)
    }
    
    fun assert_lp_supply_reserve_ratio(
        initial_reserve_a: u64,
        initial_lp_supply: u64,
        final_reserve_a: u64,
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
        output_fees: SwapFee,
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

    public fun swap_result_protocol_fees(self: &SwapResult): u64 {
        self.output_fees.protocol_fees()
    }

    public fun swap_result_pool_fees(self: &SwapResult): u64 {
        self.output_fees.pool_fees()
    }

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
    public(package) fun intent_for_testing<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        quote: SwapQuote,
        with_guard: bool,
    ): Intent<A, B, Hook> {
        if (with_guard) {
            self.guard();
        };

        Intent {
            quote,
        }
    }
    
    #[test_only]
    public(package) fun no_protocol_fees<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ) {
        let fee_num = self.protocol_fees.config_mut().swap_fee_numerator_mut();
        *fee_num = 0;
    }
    
    #[test_only]
    public(package) fun mut_reserve_a<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        bank: &mut Bank<A>,
        amount: u64,
        increase: bool,
    ) {
        if (increase) {
            self.reserve_a.deposit(bank, balance::create_for_testing(amount));
        } else {
            balance::destroy_for_testing(self.reserve_a.withdraw(bank, amount));
        };
    }
    
    #[test_only]
    public(package) fun mut_reserve_b<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        bank: &mut Bank<B>,
        amount: u64,
        increase: bool,
    ) {
        if (increase) {
            self.reserve_b.deposit(bank, balance::create_for_testing(amount));
        } else {
            balance::destroy_for_testing(self.reserve_b.withdraw(bank, amount));
        };
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
    ): &mut Fees<A, B> {
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

    #[test_only]
    public(package)fun quote_redeem_impl_test<A, B, Hook: drop, State: store>(
        self: &Pool<A, B, Hook, State>,
        lp_tokens: u64,
        min_a: u64,
        min_b: u64,
    ): RedeemQuote {
        quote_redeem_impl(
            self,
            lp_tokens,
            min_a,
            min_b,
        )
    }
    
    #[test_only]
    public(package)fun to_quote(
        result: SwapResult,
    ): SwapQuote {
        let SwapResult {
            user: _,
            pool_id: _,
            amount_in,
            amount_out,
            output_fees,
            a2b,
        } = result;

        quote::quote_for_testing(
            amount_in,
            amount_out,
            output_fees.protocol_fees(),
            output_fees.pool_fees(),
            a2b,
        )
    }

    // ===== Tests =====

    #[test]
    fun test_assert_lp_supply_reserve_ratio_ok() {

        // Perfect ratio
        assert_lp_supply_reserve_ratio(
            10, // initial_reserve_a
            10, // initial_lp_supply
            100, // final_reserve_a
            100, // final_lp_supply
        );
        
        // Ratio gets better in favor of the pool
        assert_lp_supply_reserve_ratio(
            10, // initial_reserve_a
            10, // initial_lp_supply
            100, // final_reserve_a
            99, // final_lp_supply
        );

        // initial_reserve_a
        // initial_lp_supply
        // final_reserve_a
        // final_lp_supply

    }
    
    // Note: This error cannot occur unless there is a bug in the contract.
    // It provides an extra layer of security
    #[test]
    #[expected_failure(abort_code = ELpSupplyToReserveRatioViolation)]
    fun test_assert_lp_supply_reserve_ratio_not_ok() {

        // Ratio gets worse in favor of the pool
        assert_lp_supply_reserve_ratio(
            10, // initial_reserve_a
            10, // initial_lp_supply
            100, // final_reserve_a
            101, // final_lp_supply
        );
    }
}
