# GOLD/SILVER MOMENTUM REVERSION EA - USER GUIDE

**TORAMA CAPITAL**  
**Expert Advisor Version 1.00**  
Contact: ea@torama.money | Website: torama.money

---

## TABLE OF CONTENTS

1. [Strategy Overview](#strategy-overview)
2. [Installation & Setup](#installation--setup)
3. [Understanding the Panel](#understanding-the-panel)
4. [Parameter Guide](#parameter-guide)
5. [Trading Logic Explained](#trading-logic-explained)
6. [Preset Configurations](#preset-configurations)
7. [Optimization Guide](#optimization-guide)
8. [Risk Management](#risk-management)
9. [Troubleshooting](#troubleshooting)

---

## STRATEGY OVERVIEW

### **Core Concept**
The Gold/Silver Momentum Reversion EA identifies sharp momentum moves on H1 timeframe, waits for reversal confirmation on M5, then enters with aggressive trailing stop management. The strategy is designed to capture mean reversion after overextension while protecting capital through immediate break-even moves.

### **Key Features**
✓ **Multi-Timeframe Analysis**: H4/D1 for trend, H1 for setup, M5/M15 for entry  
✓ **Single Position Focus**: Only one trade at a time for precise management  
✓ **Aggressive Trailing**: Move to BE at +15 pips, trail thereafter  
✓ **Smart Filters**: Bollinger Bands, EMA, ATR volatility checks  
✓ **Professional Panel**: Real-time stats with TORAMA CAPITAL branding  
✓ **Works on Both**: Optimized for Gold (XAUUSD) and Silver (XAGUSD)  

### **Trading Philosophy**
**"Trail to Win or Break-Even"** - Every trade aims for significant profit through trailing, but protects capital by moving to break-even quickly. This approach maximizes win potential while minimizing risk exposure.

---

## INSTALLATION & SETUP

### **Step 1: Files Preparation**
You have received:
- `GoldSilver_MomentumReversion_EA.mq5` - Main EA file
- `GoldSilver_XAUUSD_Balanced.set` - Gold settings
- `GoldSilver_XAGUSD_Balanced.set` - Silver settings

### **Step 2: Install EA**
1. Open MetaTrader 5
2. Click **File → Open Data Folder**
3. Navigate to **MQL5 → Experts**
4. Copy `GoldSilver_MomentumReversion_EA.mq5` here
5. Open MetaEditor (F4) and compile the file (F7)
6. Verify "0 errors" in compilation log

### **Step 3: Install Settings Files**
1. From MT5 Data Folder, go to **MQL5 → Presets**
2. Copy both `.set` files here
3. These will be available when you attach the EA

### **Step 4: Attach to Chart**

**For Gold Trading:**
1. Open XAUUSD chart
2. Set timeframe to M5 (for execution)
3. Drag EA from Navigator onto chart
4. Click **Load** button in EA settings
5. Select `GoldSilver_XAUUSD_Balanced.set`
6. Enable **AutoTrading** (toolbar button must be green)
7. Click **OK**

**For Silver Trading:**
1. Open XAGUSD chart
2. Set timeframe to M5
3. Attach EA and load `GoldSilver_XAGUSD_Balanced.set`
4. Enable AutoTrading
5. Click OK

### **Step 5: Verify Operation**
- Panel should appear on left side of chart
- Check **Experts** tab for initialization message
- Verify "Trend: [direction]" shows in panel
- Confirm "Ready to Trade" status appears

---

## UNDERSTANDING THE PANEL

The EA displays a comprehensive statistics panel with TORAMA CAPITAL branding:

### **Panel Sections Explained**

#### **1. ACCOUNT STATUS**
```
BAL: $10,000 | EQ: $10,150 | MAR: 0%
```
- **BAL (Balance)**: Account balance in bold
- **EQ (Equity)**: Current equity including floating P/L
- **MAR (Margin)**: Margin usage percentage (0% = no positions)

#### **2. PROFIT & LOSS**
```
Current P/L: $150.00
Daily P/L: $75.50
```
- **Current P/L**: Total unrealized + realized P/L
  - Green = Profit
  - Red = Loss
- **Daily P/L**: P/L for current trading day
  - Resets at midnight
  - Used for daily loss limit calculation

#### **3. TRADE STATISTICS**
```
Wins: 12 | Losses: 8 | BE: 5
Total Trades: 25 | Daily: 2/5
Win Rate: 48.0% | PF: 1.85
```
- **Wins/Losses/BE**: Trade outcomes
  - BE = Break-even trades (±$1)
- **Total/Daily Trades**: Lifetime and today's count
- **Win Rate**: Percentage of winning trades
- **PF (Profit Factor)**: Gross profit ÷ Gross loss

#### **4. MARKET CONDITIONS**
```
Trend: BULLISH
Spread: 2.3 | Lot: 0.50
Volatility: Normal | ATR: 1.25
```
- **Trend**: Multi-timeframe trend direction
  - BULLISH = Buy setups preferred
  - BEARISH = Sell setups preferred
  - NEUTRAL = Range-bound market
- **Spread**: Current spread in pips
- **Lot**: Current position size
- **Volatility**: Market activity level
  - Low/Normal/High based on ATR
- **ATR**: Average True Range in pips

#### **5. POSITION STATUS**
```
LONG @ 2045.50
Position P/L: $125.50 (25.0 pips)
Duration: 1h 35m | Next: Trail @ 30 pips
```
- **Position Type**: LONG (blue) or SHORT (red)
- **Entry Price**: Opening price level
- **Position P/L**: Current profit/loss
- **Duration**: Time position has been open
- **Next Action**: What happens next
  - "BE @ 15 pips" = Moving to break-even
  - "Lock @ 25 pips" = Locking profit
  - "Trail @ 30 pips" = Trailing activation
  - "Trailing Active" = Currently trailing

When no position:
```
No Open Position
Cooldown: 15 min remaining
```
or
```
Ready to Trade
```

#### **6. BRANDING (Bottom Right)**
```
TORAMA CAPITAL
ea@torama.money
```
Large, bold, white chalk-style branding

---

## PARAMETER GUIDE

### **STRATEGY SETTINGS**

**MomentumPips** (Default: 30 for Gold, 40 for Silver)
- Minimum pip movement on H1 to qualify as momentum
- Higher = fewer, higher-quality setups
- Lower = more opportunities, more noise
- *Gold: 25-35 pips*
- *Silver: 35-50 pips*

**ConfirmationCandles** (Default: 3)
- Number of consecutive M5 candles needed for confirmation
- 2 = Aggressive, faster entries
- 3 = Balanced (recommended)
- 4-5 = Conservative, fewer trades

**UseBollingerFilter** (Default: true)
- Buy when price near/below lower band
- Sell when price near/above upper band
- *Recommended: true*

**UseEMAFilter** (Default: true)
- Uses EMA20/50 on H1 for trend confirmation
- Helps avoid counter-trend trades
- *Recommended: true*

---

### **ENTRY FILTERS**

**MaxSpreadPips** (Default: 3.0 for Gold, 5.0 for Silver)
- Maximum allowed spread for entry
- Protects against poor execution
- *Gold: 2.5-3.5 pips*
- *Silver: 4.0-6.0 pips*

**MinATR_M15 / MaxATR_M15** (Default: 0.5 / 3.0 for Gold)
- Volatility range filter
- Avoids trading in dead or chaotic markets
- *Gold: 0.5-3.0*
- *Silver: 0.5-4.0*

**TradeOnlyTrending** (Default: true)
- Only trade in direction of H1/H4 trend
- Prevents counter-trend losses
- *Recommended: true*

---

### **STOP LOSS**

**InitialSL_Pips** (Default: 20 for Gold, 30 for Silver)
- Fixed stop loss distance
- Used if UseATRBasedSL = false
- *Gold: 15-25 pips*
- *Silver: 25-35 pips*

**UseATRBasedSL** (Default: true)
- Calculate SL based on current volatility
- More adaptive to market conditions
- *Recommended: true*

**ATR_SL_Multiplier** (Default: 1.5)
- Multiplier for ATR-based stop loss
- SL = ATR(14) × Multiplier
- 1.2 = Tight, 2.0 = Wide
- *Recommended: 1.5*

---

### **BREAK-EVEN & TRAILING (CRITICAL SECTION)**

**BreakEvenPips** (Default: 15 for Gold, 20 for Silver)
- Move SL to entry when this profit reached
- **KEY FEATURE**: Eliminates risk quickly
- *Gold: 12-20 pips*
- *Silver: 15-25 pips*

**ProfitLockPips** (Default: 25 for Gold, 35 for Silver)
- Lock in profit when reached
- Guarantees minimum win
- *Gold: 20-30 pips*
- *Silver: 30-45 pips*

**ProfitLockAmount** (Default: 10 for Gold, 15 for Silver)
- Amount of profit to lock (in pips)
- SL moves to entry + this amount
- *Gold: 8-15 pips*
- *Silver: 10-20 pips*

**TrailingActivation** (Default: 30 for Gold, 40 for Silver)
- Profit level where trailing starts
- After this, SL trails behind price
- *Gold: 25-40 pips*
- *Silver: 35-50 pips*

**TrailingDistance** (Default: 20 for Gold, 25 for Silver)
- Distance SL trails behind price
- Tighter = more BE stops, less profit
- Wider = more room, larger wins
- *Gold: 15-25 pips*
- *Silver: 20-30 pips*

**TrailBySwing** (Default: false)
- Trail by M5 swing points instead of fixed distance
- More adaptive but can be tighter
- *Recommended: false initially*

**MaxTradeHours** (Default: 6)
- Force close after this many hours
- Prevents overnight holds
- 4-8 hours typical range

---

### **RISK MANAGEMENT**

**RiskPercent** (Default: 1.0)
- Account percentage to risk per trade
- EA calculates lot size automatically
- Conservative: 0.5-1.0%
- Aggressive: 1.5-2.0%
- **Never exceed 2.5%**

**MaxDailyTrades** (Default: 5)
- Maximum trades allowed per day
- Prevents overtrading
- *Recommended: 3-7 trades*

**MaxDailyLossPercent** (Default: 3.0)
- Maximum daily loss before stopping
- Circuit breaker for bad days
- *Recommended: 2.5-5.0%*

**CooldownMinutes** (Default: 30)
- Minimum time between trades
- Prevents emotional trading
- *Recommended: 20-45 minutes*

---

### **TIME FILTERS**

**UseTimeFilter** (Default: true)
- Restrict trading to specific hours
- *Recommended: true*

**StartHour** (Default: 8)
- Trading begins (server time)
- 8 = London open

**EndHour** (Default: 20)
- Trading stops (server time)
- 20 = NY close

**AvoidNews** (Default: true)
- Additional news avoidance (future feature)
- *Recommended: true*

---

## TRADING LOGIC EXPLAINED

### **Phase 1: Market Analysis (Continuous)**
```
H4/D1 Analysis → Determine overall trend direction
H1 Analysis    → Identify momentum moves (30+ pip swings)
M15 Analysis   → Check volatility (ATR) and spread
M5 Execution   → Confirm reversal with candle patterns
```

### **Phase 2: Entry Signal Detection**

**BUY Setup Requirements:**
1. H1 shows sharp move down (30+ pips from recent high)
2. M5 shows 3 consecutive bullish candles (reversal)
3. Price near/below Bollinger lower band (if filter enabled)
4. Price above EMA support or in uptrend (if filter enabled)
5. Trend is BULLISH or NEUTRAL (if TradeOnlyTrending = true)
6. Spread acceptable, ATR in range
7. No position currently open

**SELL Setup Requirements:**
1. H1 shows sharp move up (30+ pips from recent low)
2. M5 shows 3 consecutive bearish candles (reversal)
3. Price near/above Bollinger upper band (if filter enabled)
4. Price below EMA resistance or in downtrend (if filter enabled)
5. Trend is BEARISH or NEUTRAL (if TradeOnlyTrending = true)
6. Spread acceptable, ATR in range
7. No position currently open

### **Phase 3: Position Management (Active Trade)**

**Timeline of a Typical Trade:**

```
ENTRY → Price 2045.00, SL 2025.00 (20 pips)

+15 pips profit → Move SL to 2045.00 (BREAK-EVEN)
                  Risk eliminated! 

+25 pips profit → Move SL to 2055.00 (+10 pips locked)
                  Guaranteed minimum win

+30 pips profit → ACTIVATE TRAILING STOP
                  SL trails 20 pips behind price
                  
Price rises to 2090.00 → SL now at 2070.00
Price rises to 2100.00 → SL now at 2080.00
Price drops to 2085.00 → SL still at 2080.00 (doesn't widen)
Price drops to 2080.00 → STOPPED OUT at 2080.00

RESULT: +35 pips profit (from 2045 entry to 2080 exit)
```

**Possible Outcomes:**
1. **Big Win**: Trail captures 50-100+ pip move
2. **Medium Win**: Stop hits at +10-40 pips
3. **Break-Even**: Exit at entry price (0 pips)
4. **Loss**: Initial SL hit (-20 pips)

---

## PRESET CONFIGURATIONS

### **Gold (XAUUSD) - Balanced**
```
Symbol: XAUUSD
Timeframe: M5 chart (analysis uses H1/H4)
Minimum Account: $1,000

Key Settings:
- MomentumPips: 30
- Initial SL: 20 pips (ATR-based)
- Break-Even: 15 pips
- Profit Lock: 25 pips (lock 10 pips)
- Trailing Activation: 30 pips
- Trailing Distance: 20 pips
- Risk: 1.0% per trade
- Max Daily Trades: 5

Expected Performance:
- Trades per week: 8-12
- Win Rate: 45-55%
- Average Win: +25-35 pips
- Average Loss: -20 pips
```

### **Silver (XAGUSD) - Balanced**
```
Symbol: XAGUSD
Timeframe: M5 chart (analysis uses H1/H4)
Minimum Account: $1,000

Key Settings:
- MomentumPips: 40 (higher volatility)
- Initial SL: 30 pips
- Break-Even: 20 pips
- Profit Lock: 35 pips (lock 15 pips)
- Trailing Activation: 40 pips
- Trailing Distance: 25 pips
- Risk: 1.0% per trade
- Max Daily Trades: 5

Expected Performance:
- Trades per week: 6-10
- Win Rate: 45-55%
- Average Win: +30-45 pips
- Average Loss: -30 pips
```

### **Conservative Setup (Both Metals)**
For risk-averse traders:
```
- MomentumPips: +5 (e.g., 35 for Gold)
- ConfirmationCandles: 4
- TradeOnlyTrending: true
- Risk: 0.5%
- MaxDailyTrades: 3
- TrailingDistance: +5 pips (wider)
```

### **Aggressive Setup (Both Metals)**
For experienced traders:
```
- MomentumPips: -5 (e.g., 25 for Gold)
- ConfirmationCandles: 2
- TradeOnlyTrending: false
- Risk: 1.5-2.0%
- MaxDailyTrades: 7
- TrailingDistance: -5 pips (tighter)
```

---

## OPTIMIZATION GUIDE

### **Week 1: Baseline Testing**
- Run with preset settings on DEMO
- Monitor for 5-7 days
- Record:
  - Total trades
  - Win rate
  - Average pips per win/loss
  - Break-even percentage
  - Time of day patterns

### **Week 2-3: Parameter Tuning**

**If Too Few Trades:**
- Reduce MomentumPips by 5
- Reduce ConfirmationCandles to 2
- Set TradeOnlyTrending = false
- Increase MaxSpreadPips by 0.5

**If Too Many Losses:**
- Increase MomentumPips by 5
- Increase ConfirmationCandles to 4
- Set TradeOnlyTrending = true
- Tighten spread filter

**If Hitting Break-Even Too Often:**
- Increase TrailingDistance by 5 pips
- Set TrailBySwing = true
- Delay trailing activation by 5-10 pips

**If Profits Too Small:**
- Increase TrailingActivation by 10 pips
- Widen TrailingDistance by 5 pips
- Increase ProfitLockPips

### **Week 4: Risk Optimization**
- Test different RiskPercent values
- Verify daily loss limit is appropriate
- Adjust MaxDailyTrades based on results
- Fine-tune CooldownMinutes

### **Backtesting Guidelines**
- Use MT5 Strategy Tester
- Minimum 6 months historical data
- Test on tick data (every tick)
- Key metrics:
  - Profit Factor > 1.5
  - Win Rate > 45%
  - Max Drawdown < 20%
  - Total Trades > 100

---

## RISK MANAGEMENT

### **Position Sizing Formula**
```
Risk Amount = Account Balance × RiskPercent / 100
Lot Size = Risk Amount / (SL Distance × Tick Value)
```

Example:
- Account: $10,000
- Risk: 1% = $100
- SL: 20 pips = $100 / 20 = $5 per pip
- Lot Size ≈ 0.50 lots (calculated automatically)

### **Daily Risk Controls**

**3-Level Protection:**
1. **Trade Count**: Stops after MaxDailyTrades
2. **Loss Limit**: Stops when daily loss exceeds MaxDailyLossPercent
3. **Cooldown**: Forces time between trades

**Example Day:**
```
Start: $10,000 balance
Trade 1: -$100 (loss)
Trade 2: +$150 (win)
Trade 3: -$100 (loss)
Trade 4: -$150 (loss)
Trade 5: +$200 (win)

Daily P/L: $0
Status: MaxDailyTrades (5) reached → Stop trading

If trade 4 was -$200:
Daily P/L: -$200 (-2%)
Trade 5 never happens
If -3% limit reached → Stop trading
```

### **Weekly Performance Review**

**Every Sunday, Analyze:**
- Total trades vs target
- Win rate trend
- Profit factor stability
- Largest loss (should be ≤ 2× average loss)
- Break-even percentage (target: 20-30%)
- Best/worst trading days

**Red Flags:**
- Win rate < 40% for 2+ weeks → Increase filters
- Average loss > 1.5× average win → Adjust trailing
- Break-even rate > 40% → Widen trailing
- No trades for days → Reduce filters

---

## TROUBLESHOOTING

### **EA Not Taking Trades**

**Diagnosis Checklist:**
1. Check panel shows "Ready to Trade" (not cooldown)
2. Verify AutoTrading enabled (green button)
3. Check daily trade limit not reached
4. Verify spread is acceptable (check panel)
5. Confirm ATR in valid range (panel shows volatility)
6. Look at trend direction - may be waiting for right setup

**Solution:**
- Review Experts log for denial messages
- Temporarily reduce MomentumPips to test
- Disable TradeOnlyTrending to see if trend filtering issue
- Check MaxSpreadPips is appropriate for your broker

### **Hitting Break-Even Too Often**

**Cause**: Trailing stop too tight or activating too early

**Solution:**
- Increase TrailingDistance by 5-10 pips
- Delay TrailingActivation by 5-10 pips
- Enable TrailBySwing for more adaptive trailing
- Increase ProfitLockPips to lock more profit before trailing

### **Large Losses Occurring**

**Cause**: Stop loss too wide or volatility spike

**Solution:**
- Reduce InitialSL_Pips or ATR_SL_Multiplier
- Enable/tighten MaxATR_M15 filter
- Set stricter time filters to avoid volatile periods
- Reduce RiskPercent temporarily

### **Too Many Small Wins, Few Big Wins**

**Cause**: Trailing too aggressive

**Solution:**
- Increase TrailingDistance significantly (+10 pips)
- Increase TrailingActivation to let profits run longer
- Consider switching TakeProfitMode if available in future updates

### **Panel Not Updating**

**Solution:**
- Press F5 to refresh chart
- Restart EA (remove and reattach)
- Check panel is not hidden behind other windows
- Verify ShowPanel = true

---

## BEST PRACTICES

### **1. Always Start on Demo**
Test for minimum 2 weeks before live trading

### **2. Monitor First Week Closely**
- Check panel multiple times daily
- Review Experts log
- Understand why each trade was taken
- Verify trailing is working correctly

### **3. Keep a Trading Journal**
Document:
- Entry reason (which setup)
- Exit outcome (trail hit, BE, SL)
- Market conditions at time
- Emotional state (if manual intervention)

### **4. Respect the System**
- Don't manually close trades prematurely
- Don't widen stops
- Don't override daily limits
- Trust the break-even logic

### **5. Regular Maintenance**
- Weekly performance review
- Monthly parameter adjustment
- Quarterly full optimization
- Keep EA updated to latest version

---

## SUPPORT & CONTACT

**TORAMA CAPITAL**

📧 **Email**: ea@torama.money  
🌐 **Website**: torama.money

**Before Contacting Support:**
- Check this guide thoroughly
- Review Experts log for error messages
- Take screenshots of panel and any issues
- Note your broker and account type
- List any custom settings used

**Include in Support Requests:**
- MT5 build number
- Broker name
- Account type (demo/live, ECN/standard)
- EA settings file (screenshot or export)
- Description of issue with screenshots
- Experts log entries (relevant portions)

---

## IMPORTANT DISCLAIMERS

### **Risk Warning**
- Trading forex and precious metals involves substantial risk
- Past performance does not guarantee future results
- Only trade with capital you can afford to lose
- EA performance varies by broker, spread, and market conditions

### **No Guarantees**
- Win rates and profit targets are estimates
- Market conditions change constantly
- Optimization to past data may not predict future performance
- Always use proper risk management

### **Testing Required**
- ALWAYS test on demo account first
- Minimum 2-4 weeks demo testing recommended
- Backtest with at least 6 months data
- Forward test in current market conditions

---

## VERSION HISTORY

**v1.00** (January 2026)
- Initial release
- Multi-timeframe momentum analysis
- Single position management with aggressive trailing
- Break-even and profit lock logic
- Comprehensive statistics panel with TORAMA CAPITAL branding
- Gold and Silver optimized settings
- Time and volatility filters

---

*TORAMA CAPITAL - Professional Trading Solutions*  
*Copyright © 2026 | All Rights Reserved*
