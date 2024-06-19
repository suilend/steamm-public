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
    ): (Pool<Base, Quote, LP>, Coin<LP>) {
        assert!(lp_treasury_cap.supply_immut().supply_value() == 0, 0);

        let k = (base_liquidity.value() as u256) * (quote_liquidity.value() as u256);

        let mut pool = Pool {
            id: object::new(ctx),
            base_balance: base_liquidity.into_balance(),
            quote_balance: quote_liquidity.into_balance(),
            lp_supply: lp_treasury_cap.treasury_into_supply(),
            k,
        };

        let lp_token_delta = math256::sqrt_down(k);

        let lp_tokens = coin::from_balance(
            pool.lp_supply.increase_supply(lp_token_delta as u64),
            ctx
        );

        (pool, lp_tokens)
    }

    public fun deposit_liquidity<Base, Quote, LP>(
        self: &mut Pool<Base, Quote, LP>,
        base_liquidity: &mut Coin<Base>,
        quote_liquidity: &mut Coin<Quote>,
        max_base: u64,
        max_quote: u64,
        ctx:  &mut TxContext,
    ): Coin<LP> {
        // 1. Compute token deposits and delta lp tokens
        let (base_deposit, quote_deposit, new_lp_tokens) = deposit_liquidity_inner(
            self.base_balance.value(),
            self.quote_balance.value(),
            self.lp_supply.supply_value(),
            max_base,
            max_quote,
        );

        // 2. Add liquidity to pool
        self.base_balance.join(
            base_liquidity.balance_mut().split(base_deposit)
        );
        
        self.quote_balance.join(
            quote_liquidity.balance_mut().split(quote_deposit)
        );

        // 3. Recompute invariant
        self.update_invariant();

        // 4. Mint LP Tokens
        coin::from_balance(
            self.lp_supply.increase_supply(new_lp_tokens),
            ctx
        )
    }
    
    fun deposit_liquidity_inner(
        base_balance: u64,
        quote_balance: u64,
        lp_supply: u64,
        max_base: u64,
        max_quote: u64,
    ): (u64, u64, u64) {
        // 1. Calculate the prices of all tokens by choosing the cheapest token to be the quote for all prices. The cheapest token is simply $min(\vec x)$. We then compute the vector of parity prices:
        let parity_amt = math64::min(max_base, max_quote);

        // 2. Denominate all tokens in parity price
        let parity_base = math256::mul_div_down(max_base as u256, base_balance as u256, parity_amt as u256) as u64;
        let parity_quote = math256::mul_div_down(max_quote as u256, quote_balance as u256, parity_amt as u256) as u64;

        // 3. pick the lowest amount, that represents the maximum
        // amount of tokens in price parity that the user can deposit
        // for all tokens
        let min_parity = math64::min(parity_base, parity_quote);

        // 4. Compute actual amount of tokens to deposit
        let base_deposit = math256::mul_div_down(max_base as u256, min_parity as u256, parity_base as u256) as u64;
        let quote_deposit = math256::mul_div_down(max_quote as u256, min_parity as u256, parity_quote as u256) as u64;

        // 5. Assert slippage
        assert!(base_deposit <= max_base, 0);
        assert!(quote_deposit <= max_quote, 0);

        // 8. Compute new LP Tokens
        let new_lp_tokens = math256::mul_div_down(base_deposit as u256, lp_supply as u256, base_balance as u256) as u64;

        (base_deposit, quote_deposit, new_lp_tokens)
    }

    public fun redeem_liquidity<Base, Quote, LP>(
        self: &mut Pool<Base, Quote, LP>,
        lp_tokens: Coin<LP>,
        min_base: u64,
        min_quote: u64,
        ctx:  &mut TxContext,
    ): (Coin<Base>, Coin<Quote>) {
        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(
            self.base_balance.value(),
            self.quote_balance.value(),
            self.lp_supply.supply_value(),
            lp_tokens.value(),
            min_base,
            min_quote,
        );

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

    fun redeem_liquidity_inner(
        base_balance: u64,
        quote_balance: u64,
        lp_supply: u64,
        lp_tokens: u64,
        min_base: u64,
        min_quote: u64,
    ): (u64, u64) {
        // 1. Compute the amount of tokens the user is allowed to
        // receive for each reserve, via the lp ratio

        let base_withdraw = math256::mul_div_down(base_balance as u256, lp_tokens as u256, lp_supply as u256) as u64;
        let quote_withdraw = math256::mul_div_down(quote_balance as u256, lp_tokens as u256, lp_supply as u256) as u64;

        // 2. Assert slippage
        assert!(base_withdraw >= min_base, 0);
        assert!(quote_withdraw >= min_quote, 0);

        (base_withdraw, quote_withdraw)
    }

    public fun swap_base_for_quote<Base, Quote, LP>(
        self: &mut Pool<Base, Quote, LP>,
        base_tokens: Coin<Base>,
        min_quote: u64,
        ctx: &mut TxContext,
    ): Coin<Quote> {

        let quote_tokens = quote_swap_base_for_quote(
            self.quote_balance.value() as u256,
            self.base_balance.value() as u256,
            base_tokens.value() as u256,
            self.k
        );

        assert!(quote_tokens >= min_quote, 0);

        self.base_balance.join(
            base_tokens.into_balance()
        );

        coin::from_balance(
            self.quote_balance.split(quote_tokens),
            ctx
        )
    }
    
    public fun quote_swap_base_for_quote(
        quote_balance: u256,
        base_balance: u256,
        base_tokens: u256,
        k: u256,
    ): u64 {
        (quote_balance - math256::div_up(k, base_balance + base_tokens)) as u64
    }
    
    public fun swap_quote_for_base<Base, Quote, LP>(
        self: &mut Pool<Base, Quote, LP>,
        quote_tokens: Coin<Quote>,
        min_base: u64,
        ctx:  &mut TxContext,
    ): Coin<Base> {

        let base_tokens = quote_swap_quote_for_base(
            self.base_balance.value() as u256,
            self.quote_balance.value() as u256,
            quote_tokens.value() as u256,
            self.k,
        );

        assert!(base_tokens >= min_base, 0);

        self.quote_balance.join(
            quote_tokens.into_balance()
        );

        coin::from_balance(
            self.base_balance.split(base_tokens),
            ctx
        )
    }
    
    public fun quote_swap_quote_for_base(
        base_balance: u256,
        quote_balance: u256,
        quote_tokens: u256,
        k: u256,
    ): u64 {
        (base_balance - (k / (quote_balance + quote_tokens))) as u64
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

    use std::debug::print;
    #[test_only]
    use sui::test_utils::assert_eq;

    #[test]
    fun test_swap_base_for_quote() {
        let delta_quote = quote_swap_base_for_quote(50000000000, 50000000000, 1000000000, (50000000000 as u256) * (50000000000 as u256));
        assert_eq(delta_quote, 980392156);

        let delta_quote = quote_swap_base_for_quote(9999005960552740, 1095387779115020, 1000000000, ((9999005960552740 as u256) * (1095387779115020 as u256)));
        assert_eq(delta_quote, 9128271305);

        let delta_quote = quote_swap_base_for_quote(1029168250865450, 7612534772798660, 1000000000, ((1029168250865450 as u256) * (7612534772798660 as u256)));
        assert_eq(delta_quote, 135193880);
        	
        let delta_quote = quote_swap_base_for_quote(2768608899383570, 5686051292328860, 1000000000, ((2768608899383570 as u256) * (5686051292328860 as u256)));
        assert_eq(delta_quote, 486912317);

        let delta_quote = quote_swap_base_for_quote(440197283258732, 9283788821706570, 1000000000, ((440197283258732 as u256) * (9283788821706570 as u256)));
        assert_eq(delta_quote, 47415688);

        let delta_quote = quote_swap_base_for_quote(7199199355268960, 9313530357314980, 1000000000, ((7199199355268960 as u256) * (9313530357314980 as u256)));
        assert_eq(delta_quote, 772982779);

        let delta_quote = quote_swap_base_for_quote(6273576615700410, 1630712284783210, 1000000000, ((6273576615700410 as u256) * (1630712284783210 as u256)));
        assert_eq(delta_quote, 3847136510);

        let delta_quote = quote_swap_base_for_quote(5196638254543900, 9284728716079420, 1000000000, ((5196638254543900 as u256) * (9284728716079420 as u256)));
        assert_eq(delta_quote, 559697310);

        let delta_quote = quote_swap_base_for_quote(1128134431179110, 4632243184772740, 1000000000, ((1128134431179110 as u256) * (4632243184772740 as u256)));
        assert_eq(delta_quote, 243539499);
    }

    #[test]
    fun test_deposit_liquidity_inner() {
        let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(
            50_000_000, // base_balance
            50_000_000, // quote_balance
            1_000_000_000, // lp_supply
            50_000_000, // max_base
            250_000_000, // max_quote,
        );

        assert_eq(base_deposit, 50_000_000);
        assert_eq(quote_deposit, 50_000_000);
        assert_eq(lp_tokens, 1_000_000_000);
        
        let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(
            995904078539, // base_balance
            433683167230, // quote_balance
            1_000_000_000, // lp_supply
            993561515, // max_base
            4685420547, // max_quote,
        );

        assert_eq(base_deposit, 993561515);
        assert_eq(quote_deposit, 2281601039);
        assert_eq(lp_tokens, 997647);
        
        
        let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(
            431624541156, // base_balance
            136587560238, // quote_balance
            1_000_000_000, // lp_supply
            167814009, // max_base
            5776084236, // max_quote,
        );

        assert_eq(base_deposit, 167814009);
        assert_eq(quote_deposit, 530301914);
        assert_eq(lp_tokens, 388796);
	
        
        let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(
            814595492359, // base_balance
            444814121159, // quote_balance
            1_000_000_000, // lp_supply
            5792262291, // max_base
            6821001626, // max_quote,
        );

        assert_eq(base_deposit, 3724643546);
        assert_eq(quote_deposit, 6821001626);
        assert_eq(lp_tokens, 4572384);
        
        let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(
            6330406121, // base_balance
            45207102784, // quote_balance
            1_000_000_000, // lp_supply
            1432889520, // max_base
            1335572325, // max_quote,
        );

        assert_eq(base_deposit, 1432889520);
        assert_eq(quote_deposit, 200649279);
        assert_eq(lp_tokens, 226350330);

        let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(420297244854, 316982205287, 6_606_760_618_411_090, 4995214965, 3570130297);

        assert_eq(base_deposit, 2692541501);
        assert_eq(quote_deposit, 3570130297);
        assert_eq(lp_tokens, 42324753183722);

        let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(413062764570, 603795453491, 1_121_070_850_572_460, 1537859755, 8438693476);

        assert_eq(base_deposit, 1537859755);
        assert_eq(quote_deposit, 1052065891);
        assert_eq(lp_tokens, 4173820279815);

        let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(307217683947, 761385620952, 4_042_886_943_071_790, 3998100768, 108790920);

        assert_eq(base_deposit, 269619382);
        assert_eq(quote_deposit, 108790920);
        assert_eq(lp_tokens, 3548105255799);

        let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(42698336282, 948435467841, 2_431_942_296_016_960, 6236994835, 8837546234);

        assert_eq(base_deposit, 6236994835);
        assert_eq(quote_deposit, 280788004);
        assert_eq(lp_tokens, 355236593742180);

        let (base_deposit, quote_deposit, lp_tokens) = deposit_liquidity_inner(861866936755, 638476503150, 244_488_474_179_102, 886029611, 7520096624);

        assert_eq(base_deposit, 886029611);
        assert_eq(quote_deposit, 1196034032);
        assert_eq(lp_tokens, 251342775123);
    }
    
    #[test]
    fun test_redeem_liquidity_inner() {
        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(
            50_000_000, // base_balance
            50_000_000, // quote_balance
            1_000_000_000, // lp_supply
            542816471, // lp_tokens
            0, // min_base
            0, // min_quote
        );

        assert_eq(base_withdraw, 27140823);
        assert_eq(quote_withdraw, 27140823);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(995904078539, 433683167230, 1000000000, 389391649, 0, 0);
        assert_eq(quote_withdraw, 168872603631);
        assert_eq(base_withdraw, 387796731388);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(431624541156, 136587560238, 1000000000, 440552590, 0, 0);
        assert_eq(base_withdraw, 190153309513);
        assert_eq(quote_withdraw, 60174003424);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(814595492359, 444814121159, 1000000000, 996613035, 0, 0);
        assert_eq(base_withdraw, 811836485937);
        assert_eq(quote_withdraw, 443307551299);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(6330406121, 45207102784, 1000000000, 12810274, 0, 0);
        assert_eq(base_withdraw, 81094236);
        assert_eq(quote_withdraw, 579115373);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(420297244854, 316982205287, 6606760618411090, 2045717643009200, 0, 0);
        assert_eq(base_withdraw, 130140857035);
        assert_eq(quote_withdraw, 98150383724);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(413062764570, 603795453491, 1121070850572460, 551538827364816, 0, 0);
        assert_eq(base_withdraw, 203216551998);
        assert_eq(quote_withdraw, 297052265890);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(307217683947, 761385620952, 4042886943071790, 2217957798004580, 0, 0);
        assert_eq(base_withdraw, 168541902702);
        assert_eq(quote_withdraw, 417701805432);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(42698336282, 948435467841, 2431942296016960, 59368562297754, 0, 0);
        assert_eq(base_withdraw, 1042351556);
        assert_eq(quote_withdraw, 23153201558);

        let (base_withdraw, quote_withdraw) = redeem_liquidity_inner(861866936755, 638476503150, 244488474179102, 129992518389093, 0, 0);
        assert_eq(base_withdraw, 458247588158);
        assert_eq(quote_withdraw, 339472725065);
    }
}
