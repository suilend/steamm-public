/// AMM Pool module. It contains the core logic of the of the AMM,
/// such as the deposit and redeem logic, which is exposed and should be
/// called directly. Is also exports an intializer and swap method to be
/// called by the hook modules.
module slamm::pool {
    // TODO: add method to modify fees as the poolcap owner
    use sui::{
        clock::Clock,
        transfer::public_transfer,
        tx_context::sender,
        coin::{Self, Coin},
        balance::{Self, Balance, Supply},
    };
    use slamm::{
        pool_math,
        events::emit_event,
        version::{Self, Version},
        registry::{Registry},
        math::safe_mul_div_up,
        global_admin::GlobalAdmin,
        fees::{Self, Fees, FeeConfig},
        quote::{Self, SwapQuote, SwapFee, DepositQuote, RedeemQuote},
        bank::{Bank},
    };

    use suilend::lending_market::{LendingMarket};
    
    public use fun slamm::pool::intent_quote as Intent.quote;
    public use fun slamm::cpmm::intent_swap as Pool.cpmm_intent_swap;
    public use fun slamm::cpmm::execute_swap as Pool.cpmm_execute_swap;
    public use fun slamm::cpmm::quote_swap as Pool.cpmm_quote_swap;
    public use fun slamm::omm::intent_swap as Pool.omm_intent_swap;
    public use fun slamm::omm::execute_swap as Pool.omm_execute_swap;
    public use fun slamm::omm::quote_swap as Pool.omm_quote_swap;
    public use fun slamm::smm::intent_swap as Pool.smm_intent_swap;
    public use fun slamm::smm::execute_swap as Pool.smm_execute_swap;
    public use fun slamm::smm::quote_swap as Pool.smm_quote_swap;
    public use fun slamm::cpmm::k as Pool.cpmm_k;

    // ===== Constants =====

    // Protocol Fee numerator in basis points
    const SWAP_FEE_NUMERATOR: u64 = 2_000;
    // Redemption Fee numerator in basis points
    const REDEMPTION_FEE_NUMERATOR: u64 = 10;
    // Protocol Fee denominator in basis points (100%)
    const BPS_DENOMINATOR: u64 = 10_000;
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
    // Assert that the reserve to lp supply ratio updates
    // in favor of of the pool. This error should not occur
    const ELpSupplyToReserveRatioViolation: u64 = 4;
    // The swap leads to zero output amount
    const ESwapOutputAmountIsZero: u64 = 5;
    // There cannot be two intents concurrently
    const EPoolGuarded: u64 = 6;
    // Attempting to unguard pool that is already unguarded
    const EPoolUnguarded: u64 = 7;
    // When the user coin object does not have enough balance to fulfil the swap
    const EInsufficientFunds: u64 = 8;

    /// Marker type for the LP coins of a pool. There can only be one
    /// pool per type, albeit given the permissionless aspect of the pool
    /// creation, we allow for pool creators to export their own types. The creator's
    /// type is not explicitly expressed in the generic types of this struct,
    /// instead the hooks types in our implementations follow the `Hook<phantom W>`
    /// schema. This has the advantage that we do not require an extra generic
    /// type on the `LP` as well as on the `Pool`
    public struct LP<phantom A, phantom B, phantom Hook: drop> has copy, drop {}

    /// Capability object given to the pool creator
    public struct PoolCap<phantom A, phantom B, phantom Hook: drop, phantom State: store> has key {
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
    /// Instead the Pool will compute fees on the amount_out of the swap and therefore
    /// inform the hook on what the fees will be for the given swap.
    /// 
    /// Moreover this object also exports an initalizer and a swap method which
    /// are meant to be called by the associated hook module.
    public struct Pool<phantom A, phantom B, phantom Hook: drop, State: store> has key, store {
        id: UID,
        // Inner state of the hook
        inner: State,
        // Tracks funds `A` kept in the bank
        total_funds_a: TotalFunds<A>,
        // Tracks funds `B` kept in the bank
        total_funds_b: TotalFunds<B>,
        // Tracks the supply of lp tokens
        lp_supply: Supply<LP<A, B, Hook>>,
        protocol_fees: Fees<A, B>,
        // Pool fee configuration
        pool_fee_config: FeeConfig,
        // Redemption fees
        redemption_fees: Fees<A, B>,
        // Lifetime trading and fee data
        trading_data: TradingData,
        // Provides Write-lock style guard in the swap intent process.
        // When a user initialises a swap the pool will lock and not allow
        // concurrent intents to take place.
        lock_guard: bool,
        version: Version,
    }

    /// Tracks the amount of funds that themselves are stored in the bank
    public struct TotalFunds<phantom T> has store (u64)

    public struct TradingData has store {
        // swap a2b
        swap_a_in_amount: u128,
        swap_b_out_amount: u128,
        // swap b2a
        swap_a_out_amount: u128,
        swap_b_in_amount: u128,
        // protocol fees
        protocol_fees_a: u64,
        protocol_fees_b: u64,
        // Redemption fees
        redemption_fees_a: u64,
        redemption_fees_b: u64,
        // pool fees
        pool_fees_a: u64,
        pool_fees_b: u64,
    }

    /// Intent object signaling that a swap is taking place. This object is a
    /// hot-potato and therefore needs to be consumed by the swap function, which
    /// in turn is called by the hook module `execute_swap`
    public struct Intent<phantom A, phantom B, phantom Hook: drop, phantom State: store> {
        quote: SwapQuote,
    }
    
    // ===== Hook Methods =====

    /// Initializes and returns a new AMM Pool along with its associated PoolCap.
    /// The pool is initialized with zero balances for both coin types `A` and `B`,
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
    ): (Pool<A, B, Hook, State>, PoolCap<A, B, Hook, State>) {
        assert!(swap_fee_bps < BPS_DENOMINATOR, EFeeAbove100Percent);

        let lp_supply = balance::create_supply(LP<A, B, Hook>{});

        let pool = Pool {
            id: object::new(ctx),
            inner,
            total_funds_a: TotalFunds(0),
            total_funds_b: TotalFunds(0),
            protocol_fees: fees::new(SWAP_FEE_NUMERATOR, BPS_DENOMINATOR),
            pool_fee_config: fees::new_config(swap_fee_bps, BPS_DENOMINATOR),
            redemption_fees: fees::new(REDEMPTION_FEE_NUMERATOR, BPS_DENOMINATOR),
            lp_supply,
            trading_data: TradingData {
                swap_a_in_amount: 0,
                swap_b_out_amount: 0,
                swap_a_out_amount: 0,
                swap_b_in_amount: 0,
                protocol_fees_a: 0,
                protocol_fees_b: 0,
                redemption_fees_a: 0,
                redemption_fees_b: 0,
                pool_fees_a: 0,
                pool_fees_b: 0,
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

    /// Executes inner swap logic that is generalised accross all hooks. It takes
    /// care of fee handling, management of fund inputs and outputs as well
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
    /// - if the `quote.amount_out()` exceeds the funds in the assocatied bank
    #[allow(unused_mut_parameter)]
    public(package) fun swap<A, B, Hook: drop, State: store, P>(
        self: &mut Pool<A, B, Hook, State>,
        _witness: Hook,
        bank_a: &mut Bank<P, A>,
        bank_b: &mut Bank<P, B>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        intent: Intent<A, B, Hook, State>,
        min_amount_out: u64,
        ctx: &mut TxContext,
    ): SwapResult {
        self.version.assert_version_and_upgrade(CURRENT_VERSION);

        let quote = self.consume(intent);

        assert!(quote.amount_out() > 0, ESwapOutputAmountIsZero);
        assert!(quote.amount_out() >= min_amount_out, ESwapExceedsSlippage);

        let (protocol_fee_a, protocol_fee_b) = self.protocol_fees.balances_mut();

        if (quote.a2b()) {
            quote.swap_inner(
                // Inputs
                bank_a, // bank_in
                &mut self.total_funds_a, // total_funds_in
                coin_a, // coin_in
                &mut self.trading_data.swap_a_in_amount, // swap_in_amount
                // Outputs
                protocol_fee_b, // protocol_fees
                bank_b, // bank_out
                &mut self.total_funds_b, // total_funds_out
                coin_b, // coin_out
                &mut self.trading_data.swap_b_out_amount, // swap_out_amount
                &mut self.trading_data.protocol_fees_b, // protocol_fees
                &mut self.trading_data.pool_fees_b, // pool_fees
            );
        } else {
            quote.swap_inner(
                // Inputs
                bank_b, // bank_in
                &mut self.total_funds_b, // total_funds_in
                coin_b, // coin_in
                &mut self.trading_data.swap_b_in_amount, // swap_in_amount
                // Outputs
                protocol_fee_a, // protocol_fees
                bank_a, // bank_out
                &mut self.total_funds_a, // total_funds_out
                coin_a, // coin_out
                &mut self.trading_data.swap_a_out_amount, // swap_out_amount
                &mut self.trading_data.protocol_fees_a, // protocol_fees
                &mut self.trading_data.pool_fees_a, // pool_fees
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

        emit_event(result);

        result
    }
    
    // ===== Public Methods =====

    /// Adds liquidity to the AMM Pool and mints LP tokens for the depositor.
    /// In respect to the initial deposit, the first supply value `minimum_liquidity`
    /// is frozen to prevent inflation attacks.
    /// This function ensures that liquidity is added to the pool in a
    /// balanced manner, maintaining the pool's reserves and LP supply ratio.
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
        bank_a: &mut Bank<P, A>,
        bank_b: &mut Bank<P, B>,
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
        let initial_total_funds_a = self.total_funds_a();
        let initial_total_funds_b = self.total_funds_b();

        let balance_a = coin_a.balance_mut().split(quote.deposit_a());
        let balance_b = coin_b.balance_mut().split(quote.deposit_b());
        
        // Add liquidity to pool
        self.total_funds_a.deposit(bank_a, balance_a);
        self.total_funds_b.deposit(bank_b, balance_b);

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
            initial_total_funds_a,
            initial_lp_supply,
            self.total_funds_a(),
            self.lp_supply.supply_value(),
        );
        
        assert_lp_supply_reserve_ratio(
            initial_total_funds_b,
            initial_lp_supply,
            self.total_funds_b(),
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
        bank_a: &mut Bank<P, A>,
        bank_b: &mut Bank<P, B>,
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

        bank_a.prepare_bank_for_pending_withdraw(
            lending_market,
            quote.withdraw_a(),
            clock,
            ctx
        );
        
        bank_b.prepare_bank_for_pending_withdraw(
            lending_market,
            quote.withdraw_b(),
            clock,
            ctx
        );

        let initial_lp_supply = self.lp_supply.supply_value();
        let initial_reserve_a = self.total_funds_a();
        let lp_burn = lp_tokens.value();

        assert!(quote.burn_lp() == lp_burn, 0);

        // Burn LP Tokens
        self.lp_supply.decrease_supply(
            lp_tokens.into_balance()
        );

        // Charge redemption fees
        let mut balance_a = self.total_funds_a.withdraw(bank_a, quote.withdraw_a());
        let mut balance_b = self.total_funds_b.withdraw(bank_b, quote.withdraw_b());

        // let (fee_amount_a, fee_amount_b) = self.compute_redemption_fees_(balance_a.value(), balance_b.value());
        let (fee_balance_a, fee_balance_b) = self.redemption_fees.balances_mut();

        fee_balance_a.join(balance_a.split(quote.fees_a()));
        fee_balance_b.join(balance_b.split(quote.fees_b()));
        
        // Update redemption fee data
        self.trading_data.redemption_fees_a = self.trading_data.redemption_fees_a + quote.fees_a();
        self.trading_data.redemption_fees_b = self.trading_data.redemption_fees_b + quote.fees_b();

        // Prepare tokens to send
        let tokens_a = coin::from_balance(
            balance_a,
            ctx,
        );
        let tokens_b = coin::from_balance(
            balance_b,
            ctx,
        );

        assert_lp_supply_reserve_ratio(
            initial_reserve_a,
            initial_lp_supply,
            self.total_funds_a(),
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
            fees_a: quote.fees_a(),
            fees_b: quote.fees_b(),
            burn_lp: lp_burn,
        };

        emit_event(result);

        (tokens_a, tokens_b, result)
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
    
    public fun prepare_bank_for_pending_withdraw<A, B, Hook: drop, State: store, P>(
        bank_a: &mut Bank<P, A>,
        bank_b: &mut Bank<P, B>,
        lending_market: &mut LendingMarket<P>,
        intent: &mut Intent<A, B, Hook, State>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        if (intent.quote.a2b()) {
            bank_b.prepare_bank_for_pending_withdraw(
                lending_market,
                intent.quote.amount_out_net_of_pool_fees(), // output amount - pool fees
                clock,
                ctx
            );
        } else {
            bank_a.prepare_bank_for_pending_withdraw(
                lending_market,
                intent.quote.amount_out_net_of_pool_fees(),
                clock,
                ctx
            );
        };
    }

    public fun needs_lending_action_on_swap<A, B, Hook: drop, State: store, P>(
        _self: &Pool<A, B, Hook, State>,
        bank_a: &mut Bank<P, A>,
        bank_b: &mut Bank<P, B>,
        quote: SwapQuote,
    ): bool {
        if (quote.a2b()) {
            needs_lending_action_on_swap_(
                bank_a,
                bank_b,
                quote.amount_in(),
                quote.amount_out_net_of_protocol_fees(),
            )
        } else {
            needs_lending_action_on_swap_(
                bank_b,
                bank_a,
                quote.amount_in(),
                quote.amount_out_net_of_protocol_fees(),
            )
        }
    }
    
    fun needs_lending_action_on_swap_<In, Out, P>(
        bank_in: &Bank<P, In>,
        bank_out: &Bank<P, Out>,
        amount_in: u64,
        amount_out: u64,
    ): bool {
        bank_in.needs_lending_action(amount_in, true)
        || 
        bank_out.needs_lending_action(amount_out, false)
    }

    // ===== View & Getters =====
    
    public fun total_funds<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): (u64, u64) {
        (
            self.total_funds_a(),
            self.total_funds_b(),
        )
    }

    public fun total_funds_a<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): u64 {
        self.total_funds_a.0
    }
    
    public fun total_funds_b<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): u64 {
        self.total_funds_b.0
    }
    
    public fun protocol_fees<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): &Fees<A, B> {
        &self.protocol_fees
    }
    
    public fun pool_fee_config<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): &FeeConfig {
        &self.pool_fee_config
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
    public fun protocol_fees_a(self: &TradingData): u64 { self.protocol_fees_a }
    public fun protocol_fees_b(self: &TradingData): u64 { self.protocol_fees_b }
    public fun pool_fees_a(self: &TradingData): u64 { self.pool_fees_a }
    public fun pool_fees_b(self: &TradingData): u64 { self.pool_fees_b }

    public fun minimum_liquidity(): u64 { MINIMUM_LIQUIDITY }

    public fun intent_quote<A, B, Hook: drop, State: store>(self: &Intent<A, B, Hook, State>): &SwapQuote { &self.quote }

    // ===== Package functions =====

    public(package) fun get_quote<A, B, Hook: drop, State: store>(
        self: &Pool<A, B, Hook, State>,
        amount_in: u64,
        amount_out: u64,
        a2b: bool,
        ): SwapQuote {
        let (protocol_fees, pool_fees) = self.compute_swap_fees_(amount_out);

        quote::quote(
            amount_in,
            amount_out,
            protocol_fees,
            pool_fees,
            a2b,
        )
    }
    
    public(package) fun compute_swap_fees_<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>, amount: u64): (u64, u64) {
        let (protocol_fee_num, protocol_fee_denom) = self.protocol_fees.fee_ratio();
        let (pool_fee_num, pool_fee_denom) = self.pool_fee_config.fee_ratio();
        
        let total_fees = safe_mul_div_up(amount, pool_fee_num, pool_fee_denom);
        let protocol_fees = safe_mul_div_up(total_fees, protocol_fee_num, protocol_fee_denom);
        let pool_fees = total_fees - protocol_fees;

        (protocol_fees, pool_fees)
    }
    
    public(package) fun compute_redemption_fees_<A, B, Hook: drop, State: store>(
        self: &Pool<A, B, Hook, State>,
        amount_a: u64,
        amount_b: u64,
    ): (u64, u64) {
        let (fee_num, fee_denom) = self.redemption_fees.fee_ratio();
        
        let fees_a = safe_mul_div_up(amount_a, fee_num, fee_denom);
        let fees_b = safe_mul_div_up(amount_b, fee_num, fee_denom);

        (fees_a, fees_b)
    }
    
    public(package) fun inner_mut<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ): &mut State {
        &mut self.inner
    }
    
    public(package) fun as_intent<A, B, Hook: drop, State: store>(
        quote: SwapQuote,
        pool: &mut Pool<A, B, Hook, State>,
    ): Intent<A, B, Hook, State> {
        pool.guard();
        
        Intent {
            quote,
        }
    }

    fun consume<A, B, Hook: drop, State: store, >(
        pool: &mut Pool<A, B, Hook, State>,
        intent: Intent<A, B, Hook, State>,
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
        _cap: &PoolCap<A, B, Hook, State>,
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

    fun deposit<P, T>(funds: &mut TotalFunds<T>, bank: &mut Bank<P, T>, balance: Balance<T>) {
        funds.0 = funds.0 + balance.value();
        bank.deposit(balance);
    }
    
    fun withdraw<P, T>(funds: &mut TotalFunds<T>, bank: &mut Bank<P, T>, amount: u64): Balance<T> {
        funds.0 = funds.0 - amount;
        bank.withdraw(amount)
    }

    fun swap_inner<In, Out, P>(
        quote: &SwapQuote,
        // In
        bank_in: &mut Bank<P, In>,
        reserve_in: &mut TotalFunds<In>,
        coin_in: &mut Coin<In>,
        lifetime_in_amount: &mut u128,
        // Out
        protocol_fee_balance: &mut Balance<Out>,
        bank_out: &mut Bank<P, Out>,
        reserve_out: &mut TotalFunds<Out>,
        coin_out: &mut Coin<Out>,
        lifetime_out_amount: &mut u128,
        lifetime_protocol_fee: &mut u64,
        lifetime_pool_fee: &mut u64,
    ) {
        assert!(quote.amount_out() < reserve_out.0, EOutputExceedsLiquidity);
        assert!(coin_in.value() >= quote.amount_in(), EInsufficientFunds);

        let balance_in = coin_in.balance_mut().split(quote.amount_in());

        // Transfers amount in
        reserve_in.deposit(bank_in, balance_in);
        
        // Transfers amount out - post fees if any
        let protocol_fees = quote.output_fees().protocol_fees();
        let pool_fees = quote.output_fees().pool_fees();
        let total_fees = protocol_fees + pool_fees;

        let net_output = quote.amount_out() - total_fees;

        // Transfer protocol fees out
        protocol_fee_balance.join(reserve_out.withdraw(bank_out, protocol_fees));

        // Transfers amount out
        coin_out.balance_mut().join(reserve_out.withdraw(bank_out, net_output));
            
        // Update trading data
        *lifetime_protocol_fee = *lifetime_protocol_fee + protocol_fees;
        *lifetime_pool_fee = *lifetime_pool_fee + pool_fees;

        *lifetime_in_amount =
            *lifetime_in_amount + (quote.amount_in() as u128);

        *lifetime_out_amount =
            *lifetime_out_amount + (quote.amount_out() as u128);
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
        let (reserve_a, reserve_b) = self.total_funds();

        // Compute token deposits and delta lp tokens
        let (deposit_a, deposit_b, lp_tokens) = pool_math::quote_deposit(
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

    fun quote_redeem_impl<A, B, Hook: drop, State: store>(
        self: &Pool<A, B, Hook, State>,
        lp_tokens: u64,
        min_a: u64,
        min_b: u64,
    ): RedeemQuote {
        // We need to consider the liquidity available for trading
        // as well as the net accumulated fees, as these belong to LPs
        let (reserve_a, reserve_b) = self.total_funds();

        // Compute amounts to withdraw
        let (withdraw_a, withdraw_b) = pool_math::quote_redeem(
            reserve_a,
            reserve_b,
            self.lp_supply_val(),
            lp_tokens,
            min_a,
            min_b,
        );

        let (fee_amount_a, fee_amount_b) = self.compute_redemption_fees_(withdraw_a, withdraw_b);

        quote::redeem_quote(
            withdraw_a,
            withdraw_b,
            fee_amount_a,
            fee_amount_b,
            lp_tokens,
        )
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
        fees_a: u64,
        fees_b: u64,
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
    ): Intent<A, B, Hook, State> {
        if (with_guard) {
            self.guard();
        };

        Intent {
            quote,
        }
    }
    
    #[test_only]
    public(package) fun no_protocol_fees_for_testing<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ) {
        let fee_num = self.protocol_fees.config_mut().fee_numerator_mut();
        *fee_num = 0;
    }
    
    #[test_only]
    public(package) fun no_redemption_fees_for_testing<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ) {
        let fee_num = self.redemption_fees.config_mut().fee_numerator_mut();
        *fee_num = 0;
    }
    
    #[test_only]
    public(package) fun mut_reserve_a<A, B, Hook: drop, State: store, P>(
        self: &mut Pool<A, B, Hook, State>,
        bank: &mut Bank<P, A>,
        amount: u64,
        increase: bool,
    ) {
        if (increase) {
            self.total_funds_a.deposit(bank, balance::create_for_testing(amount));
        } else {
            balance::destroy_for_testing(self.total_funds_a.withdraw(bank, amount));
        };
    }
    
    #[test_only]
    public(package) fun mut_reserve_b<A, B, Hook: drop, State: store, P>(
        self: &mut Pool<A, B, Hook, State>,
        bank: &mut Bank<P, B>,
        amount: u64,
        increase: bool,
    ) {
        if (increase) {
            self.total_funds_b.deposit(bank, balance::create_for_testing(amount));
        } else {
            balance::destroy_for_testing(self.total_funds_b.withdraw(bank, amount));
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
