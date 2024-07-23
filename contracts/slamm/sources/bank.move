module slamm::bank {
    use std::option::{none, some};
    use std::type_name::{Self, TypeName};
    use sui::bag::{Self, Bag};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use slamm::quote::SwapQuote;
    use slamm::global_admin::GlobalAdmin;
    use slamm::registry::Registry;
    use suilend::lending_market::{LendingMarket};
    use suilend::reserve::{CToken};

    public struct Bank<phantom T> has key {
        id: UID,
        reserve: Balance<T>,
        lending: Option<Lending>,
        fields: Bag,
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

    public struct LendingReserveKey<phantom T> has copy, store, drop {}

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
            fields,
        };

        registry.add_bank(&bank);

        bank
    }
    
    public fun init_lending<P, T>(
        self: &mut Bank<T>,
        _: &GlobalAdmin,
        lending_market: &LendingMarket<P>,
        target_liquidity_ratio_bps: u16,
        liquidity_buffer_bps: u16,
        reserve_array_index: u64,
    ) {
        self.fields.add(LendingReserveKey<T> {}, balance::zero<CToken<P, T>>());

        self.lending.fill(Lending {
            lending_market: object::id(lending_market),
            p_type: type_name::get<P>(),
            lent: 0,
            target_liquidity_ratio_bps: target_liquidity_ratio_bps,
            liquidity_buffer_bps: liquidity_buffer_bps,
            reserve_array_index: reserve_array_index,
        })
    }

    public fun lend<T, P>(
        bank: &mut Bank<T>,
        lending_market: &mut LendingMarket<P>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let lending = bank.lending.borrow();

        let amount = compute_lending_amount(
            bank.reserve.value(),
            lending.lent,
            lending.target_liquidity_ratio_bps as u64,
            lending.liquidity_buffer_bps as u64,
        );

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

        let lending = bank.lending.borrow_mut();

        lending.lent = lending.lent + amount;
        bank.deposit_c_tokens(c_tokens.into_balance());
    }

    public fun recall<T, P>(
        bank: &mut Bank<T>,
        lending_market: &mut LendingMarket<P>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let amount = {
            let lending = bank.lending.borrow();

            compute_recall_amount(
                bank.reserve.value(),
                0,
                lending.lent,
                lending.target_liquidity_ratio_bps as u64,
                lending.liquidity_buffer_bps as u64,
            )
        };
            

        if (amount == 0) {
            return
        };

        let ctokens: Coin<CToken<P, T>> = coin::from_balance(bank.withdraw_c_tokens(amount), ctx);

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

    public fun rebalance<T, P>(
        bank: &mut Bank<T>,
        lending_market: &mut LendingMarket<P>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let effective_liquidity = bank.effective_liquidity_ratio_bps();
        let target_liquidity = bank.liquidity_ratio_bps() as u64;
        let liquidity_buffer = bank.liquidity_buffer_bps() as u64;

        if (effective_liquidity > target_liquidity + liquidity_buffer) {
            let amount = compute_lend(
                bank.reserve.value(),
                bank.lent(),
                bank.liquidity_ratio_bps() as u64,
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
                bank.liquidity_ratio_bps() as u64,
            );

            bank.recall_(
                lending_market,
                amount,
                clock,
                ctx,
            );
        };
    }

    public fun compute_lending_action<T>(
        bank: &Bank<T>,
        amount: u64,
        is_input: bool,
    ): Option<LendingAction> {
        let lending = bank.lending.borrow();

        compute_lending_action_(
            bank.reserve.value(),
            amount,
            is_input,
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

    public fun assert_liquidity_requirements(
        self: &Lending,
        reserve: u64,
        amount: u64,
        is_input: bool,
        lent: u64,
    ) {
        if (is_input) {
            let liquidity_ratio = liquidity_ratio(reserve + amount, lent) as u64;
            assert!(liquidity_ratio <= (self.target_liquidity_ratio_bps + self.liquidity_buffer_bps) as u64, 0);
        } else {
            assert!(reserve + lent > amount, 0);
            assert!(reserve > amount, 0);

            let liquidity_ratio = liquidity_ratio(reserve - amount, lent) as u64;

            assert!(liquidity_ratio >= (self.target_liquidity_ratio_bps - self.liquidity_buffer_bps) as u64, 0);
        }
    }

    // ====== Package Functions =====

    public(package) fun provision<T, P>(
        bank: &mut Bank<T>,
        lending_market: &mut LendingMarket<P>,
        required_output: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
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

        let ctokens: Coin<CToken<P, T>> = coin::from_balance(bank.withdraw_c_tokens(amount), ctx);

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
    
    public(package) fun check_sync<A, B>(
        quote: &SwapQuote,
        bank_a: &Bank<A>,
        bank_b: &Bank<B>,
        a2b: bool,
    ): bool {
        if (a2b) {
            bank_b.check_sync_(quote.amount_out())
        } else {
            bank_a.check_sync_(quote.amount_out())
        }
    }

    public(package) fun assert_p_type<P, T>(
        bank: &Bank<T>,
    ) {
        let lending = bank.lending.borrow();

        assert!(type_name::get<P>() == lending.p_type, 0);
    }

    public(package) fun reserve_mut<T>(
        bank: &mut Bank<T>,
    ): &mut Balance<T> {
        &mut bank.reserve
    }

    // ====== Private Functions =====

    fun check_sync_<T>(
        bank: &Bank<T>,
        output: u64,
    ): bool {
        assert!(bank.total_reserve() >= output, 0);

        output > bank.reserve.value()
    }
    
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

        let lending = bank.lending.borrow_mut();

        lending.lent = lending.lent + amount;
        bank.deposit_c_tokens(c_tokens.into_balance());
    }

    fun recall_<T, P>(
        bank: &mut Bank<T>,
        lending_market: &mut LendingMarket<P>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        if (amount == 0) {
            return
        };

        let ctokens: Coin<CToken<P, T>> = coin::from_balance(bank.withdraw_c_tokens(amount), ctx);

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

    fun deposit_c_tokens<P, T>(
        reserve: &mut Bank<T>,
        c_tokens: Balance<CToken<P, T>>
    ) {
        let c_balance: &mut Balance<CToken<P, T>> = reserve.fields.borrow_mut(LendingReserveKey<T> {});
        c_balance.join(c_tokens);
    }
    
    fun withdraw_c_tokens<P, T>(
        reserve: &mut Bank<T>,
        c_tokens: u64,
    ): Balance<CToken<P, T>> {
        let c_balance: &mut Balance<CToken<P, T>> = reserve.fields.borrow_mut(LendingReserveKey<T> {});
        c_balance.split(c_tokens)
    }

    fun compute_lending_amount(
        reserve: u64,
        lent: u64,
        liquidity_ratio_bps: u64,
        liquidity_buffer_bps: u64,
    ): u64 {
        let liquidity_ratio = liquidity_ratio(reserve, lent) as u64;

        assert!(liquidity_ratio >= liquidity_ratio_bps, 0);

        if (liquidity_ratio > liquidity_ratio_bps + liquidity_buffer_bps) {
            compute_lend(
                reserve,
                lent,
                liquidity_ratio_bps,
            )
        } else {
            0
        }
    }
    
    fun compute_lending_action_(
        reserve: u64,
        amount: u64,
        is_input: bool,
        lent: u64,
        liquidity_ratio_bps: u64,
        liquidity_buffer_bps: u64,
    ): Option<LendingAction> {
        if (is_input) {
            let liquidity_ratio = liquidity_ratio(reserve + amount, lent) as u64;

            if (liquidity_ratio > liquidity_ratio_bps + liquidity_buffer_bps) {
                return some(LendingAction {
                    is_lend: true,
                    amount: compute_lend(
                        reserve + amount,
                        lent,
                        liquidity_ratio_bps,
                    )
                })
            } else {
                none()
            }


        } else {
            assert!(reserve + lent > amount, 0);

            if (amount > reserve) {
                return some(LendingAction {
                    is_lend: false,
                    amount: compute_recall_(
                        reserve,
                        amount,
                        lent,
                        liquidity_ratio_bps,
                    )
                })
            };

            let liquidity_ratio = liquidity_ratio(reserve - amount, lent) as u64;

            if (liquidity_ratio < liquidity_ratio_bps - liquidity_buffer_bps) {
                return some(LendingAction {
                    is_lend: false,
                    amount: compute_recall_(
                        reserve,
                        amount,
                        lent,
                        liquidity_ratio_bps,
                    )
                })
            } else {
                none()
            }
        }
    }
    
    fun compute_recall_amount(
        reserve: u64,
        amount: u64,
        lent: u64,
        liquidity_ratio_bps: u64,
        liquidity_buffer_bps: u64,
    ): u64 {
        assert!(reserve + lent > amount, 0);
        let post_liquidity_ratio = liquidity_ratio(reserve + lent - amount, lent) as u64;

        if (amount > reserve || post_liquidity_ratio < liquidity_ratio_bps - liquidity_buffer_bps) {
            return compute_recall_(
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
    
    // 15% < 20%
    // 5% * total_reserves =
    // (target_liquidity - effective_liquidity) * total_reserves
    // [target - liquid / (liquid + iliquid)] * (liquid + iliquid)
    // target * (liquid + iliquid) - liquid
    fun compute_recall(
        reserve_t1: u64,
        lent: u64,
        liquidity_ratio_bps: u64,
    ): u64 {
        (liquidity_ratio_bps * (reserve_t1 + lent) / 10_000) - reserve_t1
    }

    fun compute_recall_(
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
    
    public fun liquidity_ratio_bps<T>(self: &Bank<T>): u16 {
        if (self.lending.is_some()) {
            self.liquidity_ratio_bps_unchecked()
        } else { 0 }
    }
    
    public fun liquidity_buffer_bps<T>(self: &Bank<T>): u16 {
        if (self.lending.is_some()) {
            self.liquidity_buffer_bps_unchecked()
        } else { 0 }
    }
    
    public fun lending_market<T>(self: &Bank<T>): ID { self.lending.borrow().lending_market }
    public fun p_type<T>(self: &Bank<T>): TypeName { self.lending.borrow().p_type }
    public fun reserve<T>(self: &Bank<T>): &Balance<T> { &self.reserve }
    public fun lent_unchecked<T>(self: &Bank<T>): u64 { self.lending.borrow().lent }
    public fun liquidity_ratio_bps_unchecked<T>(self: &Bank<T>): u16 { self.lending.borrow().target_liquidity_ratio_bps }
    public fun liquidity_buffer_bps_unchecked<T>(self: &Bank<T>): u16 { self.lending.borrow().liquidity_buffer_bps }
    public fun reserve_array_index<T>(self: &Bank<T>): u64 { self.lending.borrow().reserve_array_index }
}