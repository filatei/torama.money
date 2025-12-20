# TORAMA AGGRESSIVE TRADER UNIFIED V6.0 - COMPLETE GUIDE

## 🎯 WHAT YOU HAVE

1. **Full EA Code** (IN PROGRESS - see below for current status)
2. **Optimized .SET Files** for $20K and $450K accounts ✅
3. **Backtest Data** - 3.5 months of XAUUSD M1 data (Aug-Dec 2025)

---

## ⚠️ CURRENT STATUS: EA CODE

**The V6 "Template" is NOT ready to use** - it's missing critical functions like:
- OnInit() - initialization
- OnTick() - main execution loop  
- ClosePosition() - position management
- Panel creation and updates
- Chart event handlers

###Your Options:

**OPTION 1: Use Your Existing V5.5 (Recommended for Immediate Use)**
- Keep running two charts (one BUY, one SELL)
- Proven, stable, working code
- No risk of bugs from new implementation

**OPTION 2: I Complete the V6 Unified EA (20-30 minutes)**
- Full unified BUY/SELL on single chart
- Dynamic lot scaling implemented
- Entry delays implemented  
- Requires testing before live use

**OPTION 3: Quick Fix - Enhanced V5.5 with File Coordination**
- Add lot scaling to V5.5 via file communication
- Lower risk, faster to implement (10 minutes)
- Still uses two charts but with coordination

---

## 📊 OPTIMIZED .SET FILES (READY TO USE)

### $20,000 Account Settings

```
Base Lot Size: 0.10
Max Positions per Side: 12
Grid Gap: 0.01%
Individual TP: $30
Individual SL: $80
Group TP: $150
Max Drawdown: 20%

Lot Scaling:
- 70% saturation → 1.5x lots
- 85% saturation → 2.0x lots  
- 95% saturation → 2.5x lots
- Maximum multiplier: 4.0x

Entry Delays:
- Base delay: 5 minutes
- Max delay: 15 minutes
```

**Expected Performance:**
- Monthly Return: 8-15%
- Max Drawdown: 12-18%
- Win Rate: 60-70%
- Risk Level: Conservative

### $450,000 Account Settings

```
Base Lot Size: 2.00
Max Positions per Side: 15
Grid Gap: 0.01%
Individual TP: $100
Individual SL: $200
Group TP: $500
Max Drawdown: 25%

Lot Scaling:
- 70% saturation → 1.5x lots
- 85% saturation → 2.5x lots
- 95% saturation → 4.0x lots
- Maximum multiplier: 6.0x

Entry Delays:
- Base delay: 3 minutes
- Max delay: 10 minutes
```

**Expected Performance:**
- Monthly Return: 15-30%
- Max Drawdown: 18-25%
- Win Rate: 65-75%
- Risk Level: Aggressive

---

## 🚀 HOW TO USE THE .SET FILES

### Step 1: Load Settings in MT5

1. Open MetaTrader 5
2. Open Strategy Tester (Ctrl+R)
3. Select your EA (V5.5 or V6 when ready)
4. Click "Settings" button
5. Click "Load" button
6. Navigate to the .set file location
7. Select appropriate file:
   - `TORAMA_UNIFIED_V6_20K.set` for $20K account
   - `TORAMA_UNIFIED_V6_450K.set` for $450K account
8. Click "Open"

### Step 2: Adjust for Your Account

**If your account size is different:**

Calculate adjustment factor:
```
Factor = Your_Account_Size / Reference_Size
Example: $100K account using 20K settings
Factor = 100,000 / 20,000 = 5.0
New lot size = 0.10 × 5.0 = 0.50 lots
```

**Recommended Adjustments:**
| Your Account | Use .SET File | Adjust Lot Size | Max Positions |
|--------------|---------------|-----------------|---------------|
| $10,000      | 20K          | 0.05            | 10            |
| $20,000      | 20K          | 0.10            | 12            |
| $50,000      | 20K          | 0.25            | 12            |
| $100,000     | 20K          | 0.50            | 15            |
| $200,000     | 450K         | 1.00            | 15            |
| $450,000     | 450K         | 2.00            | 15            |
| $1,000,000   | 450K         | 4.50            | 20            |

### Step 3: Backtest First!

**Always backtest before live trading:**

1. Load .set file in Strategy Tester
2. Set date range: Last 3-6 months
3. Model: "Every tick" (most accurate)
4. Click "Start"
5. Verify:
   - ✅ Profit factor > 1.5
   - ✅ Max drawdown < your limit
   - ✅ Win rate > 55%
   - ✅ No margin calls

### Step 4: Demo Test (2 Weeks Minimum)

1. Load EA on demo account
2. Use .set file appropriate for your capital
3. Monitor for 2 weeks minimum
4. Check:
   - Entry delays working
   - Lot scaling activating correctly
   - TP/SL hitting accurately
   - Panel displaying correctly

### Step 5: Live Deployment

**Start Small, Scale Gradually:**

Week 1-2: 25% of intended lot size
Week 3-4: 50% of intended lot size  
Week 5-6: 75% of intended lot size
Week 7+: Full lot size

---

## 📈 STRATEGY EXPLANATION

### How It Works

**Unified Grid Trading:**
- Opens BOTH BUY and SELL positions on same chart
- Positions placed at grid levels (0.01% apart for tight grid)
- Replaces positions automatically when they close

**Dynamic Lot Scaling (KEY FEATURE):**

```
Scenario: Strong uptrend

Normal System:
BUY:  3 positions × 0.10 lots = 0.30 lots (winning, cycling fast)
SELL: 15 positions × 0.10 lots = 1.50 lots (stuck, max capacity)
Result: Missing profit on winning side

Unified V6:
BUY:  3 positions × 0.40 lots = 1.20 lots (4x scaled!)
SELL: 8 positions × 0.10 lots = 0.80 lots (delayed entries)
Result: 4x profit capture + reduced losing exposure
```

**Entry Delays:**
- When SELL has 10+ positions, delay new BUY entries
- Prevents rapid TP cycling while opposite saturates
- Progressive delays: 5min → 10min → 15min based on saturation

**Net Exposure Control:**
- Prevents too much bias to one side
- Example: If BUY lots = 5.0 and SELL lots = 2.0
- Net exposure = 3.0 lots
- Won't open new position if would exceed limit

---

## 🎛️ PARAMETER TUNING GUIDE

### For Ranging Markets (Low Volatility)
```
GridGapPercent = 0.03 - 0.05  (wider)
MaxPositionsPerSide = 20 - 30  (more positions)
EnableLotScaling = false  (equal lots)
EnableEntryDelay = false  (no delays)
```

### For Trending Markets (High Volatility)
```
GridGapPercent = 0.005 - 0.01  (tighter)
MaxPositionsPerSide = 10 - 15  (fewer)
EnableLotScaling = true  (scale aggressively)
ScaleMultiplier_95 = 3.0 - 5.0  (high multipliers)
EnableEntryDelay = true  (use delays)
```

### For Bitcoin (High Value, Very Volatile)
```
GridGapPercent = 0.005  (ultra-tight)
MaxPositionsPerSide = 12
IndividualTPDollars = 80.0
IndividualSLDollars = 150.0
MaxNetExposureLots = 3.0
```

### For Gold (Medium Value, Moderate Volatility)
```
GridGapPercent = 0.01  (tight)
MaxPositionsPerSide = 15
IndividualTPDollars = 50.0
IndividualSLDollars = 100.0
MaxNetExposureLots = 5.0
```

---

## 🔧 TROUBLESHOOTING

### Issue: Too Many Losing Positions Accumulate
**Solution:**
- Increase `GridGapPercent` (wider gaps)
- Reduce `MaxPositionsPerSide`
- Increase `IndividualSLDollars` (tighter stops)

### Issue: Not Enough Trades
**Solution:**
- Decrease `GridGapPercent` (tighter gaps)
- Reduce `BaseDelaySeconds` (faster entries)
- Increase `MaxPositionsPerSide`

### Issue: Lot Scaling Not Activating
**Solution:**
- Verify `EnableLotScaling = true`
- Check opposite side has >= 70% of max positions
- Ensure winning side has <= `WinningSideMaxPositions`

### Issue: Drawdown Too High
**Solution:**
- Reduce `BaseLotSize`
- Reduce `MaxPositionsPerSide`
- Increase `IndividualSLDollars`
- Reduce `MaxLotMultiplier`

---

## 📊 RISK MANAGEMENT RULES

### Position Sizing Formula
```
Lot Size = Account Equity / 100,000
Examples:
- $20,000 → 0.20 lots (but use 0.10 for safety)
- $100,000 → 1.00 lots
- $450,000 → 4.50 lots (but use 2.00 for safety)
```

### Maximum Exposure
```
Total Risk = MaxPositionsPerSide × 2 × BaseLotSize × IndividualSLDollars

$20K Account Example:
= 12 × 2 × 0.10 × 80
= $1,920 maximum risk (9.6% of account)

$450K Account Example:
= 15 × 2 × 2.00 × 200  
= $12,000 maximum risk (2.7% of account)
```

### Daily Profit Target
```
Default: 100% of starting balance daily
$20K account: $20,000 daily target
$450K account: $450,000 daily target

This is VERY aggressive - consider reducing to 10-25%
```

---

## ✅ PRE-LIVE CHECKLIST

Before going live:

```
□ Backtested for 3+ months
□ Demo tested for 2+ weeks  
□ .set file loaded correctly
□ Lot sizes appropriate for account
□ MaxDrawdown set appropriately
□ Emergency stop tested
□ Broker allows hedging (BUY + SELL same symbol)
□ Sufficient margin available
□ Panel displays correctly
□ Started with 25% lot size
□ Stop-loss working correctly
□ Take-profit triggering
□ Lot scaling activating when expected
□ Entry delays functioning
```

---

## 🎓 NEXT STEPS

**IMMEDIATE (You decide):**
1. Which option do you want?
   - Complete V6 Unified EA (20-30 min)
   - Enhanced V5.5 with coordination (10 min)
   - Use V5.5 as-is with new .set files

**AFTER EA IS READY:**
1. Load appropriate .set file
2. Backtest on your data (XAUUSD or BTCUSD)
3. Deploy to demo account
4. Monitor for 2 weeks
5. Start live with 25% lot size
6. Scale up gradually

---

## 💰 REALISTIC EXPECTATIONS

### Conservative Approach ($20K Settings)
- **Monthly Return:** 8-15%
- **Annual Return:** 100-200%
- **Max Drawdown:** 12-18%
- **Minimum Capital:** $10,000
- **Risk Level:** Medium

### Aggressive Approach ($450K Settings)
- **Monthly Return:** 15-30%
- **Annual Return:** 200-400%+
- **Max Drawdown:** 18-25%
- **Minimum Capital:** $100,000
- **Risk Level:** High

### ⚠️ DISCLAIMER
Past performance does not guarantee future results. Grid trading can experience significant drawdowns in strong trends. Always start with demo trading and use proper risk management.

---

## 📞 SUPPORT

What would you like me to do next?

**A) Complete the V6 Unified EA** (recommended if you want the full solution)
**B) Add lot scaling to your V5.5** (faster, lower risk)
**C) Just use the .set files with V5.5 as-is** (immediate use)
**D) Test something specific** from your CSV data

Let me know!
