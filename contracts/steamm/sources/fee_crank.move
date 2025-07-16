/// This module was created to avoid dependencies between the pool and bank modules,
/// keeping the current design flexible. By doing so, we reserve the option to make
/// the pool module depend on the bank module or vice versa in the future, without
/// forcing said decision at this point.
module steamm::fee_crank;

use steamm::pool::Pool;
use steamm::bank::Bank;

public fun crank_fees<P, A, B, Quoter: store, LpType: drop, bA, bB>(
    pool: &mut Pool<bA, bB, Quoter, LpType>,
    bank_a: &mut Bank<P, A, bA>,
    bank_b: &mut Bank<P, B, bB>,
) {
    let (fees_a, fees_b) = pool.collect_protocol_fees_();

    bank_a.move_fees(fees_a);
    bank_b.move_fees(fees_b);
}