//+------------------------------------------------------------------+
//|                                Enhanced Mean Reversion EA v2.18                              |
//|                                Professional Trading EA                                       |
//|                                © TORAMA CAPITAL 2025                                         |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL - Advanced Trading Solutions"
#property version   "2.18"
#property description "Professional Mean Reversion EA - Counter-Trend Edition"
#property description "DEMO ACCOUNTS ONLY - Educational & Professional Use"
#property link      "www.toramacapital.com"

#include <Trade/Trade.mqh>

// ==== PROFESSIONAL COLOR SCHEME ====
#define BRAND_PRIMARY_BLUE        C'0,82,147'            // Deep corporate blue
#define BRAND_SECONDARY_GOLD      C'255,193,7'           // Premium gold
#define BRAND_ACCENT_TEAL         C'0,150,136'           // Modern teal accent
#define BRAND_DARK_BG             C'18,22,28'            // Darker professional background
#define BRAND_LIGHT_BG            C'35,42,52'            // Lighter panel background
#define BRAND_SUCCESS_GREEN       C'76,175,80'           // Success green
#define BRAND_WARNING_ORANGE      C'255,152,0'           // Warning orange
#define BRAND_DANGER_RED          C'244,67,54'           // Danger red
#define BRAND_TEXT_PRIMARY        C'255,255,255'         // Primary text
#define BRAND_TEXT_SECONDARY      C'189,189,189'         // Secondary text
#define BRAND_BORDER_LIGHT        C'70,80,90'            // Light borders
#define BRAND_SECTION_DIVIDER     C'50,60,70'            // Section divider

// ==== ENHANCED BRANDING CONSTANTS ====
#define COMPANY_NAME              "TORAMA CAPITAL"
#define COMPANY_TAGLINE           "Advanced Trading Solutions"
#define COMPANY_WEBSITE           "www.toramacapital.com"
#define COMPANY_VERSION           "Mean Reversion v2.18"
#define COMPANY_LICENSE           "Licensed Trading Software"
#define COMPANY_EMAIL             "support@toramacapital.com"

enum ENUM_TRADE_DIRECTION
{
   TRADE_BOTH = 0,
   TRADE_BUY_ONLY = 1,
   TRADE_SELL_ONLY = 2
};

input ENUM_TIMEFRAMES TimeframeParam = PERIOD_M1;  // Trading Timeframe
input ENUM_TRADE_DIRECTION TradeDirection = TRADE_BOTH;
input double      LotSize = 0.1;
input bool        UseAutoLotSizing = false;
input double      AutoLotPer1000 = 0.01;
input double      EquityIncrement = 1000.0;
input int         StopLoss = 0;
input double      TakeProfitDollars = 50.0;
input double      GlobalProfitTarget = 100.0;
input double      MaxDrawdownPercent = 30.0;  // Maximum drawdown % - closes all trades and stops EA (0 or 100 = disabled)
input bool        EnableConsecutiveCandleExit = true;
input int         ConsecutiveCandleCount = 3;  // Consecutive candles to close profitable positions
input bool        EnableCandleSizeFilter = true;  // Enable candle size validation
input double      MinCandlePoints = 30.0;  // Minimum candle size in points
input double      MinCandleSpreadRatio = 3.0;  // Candle must be X times spread size
input int         TradesPerSignal = 1;
input int         MaxPositions = 5;
input int         MagicNumber = 123456;
input string      TradeComment = "MeanRevEA";
input bool        ShowButtons = true;
input bool        StartPanelMinimized = false;  // Start with panel minimized
input int         MaxRetries = 3;
input int         RetryDelay = 100;

CTrade trade;
datetime lastBarTime = 0;
int consecutiveBullish = 0;
int consecutiveBearish = 0;
bool tradingEnabled = true;
bool isInitialized = false;
bool isPanelMinimized = false;  // Panel state
int actualTradesPerSignal = 1;
double startingEquity = 0;  // Track starting equity for drawdown calculation
double peakEquity = 0;  // Track peak equity for proper drawdown measurement
bool drawdownProtectionTriggered = false;  // Flag to prevent repeated emergency actions

#define BTN_TOGGLE_TRADING "btnToggleTrading"
#define BTN_CLOSE_PROFITABLE "btnCloseProfitable"
#define BTN_PANEL_MINIMIZE "btnPanelMinimize"
#define PANEL_BACKGROUND "panelBackground"
#define PANEL_TITLE "panelTitle"
#define PANEL_STATS "panelStats"
#define PANEL_BRANDING1 "panelBranding1"
#define PANEL_BRANDING2 "panelBranding2"

#define INFO_PANEL_BACKGROUND "infoPanelBackground"
#define INFO_PANEL_TITLE "infoPanelTitle"
#define INFO_PANEL_LINE_PREFIX "panelLine"
#define COMPACT_INFO_LABEL "compactInfoLabel"

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("=== TORAMA CAPITAL - Mean Reversion EA v2.18 ===");
   Print("Initializing Expert Advisor...");
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.LogLevel(LOG_LEVEL_ERRORS);
   
   lastBarTime = iTime(_Symbol, TimeframeParam, 0);
   actualTradesPerSignal = (TradesPerSignal < 1) ? 1 : TradesPerSignal;
   
   // Initialize equity tracking for drawdown protection
   startingEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   peakEquity = startingEquity;
   drawdownProtectionTriggered = false;
   
   Print("Starting Equity: $", DoubleToString(startingEquity, 2));
   Print("Max Drawdown Protection: ", DoubleToString(MaxDrawdownPercent, 1), "%");
   Print("Strategy: Mean Reversion (Counter-Trend)");
   Print("Entry: Buy on bearish candles | Sell on bullish candles");
   Print("Exit: Close profitable after ", ConsecutiveCandleCount, " consecutive candles in trend");
   
   if(EnableCandleSizeFilter)
   {
      Print("Candle Size Filter: ENABLED");
      Print("  - Minimum Size: ", DoubleToString(MinCandlePoints, 1), " points");
      Print("  - Minimum Spread Ratio: ", DoubleToString(MinCandleSpreadRatio, 1), "x");
   }
   else
   {
      Print("Candle Size Filter: DISABLED - All candles accepted");
   }
   
   isPanelMinimized = StartPanelMinimized;
   CreateCollapsibleInfoPanel();
   isInitialized = true;
   
   Print("EA Initialization Complete - Trading Status: ", tradingEnabled ? "ENABLED" : "DISABLED");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("Deinitializing EA. Reason: ", reason);
   DeleteInfoPanel();
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!isInitialized) return;
   
   // Update display every tick
   UpdateDisplay();
   
   // Check for drawdown protection FIRST (before any trading logic)
   if(MaxDrawdownPercent > 0 && MaxDrawdownPercent < 100)
   {
      CheckDrawdownProtection();
      if(drawdownProtectionTriggered)
      {
         // EA is stopped due to drawdown, don't process any further
         return;
      }
   }
   
   // Check if trading is enabled
   if(!tradingEnabled) return;
   
   // Check for global profit target
   if(GlobalProfitTarget > 0)
   {
      CheckGlobalProfitTarget();
   }
   
   // Check for new bar
   datetime currentBarTime = iTime(_Symbol, TimeframeParam, 0);
   if(currentBarTime == lastBarTime) return;
   
   lastBarTime = currentBarTime;
   
   // Track consecutive candle patterns for profit-taking
   DetectConsecutiveCandlePattern();
   
   // Check for exit signals (consecutive candles = close profitable positions)
   if(EnableConsecutiveCandleExit)
   {
      CheckConsecutiveCandleExit();
   }
   
   // Check for entry signals (opposite candles = enter trades)
   CheckEntrySignals();
}

//+------------------------------------------------------------------+
//| Chart event handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == BTN_TOGGLE_TRADING)
      {
         tradingEnabled = !tradingEnabled;
         Print("Trading ", tradingEnabled ? "ENABLED" : "DISABLED");
         UpdateDisplay();
         ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_STATE, false);
      }
      else if(sparam == BTN_CLOSE_PROFITABLE)
      {
         CloseAllProfitablePositions();
         ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_STATE, false);
      }
      else if(sparam == BTN_PANEL_MINIMIZE)
      {
         isPanelMinimized = !isPanelMinimized;
         UpdateCollapsibleInfoPanel();
         ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_STATE, false);
      }
   }
}

//+------------------------------------------------------------------+
//| Detect consecutive candle patterns (for exit logic)              |
//+------------------------------------------------------------------+
void DetectConsecutiveCandlePattern()
{
   double open0 = iOpen(_Symbol, TimeframeParam, 1);
   double close0 = iClose(_Symbol, TimeframeParam, 1);
   double open1 = iOpen(_Symbol, TimeframeParam, 2);
   double close1 = iClose(_Symbol, TimeframeParam, 2);
   
   bool currentBullish = (close0 > open0);
   bool previousBullish = (close1 > open1);
   bool currentBearish = (close0 < open0);
   bool previousBearish = (close1 < open1);
   
   // Track consecutive candles in the SAME direction
   if(currentBullish && previousBullish)
   {
      consecutiveBullish++;
      consecutiveBearish = 0;
   }
   else if(currentBearish && previousBearish)
   {
      consecutiveBearish++;
      consecutiveBullish = 0;
   }
   else
   {
      // Reset both if pattern breaks
      consecutiveBullish = currentBullish ? 1 : 0;
      consecutiveBearish = currentBearish ? 1 : 0;
   }
   
   Print("Consecutive Pattern - Bullish: ", consecutiveBullish, " | Bearish: ", consecutiveBearish);
}

//+------------------------------------------------------------------+
//| Validate candle size before entry                                |
//+------------------------------------------------------------------+
bool ValidateCandleSize(double open, double close)
{
   if(!EnableCandleSizeFilter) return true;  // Filter disabled, allow all candles
   
   double candleSize = MathAbs(open - close);
   double candleSizePoints = candleSize / _Point;
   
   // Check 1: Minimum candle size in points
   if(candleSizePoints < MinCandlePoints)
   {
      Print("Candle rejected - Size too small: ", DoubleToString(candleSizePoints, 1), 
            " points (Min: ", DoubleToString(MinCandlePoints, 1), ")");
      return false;
   }
   
   // Check 2: Candle must be larger than spread ratio
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double spreadRatio = candleSize / spread;
   
   if(spreadRatio < MinCandleSpreadRatio)
   {
      Print("Candle rejected - Spread ratio too low: ", DoubleToString(spreadRatio, 2), 
            "x (Min: ", DoubleToString(MinCandleSpreadRatio, 2), "x)");
      return false;
   }
   
   Print("✓ Candle validated - Size: ", DoubleToString(candleSizePoints, 1), 
         " points | Spread ratio: ", DoubleToString(spreadRatio, 2), "x");
   return true;
}

//+------------------------------------------------------------------+
//| CORRECTED: Check for entry signals - MEAN REVERSION LOGIC        |
//| BUY on bearish candles | SELL on bullish candles                 |
//+------------------------------------------------------------------+
void CheckEntrySignals()
{
   if(CountMyPositions() >= MaxPositions)
   {
      return;
   }
   
   // Get the just-closed candle (bar index 1)
   double open1 = iOpen(_Symbol, TimeframeParam, 1);
   double close1 = iClose(_Symbol, TimeframeParam, 1);
   
   bool isBearishCandle = (close1 < open1);  // Red/bearish candle
   bool isBullishCandle = (close1 > open1);  // Green/bullish candle
   
   // MEAN REVERSION: Buy on BEARISH candles (counter-trend)
   if((TradeDirection == TRADE_BOTH || TradeDirection == TRADE_BUY_ONLY) && isBearishCandle)
   {
      // Validate candle size before entry
      if(ValidateCandleSize(open1, close1))
      {
         int buyCount = CountMyPositionsByType(POSITION_TYPE_BUY);
         if(buyCount < MaxPositions)
         {
            Print("BUY SIGNAL - Bearish candle detected (Mean Reversion Entry)");
            for(int i = 0; i < actualTradesPerSignal; i++)
            {
               if(CountMyPositions() >= MaxPositions) break;
               OpenTrade(ORDER_TYPE_BUY);
            }
         }
      }
   }
   
   // MEAN REVERSION: Sell on BULLISH candles (counter-trend)
   if((TradeDirection == TRADE_BOTH || TradeDirection == TRADE_SELL_ONLY) && isBullishCandle)
   {
      // Validate candle size before entry
      if(ValidateCandleSize(open1, close1))
      {
         int sellCount = CountMyPositionsByType(POSITION_TYPE_SELL);
         if(sellCount < MaxPositions)
         {
            Print("SELL SIGNAL - Bullish candle detected (Mean Reversion Entry)");
            for(int i = 0; i < actualTradesPerSignal; i++)
            {
               if(CountMyPositions() >= MaxPositions) break;
               OpenTrade(ORDER_TYPE_SELL);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CORRECTED: Check consecutive candle exit - PROFIT TAKING         |
//| Close PROFITABLE positions when trend establishes                |
//+------------------------------------------------------------------+
void CheckConsecutiveCandleExit()
{
   // Close PROFITABLE BUY positions if consecutive BULLISH candles (trend confirmed)
   if(consecutiveBullish >= ConsecutiveCandleCount)
   {
      Print("EXIT SIGNAL: ", consecutiveBullish, " consecutive bullish candles - Closing PROFITABLE BUY positions");
      CloseProfitablePositionsByType(POSITION_TYPE_BUY);
   }
   
   // Close PROFITABLE SELL positions if consecutive BEARISH candles (trend confirmed)
   if(consecutiveBearish >= ConsecutiveCandleCount)
   {
      Print("EXIT SIGNAL: ", consecutiveBearish, " consecutive bearish candles - Closing PROFITABLE SELL positions");
      CloseProfitablePositionsByType(POSITION_TYPE_SELL);
   }
}

//+------------------------------------------------------------------+
//| Open trade with improved TP calculation                          |
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE orderType)
{
   double lots = CalculateLotSize();
   double price = (orderType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                                                    SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double sl = 0;
   double tp = 0;
   
   // Calculate Stop Loss
   if(StopLoss > 0)
   {
      double slDistance = StopLoss * _Point;
      sl = (orderType == ORDER_TYPE_BUY) ? price - slDistance : price + slDistance;
   }
   
   // Calculate Take Profit with proper tick value consideration
   if(TakeProfitDollars > 0)
   {
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickValue == 0) tickValue = 1.0; // Fallback
      
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize == 0) tickSize = _Point;
      
      // Calculate points needed to achieve dollar profit
      double pointsNeeded = (TakeProfitDollars * tickSize) / (lots * tickValue);
      
      tp = (orderType == ORDER_TYPE_BUY) ? price + pointsNeeded : price - pointsNeeded;
      
      Print("TP Calculation - Lots: ", lots, " | TickValue: ", tickValue, 
            " | Points: ", pointsNeeded, " | TP: ", tp);
   }
   
   // Normalize prices
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   price = NormalizeDouble(price, digits);
   if(sl > 0) sl = NormalizeDouble(sl, digits);
   if(tp > 0) tp = NormalizeDouble(tp, digits);
   
   string orderTypeStr = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";
   Print("Opening ", orderTypeStr, " | Lot: ", lots, " | Price: ", price, 
         " | SL: ", sl, " | TP: ", tp);
   
   // Execute trade with retry logic
   for(int attempt = 1; attempt <= MaxRetries; attempt++)
   {
      if(trade.PositionOpen(_Symbol, orderType, lots, price, sl, tp, TradeComment))
      {
         Print(orderTypeStr, " order opened successfully on attempt ", attempt);
         return true;
      }
      else
      {
         Print("Failed to open ", orderTypeStr, " order (Attempt ", attempt, "/", MaxRetries, 
               ") - Error: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
         
         if(attempt < MaxRetries)
         {
            Sleep(RetryDelay);
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size                                               |
//+------------------------------------------------------------------+
double CalculateLotSize()
{
   double lots = LotSize;
   
   if(UseAutoLotSizing)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double increments = MathFloor(equity / EquityIncrement);
      lots = increments * AutoLotPer1000;
      
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      
      lots = MathMax(lots, minLot);
      lots = MathMin(lots, maxLot);
      lots = NormalizeDouble(lots / lotStep, 0) * lotStep;
   }
   
   return lots;
}

//+------------------------------------------------------------------+
//| Count my positions                                               |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count my positions by type                                       |
//+------------------------------------------------------------------+
int CountMyPositionsByType(ENUM_POSITION_TYPE posType)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Close ALL positions by type (both profitable and losing)         |
//+------------------------------------------------------------------+
void ClosePositionsByType(ENUM_POSITION_TYPE posType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         {
            trade.PositionClose(ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| NEW: Close only PROFITABLE positions by type                     |
//+------------------------------------------------------------------+
void CloseProfitablePositionsByType(ENUM_POSITION_TYPE posType)
{
   int closedCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(profit > 0)  // Only close if profitable
            {
               if(trade.PositionClose(ticket))
               {
                  closedCount++;
                  Print("Closed profitable position #", ticket, " | Profit: $", DoubleToString(profit, 2));
               }
            }
         }
      }
   }
   
   if(closedCount > 0)
   {
      Print("Total profitable ", (posType == POSITION_TYPE_BUY ? "BUY" : "SELL"), 
            " positions closed: ", closedCount);
   }
}

//+------------------------------------------------------------------+
//| Close all profitable positions (any type)                        |
//+------------------------------------------------------------------+
void CloseAllProfitablePositions()
{
   int closedCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(profit > 0)
            {
               if(trade.PositionClose(ticket))
               {
                  closedCount++;
               }
            }
         }
      }
   }
   Print("Closed ", closedCount, " profitable positions");
}

//+------------------------------------------------------------------+
//| Check global profit target                                       |
//+------------------------------------------------------------------+
void CheckGlobalProfitTarget()
{
   double totalProfit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            totalProfit += PositionGetDouble(POSITION_PROFIT);
         }
      }
   }
   
   if(totalProfit >= GlobalProfitTarget)
   {
      Print("GLOBAL PROFIT TARGET REACHED: $", DoubleToString(totalProfit, 2));
      Print("Closing only PROFITABLE positions...");
      CloseAllProfitablePositions();  // ✅ Only close profitable, keep losers running
   }
}

//+------------------------------------------------------------------+
//| Check drawdown protection with peak equity tracking              |
//+------------------------------------------------------------------+
void CheckDrawdownProtection()
{
   if(drawdownProtectionTriggered) return; // Already triggered
   
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Update peak equity
   if(currentEquity > peakEquity)
   {
      peakEquity = currentEquity;
   }
   
   // Calculate drawdown from peak
   double drawdownAmount = peakEquity - currentEquity;
   double drawdownPercent = (peakEquity > 0) ? (drawdownAmount / peakEquity) * 100.0 : 0.0;
   
   if(drawdownPercent >= MaxDrawdownPercent)
   {
      Print("!!!!! EMERGENCY DRAWDOWN PROTECTION TRIGGERED !!!!!");
      Print("Peak Equity: $", DoubleToString(peakEquity, 2));
      Print("Current Equity: $", DoubleToString(currentEquity, 2));
      Print("Drawdown: ", DoubleToString(drawdownPercent, 2), "% (Limit: ", 
            DoubleToString(MaxDrawdownPercent, 2), "%)");
      Print("Closing all positions and stopping EA...");
      
      CloseAllMyPositions();
      tradingEnabled = false;
      drawdownProtectionTriggered = true;
      
      Alert("DRAWDOWN PROTECTION TRIGGERED! ", DoubleToString(drawdownPercent, 2), 
            "% drawdown detected. All positions closed. EA stopped.");
   }
}

//+------------------------------------------------------------------+
//| Close all my positions                                           |
//+------------------------------------------------------------------+
void CloseAllMyPositions()
{
   int closedCount = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            if(trade.PositionClose(ticket))
            {
               closedCount++;
            }
         }
      }
   }
   Print("Closed ", closedCount, " total positions");
}

//+------------------------------------------------------------------+
//| Format number with commas                                        |
//+------------------------------------------------------------------+
string FormatNumberWithCommas(double value, int decimals)
{
   string result = DoubleToString(value, decimals);
   string parts[];
   int split = StringSplit(result, '.', parts);
   
   if(split > 0)
   {
      string intPart = parts[0];
      string formatted = "";
      int len = StringLen(intPart);
      
      for(int i = 0; i < len; i++)
      {
         if(i > 0 && (len - i) % 3 == 0)
            formatted += ",";
         formatted += StringSubstr(intPart, i, 1);
      }
      
      if(split > 1)
         result = formatted + "." + parts[1];
      else
         result = formatted;
   }
   
   return result;
}

//+------------------------------------------------------------------+
//| Create collapsible info panel with better readability            |
//+------------------------------------------------------------------+
void CreateCollapsibleInfoPanel()
{
   int panelX = 15;
   int panelY = 25;
   int panelWidth = 480;
   int lineHeight = 18;  // INCREASED from 12 to 18 for better readability
   int leftColX = panelX + 15;
   int rightColX = panelX + 260;
   int currentY = panelY + 15;
   
   // Create main background
   ObjectCreate(0, INFO_PANEL_BACKGROUND, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_XDISTANCE, panelX);
   ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_YDISTANCE, panelY);
   ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_XSIZE, panelWidth);
   ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_YSIZE, 440);  // Increased from 420 to 440
   ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_BGCOLOR, BRAND_DARK_BG);
   ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_COLOR, BRAND_BORDER_LIGHT);
   ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_HIDDEN, true);
   
   // Header with gradient effect
   ObjectCreate(0, "infoPanelHeader", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "infoPanelHeader", OBJPROP_XDISTANCE, panelX);
   ObjectSetInteger(0, "infoPanelHeader", OBJPROP_YDISTANCE, panelY);
   ObjectSetInteger(0, "infoPanelHeader", OBJPROP_XSIZE, panelWidth);
   ObjectSetInteger(0, "infoPanelHeader", OBJPROP_YSIZE, 55);
   ObjectSetInteger(0, "infoPanelHeader", OBJPROP_BGCOLOR, BRAND_PRIMARY_BLUE);
   ObjectSetInteger(0, "infoPanelHeader", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, "infoPanelHeader", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "infoPanelHeader", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "infoPanelHeader", OBJPROP_HIDDEN, true);
   
   // Company name - larger, bolder
   ObjectCreate(0, "companyName", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "companyName", OBJPROP_XDISTANCE, leftColX);
   ObjectSetInteger(0, "companyName", OBJPROP_YDISTANCE, currentY);
   ObjectSetInteger(0, "companyName", OBJPROP_COLOR, BRAND_SECONDARY_GOLD);
   ObjectSetInteger(0, "companyName", OBJPROP_FONTSIZE, 11);
   ObjectSetString(0, "companyName", OBJPROP_FONT, "Arial Bold");
   ObjectSetString(0, "companyName", OBJPROP_TEXT, COMPANY_NAME);
   ObjectSetInteger(0, "companyName", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "companyName", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "companyName", OBJPROP_HIDDEN, true);
   
   currentY += 16;
   
   // Tagline
   ObjectCreate(0, "companyTagline", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "companyTagline", OBJPROP_XDISTANCE, leftColX);
   ObjectSetInteger(0, "companyTagline", OBJPROP_YDISTANCE, currentY);
   ObjectSetInteger(0, "companyTagline", OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
   ObjectSetInteger(0, "companyTagline", OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, "companyTagline", OBJPROP_FONT, "Arial");
   ObjectSetString(0, "companyTagline", OBJPROP_TEXT, COMPANY_TAGLINE);
   ObjectSetInteger(0, "companyTagline", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "companyTagline", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "companyTagline", OBJPROP_HIDDEN, true);
   
   currentY += 14;
   
   // Contact info
   ObjectCreate(0, "companyEmail", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "companyEmail", OBJPROP_XDISTANCE, leftColX);
   ObjectSetInteger(0, "companyEmail", OBJPROP_YDISTANCE, currentY);
   ObjectSetInteger(0, "companyEmail", OBJPROP_COLOR, BRAND_ACCENT_TEAL);
   ObjectSetInteger(0, "companyEmail", OBJPROP_FONTSIZE, 7);
   ObjectSetString(0, "companyEmail", OBJPROP_FONT, "Consolas");
   ObjectSetString(0, "companyEmail", OBJPROP_TEXT, "support@toramacapital.com");
   ObjectSetInteger(0, "companyEmail", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "companyEmail", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "companyEmail", OBJPROP_HIDDEN, true);
   
   // License badge
   ObjectCreate(0, "licenseBadge", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "licenseBadge", OBJPROP_XDISTANCE, rightColX + 110);
   ObjectSetInteger(0, "licenseBadge", OBJPROP_YDISTANCE, panelY + 20);
   ObjectSetInteger(0, "licenseBadge", OBJPROP_COLOR, BRAND_SUCCESS_GREEN);
   ObjectSetInteger(0, "licenseBadge", OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, "licenseBadge", OBJPROP_FONT, "Arial Bold");
   ObjectSetString(0, "licenseBadge", OBJPROP_TEXT, "✓ LICENSED");
   ObjectSetInteger(0, "licenseBadge", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "licenseBadge", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "licenseBadge", OBJPROP_HIDDEN, true);
   
   currentY = panelY + 70;
   
   // Create info panel lines with better spacing and visual hierarchy
   for(int i = 0; i < 17; i++)  // Increased from 16 to 17
   {
      string lineName = INFO_PANEL_LINE_PREFIX + IntegerToString(i);
      ObjectCreate(0, lineName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, lineName, OBJPROP_XDISTANCE, leftColX);
      ObjectSetInteger(0, lineName, OBJPROP_YDISTANCE, currentY + (i * lineHeight));
      ObjectSetInteger(0, lineName, OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
      ObjectSetInteger(0, lineName, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, lineName, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, lineName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lineName, OBJPROP_HIDDEN, true);
   }
   
   // Special bold position display
   ObjectCreate(0, "positionsBold", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "positionsBold", OBJPROP_XDISTANCE, leftColX);
   ObjectSetInteger(0, "positionsBold", OBJPROP_YDISTANCE, currentY + (17 * lineHeight));  // Changed from 16 to 17
   ObjectSetInteger(0, "positionsBold", OBJPROP_COLOR, BRAND_SECONDARY_GOLD);
   ObjectSetInteger(0, "positionsBold", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, "positionsBold", OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, "positionsBold", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "positionsBold", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "positionsBold", OBJPROP_HIDDEN, true);
   
   // Right column with better spacing
   for(int i = 0; i < 5; i++)
   {
      string rightLineName = "rightCol" + IntegerToString(i);
      ObjectCreate(0, rightLineName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, rightLineName, OBJPROP_XDISTANCE, rightColX);
      ObjectSetInteger(0, rightLineName, OBJPROP_YDISTANCE, currentY + (i * lineHeight));
      ObjectSetInteger(0, rightLineName, OBJPROP_COLOR, BRAND_TEXT_SECONDARY);
      ObjectSetInteger(0, rightLineName, OBJPROP_FONTSIZE, 8);
      ObjectSetString(0, rightLineName, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, rightLineName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, rightLineName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, rightLineName, OBJPROP_HIDDEN, true);
   }
   
   // Compact info label for minimized state
   ObjectCreate(0, COMPACT_INFO_LABEL, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_XDISTANCE, leftColX);
   ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_YDISTANCE, currentY);
   ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
   ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, COMPACT_INFO_LABEL, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_HIDDEN, true);
   
   // Create control buttons with better styling
   int buttonY = panelY + 405;  // Changed from 385 to 405 for taller panel
   int buttonWidth = 140;
   int buttonHeight = 25;
   int buttonSpacing = 10;
   
   // Toggle Trading Button
   ObjectCreate(0, BTN_TOGGLE_TRADING, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_XDISTANCE, leftColX);
   ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_YDISTANCE, buttonY);
   ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_XSIZE, buttonWidth);
   ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_YSIZE, buttonHeight);
   ObjectSetString(0, BTN_TOGGLE_TRADING, OBJPROP_TEXT, "Toggle Trading");
   ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
   ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_BGCOLOR, BRAND_PRIMARY_BLUE);
   ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_BORDER_COLOR, BRAND_BORDER_LIGHT);
   ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, BTN_TOGGLE_TRADING, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_HIDDEN, true);
   
   // Close Profitable Button
   ObjectCreate(0, BTN_CLOSE_PROFITABLE, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_XDISTANCE, leftColX + buttonWidth + buttonSpacing);
   ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_YDISTANCE, buttonY);
   ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_XSIZE, buttonWidth);
   ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_YSIZE, buttonHeight);
   ObjectSetString(0, BTN_CLOSE_PROFITABLE, OBJPROP_TEXT, "Close Profitable");
   ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
   ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_BGCOLOR, BRAND_SUCCESS_GREEN);
   ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_BORDER_COLOR, BRAND_BORDER_LIGHT);
   ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, BTN_CLOSE_PROFITABLE, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_HIDDEN, true);
   
   // Minimize/Maximize Button
   ObjectCreate(0, BTN_PANEL_MINIMIZE, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_XDISTANCE, panelX + panelWidth - 35);
   ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_YDISTANCE, panelY + 5);
   ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_XSIZE, 28);
   ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_YSIZE, 20);
   ObjectSetString(0, BTN_PANEL_MINIMIZE, OBJPROP_TEXT, isPanelMinimized ? "+" : "-");
   ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_COLOR, BRAND_TEXT_PRIMARY);
   ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_BGCOLOR, BRAND_ACCENT_TEAL);
   ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_BORDER_COLOR, BRAND_BORDER_LIGHT);
   ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_FONTSIZE, 11);
   ObjectSetString(0, BTN_PANEL_MINIMIZE, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, BTN_PANEL_MINIMIZE, OBJPROP_HIDDEN, true);
   
   UpdateCollapsibleInfoPanel();
}

//+------------------------------------------------------------------+
//| Update collapsible info panel                                    |
//+------------------------------------------------------------------+
void UpdateCollapsibleInfoPanel()
{
   if(!isInitialized) return;
   
   // Update minimize button text
   ObjectSetString(0, BTN_PANEL_MINIMIZE, OBJPROP_TEXT, isPanelMinimized ? "+" : "-");
   
   if(isPanelMinimized)
   {
      // Hide all detail objects
      for(int i = 0; i < 17; i++)  // Changed from 16 to 17
      {
         string lineName = INFO_PANEL_LINE_PREFIX + IntegerToString(i);
         ObjectSetInteger(0, lineName, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      }
      
      ObjectSetInteger(0, "positionsBold", OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      
      for(int i = 0; i < 5; i++)
      {
         string rightLineName = "rightCol" + IntegerToString(i);
         ObjectSetInteger(0, rightLineName, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      }
      
      ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      
      // Resize panel to compact
      ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_YSIZE, 85);
      ObjectSetInteger(0, "infoPanelHeader", OBJPROP_YSIZE, 55);
      
      // Show compact info
      int totalPositions = CountMyPositions();
      double totalProfit = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
               totalProfit += PositionGetDouble(POSITION_PROFIT);
            }
         }
      }
      
      string compactInfo = StringFormat("Positions: %d | P&L: $%.2f | Status: %s", 
                                       totalPositions, totalProfit, 
                                       tradingEnabled ? "ACTIVE" : "PAUSED");
      ObjectSetString(0, COMPACT_INFO_LABEL, OBJPROP_TEXT, compactInfo);
      ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
      ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_COLOR, 
                       tradingEnabled ? BRAND_SUCCESS_GREEN : BRAND_WARNING_ORANGE);
   }
   else
   {
      // Show all detail objects
      ObjectSetInteger(0, COMPACT_INFO_LABEL, OBJPROP_TIMEFRAMES, OBJ_NO_PERIODS);
      
      for(int i = 0; i < 17; i++)  // Changed from 16 to 17
      {
         string lineName = INFO_PANEL_LINE_PREFIX + IntegerToString(i);
         ObjectSetInteger(0, lineName, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
      }
      
      ObjectSetInteger(0, "positionsBold", OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
      
      for(int i = 0; i < 5; i++)
      {
         string rightLineName = "rightCol" + IntegerToString(i);
         ObjectSetInteger(0, rightLineName, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
      }
      
      if(ShowButtons)
      {
         ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
         ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
      }
      
      // Resize panel to full
      ObjectSetInteger(0, INFO_PANEL_BACKGROUND, OBJPROP_YSIZE, 440);  // Changed from 420 to 440
      ObjectSetInteger(0, "infoPanelHeader", OBJPROP_YSIZE, 55);
      
      // Update detailed statistics
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      double drawdownAmount = peakEquity - currentEquity;
      double drawdownPercent = (peakEquity > 0) ? (drawdownAmount / peakEquity) * 100.0 : 0.0;
      
      double totalProfit = 0;
      int buyPositions = 0;
      int sellPositions = 0;
      int profitablePositions = 0;
      int losingPositions = 0;
      
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
               PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
               double profit = PositionGetDouble(POSITION_PROFIT);
               totalProfit += profit;
               
               ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
               if(posType == POSITION_TYPE_BUY) buyPositions++;
               else sellPositions++;
               
               if(profit > 0) profitablePositions++;
               else if(profit < 0) losingPositions++;
            }
         }
      }
      
      double effectiveLot = CalculateLotSize();
      long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      
      string tradingStatus = tradingEnabled ? "✓ ACTIVE" : "⚠ PAUSED";
      color statusColor = tradingEnabled ? BRAND_SUCCESS_GREEN : BRAND_WARNING_ORANGE;
      ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "1", OBJPROP_COLOR, statusColor);
      
      string directionText = (TradeDirection == TRADE_BOTH) ? "Both" : 
                            (TradeDirection == TRADE_BUY_ONLY) ? "Buy Only" : "Sell Only";
      
      string tpText = (TakeProfitDollars > 0) ? "$" + DoubleToString(TakeProfitDollars, 2) : "None";
      
      // Format drawdown with color coding
      string drawdownText = StringFormat("%.2f%% ($%.2f)", drawdownPercent, drawdownAmount);
      color drawdownColor = (drawdownPercent > MaxDrawdownPercent * 0.8) ? BRAND_DANGER_RED : 
                           (drawdownPercent > MaxDrawdownPercent * 0.6) ? BRAND_WARNING_ORANGE : 
                           BRAND_SUCCESS_GREEN;
      
      // Global profit progress
      double progressPercent = (GlobalProfitTarget > 0) ? (totalProfit / GlobalProfitTarget) * 100.0 : 0;
      string globalTargetProgress = StringFormat("$%.2f / $%.2f (%.1f%%)", 
                                                totalProfit, GlobalProfitTarget, progressPercent);
      color profitColor = (totalProfit >= 0) ? BRAND_SUCCESS_GREEN : BRAND_DANGER_RED;
      
      // LEFT COLUMN - Improved readability with section headers
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "0", OBJPROP_TEXT, "━━━ MEAN REVERSION STATUS ━━━");
      ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "0", OBJPROP_COLOR, BRAND_SECONDARY_GOLD);
      
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "1", OBJPROP_TEXT, "Status: " + tradingStatus);
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "2", OBJPROP_TEXT, "Symbol: " + _Symbol + "  Spread: " + IntegerToString(spreadPoints));
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "3", OBJPROP_TEXT, "Timeframe: " + EnumToString(TimeframeParam));
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "4", OBJPROP_TEXT, "Strategy: Counter-Trend");
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "5", OBJPROP_TEXT, "Direction: " + directionText);
      
      string lotSizing = UseAutoLotSizing ? " (Auto)" : " (Fixed)";
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "6", OBJPROP_TEXT, "Lot: " + DoubleToString(effectiveLot, 2) + lotSizing);
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "7", OBJPROP_TEXT, "Trades/Signal: " + IntegerToString(actualTradesPerSignal));
      
      string candleFilter = EnableCandleSizeFilter ? 
         "Min: " + DoubleToString(MinCandlePoints, 0) + "pts/" + DoubleToString(MinCandleSpreadRatio, 1) + "x" : 
         "OFF";
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "8", OBJPROP_TEXT, "Candle Filter: " + candleFilter);
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "9", OBJPROP_TEXT, "Take Profit: " + tpText);
      
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "10", OBJPROP_TEXT, "━━━ ACCOUNT INFORMATION ━━━");
      ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "10", OBJPROP_COLOR, BRAND_SECONDARY_GOLD);
      
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "11", OBJPROP_TEXT, "Balance: $" + FormatNumberWithCommas(balance, 2));
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "12", OBJPROP_TEXT, "Equity: $" + FormatNumberWithCommas(equity, 2));
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "13", OBJPROP_TEXT, "Drawdown: " + drawdownText);
      ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "13", OBJPROP_COLOR, drawdownColor);
      
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "14", OBJPROP_TEXT, "━━━ POSITIONS ━━━");
      ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "14", OBJPROP_COLOR, BRAND_SECONDARY_GOLD);
      
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "15", OBJPROP_TEXT, "Profitable: " + IntegerToString(profitablePositions) + "  Losing: " + IntegerToString(losingPositions));
      ObjectSetString(0, INFO_PANEL_LINE_PREFIX + "16", OBJPROP_TEXT, "P&L: " + globalTargetProgress);
      ObjectSetInteger(0, INFO_PANEL_LINE_PREFIX + "16", OBJPROP_COLOR, profitColor);
      
      // BUY/SELL position display
      string positionText = "BUY: " + IntegerToString(buyPositions) + "/" + IntegerToString(MaxPositions) + 
                           "  |  SELL: " + IntegerToString(sellPositions) + "/" + IntegerToString(MaxPositions);
      ObjectSetString(0, "positionsBold", OBJPROP_TEXT, positionText);
      
      // RIGHT COLUMN  
      ObjectSetString(0, "rightCol0", OBJPROP_TEXT, "━━━ SYSTEM INFO ━━━");
      ObjectSetInteger(0, "rightCol0", OBJPROP_COLOR, BRAND_SECONDARY_GOLD);
      ObjectSetString(0, "rightCol1", OBJPROP_TEXT, "Last Bar:");
      ObjectSetString(0, "rightCol2", OBJPROP_TEXT, TimeToString(lastBarTime, TIME_DATE|TIME_MINUTES));
      ObjectSetString(0, "rightCol3", OBJPROP_TEXT, "Bull: " + IntegerToString(consecutiveBullish) + "  Bear: " + IntegerToString(consecutiveBearish));
      ObjectSetString(0, "rightCol4", OBJPROP_TEXT, "Version: " + COMPANY_VERSION);
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Delete info panel                                                |
//+------------------------------------------------------------------+
void DeleteInfoPanel()
{
   Comment("");
   
   Print("DELETING ALL PANEL OBJECTS...");
   
   // Delete main panel objects
   ObjectDelete(0, INFO_PANEL_BACKGROUND);
   ObjectDelete(0, "infoPanelHeader");
   ObjectDelete(0, INFO_PANEL_TITLE);
   ObjectDelete(0, "licenseBadge");
   ObjectDelete(0, COMPACT_INFO_LABEL);
   ObjectDelete(0, "companyName");
   ObjectDelete(0, "companyTagline");
   ObjectDelete(0, "companyEmail");
   ObjectDelete(0, "companyWebsite");
   ObjectDelete(0, "positionsBold");
   
   // Clean up left column lines
   for(int i = 0; i < 30; i++)
   {
      string lineName = INFO_PANEL_LINE_PREFIX + IntegerToString(i);
      ObjectDelete(0, lineName);
   }
   
   // Clean up right column lines
   for(int i = 0; i < 15; i++)
   {
      string rightLineName = "rightCol" + IntegerToString(i);
      ObjectDelete(0, rightLineName);
   }
   
   // Delete buttons
   ObjectDelete(0, BTN_TOGGLE_TRADING);
   ObjectDelete(0, BTN_CLOSE_PROFITABLE);
   ObjectDelete(0, BTN_PANEL_MINIMIZE);
   
   ChartRedraw();
   Print("PANEL DELETION COMPLETE");
}

//+------------------------------------------------------------------+
//| Update display                                                   |
//+------------------------------------------------------------------+
void UpdateDisplay()
{
   if(!isInitialized) return;
   UpdateCollapsibleInfoPanel();
}
//+------------------------------------------------------------------+
