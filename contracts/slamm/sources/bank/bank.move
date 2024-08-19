#[allow(lint(share_owned))]
module slamm::bank {
    use std::{
        option::{none},
    };
    use sui::{
        balance::{Self, Balance},
        transfer::share_object,
        clock::Clock,
        coin::{Self, Coin},
        bag::{Self, Bag},
    };
    use slamm::{
        bank_math,
        version::{Self, Version},
        registry::Registry,
        global_admin::GlobalAdmin,
    };
    use suilend::{
        decimal,
        reserve::CToken,
        lending_market::{LendingMarket, ObligationOwnerCap},
    };

    // ===== Constants =====

    const CURRENT_VERSION: u16 = 1;

    // ===== Errors =====

    const EUtilisationRangeAboveHundredPercent: u64 = 1;
    const EUtilisationRangeBelowHundredPercent: u64 = 2;
    const EUtilisationRateOffTarget: u64 = 3;
    const ELendingAlreadyActive: u64 = 4;
    const EInsufficientFundsInBank: u64 = 5;

    public struct Bank<phantom P, phantom T> has key {
        id: UID,
        funds_available: Balance<T>,
        lending: Option<Lending<P>>,
        fields: Bag,
        version: Version,
    }

    public struct Lending<phantom P> has store {
        lending_market: ID,
        funds_deployed: u64,
        ctokens: u64,
        target_utilisation_bps: u16,
        utilisation_buffer_bps: u16,
        reserve_array_index: u64,
        obligation_cap: ObligationOwnerCap<P>,
    }

    // ====== Entry Functions =====

    public entry fun create_bank_and_share<P, T>(
        registry: &mut Registry,
        ctx: &mut TxContext,
    ) {
        let bank = create_bank<P, T>(registry, ctx);
        share_object(bank);
    }
    
    // ====== Public Functions =====

    public fun create_bank<P, T>(
        registry: &mut Registry,
        ctx: &mut TxContext,
    ): Bank<P, T> {
        let fields = bag::new(ctx);

        let bank = Bank<P, T> {
            id: object::new(ctx),
            funds_available: balance::zero(),
            lending: none(),
            fields,
            version: version::new(CURRENT_VERSION),
        };

        registry.add_bank(&bank);

        bank
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
        assert!(target_utilisation_bps + utilisation_buffer_bps < 10_000, EUtilisationRangeAboveHundredPercent);
        assert!(target_utilisation_bps > utilisation_buffer_bps, EUtilisationRangeBelowHundredPercent);

        let obligation_cap = lending_market.create_obligation(ctx);
        let reserve_array_index = lending_market.reserve_array_index<P, T>();

        self.lending.fill(Lending {
            lending_market: object::id(lending_market),
            funds_deployed: 0,
            ctokens: 0,
            target_utilisation_bps,
            utilisation_buffer_bps,
            reserve_array_index,
            obligation_cap,
        })
    }
    
    public fun rebalance<P, T>(
        bank: &mut Bank<P, T>,
        lending_market: &mut LendingMarket<P>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        bank.version.assert_version_and_upgrade(CURRENT_VERSION);

        if (bank.lending.is_none()) {
            return
        };

        let effective_utilisation = bank.effective_utilisation_rate();
        let target_utilisation = bank.target_utilisation_rate_unchecked();
        let buffer = bank.utilisation_buffer();

        if (effective_utilisation < target_utilisation - buffer) {
            let amount_to_deploy = bank_math::compute_amount_to_deploy(
                bank.funds_available.value(),
                bank.funds_deployed_unchecked(),
                target_utilisation,
            );

            bank.deploy(
                lending_market,
                amount_to_deploy,
                clock,
                ctx,
            );
        };

        if (effective_utilisation > target_utilisation + buffer) {
            let amount_to_recall = bank_math::compute_amount_to_recall(
                bank.funds_available.value(),
                0,
                bank.funds_deployed_unchecked(),
                target_utilisation,
            );

            bank.recall(
                lending_market,
                amount_to_recall,
                clock,
                ctx,
            );
        };
    }

    public fun ctoken_amount<P, T>(
        bank: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        amount: u64,
    ): u64 {
        bank.ctoken_amount_(lending_market, amount)
    }

    public fun needs_lending_action<P, T>(
        bank: &Bank<P, T>,
        amount: u64,
        is_input: bool,
    ): bool {
        if (bank.lending.is_none()) {
            return false
        };

        let lending = bank.lending.borrow();

        needs_lending_action_(
            bank.funds_available.value(),
            lending.funds_deployed,
            lending.target_utilisation_bps as u64,
            lending.utilisation_buffer_bps as u64,
            amount,
            is_input,
        )
    }

    // ====== Admin Functions =====
    
    entry fun migrate_as_global_admin<P, T>(
        self: &mut Bank<P, T>,
        _admin: &GlobalAdmin,
    ) {
        self.version.migrate_(CURRENT_VERSION);
    }
    
    // ====== Package Functions =====

    public(package) fun prepare_bank_for_pending_withdraw<P, T>(
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
                lending.funds_deployed,
                lending.target_utilisation_bps as u64,
                lending.utilisation_buffer_bps as u64,
            )
        };

        bank.recall(
            lending_market,
            amount_to_recall,
            clock,
            ctx,
        );
    }

    // We only check lower bound
    public(package) fun assert_utilisation<P, T>(
        bank: &Bank<P, T>,
    ) {
        if (bank.lending.is_none()) {
            return
        };

        let effective_utilisation = bank.effective_utilisation_rate();
        let target_utilisation = bank.target_utilisation_rate_unchecked();
        let buffer = bank.utilisation_buffer_unchecked();

        assert!(
            effective_utilisation <= target_utilisation + buffer,
            EUtilisationRateOffTarget
        );
    }

    public(package) fun deposit<P, T>(bank: &mut Bank<P, T>, balance: Balance<T>) {
        bank.funds_available.join(balance);
    }
    
    public(package) fun withdraw<P, T>(bank: &mut Bank<P, T>, amount: u64): Balance<T> {
        assert!(amount <= bank.funds_available.value(), EInsufficientFundsInBank);

        bank.funds_available.split(amount)
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

        if (amount_to_deploy == 0) {
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
        lending.funds_deployed = lending.funds_deployed + amount_to_deploy;
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

        let mut ctoken_amount = bank.ctoken_amount_(lending_market, amount_to_recall);

        let ctokens: Coin<CToken<P, T>> = lending_market.withdraw_ctokens(
            lending.reserve_array_index,
            &lending.obligation_cap,
            clock,
            ctoken_amount,
            ctx,
        );

        ctoken_amount = ctokens.value();

        let coin = lending_market.redeem_ctokens_and_withdraw_liquidity(
            bank.lending.borrow().reserve_array_index,
            clock,
            ctokens,
            none(), // rate_limiter_exemption
            ctx,
        );

        let lending = bank.lending.borrow_mut();
        lending.funds_deployed = lending.funds_deployed - amount_to_recall;
        lending.ctokens = lending.ctokens - ctoken_amount;

        bank.funds_available.join(coin.into_balance());
    }

    fun ctoken_amount_<P, T>(
        bank: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        amount: u64,
    ): u64 {
        let reserves = lending_market.reserves();
        let lending = bank.lending.borrow();
        let reserve = reserves.borrow(lending.reserve_array_index);
        let ctoken_ratio = reserve.ctoken_ratio();

        let ctoken_amount = decimal::from(amount).div(ctoken_ratio).floor();
        
        ctoken_amount
    }

    fun needs_lending_action_(
        funds_available: u64,
        funds_deployed: u64,
        target_utilisation: u64,
        utilisation_buffer: u64,
        amount: u64,
        is_input: bool,
    ): bool {
        if (!is_input) {
            bank_math::assert_output(funds_available, funds_deployed, amount);

            // If the amount is bigger than the reserve, then it's clear that
            // we need to recall
            if (amount > funds_available) {
                return true
            }
        };

        let funds_available = if (is_input) { funds_available + amount } else { funds_available - amount };
        let effective_utilisation = bank_math::compute_utilisation_rate(funds_available, funds_deployed);

        if (effective_utilisation < target_utilisation - utilisation_buffer) {
            return true
        };

        if (effective_utilisation > target_utilisation + utilisation_buffer) {
            return true
        };

        false
    }

    // ====== Getters Functions =====

    public fun lending<P, T>(self: &Bank<P, T>): &Option<Lending<P>> { &self.lending }
    
    public fun total_funds<P, T>(self: &Bank<P, T>): u64 {
        self.funds_available.value() + self.funds_deployed()
    }

    public fun effective_utilisation_rate<P, T>(self: &Bank<P, T>): u64 { 
        bank_math::compute_utilisation_rate(self.funds_available.value(), self.funds_deployed())
    }
    
    public fun funds_deployed<P, T>(self: &Bank<P, T>): u64 {
        if (self.lending.is_some()) {
            self.funds_deployed_unchecked()
        } else { 0 }
    }
    
    public fun target_utilisation_rate<P, T>(self: &Bank<P, T>): u64 {
        if (self.lending.is_some()) {
            self.target_utilisation_rate_unchecked()
        } else { 0 }
    }
    
    public fun utilisation_buffer<P, T>(self: &Bank<P, T>): u64 {
        if (self.lending.is_some()) {
            self.utilisation_buffer_unchecked()
        } else { 0 }
    }
    
    public fun lending_market<P, T>(self: &Bank<P, T>): ID { self.lending.borrow().lending_market }
    public fun funds_available<P, T>(self: &Bank<P, T>): &Balance<T> { &self.funds_available }
    public fun funds_deployed_unchecked<P, T>(self: &Bank<P, T>): u64 { self.lending.borrow().funds_deployed }
    public fun target_utilisation_rate_unchecked<P, T>(self: &Bank<P, T>): u64 { self.lending.borrow().target_utilisation_bps as u64}
    public fun utilisation_buffer_unchecked<P, T>(self: &Bank<P, T>): u64 { self.lending.borrow().utilisation_buffer_bps as u64 }
    public fun reserve_array_index<P, T>(self: &Bank<P, T>): u64 { self.lending.borrow().reserve_array_index }

    // ===== Test-Only Functions =====
    
    #[test_only]
    public fun mock_amount_lent<P, T>(self: &mut Bank<P, T>, amount: u64){ self.lending.borrow_mut().funds_deployed = amount; }

    // ===== Tests =====

    #[test_only]
    use sui::test_utils::assert_eq;
    
    #[test]
    #[expected_failure(abort_code = bank_math::EOutputExceedsTotalBankReserves)]
    fun test_fail_compute_recall_with_output_too_big() {
        needs_lending_action_(2_000, 2_000, 1_000, 500, 4001, false);
    }
    
    #[test]
    fun test_compute_lending_action() {
        // Reserve, Lent, Utilisation Ratio
        assert_eq(
            needs_lending_action_(0, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 1_600, is_lend: false })
        );
        assert_eq(
            needs_lending_action_(500, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 1_200, is_lend: false })
        );
        assert_eq(
            needs_lending_action_(1_000, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 800, is_lend: false })
        );
        assert_eq(
            needs_lending_action_(1_500, 8_000, 8_000, 500, 0, false),
            false, // none()
        );
        assert_eq(
            needs_lending_action_(2_000, 8_000, 8_000, 500, 0, false),
            false, // none()
        );
        assert_eq(
            needs_lending_action_(2_500, 8_000, 8_000, 500, 0, false),
            false, // none()
        );
        assert_eq(
            needs_lending_action_(3_000, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 800, is_lend: true })
        );
        assert_eq(
            needs_lending_action_(3_500, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 1_200, is_lend: true })
        );
        assert_eq(
            needs_lending_action_(4_000, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 1_600, is_lend: true })
        );
        assert_eq(
            needs_lending_action_(4_500, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 2_000, is_lend: true })
        );
        assert_eq(
            needs_lending_action_(5_000, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 2_400, is_lend: true })
        );
        assert_eq(
            needs_lending_action_(5_500, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 2_800, is_lend: true })
        );
        assert_eq(
            needs_lending_action_(6_000, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 3_200, is_lend: true })
        );
        assert_eq(
            needs_lending_action_(6_500, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 3_600, is_lend: true })
        );
        assert_eq(
            needs_lending_action_(7_000, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 4_000, is_lend: true })
        );
        assert_eq(
            needs_lending_action_(7_500, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 4_400, is_lend: true })
        );
        assert_eq(
            needs_lending_action_(8_000, 8_000, 8_000, 500, 0, false),
            true, // some(LendingAction { amount: 4_800, is_lend: true })
        );
    }
}