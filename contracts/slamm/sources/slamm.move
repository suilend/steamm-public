module slamm::pool {
    use sui::balance::{Self, Balance, Supply};
    use sui::coin::{Self, Coin};
    use slamm::events::emit_event;
    use slamm::math::{safe_mul_div_u64};
    use slamm::fees::{Self, Fees};
    use sui::tx_context::sender;
    use std::type_name::{Self, TypeName};
    use sui::object_bag::{Self as ob, ObjectBag};

    const ESwapExceedsSlippage: u64 = 0;

    public use fun swap_request_amount_in as SwapRequest.amount_in;
    public use fun swap_request_net_amount_in as SwapRequest.net_amount_in;
    public use fun swap_request_min_amount_out as SwapRequest.min_amount_out;
    public use fun swap_request_protocol_fees as SwapRequest.protocol_fees;
    public use fun swap_request_admin_fees as SwapRequest.admin_fees;
    public use fun swap_request_a2b as SwapRequest.a2b;
    
    public use fun swap_response_amount_in as SwapResponse.amount_in;
    public use fun swap_response_net_amount_in as SwapResponse.net_amount_in;
    public use fun swap_response_protocol_fees as SwapResponse.protocol_fees;
    public use fun swap_response_admin_fees as SwapResponse.admin_fees;
    public use fun swap_response_a2b as SwapResponse.a2b;

    // Consts
    const SWAP_FEE_NUMERATOR: u64 = 200;
    const SWAP_FEE_DENOMINATOR: u64 = 10_000;

    // Error codes
    const EFeeAbove100Percent: u64 = 0;

    public struct LP<phantom A, phantom B, phantom W: drop> has copy, drop {}

    public struct PoolCap<phantom A, phantom B, phantom W: drop> {
        id: UID,
        pool_id: ID,
    }

    public struct Pool<phantom A, phantom B, phantom HookWit: drop, HookState: store> has key, store {
        id: UID,
        inner: HookState,
        reserve_a: Balance<A>,
        reserve_b: Balance<B>,
        lp_supply: Supply<LP<A, B, HookWit>>,
        protocol_fees: Fees<A, B>,
        admin_fees: Fees<A, B>,
    }
    
    // Note: We add both Balance<A> and Balance<B> to avoid splitting the type and therefore
    // allow for a unified swap interface
    public struct SwapRequest<phantom A, phantom B, phantom W: drop, phantom T: store> {
        amount_in: u64,
        min_amount_out: u64,
        protocol_fees: u64,
        admin_fees: u64,
        a2b: bool,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
    }

    public struct SwapResponse<phantom A, phantom B, phantom W: drop,  phantom T: store> has drop {
        amount_in: u64,
        amount_out: u64,
        protocol_fees: u64,
        admin_fees: u64,
        a2b: bool,
    }

    public fun swap_request_amount_in<A, B, HookWit: drop, T: store>(request: SwapRequest<A, B, HookWit, T>): u64 { request.amount_in }
    public fun swap_request_net_amount_in<A, B, HookWit: drop, T: store>(request: SwapRequest<A, B, HookWit, T>): u64 { request.amount_in - request.protocol_fees - request.admin_fees}
    public fun swap_request_min_amount_out<A, B, HookWit: drop, T: store>(request: SwapRequest<A, B, HookWit, T>): u64 { request.min_amount_out }
    public fun swap_request_protocol_fees<A, B, HookWit: drop, T: store>(request: SwapRequest<A, B, HookWit, T>): u64 { request.protocol_fees }
    public fun swap_request_admin_fees<A, B, HookWit: drop, T: store>(request: SwapRequest<A, B, HookWit, T>): u64 { request.admin_fees }
    public fun swap_request_a2b<A, B, HookWit: drop, T: store>(request: SwapRequest<A, B, HookWit, T>): bool { request.a2b }
    
    public fun swap_response_amount_in<A, B, HookWit: drop, T: store>(response: SwapResponse<A, B, HookWit, T>): u64 { response.amount_in }
    public fun swap_response_net_amount_in<A, B, HookWit: drop, T: store>(response: SwapResponse<A, B, HookWit, T>): u64 { response.amount_in - response.protocol_fees - response.admin_fees}
    public fun swap_response_protocol_fees<A, B, HookWit: drop, T: store>(response: SwapResponse<A, B, HookWit, T>): u64 { response.protocol_fees }
    public fun swap_response_admin_fees<A, B, HookWit: drop, T: store>(response: SwapResponse<A, B, HookWit, T>): u64 { response.admin_fees }
    public fun swap_response_a2b<A, B, HookWit: drop, T: store>(response: SwapResponse<A, B, HookWit, T>): bool { response.a2b }

    public struct DepositResponse has drop {
        deposit_a: u64,
        deposit_b: u64,
        mint_lp: u64,
    }
    
    public struct RedeemResponse has drop {
        withdraw_a: u64,
        withdraw_b: u64,
        burn_lp: u64
    }

    // public fun deposit_a(self: &DepositResult): u64 { self.deposit_a }
    // public fun deposit_b(self: &DepositResult): u64 { self.deposit_b }
    // public fun mint_lp(self: &DepositResult): u64 { self.mint_lp }

    // public fun withdraw_a(self: &RedeemResult): u64 { self.withdraw_a }
    // public fun withdraw_b(self: &RedeemResult): u64 { self.withdraw_a }
    // public fun burn_lp(self: &RedeemResult): u64 { self.burn_lp }
    
    // ===== Public Methods =====

    // Note: We add the balance to the request to avoid mutating the reserve values
    // which must be kept intact before the swap quotation logic is executed.
    public fun swap_request<A, B, HookWit: drop, T: store>(
        self: &mut Pool<A, B, HookWit, T>,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        amount_in: u64,
        min_amount_out: u64,
        a2b: bool,
    ): (SwapRequest<A, B, HookWit, T>) {
        let (protocol_fee_num, protocol_fee_denom) = self.protocol_fees.fee_ratio();
        let (admin_fee_num, admin_fee_denom) = self.admin_fees.fee_ratio();
        
        let protocol_fees = safe_mul_div_u64(amount_in, protocol_fee_num, protocol_fee_denom);
        let admin_fees = safe_mul_div_u64(amount_in, admin_fee_num, admin_fee_denom);

        let request = SwapRequest {
            amount_in,
            min_amount_out,
            protocol_fees,
            admin_fees,
            a2b: true,
            balance_a: balance::zero(),
            balance_b: balance::zero(),
        };

        if (a2b) {
            let balance_in = coin_a.balance_mut().split(amount_in);

            // Transfers protocol fees in
            self.protocol_fees.deposit_a(balance_in.split(protocol_fees));
            
            // Transfers protocol fees in
            self.admin_fees.deposit_a(balance_in.split(admin_fees));

            // Add amount in to request
            request.balance_a.join(balance_in);
        } else {
            let balance_in = coin_b.balance_mut().split(amount_in);

            // Transfers protocol fees in
            self.protocol_fees.deposit_b(balance_in.split(protocol_fees));
            
            // Transfers protocol fees in
            self.admin_fees.deposit_b(balance_in.split(admin_fees));

            // Transfers amount in
            request.balance_b.join(balance_in);
        };

        request
    }

    // only can be called by hook module. destroys SwapRequest, makes SwapResponse
    public fun swap<A, B, HookWit: drop, T: store>(
        self: &mut Pool<A, B, HookWit, T>,
        _witness: HookWit,
        coin_a: &mut Coin<A>,
        coin_b: &mut Coin<B>,
        amount_out: u64,
        request: SwapRequest<A, B, HookWit, T>,
        ctx: &mut TxContext,
    ): SwapResponse<A, B, HookWit, T> {
        let SwapRequest {
            amount_in,
            min_amount_out,
            protocol_fees,
            admin_fees,
            a2b,
            balance_a,
            balance_b,
        } = request;

        assert!(a2b == true, 0);
        assert!(amount_out < min_amount_out, ESwapExceedsSlippage);
        

        let response = SwapResponse {
            amount_in,
            amount_out,
            protocol_fees,
            admin_fees,
            a2b,
        };

        if (a2b) {
            assert!(balance_a.value() == amount_in, 0);
            balance_b.destroy_zero();

            // Transfers amount in
            self.reserve_a.join(balance_a);
        
            // Transfers amount out
            coin_b.balance_mut().join(self.reserve_b.split(amount_out));
        } else {
            assert!(balance_b.value() == amount_in, 0);
            balance_a.destroy_zero();

            // Transfers amount in
            self.reserve_b.join(balance_b);
        
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

        response
    }

    public(package) fun new<A, B, W: drop, T: store>(
        _witness: W,
        swap_fee_bps: u64,
        inner: T,
        ctx: &mut TxContext,
    ): (Pool<A, B, W, T>, PoolCap<A, B, W>) {
        assert!(swap_fee_bps < SWAP_FEE_DENOMINATOR, EFeeAbove100Percent);

        let lp_supply = balance::create_supply(LP<A, B, W>{});

        let pool = Pool {
            id: object::new(ctx),
            inner,
            reserve_a: balance::zero(),
            reserve_b: balance::zero(),
            protocol_fees: fees::new(SWAP_FEE_NUMERATOR, SWAP_FEE_DENOMINATOR),
            admin_fees: fees::new(swap_fee_bps, SWAP_FEE_DENOMINATOR),
            lp_supply,
        };

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
    
    public(package) fun inner<A, B, W: drop, T: store>(
        pool: &Pool<A, B, W, T>,
    ): &T {
        &pool.inner
    }
    
    public(package) fun inner_mut<A, B, W: drop, T: store>(
        self: &mut Pool<A, B, W, T>,
    ): &mut T {
        &mut self.inner
    }

    public fun deposit_liquidity<A, B, HookWit: drop, T: store>(
        self: &mut Pool<A, B, HookWit, T>,
        _witness: HookWit,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        lp_to_mint: u64,
        ctx:  &mut TxContext,
    ): (Coin<LP<A, B, HookWit>>, DepositResponse) {
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

        // 3. Confirm deposit
        // self.confirm_deposit(request); // TODO

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

        (lp_coins, DepositResponse {
            deposit_a,
            deposit_b,
            mint_lp: lp_to_mint,
        })
    }
    
    public fun redeem_liquidity<A, B, HookWit: drop, T: store>(
        self: &mut Pool<A, B, HookWit, T>,
        _witness: HookWit,
        withdraw_a: u64,
        withdraw_b: u64,
        lp_tokens: Coin<LP<A, B, HookWit>>,
        ctx:  &mut TxContext,
    ): (Coin<A>, Coin<B>, RedeemResponse) {
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

        (base_tokens, quote_tokens, RedeemResponse {
            withdraw_a,
            withdraw_b,
            burn_lp: lp_burn,
        })
    }

    public fun net_amount_in<A, B, W: drop, T: store>(self: &Pool<A, B, W, T>, amount_in: u64): (u64, u64, u64) {
        let (protocol_fee_num, protocol_fee_denom) = self.protocol_fees.fee_ratio();
        let (admin_fee_num, admin_fee_denom) = self.admin_fees.fee_ratio();
        
        let protocol_fees = safe_mul_div_u64(amount_in, protocol_fee_num, protocol_fee_denom);
        let admin_fees = safe_mul_div_u64(amount_in, admin_fee_num, admin_fee_denom);
        let net_amount_in = amount_in - protocol_fees - admin_fees;

        (net_amount_in, protocol_fees, admin_fees)
    }

    // ===== View & Getters =====

    public fun reserves<A, B, W: drop, T: store>(self: &Pool<A, B, W, T>): (u64, u64) {
        (self.reserve_a.value(), self.reserve_b.value())
    }
    
    public fun protocol_fees<A, B, W: drop, T: store>(self: &Pool<A, B, W, T>): &Fees<A, B> {
        &self.protocol_fees
    }
    
    public fun admin_fees<A, B, W: drop, T: store>(self: &Pool<A, B, W, T>): &Fees<A, B> {
        &self.admin_fees
    }
    
    public fun lp_supply_val<A, B, W: drop, T: store>(self: &Pool<A, B, W, T>): u64 {
        self.lp_supply.supply_value()
    }

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
