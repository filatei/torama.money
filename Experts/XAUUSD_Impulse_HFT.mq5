//+------------------------------------------------------------------+
//|                          XAUUSD Price Impulse HFT EA v4.0        |
//|                                          TORAMA CAPITAL          |
//|                                          ea@torama.money         |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "www.torama.money"
#property version   "4.00"
#property description "Gold HFT scalper - Hundreds of trades per day"
#property strict

#include <Trade/Trade.mqh>
CTrade trade;

//--- Input Parameters
input group "=== HFT Risk Management ==="
input double   InpRiskPercent        = 0.1;      // Risk per trade (% of balance)
input double   InpMaxDailyLossPct    = 5.0;      // Max daily loss (%)
input int      InpMaxConsecLosses    = 10;       // Max consecutive losses
input bool     InpAllowTrading       = true;     // Allow trading
input double   InpMaxLotSize         = 50.0;     // Maximum lot size limit
input double   InpMinLotSize         = 0.01;     // Minimum lot size

input group "=== HFT Entry Parameters (ULTRA SENSITIVE) ==="
input int      InpLookbackImpulse    = 3;        // Candles for impulse (FAST)
input int      InpMicroStructure     = 2;        // Structure break lookback (MICRO)
input double   InpMinImpulseRatio    = 0.7;      // Min impulse ratio (LOW = more trades)
input bool     InpUseVolumeFilter    = false;    // Volume filter (DISABLED for HFT)
input double   InpMinVolumeRatio     = 0.8;      // Min volume ratio (if enabled)
input int      InpMinBarsBetween     = 0;        // Min bars between trades (0 = rapid fire)

input group "=== Tick-Based Entry (HFT MODE) ==="
input bool     InpUseTickEntry       = true;     // Use tick-based entries
input double   InpTickImpulse_Points = 30;       // Tick impulse threshold (points)
input int      InpTickLookback       = 10;       // Ticks to analyze
input double   InpMinTickMove        = 5;        // Min price move per tick

input group "=== HFT Exit Parameters (FAST) ==="
input int      InpMomentumLossBars   = 1;        // Bars for momentum loss (INSTANT)
input bool     InpUseATRStops        = false;    // ATR stops (too slow for HFT)
input bool     InpUseFixedSL         = true;     // Use fixed SL/TP (FAST)
input double   InpFixedSL_Points     = 100;      // Stop Loss points (TIGHT)
input double   InpFixedTP_Points     = 150;      // Take Profit points (QUICK)
input bool     InpUseBreakeven       = true;     // Move to breakeven
input double   InpBreakeven_Points   = 50;       // Points profit for BE
input int      InpMaxHoldBars        = 5;        // Max bars to hold position

input group "=== Scalping Features ==="
input bool     InpScalpMode          = true;     // Ultra-fast scalp mode
input double   InpScalpTarget_Points = 80;       // Quick scalp target
input bool     InpCloseOnReverse     = true;     // Close on opposite signal
input bool     InpAllowHedging       = false;    // Allow simultaneous BUY/SELL

input group "=== Trailing Stop (TIGHT) ==="
input bool     InpUseTrailing        = true;     // Enable trailing
input double   InpTrailStart_Points  = 40;       // Start trailing (points)
input double   InpTrailDistance      = 30;       // Trail distance (points)

input group "=== Multi-Position Management ==="
input int      InpMaxOpenPositions   = 5;        // Max simultaneous positions
input bool     InpPyramiding         = true;     // Allow adding to winners
input int      InpMaxPyramidLevels   = 3;        // Max pyramid levels

input group "=== Flip Trading (AGGRESSIVE) ==="
input bool     InpAllowFlip          = true;     // Allow position flipping
input double   InpFlipImpulseRatio   = 0.8;      // Flip impulse ratio (LOW)
input int      InpFlipCooldown       = 0;        // No cooldown for HFT

input group "=== Time Filter ==="
input bool     InpUseTimeFilter      = false;    // Time filter (OFF for 24/7)
input int      InpStartHour          = 0;        // Trading start hour
input int      InpEndHour            = 23;       // Trading end hour
input bool     InpTradeAsian         = true;     // Trade Asian session
input bool     InpTradeLondon        = true;     // Trade London session
input bool     InpTradeNY            = true;     // Trade NY session

input group "=== Broker Protection ==="
input double   InpMaxSpreadMulti     = 3.0;      // Max spread multiplier (RELAXED)
input int      InpMaxSpread_Points   = 100;      // Absolute max spread
input int      InpSlippage           = 20;       // Max slippage
input int      InpMaxRetries         = 5;        // Max order retries
input int      InpRetryDelay_ms      = 100;      // Delay between retries

input group "=== Performance Optimization ==="
input bool     InpFastMode           = true;     // Skip heavy calculations
input bool     InpReduceLogging      = true;     // Minimal logging for speed
input int      InpMagicNumber        = 88888;    // Magic number

//--- Global Variables
double   g_TickSize, g_TickValue, g_MinLot, g_MaxLot, g_LotStep, g_Point;
double   g_MaxSpread;
int      g_LossStreak = 0;
double   g_DayStartEquity;
datetime g_DayStart;
datetime g_LastTradeTime = 0;
datetime g_LastFlipTime = 0;
int      g_TradesThisBar = 0;
datetime g_CurrentBarTime = 0;

//--- Tick data
struct TickData {
    datetime time;
    double bid;
    double ask;
    double last;
    long volume;
};
TickData g_TickHistory[];
int g_TickIndex = 0;

//--- Position tracking
struct PositionInfo {
    ulong ticket;
    datetime openTime;
    double openPrice;
    int barsHeld;
    bool beMoveDone;
    ENUM_POSITION_TYPE type;
};
PositionInfo g_Positions[];

//--- Statistics
struct HFTStats {
    int totalTrades;
    int winningTrades;
    int losingTrades;
    int scalpWins;
    double totalProfit;
    double totalLoss;
    double largestWin;
    double largestLoss;
    int tradesThisHour;
    int tradesThisDay;
    datetime hourStart;
} g_Stats;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- Get symbol properties
    if(!SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE, g_TickSize))
    {
        Print("ERROR: Cannot get tick size");
        return INIT_FAILED;
    }
    
    if(!SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE, g_TickValue))
    {
        Print("ERROR: Cannot get tick value");
        return INIT_FAILED;
    }
    
    SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN, g_MinLot);
    SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX, g_MaxLot);
    SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP, g_LotStep);
    g_Point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    //--- Override min lot if specified
    if(InpMinLotSize > g_MinLot)
        g_MinLot = InpMinLotSize;
    
    //--- Calculate max spread
    g_MaxSpread = InpMaxSpread_Points;
    
    //--- Initialize daily tracking
    g_DayStart = TimeCurrent();
    g_DayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    //--- Set trade parameters for SPEED
    trade.SetExpertMagicNumber(InpMagicNumber);
    trade.SetDeviationInPoints(InpSlippage);
    trade.SetTypeFilling(ORDER_FILLING_IOC); // Immediate or Cancel for HFT
    trade.SetAsyncMode(false); // Synchronous for better control
    
    //--- Initialize statistics
    ZeroMemory(g_Stats);
    g_Stats.hourStart = TimeCurrent();
    
    //--- Initialize tick history
    ArrayResize(g_TickHistory, InpTickLookback);
    
    Print("╔════════════════════════════════════════════════════════════╗");
    Print("║  XAUUSD IMPULSE HFT EA v4.0 - INITIALIZED                 ║");
    Print("╠════════════════════════════════════════════════════════════╣");
    Print("║  MODE: HIGH FREQUENCY TRADING                             ║");
    Print("║  TARGET: 100-500 trades per day                           ║");
    Print("║  Symbol: ", _Symbol);
    Print("║  Tick Entry: ", (InpUseTickEntry ? "ENABLED" : "DISABLED"));
    Print("║  Scalp Mode: ", (InpScalpMode ? "ACTIVE" : "INACTIVE"));
    Print("║  Min Lot: ", g_MinLot, " | Max Lot: ", g_MaxLot);
    Print("║  Max Positions: ", InpMaxOpenPositions);
    Print("╚════════════════════════════════════════════════════════════╝");
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    PrintHFTStatistics();
    Print("HFT EA stopped. Total trades today: ", g_Stats.tradesThisDay);
}

//+------------------------------------------------------------------+
//| Expert tick function - OPTIMIZED FOR SPEED                       |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Quick checks first (fastest operations)
    if(!InpAllowTrading) return;
    
    //--- Update tick history if using tick-based entry
    if(InpUseTickEntry)
        UpdateTickHistory();
    
    //--- Check daily limits (expensive, do less often)
    static datetime lastLimitCheck = 0;
    if(TimeCurrent() - lastLimitCheck > 60) // Check every minute
    {
        if(IsDailyLossExceeded()) return;
        lastLimitCheck = TimeCurrent();
    }
    
    //--- Broker safety (check every tick but fast)
    if(!IsBrokerSafe()) return;
    
    //--- Manage all open positions
    ManageAllPositions();
    
    //--- Entry logic - tick-based or candle-based
    if(InpUseTickEntry)
    {
        EvaluateTickEntry(); // Check EVERY tick for entries
    }
    else
    {
        // Traditional candle-based (still fast)
        static datetime lastBar = 0;
        datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
        
        if(currentBar != lastBar)
        {
            lastBar = currentBar;
            g_TradesThisBar = 0; // Reset bar counter
        }
        
        EvaluateEntry();
    }
}

//+------------------------------------------------------------------+
//| Update tick history for tick-based analysis                     |
//+------------------------------------------------------------------+
void UpdateTickHistory()
{
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick))
        return;
    
    g_TickIndex = (g_TickIndex + 1) % InpTickLookback;
    
    g_TickHistory[g_TickIndex].time = tick.time;
    g_TickHistory[g_TickIndex].bid = tick.bid;
    g_TickHistory[g_TickIndex].ask = tick.ask;
    g_TickHistory[g_TickIndex].last = tick.last;
    g_TickHistory[g_TickIndex].volume = (long)tick.volume;
}

//+------------------------------------------------------------------+
//| Evaluate tick-based entry (HFT MODE)                            |
//+------------------------------------------------------------------+
void EvaluateTickEntry()
{
    //--- Check position limits
    if(CountOpenPositions() >= InpMaxOpenPositions)
        return;
    
    //--- Need enough tick history
    if(g_TickIndex < InpTickLookback - 1)
        return;
    
    //--- Get current tick
    MqlTick currentTick;
    if(!SymbolInfoTick(_Symbol, currentTick))
        return;
    
    //--- Calculate tick impulse
    double tickImpulse = CalculateTickImpulse();
    if(tickImpulse < InpTickImpulse_Points * g_Point)
        return;
    
    //--- Determine direction from recent tick movement
    int startIdx = (g_TickIndex - 5 + InpTickLookback) % InpTickLookback;
    double startPrice = (g_TickHistory[startIdx].bid + g_TickHistory[startIdx].ask) / 2;
    double currentPrice = (currentTick.bid + currentTick.ask) / 2;
    
    double priceMove = currentPrice - startPrice;
    
    //--- Minimum tick move required
    if(MathAbs(priceMove) < InpMinTickMove * g_Point)
        return;
    
    //--- Execute based on direction
    if(priceMove > 0) // Upward impulse
    {
        if(!HasOpenPosition(POSITION_TYPE_BUY) || InpPyramiding)
            ExecuteHFTTrade(ORDER_TYPE_BUY, currentTick.ask);
    }
    else if(priceMove < 0) // Downward impulse
    {
        if(!HasOpenPosition(POSITION_TYPE_SELL) || InpPyramiding)
            ExecuteHFTTrade(ORDER_TYPE_SELL, currentTick.bid);
    }
}

//+------------------------------------------------------------------+
//| Calculate tick impulse                                           |
//+------------------------------------------------------------------+
double CalculateTickImpulse()
{
    double totalMove = 0;
    int count = 0;
    
    for(int i = 1; i < InpTickLookback; i++)
    {
        int currentIdx = (g_TickIndex - i + InpTickLookback) % InpTickLookback;
        int prevIdx = (g_TickIndex - i - 1 + InpTickLookback) % InpTickLookback;
        
        double currentMid = (g_TickHistory[currentIdx].bid + g_TickHistory[currentIdx].ask) / 2;
        double prevMid = (g_TickHistory[prevIdx].bid + g_TickHistory[prevIdx].ask) / 2;
        
        totalMove += MathAbs(currentMid - prevMid);
        count++;
    }
    
    return count > 0 ? totalMove / count : 0;
}

//+------------------------------------------------------------------+
//| Evaluate candle-based entry (FAST MODE)                         |
//+------------------------------------------------------------------+
void EvaluateEntry()
{
    //--- Check position limits
    if(CountOpenPositions() >= InpMaxOpenPositions)
        return;
    
    //--- Check minimum bars between trades
    if(InpMinBarsBetween > 0)
    {
        int barsSinceLastTrade = Bars(_Symbol, PERIOD_CURRENT, g_LastTradeTime, TimeCurrent());
        if(barsSinceLastTrade < InpMinBarsBetween)
            return;
    }
    
    //--- Need minimal bars
    if(Bars(_Symbol, PERIOD_CURRENT) < InpLookbackImpulse + 5)
        return;
    
    //--- Get price data (minimal copy for speed)
    MqlRates rates[];
    ArraySetAsSeries(rates, true);
    
    int barsNeeded = InpLookbackImpulse + 3;
    int copied = CopyRates(_Symbol, PERIOD_CURRENT, 0, barsNeeded, rates);
    if(copied < barsNeeded)
        return;
    
    //--- Fast impulse calculation
    double avgImpulse = 0;
    for(int i = 1; i <= InpLookbackImpulse; i++)
        avgImpulse += MathAbs(rates[i].close - rates[i].open);
    avgImpulse /= InpLookbackImpulse;
    
    if(avgImpulse <= 0)
        return;
    
    //--- Check last candle
    double lastBody = MathAbs(rates[1].close - rates[1].open);
    double impulseRatio = lastBody / avgImpulse;
    
    if(impulseRatio < InpMinImpulseRatio)
        return;
    
    //--- Volume filter (optional, disabled by default for HFT)
    if(InpUseVolumeFilter)
    {
        long totalVolume = 0;
        for(int i = 1; i <= InpLookbackImpulse; i++)
            totalVolume += rates[i].tick_volume;
        double avgVolume = (double)totalVolume / InpLookbackImpulse;
        
        if(avgVolume > 0 && ((double)rates[1].tick_volume / avgVolume) < InpMinVolumeRatio)
            return;
    }
    
    //--- Micro structure break (very short lookback for HFT)
    double structureHigh = rates[2].high;
    double structureLow = rates[2].low;
    
    for(int i = 2; i < InpMicroStructure + 2; i++)
    {
        if(rates[i].high > structureHigh) structureHigh = rates[i].high;
        if(rates[i].low < structureLow) structureLow = rates[i].low;
    }
    
    bool breakHigh = rates[1].close > structureHigh;
    bool breakLow = rates[1].close < structureLow;
    
    //--- Get current tick for entry price
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick))
        return;
    
    //--- Execute trades
    if(breakHigh && rates[1].close > rates[1].open)
    {
        if(!HasOpenPosition(POSITION_TYPE_BUY) || InpPyramiding)
            ExecuteHFTTrade(ORDER_TYPE_BUY, tick.ask);
    }
    else if(breakLow && rates[1].close < rates[1].open)
    {
        if(!HasOpenPosition(POSITION_TYPE_SELL) || InpPyramiding)
            ExecuteHFTTrade(ORDER_TYPE_SELL, tick.bid);
    }
}

//+------------------------------------------------------------------+
//| Manage all open positions (FAST)                                |
//+------------------------------------------------------------------+
void ManageAllPositions()
{
    int total = PositionsTotal();
    
    for(int i = total - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;
        
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
            continue;
        
        if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
        
        ManageSinglePosition(ticket);
    }
}

//+------------------------------------------------------------------+
//| Manage single position                                           |
//+------------------------------------------------------------------+
void ManageSinglePosition(ulong ticket)
{
    if(!PositionSelectByTicket(ticket))
        return;
    
    long posType = PositionGetInteger(POSITION_TYPE);
    ENUM_POSITION_TYPE enumPosType = (ENUM_POSITION_TYPE)posType;
    double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
    double currentSL = PositionGetDouble(POSITION_SL);
    double currentTP = PositionGetDouble(POSITION_TP);
    double currentProfit = PositionGetDouble(POSITION_PROFIT);
    datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
    
    MqlTick tick;
    if(!SymbolInfoTick(_Symbol, tick))
        return;
    
    double currentPrice = (enumPosType == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
    double priceMove = (enumPosType == POSITION_TYPE_BUY) ? 
                       (currentPrice - openPrice) : (openPrice - currentPrice);
    
    //--- Breakeven logic
    if(InpUseBreakeven && currentSL != openPrice)
    {
        if(priceMove >= InpBreakeven_Points * g_Point)
        {
            double newSL = NormalizeDouble(openPrice, _Digits);
            if(trade.PositionModify(ticket, newSL, currentTP))
            {
                if(!InpReduceLogging)
                    Print("→ BE: ", ticket);
            }
        }
    }
    
    //--- Trailing stop
    if(InpUseTrailing && priceMove >= InpTrailStart_Points * g_Point)
    {
        double newSL = 0;
        
        if(enumPosType == POSITION_TYPE_BUY)
        {
            newSL = NormalizeDouble(currentPrice - InpTrailDistance * g_Point, _Digits);
            if(newSL > currentSL)
            {
                trade.PositionModify(ticket, newSL, currentTP);
            }
        }
        else
        {
            newSL = NormalizeDouble(currentPrice + InpTrailDistance * g_Point, _Digits);
            if(currentSL == 0 || newSL < currentSL)
            {
                trade.PositionModify(ticket, newSL, currentTP);
            }
        }
    }
    
    //--- Scalp mode - quick exit
    if(InpScalpMode)
    {
        if(priceMove >= InpScalpTarget_Points * g_Point)
        {
            ClosePosition(ticket, "Scalp target");
            return;
        }
    }
    
    //--- Max hold time
    if(InpMaxHoldBars > 0)
    {
        int barsHeld = Bars(_Symbol, PERIOD_CURRENT, openTime, TimeCurrent());
        if(barsHeld >= InpMaxHoldBars)
        {
            ClosePosition(ticket, "Max hold");
            return;
        }
    }
    
    //--- Close on reverse signal
    if(InpCloseOnReverse)
    {
        MqlRates rates[];
        ArraySetAsSeries(rates, true);
        
        if(CopyRates(_Symbol, PERIOD_CURRENT, 0, 3, rates) == 3)
        {
            bool reverseSignal = false;
            
            if(enumPosType == POSITION_TYPE_BUY)
            {
                if(rates[1].close < rates[2].low)
                    reverseSignal = true;
            }
            else
            {
                if(rates[1].close > rates[2].high)
                    reverseSignal = true;
            }
            
            if(reverseSignal)
            {
                ClosePosition(ticket, "Reverse signal");
                
                //--- Immediately flip if enabled
                if(InpAllowFlip)
                {
                    ENUM_ORDER_TYPE flipType = (enumPosType == POSITION_TYPE_BUY) ? 
                                               ORDER_TYPE_SELL : ORDER_TYPE_BUY;
                    double flipPrice = (flipType == ORDER_TYPE_BUY) ? tick.ask : tick.bid;
                    ExecuteHFTTrade(flipType, flipPrice);
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Execute HFT trade with retries                                  |
//+------------------------------------------------------------------+
void ExecuteHFTTrade(ENUM_ORDER_TYPE orderType, double price)
{
    //--- Calculate lot size
    double lotSize = CalculateLotSize();
    if(lotSize <= 0)
        return;
    
    //--- Apply limits
    lotSize = MathMin(lotSize, InpMaxLotSize);
    lotSize = MathMax(lotSize, g_MinLot);
    
    //--- Calculate SL/TP
    double sl = 0, tp = 0;
    
    if(InpUseFixedSL)
    {
        if(orderType == ORDER_TYPE_BUY)
        {
            sl = NormalizeDouble(price - InpFixedSL_Points * g_Point, _Digits);
            tp = NormalizeDouble(price + InpFixedTP_Points * g_Point, _Digits);
        }
        else
        {
            sl = NormalizeDouble(price + InpFixedSL_Points * g_Point, _Digits);
            tp = NormalizeDouble(price - InpFixedTP_Points * g_Point, _Digits);
        }
    }
    
    //--- Execute with retries
    bool result = false;
    int retries = 0;
    
    while(retries < InpMaxRetries && !result)
    {
        if(orderType == ORDER_TYPE_BUY)
            result = trade.Buy(lotSize, _Symbol, 0, sl, tp, "HFT");
        else
            result = trade.Sell(lotSize, _Symbol, 0, sl, tp, "HFT");
        
        if(!result)
        {
            uint errorCode = trade.ResultRetcode();
            
            if(errorCode == TRADE_RETCODE_REQUOTE || 
               errorCode == TRADE_RETCODE_PRICE_OFF ||
               errorCode == TRADE_RETCODE_TIMEOUT)
            {
                Sleep(InpRetryDelay_ms);
                retries++;
            }
            else
            {
                break;
            }
        }
    }
    
    if(result)
    {
        g_LastTradeTime = TimeCurrent();
        g_TradesThisBar++;
        g_Stats.tradesThisDay++;
        g_Stats.tradesThisHour++;
        
        if(!InpReduceLogging)
            Print("✓ ", EnumToString(orderType), " | Lot:", lotSize, " | #", g_Stats.tradesThisDay);
    }
}

//+------------------------------------------------------------------+
//| Close position                                                   |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
    if(!PositionSelectByTicket(ticket))
        return;
    
    double profit = PositionGetDouble(POSITION_PROFIT);
    
    if(trade.PositionClose(ticket, InpSlippage))
    {
        UpdateHFTStats(profit);
        
        if(!InpReduceLogging)
            Print("✗ Close: ", reason, " | P/L: $", DoubleToString(profit, 2));
    }
}

//+------------------------------------------------------------------+
//| Count open positions                                             |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
    int count = 0;
    int total = PositionsTotal();
    
    for(int i = 0; i < total; i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;
        
        if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
           PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
            count++;
        }
    }
    
    return count;
}

//+------------------------------------------------------------------+
//| Check if has open position of type                              |
//+------------------------------------------------------------------+
bool HasOpenPosition(ENUM_POSITION_TYPE type)
{
    int total = PositionsTotal();
    
    for(int i = 0; i < total; i++)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket == 0) continue;
        
        if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
           PositionGetString(POSITION_SYMBOL) == _Symbol)
        {
            long posType = PositionGetInteger(POSITION_TYPE);
            if(posType == type)
                return true;
        }
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskMoney = balance * (InpRiskPercent / 100.0);
    
    double stopDistance = InpFixedSL_Points * g_Point;
    if(stopDistance <= 0)
        return g_MinLot;
    
    double lotSize = riskMoney / (stopDistance / g_TickSize * g_TickValue);
    
    lotSize = MathFloor(lotSize / g_LotStep) * g_LotStep;
    lotSize = MathMax(lotSize, g_MinLot);
    lotSize = MathMin(lotSize, g_MaxLot);
    
    return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| Check if broker conditions are safe                             |
//+------------------------------------------------------------------+
bool IsBrokerSafe()
{
    long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    
    if(currentSpread > g_MaxSpread)
        return false;
    
    if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE))
        return false;
    
    return true;
}

//+------------------------------------------------------------------+
//| Check if daily loss limit exceeded                              |
//+------------------------------------------------------------------+
bool IsDailyLossExceeded()
{
    MqlDateTime current, start;
    TimeToStruct(TimeCurrent(), current);
    TimeToStruct(g_DayStart, start);
    
    if(current.day != start.day || current.mon != start.mon || current.year != start.year)
    {
        g_DayStart = TimeCurrent();
        g_DayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
        g_LossStreak = 0;
        g_Stats.tradesThisDay = 0;
        
        if(!InpReduceLogging)
            Print("═══ NEW DAY - Stats Reset | Yesterday: ", g_Stats.tradesThisDay, " trades ═══");
    }
    
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    double dailyLossPct = (g_DayStartEquity - currentEquity) / g_DayStartEquity * 100.0;
    
    if(dailyLossPct >= InpMaxDailyLossPct)
        return true;
    
    if(g_LossStreak >= InpMaxConsecLosses)
        return true;
    
    return false;
}

//+------------------------------------------------------------------+
//| Update HFT statistics                                            |
//+------------------------------------------------------------------+
void UpdateHFTStats(double profit)
{
    g_Stats.totalTrades++;
    
    if(profit > 0)
    {
        g_Stats.winningTrades++;
        g_Stats.totalProfit += profit;
        
        if(profit <= InpScalpTarget_Points * g_Point * g_TickValue)
            g_Stats.scalpWins++;
        
        if(profit > g_Stats.largestWin)
            g_Stats.largestWin = profit;
        
        g_LossStreak = 0;
    }
    else if(profit < 0)
    {
        g_Stats.losingTrades++;
        g_Stats.totalLoss += MathAbs(profit);
        
        if(MathAbs(profit) > g_Stats.largestLoss)
            g_Stats.largestLoss = MathAbs(profit);
        
        g_LossStreak++;
    }
    
    //--- Hourly reset
    if(TimeCurrent() - g_Stats.hourStart > 3600)
    {
        if(!InpReduceLogging)
            Print("Hour complete: ", g_Stats.tradesThisHour, " trades");
        
        g_Stats.tradesThisHour = 0;
        g_Stats.hourStart = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
//| Print HFT statistics                                             |
//+------------------------------------------------------------------+
void PrintHFTStatistics()
{
    if(g_Stats.totalTrades == 0)
        return;
    
    double winRate = (double)g_Stats.winningTrades / g_Stats.totalTrades * 100.0;
    double avgWin = g_Stats.winningTrades > 0 ? g_Stats.totalProfit / g_Stats.winningTrades : 0;
    double avgLoss = g_Stats.losingTrades > 0 ? g_Stats.totalLoss / g_Stats.losingTrades : 0;
    double profitFactor = g_Stats.totalLoss > 0 ? g_Stats.totalProfit / g_Stats.totalLoss : 0;
    double netProfit = g_Stats.totalProfit - g_Stats.totalLoss;
    
    Print("╔═════════════════════════════════════════════╗");
    Print("║        HFT SESSION STATISTICS               ║");
    Print("╠═════════════════════════════════════════════╣");
    Print("║  Total Trades: ", g_Stats.totalTrades);
    Print("║  Today: ", g_Stats.tradesThisDay);
    Print("║  Winners: ", g_Stats.winningTrades, " | Losers: ", g_Stats.losingTrades);
    Print("║  Win Rate: ", DoubleToString(winRate, 1), "%");
    Print("║  Scalp Wins: ", g_Stats.scalpWins);
    Print("║  Profit Factor: ", DoubleToString(profitFactor, 2));
    Print("║  Avg Win: $", DoubleToString(avgWin, 2));
    Print("║  Avg Loss: $", DoubleToString(avgLoss, 2));
    Print("║  Net P/L: $", DoubleToString(netProfit, 2));
    Print("╚═════════════════════════════════════════════╝");
}

//+------------------------------------------------------------------+
