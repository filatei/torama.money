//+------------------------------------------------------------------+
//|                        Enhanced CandlePattern Mean Reversion EA v3.00        |
//|                        Professional Trading EA                                |
//|                        © TORAMA CAPITAL 2025                                  |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL - Advanced Trading Solutions"
#property version   "3.00"
#property description "Professional Mean Reversion EA - Contrarian Edition"
#property description "Buys on Bearish Candles | Sells on Bullish Candles"
#property description "DEMO ACCOUNTS ONLY - Educational & Professional Use"
#property link      "www.torama.money"

#include <Trade/Trade.mqh>

// ==== PROFESSIONAL COLOR SCHEME ====
#define BRAND_PRIMARY_BLUE         C'0,82,147'             // Deep corporate blue
#define BRAND_SECONDARY_GOLD       C'255,193,7'           // Premium gold
#define BRAND_ACCENT_TEAL          C'0,150,136'           // Modern teal accent
#define BRAND_DARK_BG              C'18,22,28'             // Darker professional background
#define BRAND_LIGHT_BG             C'35,42,52'             // Lighter panel background
#define BRAND_SUCCESS_GREEN        C'76,175,80'           // Success green
#define BRAND_WARNING_ORANGE       C'255,152,0'           // Warning orange
#define BRAND_DANGER_RED           C'244,67,54'           // Danger red
#define BRAND_TEXT_PRIMARY         C'255,255,255'         // Primary text
#define BRAND_TEXT_SECONDARY       C'189,189,189'         // Secondary text
#define BRAND_BORDER_LIGHT         C'70,80,90'             // Light borders

// ==== ENHANCED BRANDING CONSTANTS ====
#define COMPANY_NAME                   "TORAMA CAPITAL"
#define COMPANY_TAGLINE                "Advanced Trading Solutions"
#define COMPANY_WEBSITE                "www.torama.money"
#define COMPANY_VERSION                "Mean Reversion v3.00"
#define COMPANY_LICENSE                "Licensed Trading Software"
#define COMPANY_EMAIL                  "ea@torama.money"

enum ENUM_TRADE_DIRECTION
{
    TRADE_BOTH = 0,
    TRADE_BUY_ONLY = 1,
    TRADE_SELL_ONLY = 2
};

input ENUM_TIMEFRAMES Timeframe = PERIOD_M1;                    // Trading Timeframe
input ENUM_TRADE_DIRECTION TradeDirection = TRADE_BOTH;         // Trade Direction
input double    LotSize = 0.1;                                   // Fixed Lot Size
input bool      UseAutoLotSizing = false;                        // Use Auto Lot Sizing
input double    AutoLotPer1000 = 0.01;                          // Auto Lot per $1000
input double    EquityIncrement = 1000.0;                        // Equity Increment for Auto Lot
input int       StopLoss = 0;                                    // Stop Loss (0 = disabled)
input double    TakeProfitDollars = 50.0;                        // Take Profit in Dollars
input double    GlobalProfitTarget = 100.0;                      // Global Profit Target ($)
input double    MaxDrawdownPercent = 30.0;                       // Maximum Drawdown % (0 = disabled)
input bool      EnableConsecutiveCandleExit = true;              // Enable Consecutive Candle Exit
input int       ConsecutiveCandleCount = 3;                      // Consecutive Candles for Exit
input int       TradesPerSignal = 1;                             // Trades Per Signal
input int       MaxPositions = 5;                                // Max Positions Per Direction
input int       MagicNumber = 123457;                            // Magic Number
input string    TradeComment = "MeanRev";                        // Trade Comment
input bool      ShowButtons = true;                              // Show Control Buttons
input bool      StartPanelMinimized = false;                     // Start Panel Minimized
input int       MaxRetries = 3;                                  // Max Order Retries
input int       RetryDelay = 100;                                // Retry Delay (ms)

CTrade trade;
datetime lastBarTime = 0;
int consecutiveBullish = 0;
int consecutiveBearish = 0;
bool tradingEnabled = true;
bool isInitialized = false;
bool isPanelMinimized = false;
int actualTradesPerSignal = 1;
double startingEquity = 0;
bool drawdownProtectionTriggered = false;

#define BTN_TOGGLE_TRADING "btnToggleTrading"
#define BTN_CLOSE_PROFITABLE "btnCloseProfitable"
#define BTN_PANEL_MINIMIZE "btnPanelMinimize"
#define INFO_PANEL_BACKGROUND "infoPanelBackground"
#define INFO_PANEL_TITLE "infoPanelTitle"
#define INFO_PANEL_LINE_PREFIX "infoPanelLine"
#define COMPACT_INFO_LABEL "compactInfoLabel"

// Forward declarations
void CreateCollapsibleInfoPanel();
void UpdateCollapsibleInfoPanel();
void DeleteInfoPanel();
void UpdateDisplay();
string FormatNumberWithCommas(double number, int decimals);
void CreateProfessionalButtons();
void DeleteButtons();
void OnNewBar();
bool IsMarketOpen();
void CountConsecutiveCandles();
void CheckEntrySignals();
void CheckExitSignals();
void OpenMultipleBuyPositions(int numberOfTrades);
void OpenMultipleSellPositions(int numberOfTrades);
double NormalizeLotSize(double lots);
double CalculateAutoLotSize();
double GetEffectiveLotSize();
double CalculateTakeProfitPoints(double lotSize, double dollarValue);
int CountPositions(ENUM_POSITION_TYPE posType);
void ClosePositionsByType(ENUM_POSITION_TYPE posType);
void CloseAllPositions();
void CloseProfitablePositions();
void CloseProfitablePositionsByType(ENUM_POSITION_TYPE posType);
double CalculateTotalProfit();
int CountProfitablePositions();
int CountLosingPositions();
void ToggleTrading();
void CheckGlobalProfitTarget();
void TogglePanelMinimize();
double CalculateCurrentDrawdownPercent();
void CheckDrawdownProtection();
void EmergencyCloseAllAndDisable();

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("=== TORAMA CAPITAL MEAN REVERSION EA v3.00 INITIALIZING ===");
    
    // Parameter validation
    if(LotSize <= 0)
    {
        Print("ERROR: Invalid lot size");
        return(INIT_PARAMETERS_INCORRECT);
    }
    
    if(UseAutoLotSizing && (AutoLotPer1000 <= 0 || EquityIncrement <= 0))
    {
        Print("ERROR: Invalid auto lot sizing parameters");
        return(INIT_PARAMETERS_INCORRECT);
    }
    
    if(TakeProfitDollars < 0 || GlobalProfitTarget <= 0)
    {
        Print("ERROR: Invalid profit parameters");
        return(INIT_PARAMETERS_INCORRECT);
    }
    
    if(MaxDrawdownPercent < 0 || (MaxDrawdownPercent > 0 && MaxDrawdownPercent < 1))
    {
        Print("ERROR: MaxDrawdownPercent must be 0 (disabled), >= 1%, or <= 100%");
        return(INIT_PARAMETERS_INCORRECT);
    }
    
    if(TradesPerSignal <= 0 || MaxPositions <= 0)
    {
        Print("ERROR: Invalid position parameters");
        return(INIT_PARAMETERS_INCORRECT);
    }
    
    actualTradesPerSignal = TradesPerSignal;
    if(actualTradesPerSignal > MaxPositions)
    {
        Print("WARNING: TradesPerSignal adjusted to MaxPositions");
        actualTradesPerSignal = MaxPositions;
    }
    
    // Trading setup
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(10);
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    trade.SetAsyncMode(false);
    
    // Initialize timeframe
    datetime tempTime = iTime(_Symbol, Timeframe, 0);
    if(tempTime <= 0)
    {
        Print("ERROR: Cannot get chart data for timeframe " + EnumToString(Timeframe));
        return(INIT_FAILED);
    }
    lastBarTime = tempTime;
    
    startingEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(startingEquity == 0) startingEquity = AccountInfoDouble(ACCOUNT_BALANCE);
    drawdownProtectionTriggered = false;
    
    // UI setup
    DeleteButtons();
    DeleteInfoPanel();
    Sleep(500);
    
    isPanelMinimized = StartPanelMinimized;
    
    CountConsecutiveCandles();
    
    if(ShowButtons) CreateProfessionalButtons();
    CreateCollapsibleInfoPanel();
    
    isInitialized = true;
    
    Print("=================================================");
    Print("*** " + COMPANY_NAME + " - " + COMPANY_VERSION + " ***");
    Print("*** MEAN REVERSION STRATEGY INITIALIZED ***");
    Print("=================================================");
    Print("Strategy: CONTRARIAN (Mean Reversion)");
    Print("*** BEARISH CANDLE → " + IntegerToString(actualTradesPerSignal) + " BUY TRADES ***");
    Print("*** BULLISH CANDLE → " + IntegerToString(actualTradesPerSignal) + " SELL TRADES ***");
    Print("Timeframe: " + EnumToString(Timeframe));
    
    if(UseAutoLotSizing)
    {
        double currentLot = GetEffectiveLotSize();
        Print("Auto Lot: " + DoubleToString(currentLot, 3) + " lot (" + DoubleToString(AutoLotPer1000, 3) + " per $" + DoubleToString(EquityIncrement, 0) + ")");
    }
    else
    {
        Print("Fixed Lot: " + DoubleToString(LotSize, 3));
    }
    
    Print("Trades/Signal: " + IntegerToString(actualTradesPerSignal) + " | Max Positions: " + IntegerToString(MaxPositions) + " per direction");
    Print("Take Profit: $" + DoubleToString(TakeProfitDollars, 2) + " per trade");
    Print("Global Target: $" + DoubleToString(GlobalProfitTarget, 2));
    
    if(MaxDrawdownPercent > 0 && MaxDrawdownPercent < 100)
    {
        Print("Drawdown Protection: " + DoubleToString(MaxDrawdownPercent, 1) + "% (ENABLED)");
        Print("Starting Equity: $" + FormatNumberWithCommas(startingEquity, 2));
    }
    else
    {
        Print("Drawdown Protection: DISABLED");
    }
    
    if(EnableConsecutiveCandleExit)
    {
        Print("Consecutive Exit: ENABLED (" + IntegerToString(ConsecutiveCandleCount) + " candles)");
    }
    
    Print("Contact: " + COMPANY_EMAIL + " | Web: " + COMPANY_WEBSITE);
    Print("=================================================");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    DeleteButtons();
    DeleteInfoPanel();
    Comment("");
    Print("EA DEINITIALIZED - Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
    if(!isInitialized) return;
    
    CheckGlobalProfitTarget();
    CheckDrawdownProtection();
    
    datetime currentCandle = iTime(_Symbol, Timeframe, 0);
    
    if(currentCandle != lastBarTime && currentCandle > 0)
    {
        if(lastBarTime > 0)
        {
            Print("*** NEW CANDLE *** Time: " + TimeToString(currentCandle, TIME_DATE|TIME_MINUTES));
            OnNewBar();
        }
        lastBarTime = currentCandle;
    }
    
    UpdateDisplay();
}

//+------------------------------------------------------------------+
//| Chart event handler                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
    if(id == CHARTEVENT_OBJECT_CLICK)
    {
        if(sparam == BTN_TOGGLE_TRADING)
        {
            ToggleTrading();
            ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_STATE, false);
            CreateProfessionalButtons();
        }
        else if(sparam == BTN_CLOSE_PROFITABLE)
        {
            CloseProfitablePositions();
            ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_STATE, false);
        }
        else if(sparam == BTN_PANEL_MINIMIZE)
        {
            TogglePanelMinimize();
            ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_STATE, false);
        }
        ChartRedraw();
    }
}

//+------------------------------------------------------------------+
//| Process new bar                                                   |
//+------------------------------------------------------------------+
void OnNewBar()
{
    Print("=== PROCESSING NEW BAR ===");
    
    CountConsecutiveCandles();
    
    if(!tradingEnabled)
    {
        Print("Trading DISABLED");
        return;
    }
    
    if(!IsMarketOpen())
    {
        Print("Market CLOSED");
        return;
    }
    
    CheckEntrySignals();
    CheckExitSignals();
    Print("=== BAR COMPLETE ===");
}

//+------------------------------------------------------------------+
//| Check if market is open                                           |
//+------------------------------------------------------------------+
bool IsMarketOpen()
{
    return true;
}

//+------------------------------------------------------------------+
//| Count consecutive candles                                         |
//+------------------------------------------------------------------+
void CountConsecutiveCandles()
{
    double open = iOpen(_Symbol, Timeframe, 1);
    double close = iClose(_Symbol, Timeframe, 1);
    
    if(open <= 0 || close <= 0)
    {
        Print("ERROR: Invalid candle data");
        return;
    }
    
    bool isBullish = (close > open);
    bool isBearish = (close < open);
    
    if(isBullish)
    {
        consecutiveBullish++;
        consecutiveBearish = 0;
    }
    else if(isBearish)
    {
        consecutiveBearish++;
        consecutiveBullish = 0;
    }
    
    Print("Consecutive - Bullish: " + IntegerToString(consecutiveBullish) + " Bearish: " + IntegerToString(consecutiveBearish));
}

//+------------------------------------------------------------------+
//| Check entry signals - MEAN REVERSION LOGIC                       |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
    if(drawdownProtectionTriggered)
    {
        Print("ENTRY BLOCKED: Drawdown protection triggered");
        return;
    }
    
    double open = iOpen(_Symbol, Timeframe, 1);
    double close = iClose(_Symbol, Timeframe, 1);
    
    if(open <= 0 || close <= 0)
    {
        Print("ERROR: Invalid price data");
        return;
    }
    
    bool isBearish = (close < open);
    bool isBullish = (close > open);
    
    string candleType = "DOJI";
    if(isBullish) candleType = "BULLISH";
    else if(isBearish) candleType = "BEARISH";
    
    Print("Candle: Open=" + DoubleToString(open, 5) + " Close=" + DoubleToString(close, 5) + " Type=" + candleType);
    
    // MEAN REVERSION LOGIC: Buy on bearish candles (expecting bounce), sell on bullish candles (expecting pullback)
    if(isBearish && (TradeDirection == TRADE_BOTH || TradeDirection == TRADE_BUY_ONLY))
    {
        int currentBuyPositions = CountPositions(POSITION_TYPE_BUY);
        int remainingSlots = MaxPositions - currentBuyPositions;
        int tradesToOpen = MathMin(actualTradesPerSignal, remainingSlots);
        
        Print("*** BEARISH CANDLE - BUY SIGNAL (MEAN REVERSION) ***");
        Print("Logic: Price dropped → Expecting bounce UP");
        Print("Current BUY positions: " + IntegerToString(currentBuyPositions) + " / Max: " + IntegerToString(MaxPositions));
        Print("Remaining slots: " + IntegerToString(remainingSlots) + " | Will open: " + IntegerToString(tradesToOpen) + " trades");
        
        if(tradesToOpen > 0)
        {
            Print(">>> OPENING " + IntegerToString(tradesToOpen) + " BUY POSITIONS (CONTRARIAN) <<<");
            OpenMultipleBuyPositions(tradesToOpen);
        }
        else
        {
            Print("*** BUY SIGNAL IGNORED: Max positions reached ***");
        }
    }
    
    if(isBullish && (TradeDirection == TRADE_BOTH || TradeDirection == TRADE_SELL_ONLY))
    {
        int currentSellPositions = CountPositions(POSITION_TYPE_SELL);
        int remainingSlots = MaxPositions - currentSellPositions;
        int tradesToOpen = MathMin(actualTradesPerSignal, remainingSlots);
        
        Print("*** BULLISH CANDLE - SELL SIGNAL (MEAN REVERSION) ***");
        Print("Logic: Price rallied → Expecting pullback DOWN");
        Print("Current SELL positions: " + IntegerToString(currentSellPositions) + " / Max: " + IntegerToString(MaxPositions));
        Print("Remaining slots: " + IntegerToString(remainingSlots) + " | Will open: " + IntegerToString(tradesToOpen) + " trades");
        
        if(tradesToOpen > 0)
        {
            Print(">>> OPENING " + IntegerToString(tradesToOpen) + " SELL POSITIONS (CONTRARIAN) <<<");
            OpenMultipleSellPositions(tradesToOpen);
        }
        else
        {
            Print("*** SELL SIGNAL IGNORED: Max positions reached ***");
        }
    }
}

//+------------------------------------------------------------------+
//| Check exit signals                                                |
//+------------------------------------------------------------------+
void CheckExitSignals()
{
    if(!EnableConsecutiveCandleExit) return;
    
    // Exit logic: Close profitable positions when mean reversion complete
    if(consecutiveBullish >= ConsecutiveCandleCount && CountPositions(POSITION_TYPE_BUY) > 0)
    {
        Print("[EXIT] " + IntegerToString(ConsecutiveCandleCount) + "+ bullish candles - closing PROFITABLE BUY (reversion complete)");
        CloseProfitablePositionsByType(POSITION_TYPE_BUY);
    }
    
    if(consecutiveBearish >= ConsecutiveCandleCount && CountPositions(POSITION_TYPE_SELL) > 0)
    {
        Print("[EXIT] " + IntegerToString(ConsecutiveCandleCount) + "+ bearish candles - closing PROFITABLE SELL (reversion complete)");
        CloseProfitablePositionsByType(POSITION_TYPE_SELL);
    }
}

//+------------------------------------------------------------------+
//| Calculate take profit points                                      |
//+------------------------------------------------------------------+
double CalculateTakeProfitPoints(double lotSize, double dollarValue)
{
    if(dollarValue <= 0 || lotSize <= 0) return 0;
    
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    
    if(tickValue <= 0 || tickSize <= 0 || pointValue <= 0) return 0;
    
    double valuePerPoint = (tickValue / tickSize) * pointValue * lotSize;
    if(valuePerPoint <= 0) return 0;
    
    double pointsForDollarValue = dollarValue / valuePerPoint;
    
    Print("TP Calculation: $" + DoubleToString(dollarValue, 2) + " = " + DoubleToString(pointsForDollarValue, 2) + " points");
    
    return pointsForDollarValue;
}

//+------------------------------------------------------------------+
//| Open multiple buy positions                                       |
//+------------------------------------------------------------------+
void OpenMultipleBuyPositions(int numberOfTrades)
{
    int successCount = 0;
    int failCount = 0;
    
    for(int trade_num = 1; trade_num <= numberOfTrades; trade_num++)
    {
        Print("Opening BUY trade " + IntegerToString(trade_num) + " of " + IntegerToString(numberOfTrades));
        
        bool success = false;
        for(int attempt = 1; attempt <= MaxRetries; attempt++)
        {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            if(ask <= 0) break;
            
            double normalizedLot = GetEffectiveLotSize();
            if(normalizedLot <= 0) break;
            
            double sl = (StopLoss > 0) ? ask - StopLoss * _Point : 0;
            double tp = 0;
            
            if(TakeProfitDollars > 0)
            {
                double tpPoints = CalculateTakeProfitPoints(normalizedLot, TakeProfitDollars);
                if(tpPoints > 0)
                {
                    tp = ask + tpPoints * _Point;
                    Print("BUY TP: $" + DoubleToString(TakeProfitDollars, 2) + " at " + DoubleToString(tp, 5));
                }
            }
            
            if(trade.Buy(normalizedLot, _Symbol, ask, sl, tp, TradeComment))
            {
                Print("[SUCCESS] BUY #" + IntegerToString(trade.ResultOrder()) + " opened!");
                successCount++;
                success = true;
                break;
            }
            else
            {
                Print("[ATTEMPT " + IntegerToString(attempt) + "] Failed - Error: " + IntegerToString(trade.ResultRetcode()));
                if(attempt < MaxRetries) Sleep(RetryDelay);
            }
        }
        
        if(!success) failCount++;
        if(trade_num < numberOfTrades) Sleep(50);
    }
    
    Print("=== BUY SUMMARY: Success=" + IntegerToString(successCount) + " Failed=" + IntegerToString(failCount) + " ===");
}

//+------------------------------------------------------------------+
//| Open multiple sell positions                                      |
//+------------------------------------------------------------------+
void OpenMultipleSellPositions(int numberOfTrades)
{
    int successCount = 0;
    int failCount = 0;
    
    for(int trade_num = 1; trade_num <= numberOfTrades; trade_num++)
    {
        Print("Opening SELL trade " + IntegerToString(trade_num) + " of " + IntegerToString(numberOfTrades));
        
        bool success = false;
        for(int attempt = 1; attempt <= MaxRetries; attempt++)
        {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            if(bid <= 0) break;
            
            double normalizedLot = GetEffectiveLotSize();
            if(normalizedLot <= 0) break;
            
            double sl = (StopLoss > 0) ? bid + StopLoss * _Point : 0;
            double tp = 0;
            
            if(TakeProfitDollars > 0)
            {
                double tpPoints = CalculateTakeProfitPoints(normalizedLot, TakeProfitDollars);
                if(tpPoints > 0)
                {
                    tp = bid - tpPoints * _Point;
                    Print("SELL TP: $" + DoubleToString(TakeProfitDollars, 2) + " at " + DoubleToString(tp, 5));
                }
            }
            
            if(trade.Sell(normalizedLot, _Symbol, bid, sl, tp, TradeComment))
            {
                Print("[SUCCESS] SELL #" + IntegerToString(trade.ResultOrder()) + " opened!");
                successCount++;
                success = true;
                break;
            }
            else
            {
                Print("[ATTEMPT " + IntegerToString(attempt) + "] Failed - Error: " + IntegerToString(trade.ResultRetcode()));
                if(attempt < MaxRetries) Sleep(RetryDelay);
            }
        }
        
        if(!success) failCount++;
        if(trade_num < numberOfTrades) Sleep(50);
    }
    
    Print("=== SELL SUMMARY: Success=" + IntegerToString(successCount) + " Failed=" + IntegerToString(failCount) + " ===");
}

//+------------------------------------------------------------------+
//| Normalize lot size                                                |
//+------------------------------------------------------------------+
double NormalizeLotSize(double lots)
{
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    if(minLot <= 0 || maxLot <= 0 || stepLot <= 0) return 0;
    
    if(lots < minLot) lots = minLot;
    if(lots > maxLot) lots = maxLot;
    
    lots = MathRound(lots / stepLot) * stepLot;
    if(lots < minLot) lots = minLot;
    
    return lots;
}

//+------------------------------------------------------------------+
//| Calculate automatic lot size                                      |
//+------------------------------------------------------------------+
double CalculateAutoLotSize()
{
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(equity <= 0 || EquityIncrement <= 0) return LotSize;
    
    double lotMultiplier = MathCeil(equity / EquityIncrement);
    double calculatedLot = lotMultiplier * AutoLotPer1000;
    
    return calculatedLot;
}

//+------------------------------------------------------------------+
//| Get effective lot size                                            |
//+------------------------------------------------------------------+
double GetEffectiveLotSize()
{
    if(UseAutoLotSizing)
    {
        return NormalizeLotSize(CalculateAutoLotSize());
    }
    else
    {
        return NormalizeLotSize(LotSize);
    }
}

//+------------------------------------------------------------------+
//| Count positions by type                                           |
//+------------------------------------------------------------------+
int CountPositions(ENUM_POSITION_TYPE posType)
{
    int count = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetInteger(POSITION_TYPE) == posType)
            {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Close positions by type                                           |
//+------------------------------------------------------------------+
void ClosePositionsByType(ENUM_POSITION_TYPE posType)
{
    int closedCount = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetTicket(i))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetInteger(POSITION_TYPE) == posType)
            {
                if(trade.PositionClose(PositionGetInteger(POSITION_TICKET)))
                    closedCount++;
            }
        }
    }
    Print("Closed " + IntegerToString(closedCount) + " positions");
}

//+------------------------------------------------------------------+
//| Close all positions                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
    int closedCount = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetTicket(i))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                if(trade.PositionClose(PositionGetInteger(POSITION_TICKET)))
                    closedCount++;
            }
        }
    }
    Print("Closed " + IntegerToString(closedCount) + " positions");
}

//+------------------------------------------------------------------+
//| Close profitable positions                                        |
//+------------------------------------------------------------------+
void CloseProfitablePositions()
{
    int closedCount = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetTicket(i))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                if(PositionGetDouble(POSITION_PROFIT) > 0)
                {
                    if(trade.PositionClose(PositionGetInteger(POSITION_TICKET)))
                        closedCount++;
                }
            }
        }
    }
    Print("Closed " + IntegerToString(closedCount) + " profitable positions");
}

//+------------------------------------------------------------------+
//| Close profitable positions by type                                |
//+------------------------------------------------------------------+
void CloseProfitablePositionsByType(ENUM_POSITION_TYPE posType)
{
    int closedCount = 0;
    int losingCount = 0;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetTicket(i))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetInteger(POSITION_TYPE) == posType)
            {
                double profit = PositionGetDouble(POSITION_PROFIT);
                ulong ticket = PositionGetInteger(POSITION_TICKET);
                
                if(profit > 0)
                {
                    if(trade.PositionClose(ticket))
                    {
                        closedCount++;
                        Print(">>> CLOSED PROFITABLE #" + IntegerToString(ticket) + " P/L: +" + DoubleToString(profit, 2));
                    }
                }
                else
                {
                    losingCount++;
                    Print(">>> KEEPING LOSING #" + IntegerToString(ticket) + " P/L: " + DoubleToString(profit, 2));
                }
            }
        }
    }
    
    string posTypeStr = (posType == POSITION_TYPE_BUY) ? "BUY" : "SELL";
    Print("Closed " + IntegerToString(closedCount) + " profitable " + posTypeStr + " | Kept " + IntegerToString(losingCount) + " losing");
}

//+------------------------------------------------------------------+
//| Calculate total profit                                            |
//+------------------------------------------------------------------+
double CalculateTotalProfit()
{
    double totalProfit = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                totalProfit += PositionGetDouble(POSITION_PROFIT);
            }
        }
    }
    return totalProfit;
}

//+------------------------------------------------------------------+
//| Count profitable positions                                        |
//+------------------------------------------------------------------+
int CountProfitablePositions()
{
    int count = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetDouble(POSITION_PROFIT) > 0)
            {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Count losing positions                                            |
//+------------------------------------------------------------------+
int CountLosingPositions()
{
    int count = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetDouble(POSITION_PROFIT) < 0)
            {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Toggle trading on/off                                             |
//+------------------------------------------------------------------+
void ToggleTrading()
{
    tradingEnabled = !tradingEnabled;
    Print("Trading " + (tradingEnabled ? "ENABLED" : "DISABLED"));
}

//+------------------------------------------------------------------+
//| Check global profit target                                        |
//+------------------------------------------------------------------+
void CheckGlobalProfitTarget()
{
    if(GlobalProfitTarget <= 0) return;
    
    double totalProfit = CalculateTotalProfit();
    
    if(totalProfit >= GlobalProfitTarget)
    {
        int profitableCount = CountProfitablePositions();
        
        if(profitableCount > 0)
        {
            Print("========================================");
            Print("*** GLOBAL PROFIT TARGET REACHED ***");
            Print("Total Profit: $" + DoubleToString(totalProfit, 2) + " / Target: $" + DoubleToString(GlobalProfitTarget, 2));
            Print("Closing " + IntegerToString(profitableCount) + " profitable positions...");
            Print("========================================");
            
            CloseProfitablePositions();
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate current drawdown percentage                             |
//+------------------------------------------------------------------+
double CalculateCurrentDrawdownPercent()
{
    if(startingEquity <= 0) return 0;
    
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    if(currentEquity >= startingEquity) return 0;
    
    return ((startingEquity - currentEquity) / startingEquity) * 100.0;
}

//+------------------------------------------------------------------+
//| Check drawdown protection                                         |
//+------------------------------------------------------------------+
void CheckDrawdownProtection()
{
    if(MaxDrawdownPercent <= 0 || MaxDrawdownPercent >= 100 || drawdownProtectionTriggered)
        return;
    
    double currentDrawdown = CalculateCurrentDrawdownPercent();
    
    if(currentDrawdown >= MaxDrawdownPercent)
    {
        Print("========================================");
        Print("*** EMERGENCY: MAXIMUM DRAWDOWN REACHED ***");
        Print("Drawdown: " + DoubleToString(currentDrawdown, 2) + "% / Max: " + DoubleToString(MaxDrawdownPercent, 2) + "%");
        Print("========================================");
        
        EmergencyCloseAllAndDisable();
    }
}

//+------------------------------------------------------------------+
//| Emergency close all and disable                                   |
//+------------------------------------------------------------------+
void EmergencyCloseAllAndDisable()
{
    drawdownProtectionTriggered = true;
    tradingEnabled = false;
    
    int closedCount = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionGetTicket(i))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
                if(trade.PositionClose(PositionGetInteger(POSITION_TICKET)))
                    closedCount++;
            }
        }
    }
    
    Print("EMERGENCY CLOSURE: " + IntegerToString(closedCount) + " positions closed");
    Print("EA DISABLED - Manual restart required");
    
    if(ShowButtons) CreateProfessionalButtons();
}

//+------------------------------------------------------------------+
//| Toggle panel minimize                                             |
//+------------------------------------------------------------------+
void TogglePanelMinimize()
{
    isPanelMinimized = !isPanelMinimized;
    DeleteInfoPanel();
    Sleep(100);
    CreateCollapsibleInfoPanel();
    Print("Panel " + (isPanelMinimized ? "MINIMIZED" : "EXPANDED"));
}

//+------------------------------------------------------------------+
//| Format number with commas                                         |
//+------------------------------------------------------------------+
string FormatNumberWithCommas(double number, int decimals = 2)
{
    string result = DoubleToString(number, decimals);
    string wholePart = "";
    string decimalPart = "";
    
    int dotPos = StringFind(result, ".");
    if(dotPos >= 0)
    {
        wholePart = StringSubstr(result, 0, dotPos);
        decimalPart = StringSubstr(result, dotPos);
    }
    else
    {
        wholePart = result;
    }
    
    string formatted = "";
    int len = StringLen(wholePart);
    
    for(int i = 0; i < len; i++)
    {
        if(i > 0 && (len - i) % 3 == 0)
            formatted += ",";
        formatted += StringSubstr(wholePart, i, 1);
    }
    
    return formatted + decimalPart;
}

//+------------------------------------------------------------------+
//| Create professional buttons                                       |
//+------------------------------------------------------------------+
void CreateProfessionalButtons()
{
    long chartWidth = ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
    if(chartWidth <= 200) chartWidth = 800;
    
    int buttonWidth = 140;
    int buttonHeight = 28;
    int spacing = 10;
    int totalWidth = (buttonWidth * 2) + spacing;
    int startX = (int)(chartWidth - totalWidth) / 2;
    int startY = 15;
    
    // Toggle Trading Button
    ObjectDelete(0, BTN_TOGGLE_TRADING);
    ObjectCreate(0, BTN_TOGGLE_TRADING, OBJ_BUTTON, 0, 0, 0);
    ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_XDISTANCE, startX);
    ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_YDISTANCE, startY);
    ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_XSIZE, buttonWidth);
    ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_YSIZE, buttonHeight);
    
    string toggleText = tradingEnabled ? "⏸ PAUSE" : "▶ START";
    if(drawdownProtectionTriggered) toggleText = "🚨 DISABLED";
    
    ObjectSetString(0, BTN_TOGGLE_TRADING, OBJPROP_TEXT, toggleText);
    ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_FONTSIZE, 9);
    ObjectSetString(0, BTN_TOGGLE_TRADING, OBJPROP_FONT, "Arial Bold");
    ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
    
    if(drawdownProtectionTriggered)
        ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_BGCOLOR, BRAND_DANGER_RED);
    else if(tradingEnabled)
        ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_BGCOLOR, BRAND_WARNING_ORANGE);
    else
        ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_BGCOLOR, BRAND_SUCCESS_GREEN);
    
    ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_BORDER_COLOR, BRAND_BORDER_LIGHT);
    ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    
    // Close Profitable Button
    ObjectDelete(0, BTN_CLOSE_PROFITABLE);
    ObjectCreate(0, BTN_CLOSE_PROFITABLE, OBJ_BUTTON, 0, 0, 0);
    ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_XDISTANCE, startX + buttonWidth + spacing);
    ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_YDISTANCE, startY);
    ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_XSIZE, buttonWidth);
    ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_YSIZE, buttonHeight);
    ObjectSetString(0, BTN_CLOSE_PROFITABLE, OBJPROP_TEXT, "💰 Close Profits");
    ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_FONTSIZE, 9);
    ObjectSetString(0, BTN_CLOSE_PROFITABLE, OBJPROP_FONT, "Arial Bold");
    ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
    ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_BGCOLOR, BRAND_SUCCESS_GREEN);
    ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_BORDER_COLOR, BRAND_BORDER_LIGHT);
    ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Delete buttons                                                    |
//+------------------------------------------------------------------+
void DeleteButtons()
{
    ObjectDelete(0, BTN_TOGGLE_TRADING);
    ObjectDelete(0, BTN_CLOSE_PROFITABLE);
    ObjectDelete(0, BTN_PANEL_MINIMIZE);
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Create collapsible info panel with improved layout                |
//+------------------------------------------------------------------+
void CreateCollapsibleInfoPanel()
{
    DeleteInfoPanel();
    
    int panelX = 10;
    int panelY = 25;
    int panelWidth = 420;
    int lineHeight = 18;
    int padding = 8;
    int currentY = panelY;
    
    int headerHeight = 45;
    int contentHeight = isPanelMinimized ? 0 : 280;
    int buttonHeight = ShowButtons ? 28 : 0;
    int panelHeight = headerHeight + contentHeight + buttonHeight + (padding * 2);
    
    // Main background
    ObjectCreate(0, INFO_PANEL_BACKGROUND, OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_XDISTANCE, panelX);
    ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_YDISTANCE, panelY);
    ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_XSIZE, panelWidth);
    ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_YSIZE, panelHeight);
    ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_BGCOLOR, BRAND_DARK_BG);
    ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_COLOR, BRAND_BORDER_LIGHT);
    ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_HIDDEN, true);
    
    currentY += padding;
    
    // Header with company name
    ObjectCreate(0, "companyName", OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, "companyName", OBJPROP_XDISTANCE, panelX + padding);
    ObjectSetInteger(0, "companyName", OBJPROP_YDISTANCE, currentY);
    ObjectSetString(0, "companyName", OBJPROP_TEXT, COMPANY_NAME);
    ObjectSetInteger(0, "companyName", OBJPROP_FONTSIZE, 11);
    ObjectSetString(0, "companyName", OBJPROP_FONT, "Arial Bold");
    ObjectSetInteger(0, "companyName", OBJPROP_COLOR, BRAND_SECONDARY_GOLD);
    ObjectSetInteger(0, "companyName", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, "companyName", OBJPROP_SELECTABLE, false);
    
    currentY += 16;
    
    // Tagline
    ObjectCreate(0, "companyTagline", OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, "companyTagline", OBJPROP_XDISTANCE, panelX + padding);
    ObjectSetInteger(0, "companyTagline", OBJPROP_YDISTANCE, currentY);
    ObjectSetString(0, "companyTagline", OBJPROP_TEXT, COMPANY_TAGLINE + " | " + COMPANY_VERSION);
    ObjectSetInteger(0, "companyTagline", OBJPROP_FONTSIZE, 8);
    ObjectSetString(0, "companyTagline", OBJPROP_FONT, "Arial");
    ObjectSetInteger(0, "companyTagline", OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
    ObjectSetInteger(0, "companyTagline", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, "companyTagline", OBJPROP_SELECTABLE, false);
    
    // Minimize button
    ObjectCreate(0, BTN_PANEL_MINIMIZE, OBJ_BUTTON, 0, 0, 0);
    ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_XDISTANCE, panelX + panelWidth - 30);
    ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_YDISTANCE, panelY + 8);
    ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_XSIZE, 22);
    ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_YSIZE, 22);
    ObjectSetString(0, BTN_PANEL_MINIMIZE, OBJPROP_TEXT, isPanelMinimized ? "+" : "−");
    ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_FONTSIZE, 10);
    ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
    ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_BGCOLOR, BRAND_LIGHT_BG);
    ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_BORDER_COLOR, BRAND_BORDER_LIGHT);
    ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    
    currentY += 20;
    
    if(!isPanelMinimized)
    {
        // Get current data
        double balance = AccountInfoDouble(ACCOUNT_BALANCE);
        double equity = AccountInfoDouble(ACCOUNT_EQUITY);
        double margin = AccountInfoDouble(ACCOUNT_MARGIN);
        double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
        double totalProfit = CalculateTotalProfit();
        double currentDrawdown = CalculateCurrentDrawdownPercent();
        
        int buyPositions = CountPositions(POSITION_TYPE_BUY);
        int sellPositions = CountPositions(POSITION_TYPE_SELL);
        int profitablePositions = CountProfitablePositions();
        int losingPositions = CountLosingPositions();
        
        double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
        long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
        
        string tradingStatus = tradingEnabled ? "ACTIVE" : "PAUSED";
        if(drawdownProtectionTriggered) tradingStatus = "EMERGENCY STOP";
        color statusColor = drawdownProtectionTriggered ? BRAND_DANGER_RED :
                           (tradingEnabled ? BRAND_SUCCESS_GREEN : BRAND_WARNING_ORANGE);
        
        string directionText = (TradeDirection == TRADE_BOTH) ? "Both" : 
                               (TradeDirection == TRADE_BUY_ONLY) ? "Buy Only" : "Sell Only";
        
        currentY += 5;
        
        // Price (Bold) - Row 1
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "0", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0", OBJPROP_XDISTANCE, panelX + padding);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "0", OBJPROP_TEXT, "Price: " + DoubleToString(currentPrice, _Digits));
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "0", OBJPROP_FONT, "Arial Bold");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0", OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0", OBJPROP_SELECTABLE, false);
        
        // Spread - same row
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "0b", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0b", OBJPROP_XDISTANCE, panelX + 220);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0b", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "0b", OBJPROP_TEXT, "Spread: " + DoubleToString(spreadPoints, 1));
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0b", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "0b", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0b", OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0b", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0b", OBJPROP_SELECTABLE, false);
        
        currentY += lineHeight;
        
        // Balance (Bold) - Row 2
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "1", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "1", OBJPROP_XDISTANCE, panelX + padding);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "1", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "1", OBJPROP_TEXT, "Balance: $" + FormatNumberWithCommas(balance, 2));
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "1", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "1", OBJPROP_FONT, "Arial Bold");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "1", OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "1", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "1", OBJPROP_SELECTABLE, false);
        
        currentY += lineHeight;
        
        // Equity (Bold) - Row 3
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "2", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "2", OBJPROP_XDISTANCE, panelX + padding);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "2", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "2", OBJPROP_TEXT, "Equity: $" + FormatNumberWithCommas(equity, 2));
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "2", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "2", OBJPROP_FONT, "Arial Bold");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "2", OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "2", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "2", OBJPROP_SELECTABLE, false);
        
        currentY += lineHeight;
        
        // Margin (Bold) - Row 4
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "3", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "3", OBJPROP_XDISTANCE, panelX + padding);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "3", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "3", OBJPROP_TEXT, "Margin: $" + FormatNumberWithCommas(margin, 2));
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "3", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "3", OBJPROP_FONT, "Arial Bold");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "3", OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "3", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "3", OBJPROP_SELECTABLE, false);
        
        // Free Margin - same row
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "3b", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "3b", OBJPROP_XDISTANCE, panelX + 220);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "3b", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "3b", OBJPROP_TEXT, "Free: $" + FormatNumberWithCommas(freeMargin, 2));
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "3b", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "3b", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "3b", OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "3b", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "3b", OBJPROP_SELECTABLE, false);
        
        currentY += lineHeight + 3;
        
        // P/L (Bold) - Row 5
        color plColor = (totalProfit >= 0) ? BRAND_SUCCESS_GREEN : BRAND_DANGER_RED;
        string plText = (totalProfit >= 0 ? "+" : "") + "$" + FormatNumberWithCommas(totalProfit, 2);
        
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "4", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "4", OBJPROP_XDISTANCE, panelX + padding);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "4", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "4", OBJPROP_TEXT, "P/L: " + plText);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "4", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "4", OBJPROP_FONT, "Arial Bold");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "4", OBJPROP_COLOR, plColor);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "4", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "4", OBJPROP_SELECTABLE, false);
        
        // Drawdown - same row
        color ddColor = (currentDrawdown < 10) ? BRAND_SUCCESS_GREEN : 
                        (currentDrawdown < 20) ? BRAND_WARNING_ORANGE : BRAND_DANGER_RED;
        
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "4b", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "4b", OBJPROP_XDISTANCE, panelX + 220);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "4b", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "4b", OBJPROP_TEXT, "DD: " + DoubleToString(currentDrawdown, 1) + "%");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "4b", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "4b", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "4b", OBJPROP_COLOR, ddColor);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "4b", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "4b", OBJPROP_SELECTABLE, false);
        
        currentY += lineHeight;
        
        // BUY Positions - Row 6
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "5", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5", OBJPROP_XDISTANCE, panelX + padding);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "5", OBJPROP_TEXT, "BUY: " + IntegerToString(buyPositions) + "/" + IntegerToString(MaxPositions));
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "5", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5", OBJPROP_COLOR, BRAND_SUCCESS_GREEN);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5", OBJPROP_SELECTABLE, false);
        
        // SELL Positions - same row
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "5b", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5b", OBJPROP_XDISTANCE, panelX + 140);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5b", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "5b", OBJPROP_TEXT, "SELL: " + IntegerToString(sellPositions) + "/" + IntegerToString(MaxPositions));
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5b", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "5b", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5b", OBJPROP_COLOR, BRAND_DANGER_RED);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5b", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5b", OBJPROP_SELECTABLE, false);
        
        // Profitable/Losing - same row
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "5c", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5c", OBJPROP_XDISTANCE, panelX + 280);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5c", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "5c", OBJPROP_TEXT, "+" + IntegerToString(profitablePositions) + "/-" + IntegerToString(losingPositions));
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5c", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "5c", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5c", OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5c", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "5c", OBJPROP_SELECTABLE, false);
        
        currentY += lineHeight + 3;
        
        // Status - Row 7
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "6", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "6", OBJPROP_XDISTANCE, panelX + padding);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "6", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "6", OBJPROP_TEXT, "Status: " + tradingStatus);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "6", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "6", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "6", OBJPROP_COLOR, statusColor);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "6", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "6", OBJPROP_SELECTABLE, false);
        
        // Direction - same row
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "6b", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "6b", OBJPROP_XDISTANCE, panelX + 180);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "6b", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "6b", OBJPROP_TEXT, "Dir: " + directionText);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "6b", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "6b", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "6b", OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "6b", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "6b", OBJPROP_SELECTABLE, false);
        
        currentY += lineHeight;
        
        // Strategy Label - Row 8
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "7", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "7", OBJPROP_XDISTANCE, panelX + padding);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "7", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "7", OBJPROP_TEXT, "Strategy: MEAN REVERSION");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "7", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "7", OBJPROP_FONT, "Arial Bold");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "7", OBJPROP_COLOR, BRAND_ACCENT_TEAL);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "7", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "7", OBJPROP_SELECTABLE, false);
        
        currentY += lineHeight;
        
        // Symbol - Row 9
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "8", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "8", OBJPROP_XDISTANCE, panelX + padding);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "8", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "8", OBJPROP_TEXT, "Symbol: " + _Symbol);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "8", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "8", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "8", OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "8", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "8", OBJPROP_SELECTABLE, false);
        
        // Timeframe - same row
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "8b", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "8b", OBJPROP_XDISTANCE, panelX + 180);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "8b", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "8b", OBJPROP_TEXT, "TF: " + EnumToString(Timeframe));
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "8b", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "8b", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "8b", OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "8b", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "8b", OBJPROP_SELECTABLE, false);
        
        currentY += lineHeight;
        
        // Lot Size - Row 10
        double effectiveLot = GetEffectiveLotSize();
        string lotSizing = UseAutoLotSizing ? " (Auto)" : " (Fixed)";
        
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "9", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9", OBJPROP_XDISTANCE, panelX + padding);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "9", OBJPROP_TEXT, "Lot: " + DoubleToString(effectiveLot, 2) + lotSizing);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "9", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9", OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9", OBJPROP_SELECTABLE, false);
        
        // TP - same row
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "9b", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9b", OBJPROP_XDISTANCE, panelX + 180);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9b", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "9b", OBJPROP_TEXT, "TP: $" + DoubleToString(TakeProfitDollars, 2));
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9b", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "9b", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9b", OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9b", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9b", OBJPROP_SELECTABLE, false);
        
        // Global Target - same row
        ObjectCreate(0, INFO_PANEL_LINE_PREFIX + "9c", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9c", OBJPROP_XDISTANCE, panelX + 280);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9c", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "9c", OBJPROP_TEXT, "GT: $" + DoubleToString(GlobalProfitTarget, 0));
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9c", OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "9c", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9c", OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9c", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "9c", OBJPROP_SELECTABLE, false);
        
        currentY += lineHeight + 5;
        
        // BUTTONS SECTION
        if(ShowButtons)
        {
            int buttonY = currentY;
            int buttonWidth = 125;
            int buttonHeight = 24;
            int buttonSpacing = 10;
            
            // Toggle Trading Button
            ObjectCreate(0, BTN_TOGGLE_TRADING, OBJ_BUTTON, 0, 0, 0);
            ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_XDISTANCE, panelX + padding);
            ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_YDISTANCE, buttonY);
            ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_XSIZE, buttonWidth);
            ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_YSIZE, buttonHeight);
            ObjectSetString(0, BTN_TOGGLE_TRADING, OBJPROP_TEXT, tradingEnabled ? "PAUSE" : "RESUME");
            ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_FONTSIZE, 9);
            ObjectSetString(0, BTN_TOGGLE_TRADING, OBJPROP_FONT, "Arial Bold");
            ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
            ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_BGCOLOR, tradingEnabled ? BRAND_WARNING_ORANGE : BRAND_SUCCESS_GREEN);
            ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_BORDER_COLOR, BRAND_BORDER_LIGHT);
            ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_CORNER, CORNER_LEFT_UPPER);
            
            // Close Profitable Button
            ObjectCreate(0, BTN_CLOSE_PROFITABLE, OBJ_BUTTON, 0, 0, 0);
            ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_XDISTANCE, panelX + padding + buttonWidth + buttonSpacing);
            ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_YDISTANCE, buttonY);
            ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_XSIZE, buttonWidth);
            ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_YSIZE, buttonHeight);
            ObjectSetString(0, BTN_CLOSE_PROFITABLE, OBJPROP_TEXT, "Close Profitable");
            ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_FONTSIZE, 9);
            ObjectSetString(0, BTN_CLOSE_PROFITABLE, OBJPROP_FONT, "Arial Bold");
            ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
            ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_BGCOLOR, BRAND_SUCCESS_GREEN);
            ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_BORDER_COLOR, BRAND_BORDER_LIGHT);
            ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        }
        
        // Footer
        currentY += buttonHeight + 8;
        
        ObjectCreate(0, "companyWebsite", OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, "companyWebsite", OBJPROP_XDISTANCE, panelX + padding);
        ObjectSetInteger(0, "companyWebsite", OBJPROP_YDISTANCE, currentY);
        ObjectSetString(0, "companyWebsite", OBJPROP_TEXT, COMPANY_WEBSITE + " | " + COMPANY_EMAIL);
        ObjectSetInteger(0, "companyWebsite", OBJPROP_FONTSIZE, 7);
        ObjectSetString(0, "companyWebsite", OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, "companyWebsite", OBJPROP_COLOR, BRAND_ACCENT_TEAL);
        ObjectSetInteger(0, "companyWebsite", OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, "companyWebsite", OBJPROP_SELECTABLE, false);
    }
    else
    {
        // Minimized view
        ObjectCreate(0, COMPACT_INFO_LABEL, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_XDISTANCE, panelX + padding);
        ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_YDISTANCE, currentY);
        
        string compactText = StringFormat("MEAN REV | %s | Bal: $%.2f | Eq: $%.2f | P/L: $%.2f", 
                                          tradingEnabled ? "ACTIVE" : "PAUSED",
                                          AccountInfoDouble(ACCOUNT_BALANCE),
                                          AccountInfoDouble(ACCOUNT_EQUITY),
                                          CalculateTotalProfit());
        
        ObjectSetString(0, COMPACT_INFO_LABEL, OBJPROP_TEXT, compactText);
        ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_FONTSIZE, 8);
        ObjectSetString(0, COMPACT_INFO_LABEL, OBJPROP_FONT, "Arial");
        ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
        ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_SELECTABLE, false);
    }
    
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update collapsible info panel                                     |
//+------------------------------------------------------------------+
void UpdateCollapsibleInfoPanel()
{
    CreateCollapsibleInfoPanel();
}

//+------------------------------------------------------------------+
//| Delete info panel                                                 |
//+------------------------------------------------------------------+
void DeleteInfoPanel()
{
    Comment("");
    
    ObjectDelete(0, INFO_PANEL_BACKGROUND);
    ObjectDelete(0, "companyName");
    ObjectDelete(0, "companyTagline");
    ObjectDelete(0, "companyWebsite");
    ObjectDelete(0, COMPACT_INFO_LABEL);
    ObjectDelete(0, BTN_TOGGLE_TRADING);
    ObjectDelete(0, BTN_CLOSE_PROFITABLE);
    ObjectDelete(0, BTN_PANEL_MINIMIZE);
    
    for(int i = 0; i < 30; i++)
    {
        ObjectDelete(0, INFO_PANEL_LINE_PREFIX + IntegerToString(i));
        ObjectDelete(0, INFO_PANEL_LINE_PREFIX + IntegerToString(i) + "b");
        ObjectDelete(0, INFO_PANEL_LINE_PREFIX + IntegerToString(i) + "c");
    }
    
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update display                                                     |
//+------------------------------------------------------------------+
void UpdateDisplay()
{
    if(!isInitialized) return;
    UpdateCollapsibleInfoPanel();
}
//+------------------------------------------------------------------+
