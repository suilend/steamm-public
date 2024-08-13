# Suilend AMM

## Introduction

Suilend AMM is a hooks-based Automated Market Marker protocol specialised in liquidity reutilisation and extensibility of quotation systems.

- Hook-based AMM which allows to plug-in different types of swap quotation systems (hooks) on top of the base implementation;
- The protocol has a shared liquidity utilisation model, in which AMM pools deposit and withdraw their liquidity in banks, and banks in turn are responsible for deploying and recalling liquidity to Suilend (which is a lending market);

## Hooks Model
By introducing hooks, the protocol allows for the plugin of multiple quotation systems, as well as innovative features surrounding liquidity management. Currently the protocol has three quotation built-in: a Constant-Product AMM; a Fixed-Range Constant Sum AMM; and an Oracle AMM with dynamic fees based on volatility.

To initiate a pool, the base pool module provides a generator function to be used by the hook modules, in otder to construct the pool. This function allows the hook to plug-in its custom state.

Similarly, the base module makes the core swap function available to the hooks, the hooks themselves are then responsible for re-exporting the swap functionality to the client. This way, hooks can apply logic before and after the base logic of the pool is executed.


## Liquidity Reutilisation Model
One core feature of the protocol is the liquidity reutilisation. In traditional AMM designs, liquidity is locked in the pool and it remains idle until used to fulfil a swap. Even throughout trading activity only a portion of the liquidity gets utilised, whereas the majority of liquidity sits idle in contigency.

Suilend's AMM works by pulling liquidity from AMMs together into a Bank, which is then deployed to Suilend' lending markets. This reduces LP's opportunity costs by allowing them earn an extra yield on the liquidity provided.

<img src="assets/d1.svg" alt="Alt text" style="width:50%;">

Banks work by pulling liquidity from a given coin type and allocate a portion of that liquidity to the lending markets, thus earning some yield. By pulling liquidity together, AMM pools are able to fulfil their swap commitments by tapping into global net liquidity available in the respective banks, thus limiting the amount of times liquidity has to be recalled from the lending markets.

As an ilustration, if one AMM pool has high demand for SUI (i.e. high volume of swaps that extract SUI from the pool), and another has high supply of SUI (i.e. high volume of swaps that add SUI to the pool), to a great degree these flows willl offset each other.

In other words, in periods of low market correlations, offsetting flows take place, whereas in periods of high market correlations there's a higher necessity in recalling liquidity from lending markets.

### Utilisation Target and Buffer
Banks are setup with a target utilisation rate. Liquidity deployed to lending market is allowed to fluctuate around the target utilisation rate and the extent to which these fluctuations can deviate form the target is kept by a utilisation buffer. So if the target utilisation is set at 50% with a utilisation buffer of 5%, then utilised liquidity is allowed to fluctuate between 45% and 55%.

<img src="assets/utilisation.svg" alt="Alt text" style="width:40%;">

These parameter are set by the global admin when lending is initialised, however these can be technically updated dynamically, leaving the door open to strategies that manage utilisation based on market conditions such as volatility and order flow.


### Swap model

Given that a swap is constituted by an inflow and a corresponding outflow, a provisioning action takes place before the swap is executed, in order to guarantee that the pool has access to a sufficient amount of funds it needs to fulfil the outflow, as well as a posterior action which rebalances the liquidity coming in from the inflow.

<img src="assets/swap.svg" alt="Alt text" style="width:50%;">


The swap model follows an intent/execute patern where traders start by formalising an intent to swap with a given pool. During the intent process the pool formulates a quote. The intent object itself is a wrapper around a quote, which its creation signals to the pool that a swap is about to take please.

The core reason behind breaking the swap into this pattern is to allow the banks provision enough liquidity to fulfil the swap. The flow is as follows:

1. Intent swap: Pool provides a quotation via `hook_xyz::intent_swap`
2. Based on the intent object, banks provision liquidity as needed
3. Swap is executed `hook_xyz::execute_swap`
4. Optionally rebalance the utilisation of the bank receiving the inflow

<img src="assets/swap_intent.svg" alt="Alt text" style="width:50%;">

### Liquidity Providers

Pertaining to the deposit and withdraw of liquidity by the LPs, the flow is rather straigthforward.

When depositing liquidity, the respective banks will optionally deploy extra liquidity to the lending markets to guarantee that utilisation bounds are met.

<img src="assets/deposit-2.svg" alt="Alt text" style="width:50%;">

Conversely, when redeeming liquidity, we check if the outflows can be met and if the banks utilisation remains within the bounds defined, and if not the banks will recall the required liquidity from the lending markets.

<img src="assets/withdraw-2.svg" alt="Alt text" style="width:50%;">



TODO...

### Risks and mitigations

- intents function as are wright-only locks
- swap dos when utilisation is high on the bank side and lending market side


...
- Instead of having denial of service if utilisation is high we could offer for the user to redeem ctokens instead of the token and let the user redeem the funds once utilisation is back to normal..
- The SDK is responsible for composing the transaction on the swap side and therefore know if we need to sync the bank or not
- How does the design avoid constant deposits and withdraws from the lending market, making the lending market bumpy? Two things, one is the sharing of liquidity offsets USDC demand from some pools with USDC supply from other pools and vice versa; two is that we can choose widened liquidity buffer such that effective liquidity is allowed to fluctuate within a wide range, thus requiring to touch lending market less often
- Bug spillover risk of a pool/hook to another, funds from other pools cannot be at risk, due to separation of liquidity. If a bug makes funds from one hook drainable they can’t impact the funds from other hooks.. each pool is segregated in the amount of liquidity they can pool even though the they shared liquidity in the bank
- We use static typing instead of dynamic typing because it is more performant
- We avoid using dynamic fields to be more performant
- Cpmm invariant can the hook check the invariant after the swap inner logic?
- Responsibilities of each module, swap inner, fees, quotation logic
- How similar is it to uniswap v4
- Can our hooks support limit orders? Discussed limit orders from Jupyter, toxic oder flow, sudo limit order in that it only hits after, as a tail transaction