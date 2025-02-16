module steamm_scripts::bank_script;

use steamm_scripts::script_events::emit_event;

use sui::clock::Clock;
use steamm::bank::Bank;
use suilend::lending_market::{LendingMarket};

public fun needs_rebalance<P, T, BToken>(
    bank: &Bank<P, T, BToken>,
    lending_market: &LendingMarket<P>,
    clock: &Clock,
) {
    let needs_rebalance = bank.needs_rebalance(lending_market, clock);

    emit_event(needs_rebalance);
}