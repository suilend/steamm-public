#[allow(lint(share_owned))]
module steamm::bank;

use std::string;
use std::ascii;
use std::option::{none, some};
use steamm::bank_math;
use steamm::global_admin::GlobalAdmin;
use steamm::registry::Registry;
use steamm::version::{Self, Version};
use steamm::utils::get_type_reflection;
use sui::balance::{Self, Supply, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
use sui::transfer::share_object;
use sui::url;
use suilend::decimal::{Self, Decimal};
use suilend::lending_market::{LendingMarket, ObligationOwnerCap};
use suilend::reserve::CToken;

// ===== Constants =====

const CURRENT_VERSION: u16 = 1;
const MIN_TOKEN_BLOCK_SIZE: u64 = 1_000_000_000;
const BTOKEN_ICON_URL: vector<u8> = b"TODO";

// ===== Errors =====

const EBTokenTypeInvalid: u64 = 0;
const EInvalidBTokenDecimals: u64 = 1;
const EInvalidBTokenName: u64 = 2;
const EInvalidBTokenSymbol: u64 = 3;
const EInvalidBTokenDescription: u64 = 4;
const EInvalidBTokenUrl: u64 = 5;
const EBTokenSupplyMustBeZero: u64 = 6;
const EUtilisationRangeAboveHundredPercent: u64 = 7;
const EUtilisationRangeBelowHundredPercent: u64 = 8;
const ELendingAlreadyActive: u64 = 9;
const EInvalidCTokenRatio: u64 = 10;
const ECTokenRatioTooLow: u64 = 11;
const ELendingNotActive: u64 = 12;
const ECompoundedInterestNotUpdated: u64 = 13;
const EInsufficientBankFunds: u64 = 14;

public struct Bank<phantom P, phantom T, phantom BToken> has key {
    id: UID,
    funds_available: Balance<T>,
    lending: Option<Lending<P>>,
    min_token_block_size: u64,
    btoken_supply: Supply<BToken>,
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
public entry fun create_bank_and_share<P, T, BToken: drop>(
    btoken_treasury: TreasuryCap<BToken>,
    meta_b: &CoinMetadata<BToken>,
    meta_t: &CoinMetadata<T>,
    registry: &mut Registry,
    ctx: &mut TxContext
): ID {
    let bank = create_bank<P, T, BToken>(
        btoken_treasury,
        meta_b,
        meta_t,
        registry,
        ctx,
    );

    let bank_id = object::id(&bank);
    share_object(bank);
    bank_id
}

public fun init_lending<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    _: &GlobalAdmin,
    lending_market: &mut LendingMarket<P>,
    target_utilisation_bps: u16,
    utilisation_buffer_bps: u16,
    ctx: &mut TxContext,
) {
    bank.version.assert_version_and_upgrade(CURRENT_VERSION);
    assert!(bank.lending.is_none(), ELendingAlreadyActive);
    assert!(
        target_utilisation_bps + utilisation_buffer_bps <= 10_000,
        EUtilisationRangeAboveHundredPercent,
    );
    assert!(target_utilisation_bps >= utilisation_buffer_bps, EUtilisationRangeBelowHundredPercent);

    let obligation_cap = lending_market.create_obligation(ctx);
    let reserve_array_index = lending_market.reserve_array_index<P, T>();

    bank
        .lending
        .fill(Lending {
            ctokens: 0,
            target_utilisation_bps,
            utilisation_buffer_bps,
            reserve_array_index,
            obligation_cap,
        })
}

public fun mint_btokens<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    lending_market: &mut LendingMarket<P>,
    coins: &mut Coin<T>,
    coin_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<BToken> {
    bank.version.assert_version_and_upgrade(CURRENT_VERSION);
    bank.compound_interest_if_any(lending_market, clock);

    let coin_input = coins.split(coin_amount, ctx);
    let new_btokens = bank.to_btokens(lending_market, coin_amount, clock).floor();

    bank.funds_available.join(coin_input.into_balance());
    coin::from_balance(bank.btoken_supply.increase_supply(new_btokens), ctx)
}

fun to_btokens<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    amount: u64,
    clock: &Clock,
): Decimal {
    let (total_funds, btoken_supply) = bank.btoken_ratio(lending_market, clock);
    // Divides by btoken ratio
    decimal::from(amount).mul(btoken_supply).div(total_funds)
}

fun from_btokens<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    btoken_amount: u64,
    clock: &Clock,
): Decimal {
    let (total_funds, btoken_supply) = bank.btoken_ratio(lending_market, clock);
    // Multiplies by btoken ratio
    decimal::from(btoken_amount).mul(total_funds).div(btoken_supply)
}

public fun burn_btokens<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    lending_market: &mut LendingMarket<P>,
    btokens: &mut Coin<BToken>,
    btoken_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    bank.version.assert_version_and_upgrade(CURRENT_VERSION);
    bank.compound_interest_if_any(lending_market, clock);

    let btoken_input = btokens.split(btoken_amount, ctx);
    let tokens_to_withdraw = bank.from_btokens(lending_market, btoken_amount, clock).floor();

    bank.btoken_supply.decrease_supply(btoken_input.into_balance());

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

public fun rebalance<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
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
    let effective_utilisation_bps = bank_math::compute_utilisation_bps(
        bank.funds_available.value(),
        funds_deployed,
    );

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

public fun set_utilisation_bps<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    _: &GlobalAdmin,
    target_utilisation_bps: u16,
    utilisation_buffer_bps: u16,
) {
    bank.version.assert_version_and_upgrade(CURRENT_VERSION);
    assert!(bank.lending.is_some(), ELendingNotActive);
    assert!(
        target_utilisation_bps + utilisation_buffer_bps <= 10_000,
        EUtilisationRangeAboveHundredPercent,
    );
    assert!(target_utilisation_bps >= utilisation_buffer_bps, EUtilisationRangeBelowHundredPercent);

    let lending = bank.lending.borrow_mut();

    lending.target_utilisation_bps = target_utilisation_bps;
    lending.utilisation_buffer_bps = utilisation_buffer_bps;
}

entry fun migrate<P, T, BToken>(bank: &mut Bank<P, T, BToken>, _admin: &GlobalAdmin) {
    bank.version.migrate_(CURRENT_VERSION);
}

// ====== Package Functions =====

public(package) fun create_bank<P, T, BToken: drop>(
    btoken_treasury: TreasuryCap<BToken>,
    meta_b: &CoinMetadata<BToken>,
    meta_t: &CoinMetadata<T>,
    registry: &mut Registry,
    ctx: &mut TxContext
): Bank<P, T, BToken> {
    assert!(btoken_treasury.total_supply() == 0, EBTokenSupplyMustBeZero);

    validate_btoken_metadata(meta_t, meta_b);

    let bank = Bank<P, T, BToken> {
        id: object::new(ctx),
        funds_available: balance::zero(),
        lending: none(),
        min_token_block_size: MIN_TOKEN_BLOCK_SIZE,
        btoken_supply: btoken_treasury.treasury_into_supply(),
        version: version::new(CURRENT_VERSION),
    };

    registry.add_bank(&bank);

    bank
}

// Package is added to allow testing
public(package) fun prepare_for_pending_withdraw<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
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

fun deploy<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    lending_market: &mut LendingMarket<P>,
    amount_to_deploy: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let lending = bank.lending.borrow();

    if (amount_to_deploy < bank.min_token_block_size) {
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

fun recall<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
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

    assert!(
        ctoken_amount * bank.funds_deployed(lending_market, clock).floor() <= lending.ctokens * coin.value(),
        EInvalidCTokenRatio,
    );

    let lending = bank.lending.borrow_mut();
    lending.ctokens = lending.ctokens - ctoken_amount;

    bank.funds_available.join(coin.into_balance());

    let reserves = lending_market.reserves();
    let reserve = reserves.borrow(lending.reserve_array_index);
    let ctoken_ratio = reserve.ctoken_ratio();

    // Note: the amount of funds deployed is different from the previous assertion
    assert!(
        decimal::from(lending.ctokens).mul(ctoken_ratio).floor() >= bank.funds_deployed(lending_market, clock).floor(),
        ECTokenRatioTooLow,
    );
}

// Given how much tokens we want to withdraw from the lending market,
// how many ctokens do we need to burn
fun ctoken_amount<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    amount: u64,
): Decimal {
    let reserves = lending_market.reserves();
    let lending = bank.lending.borrow();
    let reserve = reserves.borrow(lending.reserve_array_index);
    let ctoken_ratio = reserve.ctoken_ratio();

    decimal::from(amount).div(ctoken_ratio)
}

fun btoken_ratio<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    clock: &Clock,
): (Decimal, Decimal) {
    // this branch is only used once -- when the bank is first initialized and has
    // zero deposits. after that, borrows and redemptions won't let the btokn supply fall
    // below MIN_AVAILABLE_AMOUNT - TODO: add MIN_AVAILABLE_AMOUNT
    if (bank.btoken_supply.supply_value() == 0) {
        (decimal::from(1), decimal::from(1))
    } else {
        (total_funds(bank, lending_market, clock), decimal::from(bank.btoken_supply.supply_value()))
    }
}

fun validate_btoken_metadata<T, BToken: drop>(
    meta_a: &CoinMetadata<T>,
    meta_lp: &CoinMetadata<BToken>,
) {
    assert_btoken_type<T, BToken>();
    assert!(meta_a.get_decimals() != 9, EInvalidBTokenDecimals);

    let mut btoken_name = string::utf8(b"bToken ");
    btoken_name.append(meta_a.get_symbol().to_string());

    assert!(meta_lp.get_name() == btoken_name, EInvalidBTokenName);

    let mut btoken_symbol = ascii::string(b"b");
    btoken_symbol.append(meta_a.get_symbol());

    assert!(meta_lp.get_symbol() == btoken_symbol, EInvalidBTokenSymbol);
    assert!(meta_lp.get_description() == string::utf8(b"Steamm LP Token"), EInvalidBTokenDescription);
    assert!(meta_lp.get_icon_url() == some(url::new_unsafe(ascii::string(BTOKEN_ICON_URL))), EInvalidBTokenUrl);
}

public(package) fun assert_btoken_type<T, BToken>() {
    let type_reflection_t = get_type_reflection<T>();
    let type_reflection_btoken = get_type_reflection<BToken>();

    let mut expected_btoken_type = string::utf8(b"B_");
    string::append(&mut expected_btoken_type, type_reflection_t);
    assert!(type_reflection_btoken == expected_btoken_type, EBTokenTypeInvalid);
}

public(package) fun total_funds<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    clock: &Clock,
): Decimal {
    let funds_deployed = bank.funds_deployed(lending_market, clock);
    let total_funds = funds_deployed.add(decimal::from(bank.funds_available.value()));

    total_funds
}

public(package) fun funds_deployed<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    clock: &Clock,
): Decimal {
    // FundsDeployed =  cTokens * Total Supply of Funds / cToken Supply
    if (bank.lending.is_some()) {
        let reserve = vector::borrow(lending_market.reserves(), bank.reserve_array_index());
        let interest_last_update_timestamp_s = reserve.interest_last_update_timestamp_s();

        assert!(
            interest_last_update_timestamp_s == clock.timestamp_ms() / 1000,
            ECompoundedInterestNotUpdated,
        );

        let ctoken_ratio = reserve.ctoken_ratio();

        decimal::from(bank.lending.borrow().ctokens).mul(ctoken_ratio)
    } else {
        decimal::from(0)
    }
}

public fun needs_rebalance<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    clock: &Clock,
): bool {
    if (bank.lending.is_none()) {
        return false
    };

    let effective_utilisation_bps = bank.effective_utilisation_bps(lending_market, clock);
    let target_utilisation_bps = bank.target_utilisation_bps_unchecked();
    let buffer_bps = bank.utilisation_buffer_bps_unchecked();

    if (
        effective_utilisation_bps <= target_utilisation_bps + buffer_bps && effective_utilisation_bps >= target_utilisation_bps - buffer_bps
    ) { false } else { true }
}

fun compound_interest_if_any<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &mut LendingMarket<P>,
    clock: &Clock,
) {
    if (bank.lending.is_some()) {
        lending_market.compound_interest<P, T>(bank.reserve_array_index(), clock);
    }
}

// ====== Getters Functions =====

public fun lending<P, T, BToken>(bank: &Bank<P, T, BToken>): &Option<Lending<P>> { &bank.lending }

public(package) fun effective_utilisation_bps<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    clock: &Clock,
): u64 {
    bank_math::compute_utilisation_bps(
        bank.funds_available.value(),
        bank.funds_deployed(lending_market, clock).floor(),
    )
}

public fun target_utilisation_bps<P, T, BToken>(bank: &Bank<P, T, BToken>): u64 {
    if (bank.lending.is_some()) {
        bank.target_utilisation_bps_unchecked()
    } else { 0 }
}

public fun utilisation_buffer_bps<P, T, BToken>(bank: &Bank<P, T, BToken>): u64 {
    if (bank.lending.is_some()) {
        bank.utilisation_buffer_bps_unchecked()
    } else { 0 }
}

public fun funds_available<P, T, BToken>(bank: &Bank<P, T, BToken>): &Balance<T> { &bank.funds_available }

public fun target_utilisation_bps_unchecked<P, T, BToken>(bank: &Bank<P, T, BToken>): u64 {
    bank.lending.borrow().target_utilisation_bps as u64
}

public fun utilisation_buffer_bps_unchecked<P, T, BToken>(bank: &Bank<P, T, BToken>): u64 {
    bank.lending.borrow().utilisation_buffer_bps as u64
}

public fun reserve_array_index<P, T, BToken>(bank: &Bank<P, T, BToken>): u64 {
    bank.lending.borrow().reserve_array_index
}

// ===== Test-Only Functions =====

#[test_only]
public(package) fun mock_min_token_block_size<P, T, BToken>(bank: &mut Bank<P, T, BToken>, amount: u64) {
    bank.min_token_block_size = amount;
}

#[test_only]
public(package) fun deposit_for_testing<P, T, BToken>(bank: &mut Bank<P, T, BToken>, amount: u64) {
    bank
        .funds_available
        .join(
            balance::create_for_testing(amount),
        );
}

#[test_only]
public(package) fun withdraw_for_testing<P, T, BToken>(bank: &mut Bank<P, T, BToken>, amount: u64): Balance<T> {
    bank
        .funds_available
        .split(
            amount,
        )
}

#[test_only]
public(package) fun set_utilisation_bps_for_testing<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    target_utilisation_bps: u16,
    utilisation_buffer_bps: u16,
) {
    bank.lending.borrow_mut().target_utilisation_bps = target_utilisation_bps;
    bank.lending.borrow_mut().utilisation_buffer_bps = utilisation_buffer_bps;
}

#[test_only]
public fun needs_rebalance_after_inflow<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    amount: u64,
    clock: &Clock,
): bool {
    if (bank.lending.is_none()) {
        return false
    };

    let funds_deployed = bank.funds_deployed(lending_market, clock).floor();

    let effective_utilisation_bps = bank_math::compute_utilisation_bps(
        bank.funds_available.value() + amount,
        funds_deployed,
    );
    let target_utilisation_bps = bank.target_utilisation_bps_unchecked();
    let buffer_bps = bank.utilisation_buffer_bps_unchecked();

    if (
        effective_utilisation_bps <= target_utilisation_bps + buffer_bps && effective_utilisation_bps >= target_utilisation_bps - buffer_bps
    ) { false } else { true }
}

#[test_only]
public fun needs_rebalance_after_outflow<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
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

    let effective_utilisation_bps = bank_math::compute_utilisation_bps(
        bank.funds_available.value() - amount,
        funds_deployed,
    );
    let target_utilisation_bps = bank.target_utilisation_bps_unchecked();
    let buffer_bps = bank.utilisation_buffer_bps_unchecked();

    if (
        effective_utilisation_bps <= target_utilisation_bps + buffer_bps && effective_utilisation_bps >= target_utilisation_bps - buffer_bps
    ) { false } else { true }
}
