module slamm::pool {
    use sui::balance::{Self, Balance, Supply};
    use sui::coin::{Self, Coin};
    use slamm::events::emit_event;
    use slamm::math::{safe_mul_div_u64};
    use slamm::fees::{Self, Fees};
    use slamm::registry::{Registry};
    use sui::tx_context::sender;

    public use fun slamm::cpmm::deposit_liquidity as Pool.cpmm_deposit;
    public use fun slamm::cpmm::redeem_liquidity as Pool.cpmm_redeem;
    public use fun slamm::cpmm::swap as Pool.cpmm_swap;
    public use fun slamm::cpmm::quote_swap as Pool.cpmm_quote_swap;
    public use fun slamm::cpmm::quote_deposit as Pool.cpmm_quote_deposit;
    public use fun slamm::cpmm::quote_redeem as Pool.cpmm_quote_redeem;
    public use fun slamm::cpmm::k as Pool.cpmm_k;
    
    public use fun swap_amount_in as SwapResult.amount_in;
    public use fun swap_amount_out as SwapResult.amount_out;
    public use fun swap_net_amount_in as SwapResult.net_amount_in;
    public use fun swap_protocol_fees as SwapResult.protocol_fees;
    public use fun swap_admin_fees as SwapResult.admin_fees;
    public use fun swap_a2b as SwapResult.a2b;

    // Consts
    const SWAP_FEE_NUMERATOR: u64 = 200;
    const SWAP_FEE_DENOMINATOR: u64 = 10_000;

    // Error codes
    const EFeeAbove100Percent: u64 = 0;

    public struct LP<phantom A, phantom B, phantom Hook: drop> has copy, drop {}

    public struct PoolCap<phantom A, phantom B, phantom Hook: drop> {
        id: UID,
        pool_id: ID,
    }

    public struct Pool<phantom A, phantom B, phantom Hook: drop, State: store> has key, store {
        id: UID,
        inner: State,
        reserve_a: Balance<A>,
        reserve_b: Balance<B>,
        lp_supply: Supply<LP<A, B, Hook>>,
        protocol_fees: Fees<A, B>,
        admin_fees: Fees<A, B>,
    }
    
    // ===== Public Methods =====

    public(package) fun new<A, B, Hook: drop, State: store>(
        _witness: Hook,
        registry: &mut Registry,
        swap_fee_bps: u64,
        inner: State,
        ctx: &mut TxContext,
    ): (Pool<A, B, Hook, State>, PoolCap<A, B, Hook>) {
        assert!(swap_fee_bps < SWAP_FEE_DENOMINATOR, EFeeAbove100Percent);

        let lp_supply = balance::create_supply(LP<A, B, Hook>{});

        let pool = Pool {
            id: object::new(ctx),
            inner,
            reserve_a: balance::zero(),
            reserve_b: balance::zero(),
            protocol_fees: fees::new(SWAP_FEE_NUMERATOR, SWAP_FEE_DENOMINATOR),
            admin_fees: fees::new(swap_fee_bps, SWAP_FEE_DENOMINATOR),
            lp_supply,
        };

        registry.add_amm(&pool);

        // Create pool cap
        let pool_cap = PoolCap {
            id: object::new(ctx),
            pool_id: pool.id.uid_to_inner(),
        };


        // Emit event
        emit_event(
            InitPoolEvent {
                creator: sender(ctx),
                pool_id: object::id(&pool),
            }
        );

        (pool, pool_cap)
    }

    public fun swap<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _witness: Hook,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        amount_in: u64,
        amount_out: u64,
        a2b: bool,
        ctx: &mut TxContext,
    ): SwapResult {
        let (protocol_fee_num, protocol_fee_denom) = self.protocol_fees.fee_ratio();
        let (admin_fee_num, admin_fee_denom) = self.admin_fees.fee_ratio();
        
        let protocol_fees = safe_mul_div_u64(amount_in, protocol_fee_num, protocol_fee_denom);
        let admin_fees = safe_mul_div_u64(amount_in, admin_fee_num, admin_fee_denom);

        if (a2b) {
            let mut balance_in = coin_a.balance_mut().split(amount_in);

            // Transfers protocol fees in
            self.protocol_fees.deposit_a(balance_in.split(protocol_fees));
            
            // Transfers protocol fees in
            self.admin_fees.deposit_a(balance_in.split(admin_fees));

            // Transfers amount in
            self.reserve_a.join(balance_in);
        
            // Transfers amount out
            coin_b.balance_mut().join(self.reserve_b.split(amount_out));
        } else {
            let mut balance_in = coin_b.balance_mut().split(amount_in);

            // Transfers protocol fees in
            self.protocol_fees.deposit_b(balance_in.split(protocol_fees));
            
            // Transfers protocol fees in
            self.admin_fees.deposit_b(balance_in.split(admin_fees));

            // Transfers amount in
            self.reserve_b.join(balance_in);
        
            // Transfers amount out
            coin_a.balance_mut().join(self.reserve_a.split(amount_out));
        };

        // Emit event
        emit_event(
            SwapEvent {
                user: sender(ctx),
                pool_id: object::id(self),
                amount_in: amount_in,
                amount_out: amount_out,
                protocol_fees: protocol_fees,
                admin_fees: admin_fees,
                a2b,
            }
        );

        SwapResult {
            amount_in,
            amount_out,
            protocol_fees,
            admin_fees,
            a2b,
        }
    }

    public fun deposit_liquidity<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _witness: Hook,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        lp_to_mint: u64,
        ctx:  &mut TxContext,
    ): (Coin<LP<A, B, Hook>>, DepositResult) {
        let deposit_a = balance_a.value();
        let deposit_b = balance_b.value();
        
        // 1. Add liquidity to pool
        self.reserve_a.join(balance_a);
        self.reserve_b.join(balance_b);

        // 2. Mint LP Tokens
        let lp_coins = coin::from_balance(
            self.lp_supply.increase_supply(lp_to_mint),
            ctx
        );

        // 4. Emit event
        emit_event(
            DepositLiquidityEvent {
                user: sender(ctx),
                pool_id: object::id(self),
                lp_minted: lp_to_mint,
                a_deposited: deposit_a,
                b_deposited: deposit_b,
            }
        );

        (lp_coins, DepositResult {
            deposit_a,
            deposit_b,
            mint_lp: lp_to_mint,
        })
    }
    
    public fun redeem_liquidity<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
        _witness: Hook,
        withdraw_a: u64,
        withdraw_b: u64,
        lp_tokens: Coin<LP<A, B, Hook>>,
        ctx:  &mut TxContext,
    ): (Coin<A>, Coin<B>, RedeemResult) {
        let lp_burn = lp_tokens.value();

        // 1. Burn LP Tokens
        self.lp_supply.decrease_supply(
            lp_tokens.into_balance()
        );

        // 2. Prepare tokens to send
        let base_tokens = coin::from_balance(
            self.reserve_a.split(withdraw_a),
            ctx,
        );
        let quote_tokens = coin::from_balance(
            self.reserve_b.split(withdraw_b),
            ctx,
        );

        // 3. Confirm redemption
        // self.confirm_redeem(request); // TODO

        // 4. Emit events
        emit_event(
            RedeemLiquidityEvent {
                user: sender(ctx),
                pool_id: object::id(self),
                lp_burned: lp_burn,
                a_withdrawn: withdraw_a,
                b_withdrwan: withdraw_b,
            }
        );

        (base_tokens, quote_tokens, RedeemResult {
            withdraw_a,
            withdraw_b,
            burn_lp: lp_burn,
        })
    }

    public fun net_amount_in<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>, amount_in: u64): (u64, u64, u64) {
        let (protocol_fee_num, protocol_fee_denom) = self.protocol_fees.fee_ratio();
        let (admin_fee_num, admin_fee_denom) = self.admin_fees.fee_ratio();
        
        let protocol_fees = safe_mul_div_u64(amount_in, protocol_fee_num, protocol_fee_denom);
        let admin_fees = safe_mul_div_u64(amount_in, admin_fee_num, admin_fee_denom);
        let net_amount_in = amount_in - protocol_fees - admin_fees;

        (net_amount_in, protocol_fees, admin_fees)
    }

    // ===== View & Getters =====

    public fun reserves<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): (u64, u64) {
        (self.reserve_a.value(), self.reserve_b.value())
    }
    
    public fun protocol_fees<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): &Fees<A, B> {
        &self.protocol_fees
    }
    
    public fun admin_fees<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): &Fees<A, B> {
        &self.admin_fees
    }
    
    public fun lp_supply_val<A, B, Hook: drop, State: store>(self: &Pool<A, B, Hook, State>): u64 {
        self.lp_supply.supply_value()
    }

    // ===== Package functions =====

    public(package) fun inner<A, B, Hook: drop, State: store>(
        pool: &Pool<A, B, Hook, State>,
    ): &State {
        &pool.inner
    }
    
    public(package) fun inner_mut<A, B, Hook: drop, State: store>(
        self: &mut Pool<A, B, Hook, State>,
    ): &mut State {
        &mut self.inner
    }

    // ===== Results =====

    public struct SwapResult has drop {
        amount_in: u64,
        amount_out: u64,
        protocol_fees: u64,
        admin_fees: u64,
        a2b: bool,
    }
    
    public fun swap_amount_in(response: &SwapResult): u64 { response.amount_in }
    public fun swap_amount_out(response: &SwapResult): u64 { response.amount_out }
    public fun swap_net_amount_in(response: &SwapResult): u64 { response.amount_in - response.protocol_fees - response.admin_fees}
    public fun swap_protocol_fees(response: &SwapResult): u64 { response.protocol_fees }
    public fun swap_admin_fees(response: &SwapResult): u64 { response.admin_fees }
    public fun swap_a2b(response: &SwapResult): bool { response.a2b }

    public struct DepositResult has drop {
        deposit_a: u64,
        deposit_b: u64,
        mint_lp: u64,
    }
    
    public struct RedeemResult has drop {
        withdraw_a: u64,
        withdraw_b: u64,
        burn_lp: u64
    }

    public fun deposit_a(self: &DepositResult): u64 { self.deposit_a }
    public fun deposit_b(self: &DepositResult): u64 { self.deposit_b }
    public fun mint_lp(self: &DepositResult): u64 { self.mint_lp }

    public fun withdraw_a(self: &RedeemResult): u64 { self.withdraw_a }
    public fun withdraw_b(self: &RedeemResult): u64 { self.withdraw_a }
    public fun burn_lp(self: &RedeemResult): u64 { self.burn_lp }
    
    // ===== Events =====

    public struct InitPoolEvent has copy, drop {
        creator: address,
        pool_id: ID,
    }
    
    public struct DepositLiquidityEvent has copy, drop {
        user: address,
        pool_id: ID,
        lp_minted: u64,
        a_deposited: u64,
        b_deposited: u64,
    }
    
    public struct RedeemLiquidityEvent has copy, drop {
        user: address,
        pool_id: ID,
        lp_burned: u64,
        a_withdrawn: u64,
        b_withdrwan: u64,
    }
    
    public struct SwapEvent has copy, drop {
        user: address,
        pool_id: ID,
        amount_in: u64,
        amount_out: u64,
        protocol_fees: u64,
        admin_fees: u64,
        a2b: bool,
    }
}
