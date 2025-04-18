#[allow(lint(share_owned))]
module steamm::bank;

use std::ascii;
use std::option::{some, none};
use std::string;
use std::type_name::{get, TypeName};
use steamm::bank_math;
use steamm::registry::Registry;
use steamm::events::emit_event;
use steamm::global_admin::GlobalAdmin;
use steamm::utils::get_type_reflection;
use steamm::version::{Self, Version};
use sui::balance::{Self, Supply, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap, CoinMetadata};
use sui::transfer::share_object;
use suilend::decimal::{Self, Decimal};
use suilend::lending_market::{LendingMarket, ObligationOwnerCap};
use suilend::reserve::CToken;

// ===== Constants =====

const CURRENT_VERSION: u16 = 1;
const MIN_TOKEN_BLOCK_SIZE: u64 = 1_000_000_000;
// Minimum liquidity of btokens that cannot be withdrawn
const MINIMUM_LIQUIDITY: u64 = 1_000;
const BTOKEN_ICON_URL: vector<u8> = b"https://suilend-assets.s3.us-east-2.amazonaws.com/steamm/STEAMM+bToken.svg";

// ===== Errors =====

// bToken name must start with "B_" followed by underlying token name
const EBTokenTypeInvalid: u64 = 0;
// bToken decimals must be 9
const EInvalidBTokenDecimals: u64 = 1;
// bToken treasury must have zero supply when creating bank
const EBTokenSupplyMustBeZero: u64 = 2;
// Target utilisation + buffer cannot exceed 100%
const EUtilisationRangeAboveHundredPercent: u64 = 3;
// Target utilisation must be greater than buffer
const EUtilisationRangeBelowZeroPercent: u64 = 4;
// Bank already has lending initialized
const ELendingAlreadyActive: u64 = 5;
// Insufficient cTokens in reserve after redemption
const ECTokenRatioTooLow: u64 = 6;
// Lending must be initialized first
const ELendingNotActive: u64 = 7;
// No cToken ratio provided for funds_deployed calculation
const ENoCTokenRatioProvided: u64 = 8;
// Bank has insufficient funds for withdrawal
const EInsufficientBankFunds: u64 = 9;
// Input coin balance too low for requested operation
const EInsufficientCoinBalance: u64 = 10;
// Cannot deposit zero coins
const EEmptyCoinAmount: u64 = 11;
// Cannot burn empty bToken
const EEmptyBToken: u64 = 12;
// bToken balance less than amount to burn
const EInvalidBtokenBalance: u64 = 13;
// No bTokens available to burn after minimum liquidity check
const ENoBTokensToBurn: u64 = 14;
// No tokens available to withdraw after calculations
const ENoTokensToWithdraw: u64 = 15;
// First deposit must be greater than minimum liquidity
const EInitialDepositBelowMinimumLiquidity: u64 = 16;

// ===== Structs =====

public struct Bank<phantom P, phantom T, phantom BToken> has key, store {
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

// ====== Public Functions =====

/// Creates a new bank and shares it as a shared object on-chain.
/// The bank is initialized with zero balances and a new BToken supply.
///
/// # Arguments
///
/// * `meta_t` - Coin metadata for the underlying token T
/// * `meta_b` - Mutable coin metadata for the bank token BToken
/// * `btoken_treasury` - Treasury capability for minting BTokens
/// * `ctx` - Transaction context
///
/// # Returns
///
/// * `ID` - The object ID of the created bank
#[allow(lint(share_owned))]
public entry fun create_bank_and_share<P, T, BToken: drop>(
    registry: &mut Registry,
    meta_t: &CoinMetadata<T>,
    meta_b: &mut CoinMetadata<BToken>,
    btoken_treasury: TreasuryCap<BToken>,
    lending_market: &LendingMarket<P>,
    ctx: &mut TxContext,
): ID {
    let bank = create_bank<P, T, BToken>(
        registry,
        meta_t,
        meta_b,
        btoken_treasury,
        lending_market,
        ctx,
    );

    let bank_id = object::id(&bank);
    share_object(bank);
    bank_id
}

/// Initializes lending functionality for a bank by setting up utilization parameters and creating
/// an obligation in the lending market. This allows the bank to participate in lending activities.
///
/// # Arguments
///
/// * `bank` - The bank to initialize lending for
/// * `_` - Global admin capability for authorization
/// * `lending_market` - The lending market to create an obligation in
/// * `target_utilisation_bps` - Target utilization rate in basis points (100 = 1%)
/// * `utilisation_buffer_bps` - Buffer around target utilization in basis points
/// * `ctx` - Transaction context
///
/// # Panics
///
/// This function will panic if:
/// - Lending is already initialized for the bank
/// - Target utilization + buffer exceeds 100%
/// - Target utilization is less than the buffer
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
    assert!(target_utilisation_bps >= utilisation_buffer_bps, EUtilisationRangeBelowZeroPercent);

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

/// Mints bank tokens (BTokens) in exchange for deposited coins. The amount of BTokens minted
/// is calculated based on the current exchange rate between coins and BTokens, which takes into
/// account accumulated interest.
///
/// # Arguments
///
/// * `bank` - The bank to mint BTokens from
/// * `lending_market` - The lending market the bank participates in
/// * `coins` - The coins to deposit in exchange for BTokens
/// * `coin_amount` - Amount of coins to deposit
/// * `clock` - Clock for time-based calculations
/// * `ctx` - Transaction context
///
/// # Returns
///
/// `Coin<BToken>`: The newly minted BTokens
///
/// # Panics
///
/// This function will panic if:
/// - The bank version is not current
/// - The coin amount exceeds the available balance
public fun mint_btokens<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    lending_market: &mut LendingMarket<P>,
    coin_t: &mut Coin<T>,
    coin_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<BToken> {
    mint_btoken(bank, lending_market, coin_t, coin_amount, clock, ctx)
}

/// Burns bank tokens (BTokens) to withdraw the underlying tokens from the bank.
/// The amount of underlying tokens received depends on the current exchange rate
/// between BTokens and underlying tokens.
///
/// # Arguments
/// * `bank` - The bank to withdraw from
/// * `lending_market` - The lending market associated with the bank
/// * `btokens` - The BTokens to burn
/// * `btoken_amount` - Amount of BTokens to burn
/// * `clock` - Clock for timing
/// * `ctx` - Transaction context
///
/// # Returns
/// * `Coin<T>` - The withdrawn underlying tokens
///
/// # Panics
/// * If the bank version is not current
/// * If there are insufficient funds in the bank to fulfill the withdrawal
/// * If the withdrawal amount exceeds the bank's available balance
public fun burn_btoken<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    btokens: &mut Coin<BToken>,
    mut btoken_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<T> {
    bank.version.assert_version_and_upgrade(CURRENT_VERSION);

    if (btoken_amount == 0) {
        return coin::zero(ctx)
    };
    
    assert!(btokens.value() != 0, EEmptyBToken);
    assert!(btokens.value() >= btoken_amount, EInvalidBtokenBalance);

    let remaining_tokens = bank.btoken_supply.supply_value() - btoken_amount;
    if (remaining_tokens < MINIMUM_LIQUIDITY) {
        let delta = MINIMUM_LIQUIDITY - remaining_tokens;
        btoken_amount = btoken_amount - delta
    };

    assert!(btoken_amount > 0, ENoBTokensToBurn);

    let btoken_input = btokens.split(btoken_amount, ctx);
    let mut tokens_to_withdraw = bank.from_btokens(lending_market, btoken_amount, clock);

    bank.btoken_supply.decrease_supply(btoken_input.into_balance());

    assert!(bank.funds_available.value() >= tokens_to_withdraw, EInsufficientBankFunds);

    // In the edge case where the bank utilisation is at 100%, the amount withdrawn from
    // suilend might be off by 1 due to rounding, in such case, the amount available
    // will be lower than the amount requested
    let max_available = bank.funds_available.value();
    assert!(max_available + 1 >= tokens_to_withdraw, EInsufficientBankFunds);

    tokens_to_withdraw = tokens_to_withdraw.min(max_available);
    assert!(tokens_to_withdraw > 0, ENoTokensToWithdraw);

    emit_event(BurnBTokenEvent {
        user: ctx.sender(),
        bank_id: object::id(bank),
        lending_market_id: object::id(lending_market),
        withdrawn_amount: tokens_to_withdraw,
        burned_amount: btoken_amount,
    });

    let funds = coin::from_balance(bank.funds_available.split(tokens_to_withdraw), ctx);

    emit_event(BankLiquidityEvent {
        bank_id: object::id(bank),
        funds_available: bank.funds_available.value(),
        funds_deployed: bank.funds_deployed_(lending_market).floor(),
    });

    funds
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

    let tokens_to_withdraw = bank.from_btokens(lending_market, btoken_amount, clock);
    if (bank.funds_available.value() < tokens_to_withdraw) {
        // TODO: consider adding a slack to the tokens_to_withdraw to handle rounding errs
        bank.prepare_for_pending_withdraw(lending_market, tokens_to_withdraw, clock, ctx);
    };

    bank.burn_btoken(lending_market, btokens, btoken_amount, clock, ctx)
}

/// Mints bTokens in exchange for deposited coins. The amount of BTokens minted
/// is calculated based on the current exchange rate between coins and BTokens, which takes into
/// account accumulated interest.
///
/// # Arguments
///
/// * `bank` - The bank to mint BTokens from
/// * `lending_market` - The lending market where the bank is registered
/// * `coin_input` - The coin to split funds from
/// * `coin_amount` - Amount of coins to deposit
/// * `clock` - Clock for timing
/// * `ctx` - Transaction context
///
/// # Returns
///
/// * `Coin<BToken>` - The newly minted BTokens
///
/// # Panics
///
/// * If the bank version is not current
/// * If attempting first deposit below minimum liquidity
/// * If the coin amount is zero for non-first deposit
/// * If the coin input has insufficient balance
public fun mint_btoken<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    coin_t: &mut Coin<T>,
    coin_amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<BToken> {
    bank.version.assert_version_and_upgrade(CURRENT_VERSION);
    
    if (bank.btoken_supply.supply_value() == 0) {
        assert!(coin_amount > MINIMUM_LIQUIDITY, EInitialDepositBelowMinimumLiquidity);
    } else {
        assert!(coin_amount > 0, EEmptyCoinAmount);
    };

    assert!(coin_t.value() >= coin_amount, EInsufficientCoinBalance);
    let coin_input = coin_t.split(coin_amount, ctx);
    let new_btokens = bank.to_btokens(lending_market, coin_amount, clock);

    emit_event(MintBTokenEvent {
        user: ctx.sender(),
        bank_id: object::id(bank),
        lending_market_id: object::id(lending_market),
        deposited_amount: coin_amount,
        minted_amount: new_btokens,
    });

    bank.funds_available.join(coin_input.into_balance());
    let btoken = coin::from_balance(bank.btoken_supply.increase_supply(new_btokens), ctx);

    emit_event(BankLiquidityEvent {
        bank_id: object::id(bank),
        funds_available: bank.funds_available.value(),
        funds_deployed: bank.funds_deployed_(lending_market).floor(),
    });

    btoken
}

/// Rebalances the bank's funds between available balance and deployed funds in the lending market
/// to maintain the target utilization rate within the specified buffer range.
///
/// If the effective utilization is below target - buffer, deploys additional funds to the lending market.
/// If the effective utilization is above target + buffer, recalls funds from the lending market.
/// Does nothing if utilization is within the target range or if lending is not initialized.
///
/// # Arguments
/// * `bank` - The bank to rebalance
/// * `lending_market` - The lending market where funds are deployed
/// * `clock` - Clock for timing
/// * `ctx` - Transaction context
///
/// # Panics
/// * If the bank version is not current
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

    let ctoken_ratio = bank.ctoken_ratio(lending_market, clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();
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

public fun compound_interest_if_any<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &mut LendingMarket<P>,
    clock: &Clock,
) {
    if (bank.lending.is_some()) {
        lending_market.compound_interest<P>(bank.reserve_array_index(), clock);
    }
}

public fun to_btokens<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    amount: u64,
    clock: &Clock,
): u64 {
    if (bank.lending.is_some()) {
        let ctoken_ratio = bank.ctoken_ratio(lending_market, clock);
        let (total_funds, btoken_supply) = bank.btoken_ratio(some(ctoken_ratio));
        // Divides by btoken ratio
        decimal::from(amount).mul(btoken_supply).div(total_funds).floor()
    } else { amount }
}

public fun from_btokens<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    btoken_amount: u64,
    clock: &Clock,
): u64 {
    if (bank.lending.is_some()) {
        let ctoken_ratio = bank.ctoken_ratio(lending_market, clock);
        let (total_funds, btoken_supply) = bank.btoken_ratio(some(ctoken_ratio));
        // Multiplies by btoken ratio
        decimal::from(btoken_amount).mul(total_funds).div(btoken_supply).floor()
    } else { btoken_amount }
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
    assert!(target_utilisation_bps >= utilisation_buffer_bps, EUtilisationRangeBelowZeroPercent);

    let lending = bank.lending.borrow_mut();

    lending.target_utilisation_bps = target_utilisation_bps;
    lending.utilisation_buffer_bps = utilisation_buffer_bps;
}

public fun set_min_token_block_size<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    _: &GlobalAdmin,
    min_token_block_size: u64,
) {
    bank.version.assert_version_and_upgrade(CURRENT_VERSION);
    bank.min_token_block_size = min_token_block_size;
}

entry fun migrate<P, T, BToken>(bank: &mut Bank<P, T, BToken>, _admin: &GlobalAdmin) {
    bank.version.migrate_(CURRENT_VERSION);
}

// ====== Package Functions =====

public(package) fun create_bank<P, T, BToken: drop>(
    registry: &mut Registry,
    meta_t: &CoinMetadata<T>,
    meta_b: &mut CoinMetadata<BToken>,
    btoken_treasury: TreasuryCap<BToken>,
    lending_market: &LendingMarket<P>,
    ctx: &mut TxContext,
): Bank<P, T, BToken> {
    assert!(btoken_treasury.total_supply() == 0, EBTokenSupplyMustBeZero);

    update_btoken_metadata(meta_t, meta_b, &btoken_treasury);

    let bank = Bank<P, T, BToken> {
        id: object::new(ctx),
        funds_available: balance::zero(),
        lending: none(),
        min_token_block_size: MIN_TOKEN_BLOCK_SIZE,
        btoken_supply: btoken_treasury.treasury_into_supply(),
        version: version::new(CURRENT_VERSION),
    };

    let event = NewBankEvent {
        bank_id: object::id(&bank),
        coin_type: get<T>(),
        btoken_type: get<BToken>(),
        lending_market_id: object::id(lending_market),
        lending_market_type: get<P>(),
    };
    
    registry.register_bank(
        event.bank_id,
        event.coin_type,
        event.btoken_type,
        event.lending_market_id,
        event.lending_market_type,
    );

    emit_event(event);

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
    let ctoken_ratio = bank.ctoken_ratio(lending_market, clock);

    let amount_to_recall = {
        let lending = bank.lending.borrow();

        bank_math::compute_recall_for_pending_withdraw(
            bank.funds_available.value(),
            withdraw_amount,
            bank.funds_deployed(some(ctoken_ratio)).floor(),
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

public(package) fun assert_btoken_type<T, BToken>() {
    let type_reflection_t = get_type_reflection<T>();
    let type_reflection_btoken = get_type_reflection<BToken>();

    let mut expected_btoken_type = string::utf8(b"B_");
    string::append(&mut expected_btoken_type, type_reflection_t);
    assert!(type_reflection_btoken == expected_btoken_type, EBTokenTypeInvalid);
}

public(package) fun total_funds<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    ctoken_ratio: Option<Decimal>,
): Decimal {
    let funds_deployed = bank.funds_deployed(ctoken_ratio);
    let total_funds = funds_deployed.add(decimal::from(bank.funds_available.value()));

    total_funds
}

public(package) fun funds_deployed<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    ctoken_ratio: Option<Decimal>,
): Decimal {
    // FundsDeployed =  cTokens * Total Supply of Funds / cToken Supply
    if (bank.lending.is_some()) {
        assert!(ctoken_ratio.is_some(), ENoCTokenRatioProvided);
        decimal::from(bank.lending.borrow().ctokens).mul(*ctoken_ratio.borrow())
    } else {
        decimal::from(0)
    }
}

fun funds_deployed_<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
): Decimal {
    // FundsDeployed =  cTokens * Total Supply of Funds / cToken Supply
    if (bank.lending.is_some()) {
        let lending = bank.lending.borrow();
        let reserves = lending_market.reserves();
        let reserve = reserves.borrow(lending.reserve_array_index);
        let ctoken_ratio = reserve.ctoken_ratio();
        decimal::from(bank.lending.borrow().ctokens).mul(ctoken_ratio)
    } else {
        decimal::from(0)
    }
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

    let reserves = lending_market.reserves();
    let reserve = reserves.borrow(lending.reserve_array_index);
    let ctoken_ratio = reserve.ctoken_ratio();

    emit_event(BankLiquidityEvent {
        bank_id: object::id(bank),
        funds_available: bank.funds_available.value(),
        funds_deployed: bank.funds_deployed(some(ctoken_ratio)).floor(),
    });

    emit_event(DeployEvent {
        bank_id: object::id(bank),
        lending_market_id: object::id(lending_market),
        deployed_amount: amount_to_deploy,
        ctokens_minted: ctoken_amount,
    });
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

    let coin_recalled = lending_market.redeem_ctokens_and_withdraw_liquidity(
        bank.lending.borrow().reserve_array_index,
        clock,
        ctokens,
        none(), // rate_limiter_exemption
        ctx,
    );

    let recalled_amount = coin_recalled.value();

    let lending = bank.lending.borrow_mut();
    lending.ctokens = lending.ctokens - ctoken_amount;

    bank.funds_available.join(coin_recalled.into_balance());

    let reserves = lending_market.reserves();
    let reserve = reserves.borrow(lending.reserve_array_index);
    let ctoken_ratio = reserve.ctoken_ratio();

    // Note: the amount of funds deployed is different from the previous assertion
    assert!(
        decimal::from(lending.ctokens).mul(ctoken_ratio).floor() >= bank.funds_deployed(some(ctoken_ratio)).floor(),
        ECTokenRatioTooLow,
    );

    emit_event(BankLiquidityEvent {
        bank_id: object::id(bank),
        funds_available: bank.funds_available.value(),
        funds_deployed: bank.funds_deployed(some(ctoken_ratio)).floor(),
    });
    
    emit_event(RecallEvent {
        bank_id: object::id(bank),
        lending_market_id: object::id(lending_market),
        recalled_amount: recalled_amount,
        ctokens_burned: ctoken_amount,
    });
}

public(package) fun ctoken_ratio<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    clock: &Clock,
): Decimal {
    let reserves = lending_market.reserves();
    let reserve = reserves.borrow(bank.lending.borrow().reserve_array_index);
    reserve.simulated_ctoken_ratio(clock)
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
    ctoken_ratio: Option<Decimal>
): (Decimal, Decimal) {
    // this branch is only used once -- when the bank is
    // first initialized and has zero deposits
    if (bank.btoken_supply.supply_value() == 0) {
        (decimal::from(1), decimal::from(1))
    } else {
        (bank.total_funds(ctoken_ratio), decimal::from(bank.btoken_supply.supply_value()))
    }
}

public(package) fun get_btoken_ratio<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    clock: &Clock,
): (Decimal, Decimal) {
    if (bank.lending.is_some()) {
        let ctoken_ratio = bank.ctoken_ratio(lending_market, clock);
        let (total_funds, btoken_supply) = bank.btoken_ratio(some(ctoken_ratio));
        (total_funds, btoken_supply)
    } else {
        (decimal::from(1), decimal::from(1))
    }
}

fun update_btoken_metadata<T, BToken: drop>(
    meta_a: &CoinMetadata<T>,
    meta_btoken: &mut CoinMetadata<BToken>,
    treasury_btoken: &TreasuryCap<BToken>,
) {
    assert_btoken_type<T, BToken>();
    assert!(meta_btoken.get_decimals() == 9, EInvalidBTokenDecimals);

    // Construct and set the LP token name
    let mut btoken_name = string::utf8(b"bToken ");
    btoken_name.append(meta_a.get_symbol().to_string());
    treasury_btoken.update_name(meta_btoken, btoken_name);

    // Construct and set the LP token symbol
    let mut btoken_symbol = ascii::string(b"b");
    btoken_symbol.append(meta_a.get_symbol());
    treasury_btoken.update_symbol(meta_btoken, btoken_symbol);

    // Set the description
    treasury_btoken.update_description(meta_btoken, string::utf8(b"Steamm bToken"));

    // Set the icon URL
    treasury_btoken.update_icon_url(meta_btoken, ascii::string(BTOKEN_ICON_URL));
}

// ====== View Functions =====

public fun needs_rebalance<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    clock: &Clock,
): NeedsRebalance {
    if (bank.lending.is_none()) {
        return NeedsRebalance { needs_rebalance: false }
    };

    let ctoken_ratio = bank.ctoken_ratio(lending_market, clock);
    let funds_deployed = bank.funds_deployed(some(ctoken_ratio)).floor();

    let effective_utilisation_bps = bank.effective_utilisation_bps(funds_deployed);
    let target_utilisation_bps = bank.target_utilisation_bps_unchecked();
    let buffer_bps = bank.utilisation_buffer_bps_unchecked();

    let needs_rebalance = if (
        effective_utilisation_bps <= target_utilisation_bps + buffer_bps && effective_utilisation_bps >= target_utilisation_bps - buffer_bps
    ) { false } else { true };

    NeedsRebalance { needs_rebalance }
}

public fun lending<P, T, BToken>(bank: &Bank<P, T, BToken>): &Option<Lending<P>> { &bank.lending }

public(package) fun effective_utilisation_bps<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    funds_deployed: u64,
): u64 {
    bank_math::compute_utilisation_bps(
        bank.funds_available.value(),
        funds_deployed,
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

public fun funds_available<P, T, BToken>(bank: &Bank<P, T, BToken>): &Balance<T> {
    &bank.funds_available
}

public fun target_utilisation_bps_unchecked<P, T, BToken>(bank: &Bank<P, T, BToken>): u64 {
    bank.lending.borrow().target_utilisation_bps as u64
}

public fun utilisation_buffer_bps_unchecked<P, T, BToken>(bank: &Bank<P, T, BToken>): u64 {
    bank.lending.borrow().utilisation_buffer_bps as u64
}

public fun reserve_array_index<P, T, BToken>(bank: &Bank<P, T, BToken>): u64 {
    bank.lending.borrow().reserve_array_index
}

public fun minimum_liquidity(): u64 { MINIMUM_LIQUIDITY }

// ===== Events =====

public struct NewBankEvent has copy, drop, store {
    bank_id: ID,
    coin_type: TypeName,
    btoken_type: TypeName,
    lending_market_id: ID,
    lending_market_type: TypeName,
}

public struct MintBTokenEvent has copy, drop, store {
    user: address,
    bank_id: ID,
    lending_market_id: ID,
    deposited_amount: u64,
    minted_amount: u64,
}

public struct BurnBTokenEvent has copy, drop, store {
    user: address,
    bank_id: ID,
    lending_market_id: ID,
    withdrawn_amount: u64,
    burned_amount: u64,
}

public struct DeployEvent has copy, drop, store {
    bank_id: ID,
    lending_market_id: ID,
    deployed_amount: u64,
    ctokens_minted: u64,
}

public struct RecallEvent has copy, drop, store {
    bank_id: ID,
    lending_market_id: ID,
    recalled_amount: u64,
    ctokens_burned: u64,
}

public struct BankLiquidityEvent has copy, drop, store {
    bank_id: ID,
    funds_available: u64,
    funds_deployed: u64,
}


public struct NeedsRebalance has copy, drop, store {
    needs_rebalance: bool,
}

// ===== Test-Only Functions =====

#[test_only]
public fun new_for_testing<P, T, BToken: drop>(
    ctx: &mut TxContext,
): Bank<P, T, BToken> {
    let btoken_treasury = coin::create_treasury_cap_for_testing(ctx);

    let bank = Bank<P, T, BToken> {
        id: object::new(ctx),
        funds_available: balance::zero(),
        lending: none(),
        min_token_block_size: MIN_TOKEN_BLOCK_SIZE,
        btoken_supply: btoken_treasury.treasury_into_supply(),
        version: version::new(CURRENT_VERSION),
    };

    bank
}

#[test_only]
public fun mock_min_token_block_size<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    amount: u64,
) {
    bank.min_token_block_size = amount;
}

#[test_only]
public(package) fun funds_available_for_testing<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
): &mut Balance<T> {
    &mut bank.funds_available
}

#[test_only]
public(package) fun btoken_supply_for_testing<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
): &mut Supply<BToken> {
    &mut bank.btoken_supply
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
public(package) fun withdraw_for_testing<P, T, BToken>(
    bank: &mut Bank<P, T, BToken>,
    amount: u64,
): Balance<T> {
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

    let funds_deployed = bank.funds_deployed(some(bank.ctoken_ratio(lending_market, clock))).floor();

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

    let funds_deployed = bank.funds_deployed(some(bank.ctoken_ratio(lending_market, clock))).floor();
    let amount = bank.from_btokens(lending_market, btoken_amount, clock);

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

#[test_only]
public fun needs_rebalance_(needs_rebalance: NeedsRebalance): bool { needs_rebalance.needs_rebalance }