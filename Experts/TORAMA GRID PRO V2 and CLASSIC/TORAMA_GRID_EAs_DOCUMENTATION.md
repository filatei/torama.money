# TORAMA GRID EAs - COMPLETE DOCUMENTATION

## Overview

Two professional grid trading Expert Advisors designed for different trading strategies:

1. **ToramaGrid_Pro_v2** - Bidirectional hedging grid for trending markets
2. **ToramaGrid_Classic** - Unidirectional grid for directional trading

---

## 1. TORAMA GRID PRO V2 (ToramaGrid_Pro_v2.mq5)

### Strategy Concept
**Hedging Grid Strategy** - Opens positions in BOTH directions (BUY above reference, SELL below reference) to profit from trending markets where one side dominates.

### Key Features
✅ **Bidirectional Grid** - Opens BUYs above reference price, SELLs below
✅ **Optional Individual TP** - Each position can close at individual TP (% of gap)
✅ **Global TP** - Closes all positions when combined profit reaches target
✅ **Max Positions Per Side** - Limits maximum BUYs and SELLs separately
✅ **Drawdown Protection** - Stops trading at 20% drawdown (default)
✅ **No "Take All Profits" Button** - Removed as requested

### How It Works
```
Reference Price: 1.1000
Gap: 0.5% = 0.0055

SELL positions open at:
1.1055 (reference + 1 gap)
1.1110 (reference + 2 gaps)
1.1165 (reference + 3 gaps)
...up to Max Positions Per Side

BUY positions open at:
1.0945 (reference - 1 gap)
1.0890 (reference - 2 gaps)
1.0835 (reference - 3 gaps)
...up to Max Positions Per Side
```

### When It Profits
- **Uptrend**: Opens 20 BUYs, 5 SELLs → BUYs profit heavily → Global TP reached
- **Downtrend**: Opens 20 SELLs, 5 BUYs → SELLs profit heavily → Global TP reached
- **Ranging**: Both sides oscillate, individual TPs close winning positions

### Input Parameters

#### Grid Settings
- **Gap Percentage**: 0.5% (distance between grid levels as % of price)
- **Base Lot Size**: 0.01 (standard lot size for each position)
- **Max Positions Per Side**: 20 (maximum BUYs and maximum SELLs)

#### Risk Management
- **Global Take Profit**: $100 (closes ALL positions when reached)
- **Max Drawdown %**: 20% (stops trading to protect capital)
- **Individual TP % of Gap**: 0.0 (default disabled, set to 100 for 1 gap TP)

#### EA Settings
- **Magic Number**: 0 (uses ChartID, change to separate multiple instances)
- **Trade Comment**: "ToramaGridPro"

### Individual TP Feature
When `Individual TP % of Gap` > 0:
- Each position gets its own TP
- 100% = TP at 1 full gap distance
- 50% = TP at half gap distance
- Example: Gap = $50, Individual TP = 100% → TP = $50 away

**Benefits:**
- Locks in profits from winning positions
- Reduces exposure as market moves
- Works alongside Global TP

### Risk Characteristics
- **Best for**: Trending news events, breakouts
- **Risk Level**: Medium-High (bidirectional exposure)
- **Capital Requirements**: Higher margin needed for multiple positions
- **Max Drawdown**: Can be significant in choppy markets

### Usage Tips
1. **Enable Individual TP** (100-200% of gap) during volatile periods
2. Use **lower Max Positions** (5-10) on smaller accounts
3. Set **realistic Global TP** based on account size ($50-$100 per $10k)
4. Monitor **Net Position** in panel - shows market bias
5. **Reset Reference** after major price moves

---

## 2. TORAMA GRID CLASSIC (ToramaGrid_Classic.mq5)

### Strategy Concept
**True Unidirectional Grid** - Classic grid trading that buys on dips (BUY ONLY) or sells on rallies (SELL ONLY) with individual TPs.

### Key Features
✅ **Direction Control** - Choose BUY ONLY or SELL ONLY
✅ **Individual TP Required** - Every position has TP (% of gap)
✅ **Optional Individual SL** - Set SL as % of gap (0 = disabled)
✅ **Global TP Option** - Additional safety net (can be disabled)
✅ **Lower Drawdown Risk** - Single direction = less exposure

### How It Works

#### BUY ONLY Mode (Buy the dips)
```
Reference Price: 1.1000
Gap: 0.5% = 0.0055

BUY positions open at:
1.0945 (reference - 1 gap) with TP at 1.1000 (+1 gap)
1.0890 (reference - 2 gaps) with TP at 1.0945 (+1 gap)
1.0835 (reference - 3 gaps) with TP at 1.0890 (+1 gap)
...

As price rises, positions close at TP
As price falls, more BUYs open
```

#### SELL ONLY Mode (Sell the rallies)
```
Reference Price: 1.1000
Gap: 0.5% = 0.0055

SELL positions open at:
1.1055 (reference + 1 gap) with TP at 1.1000 (-1 gap)
1.1110 (reference + 2 gaps) with TP at 1.1055 (-1 gap)
1.1165 (reference + 3 gaps) with TP at 1.1110 (-1 gap)
...

As price falls, positions close at TP
As price rises, more SELLs open
```

### When It Profits
- **BUY ONLY**: Profits in uptrends and ranging markets (buy low, sell high)
- **SELL ONLY**: Profits in downtrends and ranging markets (sell high, buy low)
- Individual TPs lock in profits at each grid level

### Input Parameters

#### Grid Direction
- **Grid Direction**: BUY_ONLY or SELL_ONLY (choose market expectation)

#### Grid Settings
- **Gap Percentage**: 0.5% (distance between grid levels)
- **Base Lot Size**: 0.01 (standard lot size)
- **Max Positions**: 10 (total grid positions allowed)

#### Take Profit Settings
- **Individual TP % of Gap**: 100.0 (100 = TP at 1 full gap, 200 = 2 gaps)
- **Global Take Profit**: $50 (closes all positions, 0 = disabled)

#### Stop Loss Settings
- **Individual SL % of Gap**: 0.0 (0 = disabled, 100 = SL at next grid back)

#### Risk Management
- **Max Drawdown %**: 20% (stops trading and closes positions)

#### EA Settings
- **Magic Number**: 0 (uses ChartID)
- **Trade Comment**: "ToramaClassic"

### Individual TP/SL Explained

#### Individual TP (Required)
- **100%**: TP at 1 full gap distance (standard grid behavior)
- **200%**: TP at 2 gaps (wait for bigger moves)
- **50%**: TP at half gap (quick profits)

Example: Gap = $50
- TP 100% = $50 profit target per position
- TP 200% = $100 profit target per position

#### Individual SL (Optional)
- **0%**: No SL (positions only close at TP or Global TP)
- **100%**: SL at next grid level backward (limits loss per position)
- **50%**: SL at half gap backward (tighter stop)

Example: Gap = $50, SL = 100%
- BUY at 1.0900 with SL at 1.0850 (next grid level)
- Limits maximum loss if trend reverses

### Risk Characteristics
- **Best for**: Ranging markets, mean reversion strategies
- **Risk Level**: Low-Medium (single direction)
- **Capital Requirements**: Lower margin than bidirectional
- **Max Drawdown**: More predictable and controlled

### Usage Tips
1. **BUY ONLY**: Use in uptrends or support zones
2. **SELL ONLY**: Use in downtrends or resistance zones
3. Set **Individual TP = 100%** for standard grid behavior
4. Enable **Individual SL = 100%** for volatile markets
5. Use **Global TP** as a "take profit and reset" target
6. **Lower Max Positions** (5-7) for small accounts
7. **Reset Reference** when market structure changes

---

## COMPARISON TABLE

| Feature | ToramaGrid Pro V2 | ToramaGrid Classic |
|---------|-------------------|-------------------|
| **Direction** | Bidirectional | Unidirectional |
| **Strategy** | Hedge both sides | Classic grid |
| **Best For** | Trending markets | Ranging markets |
| **Risk Level** | Medium-High | Low-Medium |
| **Individual TP** | Optional | Required |
| **Individual SL** | No | Optional |
| **Global TP** | Required | Optional |
| **Max Positions** | Per side (20+20) | Total (10) |
| **Margin Need** | Higher | Lower |
| **Complexity** | Advanced | Beginner-friendly |

---

## RISK MANAGEMENT GUIDELINES

### Capital Allocation
- **$1,000**: Use 0.01 lots, Max 5 positions
- **$5,000**: Use 0.01-0.02 lots, Max 10 positions
- **$10,000**: Use 0.02-0.05 lots, Max 15-20 positions

### Gap Size Selection
- **Forex Major Pairs**: 0.3% - 0.5%
- **Forex Minor Pairs**: 0.5% - 1.0%
- **Crypto (BTC, ETH)**: 1.0% - 2.0%
- **Gold (XAUUSD)**: 0.5% - 1.0%

### Drawdown Protection
- Both EAs stop at 20% drawdown (default)
- Adjust based on risk tolerance (10% conservative, 30% aggressive)
- Monitor margin levels - keep above 300%

---

## INSTALLATION

1. Copy `.mq5` files to: `MetaTrader 5/MQL5/Experts/`
2. Restart MT5 or compile in MetaEditor
3. Attach to chart and configure inputs
4. Enable AutoTrading button

---

## TESTING RECOMMENDATIONS

### Backtest Settings
- **Timeframe**: M15 or H1
- **Period**: 6-12 months minimum
- **Spread**: Include realistic spread
- **Commission**: Include broker commission
- **Initial Deposit**: Match real account size

### Forward Test
1. Test on demo for 2-4 weeks
2. Monitor all statistics in panel
3. Verify Global TP triggers correctly
4. Check Individual TPs close properly
5. Ensure drawdown protection works

---

## KEY DIFFERENCES FROM ORIGINAL

### ToramaGrid_Pro_v2 Fixes:
1. ✅ **Removed "Take All Profits" button** - No more orphaned losers
2. ✅ **Added Individual TP option** - Each position can take profit
3. ✅ **Max Positions Per Side** - Limits exposure per direction
4. ✅ **Improved tolerance** - 10% of gap for level detection
5. ✅ **Better panel display** - Shows Individual TP status
6. ✅ **Drawdown default 20%** - More conservative risk limit

### ToramaGrid_Classic Features:
1. ✅ **Direction switch** - BUY ONLY or SELL ONLY mode
2. ✅ **Required Individual TP** - Classic grid behavior
3. ✅ **Optional Individual SL** - Risk control per position
4. ✅ **Optional Global TP** - Can be disabled (set to 0)
5. ✅ **Cleaner logic** - No hedging complexity
6. ✅ **Lower margin needs** - Single direction trading

---

## SUPPORT

For questions or issues:
- Email: ea@torama.money
- Website: https://torama.money

---

**TORAMA CAPITAL**
*Professional Algorithmic Trading Solutions*
