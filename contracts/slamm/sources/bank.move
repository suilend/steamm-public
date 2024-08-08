#[allow(lint(share_owned))]
module slamm::bank {
    use std::{
        option::{none, some},
        // debug::print,
    };
    use sui::{
        balance::{Self, Balance},
        transfer::share_object,
        clock::Clock,
        coin::{Self, Coin},
        bag::{Self, Bag},
    };
    use slamm::{
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
    const EOutputExceedsTotalBankReserves: u64 = 3;
    const EUtilisationRateOffTarget: u64 = 4;
    const ELendingAlreadyActive: u64 = 5;
    const EEmptyBank: u64 = 6;

    public struct Bank<phantom P, phantom T> has key {
        id: UID,
        reserve: Balance<T>,
        lending: Option<Lending<P>>,
        fields: Bag,
        version: Version,
    }

    public struct Lending<phantom P> has store {
        lending_market: ID,
        lent: u64,
        ctokens: u64,
        target_utilisation: u16,
        utilisation_buffer: u16,
        reserve_array_index: u64,
        obligation_cap: ObligationOwnerCap<P>,
    }
    
    public struct LendingAction has copy, store, drop {
        amount: u64,
        is_lend: bool,
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
            reserve: balance::zero(),
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
        target_utilisation: u16,
        utilisation_buffer: u16,
        ctx: &mut TxContext,
    ) {
        self.version.assert_version_and_upgrade(CURRENT_VERSION);
        assert!(self.lending.is_none(), ELendingAlreadyActive);
        assert!(target_utilisation + utilisation_buffer < 10_000, EUtilisationRangeAboveHundredPercent);
        assert!(target_utilisation > utilisation_buffer, EUtilisationRangeBelowHundredPercent);

        let obligation_cap = lending_market.create_obligation(ctx);
        let reserve_array_index = lending_market.reserve_array_index<P, T>();

        self.lending.fill(Lending {
            lending_market: object::id(lending_market),
            lent: 0,
            ctokens: 0,
            target_utilisation,
            utilisation_buffer,
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
            let amount = compute_lend(
                bank.reserve.value(),
                bank.lent(),
                target_utilisation,
            );

            bank.deploy(
                lending_market,
                amount,
                clock,
                ctx,
            );
        };

        if (effective_utilisation > target_utilisation + buffer) {
            let amount = compute_recall(
                bank.reserve.value(),
                bank.lent(),
                target_utilisation,
            );

            bank.recall(
                lending_market,
                amount,
                clock,
                ctx,
            );
        };
    }

    public fun compute_lending_action_with_amount<P, T>(
        bank: &Bank<P, T>,
        amount: u64,
        is_input: bool,
    ): Option<LendingAction> {
        if (bank.lending.is_none()) {
            return none()
        };

        let lending = bank.lending.borrow();

        compute_lending_action_with_amount_(
            bank.reserve.value(),
            amount,
            is_input,
            lending.lent,
            lending.target_utilisation as u64,
            lending.utilisation_buffer as u64,
        )
    }
    
    public fun compute_lending_action<P, T>(
        bank: &Bank<P, T>,
    ): Option<LendingAction> {
        if (bank.lending.is_none()) {
            return none()
        };

        let lending = bank.lending.borrow();

        compute_lending_action_(
            bank.reserve.value(),
            lending.lent,
            lending.target_utilisation as u64,
            lending.utilisation_buffer as u64,
        )
    }

    public fun ctoken_amount<P, T>(
        bank: &Bank<P, T>,
        lending_market: &LendingMarket<P>,
        amount: u64,
    ): u64 {
        bank.ctoken_amount_(lending_market, amount)
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

    // ====== Admin Functions =====
    
    entry fun migrate_as_global_admin<P, T>(
        self: &mut Bank<P, T>,
        _admin: &GlobalAdmin,
    ) {
        self.version.migrate_(CURRENT_VERSION);
    }
    
    // ====== Package Functions =====

    public(package) fun provision<P, T>(
        bank: &mut Bank<P, T>,
        lending_market: &mut LendingMarket<P>,
        required_output: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        bank.version.assert_version_and_upgrade(CURRENT_VERSION);

        if (bank.lending.is_none()) {
            return
        };

        let amount = {
            let lending = bank.lending.borrow();
            
            compute_recall_amount(
                bank.reserve.value(),
                required_output,
                lending.lent,
                lending.target_utilisation as u64,
                lending.utilisation_buffer as u64,
            )
        };

        bank.recall(
            lending_market,
            amount,
            clock,
            ctx,
        );
    }

    public(package) fun reserve_mut<P, T>(
        bank: &mut Bank<P, T>,
    ): &mut Balance<T> {
        &mut bank.reserve
    }

    // ====== Private Functions =====

    fun deploy<P, T>(
        bank: &mut Bank<P, T>,
        lending_market: &mut LendingMarket<P>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let lending = bank.lending.borrow();

        if (amount == 0) {
            return
        };

        let balance_to_lend = bank.reserve.split(amount);

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
        lending.lent = lending.lent + amount;
        lending.ctokens = lending.ctokens + ctoken_amount;
    }

    fun recall<P, T>(
        bank: &mut Bank<P, T>,
        lending_market: &mut LendingMarket<P>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let lending = bank.lending.borrow();

        if (amount == 0) {
            return
        };

        let mut ctoken_amount = bank.ctoken_amount_(lending_market, amount);
        // let obligation_cap = bank.fields.borrow_mut(ObligationCapKey<P, T> {});

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
        lending.lent = lending.lent - amount;
        lending.ctokens = lending.ctokens - ctoken_amount;

        bank.reserve.join(coin.into_balance());
    }
    
    fun assert_output_(
        liquid_reserve: u64,
        lent: u64,
        output: u64,
    ) {
        assert!(liquid_reserve + lent >= output, EOutputExceedsTotalBankReserves);
    }

    fun compute_lending_action_with_amount_(
        reserve: u64,
        amount: u64,
        is_input: bool,
        lent: u64,
        target_utilisation: u64,
        buffer: u64,
    ): Option<LendingAction> {
        if (!is_input) {
            assert_output_(reserve, lent, amount);

            // If the amount is bigger than the reserve, then it's clear that
            // we need to recall
            if (amount > reserve) {
                return some(LendingAction {
                    is_lend: false,
                    amount: compute_recall_with_amount(
                        reserve,
                        amount,
                        lent,
                        target_utilisation,
                    )
                })
            }
        };

        let final_reserve = if (is_input) { reserve + amount } else { reserve - amount };

        // Else we compoute the lending action based on the liquidty ratio and buffer
        compute_lending_action_(
            final_reserve,
            lent,
            target_utilisation,
            buffer,
        )
    }
    
    fun compute_lending_action_(
        reserve: u64,
        lent: u64,
        target_utilisation: u64,
        buffer: u64,
    ): Option<LendingAction> {
        let effective_utilisation = compute_utilisation_rate(reserve, lent);

        if (effective_utilisation < target_utilisation - buffer) {
            return some(LendingAction {
                is_lend: true,
                amount: compute_lend(
                    reserve,
                    lent,
                    target_utilisation,
                )
            })
        };

        if (effective_utilisation > target_utilisation + buffer) {
            return some(LendingAction {
                is_lend: false,
                amount: compute_recall(
                    reserve,
                    lent,
                    target_utilisation,
                )
            })
        };

        none()   
    }
    
    // Only computes recall if needed, else returns zero
    fun compute_recall_amount(
        reserve: u64,
        amount: u64,
        lent: u64,
        target_utilisation: u64,
        buffer: u64,
    ): u64 {
        assert_output_(reserve, lent, amount);
        
        let needs_recall = if (amount > reserve) { true } else {
            let post_utilisation_ratio = compute_utilisation_rate(reserve - amount, lent) as u64;

            post_utilisation_ratio > target_utilisation + buffer
        };

        if (needs_recall) {
            return compute_recall_with_amount(
                reserve,
                amount,
                lent,
                target_utilisation,
            )
        } else { 0 }
    }
    
    fun compute_utilisation_rate(
        liquid_reserve: u64,
        lent: u64,
    ): u64 {
        assert!(liquid_reserve + lent > 0, EEmptyBank);
        10_000 - ( (liquid_reserve * 10_000) / (liquid_reserve + lent) )
    }

    // only called when the ratio is above... otherwise fails
    fun compute_recall(
        reserve: u64,
        lent: u64,
        target_utilisation: u64,
    ): u64 {
        compute_recall_with_amount(reserve, 0, lent, target_utilisation)
    }
    

    // (1 - utilisation ratio) * (R + Lent - Out) + (Out * 10_000) - (R * 10_000)
    fun compute_recall_with_amount(
        reserve: u64,
        output: u64,
        lent: u64,
        target_utilisation: u64,
    ): u64 {
        (
            (10_000 - target_utilisation) * (reserve + lent - output) + (output * 10_000) - (reserve * 10_000)
        ) / 10_000
    }
    
    // effective_liquidity > target_liquidity + liquidity_buffer
    // 25% > 20%
    // 5% * total_reserves =
    // (effective_liquidity - target_liquidity) * total_reserves
    // [liquid / (liquid + iliquid) - target] * (liquid + iliquid)
    // liquid - target * (liquid + iliquid)
    fun compute_lend(
        reserve_t1: u64,
        lent: u64,
        target_utilisation: u64,
    ): u64 {
        reserve_t1 - ((10_000 - target_utilisation) * (reserve_t1 + lent) / 10_000)
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

    // ====== Getters Functions =====

    public fun lending<P, T>(self: &Bank<P, T>): &Option<Lending<P>> { &self.lending }
    
    public fun total_reserve<P, T>(self: &Bank<P, T>): u64 {
        self.reserve.value() + self.lent()
    }

    public fun effective_utilisation_rate<P, T>(self: &Bank<P, T>): u64 { 
        compute_utilisation_rate(self.reserve.value(), self.lent())
    }
    
    public fun lent<P, T>(self: &Bank<P, T>): u64 {
        if (self.lending.is_some()) {
            self.lent_unchecked()
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
    public fun reserve<P, T>(self: &Bank<P, T>): &Balance<T> { &self.reserve }
    public fun lent_unchecked<P, T>(self: &Bank<P, T>): u64 { self.lending.borrow().lent }
    public fun target_utilisation_rate_unchecked<P, T>(self: &Bank<P, T>): u64 { self.lending.borrow().target_utilisation as u64}
    public fun utilisation_buffer_unchecked<P, T>(self: &Bank<P, T>): u64 { self.lending.borrow().utilisation_buffer as u64 }
    public fun reserve_array_index<P, T>(self: &Bank<P, T>): u64 { self.lending.borrow().reserve_array_index }

    // ===== Test-Only Functions =====
    
    #[test_only]
    public fun mock_amount_lent<P, T>(self: &mut Bank<P, T>, amount: u64){ self.lending.borrow_mut().lent = amount; }

    // ===== Tests =====

    #[test_only]
    use sui::test_utils::assert_eq;
    
    #[test]
    fun test_compute_recall() {
        // Reserve, Lent, Utilisation Ratio
        assert_eq(compute_recall(2_000, 8_000, 8_000), 0);
        assert_eq(compute_recall(1_000, 9_000, 8_000), 1000);
        assert_eq(compute_recall(0, 10_000, 8_000), 2000);
    }
    
    #[test]
    fun test_compute_recall_amount() {
        assert_eq(
            compute_recall_amount(2_000, 0, 8_000, 8_000, 500), 0
        );
        
        assert_eq(
            compute_recall_amount(2_000, 1_000, 8_000, 8_000, 500), 800
        );
        
        assert_eq(
            compute_recall_amount(2_000, 2_000, 8_000, 8_000, 500), 1_600
        );
        
        // Does not need recall as it does not change liq. ratio beyond the bands
        assert_eq(
            compute_recall_amount(2_000, 100, 8_000, 8_000, 500), 0
        );
    }
    
    #[test]
    #[expected_failure(abort_code = EOutputExceedsTotalBankReserves)]
    fun test_fail_compute_recall_with_output_too_big() {
        compute_lending_action_with_amount_(2_000, 4001, false, 2_000, 1_000, 500);
    }
    
    #[test]
    fun test_assert_output_ok() {
        assert_output_(1_000, 1_000, 500);
    }
    
    #[test]
    #[expected_failure(abort_code = EOutputExceedsTotalBankReserves)]
    fun test_assert_output_not_ok() {
        assert_output_(1_000, 1_000, 5_000);
    }

    #[test]
    fun test_compute_lend() {
        // Reserve, Lent, Utilisation Ratio
        assert_eq(compute_lend(2_000, 8_000, 8_000), 0);
        assert_eq(compute_lend(3_000, 8_000, 8_000), 800);
        assert_eq(compute_lend(4_000, 8_000, 8_000), 1600);
    }
    
    #[test]
    fun test_compute_utilisation_rate() {
        // Reserve, Lent, Utilisation Ratio
        assert_eq(compute_utilisation_rate(10_000, 0), 0); // 100%
        assert_eq(compute_utilisation_rate(7_000, 3_000), 3_000); // 70%
        assert_eq(compute_utilisation_rate(5_000, 5_000), 5_000); // 50%
        assert_eq(compute_utilisation_rate(3_000, 7_000), 7_000); // 30%
        assert_eq(compute_utilisation_rate(0, 10_000), 10_000); // 0%
    }
    
    #[test]
    fun test_compute_lending_action() {
        // Reserve, Lent, Utilisation Ratio
        assert_eq(compute_lending_action_(0, 8_000, 8_000, 500), some(LendingAction { amount: 1_600, is_lend: false }));
        assert_eq(compute_lending_action_(500, 8_000, 8_000, 500), some(LendingAction { amount: 1_200, is_lend: false }));
        assert_eq(compute_lending_action_(1_000, 8_000, 8_000, 500), some(LendingAction { amount: 800, is_lend: false }));
        assert_eq(compute_lending_action_(1_500, 8_000, 8_000, 500), none());
        assert_eq(compute_lending_action_(2_000, 8_000, 8_000, 500), none());
        assert_eq(compute_lending_action_(2_500, 8_000, 8_000, 500), none());
        assert_eq(compute_lending_action_(3_000, 8_000, 8_000, 500), some(LendingAction { amount: 800, is_lend: true }));
        assert_eq(compute_lending_action_(3_500, 8_000, 8_000, 500), some(LendingAction { amount: 1_200, is_lend: true }));
        assert_eq(compute_lending_action_(4_000, 8_000, 8_000, 500), some(LendingAction { amount: 1_600, is_lend: true }));
        assert_eq(compute_lending_action_(4_500, 8_000, 8_000, 500), some(LendingAction { amount: 2_000, is_lend: true }));
        assert_eq(compute_lending_action_(5_000, 8_000, 8_000, 500), some(LendingAction { amount: 2_400, is_lend: true }));
        assert_eq(compute_lending_action_(5_500, 8_000, 8_000, 500), some(LendingAction { amount: 2_800, is_lend: true }));
        assert_eq(compute_lending_action_(6_000, 8_000, 8_000, 500), some(LendingAction { amount: 3_200, is_lend: true }));
        assert_eq(compute_lending_action_(6_500, 8_000, 8_000, 500), some(LendingAction { amount: 3_600, is_lend: true }));
        assert_eq(compute_lending_action_(7_000, 8_000, 8_000, 500), some(LendingAction { amount: 4_000, is_lend: true }));
        assert_eq(compute_lending_action_(7_500, 8_000, 8_000, 500), some(LendingAction { amount: 4_400, is_lend: true }));
        assert_eq(compute_lending_action_(8_000, 8_000, 8_000, 500), some(LendingAction { amount: 4_800, is_lend: true }));
    }
}