module slamm::pool {
    use sui::balance::{Self, Balance, Supply};
    use sui::coin::{Self, Coin};
    use slamm::events::emit_event;
    use slamm::math::{safe_mul_div_u64};
    use slamm::fees::{Self, Fees};
    use sui::tx_context::sender;
    use std::type_name::{Self, TypeName};
    use sui::object_bag::{Self as ob, ObjectBag};

    // Allows calling `.split_vec(amounts, ctx)` on `coin`
    public use fun slamm::cpmm::deposit_liquidity as Pool.cpmm_deposit;
    public use fun slamm::cpmm::redeem_liquidity as Pool.cpmm_redeem;
    public use fun slamm::cpmm::swap as Pool.cpmm_swap;
    public use fun slamm::cpmm::state as Pool.cpmm;

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

    public struct Pool<phantom A, phantom B, phantom W: drop> has key, store {
        id: UID,
        reserve_a: Balance<A>,
        reserve_b: Balance<B>,
        lp_supply: Supply<LP<A, B, W>>,
        protocol_fees: Fees<A, B>,
        admin_fees: Fees<A, B>,
        hooks: Hooks,
        fields: ObjectBag,
    }

    public struct Hooks has store {
        swap: vector<TypeName>,
        deposit: vector<TypeName>,
        redeem: vector<TypeName>,
    }

    public struct Request<phantom T> {
        pool: ID,
        receipts: vector<TypeName>
    }

    // Type Markers
    public struct Swap {}
    public struct Deposit {}
    public struct Redeem {}

    fun confirm_swap<A, B, W: drop>(self: &Pool<A, B, W>, request: Request<Swap>) {
        assert!(object::id(self) == request.pool, 0);
        confirm(&self.hooks.swap, request);
    }
    
    fun confirm_deposit<A, B, W: drop>(self: &Pool<A, B, W>, request: Request<Deposit>) {
        assert!(object::id(self) == request.pool, 0);
        confirm(&self.hooks.deposit, request);
    }
    
    fun confirm_redeem<A, B, W: drop>(self: &Pool<A, B, W>, request: Request<Redeem>) {
        assert!(object::id(self) == request.pool, 0);
        confirm(&self.hooks.redeem, request);
    }
    
    fun confirm<T>(
        hooks: &vector<TypeName>,
        request: Request<T>
    ) {
        let Request { pool: _, receipts } = request;
        assert!(hooks == &receipts, 0);
    }
    
    // ===== Public Methods =====

    public fun new<A, B, W: drop>(
        _witness: W,
        swap_fee_bps: u64,
        swap_hooks: vector<TypeName>,
        deposit_hooks: vector<TypeName>,
        redeem_hooks: vector<TypeName>,
        ctx: &mut TxContext,
    ): (Pool<A, B, W>, PoolCap<A, B, W>) {
        assert!(swap_fee_bps < SWAP_FEE_DENOMINATOR, EFeeAbove100Percent);

        let lp_supply = balance::create_supply(LP<A, B, W>{});

        let pool = Pool {
            id: object::new(ctx),
            reserve_a: balance::zero(),
            reserve_b: balance::zero(),
            protocol_fees: fees::new(SWAP_FEE_NUMERATOR, SWAP_FEE_DENOMINATOR),
            admin_fees: fees::new(swap_fee_bps, SWAP_FEE_DENOMINATOR),
            lp_supply,
            hooks: Hooks {
                swap: swap_hooks,
                deposit: deposit_hooks,
                redeem: redeem_hooks,
            },
            fields: ob::new(ctx),
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

    public fun get_field<A, B, W: drop, K: copy + store + drop, V: key + store>(
        self: &Pool<A, B, W>,
        key: K,
    ): &V {
        self.fields.borrow(key)
    }
    
    public fun add_field<A, B, W: drop, K: copy + store + drop, V: key + store>(
        self: &mut Pool<A, B, W>,
        key: K,
        value: V,
    ) {
        self.fields.add(key, value)
    }
    
    public fun get_field_mut<A, B, W: drop, K: copy + store + drop, V: key + store>(
        self: &mut Pool<A, B, W>,
        key: K,
    ): &mut V {
        self.fields.borrow_mut(key)
    }


    public fun deposit_liquidity<A, B, W: drop>(
        self: &mut Pool<A, B, W>,
        balance_a: Balance<A>,
        balance_b: Balance<B>,
        lp_to_mint: u64,
        request: Request<Deposit>,
        ctx:  &mut TxContext,
    ): (Coin<LP<A, B, W>>, DepositResult) {
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
        self.confirm_deposit(request);

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
    
    public fun redeem_liquidity<A, B, W: drop>(
        self: &mut Pool<A, B, W>,
        withdraw_a: u64,
        withdraw_b: u64,
        lp_tokens: Coin<LP<A, B, W>>,
        request: Request<Redeem>,
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
        self.confirm_redeem(request);

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

    public fun swap_a2b<A, B, W: drop>(
        self: &mut Pool<A, B, W>,
        mut balance_in: Balance<A>,
        amount_out: u64,
        request: Request<Swap>,
        ctx: &mut TxContext,
    ): (Balance<B>, SwapResult) {
        assert!(self.lp_supply_val() > 0, 0);

        let amount_in = balance_in.value();
        let (_, protocol_fees, admin_fees) = self.net_amount_in(amount_in);

        // Transfers protocol fees in
        self.protocol_fees.deposit_a(balance_in.split(protocol_fees));
            
        // Transfers protocol fees in
        self.admin_fees.deposit_a(balance_in.split(admin_fees));
            
        // Transfers amount in
        self.reserve_a.join(balance_in);

        // Transfers amount out
        let output = self.reserve_b.split(amount_out);

        // 4. Confirm swap
        self.confirm_swap(request);
        
        // 5. Emit event
        emit_event(
            SwapEvent {
                user: sender(ctx),
                pool_id: object::id(self),
                amount_in: amount_in,
                amount_out: amount_out,
                protocol_fees: protocol_fees,
                admin_fees: admin_fees,
                a2b: true,
            }
        );

        (output, SwapResult {
            amount_in,
            amount_out,
            protocol_fees,
            admin_fees,
            a2b: true,
        })
    }
    
    public fun swap_b2a<A, B, W: drop>(
        self: &mut Pool<A, B, W>,
        mut balance_in: Balance<B>,
        amount_out: u64,
        request: Request<Swap>,
        ctx: &mut TxContext,
    ): (Balance<A>, SwapResult) {
        assert!(self.lp_supply_val() > 0, 0);

        let amount_in = balance_in.value();
        let (_, protocol_fees, admin_fees) = self.net_amount_in(amount_in);

        // Transfers protocol fees in
        self.protocol_fees.deposit_b(balance_in.split(protocol_fees));
            
        // Transfers protocol fees in
        self.admin_fees.deposit_b(balance_in.split(admin_fees));
            
        // Transfers amount in
        self.reserve_b.join(balance_in);

        // Transfers amount out
        let output = self.reserve_a.split(amount_out);

        // 4. Confirm swap
        self.confirm_swap(request);
        
        // 5. Emit event
        emit_event(
            SwapEvent {
                user: sender(ctx),
                pool_id: object::id(self),
                amount_in: amount_in,
                amount_out: amount_out,
                protocol_fees: protocol_fees,
                admin_fees: admin_fees,
                a2b: false,
            }
        );

        (output, SwapResult {
            amount_in,
            amount_out,
            protocol_fees,
            admin_fees,
            a2b: false,
        })
    }

    public fun net_amount_in<A, B, W: drop>(self: &Pool<A, B, W>, amount_in: u64): (u64, u64, u64) {
        let (protocol_fee_num, protocol_fee_denom) = self.protocol_fees.fee_ratio();
        let (admin_fee_num, admin_fee_denom) = self.admin_fees.fee_ratio();
        
        let protocol_fees = safe_mul_div_u64(amount_in, protocol_fee_num, protocol_fee_denom);
        let admin_fees = safe_mul_div_u64(amount_in, admin_fee_num, admin_fee_denom);
        let net_amount_in = amount_in - protocol_fees - admin_fees;

        (net_amount_in, protocol_fees, admin_fees)
    }

    // ===== Public Request Functions =====

    public fun swap_request<A, B, W: drop>(self: &Pool<A, B, W>): Request<Swap> {
        Request {
            pool: object::id(self),
            receipts: vector[],
        }
    }

    public fun deposit_request<A, B, W: drop>(self: &Pool<A, B, W>): Request<Deposit> {
        Request {
            pool: object::id(self),
            receipts: vector[],
        }
    }
    public fun redeem_request<A, B, W: drop>(self: &Pool<A, B, W>): Request<Redeem> {
        Request {
            pool: object::id(self),
            receipts: vector[],
        }
    }

    public fun push_receipt<T, W: drop>(self: &mut Request<T>, _witness: W) {
        let receipt = type_name::get<W>();
        self.receipts.push_back(receipt);
    }

    // ===== View & Getters =====

    public fun reserves<A, B, W: drop>(self: &Pool<A, B, W>): (u64, u64) {
        (self.reserve_a.value(), self.reserve_b.value())
    }
    
    public fun protocol_fees<A, B, W: drop>(self: &Pool<A, B, W>): &Fees<A, B> {
        &self.protocol_fees
    }
    
    public fun admin_fees<A, B, W: drop>(self: &Pool<A, B, W>): &Fees<A, B> {
        &self.admin_fees
    }
    
    public fun lp_supply_val<A, B, W: drop>(self: &Pool<A, B, W>,): u64 {
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

    // ===== Results =====

    public struct SwapResult has drop {
        amount_in: u64,
        amount_out: u64,
        protocol_fees: u64,
        admin_fees: u64,
        a2b: bool,
    }

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

    public fun amount_in(self: &SwapResult): u64 { self.amount_in }
    public fun amount_out(self: &SwapResult): u64 { self.amount_out }
    public fun swap_protocol_fees(self: &SwapResult): u64 { self.protocol_fees }
    public fun swap_admin_fees(self: &SwapResult): u64 { self.admin_fees }
    public fun a2b(self: &SwapResult): bool { self.a2b }
    public fun deposit_a(self: &DepositResult): u64 { self.deposit_a }
    public fun deposit_b(self: &DepositResult): u64 { self.deposit_b }
    public fun mint_lp(self: &DepositResult): u64 { self.mint_lp }
    public fun withdraw_a(self: &RedeemResult): u64 { self.withdraw_a }
    public fun withdraw_b(self: &RedeemResult): u64 { self.withdraw_a }
    public fun burn_lp(self: &RedeemResult): u64 { self.burn_lp }
}
