module slamm::lend {
    use std::option::none;
    use std::type_name::{Self, TypeName};
    use sui::bag::{Self, Bag};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use slamm::global_admin::GlobalAdmin;
    use suilend::lending_market::{LendingMarket};
    use suilend::reserve::{CToken};

    public struct Bank<phantom T> has key {
        id: UID,
        lending_market: ID,
        p_type: TypeName,
        reserve: Balance<T>,
        // c_tokens: Balance<CToken<P, T>>,
        lent: u64,
        liquidity_ratio_bps: u16,
        liquidity_buffer_bps: u16,
        reserve_array_index: u64,
        fields: Bag,
    }

    public enum ReserveAction has copy, store, drop {
        PushFunds(u64),
        Ok,
        PullFunds(u64),
    }
    
    public enum LendingAction has copy, store, drop {
        Lend(u64),
        Ok,
        Recall(u64),
    }

    public struct LendingReserveKey<phantom T> has copy, store, drop {}

    public struct LendingReserve<phantom P, phantom T> has store {
        c_tokens: Balance<CToken<P, T>>
    }

    public fun lent<T>(self: &Bank<T>): u64 { self.lent }
    public(package) fun lent_mut<T>(self: &mut Bank<T>): &mut u64 { &mut self.lent }
    
    public fun is_ok(self: &LendingAction): bool {
        match(self) {
            LendingAction::Ok => true,
            _ => false,
        }
    }
    
    public(package) fun no_op(): LendingAction { LendingAction::Ok }

    public fun init_bank<P, T>(
        _: &GlobalAdmin,
        lending_market: &LendingMarket<P>,
        liquidity_ratio_bps: u16,
        liquidity_buffer_bps: u16,
        reserve_array_index: u64,
        ctx: &mut TxContext,
    ): Bank<T> {
        let mut fields = bag::new(ctx);
        fields.add(LendingReserveKey<T> {}, LendingReserve<P, T> { c_tokens: balance::zero() });

        Bank<T> {
            id: object::new(ctx),
            lending_market: object::id(lending_market),
            p_type: type_name::get<P>(),
            reserve: balance::zero(),
            lent: 0,
            liquidity_ratio_bps,
            liquidity_buffer_bps,
            reserve_array_index,
            fields,
        }
    }

    public fun compute_lending_action<T>(
        bank: &Bank<T>,
        amount: u64,
        is_input: bool,
    ): LendingAction {
        compute_lending_action_(
            bank.reserve.value(),
            amount,
            is_input,
            bank.lent,
            bank.liquidity_ratio_bps as u64,
            bank.liquidity_buffer_bps as u64,
        )
    }
    
    public(package) fun reserve_mut<T>(
        bank: &mut Bank<T>,
    ): &mut Balance<T> {
        &mut bank.reserve
    }

    // public(package) fun deposit_liquidity<T>(
    //     deposit: Balance<T>,
    //     lending: &mut Lending,
    //     lending_pool: &mut Bank<T>,
    // ): LendingAction {
    //     let deposit_amt = deposit.value();
    //     lending.lent = lending.lent + deposit_amt;

    //     let lending_action = compute_lending_action_(
    //         lending_pool.reserve.value(),
    //         deposit.value(),
    //         true,
    //         lending_pool.lent,
    //         lending_pool.liquidity_ratio_bps as u64,
    //         lending_pool.liquidity_buffer_bps as u64,
    //     );

    //     lending_pool.reserve.join(deposit);

    //     lending_action
    // }
    
    // public(package) fun withdraw_liquidity<T>(
    //     reserve: &mut Balance<T>,
    //     withdraw: u64,
    //     lending: &mut Lending,
    //     lending_pool: &mut Bank<T>,
    // ): LendingAction {
    //     lending.lent = lending.lent - withdraw;

    //     let lending_action = compute_lending_action_(
    //         lending_pool.reserve.value(),
    //         withdraw,
    //         false,
    //         lending_pool.lent,
    //         lending_pool.liquidity_ratio_bps as u64,
    //         lending_pool.liquidity_buffer_bps as u64,
    //     );

    //     reserve.join(lending_pool.reserve.split(withdraw));

    //     lending_action
    // }

    // public(package) fun rebalance_pool<T>(
    //     reserve: &mut Balance<T>,
    //     lending: &mut Lending,
    //     lending_action: &LendingAction,
    //     lending_pool: &mut Bank<T>,
    // ): LendingAction {
    //     match (lending_action) {
    //         LendingAction::Lend(amount) => {
    //             let balance_to_lend = reserve.split(*amount);

    //             let action = deposit_liquidity(
    //                 balance_to_lend,
    //                 lending,
    //                 lending_pool,
    //             );

    //             action
    //         },
    //         LendingAction::Ok => { LendingAction::Ok },
    //         LendingAction::Recall(amount) => {
    //             let action = withdraw_liquidity(
    //                 reserve,
    //                 *amount,
    //                 lending,
    //                 lending_pool,
    //             );

    //             action
    //         },
    //     }

    // }

    public(package) fun rebalance_lending<T, P>(
        bank: &mut Bank<T>,
        lending_market: &mut LendingMarket<P>,
        lending_action: &mut LendingAction,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        match (lending_action) {
            LendingAction::Lend(amount) => {
                let balance_to_lend = bank.reserve.split(*amount);

                let c_tokens = lending_market.deposit_liquidity_and_mint_ctokens<P, T>(
                    bank.reserve_array_index,
                    clock,
                    coin::from_balance(balance_to_lend, ctx),
                    ctx,
                );

                bank.lent = bank.lent + *amount;
                bank.deposit_c_tokens(c_tokens.into_balance());

                *lending_action = LendingAction::Ok;
            },
            LendingAction::Ok => {},
            LendingAction::Recall(amount) => {
                let ctokens: Coin<CToken<P, T>> = coin::from_balance(bank.withdraw_c_tokens(*amount), ctx);

                let coin = lending_market.redeem_ctokens_and_withdraw_liquidity(
                    bank.reserve_array_index,
                    clock,
                    ctokens,
                    none(), // rate_limiter_exemption
                    ctx,
                );

                bank.lent = bank.lent - *amount;

                bank.reserve.join(coin.into_balance());
                *lending_action = LendingAction::Ok;
            },
        };

    }

    public(package) fun assert_p_type<P, T>(
        reserve: &Bank<T>,
    ) {
        assert!(type_name::get<P>() == reserve.p_type, 0);
    }

    public(package) fun deposit_c_tokens<P, T>(
        reserve: &mut Bank<T>,
        c_tokens: Balance<CToken<P, T>>
    ) {
        let c_balance: &mut Balance<CToken<P, T>> = reserve.fields.borrow_mut(LendingReserveKey<T> {});
        c_balance.join(c_tokens);
    }
    
    public(package) fun withdraw_c_tokens<P, T>(
        reserve: &mut Bank<T>,
        c_tokens: u64,
    ): Balance<CToken<P, T>> {
        let c_balance: &mut Balance<CToken<P, T>> = reserve.fields.borrow_mut(LendingReserveKey<T> {});
        c_balance.split(c_tokens)
    }
    
    public fun add_c_token_field_<P, T>(
        fields: &mut Bag,
    ) {
        fields.add(LendingReserveKey<T> {}, LendingReserve<P, T> { c_tokens: balance::zero() })
    }
    
    public fun deposit_c_tokens_<P, T>(
        fields: &mut Bag,
        c_tokens: Balance<CToken<P, T>>
    ) {
        let c_balance: &mut Balance<CToken<P, T>> = fields.borrow_mut(LendingReserveKey<T> {});
        c_balance.join(c_tokens);
    }
    
    public fun withdraw_c_tokens_<P, T>(
        fields: &mut Bag,
        c_tokens: u64,
    ): Balance<CToken<P, T>> {
        let c_balance: &mut Balance<CToken<P, T>> = fields.borrow_mut(LendingReserveKey<T> {});
        c_balance.split(c_tokens)
    }

    public fun compute_lending_action_(
        reserve: u64,
        amount: u64,
        is_input: bool,
        lent: u64,
        liquidity_ratio_bps: u64,
        liquidity_buffer_bps: u64,
    ): LendingAction {
        if (is_input) {
            let liquidity_ratio = liquidity_ratio(reserve + amount, lent) as u64;

            if (liquidity_ratio > liquidity_ratio_bps + liquidity_buffer_bps) {
                return LendingAction::Lend(compute_lend(
                    reserve,
                        amount,
                        lent,
                        liquidity_ratio_bps,
                        liquidity_buffer_bps,
                ))
            } else {
                LendingAction::Ok
            }


        } else {
            assert!(reserve + lent > amount, 0);

            if (amount > reserve) {
                return LendingAction::Recall(compute_recall(
                    reserve,
                    amount,
                    lent,
                    liquidity_ratio_bps,
                    liquidity_buffer_bps,
                ))
            };

            let liquidity_ratio = liquidity_ratio(reserve - amount, lent) as u64;

            if (liquidity_ratio < liquidity_ratio_bps - liquidity_buffer_bps) {
                return LendingAction::Recall(compute_recall(
                    reserve,
                        amount,
                        lent,
                        liquidity_ratio_bps,
                        liquidity_buffer_bps,
                ))
            } else {
                LendingAction::Ok
            }
        }
    }
    
    public fun assert_liquidity_requirements<T>(
        self: &Bank<T>,
        reserve: u64,
        amount: u64,
        is_input: bool,
        lent: u64,
    ) {
        if (is_input) {
            let liquidity_ratio = liquidity_ratio(reserve + amount, lent) as u64;
            assert!(liquidity_ratio <= (self.liquidity_ratio_bps + self.liquidity_buffer_bps) as u64, 0);
        } else {
            assert!(reserve + lent > amount, 0);
            assert!(reserve > amount, 0);

            let liquidity_ratio = liquidity_ratio(reserve - amount, lent) as u64;

            assert!(liquidity_ratio >= (self.liquidity_ratio_bps - self.liquidity_buffer_bps) as u64, 0);
        }
    }

    fun compute_recall(
        reserve: u64,
        output: u64,
        lent: u64,
        liquidity_ratio_bps: u64,
        liquidity_buffer_bps: u64
    ): u64 {
        (
            (liquidity_ratio_bps + liquidity_buffer_bps) * (reserve + lent - output) + (output * 10_000) - (reserve * 10_000)
        ) / 10_000
    }
    
    fun compute_lend(
        reserve: u64,
        input: u64,
        lent: u64,
        liquidity_ratio_bps: u64,
        liquidity_buffer_bps: u64
    ): u64 {
        (reserve + input) - ((liquidity_ratio_bps + liquidity_buffer_bps) * (reserve + input + lent) / 10_000) 
    }

    public fun liquidity_ratio(
        liquid_reserve: u64,
        iliquid_reserve: u64,
    ): u16 {
        ((liquid_reserve * 10_000) / (liquid_reserve + iliquid_reserve)) as u16
    }

    public(package) fun funds_mut<T>(reserve: &mut Bank<T>): &mut Balance<T> {
        &mut reserve.reserve
    }
}