import math
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d import Axes3D
from matplotlib.animation import FuncAnimation
import IPython.display
from IPython.display import HTML

from dynamic_amm import *


# Test function returning a pandas DataFrame with initial reserves
def swap_x_to_y_sensitivity(reserve_x=2.0, reserve_y=100.0, price_x=1.0, price_y=1.0, x_amounts=None):
    """
    Test the AMM swap for various amounts of Y and return results in a DataFrame.
    :param reserve_x: Initial reserve of X
    :param reserve_y: Initial reserve of Y
    :param oracle_price: Oracle price (X per Y)
    :param y_amounts: List of Y amounts to test; if None, use default range
    :return: pandas DataFrame with swap results
    """

    oracle_price = price_x / price_y
    # Default Y amounts to test (e.g., 1 to 50 in steps)
    if x_amounts is None:
        x_amounts = [1.0, 5.0, 10.0, 20.0, 30.0, 40.0, 50.0]
    
    # Lists to store results
    data = {
        "Initial_Reserve_X": [],
        "Initial_Reserve_Y": [],
        "Amount_X": [],
        "Delta_Y": [],
        "New_Reserve_X": [],
        "New_Reserve_Y": [],
        "Effective_Price": [],
        "Slippage_Percent": []
    }
    
    for amount_x in x_amounts:
        try:
            # Calculate required X
            delta_y = swap_x_to_y_volatile(amount_x, reserve_x, reserve_y, price_x, price_y)
            
            # New reserves
            new_reserve_x = reserve_x + amount_x
            new_reserve_y = reserve_y - delta_y
            
            # Effective price (average price paid)
            effective_price = amount_x / delta_y if amount_x > 0 else 0
            
            # Slippage as percentage
            slippage = (effective_price - oracle_price) / oracle_price * 100 if oracle_price > 0 else 0
            
            # Append to data
            data["Initial_Reserve_X"].append(reserve_x)
            data["Initial_Reserve_Y"].append(reserve_y)
            data["Amount_X"].append(amount_x)
            data["Delta_Y"].append(delta_y)
            data["New_Reserve_X"].append(new_reserve_x)
            data["New_Reserve_Y"].append(new_reserve_y)
            data["Effective_Price"].append(effective_price)
            data["Slippage_Percent"].append(slippage)
            
        except ValueError as e:
            print(f"Error for Amount X = {amount_x}: {e}")
            break
    
    # Create DataFrame
    df = pd.DataFrame(data)
    print(f"\nScenario: Initial Reserves X = {reserve_x}, Y = {reserve_y}, Oracle Price = {oracle_price}")
    return df

# Function to compute slippage for a grid of reserve_y_percent and amount_x
def compute_slippage_surface(
    y_percent_range,
    x_amount_range,
    total_reserve=100.0,
    price_x=1.0,
    price_y=1.0,
):
    """
    Compute slippage for varying reserve Y percentage and X amounts.
    :param total_reserve: Total reserve (X + Y)
    :param oracle_price: Oracle price (X per Y)
    :param y_percent_range: Array of Y reserve percentages (0 to 0.999)
    :param x_amount_range: Array of X amounts to swap
    :return: 2D array of slippage values
    """
    
    # Create meshgrid: X is amount_x, Y is y_percent
    Amount_X, Y_percent = np.meshgrid(x_amount_range, y_percent_range)
    Slippage = np.zeros_like(Amount_X)

    oracle_price = price_x / price_y
    
    for i in range(Amount_X.shape[0]):
        for j in range(Amount_X.shape[1]):
            reserve_y = Y_percent[i, j] * total_reserve
            reserve_x = total_reserve - reserve_y
            amount_x = Amount_X[i, j]

            delta_y = swap_x_to_y_volatile(amount_x, reserve_x, reserve_y, price_x, price_y)
            if delta_y > 0:  # Avoid division by zero
                effective_price = amount_x / delta_y  # X per Y

                slippage = (effective_price - oracle_price) / oracle_price * 100
                #print("Reserve Y: ", reserve_y, ", Reserve X: ", reserve_x, ", Effective Price: ", effective_price, ", Slippage: ", slippage)
                Slippage[i, j] = slippage
            else:
                Slippage[i, j] = 0.0  # No slippage if no Y received
    
    return Amount_X, Y_percent, Slippage

# Generate data and plot
def plot_3d_surface(x_amount_range = None, y_percent_range = None):
    # Parameters
    total_reserve = 100.0
    price_x = 1.0
    price_y = 1.0
    
    # Compute slippage surface
    if y_percent_range is None:
        y_percent_range = np.linspace(0.001, 0.999, 50)  # Avoid 0 and 1
    if x_amount_range is None:
        x_amount_range = np.linspace(0.05, 100.0, 50)  # Range of X amounts

    Amount_X, Y_percent, Slippage = compute_slippage_surface(y_percent_range, x_amount_range, total_reserve, price_x, price_y)
    
    # Create 3D plot
    fig = plt.figure(figsize=(10, 8))
    ax = fig.add_subplot(111, projection='3d')
    
    # Plot surface
    surf = ax.plot_surface(Amount_X, Y_percent, Slippage, cmap='viridis', edgecolor='none')
    
    # Labels and title
    ax.set_xlabel('Amount X Sold')
    ax.set_ylabel('Reserve Y (% of Total)')
    ax.set_zlabel('Slippage (%)')
    ax.set_title('Slippage on a swap X-to-Y')
    
    # Add color bar
    fig.colorbar(surf, ax=ax, shrink=0.5, aspect=5)
    
    # Adjust view angle for better visibility
    #ax.view_init(elev=30, azim=135)

    ax.view_init(elev=30, azim=150)  # Lower elevation, different azimuth
    
    plt.show()


def render_3d_surface(x_amount_range=None, y_percent_range=None):
    # Parameters
    total_reserve = 100.0
    price_x = 1.0
    price_y = 1.0
    
    # Compute slippage surface
    if y_percent_range is None:
        y_percent_range = np.linspace(0.001, 0.999, 50)  # Avoid 0 and 1
    if x_amount_range is None:
        x_amount_range = np.linspace(0.05, 100.0, 50)  # Range of X amounts

    Amount_X, Y_percent, Slippage = compute_slippage_surface(y_percent_range, x_amount_range, total_reserve, price_x, price_y)
    
    # Create 3D plot
    fig = plt.figure(figsize=(10, 8))
    ax = fig.add_subplot(111, projection='3d')
    
    # Plot surface
    surf = ax.plot_surface(Amount_X, Y_percent, Slippage, cmap='viridis', edgecolor='none')
    
    # Labels and title
    ax.set_xlabel('Amount X Sold')
    ax.set_ylabel('Reserve Y (% of Total)')
    ax.set_zlabel('Slippage (%)')
    ax.set_title('Slippage on a swap X-to-Y')
    
    # Add color bar
    fig.colorbar(surf, ax=ax, shrink=0.5, aspect=5)
    
    # Adjust view angle for better visibility
    #ax.view_init(elev=30, azim=135)

    ax.view_init(elev=30, azim=-80)  # Lower elevation, different azimuth

    # Animation function
    def update(frame):
        ax.view_init(elev=30, azim=frame)
        return surf,

    # Create animation
    anim = FuncAnimation(fig, update, frames=np.arange(0, 360, 5), interval=100, blit=False)
    print("Animation object created")  # Debug to confirm creation
    
    # Explicitly display the animation
    #plt.show()
    #IPython.display.display(fig)  # Ensure figure is rendered
    
    # Display animation as HTML5 video
    return HTML(anim.to_jshtml())

def compute_2d_slippage_plot(
    y_percent_range,
    x_amount_range,
    total_reserve=100.0,
    price_x=1.0,
    price_y=1.0,
):
    """
    Compute slippage for varying reserve Y percentage and X amounts.
    :param total_reserve: Total reserve (X + Y)
    :param oracle_price: Oracle price (X per Y)
    :param y_percent_range: Array of Y reserve percentages (0 to 0.999)
    :param x_amount_range: Array of X amounts to swap
    :return: 2D array of slippage values
    """
    
    # Create meshgrid: X is amount_x, Y is y_percent
    Amount_X, Y_percent = np.meshgrid(x_amount_range, y_percent_range)
    Slippage = np.zeros_like(Amount_X)

    oracle_price = price_x / price_y
    
    for i in range(Amount_X.shape[0]):
        for j in range(Amount_X.shape[1]):
            reserve_y = Y_percent[i, j] * total_reserve
            reserve_x = total_reserve - reserve_y
            amount_x = Amount_X[i, j]

            delta_y = swap_x_to_y_volatile(amount_x, reserve_x, reserve_y, price_x, price_y)
            if delta_y > 0:  # Avoid division by zero
                effective_price = amount_x / delta_y  # X per Y

                slippage = (effective_price - oracle_price) / oracle_price * 100
                #print("Reserve Y: ", reserve_y, ", Effective Price: ", effective_price, ", Slippage: ", slippage)
                Slippage[i, j] = slippage
            else:
                Slippage[i, j] = 0.0  # No slippage if no Y received
    
    return Amount_X, Y_percent, Slippage


def plot_2d_slippage():
    # Parameters
    total_reserve = 100.0
    price_x = 2.0
    price_y = 1.0
    fixed_amount_x = 10.0  # Fixed X amount for 2D plot
    y_percent_range = np.linspace(0.01, 0.999, 100)  # Avoid 0 and 1
    x_amount_range = np.array([fixed_amount_x])  # Single value for 2D
    
    # Compute slippage surface
    Amount_X, Y_percent, Slippage = compute_2d_slippage_plot(
        y_percent_range, x_amount_range, total_reserve, price_x, price_y
    )
    
    # Extract 1D slice for fixed amount_x (first column since x_amount_range is single-valued)
    slippage_1d = Slippage[:, 0]
    y_percent_1d = y_percent_range * 100  # Convert to percentage
    
    # Create 2D plot
    plt.figure(figsize=(10, 6))
    plt.plot(y_percent_1d, slippage_1d, label=f'Amount X = {fixed_amount_x}')
    
    # Labels and title
    plt.xlabel('Reserve Y (% of Total)')
    plt.ylabel('Slippage (%)')
    plt.title('Slippage vs Reserve Y Percentage (Fixed X Amount)')
    plt.grid(True)
    plt.legend()
    
    plt.show()
