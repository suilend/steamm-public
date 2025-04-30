import math
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D
from matplotlib.animation import FuncAnimation

def swap_x_to_y_volatile(amount_x, reserve_x, reserve_y, price_x, price_y, decimals_x = 0, decimals_y = 0):
    if amount_x <= 0:
        return 0.0
    
    p_o_raw = price_x / price_y    
    dec_pow = 10**(decimals_x - decimals_y)

    delta_y = reserve_y * (1 - np.exp(- (amount_x * p_o_raw) / (reserve_y * dec_pow)))
    if delta_y >= reserve_y:  # Prevent depletion
        return reserve_y * 0.999
    return delta_y

# Pricing function for swapping Y to X (returns amount X for given Y)
def swap_y_to_x_volatile(amount_y, reserve_x, reserve_y, price_x, price_y, decimals_x = 0, decimals_y = 0):
    if amount_y <= 0:
        return 0.0
    
    p_o_raw = price_x / price_y
    dec_pow = 10**(decimals_x - decimals_y)

    delta_x = reserve_x * (1 - np.exp(- (amount_y * dec_pow) / (reserve_x * p_o_raw)))
    if delta_x >= reserve_x:
        return reserve_x * 0.999
    return delta_x

def swap_x_to_y_stable(amount_x, reserve_x, reserve_y, price_x, price_y, decimals_x=0, decimals_y=0, A=10):
    if amount_x <= 0:
        return 0.0
    p_o_raw = price_x / price_y  # X per Y
    dec_pow = 10**(decimals_x - decimals_y)
    k = (amount_x * p_o_raw) / (reserve_y * dec_pow)  # Corrected: X * (X/Y) = Y units

    upper_bound_z = min(0.99999, amount_x * p_o_raw / (dec_pow * reserve_y))
    z = newton_raphson(k, A, upper_bound_z)

    #print("A: ", A, "Initial Z: ", upper_bound_z, "; k: ", k, "; Z = ", z, "RESULT ", (1 - 1/A) * z - (1/A) * np.log(1 - z) - k)
    
    delta_y = z * reserve_y
    if delta_y >= reserve_y:
        return reserve_y * 0.999
    return delta_y

def swap_y_to_x_stable(amount_y, reserve_x, reserve_y, price_x, price_y, decimals_x=0, decimals_y=0, A=10):
    if amount_y <= 0:
        return 0.0
    p_o_raw = price_x / price_y
    dec_pow = 10**(decimals_x - decimals_y)
    k = (amount_y * dec_pow) / (reserve_x * p_o_raw)
    
    upper_bound_z = min(0.99999, amount_y * dec_pow / (p_o_raw * reserve_x))
    z = newton_raphson(k, A, upper_bound_z)
    
    delta_x = z * reserve_x
    if delta_x >= reserve_x:
        return reserve_x * 0.999
    return delta_x


def newton_raphson(k, A, z_initial, tol=1e-10, max_iter=100):
    def f(z):
        return (1 - 1/A) * z - (1/A) * np.log(1 - z) - k
    
    def f_prime(z):
        return 1 - 1/A + 1/(A * (1 - z))
    
    # Improve initial guess
    if z_initial <= 0 or z_initial >= 1:
        #z_initial = max(1e-5, min(0.99999, k / (1 - 1/A)))
        z_initial = max(1e-5, min(0.999999999999999999, k / (1 - 1/A)))
    
    z = z_initial
    it = 0
    
    for ite in range(max_iter):
        it += 1
        fx = f(z)
        
        # Check convergence
        if abs(fx) < tol:
            break
            
        fp = f_prime(z)
        if abs(fp) < 1e-10:  # Avoid division by near-zero
            raise ValueError("Derivative near zero, Newton-Raphson failed")
        
        # Newton step with damping
        step = fx / fp
        alpha = 1.0
        z_new = z - alpha * step
        
        # Clamp to valid range
        if z_new <= 0 or z_new >= 1:
            alpha *= 0.5  # Reduce step size
            z_new = z - alpha * step
            #z_new = max(1e-5, min(0.99999, z_new))
            z_new = max(1e-5, min(0.999999999999999999, z_new))
        
        # Check if step is too small
        if abs(z_new - z) < tol:
            break
            
        z = z_new
    
    if it >= max_iter:
        print("Warning: Max iterations reached, may not have converged")

    return z

def get_slippage(amount_x, amount_y, price_x, price_y, decimals_x, decimals_y, direction):
    p_o = price_x / price_y

    
    if direction == "x2y":
        effective_price = (amount_x / 10**decimals_x) / (amount_y / 10**decimals_y)
        p_star = 1 / p_o
        slippage = (effective_price - p_star) / p_star
        #print("effective_price X2Y: ", effective_price)
        #print("midmarket price X2Y: ", p_star)

        return slippage
    elif direction == "y2x":
        effective_price = (amount_y / 10**decimals_y) / (amount_x / 10**decimals_x)
        #print("effective_price Y2X: ", effective_price)
        #print("midmarket price Y2X: ", p_o)
        slippage = (effective_price - p_o) / p_o

        return slippage
    else:
        raise ValueError("Invalid direction. Use 'x2y' or 'y2x'")

# Currently not being used
def runge_kutta(k, A, z_initial, tol=1e-10, max_iter=100, dt=0.1):
    def f(z):
        return (1 - 1/A) * z - (1/A) * np.log(1 - z) - k
    
    # Improve initial guess
    if z_initial <= 0 or z_initial >= 1:
        z_initial = max(1e-5, min(0.99999, k / (1 - 1/A)))
    
    z = z_initial
    it = 0
    
    for it in range(max_iter):
        # Check convergence
        if abs(f(z)) < tol:
            break
        
        # RK4 step for dz/dt = -f(z)
        k1 = -f(z)
        k2 = -f(max(1e-5, min(0.999999999999, z + 0.5 * dt * k1)))
        k3 = -f(max(1e-5, min(0.999999999999, z + 0.5 * dt * k2)))
        k4 = -f(max(1e-5, min(0.999999999999, z + dt * k3)))
        
        # Update z
        z_new = z + (dt / 6.0) * (k1 + 2 * k2 + 2 * k3 + k4)
        
        # Clamp to valid range
        #print(z_new)
        z_new = max(1e-5, min(0.999999999999, z_new))
        
        # Check if step is too small
        if abs(z_new - z) < tol:
            break
        
        z = z_new
    
    if it >= max_iter:
        print("Warning: Max iterations reached, may not have converged")
    
    print("RK4 iters: ", it)
    return z