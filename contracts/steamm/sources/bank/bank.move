#[allow(lint(share_owned))]
module steamm::bank {
    use std::{
        option::{none},
    };
    use sui::{
        balance::{Self, Supply, Balance},
        transfer::share_object,
        clock::Clock,
        coin::{Self, Coin},
    };
    use steamm::{
        bank_math,
        version::{Self, Version},
        registry::Registry,
        global_admin::GlobalAdmin,
    };
    use suilend::{
        decimal::{Self, Decimal},
        reserve::CToken,
        lending_market::{LendingMarket, ObligationOwnerCap},
    };

    // ===== Constants =====

    const CURRENT_VERSION: u16 = 1;
    const MIN_TOKEN_BLOCK_SIZE: u64 = 1_000_000_000;

    // ===== Errors =====

    const EUtilisationRangeAboveHundredPercent: u64 = 1;
    const EUtilisationRangeBelowHundredPercent: u64 = 2;
    const ELendingAlreadyActive: u64 = 3;
    const EInvalidCTokenRatio: u64 = 4;
    const ECTokenRatioTooLow: u64 = 5;
    const ELendingNotActive: u64 = 6;
    const ECompoundedInterestNotUpdated: u64 = 7;
    const EInsufficientBankFunds: u64 = 8;

    /// Interest bearing token on the underlying Coin<T>. The ctoken can be redeemed for 
    /// the underlying token + any interest earned.
    public struct BToken<phantom P, phantom T> has drop {}

    public struct Bank<phantom P, phantom T> has key {
        id: UID,
        funds_available: Balance<T>,
        lending: Option<Lending<P>>,
        min_token_block_size: u64,
        btoken_supply: Supply<BToken<P, T>>,
        version: Version,
    }

    public struct Lending<phantom P> has store {
        /// Tracks the total amount of funds deposited into the bank,
        /// and does not account for the interest generated
        /// by depositing into suilend.
        ctokens: u64,
        target_utilisation_bps: u16,
        utilisation_buffer_bps: u16,
        reserve_array_index: u64,
        obligation_cap: ObligationOwnerCap<P>,
    }

    // ====== Entry Functions =====

    #[allow(lint(share_owned))]
    public entry fun create_bank_and_share<P, T>(
        registry: &mut Registry,
        ctx: &mut TxContext,
    ): ID {
        let bank = create_bank<P, T>(registry, ctx);
        let bank_id = object::id(&bank);
        share_object(bank);
        bank_id
    }
    
    public fun init_lending<P, T>(
        self: &mut Bank<P, T>,
        _: &GlobalAdmin,
        lending_market: &mut LendingMarket<P>,
        target_utilisation_bps: u16,
        utilisation_buffer_bps: u16,
        ctx: &mut TxContext,
    ) {
        self.version.assert_version_and_upgrade(CURRENT_VERSION);
        assert!(self.lending.is_none(), ELendingAlreadyActive);
        assert!(target_utilisation_bps + utilisation_buffer_bps <= 10_000, EUtilisationRangeAboveHundredPercent);
        assert!(target_utilisation_bps >= utilisation_buffer_bps, EUtilisationRangeBelowHundredPercent);

        let obligation_cap = lending_market.create_obligation(ctx);
        let reserve_array_index = lending_market.reserve_array_index<P, T>();

        self.lending.fill(Lending {
            ctokens: 0,
            target_utilisation_bps,
            utilisation_buffer_bps,
            reserve_array_index,
            obligation_cap,
        })
    }

    public fun mint_btokens<P, T>(
        bank: &mut Bank<P, T>,
        lending_market: &mut LendingMarket<P>,
        liquidity: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<BToken<P, T>> {
        bank.version.assert_version_and_upgrade(CURRENT_VERSION);
        bank.compound_interest_if_any(lending_market, clock);

        let new_btokens = bank.to_btokens(lending_market, liquidity.value(), clock).floor();

        bank.funds_available.join(liquidity.into_balance());
        coin::from_balance(bank.btoken_supply.increase_supply(new_btokens), ctx)
    }

    fun to_btokens<P, T>(
        bank: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        amount: u64,
        clock: &Clock,
    ): Decimal {
        let (total_funds, btoken_supply) = bank.btoken_ratio(lending_market, clock);
        // Divides by btoken ratio
        decimal::from(amount).div(total_funds).mul(btoken_supply)
    }
    
    fun from_btokens<P, T>(
        bank: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        btoken_amount: u64,
        clock: &Clock,
    ): Decimal {
        let (total_funds, btoken_supply) = bank.btoken_ratio(lending_market, clock);
        // Multiplies by btoken ratio
        decimal::from(btoken_amount).mul(total_funds).div(btoken_supply)
    }
    
    public fun burn_btokens<P, T>(
        bank: &mut Bank<P, T>,
        lending_market: &mut LendingMarket<P>,
        // TODO: consider having &mut Coin in case we can't fulfill the full requested amount
        btokens: Coin<BToken<P, T>>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<T> {
        bank.version.assert_version_and_upgrade(CURRENT_VERSION);
        bank.compound_interest_if_any(lending_market, clock);

        let tokens_to_withdraw = bank.from_btokens(lending_market, btokens.value(), clock).floor();

        bank.btoken_supply.decrease_supply(btokens.into_balance());

        if (bank.funds_available.value() < tokens_to_withdraw) {
            // TODO: add a slack to the tokens_to_withdraw to handle rounding errs
            bank.prepare_for_pending_withdraw(lending_market, tokens_to_withdraw, clock, ctx);
        };

        // In the edge case where the bank utilisation is at 100%, the amount withdrawn from
        // suilend might be off by 1 due to rounding, in such case, the amount available
        // will be lower than the amount requested
        let max_available = bank.funds_available.value();
        assert!(max_available + 1 >= tokens_to_withdraw, EInsufficientBankFunds);
        coin::from_balance(bank.funds_available.split(tokens_to_withdraw.min(max_available)), ctx)
    }
    
    public fun rebalance<P, T>(
        bank: &mut Bank<P, T>,
        lending_market: &mut LendingMarket<P>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        bank.version.assert_version_and_upgrade(CURRENT_VERSION);
        bank.compound_interest_if_any(lending_market, clock);

        if (bank.lending.is_none()) {
            return
        };

        let funds_deployed = bank.funds_deployed(lending_market, clock).floor();
        let effective_utilisation_bps = bank_math::compute_utilisation_bps(bank.funds_available.value(), funds_deployed);

        let target_utilisation_bps = bank.target_utilisation_bps_unchecked();
        let buffer_bps = bank.utilisation_buffer_bps();

        if (effective_utilisation_bps < target_utilisation_bps - buffer_bps) {
            let amount_to_deploy = bank_math::compute_amount_to_deploy(
                bank.funds_available.value(),
                funds_deployed,
                target_utilisation_bps,
            );

            bank.deploy(
                lending_market,
                amount_to_deploy,
                clock,
                ctx,
            );
        } else if (effective_utilisation_bps > target_utilisation_bps + buffer_bps) {
            let amount_to_recall = bank_math::compute_amount_to_recall(
                bank.funds_available.value(),
                0,
                funds_deployed,
                target_utilisation_bps,
            );

            bank.recall(
                lending_market,
                amount_to_recall,
                clock,
                ctx,
            );
        };
    }

    // ====== Admin Functions =====

    public fun set_utilisation_bps<P, T>(
        self: &mut Bank<P, T>,
        _: &GlobalAdmin,
        target_utilisation_bps: u16,
        utilisation_buffer_bps: u16,
    ) {
        self.version.assert_version_and_upgrade(CURRENT_VERSION);
        assert!(self.lending.is_some(), ELendingNotActive);
        assert!(target_utilisation_bps + utilisation_buffer_bps <= 10_000, EUtilisationRangeAboveHundredPercent);
        assert!(target_utilisation_bps >= utilisation_buffer_bps, EUtilisationRangeBelowHundredPercent);

        let lending = self.lending.borrow_mut();

        lending.target_utilisation_bps = target_utilisation_bps;
        lending.utilisation_buffer_bps = utilisation_buffer_bps;
    }
    
    entry fun migrate_as_global_admin<P, T>(
        self: &mut Bank<P, T>,
        _admin: &GlobalAdmin,
    ) {
        self.version.migrate_(CURRENT_VERSION);
    }
    
    // ====== Package Functions =====

    public(package) fun create_bank<P, T>(
        registry: &mut Registry,
        ctx: &mut TxContext,
    ): Bank<P, T> {
        let bank = Bank<P, T> {
            id: object::new(ctx),
            funds_available: balance::zero(),
            lending: none(),
            min_token_block_size: MIN_TOKEN_BLOCK_SIZE,
            btoken_supply: balance::create_supply(BToken<P, T> {}),
            version: version::new(CURRENT_VERSION),
        };

        registry.add_bank(&bank);

        bank
    }
    
    fun prepare_for_pending_withdraw<P, T>(
        bank: &mut Bank<P, T>,
        lending_market: &mut LendingMarket<P>,
        withdraw_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        bank.version.assert_version_and_upgrade(CURRENT_VERSION);

        if (bank.lending.is_none()) {
            return
        };

        let amount_to_recall = {
            let lending = bank.lending.borrow();
            
            bank_math::compute_recall_for_pending_withdraw(
                bank.funds_available.value(),
                withdraw_amount,
                bank.funds_deployed(lending_market, clock).floor(),
                lending.target_utilisation_bps as u64,
                lending.utilisation_buffer_bps as u64,
            )
        };

        bank.recall(
            lending_market,
            amount_to_recall,
            clock,
            ctx,
        )
    }


    // ====== Private Functions =====

    fun deploy<P, T>(
        bank: &mut Bank<P, T>,
        lending_market: &mut LendingMarket<P>,
        amount_to_deploy: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let lending = bank.lending.borrow();

        if (amount_to_deploy < bank.min_token_block_size ) {
            return
        };

        let balance_to_lend = bank.funds_available.split(amount_to_deploy);

        let c_tokens = lending_market.deposit_liquidity_and_mint_ctokens<P, T>(
            lending.reserve_array_index,
            clock,
            coin::from_balance(balance_to_lend, ctx),
            ctx,
        );

        let ctoken_amount = c_tokens.value();

        lending_market.deposit_ctokens_into_obligation(
            lending.reserve_array_index,
            &lending.obligation_cap,
            clock,
            c_tokens,
            ctx,
        );

        let lending = bank.lending.borrow_mut();
        lending.ctokens = lending.ctokens + ctoken_amount;
    }

    fun recall<P, T>(
        bank: &mut Bank<P, T>,
        lending_market: &mut LendingMarket<P>,
        amount_to_recall: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let lending = bank.lending.borrow();

        if (amount_to_recall == 0) {
            return
        };

        let amount_to_recall = amount_to_recall.max(bank.min_token_block_size);
        let ctoken_amount = bank.ctoken_amount(lending_market, amount_to_recall);

        let ctokens: Coin<CToken<P, T>> = lending_market.withdraw_ctokens(
            lending.reserve_array_index,
            &lending.obligation_cap,
            clock,
            ctoken_amount.ceil(),
            ctx,
        );

        let ctoken_amount = ctokens.value();
        
        let coin = lending_market.redeem_ctokens_and_withdraw_liquidity(
            bank.lending.borrow().reserve_array_index,
            clock,
            ctokens,
            none(), // rate_limiter_exemption
            ctx,
        );

        assert!(ctoken_amount * bank.funds_deployed(lending_market, clock).floor() <= lending.ctokens * coin.value() , EInvalidCTokenRatio);

        let lending = bank.lending.borrow_mut();
        lending.ctokens = lending.ctokens - ctoken_amount;

        bank.funds_available.join(coin.into_balance());

        let reserves = lending_market.reserves();
        let reserve = reserves.borrow(lending.reserve_array_index);
        let ctoken_ratio = reserve.ctoken_ratio();

        // Note: the amount of funds deployed is different from the previous assertion
        assert!(decimal::from(lending.ctokens).mul(ctoken_ratio).floor() >= bank.funds_deployed(lending_market, clock).floor(), ECTokenRatioTooLow);
    }

    // Given how much tokens we want to withdraw from the lending market,
    // how many ctokens do we need to burn
    fun ctoken_amount<P, T>(
        bank: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        amount: u64,
    ): Decimal {
        let reserves = lending_market.reserves();
        let lending = bank.lending.borrow();
        let reserve = reserves.borrow(lending.reserve_array_index);
        let ctoken_ratio = reserve.ctoken_ratio();

        decimal::from(amount).div(ctoken_ratio)
    }

    fun btoken_ratio<P, T>(
        bank: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        clock: &Clock,
    ): (Decimal, Decimal) {
        // this branch is only used once -- when the bank is first initialized and has 
        // zero deposits. after that, borrows and redemptions won't let the btokn supply fall 
        // below MIN_AVAILABLE_AMOUNT - TODO: add MIN_AVAILABLE_AMOUNT
        if (bank.btoken_supply.supply_value() == 0) {
            (decimal::from(1), decimal::from(1))
        } else {
            (
                total_funds(bank, lending_market, clock),
                decimal::from(bank.btoken_supply.supply_value())
            )
        }
    }

    public(package) fun total_funds<P, T>(
        bank: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        clock: &Clock,
    ): Decimal {
        let funds_deployed = bank.funds_deployed(lending_market, clock);
        let total_funds = funds_deployed.add(decimal::from(bank.funds_available.value()));

        total_funds
    }
    
    public(package) fun funds_deployed<P, T>(
        bank: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        clock: &Clock,
    ): Decimal {
        // FundsDeployed =  cTokens * Total Supply of Funds / cToken Supply
        if (bank.lending.is_some()) {
            let reserve = vector::borrow(lending_market.reserves(), bank.reserve_array_index());
            let interest_last_update_timestamp_s = reserve.interest_last_update_timestamp_s();

            assert!(interest_last_update_timestamp_s == clock.timestamp_ms() / 1000, ECompoundedInterestNotUpdated);

            let ctoken_ratio = reserve.ctoken_ratio();
        
            decimal::from(bank.lending.borrow().ctokens).mul(ctoken_ratio)
        } else {
            decimal::from(0)
        }
    }

    public fun needs_rebalance<P, T>(
        bank: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        clock: &Clock,
    ): bool {
        if (bank.lending.is_none()) {
            return false
        };

        let effective_utilisation_bps = bank.effective_utilisation_bps(lending_market, clock);
        let target_utilisation_bps = bank.target_utilisation_bps_unchecked();
        let buffer_bps = bank.utilisation_buffer_bps_unchecked();

        if (effective_utilisation_bps <= target_utilisation_bps + buffer_bps && effective_utilisation_bps >= target_utilisation_bps - buffer_bps) { false } else { true }
    }

    fun compound_interest_if_any<P, T>(
        bank: &Bank<P, T>,
        lending_market: &mut LendingMarket<P>,
        clock: &Clock,
    ) {
        if (bank.lending.is_some()) {
            lending_market.compound_interest<P, T>(bank.reserve_array_index(), clock);
        } else {
            return
        }
    }

    // ====== Getters Functions =====

    public fun lending<P, T>(self: &Bank<P, T>): &Option<Lending<P>> { &self.lending }

    public(package) fun effective_utilisation_bps<P, T>(
        self: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        clock: &Clock
    ): u64 { 
        bank_math::compute_utilisation_bps(self.funds_available.value(), self.funds_deployed(lending_market, clock).floor())
    }
    
    public fun target_utilisation_bps<P, T>(self: &Bank<P, T>): u64 {
        if (self.lending.is_some()) {
            self.target_utilisation_bps_unchecked()
        } else { 0 }
    }
    
    public fun utilisation_buffer_bps<P, T>(self: &Bank<P, T>): u64 {
        if (self.lending.is_some()) {
            self.utilisation_buffer_bps_unchecked()
        } else { 0 }
    }
    
    public fun funds_available<P, T>(self: &Bank<P, T>): &Balance<T> { &self.funds_available }
    public fun target_utilisation_bps_unchecked<P, T>(self: &Bank<P, T>): u64 { self.lending.borrow().target_utilisation_bps as u64}
    public fun utilisation_buffer_bps_unchecked<P, T>(self: &Bank<P, T>): u64 { self.lending.borrow().utilisation_buffer_bps as u64 }
    public fun reserve_array_index<P, T>(self: &Bank<P, T>): u64 { self.lending.borrow().reserve_array_index }

    // ===== Test-Only Functions =====
    
    #[test_only]
    public(package) fun mock_min_token_block_size<P, T>(self: &mut Bank<P, T>, amount: u64){ self.min_token_block_size = amount; }
    
    #[test_only]
    public(package) fun deposit_for_testing<P, T>(self: &mut Bank<P, T>, amount: u64) {
        self.funds_available.join(
            balance::create_for_testing(amount)
        );
    }
    
    #[test_only]
    public(package) fun withdraw_for_testing<P, T>(self: &mut Bank<P, T>, amount: u64): Balance<T> {
        self.funds_available.split(
            amount
        )
    }

    #[test_only]
    public fun needs_rebalance_after_inflow<P, T>(
        bank: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        amount: u64,
        clock: &Clock,
    ): bool {
        if (bank.lending.is_none()) {
            return false
        };

        let funds_deployed = bank.funds_deployed(lending_market, clock).floor();

        let effective_utilisation_bps = bank_math::compute_utilisation_bps(bank.funds_available.value() + amount, funds_deployed);
        let target_utilisation_bps = bank.target_utilisation_bps_unchecked();
        let buffer_bps = bank.utilisation_buffer_bps_unchecked();

        if (effective_utilisation_bps <= target_utilisation_bps + buffer_bps && effective_utilisation_bps >= target_utilisation_bps - buffer_bps) { false } else { true }
    }
    
    #[test_only]
    public fun needs_rebalance_after_outflow<P, T>(
        bank: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        btoken_amount: u64,
        clock: &Clock,
    ): bool {
        if (bank.lending.is_none()) {
            return false
        };

        let funds_deployed = bank.funds_deployed(lending_market, clock).floor();
        let amount = bank.from_btokens(lending_market, btoken_amount, clock).floor();

        if (amount > bank.funds_available.value()) {
            return true
        };

        let effective_utilisation_bps = bank_math::compute_utilisation_bps(bank.funds_available.value() - amount, funds_deployed);
        let target_utilisation_bps = bank.target_utilisation_bps_unchecked();
        let buffer_bps = bank.utilisation_buffer_bps_unchecked();

        if (effective_utilisation_bps <= target_utilisation_bps + buffer_bps && effective_utilisation_bps >= target_utilisation_bps - buffer_bps) { false } else { true }
    }
}