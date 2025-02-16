#[allow(lint(share_owned, self_transfer))]
module lp_rewards::lp_rewards;

use suilend::reserve_config::create_reserve_config;
use suilend::lending_market::{Self, LendingMarket, LendingMarketOwnerCap};
use suilend::lending_market_registry::{Self, Registry};
use sui::clock::Clock;
use sui::coin::CoinMetadata;
use pyth::price_info::PriceInfoObject;

public struct LP_REWARDS has drop {}

public fun create_reserve<P, LpType>(
    lending_cap: &LendingMarketOwnerCap<P>,
    lending_market: &mut LendingMarket<P>,
    price_info: &PriceInfoObject,
    coin_metadata: &CoinMetadata<LpType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let reserve_config = create_reserve_config(
        0, // open_ltv_pct
        0, // close_ltv_pct
        0, // max_close_ltv_pct
        18446744073709551615, // borrow_weight_bps
        80000000000000000, // deposit_limit
        0, // borrow_limit
        300, // liquidation_bonus_bps
        300, // max_liquidation_bonus_bps
        500000000, // deposit_limit_usd
        0, //borrow_limit_usd
        30, // borrow_fee_bps
        2000, // spread_fee_bps
        199, // protocol_liquidation_fee_bps
        vector[0, 100], // interest_rate_utils
        vector[0, 0], // interest_rate_aprs
        true, // isolated,
        0, // open_attributed_borrow_limit_usd
        0, // close_attributed_borrow_limit_usd
        ctx,
    );

    lending_market::add_reserve<P, LpType>(
        lending_cap,
        lending_market,
        price_info,
        reserve_config,
        coin_metadata,
        clock,
        ctx,
    );
}

public fun create_lending_market(
    registry: &mut Registry,
    ctx: &mut TxContext,
) {
    let (owner_cap, lending_market) = lending_market_registry::create_lending_market<LP_REWARDS>(registry, ctx);

    transfer::public_transfer(owner_cap, ctx.sender());
    transfer::public_share_object(lending_market);
}