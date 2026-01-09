//+------------------------------------------------------------------+
//|                                              ToramaTickHFT.mq5    |
//|                                    TORAMA CAPITAL - ea@torama.money |
//|                                              https://torama.money   |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.00"
#property description "High-Frequency Tick Trading EA"
#property description "Trades every tick based on price direction"

//--- Input Parameters
input group "=== Position Management ==="
input int      InpMaxPositionsPerSide = 200;        // Maximum Positions Per Side
input double   InpTakeProfitPercent = 5.0;          // Global Take Profit (%)
input double   InpMaxDrawdownPercent = 10.0;        // Maximum Drawdown (%)

input group "=== Trade Settings ==="
input int      InpSlippage = 10;                     // Slippage (points)
input string   InpTradeComment = "ToramaHFT";        // Trade Comment

//--- Global Variables
long           g_MagicNumber;
double         g_MinLot;
double         g_MaxLot;
double         g_LotStep;
int            g_Digits;
double         g_Point;
double         g_TickSize;
double         g_TickValue;
int            g_StopsLevel;
int            g_FreezeLevel;

double         g_LastTickPrice = 0;
datetime       g_LastTickTime = 0;
double         g_InitialBalance;
double         g_PeakBalance;
int            g_BuyPositions = 0;
int            g_SellPositions = 0;

MqlTick        g_LastTick;
MqlTick        g_CurrentTick;

//--- Trade object
#include <Trade\Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
    //--- Use Chart ID as Magic Number
    g_MagicNumber = ChartID();
    
    //--- Initialize symbol properties
    if(!InitializeSymbolInfo())
    {
        Print("❌ Failed to initialize symbol information");
        return INIT_FAILED;
    }
    
    //--- Setup trade object
    trade.SetExpertMagicNumber(g_MagicNumber);
    trade.SetDeviationInPoints(InpSlippage);
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    trade.SetAsyncMode(false);
    
    //--- Check filling mode
    if(!CheckFillingMode())
    {
        Print("⚠️ FOK filling not available, switching to IOC");
        trade.SetTypeFilling(ORDER_FILLING_IOC);
        
        if(!CheckFillingMode())
        {
            Print("⚠️ IOC filling not available, using RETURN");
            trade.SetTypeFilling(ORDER_FILLING_RETURN);
        }
    }
    
    //--- Initialize balance tracking
    g_InitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_PeakBalance = g_InitialBalance;
    
    //--- Get initial tick
    if(!SymbolInfoTick(_Symbol, g_CurrentTick))
    {
        Print("❌ Failed to get initial tick");
        return INIT_FAILED;
    }
    
    g_LastTickPrice = g_CurrentTick.last;
    g_LastTickTime = g_CurrentTick.time;
    g_LastTick = g_CurrentTick;
    
    //--- Count existing positions
    CountPositions();
    
    //--- Display initialization info
    PrintInitInfo();
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    string reasonText = GetDeinitReasonText(reason);
    Print("═══════════════════════════════════════");
    Print("EA Stopped: ", reasonText);
    Print("Final Buy Positions: ", g_BuyPositions);
    Print("Final Sell Positions: ", g_SellPositions);
    Print("═══════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Get current tick
    if(!SymbolInfoTick(_Symbol, g_CurrentTick))
    {
        Print("❌ Failed to get current tick");
        return;
    }
    
    //--- Check if this is a new tick with price change
    if(g_CurrentTick.time == g_LastTickTime)
        return;
    
    //--- Check drawdown limit
    if(!CheckDrawdownLimit())
    {
        Print("🛑 Maximum drawdown reached - stopping trading");
        return;
    }
    
    //--- Check take profit
    if(CheckGlobalTakeProfit())
    {
        Print("🎯 Global take profit reached - closing all positions");
        CloseAllPositions();
        return;
    }
    
    //--- Update position counts
    CountPositions();
    
    //--- Determine tick direction
    bool isBullish = g_CurrentTick.last > g_LastTickPrice;
    bool isBearish = g_CurrentTick.last < g_LastTickPrice;
    
    //--- Trade based on tick direction
    if(isBullish && g_BuyPositions < InpMaxPositionsPerSide)
    {
        if(CheckTradingConditions(ORDER_TYPE_BUY))
        {
            ExecuteTrade(ORDER_TYPE_BUY);
        }
    }
    else if(isBearish && g_SellPositions < InpMaxPositionsPerSide)
    {
        if(CheckTradingConditions(ORDER_TYPE_SELL))
        {
            ExecuteTrade(ORDER_TYPE_SELL);
        }
    }
    
    //--- Update last tick data
    g_LastTickPrice = g_CurrentTick.last;
    g_LastTickTime = g_CurrentTick.time;
    g_LastTick = g_CurrentTick;
}

//+------------------------------------------------------------------+
//| Initialize symbol information                                      |
//+------------------------------------------------------------------+
bool InitializeSymbolInfo()
{
    //--- Get symbol properties
    g_Digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    g_Point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    g_TickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    g_TickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    g_StopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
    g_FreezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
    
    //--- Get lot parameters
    g_MinLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    g_MaxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    g_LotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    //--- Validate values
    if(g_MinLot <= 0 || g_Point <= 0 || g_TickSize <= 0)
    {
        Print("❌ Invalid symbol properties");
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Check filling mode availability                                    |
//+------------------------------------------------------------------+
bool CheckFillingMode()
{
    int filling = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
    int currentMode = (int)trade.RequestType();
    
    return (filling & currentMode) != 0;
}

//+------------------------------------------------------------------+
//| Count current positions                                            |
//+------------------------------------------------------------------+
void CountPositions()
{
    g_BuyPositions = 0;
    g_SellPositions = 0;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != g_MagicNumber) continue;
        
        ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
        
        if(type == POSITION_TYPE_BUY)
            g_BuyPositions++;
        else if(type == POSITION_TYPE_SELL)
            g_SellPositions++;
    }
}

//+------------------------------------------------------------------+
//| Check trading conditions                                           |
//+------------------------------------------------------------------+
bool CheckTradingConditions(ENUM_ORDER_TYPE orderType)
{
    //--- Check if trading is allowed
    if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
    {
        Print("⚠️ Terminal trading not allowed");
        return false;
    }
    
    if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
    {
        Print("⚠️ EA trading not allowed");
        return false;
    }
    
    //--- Check if symbol is tradeable
    if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE))
    {
        Print("⚠️ Symbol not tradeable");
        return false;
    }
    
    //--- Check market session
    datetime serverTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(serverTime, dt);
    
    if(dt.day_of_week == 0 || dt.day_of_week == 6)
    {
        // Weekend check
        if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE))
            return false;
    }
    
    //--- Check spread
    long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    long spreadLimit = 50; // Maximum 50 point spread for HFT
    
    if(spread > spreadLimit)
    {
        Print("⚠️ Spread too high: ", spread, " points");
        return false;
    }
    
    //--- Check account free margin
    double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    double marginRequired = 0;
    
    if(!OrderCalcMargin(orderType, _Symbol, g_MinLot, 
                        orderType == ORDER_TYPE_BUY ? g_CurrentTick.ask : g_CurrentTick.bid,
                        marginRequired))
    {
        Print("⚠️ Failed to calculate margin");
        return false;
    }
    
    if(freeMargin < marginRequired * 2) // Safety factor
    {
        Print("⚠️ Insufficient margin: ", freeMargin, " required: ", marginRequired);
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Execute trade                                                      |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE orderType)
{
    double price = (orderType == ORDER_TYPE_BUY) ? g_CurrentTick.ask : g_CurrentTick.bid;
    
    //--- Normalize lot size
    double lot = NormalizeLot(g_MinLot);
    
    //--- Execute trade
    bool result = false;
    
    if(orderType == ORDER_TYPE_BUY)
    {
        result = trade.Buy(lot, _Symbol, price, 0, 0, InpTradeComment);
    }
    else
    {
        result = trade.Sell(lot, _Symbol, price, 0, 0, InpTradeComment);
    }
    
    //--- Check result
    if(result)
    {
        if(orderType == ORDER_TYPE_BUY)
            g_BuyPositions++;
        else
            g_SellPositions++;
            
        Print("✅ ", (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"), 
              " executed | Ticket: ", trade.ResultOrder(), 
              " | Price: ", DoubleToString(price, g_Digits),
              " | Buy: ", g_BuyPositions, " Sell: ", g_SellPositions);
    }
    else
    {
        uint errorCode = GetLastError();
        Print("❌ Trade failed | Type: ", EnumToString(orderType),
              " | Error: ", errorCode, " - ", GetErrorDescription(errorCode),
              " | RetCode: ", trade.ResultRetcode());
    }
}

//+------------------------------------------------------------------+
//| Normalize lot size                                                 |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
    lot = MathFloor(lot / g_LotStep) * g_LotStep;
    lot = MathMax(lot, g_MinLot);
    lot = MathMin(lot, g_MaxLot);
    
    return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Check drawdown limit                                               |
//+------------------------------------------------------------------+
bool CheckDrawdownLimit()
{
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    
    //--- Update peak balance
    if(currentBalance > g_PeakBalance)
        g_PeakBalance = currentBalance;
    
    //--- Calculate drawdown from peak
    double drawdown = ((g_PeakBalance - currentEquity) / g_PeakBalance) * 100.0;
    
    if(drawdown >= InpMaxDrawdownPercent)
    {
        Print("🛑 DRAWDOWN LIMIT REACHED!");
        Print("Peak Balance: ", g_PeakBalance);
        Print("Current Equity: ", currentEquity);
        Print("Drawdown: ", DoubleToString(drawdown, 2), "%");
        
        CloseAllPositions();
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Check global take profit                                           |
//+------------------------------------------------------------------+
bool CheckGlobalTakeProfit()
{
    double totalProfit = 0;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != g_MagicNumber) continue;
        
        totalProfit += PositionGetDouble(POSITION_PROFIT);
    }
    
    double targetProfit = g_InitialBalance * (InpTakeProfitPercent / 100.0);
    
    return (totalProfit >= targetProfit);
}

//+------------------------------------------------------------------+
//| Close all positions                                                |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
    int closed = 0;
    
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
        if(PositionGetInteger(POSITION_MAGIC) != g_MagicNumber) continue;
        
        if(trade.PositionClose(ticket))
        {
            closed++;
            Print("✅ Position closed | Ticket: ", ticket);
        }
        else
        {
            Print("❌ Failed to close position | Ticket: ", ticket, 
                  " | Error: ", GetLastError());
        }
    }
    
    Print("🔒 Closed ", closed, " positions");
    g_BuyPositions = 0;
    g_SellPositions = 0;
}

//+------------------------------------------------------------------+
//| Get error description                                              |
//+------------------------------------------------------------------+
string GetErrorDescription(uint errorCode)
{
    switch(errorCode)
    {
        case 10004: return "Requote";
        case 10006: return "Request rejected";
        case 10007: return "Request canceled";
        case 10008: return "Order placed";
        case 10009: return "Request completed";
        case 10010: return "Only part of request completed";
        case 10011: return "Request processing error";
        case 10012: return "Request canceled by timeout";
        case 10013: return "Invalid request";
        case 10014: return "Invalid volume";
        case 10015: return "Invalid price";
        case 10016: return "Invalid stops";
        case 10017: return "Trade disabled";
        case 10018: return "Market closed";
        case 10019: return "No money";
        case 10020: return "Prices changed";
        case 10021: return "No quotes";
        case 10022: return "Invalid order expiration";
        case 10023: return "Order state changed";
        case 10024: return "Too many requests";
        case 10025: return "No changes in request";
        case 10026: return "Autotrading disabled";
        case 10027: return "Autotrading disabled by client";
        case 10028: return "Request locked for processing";
        case 10029: return "Order/position frozen";
        case 10030: return "Invalid fill type";
        case 10031: return "No connection";
        case 10032: return "Only real accounts allowed";
        case 10033: return "Limit of pending orders reached";
        case 10034: return "Limit of positions reached";
        case 10035: return "Invalid order for hedging";
        case 10036: return "Invalid close volume";
        default: return "Unknown error";
    }
}

//+------------------------------------------------------------------+
//| Get deinitialization reason text                                   |
//+------------------------------------------------------------------+
string GetDeinitReasonText(int reason)
{
    switch(reason)
    {
        case REASON_PROGRAM: return "EA terminated by user";
        case REASON_REMOVE: return "EA removed from chart";
        case REASON_RECOMPILE: return "EA recompiled";
        case REASON_CHARTCHANGE: return "Symbol/timeframe changed";
        case REASON_CHARTCLOSE: return "Chart closed";
        case REASON_PARAMETERS: return "Input parameters changed";
        case REASON_ACCOUNT: return "Account changed";
        case REASON_TEMPLATE: return "Template changed";
        case REASON_INITFAILED: return "Initialization failed";
        case REASON_CLOSE: return "Terminal closed";
        default: return "Unknown reason";
    }
}

//+------------------------------------------------------------------+
//| Print initialization information                                   |
//+------------------------------------------------------------------+
void PrintInitInfo()
{
    Print("═══════════════════════════════════════");
    Print("🚀 TORAMA TICK HFT EA INITIALIZED");
    Print("═══════════════════════════════════════");
    Print("Symbol: ", _Symbol);
    Print("Magic Number: ", g_MagicNumber);
    Print("Min Lot: ", g_MinLot);
    Print("Max Lot: ", g_MaxLot);
    Print("Lot Step: ", g_LotStep);
    Print("Tick Size: ", g_TickSize);
    Print("Tick Value: ", g_TickValue);
    Print("Stops Level: ", g_StopsLevel);
    Print("Freeze Level: ", g_FreezeLevel);
    Print("Digits: ", g_Digits);
    Print("───────────────────────────────────────");
    Print("Max Positions/Side: ", InpMaxPositionsPerSide);
    Print("Global TP: ", InpTakeProfitPercent, "%");
    Print("Max Drawdown: ", InpMaxDrawdownPercent, "%");
    Print("Initial Balance: $", DoubleToString(g_InitialBalance, 2));
    Print("═══════════════════════════════════════");
}

//+------------------------------------------------------------------+
