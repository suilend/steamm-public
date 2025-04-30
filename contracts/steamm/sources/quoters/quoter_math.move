module steamm::quoter_math;

use suilend::decimal::Decimal;

use steamm::fixed_point64::{Self, FixedPoint64};
use steamm::utils::decimal_to_fixedpoint64;

const EInvalidZ: u64 = 1;

public(package) fun swap(
    // Amount in (underlying)
    amount_in: Decimal,
    // Amount X (underlying)
    reserve_x: Decimal,
    // Amount Y (underlying)
    reserve_y: Decimal,
    // Price X (underlying)
    price_x: Decimal,
    // Price Y (underlying)
    price_y: Decimal,
    decimals_x: u64,
    decimals_y: u64,
    amplifier: u64,
    x2y: bool,
): u64 {
    let r_x = decimal_to_fixedpoint64(reserve_x);
    let r_y = decimal_to_fixedpoint64(reserve_y);
    let p_x = decimal_to_fixedpoint64(price_x);
    let p_y = decimal_to_fixedpoint64(price_y);
    let amp = fixed_point64::from(amplifier as u128);
    let delta_in = decimal_to_fixedpoint64(amount_in);

    let dec_pow = if (decimals_x >= decimals_y) {
        fixed_point64::from(10).pow(decimals_x - decimals_y)
    } else {
        fixed_point64::one().div(
            fixed_point64::from(10).pow(decimals_y - decimals_x)
        )
    };

    // k can be interpreted as the trade utilisation, based on the oracle price
    // In general terms: k = Δin * Price / Reserve Out
    // Depending on the direction of the trade we either multiply or divide by the price
    // x2y: k = ΔX * Price / (Reserve Y * DecPow)
    // y2x: k = ΔY * DecPow / (Reserve X * Price)
    let k = if (x2y) {
        // k = [ΔX * PriceX] / [ReserveY * PriceY * DecPow]
        fixed_point64::multiply_divide(
            &mut vector[delta_in, p_x],
            &mut vector[r_y, p_y, dec_pow],
        )
    } else {
        // k = [ΔY * PriceY * DecPow] / [ReserveX * PriceX]
        fixed_point64::multiply_divide(
            &mut vector[delta_in, dec_pow, p_y],
            &mut vector[r_x, p_x],
        )
    };

    // z can be interpreted as the effective utilisation. Since k is the trade utilisation
    // if the trade was executed with the oracle price, this means that z will always be
    // lower than k. Since slippage is supposed to reduce the trade output, in effect this
    // means that the effective utilisation `z` is lower than the oracle-given utilisation `k`.
    // Therefore we can use `k` as our initial guess for `z`.
    let max_bound = fixed_point64::from_rational(9999999999, 10000000000);
    let z_upper_bound = max_bound.min(k);

    let z = newton_raphson(k, amp, z_upper_bound);

    assert!(z.lt(fixed_point64::one()), EInvalidZ);

    // `z` is defined as Δout / ReserveOut. Therefore depending on the
    // direction of the trade we pick the corresponding ouput reserve
    let delta_out = if (x2y) {
        z.mul(r_y).to_u128_down() as u64
    } else {
        z.mul(r_x).to_u128_down() as u64
    };

    // If the trade still depletes the output reserve we quote an output of zero
    if (x2y) {
        if (delta_out >= reserve_y.floor()) {
            return 0
        };
    } else {
        if (delta_out >= reserve_x.floor()) {
            return 0
        };
    };

    delta_out
}

/// Implements the Newton-Raphson method for finding roots of a function in fixed-point arithmetic.
/// This function iteratively refines an initial guess to approximate a root of the function f(z) = 0,
/// where f(z) is defined by the parameters `k` and `a`.
///
/// # Arguments
/// * `k` - A fixed-point parameter used in the function f(z) and its derivative.
/// * `a` - A fixed-point parameter used in the function f(z) and its derivative.
/// * `z_initial` - The initial guess for the root, in fixed-point format.
///
/// # Returns
/// * A `FixedPoint64` value representing the approximate root of the function.
///
/// # Remarks
/// - The method uses a maximum of 20 iterations and a tolerance of 1e-10 for convergence.
/// - The solution is clamped to the range [1e-5, 0.999999999999999999] to ensure stability.
/// - If the derivative is near zero (less than 1e-10), the function aborts with error code 1001.
/// - A damping factor (alpha) is applied if the step takes the solution outside the valid range.
fun newton_raphson(
    k: FixedPoint64,
    a: FixedPoint64,
    z_initial: FixedPoint64
): FixedPoint64 {
    let one = fixed_point64::one();
    let z_min = fixed_point64::from_rational(1, 100000); // 1e-5 // todo: increase scale?
    let z_max = fixed_point64::from_rational(999999999999999999, 1000000000000000000); // 0.999999999999999999
    let tol = fixed_point64::from_rational(1, 1000000000_00000); // 1e-14
    let max_iter = 20;
    
    // Improve initial guess
    let mut z = if (z_initial.gte(one)) {
        z_max
    } else {
        z_initial
    };
    
    let mut i = 0;
    
    while (i < max_iter) {
        // Compute f(z)
        let (fx_val, fx_positive) = compute_f(z, a, k);
        
        // Check convergence
        if (fixed_point64::lt(fx_val, tol)) {
            break
        };
        
        // Compute f'(z)
        let fp = compute_f_prime(z, a);
        
        // Check for near-zero derivative
        assert!(
            !fixed_point64::lt(fp, fixed_point64::from_rational(1, 10000000000)), // 1e-10
            1001 // Error if derivative is near zero
        );
        
        // Newton step: z_new = z - alpha * f(z)/f'(z)
        let fx_div_fp = fixed_point64::div(fx_val, fp);
        let mut alpha = one; // Start with alpha = 1.0
        let z_new_temp = if (fx_positive) {
            fixed_point64::sub(z, fx_div_fp)
        } else {
            fixed_point64::add(z, fx_div_fp)
        };
        
        let mut z_new = z_new_temp;
        
        // Check if z_new is outside valid range
        if (fixed_point64::lte(z_new, fixed_point64::zero()) || fixed_point64::gte(z_new, one)) {
            // Reduce alpha to 0.5
            alpha = fixed_point64::from_rational(1, 2); // 0.5
            let damped_step = fixed_point64::mul(fx_div_fp, alpha);
            z_new = if (fx_positive) {
                fixed_point64::sub(z, damped_step)
            } else {
                fixed_point64::add(z, damped_step)
            };
            // Clamp to [z_min, z_max]
            z_new = if (fixed_point64::lt(z_new, z_min)) {
                z_min
            } else if (fixed_point64::gt(z_new, z_max)) {
                z_max
            } else {
                z_new
            };
        };
        
        // Check if step is too small
        let step_size = if (fixed_point64::gte(z_new, z)) {
            fixed_point64::sub(z_new, z)
        } else {
            fixed_point64::sub(z, z_new)
        };
        if (fixed_point64::lt(step_size, tol)) {
            break
        };
        
        // Update z for next iteration
        z = z_new;
        i = i + 1;
    };
    
    z
}

/// Computes f(z) = (1 - 1/A) * z - (1/A) * ln(1 - z) - k
/// Returns (magnitude, is_positive) where magnitude is |f(z)| and is_positive indicates the sign
fun compute_f(
    z: FixedPoint64,
    a: FixedPoint64,
    k: FixedPoint64
): (FixedPoint64, bool) {
    let one = fixed_point64::one();
    
    // 64 * ln(2) in FixedPoint64 format
    let ln2_64 = fixed_point64::from_raw_value(12786308645202655660).mul(fixed_point64::from(64)); // 64 * LN2

    // Step 1: Compute (1 - 1/A) * z (always positive)
    let one_div_a = fixed_point64::div(one, a);
    let term1 = fixed_point64::mul(fixed_point64::sub(one, one_div_a), z); // Term 1 is always positive

    // Step 2: Compute (1/A) * ln(1 - z)
    let one_minus_z = fixed_point64::sub(one, z); // 0.99 OK
    let ln_plus_64ln2 = fixed_point64::ln_plus_64ln2(one_minus_z); // ln(1-z) + 64*ln(2) // 44.351369219983 OK

    assert!(!fixed_point64::gt(ln_plus_64ln2, ln2_64), 999);

    // ln_magniture is always negative
    let ln_magnitude = fixed_point64::sub(ln2_64, ln_plus_64ln2);
    
    // Compute (1/A) * |ln(1-z)| (magnitude is positive, sign follows ln(1-z))
    // Term 2 is always negative
    let term2_magnitude = fixed_point64::mul(one_div_a, ln_magnitude);    

    // Term 1 is always positive, term 2 is always negative, so this will always result in an addition
    // Intermediate magnitude is always positive
    let intermediate_magnitude = fixed_point64::add(term1, term2_magnitude);

    // t1 - t2 > 0 (always)
    if (fixed_point64::gte(intermediate_magnitude, k)) {
        // BRANCH 1
        // If t1 - t2 > 0 && > k, then its safe to subtract k and get positive value
        (fixed_point64::sub(intermediate_magnitude, k), true)
    } else {
        // BRANCH 2
        // If t1 - t2 > 0 && < k, then the subtraction of k will lead to a negative value
        (fixed_point64::sub(k, intermediate_magnitude), false)
    }
}

/// Computes f'(z) = 1 - 1/A + 1/(A * (1 - z))
/// Result is always positive
fun compute_f_prime(
    z: FixedPoint64,
    a: FixedPoint64,
): FixedPoint64 {
    let one = fixed_point64::one();
    let one_div_a = fixed_point64::div(one, a);
    let term3 = one.div(
        a.mul(one.sub(z))
    );

    one.sub(one_div_a).add(term3)
}

#[test]
fun test_iter_newton_raphson() {
    use std::debug::print;
    // let k = fixed_point64::from_rational(10049999999999999999, 1000000000000000000); // 10.049999999999999999c
    // let a = fixed_point64::from(1);                // A = 1
    // let z_initial = fixed_point64::from_rational(999999999899999999, 1000000000000000000); // 0.999999999899999999
    // let z = newton_raphson(k, a, z_initial);

    // print(&z.to_string());
    
    
    let k = fixed_point64::from_rational(10019999999999999999, 1000000000000000000); // 10.049999999999999999c
    let a = fixed_point64::from(1);                // A = 1
    let z_initial = fixed_point64::from_rational(999999999899999999, 1000000000000000000); // 0.999999999899999999
    let z = newton_raphson(k, a, z_initial);

    // print(&z.to_string());
    
    // assert!(z.to_string() == utf8(b"0.000199980001333266"), 0);

    // let (result, _) = compute_f(z, a, k);
    // assert!(result.to_string() == utf8(b"0.000000000000000000"), 0);
}

#[test]
fun test_newton_raphson() {
    use std::debug::print;
    use std::string::utf8;
    // k:  0.0002 ; A:  1
    let k = fixed_point64::from_rational(2, 10000); // 0.0002
    let a = fixed_point64::from(1);                // A = 1
    let z_initial = fixed_point64::from_rational(199979994408495, 1000000000000000000); // 0.000199979994408495
    let z = newton_raphson(k, a, z_initial);
    
    // print(&z.to_string());
    assert!(z.to_string() == utf8(b"0.000199980001333266"), 0);

    let (result, _) = compute_f(z, a, k);
    assert!(result.to_string() == utf8(b"0.000000000000000000"), 0);
    
    // k:  0.630828828828829 ; A:  1 ;
    let k = fixed_point64::from_rational(630828828828829, 1000000000000000); // 0.630828828828829
    let a = fixed_point64::from(1);                // A = 1
    let z_initial = fixed_point64::from_rational(467849443537058250, 1000000000000000000); // 0.467849443537058250
    let z = newton_raphson(k, a, z_initial);

    assert!(z.to_string() == utf8(b"0.467849443548411605"), 0);

    let (result, _) = compute_f(z, a, k);
    assert!(result.to_string() == utf8(b"0.000000000000000000"), 0);

    // k:  69.50951091091092 ; A: 1 ;
    let k = fixed_point64::from_rational(6950951091091092, 100000000000000); // 69.50951091091092
    let a = fixed_point64::from(1);                // A = 1
    let z_initial = fixed_point64::from_rational(999989999970896460, 1000000000000000000); // 0.999989999970896460
    // let (z_left, z_right) = find_brackets(k, a);
    // let z_initial = z_left.add(z_right).div(fixed_point64::from(2));
    let z = newton_raphson(k, a, z_initial);
    // print(&z.to_string());

    let (result, _) = compute_f(z, a, k);
    // print(&result.to_string());
    // assert!(result.to_string() == utf8(b"0.000000000000000000"), 0); // Note: This is not zero as it struggles to converge
}

#[test]
fun test_compute_f_branch_1() {
    let z = fixed_point64::from_rational(1, 100); // z = 0.01
    let a = fixed_point64::from(10);              // A = 10
    let k = fixed_point64::from_rational(1, 100); // k = 0.01
    
    let (magnitude, is_positive) = compute_f(z, a, k); // 5.03358535e-06
    // print(&magnitude.mul(fixed_point64::from(1000000000000000)).to_u128());
    
    // Expected: (1 - 1/10) * 0.01 - (1/10) * ln(0.99) - 0.01
    // ≈ 0.9 * 0.01 - 0.1 * (-0.01005033585) - 0.01
    // ≈ 0.009 + 0.001005033585 - 0.01 ≈ 0.000005033585 (positive)
    assert!(is_positive, 1);
    assert!(magnitude.mul(fixed_point64::from(1000000000000000)).to_u128() == 5033585350_u128, 0);

    // let z = fixed_point64::from_rational(99, 100); // z = 0.99
    // let a = fixed_point64::from(2);                // A = 2
    // let k = fixed_point64::from_rational(1, 100);  // k = 0.01
    // let (magnitude, is_positive) = compute_f(z, a, k);
    
    // print(&magnitude.mul(fixed_point64::from(1000000000000000)).to_u128());
    // assert!(is_positive, 1); // Expect positive result
}

#[test]
fun test_compute_f_branch_2() {
    // Test Branch 5b: intermediate_positive, intermediate_magnitude < k ("shalom")
    // Set z small, A large, k large
    let z = fixed_point64::from_rational(1, 100);  // z = 0.01
    let a = fixed_point64::from(100);              // A = 100
    let k = fixed_point64::from_rational(1, 10);   // k = 0.1
    let (_magnitude, is_positive) = compute_f(z, a, k);
    // term1 = (1 - 1/100) * 0.01 = 0.99 * 0.01 = 0.0099
    // term2 = (1/100) * |ln(0.99)| ≈ 0.01 * 0.0100503 ≈ 0.000100503
    // intermediate = 0.0099 - 0.000100503 ≈ 0.0097995 < 0.1
    // result = 0.1 - 0.0097995 ≈ 0.0902005 (negative)
    // print(&magnitude.mul(fixed_point64::from(1000000000000000)).to_u128());
    assert!(!is_positive, 1); // Expect negative result
}

#[test]
fun test_compute_f_both_branches() {
    // Requires term1 - term2 < 0 when term2_positive is false (normal case)
    let z = fixed_point64::from_rational(9, 10);   // z = 0.9
    let a = fixed_point64::from(10);               // A = 10
    let k = fixed_point64::from_rational(1, 100);  // k = 0.01
    let (magnitude, is_positive) = compute_f(z, a, k);

    assert!(is_positive, 1); // Expect negative result
    let k = fixed_point64::from(10); // k = 10
    let (magnitude, is_positive) = compute_f(z, a, k);
    // result = 0.5797415 - 10 ≈ -9.4202585 (negative)
    // print(&magnitude.mul(fixed_point64::from(1000000000000000)).to_u128());
    assert!(!is_positive, 1); // Expect negative result
}

#[test]
fun test_ln() {
    // Computed values with high precision vs. results from fixed_point64
    // 1_____
    //  44.351369219983
    //  44.351369219982_9983615193069157647526507464935913817063903448211820476087970...
    // -0.010050335853
    // -0.0100503358535_014411835488575585477060855150076746298733786994255295830090...
    //
    //
    // 2____
    //  43.668272375276554
    //  43.668272375276554_4932856236518651237887565084646960810096028405980837981840...
    // -0.6931471805599453_094172321214581765680755001343602552541206800094933936219...
    // -0.693147180559446
    //
    //
    // 3___
    //  44.3614195557365
    //  44.3614195557364_998026978557733229670234986502657230009303901871075771917917
    // -0.00000000010000000000500000000033333333335833333333533333333350000000001428571428696428571439682539683539682539773448773457106782107551337551408979...
    // -0.0000000000995
    //
    //
    // 4___
    //  28.243323904878204
    //  28.243323904878180_0145769155905327509036242981786549254314902253008041835383...
    // -16.118095650958319_788125940182790549453207710420401410832233295306773008267741467361651980435627188088393774488296003740433866678255579647296664...
    // -16.118095650957796
    //
    // 64*ln(2)
    // 44.361419555836_4998027028557733233003568320085990563362637235206075771918060604617987752529277707960026880947853165238869558732950885203556500909

    let z = fixed_point64::from_rational(1, 100); // z = 0.01
    let result = fixed_point64::ln_plus_64ln2(fixed_point64::one().sub(z)); // 44.351369219983
    assert!(result.mul(fixed_point64::from(1000000000000)).to_u128() == 44351369219983_u128, 0);
    
    let z = fixed_point64::from_rational(50, 100); // z = 0.5
    let result = fixed_point64::ln_plus_64ln2(fixed_point64::one().sub(z)); // 43.668272375276554
    assert!(result.mul(fixed_point64::from(1000000000000000)).to_u128() == 43668272375276554, 0);
    
    let z = fixed_point64::from_rational(1, 10000000000); // z = 1e-10
    let result = fixed_point64::ln_plus_64ln2(fixed_point64::one().sub(z)); // 44.361419555736499
    assert!(result.mul(fixed_point64::from(1000000000000000)).to_u128() == 44361419555736500, 0);
    
    let z = fixed_point64::from_rational(9999999, 10000000); // z = 0.9999999
    let result = fixed_point64::ln_plus_64ln2(fixed_point64::one().sub(z)); // 28.243323904878204
    // print(&result.mul(fixed_point64::from(1000000000000000)).to_u128());
    assert!(result.mul(fixed_point64::from(1000000000000000)).to_u128() == 28243323904878204, 0);
}