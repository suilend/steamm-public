#[allow(lint(share_owned))]
module slamm::bank {
    use std::option::{none, some};
    use std::type_name::{Self, TypeName};
    use sui::bag::{Self, Bag};
    use sui::balance::{Self, Balance};
    use sui::transfer::share_object;
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use slamm::global_admin::GlobalAdmin;
    use slamm::version::{Self, Version};
    use slamm::registry::Registry;
    use suilend::lending_market::{LendingMarket};
    use suilend::reserve::{CToken};

    // ===== Constants =====

    const CURRENT_VERSION: u16 = 1;

    // ===== Errors =====

    const ELiquidityRangeAboveHundredPercent: u64 = 1;
    const ELiquidityRangeBelowHundredPercent: u64 = 2;
    const ELendingMarketTypeMismatch: u64 = 3;
    const EOutputExceedsTotalBankReserves: u64 = 4;
    const ELiquidityRatioOffTarget: u64 = 5;

    public struct Bank<phantom T> has key {
        id: UID,
        reserve: Balance<T>,
        lending: Option<Lending>,
        c_tokens: u64,
        fields: Bag,
        version: Version,
    }

    public struct Lending has store {
        lending_market: ID,
        p_type: TypeName,
        lent: u64,
        target_liquidity_ratio_bps: u16,
        liquidity_buffer_bps: u16,
        reserve_array_index: u64,
    }
    
    public struct LendingAction has copy, store, drop {
        amount: u64,
        is_lend: bool,
    }

    public struct ObligationCapKey<phantom P, phantom T> has copy, store, drop {}

    // ====== Entry Functions =====

    public entry fun create_bank_and_share<T>(
        registry: &mut Registry,
        ctx: &mut TxContext,
    ) {
        let bank = create_bank<T>(registry, ctx);
        share_object(bank);
    }
    
    // ====== Public Functions =====

    public fun create_bank<T>(
        registry: &mut Registry,
        ctx: &mut TxContext,
    ): Bank<T> {
        let fields = bag::new(ctx);

        let bank = Bank<T> {
            id: object::new(ctx),
            reserve: balance::zero(),
            lending: none(),
            c_tokens: 0,
            fields,
            version: version::new(CURRENT_VERSION),
        };

        registry.add_bank(&bank);

        bank
    }
    
    public fun init_lending<P, T>(
        self: &mut Bank<T>,
        _: &GlobalAdmin,
        lending_market: &mut LendingMarket<P>,
        target_liquidity_ratio_bps: u16,
        liquidity_buffer_bps: u16,
        reserve_array_index: u64,
        ctx: &mut TxContext,
    ) {
        self.version.assert_version_and_upgrade(CURRENT_VERSION);
        assert!(target_liquidity_ratio_bps + liquidity_buffer_bps < 10_000, ELiquidityRangeAboveHundredPercent);
        assert!(target_liquidity_ratio_bps > liquidity_buffer_bps, ELiquidityRangeBelowHundredPercent);

        let obligation_cap = lending_market.create_obligation(ctx);

        self.fields.add(ObligationCapKey<P, T> {}, obligation_cap);

        self.lending.fill(Lending {
            lending_market: object::id(lending_market),
            p_type: type_name::get<P>(),
            lent: 0,
            target_liquidity_ratio_bps: target_liquidity_ratio_bps,
            liquidity_buffer_bps: liquidity_buffer_bps,
            reserve_array_index: reserve_array_index,
        })
    }
    
    public fun rebalance<T, P>(
        bank: &mut Bank<T>,
        lending_market: &mut LendingMarket<P>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        bank.version.assert_version_and_upgrade(CURRENT_VERSION);

        if (bank.lending.is_none()) {
            return
        };

        bank.assert_p_type<T, P>();

        let effective_liquidity = bank.effective_liquidity_ratio_bps();
        let target_liquidity = bank.target_liquidity_ratio_bps();
        let liquidity_buffer = bank.liquidity_buffer_bps();

        if (effective_liquidity > target_liquidity + liquidity_buffer) {
            let amount = compute_lend(
                bank.reserve.value(),
                bank.lent(),
                bank.target_liquidity_ratio_bps(),
            );

            bank.lend_(
                lending_market,
                amount,
                clock,
                ctx,
            );
        };

        if (effective_liquidity < target_liquidity - liquidity_buffer) {
            let amount = compute_recall(
                bank.reserve.value(),
                bank.lent(),
                bank.target_liquidity_ratio_bps(),
            );

            bank.recall_(
                lending_market,
                amount,
                clock,
                ctx,
            );
        };
    }

    public fun compute_lending_action_with_amount<T>(
        bank: &Bank<T>,
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
            lending.target_liquidity_ratio_bps as u64,
            lending.liquidity_buffer_bps as u64,
        )
    }
    
    public fun compute_lending_action<T>(
        bank: &Bank<T>,
    ): Option<LendingAction> {
        if (bank.lending.is_none()) {
            return none()
        };

        let lending = bank.lending.borrow();

        compute_lending_action_(
            bank.reserve.value(),
            lending.lent,
            lending.target_liquidity_ratio_bps as u64,
            lending.liquidity_buffer_bps as u64,
        )
    }

    public fun liquidity_ratio(
        liquid_reserve: u64,
        iliquid_reserve: u64,
    ): u16 {
        ((liquid_reserve * 10_000) / (liquid_reserve + iliquid_reserve)) as u16
    }

    // We only check lower bound
    public fun assert_liquidity<T>(
        bank: &mut Bank<T>,
    ) {
        if (bank.lending.is_none()) {
            return
        };

        let effective_liquidity = bank.effective_liquidity_ratio_bps();
        let target_liquidity = bank.target_liquidity_ratio_bps();
        let liquidity_buffer = bank.liquidity_buffer_bps();

        assert!(
            effective_liquidity >= target_liquidity - liquidity_buffer,
            ELiquidityRatioOffTarget
        );
    }

    // ====== Admin Functions =====
    
    entry fun migrate_as_global_admin<T>(
        self: &mut Bank<T>,
        _admin: &GlobalAdmin,
    ) {
        self.version.migrate_(CURRENT_VERSION);
    }
    
    // ====== Package Functions =====

    public(package) fun provision<T, P>(
        bank: &mut Bank<T>,
        lending_market: &mut LendingMarket<P>,
        required_output: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        bank.version.assert_version_and_upgrade(CURRENT_VERSION);

        if (bank.lending.is_none()) {
            return
        };

        bank.assert_p_type<T, P>();

        let amount = {
            let lending = bank.lending.borrow();
            
            compute_recall_amount(
                bank.reserve.value(),
                required_output,
                lending.lent,
                lending.target_liquidity_ratio_bps as u64,
                lending.liquidity_buffer_bps as u64,
            )
        };

        if (amount == 0) {
            return
        };

        let obligation_cap = bank.fields.borrow_mut(ObligationCapKey<P, T> {});

        let ctokens: Coin<CToken<P, T>> = lending_market.withdraw_ctokens(
            bank.lending.borrow().reserve_array_index,
            obligation_cap,
            clock,
            amount,
            ctx,
        );

        bank.c_tokens = bank.c_tokens - ctokens.value();

        let coin = lending_market.redeem_ctokens_and_withdraw_liquidity(
            bank.lending.borrow().reserve_array_index,
            clock,
            ctokens,
            none(), // rate_limiter_exemption
            ctx,
        );

        let lending = bank.lending.borrow_mut();
        lending.lent = lending.lent - amount;

        bank.reserve.join(coin.into_balance());
    }

    public(package) fun assert_p_type<T, P>(
        bank: &Bank<T>,
    ) {
        let lending = bank.lending.borrow();

        assert!(type_name::get<P>() == lending.p_type, ELendingMarketTypeMismatch);
    }

    public(package) fun reserve_mut<T>(
        bank: &mut Bank<T>,
    ): &mut Balance<T> {
        &mut bank.reserve
    }

    // ====== Private Functions =====

    fun lend_<T, P>(
        bank: &mut Bank<T>,
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

        bank.c_tokens = bank.c_tokens + c_tokens.value();

        let obligation_cap = bank.fields.borrow_mut(ObligationCapKey<P, T> {});

        lending_market.deposit_ctokens_into_obligation(
            lending.reserve_array_index,
            obligation_cap,
            clock,
            c_tokens,
            ctx,
        );

        let lending = bank.lending.borrow_mut();
        lending.lent = lending.lent + amount;
    }

    fun recall_<T, P>(
        bank: &mut Bank<T>,
        lending_market: &mut LendingMarket<P>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let lending = bank.lending.borrow();

        if (amount == 0) {
            return
        };

        let obligation_cap = bank.fields.borrow_mut(ObligationCapKey<P, T> {});

        let ctokens: Coin<CToken<P, T>> = lending_market.withdraw_ctokens(
            lending.reserve_array_index,
            obligation_cap,
            clock,
            amount,
            ctx,
        );

        bank.c_tokens = bank.c_tokens - ctokens.value();

        let coin = lending_market.redeem_ctokens_and_withdraw_liquidity(
            bank.lending.borrow().reserve_array_index,
            clock,
            ctokens,
            none(), // rate_limiter_exemption
            ctx,
        );

        let lending = bank.lending.borrow_mut();
        lending.lent = lending.lent - amount;

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
        liquidity_ratio_bps: u64,
        liquidity_buffer_bps: u64,
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
                        liquidity_ratio_bps,
                    )
                })
            }
        };

        let final_reserve = if (is_input) { reserve + amount } else { reserve - amount };

        // Else we compoute the lending action based on the liquidty ratio and buffer
        compute_lending_action_(
            final_reserve,
            lent,
            liquidity_ratio_bps,
            liquidity_buffer_bps
        )
    }
    
    fun compute_lending_action_(
        reserve: u64,
        lent: u64,
        liquidity_ratio_bps: u64,
        liquidity_buffer_bps: u64,
    ): Option<LendingAction> {
        let liquidity_ratio = liquidity_ratio(reserve, lent) as u64;

        if (liquidity_ratio > liquidity_ratio_bps + liquidity_buffer_bps) {
            return some(LendingAction {
                is_lend: true,
                amount: compute_lend(
                    reserve,
                    lent,
                    liquidity_ratio_bps,
                )
            })
        };

        let liquidity_ratio = liquidity_ratio(reserve, lent) as u64;

        if (liquidity_ratio < liquidity_ratio_bps - liquidity_buffer_bps) {
            return some(LendingAction {
                is_lend: false,
                amount: compute_recall(
                    reserve,
                    lent,
                    liquidity_ratio_bps,
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
        liquidity_ratio_bps: u64,
        liquidity_buffer_bps: u64,
    ): u64 {
        assert_output_(reserve, lent, amount);
        
        let needs_recall = if (amount > reserve) { true } else {
            let post_liquidity_ratio = liquidity_ratio(reserve - amount, lent) as u64;
            post_liquidity_ratio < liquidity_ratio_bps - liquidity_buffer_bps
        };

        if (needs_recall) {
            return compute_recall_with_amount(
                reserve,
                amount,
                lent,
                liquidity_ratio_bps,
            )
        } else { 0 }
    }
    
    fun compute_liquidity_ratio(
        reserve: u64,
        lent: u64,
    ): u64 {
        (reserve * 10_000) / (reserve + lent)
    }

    // only called when the ratio is above... otherwise fails
    fun compute_recall(
        reserve: u64,
        lent: u64,
        liquidity_ratio_bps: u64,
    ): u64 {
        compute_recall_with_amount(reserve, 0, lent, liquidity_ratio_bps)
    }
    
    fun compute_recall_with_amount(
        reserve: u64,
        output: u64,
        lent: u64,
        liquidity_ratio_bps: u64,
    ): u64 {
        (
            liquidity_ratio_bps * (reserve + lent - output) + (output * 10_000) - (reserve * 10_000)
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
        liquidity_ratio_bps: u64,
    ): u64 {
        reserve_t1 - (liquidity_ratio_bps * (reserve_t1 + lent) / 10_000)
    }

    // ====== Getters Functions =====

    public fun lending<T>(self: &Bank<T>): &Option<Lending> { &self.lending }
    
    public fun total_reserve<T>(self: &Bank<T>): u64 {
        self.reserve.value() + self.lent()
    }
    
    public fun effective_liquidity_ratio_bps<T>(self: &Bank<T>): u64 { 
        compute_liquidity_ratio(self.reserve.value(), self.lent())
    }
    
    public fun lent<T>(self: &Bank<T>): u64 {
        if (self.lending.is_some()) {
            self.lent_unchecked()
        } else { 0 }
    }
    
    public fun target_liquidity_ratio_bps<T>(self: &Bank<T>): u64 {
        if (self.lending.is_some()) {
            self.liquidity_ratio_bps_unchecked()
        } else { 0 }
    }
    
    public fun liquidity_buffer_bps<T>(self: &Bank<T>): u64 {
        if (self.lending.is_some()) {
            self.liquidity_buffer_bps_unchecked()
        } else { 0 }
    }
    
    public fun lending_market<T>(self: &Bank<T>): ID { self.lending.borrow().lending_market }
    public fun p_type<T>(self: &Bank<T>): TypeName { self.lending.borrow().p_type }
    public fun reserve<T>(self: &Bank<T>): &Balance<T> { &self.reserve }
    public fun lent_unchecked<T>(self: &Bank<T>): u64 { self.lending.borrow().lent }
    public fun liquidity_ratio_bps_unchecked<T>(self: &Bank<T>): u64 { self.lending.borrow().target_liquidity_ratio_bps as u64}
    public fun liquidity_buffer_bps_unchecked<T>(self: &Bank<T>): u64 { self.lending.borrow().liquidity_buffer_bps as u64 }
    public fun reserve_array_index<T>(self: &Bank<T>): u64 { self.lending.borrow().reserve_array_index }

    // ===== Tests =====

    #[test_only]
    use sui::test_utils::assert_eq;

    #[test]
    fun test_compute_recall() {
        
        // Reserve, Lent, Liquidity Ratio
        assert_eq(compute_recall(2_000, 8_000, 2_000), 0);
        assert_eq(compute_recall(1_000, 9_000, 2_000), 1000);
        assert_eq(compute_recall(0, 10_000, 2_000), 2000);
    }
    
    #[test]
    fun test_compute_recall_amount() {

        assert_eq(
            compute_recall_amount(2_000, 0, 8_000, 2_000, 500), 0
        );
        
        assert_eq(
            compute_recall_amount(2_000, 1_000, 8_000, 2_000, 500), 800
        );
        
        assert_eq(
            compute_recall_amount(2_000, 2_000, 8_000, 2_000, 500), 1_600
        );
        
        // Does not need recall as it does not change liq. ratio beyond the bands
        assert_eq(
            compute_recall_amount(2_000, 100, 8_000, 2_000, 500), 0
        );
    }

    #[test]
    fun test_compute_lend() {
        
        // Reserve, Lent, Liquidity Ratio
        assert_eq(compute_lend(2_000, 8_000, 2_000), 0);
        assert_eq(compute_lend(3_000, 8_000, 2_000), 800);
        assert_eq(compute_lend(4_000, 8_000, 2_000), 1600);
    }
    
    #[test]
    fun test_compute_lending_action() {
        // Reserve, Lent, Liquidity Ratio
        assert_eq(compute_lending_action_(0, 8_000, 2_000, 500), some(LendingAction { amount: 1_600, is_lend: false }));
        assert_eq(compute_lending_action_(500, 8_000, 2_000, 500), some(LendingAction { amount: 1_200, is_lend: false }));
        assert_eq(compute_lending_action_(1_000, 8_000, 2_000, 500), some(LendingAction { amount: 800, is_lend: false }));
        assert_eq(compute_lending_action_(1_500, 8_000, 2_000, 500), none());
        assert_eq(compute_lending_action_(2_000, 8_000, 2_000, 500), none());
        assert_eq(compute_lending_action_(2_500, 8_000, 2_000, 500), none());
        assert_eq(compute_lending_action_(3_000, 8_000, 2_000, 500), some(LendingAction { amount: 800, is_lend: true }));
        assert_eq(compute_lending_action_(3_500, 8_000, 2_000, 500), some(LendingAction { amount: 1_200, is_lend: true }));
        assert_eq(compute_lending_action_(4_000, 8_000, 2_000, 500), some(LendingAction { amount: 1_600, is_lend: true }));
        assert_eq(compute_lending_action_(4_500, 8_000, 2_000, 500), some(LendingAction { amount: 2_000, is_lend: true }));
        assert_eq(compute_lending_action_(5_000, 8_000, 2_000, 500), some(LendingAction { amount: 2_400, is_lend: true }));
        assert_eq(compute_lending_action_(5_500, 8_000, 2_000, 500), some(LendingAction { amount: 2_800, is_lend: true }));
        assert_eq(compute_lending_action_(6_000, 8_000, 2_000, 500), some(LendingAction { amount: 3_200, is_lend: true }));
        assert_eq(compute_lending_action_(6_500, 8_000, 2_000, 500), some(LendingAction { amount: 3_600, is_lend: true }));
        assert_eq(compute_lending_action_(7_000, 8_000, 2_000, 500), some(LendingAction { amount: 4_000, is_lend: true }));
        assert_eq(compute_lending_action_(7_500, 8_000, 2_000, 500), some(LendingAction { amount: 4_400, is_lend: true }));
        assert_eq(compute_lending_action_(8_000, 8_000, 2_000, 500), some(LendingAction { amount: 4_800, is_lend: true }));
        // assert_eq(compute_lend(3_000, 8_000, 2_000), 800);
        // assert_eq(compute_lend(4_000, 8_000, 2_000), 1600);
    }
}