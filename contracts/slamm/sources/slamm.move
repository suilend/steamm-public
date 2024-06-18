module slamm::pool {
    use sui::balance::{Balance, Supply};
    use sui::coin::{Self, Coin, TreasuryCap};
    use slamm::math256;
    use slamm::math64;

    const MAX_ITERATIONS: u64 = 100;

    public struct Pool<phantom Base, phantom Quote, phantom LP> has key, store {
        id: UID,
        base_balance: Balance<Base>,
        quote_balance: Balance<Quote>,
        lp_supply: Supply<LP>,
        k: u256,
    }

    fun update_invariant<Base, Quote, LP>(self: &mut Pool<Base, Quote, LP>) {
        self.k = (self.base_balance.value() as u256) * (self.quote_balance.value() as u256);
    }

    public fun init_pool<Base, Quote, LP>(
        lp_treasury_cap: TreasuryCap<LP>,
        base_liquidity: Coin<Base>,
        quote_liquidity: Coin<Quote>,
        ctx: &mut TxContext,
    ): Pool<Base, Quote, LP> {
        assert!(lp_treasury_cap.supply_immut().supply_value() == 0, 0);

        let k = (base_liquidity.value() as u256) * (quote_liquidity.value() as u256);

        let pool = Pool {
            id: object::new(ctx),
            base_balance: base_liquidity.into_balance(),
            quote_balance: quote_liquidity.into_balance(),
            lp_supply: lp_treasury_cap.treasury_into_supply(),
            k,
        };

        pool
    }

    public fun deposit_liquidity<Base, Quote, LP>(
        self: &mut Pool<Base, Quote, LP>,
        base_liquidity: &mut Coin<Base>,
        quote_liquidity: &mut Coin<Quote>,
        max_base: u64,
        max_quote: u64,
        ctx:  &mut TxContext,
    ): Coin<LP> {
        // 1. Calculate the prices of all tokens by choosing the cheapest token to be the quote for all prices. The cheapest token is simply $min(\vec x)$. We then compute the vector of parity prices:
        let parity_amt = math64::min(max_base, max_quote);

        // 2. Denominate all tokens in parity price
        let parity_base = max_base / parity_amt;
        let parity_quote = max_quote / parity_amt;

        // 3. pick the lowest amount, that represents the maximum
        // amount of tokens in price parity that the user can deposit
        // for all tokens
        let min_parity = math64::min(parity_base, parity_quote);

        // 4. Compute actual amount of tokens to deposit
        let base_deposit = max_base * min_parity / parity_base;
        let quote_deposit = max_quote * min_parity / parity_quote;

        // 5. Assert slippage
        assert!(base_deposit <= max_base, 0);
        assert!(quote_deposit <= max_quote, 0);

        // 6. Add liquidity to pool
        self.base_balance.join(
            base_liquidity.balance_mut().split(base_deposit)
        );
        
        self.quote_balance.join(
            quote_liquidity.balance_mut().split(quote_deposit)
        );

        // 7. Recompute invariant
        self.update_invariant();

        // 8. Mint LP Tokens
        let lp_supply = self.lp_supply.supply_value();
        let base_balance = self.base_balance.value();

        let new_lp_tokens = base_deposit * lp_supply / base_balance;

        coin::from_balance(
            self.lp_supply.increase_supply(new_lp_tokens),
            ctx
        )
    }

    public fun redeem_liquidity<Base, Quote, LP>(
        self: &mut Pool<Base, Quote, LP>,
        lp_tokens: Coin<LP>,
        min_base: u64,
        min_quote: u64,
        ctx:  &mut TxContext,
    ): (Coin<Base>, Coin<Quote>) {
        // 1. Compute LP tokens ratio
        let lp_amt = lp_tokens.value();
        let lp_supply = self.lp_supply.supply_value();

        let lp_ratio = lp_amt / lp_supply;

        // 2. Compute the amount of tokens the user is allowed to
        // receive for each reserve
        let base_withdraw = self.base_balance.value() * lp_ratio;
        let quote_withdraw = self.quote_balance.value() * lp_ratio;

        // 3. Assert slippage
        assert!(base_withdraw >= min_base, 0);
        assert!(quote_withdraw >= min_quote, 0);

        // 4. Burn LP Tokens
        self.lp_supply.decrease_supply(
            lp_tokens.into_balance()
        );

        // 5. Recompute invariant
        self.update_invariant();

        // 6. Send tokens
        let base_tokens = coin::from_balance(
            self.base_balance.split(base_withdraw),
            ctx,
        );
        let quote_tokens = coin::from_balance(
            self.quote_balance.split(quote_withdraw),
            ctx,
        );

        (base_tokens, quote_tokens)
    }

    public fun swap_base_for_quote<Base, Quote, LP>(
        self: &mut Pool<Base, Quote, LP>,
        base_tokens: Coin<Base>,
        min_quote: u64,
        ctx:  &mut TxContext,
    ): Coin<Quote> {

        let quote_tokens = self.quote_swap_base_for_quote(&base_tokens);

        assert!(quote_tokens >= min_quote, 0);

        self.base_balance.join(
            base_tokens.into_balance()
        );

        coin::from_balance(
            self.quote_balance.split(quote_tokens),
            ctx
        )
    }
    
    public fun quote_swap_base_for_quote<Base, Quote, LP>(
        self: &mut Pool<Base, Quote, LP>,
        base_tokens: &Coin<Base>,
    ): u64 {

        let x = self.quote_balance.value() as u256;
        let y = self.base_balance.value() as u256;
        let delta_y = base_tokens.value() as u256;

        let delta_x = x - (self.k / (y + delta_y));

        delta_x as u64
    }
    
    public fun swap_quote_for_base<Base, Quote, LP>(
        self: &mut Pool<Base, Quote, LP>,
        quote_tokens: Coin<Quote>,
        min_base: u64,
        ctx:  &mut TxContext,
    ): Coin<Base> {

        let base_tokens = self.quote_swap_quote_for_base(&quote_tokens);

        assert!(base_tokens >= min_base, 0);

        self.quote_balance.join(
            quote_tokens.into_balance()
        );

        coin::from_balance(
            self.base_balance.split(base_tokens),
            ctx
        )
    }
    
    public fun quote_swap_quote_for_base<Base, Quote, LP>(
        self: &mut Pool<Base, Quote, LP>,
        quote_tokens: &Coin<Quote>,
    ): u64 {

        let x = self.base_balance.value() as u256;
        let y = self.quote_balance.value() as u256;
        let delta_y = quote_tokens.value() as u256;

        let delta_x = x - (self.k / (y + delta_y));

        delta_x as u64
    }

    public fun newtonian_root_approximation(
        base: u256,
        root: u256,
        mut guess: u256,
    ): u256 {
        if (base == 0) {
            return 0
        };
        
        if (root == 0) {
            abort(0)
        };

        let root_minus_one = root - 1;
        let mut last_guess = guess;

        let mut current_iteration = 0;

        while (current_iteration <= MAX_ITERATIONS) {

            current_iteration = current_iteration + 1;

            // x_k+1 = ((n - 1) * x_k + A / (x_k ^ (n - 1))) / n
            let first_term = root_minus_one * guess;
    
            let power = math256::pow(guess, root_minus_one);

            let second_term = base / power;
            // let second_term = match power {
            //     Ok(num) => base.clone().try_div(num)?,
            //     Err(_) => T::from(0u64),
            // };
            guess = (first_term + second_term) / root;
            // the source uses precision of 2 places, but we originally used 3
            // places and want to keep the same precision as we tested our
            // programs with
            if (almost_eq(last_guess, guess, 3)) {
                break
            } else {
                last_guess = guess;
            }
        };
        
        guess
    }

    public fun almost_eq(num: u256, other: u256, precision: u64): bool {
        let precision = math256::pow(10 as u256, precision as u256);

        if (num == other) {
            true
        } else if (num < other) {
            other - num < precision
        } else {
            num - other < precision
        }

    }
}
