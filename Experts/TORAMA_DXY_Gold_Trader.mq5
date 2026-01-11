//+------------------------------------------------------------------+
//|                                    TORAMA_DXY_Gold_Trader.mq5    |
//|                                          TORAMA CAPITAL          |
//|                                      https://www.torama.money    |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "1.00"
#property description "Trades Gold based on Synthetic Dollar Index breakouts"
#property description "Contact: ea@torama.money"

//--- Input Parameters
input group "===== DXY Calculation ====="
input bool UseSimplifiedDXY = true;           // Use Simplified 3-Pair DXY (faster)
input int DXY_Period = 1;                     // DXY Calculation Period (bars lookback)

input group "===== Level Detection ====="
input double LevelSpacing = 1.0;              // DXY Level Spacing (points)
input int SwingBars = 20;                     // Swing Detection Period (bars)
input int BreakoutConfirmBars = 2;            // Breakout Confirmation Bars

input group "===== Risk Management ====="
input double RiskPercent = 1.0;               // Risk Per Trade (%)
input double RiskRewardRatio = 2.5;           // Risk:Reward Ratio
input int ATR_Period = 14;                    // ATR Period
input double ATR_StopMultiplier = 2.0;        // ATR Stop Loss Multiplier
input int MaxPositions = 2;                   // Maximum Concurrent Positions
input double MaxDailyDrawdown = 5.0;          // Max Daily Drawdown (%)

input group "===== Entry Filters ====="
input double MinDXYMovement = 0.3;            // Minimum DXY Movement for Signal
input int MaxSpreadPoints = 50;               // Maximum Gold Spread (points)
input bool UseNewsFilter = true;              // Enable News Time Filter
input string NewsFilterStart = "13:30";       // News Filter Start Time
input string NewsFilterEnd = "14:30";         // News Filter End Time

input group "===== Position Management ====="
input bool UseTrailingStop = true;            // Enable Trailing Stop
input double TrailingActivation = 1.5;        // Trailing Activation (R multiple)
input double TrailingDistance = 1.0;          // Trailing Distance (ATR multiple)

input group "===== UI Settings ====="
input color PanelColor = clrNavy;             // Panel Background Color
input color TextColor = clrWhite;             // Text Color
input int FontSize = 9;                       // Font Size

//--- Global Variables
string symbol_EURUSD = "EURUSDc";
string symbol_USDJPY = "USDJPYc";
string symbol_GBPUSD = "GBPUSDc";
string symbol_USDCAD = "USDCADc";
string symbol_USDSEK = "USDSEKc";
string symbol_USDCHF = "USDCHFc";

double currentDXY = 0.0;
double previousDXY = 0.0;
double resistanceLevel = 0.0;
double supportLevel = 0.0;

datetime lastBarTime = 0;
double dailyStartBalance = 0.0;
datetime dailyStartTime = 0;

int atr_handle;
double atr_buffer[];

struct TradeStats
{
    int totalTrades;
    int winningTrades;
    int losingTrades;
    double totalProfit;
    double totalLoss;
    datetime lastTradeTime;
};
TradeStats stats;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Initialize ATR indicator
    atr_handle = iATR(_Symbol, PERIOD_CURRENT, ATR_Period);
    if(atr_handle == INVALID_HANDLE)
    {
        Print("Failed to create ATR indicator");
        return INIT_FAILED;
    }
    
    ArraySetAsSeries(atr_buffer, true);
    
    // Initialize daily tracking
    dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    dailyStartTime = TimeCurrent();
    
    // Initialize stats
    stats.totalTrades = 0;
    stats.winningTrades = 0;
    stats.losingTrades = 0;
    stats.totalProfit = 0.0;
    stats.totalLoss = 0.0;
    stats.lastTradeTime = 0;
    
    // Create UI Panel
    CreatePanel();
    
    Print("TORAMA DXY Gold Trader initialized successfully");
    Print("Trading ", _Symbol, " based on synthetic DXY movements");
    
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    // Release indicator handle
    if(atr_handle != INVALID_HANDLE)
        IndicatorRelease(atr_handle);
    
    // Delete UI objects
    ObjectsDeleteAll(0, "TORAMA_");
    
    Print("TORAMA DXY Gold Trader stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Check for new bar
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    bool isNewBar = (currentBarTime != lastBarTime);
    
    if(isNewBar)
    {
        lastBarTime = currentBarTime;
        
        // Check daily reset
        CheckDailyReset();
        
        // Update DXY calculation
        previousDXY = currentDXY;
        currentDXY = CalculateSyntheticDXY();
        
        if(currentDXY <= 0)
        {
            UpdatePanel();
            return; // Invalid DXY calculation
        }
        
        // Update support/resistance levels
        UpdateDXYLevels();
        
        // Check for trade signals
        if(CheckFilters())
        {
            CheckForSignals();
        }
        
        // Manage existing positions
        ManagePositions();
    }
    
    // Update trailing stops on every tick
    if(UseTrailingStop)
        UpdateTrailingStops();
    
    // Update UI
    UpdatePanel();
}

//+------------------------------------------------------------------+
//| Calculate Synthetic Dollar Index                                 |
//+------------------------------------------------------------------+
double CalculateSyntheticDXY()
{
    double eurusd = GetSymbolPrice(symbol_EURUSD);
    double usdjpy = GetSymbolPrice(symbol_USDJPY);
    double gbpusd = GetSymbolPrice(symbol_GBPUSD);
    
    if(eurusd <= 0 || usdjpy <= 0 || gbpusd <= 0)
        return 0.0;
    
    if(UseSimplifiedDXY)
    {
        // Simplified 3-pair DXY (83% weight coverage)
        double dxy = 50.14348112 * MathPow(eurusd, -0.576) * MathPow(usdjpy, 0.136) * MathPow(gbpusd, -0.119);
        return dxy;
    }
    else
    {
        // Full 6-pair DXY (100% weight)
        double usdcad = GetSymbolPrice(symbol_USDCAD);
        double usdsek = GetSymbolPrice(symbol_USDSEK);
        double usdchf = GetSymbolPrice(symbol_USDCHF);
        
        if(usdcad <= 0 || usdsek <= 0 || usdchf <= 0)
            return 0.0;
        
        double dxy = 50.14348112 * 
                     MathPow(eurusd, -0.576) * 
                     MathPow(usdjpy, 0.136) * 
                     MathPow(gbpusd, -0.119) * 
                     MathPow(usdcad, 0.091) * 
                     MathPow(usdsek, 0.042) * 
                     MathPow(usdchf, 0.036);
        return dxy;
    }
}

//+------------------------------------------------------------------+
//| Get symbol price (current bid)                                   |
//+------------------------------------------------------------------+
double GetSymbolPrice(string symbolName)
{
    double bid = SymbolInfoDouble(symbolName, SYMBOL_BID);
    if(bid <= 0)
    {
        Print("Warning: Unable to get price for ", symbolName);
        return 0.0;
    }
    return bid;
}

//+------------------------------------------------------------------+
//| Update DXY Support/Resistance Levels                            |
//+------------------------------------------------------------------+
void UpdateDXYLevels()
{
    if(currentDXY <= 0)
        return;
    
    // Calculate levels based on spacing
    double baseLevel = MathFloor(currentDXY / LevelSpacing) * LevelSpacing;
    
    resistanceLevel = baseLevel + LevelSpacing;
    supportLevel = baseLevel;
    
    // Alternative: Use swing highs/lows for dynamic levels
    // This can be enhanced based on preference
}

//+------------------------------------------------------------------+
//| Check for trade signals                                          |
//+------------------------------------------------------------------+
void CheckForSignals()
{
    if(previousDXY <= 0 || currentDXY <= 0)
        return;
    
    // Check if we already have maximum positions
    if(CountOpenPositions() >= MaxPositions)
        return;
    
    // Calculate DXY movement
    double dxyMovement = MathAbs(currentDXY - previousDXY);
    if(dxyMovement < MinDXYMovement)
        return;
    
    // Check for breakout confirmation
    bool breakoutConfirmed = CheckBreakoutConfirmation();
    if(!breakoutConfirmed)
        return;
    
    // DXY breaks below support → BUY Gold (inverse correlation)
    if(previousDXY > supportLevel && currentDXY < supportLevel)
    {
        Print("DXY broke support at ", supportLevel, " - Signal: BUY GOLD");
        OpenTrade(ORDER_TYPE_BUY, "DXY Support Break");
    }
    
    // DXY breaks above resistance → SELL Gold (inverse correlation)
    if(previousDXY < resistanceLevel && currentDXY > resistanceLevel)
    {
        Print("DXY broke resistance at ", resistanceLevel, " - Signal: SELL GOLD");
        OpenTrade(ORDER_TYPE_SELL, "DXY Resistance Break");
    }
}

//+------------------------------------------------------------------+
//| Check breakout confirmation                                      |
//+------------------------------------------------------------------+
bool CheckBreakoutConfirmation()
{
    if(BreakoutConfirmBars <= 0)
        return true;
    
    // Check if DXY stayed beyond level for confirmation bars
    int confirmCount = 0;
    
    for(int i = 0; i < BreakoutConfirmBars; i++)
    {
        double historicalDXY = CalculateHistoricalDXY(i);
        
        if(historicalDXY <= 0)
            continue;
        
        // Check if beyond support
        if(currentDXY < supportLevel && historicalDXY < supportLevel)
            confirmCount++;
        
        // Check if beyond resistance
        if(currentDXY > resistanceLevel && historicalDXY > resistanceLevel)
            confirmCount++;
    }
    
    return (confirmCount >= BreakoutConfirmBars);
}

//+------------------------------------------------------------------+
//| Calculate historical DXY value                                   |
//+------------------------------------------------------------------+
double CalculateHistoricalDXY(int shift)
{
    double eurusd = iClose(symbol_EURUSD, PERIOD_CURRENT, shift);
    double usdjpy = iClose(symbol_USDJPY, PERIOD_CURRENT, shift);
    double gbpusd = iClose(symbol_GBPUSD, PERIOD_CURRENT, shift);
    
    if(eurusd <= 0 || usdjpy <= 0 || gbpusd <= 0)
        return 0.0;
    
    double dxy = 50.14348112 * MathPow(eurusd, -0.576) * MathPow(usdjpy, 0.136) * MathPow(gbpusd, -0.119);
    return dxy;
}

//+------------------------------------------------------------------+
//| Check filters before trading                                     |
//+------------------------------------------------------------------+
bool CheckFilters()
{
    // Check spread
    long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    if(spread > MaxSpreadPoints)
    {
        Print("Spread too high: ", spread, " points");
        return false;
    }
    
    // Check daily drawdown
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double drawdown = ((dailyStartBalance - currentBalance) / dailyStartBalance) * 100.0;
    
    if(drawdown > MaxDailyDrawdown)
    {
        Print("Daily drawdown limit reached: ", DoubleToString(drawdown, 2), "%");
        return false;
    }
    
    // Check news filter
    if(UseNewsFilter && IsNewsTime())
    {
        Print("News filter active - no trading");
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Check if current time is news time                               |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
    MqlDateTime timeStruct;
    TimeCurrent(timeStruct);
    
    int currentMinutes = timeStruct.hour * 60 + timeStruct.min;
    
    string startParts[];
    string endParts[];
    StringSplit(NewsFilterStart, ':', startParts);
    StringSplit(NewsFilterEnd, ':', endParts);
    
    if(ArraySize(startParts) < 2 || ArraySize(endParts) < 2)
        return false;
    
    int startMinutes = (int)StringToInteger(startParts[0]) * 60 + (int)StringToInteger(startParts[1]);
    int endMinutes = (int)StringToInteger(endParts[0]) * 60 + (int)StringToInteger(endParts[1]);
    
    return (currentMinutes >= startMinutes && currentMinutes <= endMinutes);
}

//+------------------------------------------------------------------+
//| Open trade                                                        |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE orderType, string comment)
{
    // Get current ATR
    if(CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) <= 0)
    {
        Print("Failed to get ATR value");
        return;
    }
    
    double atr = atr_buffer[0];
    double currentPrice = (orderType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
    
    // Calculate stop loss
    double stopLoss = (orderType == ORDER_TYPE_BUY) ? 
                      currentPrice - (atr * ATR_StopMultiplier) : 
                      currentPrice + (atr * ATR_StopMultiplier);
    
    // Calculate take profit
    double slDistance = MathAbs(currentPrice - stopLoss);
    double takeProfit = (orderType == ORDER_TYPE_BUY) ? 
                        currentPrice + (slDistance * RiskRewardRatio) : 
                        currentPrice - (slDistance * RiskRewardRatio);
    
    // Calculate lot size based on risk
    double lotSize = CalculateLotSize(slDistance);
    
    // Normalize values
    stopLoss = NormalizeDouble(stopLoss, _Digits);
    takeProfit = NormalizeDouble(takeProfit, _Digits);
    lotSize = NormalizeDouble(lotSize, 2);
    
    // Validate lot size
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    
    if(lotSize < minLot)
        lotSize = minLot;
    if(lotSize > maxLot)
        lotSize = maxLot;
    
    // Prepare trade request
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_DEAL;
    request.symbol = _Symbol;
    request.volume = lotSize;
    request.type = orderType;
    request.price = currentPrice;
    request.sl = stopLoss;
    request.tp = takeProfit;
    request.deviation = 10;
    request.magic = 202501;
    request.comment = "TORAMA-" + comment;
    
    // Send order
    if(OrderSend(request, result))
    {
        if(result.retcode == TRADE_RETCODE_DONE)
        {
            Print("Order opened successfully: ", result.order, " | Type: ", EnumToString(orderType), 
                  " | Lot: ", lotSize, " | SL: ", stopLoss, " | TP: ", takeProfit);
            stats.totalTrades++;
            stats.lastTradeTime = TimeCurrent();
        }
        else
        {
            Print("Order failed: ", result.retcode, " - ", result.comment);
        }
    }
    else
    {
        Print("OrderSend failed: ", GetLastError());
    }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = accountBalance * (RiskPercent / 100.0);
    
    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    
    double slPoints = slDistance / _Point;
    double lotSize = riskAmount / (slPoints * tickValue / tickSize);
    
    return lotSize;
}

//+------------------------------------------------------------------+
//| Count open positions                                             |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == 202501)
            {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Manage existing positions                                        |
//+------------------------------------------------------------------+
void ManagePositions()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == 202501)
            {
                // Position management logic can be added here
                // For now, we rely on SL/TP and trailing stops
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Update trailing stops                                            |
//+------------------------------------------------------------------+
void UpdateTrailingStops()
{
    if(CopyBuffer(atr_handle, 0, 0, 1, atr_buffer) <= 0)
        return;
    
    double atr = atr_buffer[0];
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == 202501)
            {
                double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                double currentSL = PositionGetDouble(POSITION_SL);
                double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
                ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
                
                double slDistance = MathAbs(openPrice - currentSL);
                double profit = (posType == POSITION_TYPE_BUY) ? 
                               (currentPrice - openPrice) : (openPrice - currentPrice);
                
                // Check if profit reached activation level
                if(profit >= slDistance * TrailingActivation)
                {
                    double newSL = 0.0;
                    double trailDistance = atr * TrailingDistance;
                    
                    if(posType == POSITION_TYPE_BUY)
                    {
                        newSL = currentPrice - trailDistance;
                        if(newSL > currentSL + _Point)
                        {
                            ModifyPosition(ticket, newSL, PositionGetDouble(POSITION_TP));
                        }
                    }
                    else // SELL
                    {
                        newSL = currentPrice + trailDistance;
                        if(newSL < currentSL - _Point && newSL > 0)
                        {
                            ModifyPosition(ticket, newSL, PositionGetDouble(POSITION_TP));
                        }
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Modify position                                                   |
//+------------------------------------------------------------------+
void ModifyPosition(ulong ticket, double newSL, double newTP)
{
    MqlTradeRequest request = {};
    MqlTradeResult result = {};
    
    request.action = TRADE_ACTION_SLTP;
    request.position = ticket;
    request.sl = NormalizeDouble(newSL, _Digits);
    request.tp = NormalizeDouble(newTP, _Digits);
    
    if(OrderSend(request, result))
    {
        if(result.retcode == TRADE_RETCODE_DONE)
        {
            Print("Trailing stop updated for ticket ", ticket, " - New SL: ", newSL);
        }
    }
}

//+------------------------------------------------------------------+
//| Check daily reset                                                |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
    MqlDateTime currentTime, startTime;
    TimeCurrent(currentTime);
    TimeToStruct(dailyStartTime, startTime);
    
    if(currentTime.day != startTime.day)
    {
        dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        dailyStartTime = TimeCurrent();
        Print("Daily reset - New tracking balance: ", dailyStartBalance);
    }
}

//+------------------------------------------------------------------+
//| Create UI Panel                                                  |
//+------------------------------------------------------------------+
void CreatePanel()
{
    int x = 20;
    int y = 20;
    int width = 280;
    int height = 320;
    
    // Main panel - solid background, on top of everything
    ObjectCreate(0, "TORAMA_Panel", OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_XSIZE, width);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_YSIZE, height);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_BGCOLOR, PanelColor);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_COLOR, clrWhite);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_BACK, false);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, "TORAMA_Panel", OBJPROP_ZORDER, 0);
    
    // Header
    CreateLabel("TORAMA_Header", "TORAMA DXY GOLD TRADER", x + 10, y + 10, 10, clrGold, "Arial Black");
    CreateLabel("TORAMA_Contact", "ea@torama.money", x + 10, y + 30, 7, clrSilver, "Arial");
    
    // DXY Section
    CreateLabel("TORAMA_DXY_Label", "Synthetic DXY:", x + 10, y + 55, FontSize, TextColor);
    CreateLabel("TORAMA_DXY_Value", "Calculating...", x + 150, y + 55, FontSize, clrLime);
    
    CreateLabel("TORAMA_Resistance_Label", "Resistance:", x + 10, y + 75, FontSize, TextColor);
    CreateLabel("TORAMA_Resistance_Value", "---", x + 150, y + 75, FontSize, clrRed);
    
    CreateLabel("TORAMA_Support_Label", "Support:", x + 10, y + 95, FontSize, TextColor);
    CreateLabel("TORAMA_Support_Value", "---", x + 150, y + 95, FontSize, clrDodgerBlue);
    
    // Position Info
    CreateLabel("TORAMA_Positions_Label", "Open Positions:", x + 10, y + 120, FontSize, TextColor);
    CreateLabel("TORAMA_Positions_Value", "0", x + 150, y + 120, FontSize, clrYellow);
    
    // Stats
    CreateLabel("TORAMA_Stats_Header", "--- STATISTICS ---", x + 10, y + 145, FontSize, clrGold);
    CreateLabel("TORAMA_Total_Label", "Total Trades:", x + 10, y + 165, FontSize, TextColor);
    CreateLabel("TORAMA_Total_Value", "0", x + 150, y + 165, FontSize, TextColor);
    
    CreateLabel("TORAMA_Win_Label", "Win Rate:", x + 10, y + 185, FontSize, TextColor);
    CreateLabel("TORAMA_Win_Value", "0%", x + 150, y + 185, FontSize, clrLime);
    
    CreateLabel("TORAMA_PL_Label", "Net P/L:", x + 10, y + 205, FontSize, TextColor);
    CreateLabel("TORAMA_PL_Value", "$0.00", x + 150, y + 205, FontSize, TextColor);
    
    CreateLabel("TORAMA_DD_Label", "Daily DD:", x + 10, y + 225, FontSize, TextColor);
    CreateLabel("TORAMA_DD_Value", "0%", x + 150, y + 225, FontSize, TextColor);
    
    // Account Info
    CreateLabel("TORAMA_Account_Header", "--- ACCOUNT ---", x + 10, y + 250, FontSize, clrGold);
    CreateLabel("TORAMA_Balance_Label", "Balance:", x + 10, y + 270, FontSize, TextColor);
    CreateLabel("TORAMA_Balance_Value", "$0.00", x + 150, y + 270, FontSize, clrLime);
    
    CreateLabel("TORAMA_Equity_Label", "Equity:", x + 10, y + 290, FontSize, TextColor);
    CreateLabel("TORAMA_Equity_Value", "$0.00", x + 150, y + 290, FontSize, TextColor);
    
    // TORAMA CAPITAL brand at bottom right - large chalk white text
    CreateLabelBottomRight("TORAMA_Brand", "TORAMA CAPITAL", 15, 30, 14, clrWhiteSmoke, "Arial Black");
    
    ChartRedraw();
}

//+------------------------------------------------------------------+
//| Create label helper                                              |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, int fontSize, color clr, string font = "Arial")
{
    ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
    ObjectSetString(0, name, OBJPROP_FONT, font);
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);
}

//+------------------------------------------------------------------+
//| Create label at bottom right corner                             |
//+------------------------------------------------------------------+
void CreateLabelBottomRight(string name, string text, int x, int y, int fontSize, color clr, string font = "Arial")
{
    ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
    ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
    ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
    ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
    ObjectSetString(0, name, OBJPROP_FONT, font);
    ObjectSetString(0, name, OBJPROP_TEXT, text);
    ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_LOWER);
    ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_RIGHT_LOWER);
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, name, OBJPROP_ZORDER, 0);
}

//+------------------------------------------------------------------+
//| Update UI Panel                                                  |
//+------------------------------------------------------------------+
void UpdatePanel()
{
    // Update DXY values
    ObjectSetString(0, "TORAMA_DXY_Value", OBJPROP_TEXT, DoubleToString(currentDXY, 2));
    ObjectSetString(0, "TORAMA_Resistance_Value", OBJPROP_TEXT, DoubleToString(resistanceLevel, 2));
    ObjectSetString(0, "TORAMA_Support_Value", OBJPROP_TEXT, DoubleToString(supportLevel, 2));
    
    // Update positions
    int openPos = CountOpenPositions();
    ObjectSetString(0, "TORAMA_Positions_Value", OBJPROP_TEXT, IntegerToString(openPos));
    
    // Update stats
    ObjectSetString(0, "TORAMA_Total_Value", OBJPROP_TEXT, IntegerToString(stats.totalTrades));
    
    double winRate = (stats.totalTrades > 0) ? ((double)stats.winningTrades / stats.totalTrades * 100.0) : 0.0;
    ObjectSetString(0, "TORAMA_Win_Value", OBJPROP_TEXT, DoubleToString(winRate, 1) + "%");
    
    double netPL = stats.totalProfit + stats.totalLoss;
    ObjectSetString(0, "TORAMA_PL_Value", OBJPROP_TEXT, "$" + DoubleToString(netPL, 2));
    ObjectSetInteger(0, "TORAMA_PL_Value", OBJPROP_COLOR, (netPL >= 0) ? clrLime : clrRed);
    
    // Daily drawdown
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double drawdown = ((dailyStartBalance - currentBalance) / dailyStartBalance) * 100.0;
    ObjectSetString(0, "TORAMA_DD_Value", OBJPROP_TEXT, DoubleToString(drawdown, 2) + "%");
    ObjectSetInteger(0, "TORAMA_DD_Value", OBJPROP_COLOR, (drawdown < 3.0) ? clrLime : clrOrange);
    
    // Account info
    ObjectSetString(0, "TORAMA_Balance_Value", OBJPROP_TEXT, "$" + DoubleToString(currentBalance, 2));
    
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    ObjectSetString(0, "TORAMA_Equity_Value", OBJPROP_TEXT, "$" + DoubleToString(equity, 2));
    ObjectSetInteger(0, "TORAMA_Equity_Value", OBJPROP_COLOR, (equity >= currentBalance) ? clrLime : clrRed);
    
    ChartRedraw();
}
//+------------------------------------------------------------------+
