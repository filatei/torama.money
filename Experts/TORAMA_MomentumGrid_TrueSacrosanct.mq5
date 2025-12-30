//+------------------------------------------------------------------+
//|                       TORAMA_MomentumGrid_TrueSacrosanct.mq5     |
//|                                          TORAMA CAPITAL           |
//|                                   Algorithmic Trading Solutions   |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://toramacapital.com"
#property version   "3.00"
#property description "Momentum Grid EA - TRUE Sacrosanct Grid"
#property description "Grid levels NEVER replaced once triggered"
#property description "Global TP & Drawdown Control, No Individual SL/TP"

//--- Include files
#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== TRADING DIRECTION ==="
enum ENUM_TRADE_DIRECTION
{
   DIRECTION_BOTH = 0,      // Trade Both Directions
   DIRECTION_BUY_ONLY = 1,  // Buy Only (Upward Momentum)
   DIRECTION_SELL_ONLY = 2  // Sell Only (Downward Momentum)
};
input ENUM_TRADE_DIRECTION InpTradeDirection = DIRECTION_BOTH; // Trading Direction

input group "=== GRID SETTINGS ==="
input double InpGridGapPercent = 0.5;           // Grid Gap (% of Price)
input double InpInitialLotSize = 0.01;          // Initial Lot Size
input double InpLotMultiplier = 1.0;            // Lot Multiplier (1.0 = Fixed)
input int    InpMaxGridLevels = 30;             // Max Grid Levels (0 = Unlimited)
input double InpMaxSpreadPoints = 0;            // Max Spread (Points, 0 = No Limit)

input group "=== GLOBAL PROFIT & RISK ==="
input double InpGlobalTakeProfitUSD = 100.0;    // Global Take Profit (USD)
input double InpMaxDrawdownPercent = 10.0;      // Max Drawdown (%)
input int    InpDrawdownPauseMinutes = 30;      // Drawdown Pause (Minutes)

input group "=== DISPLAY SETTINGS ==="
input color  InpPanelColor = C'20,25,30';       // Panel Background Color
input color  InpHeaderColor = C'41,98,255';     // Header Color (TORAMA Blue)
input color  InpTextColor = clrWhite;           // Text Color
input int    InpPanelX = 20;                    // Panel X Position
input int    InpPanelY = 50;                    // Panel Y Position

//--- Global variables
CTrade trade;
string sym;
double pt;
int dgt;
double tickSize;
double tickValue;
double minLot, maxLot, lotStep;
double stopLevel;
double gridGapPrice;
datetime lastDrawdownPauseTime = 0;
bool isDrawdownPaused = false;
bool isManuallyPaused = false;
double accountStartBalance = 0;
double peakBalance = 0;
double peakEquity = 0;              // NEW: Track equity high water mark
bool isStoppedByDrawdown = false;   // NEW: Permanent stop flag
long magicNumber = 0;
double effectiveInitialLotSize = 0;

//--- Spread tracking
double maxAllowedSpread = 0;
double currentSpread = 0;

//--- Grid tracking - TRUE SACROSANCT SYSTEM
double referencePrice = 0;           // Sacred reference price
int highestBuyLevel = 0;             // Highest buy level placed
int lowestSellLevel = 0;             // Lowest sell level placed (negative)
bool gridInitialized = false;

//--- CRITICAL: Track triggered levels to prevent replacement
int triggeredBuyLevels[];            // Array of buy levels that have been triggered
int triggeredSellLevels[];           // Array of sell levels that have been triggered (as positive numbers)
int buyTriggeredCount = 0;           // Count of triggered buy levels
int sellTriggeredCount = 0;          // Count of triggered sell levels

//--- Market order mode (for symbols that don't support pending orders like Deriv synthetics)
bool useMarketOrders = false;        // Use market orders instead of pending orders
double lastBuyTriggerPrice = 0;      // Last price where buy was triggered
double lastSellTriggerPrice = 0;     // Last price where sell was triggered

//--- Panel objects
string panelPrefix = "TORAMA_Panel_";

//--- Button tracking
bool buttonPressed = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Get Chart ID as Magic Number
   magicNumber = ChartID();
   PrintFormat("Chart ID (Magic Number): %I64d", magicNumber);
   
   //--- Initialize symbol properties
   sym = _Symbol;
   pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   dgt = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   
   //--- Get lot size limits
   minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   stopLevel = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * pt;
   
   //--- Set max allowed spread
   if(InpMaxSpreadPoints > 0)
   {
      maxAllowedSpread = InpMaxSpreadPoints * pt;
      PrintFormat("Max allowed spread: %.1f points", InpMaxSpreadPoints);
   }
   else
   {
      maxAllowedSpread = 0; // No spread limit
      Print("Spread filter: DISABLED (no limit)");
   }
   
   //--- Validate and adjust initial lot size
   if(InpInitialLotSize < minLot)
   {
      effectiveInitialLotSize = minLot;
      PrintFormat("WARNING: Initial lot size %.2f is below broker minimum %.2f", InpInitialLotSize, minLot);
      PrintFormat("INFO: Using broker minimum lot size: %.2f", effectiveInitialLotSize);
   }
   else if(InpInitialLotSize > maxLot)
   {
      effectiveInitialLotSize = maxLot;
      PrintFormat("WARNING: Initial lot size %.2f exceeds broker maximum %.2f", InpInitialLotSize, maxLot);
      PrintFormat("INFO: Using broker maximum lot size: %.2f", effectiveInitialLotSize);
   }
   else
   {
      effectiveInitialLotSize = InpInitialLotSize;
   }
   
   //--- Normalize to lot step
   effectiveInitialLotSize = NormalizeLot(effectiveInitialLotSize);
   
   //--- Validate other inputs
   if(InpGridGapPercent <= 0)
   {
      Print("ERROR: Grid gap must be positive!");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(InpGlobalTakeProfitUSD <= 0)
   {
      Print("ERROR: Global take profit must be positive!");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(InpMaxDrawdownPercent <= 0 || InpMaxDrawdownPercent > 100)
   {
      Print("ERROR: Max drawdown must be between 0 and 100%!");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(InpMaxSpreadPoints < 0)
   {
      Print("ERROR: Max spread must be 0 or positive!");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   //--- Setup trade class with Chart ID as magic number
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   if(trade.ResultRetcode() == TRADE_RETCODE_INVALID_FILL)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   //--- Initialize account tracking
   accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   peakBalance = accountStartBalance;
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);  // Initialize equity high water mark
   isStoppedByDrawdown = false;
   
   //--- Initialize triggered level arrays (max 200 levels each direction)
   ArrayResize(triggeredBuyLevels, 200);
   ArrayResize(triggeredSellLevels, 200);
   ArrayFill(triggeredBuyLevels, 0, ArraySize(triggeredBuyLevels), -999999);
   ArrayFill(triggeredSellLevels, 0, ArraySize(triggeredSellLevels), -999999);
   buyTriggeredCount = 0;
   sellTriggeredCount = 0;
   
   //--- Auto-detect if we should use market orders (for Deriv synthetics, etc.)
   DetectMarketOrderMode();
   
   //--- Calculate initial grid gap
   CalculateGridGap();
   
   //--- Initialize sacrosanct grid
   InitializeSacrosanctGrid();
   
   //--- Create display panel
   CreatePanel();
   
   //--- Enable chart events for button clicks
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
   
   PrintFormat("TORAMA Momentum Grid EA initialized on %s", sym);
   PrintFormat("Magic Number (Chart ID): %I64d", magicNumber);
   PrintFormat("Effective Lot Size: %.2f (Input: %.2f, Broker Min: %.2f, Max: %.2f)", 
               effectiveInitialLotSize, InpInitialLotSize, minLot, maxLot);
   PrintFormat("Grid Gap: %.5f (%.2f%%), Global TP: $%.2f, Max DD: %.1f%%", 
               gridGapPrice, InpGridGapPercent, InpGlobalTakeProfitUSD, InpMaxDrawdownPercent);
   PrintFormat("TRUE SACROSANCT GRID - Reference Price: %.*f", dgt, referencePrice);
   Print("Grid levels will NEVER be replaced once triggered!");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Remove all panel objects
   DeletePanel();
   
   Comment("");
   PrintFormat("TORAMA Momentum Grid EA stopped. Reason: %s", GetUninitReasonText(reason));
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Update current spread
   currentSpread = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
   
   //--- Update grid gap dynamically
   CalculateGridGap();
   
   //--- Track triggered levels (positions that opened from pending orders)
   TrackTriggeredLevels();
   
   //--- CRITICAL: Check if EA is permanently stopped by drawdown
   if(isStoppedByDrawdown)
   {
      UpdatePanel();
      return; // EA is permanently stopped - no trading
   }
   
   //--- Check for global take profit
   if(CheckGlobalTakeProfit())
   {
      CloseAllPositions();
      DeleteAllPendingOrders();
      ResetSacrosanctGrid();
      PrintFormat("Global TP reached: $%.2f - All positions closed, grid reset", InpGlobalTakeProfitUSD);
      UpdatePanel();
      return;
   }
   
   //--- Check if manually paused
   if(isManuallyPaused)
   {
      UpdatePanel();
      return;
   }
   
   //--- Check for MAX DRAWDOWN - CLOSE ALL AND STOP
   if(CheckMaxDrawdown())
   {
      if(!isStoppedByDrawdown)
      {
         isStoppedByDrawdown = true;
         double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         double drawdown = ((peakEquity - currentEquity) / peakEquity) * 100.0;
         
         PrintFormat("========================================");
         PrintFormat("MAX DRAWDOWN REACHED: %.2f%%", drawdown);
         PrintFormat("Peak Equity: $%.2f", peakEquity);
         PrintFormat("Current Equity: $%.2f", currentEquity);
         PrintFormat("Closing all positions and STOPPING EA");
         PrintFormat("========================================");
         
         CloseAllPositions();
         DeleteAllPendingOrders();
         
         Comment(StringFormat("\n\n*** EA STOPPED ***\n\nMax Drawdown Reached: %.2f%%\n\nAll positions closed\nEA will not trade again\n\nRemove EA from chart to restart", drawdown));
         UpdatePanel();
         return;
      }
   }
   
   //--- Check if all positions closed -> reset grid (only if not stopped by drawdown)
   if(GetTotalPositions() == 0 && gridInitialized && !isStoppedByDrawdown)
   {
      PrintFormat("All positions closed - Resetting sacrosanct grid");
      DeleteAllPendingOrders();
      ResetSacrosanctGrid();
   }
   
   //--- Maintain sacrosanct grid - ensure pending orders exist
   MaintainSacrosanctGrid();
   
   //--- Update display
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| Track triggered levels - CRITICAL NEW FUNCTION                    |
//+------------------------------------------------------------------+
void TrackTriggeredLevels()
{
   //--- Check all open positions to see if they opened from pending orders
   int totalPositions = PositionsTotal();
   
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      //--- Extract level from position comment
      string comment = PositionGetString(POSITION_COMMENT);
      if(StringFind(comment, "TORAMA_Grid_L") != 0) continue;
      
      //--- Parse level number from comment
      string levelStr = StringSubstr(comment, 13); // After "TORAMA_Grid_L"
      int level = (int)StringToInteger(levelStr);
      
      //--- Determine position type and mark level as triggered
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      if(posType == POSITION_TYPE_BUY)
      {
         if(!IsLevelTriggered(level, true))
         {
            MarkLevelAsTriggered(level, true);
            PrintFormat("BUY Level %d TRIGGERED - Will NEVER be replaced!", level);
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         if(!IsLevelTriggered(level, false))
         {
            MarkLevelAsTriggered(level, false);
            PrintFormat("SELL Level %d TRIGGERED - Will NEVER be replaced!", level);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if a level has been triggered                               |
//+------------------------------------------------------------------+
bool IsLevelTriggered(int level, bool isBuy)
{
   if(isBuy)
   {
      for(int i = 0; i < buyTriggeredCount; i++)
      {
         if(triggeredBuyLevels[i] == level)
            return true;
      }
   }
   else
   {
      int absLevel = MathAbs(level);
      for(int i = 0; i < sellTriggeredCount; i++)
      {
         if(triggeredSellLevels[i] == absLevel)
            return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Mark a level as triggered (sacrosanct - never to be replaced)     |
//+------------------------------------------------------------------+
void MarkLevelAsTriggered(int level, bool isBuy)
{
   if(isBuy)
   {
      if(buyTriggeredCount >= ArraySize(triggeredBuyLevels))
      {
         ArrayResize(triggeredBuyLevels, ArraySize(triggeredBuyLevels) + 100);
      }
      triggeredBuyLevels[buyTriggeredCount] = level;
      buyTriggeredCount++;
   }
   else
   {
      if(sellTriggeredCount >= ArraySize(triggeredSellLevels))
      {
         ArrayResize(triggeredSellLevels, ArraySize(triggeredSellLevels) + 100);
      }
      int absLevel = MathAbs(level);
      triggeredSellLevels[sellTriggeredCount] = absLevel;
      sellTriggeredCount++;
   }
}

//+------------------------------------------------------------------+
//| ChartEvent function - Handle button clicks                        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      //--- Disable all buttons if EA is stopped by drawdown
      if(isStoppedByDrawdown)
      {
         return; // No button actions when stopped
      }
      
      //--- Close All button
      if(sparam == panelPrefix + "BtnCloseAll")
      {
         if(!buttonPressed)
         {
            buttonPressed = true;
            ObjectSetInteger(0, panelPrefix + "BtnCloseAll", OBJPROP_STATE, false);
            
            Print("Close All button pressed - Closing all positions, deleting pending orders, resetting grid");
            CloseAllPositions();
            DeleteAllPendingOrders();
            ResetSacrosanctGrid();
            
            Sleep(100);
            buttonPressed = false;
            UpdatePanel();
         }
      }
      
      //--- Pause/Resume button
      else if(sparam == panelPrefix + "BtnPause")
      {
         if(!buttonPressed)
         {
            buttonPressed = true;
            ObjectSetInteger(0, panelPrefix + "BtnPause", OBJPROP_STATE, false);
            
            isManuallyPaused = !isManuallyPaused;
            
            if(isManuallyPaused)
            {
               Print("Trading PAUSED manually");
               ObjectSetString(0, panelPrefix + "BtnPause", OBJPROP_TEXT, "RESUME");
               ObjectSetInteger(0, panelPrefix + "BtnPause", OBJPROP_BGCOLOR, clrOrangeRed);
            }
            else
            {
               Print("Trading RESUMED manually");
               ObjectSetString(0, panelPrefix + "BtnPause", OBJPROP_TEXT, "PAUSE");
               ObjectSetInteger(0, panelPrefix + "BtnPause", OBJPROP_BGCOLOR, C'255,152,0');
            }
            
            Sleep(100);
            buttonPressed = false;
            UpdatePanel();
         }
      }
      
      //--- Take Profit Now button
      else if(sparam == panelPrefix + "BtnTakeProfit")
      {
         if(!buttonPressed)
         {
            buttonPressed = true;
            ObjectSetInteger(0, panelPrefix + "BtnTakeProfit", OBJPROP_STATE, false);
            
            double totalProfit = GetTotalProfit();
            PrintFormat("Take Profit Now pressed - Closing all positions (Profit: $%.2f)", totalProfit);
            CloseAllPositions();
            DeleteAllPendingOrders();
            ResetSacrosanctGrid();
            
            Sleep(100);
            buttonPressed = false;
            UpdatePanel();
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Detect if we should use market orders instead of pending         |
//+------------------------------------------------------------------+
void DetectMarketOrderMode()
{
   //--- Check if symbol name contains Deriv synthetic indicator
   string symbolName = sym;
   StringToUpper(symbolName);
   
   //--- List of Deriv synthetic symbols that don't support pending orders
   if(StringFind(symbolName, "BOOM") >= 0 ||
      StringFind(symbolName, "CRASH") >= 0 ||
      StringFind(symbolName, "JUMP") >= 0 ||
      StringFind(symbolName, "RANGE") >= 0 ||
      StringFind(symbolName, "STEP") >= 0 ||
      StringFind(symbolName, "VOLATILITY") >= 0 ||
      StringFind(symbolName, "1HZ") >= 0)
   {
      useMarketOrders = true;
      Print("MARKET ORDER MODE ENABLED - Deriv synthetic symbol detected");
      Print("EA will use market orders instead of pending orders");
   }
   else
   {
      useMarketOrders = false;
      Print("PENDING ORDER MODE - Standard symbol");
   }
}

//+------------------------------------------------------------------+
//| Calculate grid gap based on current price                         |
//+------------------------------------------------------------------+
void CalculateGridGap()
{
   double currentPrice = SymbolInfoDouble(sym, SYMBOL_BID);
   if(currentPrice <= 0) return;
   
   gridGapPrice = NormalizeDouble(currentPrice * InpGridGapPercent / 100.0, dgt);
   
   //--- Ensure grid gap meets minimum requirements
   double minGap = stopLevel * 2;
   if(minGap > 0 && gridGapPrice < minGap)
   {
      gridGapPrice = minGap;
   }
   
   //--- Align to tick size
   gridGapPrice = MathRound(gridGapPrice / tickSize) * tickSize;
}

//+------------------------------------------------------------------+
//| Initialize Sacrosanct Grid System                                 |
//+------------------------------------------------------------------+
void InitializeSacrosanctGrid()
{
   //--- Set reference price as current mid-price
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   referencePrice = NormalizeDouble((ask + bid) / 2.0, dgt);
   
   //--- Align reference price to tick size
   referencePrice = MathRound(referencePrice / tickSize) * tickSize;
   
   //--- Reset grid levels
   highestBuyLevel = 0;
   lowestSellLevel = 0;
   
   gridInitialized = true;
   
   PrintFormat("Sacrosanct Grid Initialized - Reference: %.*f, Gap: %.*f", 
               dgt, referencePrice, dgt, gridGapPrice);
   
   //--- Place initial order AT reference price
   PlaceInitialOrder();
   
   //--- Place initial grid of pending orders
   MaintainSacrosanctGrid();
}

//+------------------------------------------------------------------+
//| Reset Sacrosanct Grid System                                      |
//+------------------------------------------------------------------+
void ResetSacrosanctGrid()
{
   //--- Set NEW reference price as current mid-price
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   referencePrice = NormalizeDouble((ask + bid) / 2.0, dgt);
   
   //--- Align reference price to tick size
   referencePrice = MathRound(referencePrice / tickSize) * tickSize;
   
   //--- Reset grid levels
   highestBuyLevel = 0;
   lowestSellLevel = 0;
   
   //--- CRITICAL: Clear triggered level arrays
   ArrayFill(triggeredBuyLevels, 0, ArraySize(triggeredBuyLevels), -999999);
   ArrayFill(triggeredSellLevels, 0, ArraySize(triggeredSellLevels), -999999);
   buyTriggeredCount = 0;
   sellTriggeredCount = 0;
   
   //--- Update peak balance and equity (reset high water mark)
   peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   gridInitialized = true;
   
   PrintFormat("Sacrosanct Grid RESET - New Reference: %.*f, Gap: %.*f", 
               dgt, referencePrice, dgt, gridGapPrice);
   PrintFormat("Triggered levels cleared. Fresh grid starting.");
   
   //--- Place initial order AT reference price
   PlaceInitialOrder();
   
   //--- Place fresh grid of pending orders
   MaintainSacrosanctGrid();
}

//+------------------------------------------------------------------+
//| Place initial order AT reference price                            |
//+------------------------------------------------------------------+
void PlaceInitialOrder()
{
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   
   //--- Determine if we should place buy or sell based on current price vs reference
   if(ask < referencePrice && (InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_BUY_ONLY))
   {
      //--- Price is below reference, place BUY STOP at reference
      PlaceBuyOrder(0, referencePrice);
   }
   else if(bid > referencePrice && (InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_SELL_ONLY))
   {
      //--- Price is above reference, place SELL STOP at reference
      PlaceSellOrder(0, referencePrice);
   }
   else if(MathAbs(ask - referencePrice) < gridGapPrice / 2)
   {
      //--- Price is very close to reference, open market order
      double lotSize = CalculateLotSize(0);
      lotSize = NormalizeLot(lotSize);
      
      if(InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_BUY_ONLY)
      {
         if(trade.Buy(lotSize, sym, 0, 0, 0, "TORAMA_Grid_L0"))
         {
            PrintFormat("Market BUY at reference: %.5f, Lot=%.2f", ask, lotSize);
         }
      }
      else if(InpTradeDirection == DIRECTION_SELL_ONLY)
      {
         if(trade.Sell(lotSize, sym, 0, 0, 0, "TORAMA_Grid_L0"))
         {
            PrintFormat("Market SELL at reference: %.5f, Lot=%.2f", bid, lotSize);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Maintain Sacrosanct Grid - MODIFIED FOR TRUE SACROSANCT          |
//+------------------------------------------------------------------+
void MaintainSacrosanctGrid()
{
   if(!gridInitialized) return;
   
   //--- Get current price
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   
   //--- For market order mode, check if price has crossed grid levels
   if(useMarketOrders)
   {
      CheckAndExecuteMarketOrders();
      return;
   }
   
   //--- Calculate how many levels we need based on current price distance from reference
   int levelsAbove = (int)MathCeil((ask - referencePrice) / gridGapPrice);
   int levelsBelow = (int)MathCeil((referencePrice - bid) / gridGapPrice);
   
   //--- Place BUY orders (above reference for momentum up)
   if(InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_BUY_ONLY)
   {
      for(int level = highestBuyLevel + 1; level <= levelsAbove + 10; level++) // 10 levels ahead
      {
         if(InpMaxGridLevels > 0 && level > InpMaxGridLevels) break;
         
         //--- CRITICAL: Skip if level was already triggered
         if(IsLevelTriggered(level, true))
         {
            continue; // Do NOT place order at triggered level
         }
         
         double orderPrice = referencePrice + (level * gridGapPrice);
         if(!PendingOrderExists(level, true))
         {
            if(PlaceBuyOrder(level, orderPrice))
            {
               highestBuyLevel = level;
            }
         }
         else
         {
            highestBuyLevel = MathMax(highestBuyLevel, level);
         }
      }
   }
   
   //--- Place SELL orders (below reference for momentum down)
   if(InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_SELL_ONLY)
   {
      for(int level = lowestSellLevel - 1; level >= -(levelsBelow + 10); level--) // 10 levels ahead
      {
         if(InpMaxGridLevels > 0 && MathAbs(level) > InpMaxGridLevels) break;
         
         //--- CRITICAL: Skip if level was already triggered
         if(IsLevelTriggered(level, false))
         {
            continue; // Do NOT place order at triggered level
         }
         
         double orderPrice = referencePrice + (level * gridGapPrice); // level is negative
         if(!PendingOrderExists(level, false))
         {
            if(PlaceSellOrder(level, orderPrice))
            {
               lowestSellLevel = level;
            }
         }
         else
         {
            lowestSellLevel = MathMin(lowestSellLevel, level);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check price and execute market orders when levels are crossed    |
//+------------------------------------------------------------------+
void CheckAndExecuteMarketOrders()
{
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   
   //--- Check BUY levels (price moving up above reference)
   if(InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_BUY_ONLY)
   {
      //--- Calculate current level based on ask price
      int currentLevel = (int)MathFloor((ask - referencePrice) / gridGapPrice);
      
      //--- Check if we've crossed into a new level
      for(int level = 1; level <= currentLevel; level++)
      {
         if(InpMaxGridLevels > 0 && level > InpMaxGridLevels) break;
         
         //--- Skip if already triggered
         if(IsLevelTriggered(level, true)) continue;
         
         //--- Skip if position already exists at this level
         if(PositionExistsAtLevel(level, true)) continue;
         
         double levelPrice = referencePrice + (level * gridGapPrice);
         
         //--- Check if we've crossed this level
         if(ask >= levelPrice)
         {
            //--- Execute market buy
            ExecuteMarketBuy(level);
            MarkLevelAsTriggered(level, true);
            highestBuyLevel = MathMax(highestBuyLevel, level);
         }
      }
   }
   
   //--- Check SELL levels (price moving down below reference)
   if(InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_SELL_ONLY)
   {
      //--- Calculate current level based on bid price (negative)
      int currentLevel = (int)MathFloor((referencePrice - bid) / gridGapPrice);
      
      //--- Check if we've crossed into a new level
      for(int level = 1; level <= currentLevel; level++)
      {
         if(InpMaxGridLevels > 0 && level > InpMaxGridLevels) break;
         
         int sellLevel = -level; // Negative for sell
         
         //--- Skip if already triggered
         if(IsLevelTriggered(sellLevel, false)) continue;
         
         //--- Skip if position already exists at this level
         if(PositionExistsAtLevel(sellLevel, false)) continue;
         
         double levelPrice = referencePrice - (level * gridGapPrice);
         
         //--- Check if we've crossed this level
         if(bid <= levelPrice)
         {
            //--- Execute market sell
            ExecuteMarketSell(sellLevel);
            MarkLevelAsTriggered(sellLevel, false);
            lowestSellLevel = MathMin(lowestSellLevel, sellLevel);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Execute market BUY order                                          |
//+------------------------------------------------------------------+
void ExecuteMarketBuy(int level)
{
   double lotSize = CalculateLotSize(MathAbs(level));
   lotSize = NormalizeLot(lotSize);
   
   if(lotSize < minLot || lotSize > maxLot)
   {
      PrintFormat("ERROR: Invalid lot size %.2f for level %d", lotSize, level);
      return;
   }
   
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   string comment = "TORAMA_Grid_L" + IntegerToString(level);
   
   if(trade.Buy(lotSize, sym, ask, 0, 0, comment))
   {
      PrintFormat("MARKET BUY executed: Level=%d, Price=%.*f, Lot=%.2f", level, dgt, ask, lotSize);
   }
   else
   {
      PrintFormat("MARKET BUY failed: Level=%d, Error=%d - %s", level, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Execute market SELL order                                         |
//+------------------------------------------------------------------+
void ExecuteMarketSell(int level)
{
   double lotSize = CalculateLotSize(MathAbs(level));
   lotSize = NormalizeLot(lotSize);
   
   if(lotSize < minLot || lotSize > maxLot)
   {
      PrintFormat("ERROR: Invalid lot size %.2f for level %d", lotSize, level);
      return;
   }
   
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   string comment = "TORAMA_Grid_L" + IntegerToString(level);
   
   if(trade.Sell(lotSize, sym, bid, 0, 0, comment))
   {
      PrintFormat("MARKET SELL executed: Level=%d, Price=%.*f, Lot=%.2f", level, dgt, bid, lotSize);
   }
   else
   {
      PrintFormat("MARKET SELL failed: Level=%d, Error=%d - %s", level, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Check if position exists at a specific level                      |
//+------------------------------------------------------------------+
bool PositionExistsAtLevel(int level, bool isBuy)
{
   int totalPositions = PositionsTotal();
   
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      string comment = PositionGetString(POSITION_COMMENT);
      string expectedComment = "TORAMA_Grid_L" + IntegerToString(level);
      
      if(comment == expectedComment)
      {
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if((isBuy && posType == POSITION_TYPE_BUY) || (!isBuy && posType == POSITION_TYPE_SELL))
            return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check if pending order exists at level                            |
//+------------------------------------------------------------------+
bool PendingOrderExists(int level, bool isBuy)
{
   int totalOrders = OrdersTotal();
   
   for(int i = 0; i < totalOrders; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0) continue;
      
      if(OrderGetString(ORDER_SYMBOL) != sym) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
      
      string comment = OrderGetString(ORDER_COMMENT);
      string expectedComment = "TORAMA_Grid_L" + IntegerToString(level);
      
      if(comment == expectedComment)
         return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Place BUY pending order                                           |
//+------------------------------------------------------------------+
bool PlaceBuyOrder(int level, double price)
{
   //--- Calculate lot size based on level
   double lotSize = CalculateLotSize(MathAbs(level));
   lotSize = NormalizeLot(lotSize);
   
   if(lotSize < minLot || lotSize > maxLot)
   {
      PrintFormat("ERROR: Invalid lot size %.2f for level %d", lotSize, level);
      return false;
   }
   
   //--- Normalize price
   price = NormalizeDouble(price, dgt);
   
   //--- Check minimum distance from current price
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double minDistance = stopLevel;
   
   if(price <= ask + minDistance)
   {
      price = ask + minDistance + gridGapPrice;
      price = NormalizeDouble(price, dgt);
   }
   
   //--- Place BUY STOP order
   string comment = "TORAMA_Grid_L" + IntegerToString(level);
   
   if(trade.BuyStop(lotSize, price, sym, 0, 0, ORDER_TIME_GTC, 0, comment))
   {
      PrintFormat("BUY STOP placed: Level=%d, Price=%.*f, Lot=%.2f", level, dgt, price, lotSize);
      return true;
   }
   else
   {
      PrintFormat("BUY STOP failed: Level=%d, Error=%d - %s", level, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Place SELL pending order                                          |
//+------------------------------------------------------------------+
bool PlaceSellOrder(int level, double price)
{
   //--- Calculate lot size based on level
   double lotSize = CalculateLotSize(MathAbs(level));
   lotSize = NormalizeLot(lotSize);
   
   if(lotSize < minLot || lotSize > maxLot)
   {
      PrintFormat("ERROR: Invalid lot size %.2f for level %d", lotSize, level);
      return false;
   }
   
   //--- Normalize price
   price = NormalizeDouble(price, dgt);
   
   //--- Check minimum distance from current price
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double minDistance = stopLevel;
   
   if(price >= bid - minDistance)
   {
      price = bid - minDistance - gridGapPrice;
      price = NormalizeDouble(price, dgt);
   }
   
   //--- Place SELL STOP order
   string comment = "TORAMA_Grid_L" + IntegerToString(level);
   
   if(trade.SellStop(lotSize, price, sym, 0, 0, ORDER_TIME_GTC, 0, comment))
   {
      PrintFormat("SELL STOP placed: Level=%d, Price=%.*f, Lot=%.2f", level, dgt, price, lotSize);
      return true;
   }
   else
   {
      PrintFormat("SELL STOP failed: Level=%d, Error=%d - %s", level, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on grid level                            |
//+------------------------------------------------------------------+
double CalculateLotSize(int gridLevel)
{
   double lotSize = effectiveInitialLotSize;
   
   if(InpLotMultiplier != 1.0 && gridLevel > 0)
   {
      lotSize = effectiveInitialLotSize * MathPow(InpLotMultiplier, gridLevel);
   }
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Normalize lot size                                                 |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Check global take profit                                          |
//+------------------------------------------------------------------+
bool CheckGlobalTakeProfit()
{
   double totalProfit = GetTotalProfit();
   return (totalProfit >= InpGlobalTakeProfitUSD);
}

//+------------------------------------------------------------------+
//| Get total profit from all positions                               |
//+------------------------------------------------------------------+
double GetTotalProfit()
{
   double totalProfit = 0;
   int totalPositions = PositionsTotal();
   
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   
   return totalProfit;
}

//+------------------------------------------------------------------+
//| Get total number of positions                                     |
//+------------------------------------------------------------------+
int GetTotalPositions()
{
   int count = 0;
   int totalPositions = PositionsTotal();
   
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      count++;
   }
   
   return count;
}

//+------------------------------------------------------------------+
//| Get total lots by type                                            |
//+------------------------------------------------------------------+
double GetTotalLots(bool buyOnly)
{
   double totalLots = 0;
   int totalPositions = PositionsTotal();
   
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      if(buyOnly && posType == POSITION_TYPE_BUY)
         totalLots += PositionGetDouble(POSITION_VOLUME);
      else if(!buyOnly && posType == POSITION_TYPE_SELL)
         totalLots += PositionGetDouble(POSITION_VOLUME);
   }
   
   return totalLots;
}

//+------------------------------------------------------------------+
//| Get grid level counts                                             |
//+------------------------------------------------------------------+
int GetGridLevelCount(bool buyOnly)
{
   int count = 0;
   int totalPositions = PositionsTotal();
   
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      if(buyOnly && posType == POSITION_TYPE_BUY)
         count++;
      else if(!buyOnly && posType == POSITION_TYPE_SELL)
         count++;
   }
   
   return count;
}

//+------------------------------------------------------------------+
//| Get next pending order price                                      |
//+------------------------------------------------------------------+
double GetNextPendingPrice(bool buyOrder)
{
   double nextPrice = 0;
   int totalOrders = OrdersTotal();
   
   for(int i = 0; i < totalOrders; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0) continue;
      
      if(OrderGetString(ORDER_SYMBOL) != sym) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
      
      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      
      if(buyOrder && orderType == ORDER_TYPE_BUY_STOP)
      {
         if(nextPrice == 0 || orderPrice < nextPrice)
            nextPrice = orderPrice;
      }
      else if(!buyOrder && orderType == ORDER_TYPE_SELL_STOP)
      {
         if(nextPrice == 0 || orderPrice > nextPrice)
            nextPrice = orderPrice;
      }
   }
   
   return nextPrice;
}

//+------------------------------------------------------------------+
//| Check MAX drawdown from equity high water mark                   |
//+------------------------------------------------------------------+
bool CheckMaxDrawdown()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   //--- Update peak EQUITY (high water mark)
   if(currentEquity > peakEquity)
   {
      peakEquity = currentEquity;
      PrintFormat("New equity high water mark: $%.2f", peakEquity);
   }
   
   //--- Calculate drawdown from peak EQUITY
   double drawdown = 0;
   if(peakEquity > 0)
      drawdown = ((peakEquity - currentEquity) / peakEquity) * 100.0;
   
   //--- Check if max drawdown exceeded
   return (drawdown >= InpMaxDrawdownPercent);
}

//+------------------------------------------------------------------+
//| Close all positions                                                |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   int totalPositions = PositionsTotal();
   
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      if(!trade.PositionClose(ticket))
      {
         PrintFormat("Failed to close position #%I64u: %d - %s", 
                    ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
      else
      {
         Sleep(100); // Small delay between closes
      }
   }
}

//+------------------------------------------------------------------+
//| Delete all pending orders                                         |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   int totalOrders = OrdersTotal();
   
   for(int i = totalOrders - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0) continue;
      
      if(OrderGetString(ORDER_SYMBOL) != sym) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
      
      if(!trade.OrderDelete(ticket))
      {
         PrintFormat("Failed to delete order #%I64u: %d - %s", 
                    ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
      else
      {
         PrintFormat("Deleted pending order #%I64u", ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Create professional display panel - ENHANCED VERSION              |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int panelWidth = 340;
   int panelHeight = 328;  // Increased from 290 to accommodate new rows
   int lineHeight = 19;
   int colWidth = 160;
   
   int xLeft = InpPanelX + 12;
   int xRight = InpPanelX + colWidth + 10;
   int yOffset = InpPanelY;
   
   //--- Background panel (solid, on top)
   CreateRectLabel(panelPrefix + "BG", InpPanelX, yOffset, panelWidth, panelHeight, InpPanelColor, CORNER_LEFT_UPPER, false);
   yOffset += 10;
   
   //--- Header: TRUE SACROSANCT
   CreateText(panelPrefix + "EAName", xLeft, yOffset, "TRUE SACROSANCT GRID", clrGold, 11, "Arial Black");
   yOffset += 24;
   
   //--- Separator line
   CreateRectLabel(panelPrefix + "Sep1", InpPanelX + 8, yOffset, panelWidth - 16, 1, clrDimGray, CORNER_LEFT_UPPER, false);
   yOffset += 7;
   
   //--- Row 1: Status | Direction
   CreateText(panelPrefix + "StatusLabel", xLeft, yOffset, "Status:", C'120,120,120', 9);
   CreateText(panelPrefix + "Status", xLeft + 52, yOffset, "Active", clrLimeGreen, 9, "Arial Bold");
   CreateText(panelPrefix + "DirLabel", xRight, yOffset, "Dir:", C'120,120,120', 9);
   CreateText(panelPrefix + "Direction", xRight + 32, yOffset, "BOTH", clrWhite, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 2: Symbol | Magic #
   CreateText(panelPrefix + "SymLabel", xLeft, yOffset, "Symbol:", C'120,120,120', 9);
   CreateText(panelPrefix + "Symbol", xLeft + 52, yOffset, sym, clrWhite, 9, "Arial Bold");
   CreateText(panelPrefix + "MagicLabel", xRight, yOffset, "Magic:", C'120,120,120', 9);
   CreateText(panelPrefix + "Magic", xRight + 45, yOffset, IntegerToString(magicNumber), clrWhite, 8);
   yOffset += lineHeight;
   
   //--- Row 3: Lot Size | Spread
   CreateText(panelPrefix + "LotLabel", xLeft, yOffset, "Lot:", C'120,120,120', 9);
   CreateText(panelPrefix + "LotSize", xLeft + 52, yOffset, 
              StringFormat("%.2f", effectiveInitialLotSize), 
              (effectiveInitialLotSize == InpInitialLotSize) ? clrWhite : clrYellow, 9, "Arial Bold");
   CreateText(panelPrefix + "SpreadLabel", xRight, yOffset, "Spread:", C'120,120,120', 9);
   CreateText(panelPrefix + "Spread", xRight + 50, yOffset, "0.0", clrWhite, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 4: Equity | Reference Price
   CreateText(panelPrefix + "EquityLabel", xLeft, yOffset, "Equity:", C'120,120,120', 9);
   CreateText(panelPrefix + "Equity", xLeft + 52, yOffset, "$0.00", C'240,248,255', 9, "Arial Black");
   CreateText(panelPrefix + "RefLabel", xRight, yOffset, "Ref:", C'120,120,120', 9);
   CreateText(panelPrefix + "RefPrice", xRight + 32, yOffset, "0.00000", clrWhite, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 4b: Peak Equity (high water mark)
   CreateText(panelPrefix + "PeakLabel", xLeft, yOffset, "Peak:", C'120,120,120', 9);
   CreateText(panelPrefix + "PeakEquity", xLeft + 52, yOffset, "$0.00", clrGold, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 5: Grid Gap (full width)
   CreateText(panelPrefix + "GapLabel", xLeft, yOffset, "Grid Gap:", C'120,120,120', 9);
   CreateText(panelPrefix + "GridGap", xLeft + 65, yOffset, "0.00%", clrWhite, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 6: Triggered levels count
   CreateText(panelPrefix + "TriggeredLabel", xLeft, yOffset, "Triggered:", clrOrange, 9, "Arial Bold");
   CreateText(panelPrefix + "TriggeredCount", xLeft + 72, yOffset, "B:0 | S:0", clrOrange, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 6b: Execution mode
   CreateText(panelPrefix + "ModeLabel", xLeft, yOffset, "Mode:", C'120,120,120', 9);
   string modeText = useMarketOrders ? "MARKET" : "PENDING";
   color modeColor = useMarketOrders ? clrYellow : clrLimeGreen;
   CreateText(panelPrefix + "Mode", xLeft + 45, yOffset, modeText, modeColor, 9, "Arial Bold");
   yOffset += lineHeight + 2;
   
   //--- Separator
   CreateRectLabel(panelPrefix + "Sep2", InpPanelX + 8, yOffset, panelWidth - 16, 1, clrDimGray, CORNER_LEFT_UPPER, false);
   yOffset += 7;
   
   //--- Row 7: Next Buy | Next Sell
   CreateText(panelPrefix + "NextBuyLabel", xLeft, yOffset, "Next Buy:", clrDodgerBlue, 9, "Arial Bold");
   CreateText(panelPrefix + "NextBuy", xLeft + 65, yOffset, "---", clrDodgerBlue, 9, "Arial Bold");
   CreateText(panelPrefix + "NextSellLabel", xRight, yOffset, "Next Sell:", clrTomato, 9, "Arial Bold");
   CreateText(panelPrefix + "NextSell", xRight + 65, yOffset, "---", clrTomato, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 8: Buy Lots (Net) | Sell Lots (Net)
   CreateText(panelPrefix + "BuyLotsLabel", xLeft, yOffset, "Buy Lots:", clrDodgerBlue, 9, "Arial Bold");
   CreateText(panelPrefix + "BuyLots", xLeft + 65, yOffset, "0.00", clrDodgerBlue, 9, "Arial Bold");
   CreateText(panelPrefix + "SellLotsLabel", xRight, yOffset, "Sell Lots:", clrTomato, 9, "Arial Bold");
   CreateText(panelPrefix + "SellLots", xRight + 65, yOffset, "0.00", clrTomato, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 9: Buy Grid Levels | Sell Grid Levels
   CreateText(panelPrefix + "BuyLabel", xLeft, yOffset, "Buy:", clrDodgerBlue, 9, "Arial Bold");
   CreateText(panelPrefix + "BuyGrid", xLeft + 35, yOffset, "0 lvls", clrDodgerBlue, 9, "Arial Bold");
   CreateText(panelPrefix + "SellLabel", xRight, yOffset, "Sell:", clrTomato, 9, "Arial Bold");
   CreateText(panelPrefix + "SellGrid", xRight + 35, yOffset, "0 lvls", clrTomato, 9, "Arial Bold");
   yOffset += lineHeight + 2;
   
   //--- Separator
   CreateRectLabel(panelPrefix + "Sep3", InpPanelX + 8, yOffset, panelWidth - 16, 1, clrDimGray, CORNER_LEFT_UPPER, false);
   yOffset += 7;
   
   //--- Row 10: Profit | Target TP
   CreateText(panelPrefix + "ProfitLabel", xLeft, yOffset, "Profit:", C'120,120,120', 9);
   CreateText(panelPrefix + "Profit", xLeft + 50, yOffset, "$0.00", clrLimeGreen, 10, "Arial Black");
   CreateText(panelPrefix + "TPLabel", xRight, yOffset, "Target:", C'120,120,120', 9);
   CreateText(panelPrefix + "GlobalTP", xRight + 50, yOffset, "$" + FormatWithCommas(InpGlobalTakeProfitUSD, 0), clrGold, 9, "Arial Bold");
   yOffset += lineHeight + 2;
   
   //--- Row 11: Drawdown | Max DD
   CreateText(panelPrefix + "DDLabel", xLeft, yOffset, "DD:", C'120,120,120', 9);
   CreateText(panelPrefix + "Drawdown", xLeft + 50, yOffset, "0.00%", clrWhite, 9, "Arial Bold");
   CreateText(panelPrefix + "MaxDDLabel", xRight, yOffset, "Max DD:", C'120,120,120', 9);
   CreateText(panelPrefix + "MaxDD", xRight + 50, yOffset, StringFormat("%.1f%%", InpMaxDrawdownPercent), clrOrangeRed, 9, "Arial Bold");
   yOffset += lineHeight + 6;
   
   //--- Separator
   CreateRectLabel(panelPrefix + "Sep4", InpPanelX + 8, yOffset, panelWidth - 16, 1, clrDimGray, CORNER_LEFT_UPPER, false);
   yOffset += 8;
   
   //--- Control Buttons (inside panel, 3 buttons in row)
   CreateButton(panelPrefix + "BtnCloseAll", InpPanelX + 12, yOffset, 103, 26, "CLOSE ALL", clrWhite, clrCrimson);
   CreateButton(panelPrefix + "BtnPause", InpPanelX + 121, yOffset, 103, 26, "PAUSE", clrWhite, C'255,152,0');
   CreateButton(panelPrefix + "BtnTakeProfit", InpPanelX + 230, yOffset, 98, 26, "TAKE TP", clrWhite, C'34,139,34');
   yOffset += 32;
   
   //--- TORAMA CAPITAL branding - bottom right, INSIDE panel, SOLID GOLD
   CreateText(panelPrefix + "Brand", InpPanelX + panelWidth - 130, yOffset - 6, "TORAMA CAPITAL", clrGold, 9, "Arial Black");
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update display panel                                               |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   //--- Calculate metrics
   double totalProfit = GetTotalProfit();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double buyLots = GetTotalLots(true);
   double sellLots = GetTotalLots(false);
   double netLots = buyLots - sellLots;
   
   int buyCount = GetGridLevelCount(true);
   int sellCount = GetGridLevelCount(false);
   
   //--- Get next pending order prices
   double nextBuy = GetNextPendingPrice(true);
   double nextSell = GetNextPendingPrice(false);
   
   //--- Calculate drawdown from equity high water mark
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   //--- Update peak equity if current is higher
   if(currentEquity > peakEquity)
      peakEquity = currentEquity;
   
   double drawdown = 0;
   if(peakEquity > 0)
      drawdown = ((peakEquity - currentEquity) / peakEquity) * 100.0;
   
   //--- Status
   string status = "Active";
   color statusColor = clrLimeGreen;
   
   if(isStoppedByDrawdown)
   {
      status = "STOPPED";
      statusColor = clrRed;
   }
   else if(isManuallyPaused)
   {
      status = "PAUSED";
      statusColor = clrOrange;
   }
   
   ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, status);
   ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, statusColor);
   
   //--- Direction
   string direction = InpTradeDirection == DIRECTION_BOTH ? "BOTH" : 
                     (InpTradeDirection == DIRECTION_BUY_ONLY ? "BUY" : "SELL");
   ObjectSetString(0, panelPrefix + "Direction", OBJPROP_TEXT, direction);
   
   //--- Equity (chalk white bold)
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT, "$" + FormatWithCommas(equity, 2));
   
   //--- Peak Equity (high water mark in gold)
   ObjectSetString(0, panelPrefix + "PeakEquity", OBJPROP_TEXT, "$" + FormatWithCommas(peakEquity, 2));
   
   //--- Reference Price (SACROSANCT)
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, FormatWithCommas(referencePrice, dgt));
   
   //--- Triggered levels count
   ObjectSetString(0, panelPrefix + "TriggeredCount", OBJPROP_TEXT, 
                  StringFormat("B:%d | S:%d", buyTriggeredCount, sellTriggeredCount));
   
   //--- Spread with color coding
   double spreadPoints = currentSpread / pt;
   color spreadColor = clrWhite;
   string spreadText = "";
   
   if(maxAllowedSpread > 0)
   {
      double maxSpreadPoints = maxAllowedSpread / pt;
      
      if(currentSpread > maxAllowedSpread)
         spreadColor = clrRed;
      else if(currentSpread > maxAllowedSpread * 0.8)
         spreadColor = clrOrange;
      else
         spreadColor = clrLimeGreen;
      
      spreadText = StringFormat("%.1f/%.0f", spreadPoints, maxSpreadPoints);
   }
   else
   {
      spreadColor = clrLimeGreen;
      spreadText = StringFormat("%.1f", spreadPoints);
   }
   
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_TEXT, spreadText);
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_COLOR, spreadColor);
   
   //--- Grid gap
   ObjectSetString(0, panelPrefix + "GridGap", OBJPROP_TEXT, 
                  StringFormat("%.2f%% (%s)", InpGridGapPercent, FormatWithCommas(gridGapPrice, dgt)));
   
   //--- Next Buy/Sell (from pending orders - or N/A for market mode)
   if(useMarketOrders)
   {
      ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, "N/A");
      ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, "N/A");
   }
   else
   {
      if(nextBuy > 0)
         ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, FormatWithCommas(nextBuy, dgt));
      else
         ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, "---");
      
      if(nextSell > 0)
         ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, FormatWithCommas(nextSell, dgt));
      else
         ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, "---");
   }
   
   //--- Buy/Sell Lots with Net in parentheses
   string buyLotsText = StringFormat("%.2f (%.2f)", buyLots, netLots);
   string sellLotsText = StringFormat("%.2f (%.2f)", sellLots, -netLots);
   ObjectSetString(0, panelPrefix + "BuyLots", OBJPROP_TEXT, buyLotsText);
   ObjectSetString(0, panelPrefix + "SellLots", OBJPROP_TEXT, sellLotsText);
   
   //--- Grid levels
   ObjectSetString(0, panelPrefix + "BuyGrid", OBJPROP_TEXT, 
                  StringFormat("%d lvls", buyCount));
   ObjectSetString(0, panelPrefix + "SellGrid", OBJPROP_TEXT, 
                  StringFormat("%d lvls", sellCount));
   
   //--- Profit
   color profitColor = totalProfit >= 0 ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "Profit", OBJPROP_TEXT, 
                  "$" + FormatWithCommas(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "Profit", OBJPROP_COLOR, profitColor);
   
   //--- Drawdown
   color ddColor = clrWhite;
   if(drawdown >= InpMaxDrawdownPercent * 0.8) 
      ddColor = clrOrange;
   if(drawdown >= InpMaxDrawdownPercent) 
      ddColor = clrRed;
      
   ObjectSetString(0, panelPrefix + "Drawdown", OBJPROP_TEXT, 
                  StringFormat("%.2f%%", drawdown));
   ObjectSetInteger(0, panelPrefix + "Drawdown", OBJPROP_COLOR, ddColor);
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Delete display panel                                               |
//+------------------------------------------------------------------+
void DeletePanel()
{
   ObjectsDeleteAll(0, panelPrefix);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Create rectangle label                                             |
//+------------------------------------------------------------------+
void CreateRectLabel(string name, int x, int y, int width, int height, color bgColor, ENUM_BASE_CORNER corner, bool back = true)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_BACK, back);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Create text object                                                 |
//+------------------------------------------------------------------+
void CreateText(string name, int x, int y, string text, color textColor, int fontSize = 8, string fontName = "Arial")
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, fontName);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Create button object                                               |
//+------------------------------------------------------------------+
void CreateButton(string name, int x, int y, int width, int height, string text, color textColor, color bgColor)
{
   if(ObjectFind(0, name) >= 0)
      ObjectDelete(0, name);
   
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrBlack);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Format number with thousand separators (commas)                  |
//+------------------------------------------------------------------+
string FormatWithCommas(double value, int decimals = 2)
{
   string result = "";
   string sign = "";
   
   // Handle negative numbers
   if(value < 0)
   {
      sign = "-";
      value = MathAbs(value);
   }
   
   // Split into integer and decimal parts
   long intPart = (long)MathFloor(value);
   double decPart = value - intPart;
   
   // Format integer part with commas
   string intStr = IntegerToString(intPart);
   int len = StringLen(intStr);
   
   for(int i = 0; i < len; i++)
   {
      if(i > 0 && (len - i) % 3 == 0)
         result += ",";
      result += StringSubstr(intStr, i, 1);
   }
   
   // Add decimal part if needed
   if(decimals > 0)
   {
      string decStr = DoubleToString(decPart, decimals);
      // Extract decimal part after the "0."
      int dotPos = StringFind(decStr, ".");
      if(dotPos >= 0)
         result += StringSubstr(decStr, dotPos);
   }
   
   return sign + result;
}

//+------------------------------------------------------------------+
//| Get uninitialization reason text                                   |
//+------------------------------------------------------------------+
string GetUninitReasonText(int reason)
{
   switch(reason)
   {
      case REASON_PROGRAM:     return "Program terminated";
      case REASON_REMOVE:      return "EA removed from chart";
      case REASON_RECOMPILE:   return "EA recompiled";
      case REASON_CHARTCHANGE: return "Chart symbol/period changed";
      case REASON_CHARTCLOSE:  return "Chart closed";
      case REASON_PARAMETERS:  return "Input parameters changed";
      case REASON_ACCOUNT:     return "Account changed";
      case REASON_TEMPLATE:    return "Template changed";
      case REASON_INITFAILED:  return "Initialization failed";
      case REASON_CLOSE:       return "Terminal closed";
      default:                 return "Unknown reason";
   }
}
//+------------------------------------------------------------------+
