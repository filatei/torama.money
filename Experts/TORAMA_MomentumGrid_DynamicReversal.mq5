//+------------------------------------------------------------------+
//|                       TORAMA_MomentumGrid_DynamicReversal.mq5    |
//|                                          TORAMA CAPITAL           |
//|                                   Algorithmic Trading Solutions   |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://toramacapital.com"
#property version   "4.00"
#property description "Dynamic Reversal Grid EA - Watermark Based Direction Switching"
#property description "Buy up, sell down, reverse at watermarks"
#property description "Global TP, BUY & SELL can coexist at same level"

//--- Include files
#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== GRID SETTINGS ==="
input double InpGridGapPercent = 0.5;           // Grid Gap (% of Price)
input double InpInitialLotSize = 0.01;          // Initial Lot Size
input double InpLotMultiplier = 1.0;            // Lot Multiplier (1.0 = Fixed)
input int    InpMaxGridLevels = 30;             // Max Grid Levels (0 = Unlimited)
input double InpMaxSpreadPoints = 0;            // Max Spread (Points, 0 = No Limit)

input group "=== REVERSAL SETTINGS ==="
input int    InpReversalLevels = 5;             // Levels Before Reversal (from watermark)

input group "=== GLOBAL PROFIT & RISK ==="
input double InpGlobalTakeProfitUSD = 100.0;    // Global Take Profit (USD)
input double InpMaxDrawdownPercent = 10.0;      // Max Drawdown (%)

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
double accountStartBalance = 0;
double peakBalance = 0;
double peakEquity = 0;
bool isStoppedByDrawdown = false;
bool isManuallyPaused = false;
long magicNumber = 0;
double effectiveInitialLotSize = 0;

//--- Spread tracking
double maxAllowedSpread = 0;
double currentSpread = 0;

//--- Grid tracking - DYNAMIC REVERSAL SYSTEM
double referencePrice = 0;
bool gridInitialized = false;

//--- Watermark tracking - CRITICAL FOR REVERSAL LOGIC
int highBuyWatermark = 0;      // Highest level where BUY was placed
int lowSellWatermark = 0;      // Lowest level where SELL was placed (negative number)
bool buyWatermarkActive = false;   // Has any buy been placed
bool sellWatermarkActive = false;  // Has any sell been placed

//--- Market order mode (for symbols that don't support pending orders)
bool useMarketOrders = false;

//--- Panel objects
string panelPrefix = "TORAMA_Panel_";
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
      maxAllowedSpread = 0;
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
   
   //--- Validate inputs
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
   
   if(InpReversalLevels < 1)
   {
      Print("ERROR: Reversal levels must be at least 1!");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   //--- Setup trade class
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   if(trade.ResultRetcode() == TRADE_RETCODE_INVALID_FILL)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   //--- Initialize account tracking
   accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   peakBalance = accountStartBalance;
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   isStoppedByDrawdown = false;
   
   //--- Calculate initial grid gap
   CalculateGridGap();
   
   //--- Auto-detect market order mode
   DetectMarketOrderMode();
   
   //--- Initialize grid
   InitializeGrid();
   
   //--- Create display panel
   CreatePanel();
   
   //--- Enable chart events
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);
   
   PrintFormat("TORAMA Dynamic Reversal Grid EA initialized on %s", sym);
   PrintFormat("Magic Number: %I64d", magicNumber);
   PrintFormat("Effective Lot Size: %.2f", effectiveInitialLotSize);
   PrintFormat("Grid Gap: %.5f (%.2f%%)", gridGapPrice, InpGridGapPercent);
   PrintFormat("Reversal: After %d levels from watermark", InpReversalLevels);
   PrintFormat("Global TP: $%.2f, Max DD: %.1f%%", InpGlobalTakeProfitUSD, InpMaxDrawdownPercent);
   PrintFormat("Reference Price: %.*f", dgt, referencePrice);
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeletePanel();
   Comment("");
   PrintFormat("TORAMA Dynamic Reversal Grid EA stopped. Reason: %s", GetUninitReasonText(reason));
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
   
   //--- Update watermarks based on existing positions
   UpdateWatermarks();
   
   //--- CRITICAL: Check if EA is permanently stopped by drawdown
   if(isStoppedByDrawdown)
   {
      UpdatePanel();
      return;
   }
   
   //--- Check for global take profit
   if(CheckGlobalTakeProfit())
   {
      double profit = GetTotalProfit();
      PrintFormat("========================================");
      PrintFormat("GLOBAL TAKE PROFIT REACHED: $%.2f", profit);
      PrintFormat("Closing all positions and resetting grid");
      PrintFormat("========================================");
      
      CloseAllPositions();
      DeleteAllPendingOrders();
      ResetGrid();
      UpdatePanel();
      return;
   }
   
   //--- Check if manually paused
   if(isManuallyPaused)
   {
      UpdatePanel();
      return;
   }
   
   //--- Check for MAX DRAWDOWN
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
   
   //--- Maintain dynamic reversal grid
   MaintainDynamicGrid();
   
   //--- Update display
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| Detect market order mode for Deriv synthetics                    |
//+------------------------------------------------------------------+
void DetectMarketOrderMode()
{
   string symbolName = sym;
   StringToUpper(symbolName);
   
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
   
   double minGap = stopLevel * 2;
   if(minGap > 0 && gridGapPrice < minGap)
      gridGapPrice = minGap;
   
   gridGapPrice = MathRound(gridGapPrice / tickSize) * tickSize;
}

//+------------------------------------------------------------------+
//| Initialize grid system                                            |
//+------------------------------------------------------------------+
void InitializeGrid()
{
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   referencePrice = NormalizeDouble((ask + bid) / 2.0, dgt);
   referencePrice = MathRound(referencePrice / tickSize) * tickSize;
   
   highBuyWatermark = 0;
   lowSellWatermark = 0;
   buyWatermarkActive = false;
   sellWatermarkActive = false;
   
   gridInitialized = true;
   
   PrintFormat("Grid Initialized - Reference: %.*f, Gap: %.*f", dgt, referencePrice, dgt, gridGapPrice);
}

//+------------------------------------------------------------------+
//| Reset grid system                                                 |
//+------------------------------------------------------------------+
void ResetGrid()
{
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   referencePrice = NormalizeDouble((ask + bid) / 2.0, dgt);
   referencePrice = MathRound(referencePrice / tickSize) * tickSize;
   
   highBuyWatermark = 0;
   lowSellWatermark = 0;
   buyWatermarkActive = false;
   sellWatermarkActive = false;
   
   peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   gridInitialized = true;
   
   PrintFormat("Grid RESET - New Reference: %.*f", dgt, referencePrice);
}

//+------------------------------------------------------------------+
//| Update watermarks based on existing positions                     |
//+------------------------------------------------------------------+
void UpdateWatermarks()
{
   int totalPositions = PositionsTotal();
   
   //--- Reset watermark tracking
   int tempHighBuy = -999999;
   int tempLowSell = 999999;
   bool foundBuy = false;
   bool foundSell = false;
   
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      //--- Calculate level
      double distanceFromRef = entryPrice - referencePrice;
      int level = (int)MathRound(distanceFromRef / gridGapPrice);
      
      if(posType == POSITION_TYPE_BUY)
      {
         foundBuy = true;
         if(level > tempHighBuy)
            tempHighBuy = level;
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         foundSell = true;
         if(level < tempLowSell)
            tempLowSell = level;
      }
   }
   
   //--- Update watermarks
   if(foundBuy)
   {
      highBuyWatermark = tempHighBuy;
      buyWatermarkActive = true;
   }
   
   if(foundSell)
   {
      lowSellWatermark = tempLowSell;
      sellWatermarkActive = true;
   }
}

//+------------------------------------------------------------------+
//| Maintain dynamic reversal grid - CORE LOGIC                      |
//+------------------------------------------------------------------+
void MaintainDynamicGrid()
{
   if(!gridInitialized) return;
   
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   
   //--- Calculate current level based on price
   int currentLevel = (int)MathRound((ask - referencePrice) / gridGapPrice);
   
   //--- DECISION TREE: Determine what to trade
   
   //--- Case 1: No positions yet - neutral start
   if(!buyWatermarkActive && !sellWatermarkActive)
   {
      //--- Price above reference: Start buying up
      if(currentLevel > 0)
      {
         for(int level = 1; level <= currentLevel + 10; level++)
         {
            if(InpMaxGridLevels > 0 && level > InpMaxGridLevels) break;
            
            if(!PositionExistsAtLevel(level, true) && !PendingOrderExists(level, true))
            {
               double orderPrice = referencePrice + (level * gridGapPrice);
               PlaceBuyOrder(level, orderPrice);
            }
         }
      }
      //--- Price below reference: Start selling down
      else if(currentLevel < 0)
      {
         int levelsBelow = MathAbs(currentLevel);
         for(int level = -1; level >= -(levelsBelow + 10); level--)
         {
            if(InpMaxGridLevels > 0 && MathAbs(level) > InpMaxGridLevels) break;
            
            if(!PositionExistsAtLevel(level, false) && !PendingOrderExists(level, false))
            {
               double orderPrice = referencePrice + (level * gridGapPrice);
               PlaceSellOrder(level, orderPrice);
            }
         }
      }
      
      return;
   }
   
   //--- Case 2: Buy watermark active - check for reversal to selling
   if(buyWatermarkActive)
   {
      int levelsFromHighBuy = highBuyWatermark - currentLevel;
      
      //--- If fallen InpReversalLevels below high buy watermark: START SELLING
      if(levelsFromHighBuy >= InpReversalLevels)
      {
         int sellStartLevel = highBuyWatermark - InpReversalLevels;
         
         //--- Sell from reversal point downward
         for(int level = sellStartLevel; level >= currentLevel - 10; level--)
         {
            if(InpMaxGridLevels > 0 && MathAbs(level) > InpMaxGridLevels) break;
            
            //--- Check if SELL already exists (skip if yes)
            if(!PositionExistsAtLevel(level, false) && !PendingOrderExists(level, false))
            {
               double orderPrice = referencePrice + (level * gridGapPrice);
               PlaceSellOrder(level, orderPrice);
            }
         }
      }
      //--- Still above reversal threshold: Continue buying up
      else if(currentLevel > highBuyWatermark)
      {
         for(int level = highBuyWatermark + 1; level <= currentLevel + 10; level++)
         {
            if(InpMaxGridLevels > 0 && level > InpMaxGridLevels) break;
            
            if(!PositionExistsAtLevel(level, true) && !PendingOrderExists(level, true))
            {
               double orderPrice = referencePrice + (level * gridGapPrice);
               PlaceBuyOrder(level, orderPrice);
            }
         }
      }
   }
   
   //--- Case 3: Sell watermark active - check for reversal to buying
   if(sellWatermarkActive)
   {
      int levelsFromLowSell = currentLevel - lowSellWatermark;
      
      //--- If risen InpReversalLevels above low sell watermark: START BUYING
      if(levelsFromLowSell >= InpReversalLevels)
      {
         int buyStartLevel = lowSellWatermark + InpReversalLevels;
         
         //--- Buy from reversal point upward
         for(int level = buyStartLevel; level <= currentLevel + 10; level++)
         {
            if(InpMaxGridLevels > 0 && level > InpMaxGridLevels) break;
            
            //--- Check if BUY already exists (skip if yes)
            if(!PositionExistsAtLevel(level, true) && !PendingOrderExists(level, true))
            {
               double orderPrice = referencePrice + (level * gridGapPrice);
               PlaceBuyOrder(level, orderPrice);
            }
         }
      }
      //--- Still below reversal threshold: Continue selling down
      else if(currentLevel < lowSellWatermark)
      {
         for(int level = lowSellWatermark - 1; level >= currentLevel - 10; level--)
         {
            if(InpMaxGridLevels > 0 && MathAbs(level) > InpMaxGridLevels) break;
            
            if(!PositionExistsAtLevel(level, false) && !PendingOrderExists(level, false))
            {
               double orderPrice = referencePrice + (level * gridGapPrice);
               PlaceSellOrder(level, orderPrice);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if position exists at level for specific direction         |
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
      
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      double distanceFromRef = entryPrice - referencePrice;
      int posLevel = (int)MathRound(distanceFromRef / gridGapPrice);
      
      if(posLevel == level)
      {
         if((isBuy && posType == POSITION_TYPE_BUY) || (!isBuy && posType == POSITION_TYPE_SELL))
            return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Check if pending order exists at level                           |
//+------------------------------------------------------------------+
bool PendingOrderExists(int level, bool isBuy)
{
   if(useMarketOrders) return false; // No pending orders in market mode
   
   int totalOrders = OrdersTotal();
   
   for(int i = 0; i < totalOrders; i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0) continue;
      
      if(OrderGetString(ORDER_SYMBOL) != sym) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
      
      double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      
      double distanceFromRef = orderPrice - referencePrice;
      int orderLevel = (int)MathRound(distanceFromRef / gridGapPrice);
      
      if(orderLevel == level)
      {
         if((isBuy && orderType == ORDER_TYPE_BUY_STOP) || (!isBuy && orderType == ORDER_TYPE_SELL_STOP))
            return true;
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Place BUY order (pending or market)                              |
//+------------------------------------------------------------------+
void PlaceBuyOrder(int level, double price)
{
   double lotSize = CalculateLotSize(MathAbs(level));
   lotSize = NormalizeLot(lotSize);
   
   if(lotSize < minLot || lotSize > maxLot) return;
   
   price = NormalizeDouble(price, dgt);
   
   if(useMarketOrders)
   {
      //--- Market order
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      if(trade.Buy(lotSize, sym, ask, 0, 0, StringFormat("DynGrid_L%d", level)))
      {
         PrintFormat("MARKET BUY: Level=%d, Price=%.*f, Lot=%.2f", level, dgt, ask, lotSize);
      }
   }
   else
   {
      //--- Pending order
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      if(price <= ask + stopLevel)
         price = ask + stopLevel + gridGapPrice;
      
      price = NormalizeDouble(price, dgt);
      
      if(trade.BuyStop(lotSize, price, sym, 0, 0, ORDER_TIME_GTC, 0, StringFormat("DynGrid_L%d", level)))
      {
         PrintFormat("BUY STOP: Level=%d, Price=%.*f, Lot=%.2f", level, dgt, price, lotSize);
      }
   }
}

//+------------------------------------------------------------------+
//| Place SELL order (pending or market)                             |
//+------------------------------------------------------------------+
void PlaceSellOrder(int level, double price)
{
   double lotSize = CalculateLotSize(MathAbs(level));
   lotSize = NormalizeLot(lotSize);
   
   if(lotSize < minLot || lotSize > maxLot) return;
   
   price = NormalizeDouble(price, dgt);
   
   if(useMarketOrders)
   {
      //--- Market order
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      if(trade.Sell(lotSize, sym, bid, 0, 0, StringFormat("DynGrid_L%d", level)))
      {
         PrintFormat("MARKET SELL: Level=%d, Price=%.*f, Lot=%.2f", level, dgt, bid, lotSize);
      }
   }
   else
   {
      //--- Pending order
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      if(price >= bid - stopLevel)
         price = bid - stopLevel - gridGapPrice;
      
      price = NormalizeDouble(price, dgt);
      
      if(trade.SellStop(lotSize, price, sym, 0, 0, ORDER_TIME_GTC, 0, StringFormat("DynGrid_L%d", level)))
      {
         PrintFormat("SELL STOP: Level=%d, Price=%.*f, Lot=%.2f", level, dgt, price, lotSize);
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on grid level                           |
//+------------------------------------------------------------------+
double CalculateLotSize(int gridLevel)
{
   double lotSize = effectiveInitialLotSize;
   
   if(InpLotMultiplier != 1.0 && gridLevel > 0)
      lotSize = effectiveInitialLotSize * MathPow(InpLotMultiplier, gridLevel);
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Normalize lot size                                                |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Check global take profit                                         |
//+------------------------------------------------------------------+
bool CheckGlobalTakeProfit()
{
   double totalProfit = GetTotalProfit();
   return (totalProfit >= InpGlobalTakeProfitUSD);
}

//+------------------------------------------------------------------+
//| Get total profit from all positions                              |
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
//| Check MAX drawdown from equity high water mark                   |
//+------------------------------------------------------------------+
bool CheckMaxDrawdown()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(currentEquity > peakEquity)
      peakEquity = currentEquity;
   
   double drawdown = 0;
   if(peakEquity > 0)
      drawdown = ((peakEquity - currentEquity) / peakEquity) * 100.0;
   
   return (drawdown >= InpMaxDrawdownPercent);
}

//+------------------------------------------------------------------+
//| Get total number of positions                                    |
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
//| Get total lots by type                                           |
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
//| Get grid level counts                                            |
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
//| Close all positions                                              |
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
         Sleep(100);
      }
   }
}

//+------------------------------------------------------------------+
//| Delete all pending orders                                        |
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
   }
}

//+------------------------------------------------------------------+
//| ChartEvent function - Handle button clicks                       |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(isStoppedByDrawdown) return; // No buttons when stopped
      
      //--- Close All button
      if(sparam == panelPrefix + "BtnCloseAll")
      {
         if(!buttonPressed)
         {
            buttonPressed = true;
            ObjectSetInteger(0, panelPrefix + "BtnCloseAll", OBJPROP_STATE, false);
            
            Print("Close All - Closing all positions, deleting orders, resetting grid");
            CloseAllPositions();
            DeleteAllPendingOrders();
            ResetGrid();
            
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
               Print("Trading PAUSED");
               ObjectSetString(0, panelPrefix + "BtnPause", OBJPROP_TEXT, "RESUME");
               ObjectSetInteger(0, panelPrefix + "BtnPause", OBJPROP_BGCOLOR, clrOrangeRed);
            }
            else
            {
               Print("Trading RESUMED");
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
            PrintFormat("Take Profit Now - Closing all (Profit: $%.2f)", totalProfit);
            CloseAllPositions();
            DeleteAllPendingOrders();
            ResetGrid();
            
            Sleep(100);
            buttonPressed = false;
            UpdatePanel();
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Create professional display panel                                |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int panelWidth = 340;
   int panelHeight = 310;
   int lineHeight = 19;
   int colWidth = 160;
   
   int xLeft = InpPanelX + 12;
   int xRight = InpPanelX + colWidth + 10;
   int yOffset = InpPanelY;
   
   //--- Background
   CreateRectLabel(panelPrefix + "BG", InpPanelX, yOffset, panelWidth, panelHeight, InpPanelColor, CORNER_LEFT_UPPER, false);
   yOffset += 10;
   
   //--- Header
   CreateText(panelPrefix + "EAName", xLeft, yOffset, "DYNAMIC REVERSAL GRID", clrGold, 11, "Arial Black");
   yOffset += 24;
   
   CreateRectLabel(panelPrefix + "Sep1", InpPanelX + 8, yOffset, panelWidth - 16, 1, clrDimGray, CORNER_LEFT_UPPER, false);
   yOffset += 7;
   
   //--- Row 1: Status | Mode
   CreateText(panelPrefix + "StatusLabel", xLeft, yOffset, "Status:", C'120,120,120', 9);
   CreateText(panelPrefix + "Status", xLeft + 52, yOffset, "Active", clrLimeGreen, 9, "Arial Bold");
   CreateText(panelPrefix + "ModeLabel", xRight, yOffset, "Mode:", C'120,120,120', 9);
   string modeText = useMarketOrders ? "MARKET" : "PENDING";
   color modeColor = useMarketOrders ? clrYellow : clrLimeGreen;
   CreateText(panelPrefix + "Mode", xRight + 45, yOffset, modeText, modeColor, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 2: Symbol | Reversal
   CreateText(panelPrefix + "SymLabel", xLeft, yOffset, "Symbol:", C'120,120,120', 9);
   CreateText(panelPrefix + "Symbol", xLeft + 52, yOffset, sym, clrWhite, 9, "Arial Bold");
   CreateText(panelPrefix + "RevLabel", xRight, yOffset, "Reversal:", C'120,120,120', 9);
   CreateText(panelPrefix + "Reversal", xRight + 60, yOffset, IntegerToString(InpReversalLevels) + " lvls", clrCyan, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 3: Lot | Spread
   CreateText(panelPrefix + "LotLabel", xLeft, yOffset, "Lot:", C'120,120,120', 9);
   CreateText(panelPrefix + "LotSize", xLeft + 52, yOffset, StringFormat("%.2f", effectiveInitialLotSize), clrWhite, 9, "Arial Bold");
   CreateText(panelPrefix + "SpreadLabel", xRight, yOffset, "Spread:", C'120,120,120', 9);
   CreateText(panelPrefix + "Spread", xRight + 50, yOffset, "0.0", clrWhite, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 4: Equity | Peak
   CreateText(panelPrefix + "EquityLabel", xLeft, yOffset, "Equity:", C'120,120,120', 9);
   CreateText(panelPrefix + "Equity", xLeft + 52, yOffset, "$0.00", C'240,248,255', 9, "Arial Black");
   CreateText(panelPrefix + "PeakLabel", xRight, yOffset, "Peak:", C'120,120,120', 9);
   CreateText(panelPrefix + "PeakEquity", xRight + 40, yOffset, "$0.00", clrGold, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 5: Grid Gap
   CreateText(panelPrefix + "GapLabel", xLeft, yOffset, "Grid Gap:", C'120,120,120', 9);
   CreateText(panelPrefix + "GridGap", xLeft + 65, yOffset, "0.00%", clrWhite, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 6: Watermarks
   CreateText(panelPrefix + "WMLabel", xLeft, yOffset, "Watermarks:", clrOrange, 9, "Arial Bold");
   CreateText(panelPrefix + "Watermarks", xLeft + 82, yOffset, "B:-- | S:--", clrOrange, 9, "Arial Bold");
   yOffset += lineHeight + 2;
   
   CreateRectLabel(panelPrefix + "Sep2", InpPanelX + 8, yOffset, panelWidth - 16, 1, clrDimGray, CORNER_LEFT_UPPER, false);
   yOffset += 7;
   
   //--- Row 7: Buy Lots | Sell Lots
   CreateText(panelPrefix + "BuyLotsLabel", xLeft, yOffset, "Buy Lots:", clrDodgerBlue, 9, "Arial Bold");
   CreateText(panelPrefix + "BuyLots", xLeft + 65, yOffset, "0.00", clrDodgerBlue, 9, "Arial Bold");
   CreateText(panelPrefix + "SellLotsLabel", xRight, yOffset, "Sell Lots:", clrTomato, 9, "Arial Bold");
   CreateText(panelPrefix + "SellLots", xRight + 65, yOffset, "0.00", clrTomato, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Row 8: Buy Grid | Sell Grid
   CreateText(panelPrefix + "BuyLabel", xLeft, yOffset, "Buy:", clrDodgerBlue, 9, "Arial Bold");
   CreateText(panelPrefix + "BuyGrid", xLeft + 35, yOffset, "0 lvls", clrDodgerBlue, 9, "Arial Bold");
   CreateText(panelPrefix + "SellLabel", xRight, yOffset, "Sell:", clrTomato, 9, "Arial Bold");
   CreateText(panelPrefix + "SellGrid", xRight + 35, yOffset, "0 lvls", clrTomato, 9, "Arial Bold");
   yOffset += lineHeight + 2;
   
   CreateRectLabel(panelPrefix + "Sep3", InpPanelX + 8, yOffset, panelWidth - 16, 1, clrDimGray, CORNER_LEFT_UPPER, false);
   yOffset += 7;
   
   //--- Row 9: Profit | Target
   CreateText(panelPrefix + "ProfitLabel", xLeft, yOffset, "Profit:", C'120,120,120', 9);
   CreateText(panelPrefix + "Profit", xLeft + 50, yOffset, "$0.00", clrLimeGreen, 10, "Arial Black");
   CreateText(panelPrefix + "TPLabel", xRight, yOffset, "Target:", C'120,120,120', 9);
   CreateText(panelPrefix + "GlobalTP", xRight + 50, yOffset, "$" + DoubleToString(InpGlobalTakeProfitUSD, 0), clrGold, 9, "Arial Bold");
   yOffset += lineHeight + 2;
   
   //--- Row 10: Drawdown | Max DD
   CreateText(panelPrefix + "DDLabel", xLeft, yOffset, "DD:", C'120,120,120', 9);
   CreateText(panelPrefix + "Drawdown", xLeft + 50, yOffset, "0.00%", clrWhite, 9, "Arial Bold");
   CreateText(panelPrefix + "MaxDDLabel", xRight, yOffset, "Max DD:", C'120,120,120', 9);
   CreateText(panelPrefix + "MaxDD", xRight + 50, yOffset, StringFormat("%.1f%%", InpMaxDrawdownPercent), clrOrangeRed, 9, "Arial Bold");
   yOffset += lineHeight + 6;
   
   CreateRectLabel(panelPrefix + "Sep4", InpPanelX + 8, yOffset, panelWidth - 16, 1, clrDimGray, CORNER_LEFT_UPPER, false);
   yOffset += 8;
   
   //--- Control Buttons
   CreateButton(panelPrefix + "BtnCloseAll", InpPanelX + 12, yOffset, 103, 26, "CLOSE ALL", clrWhite, clrCrimson);
   CreateButton(panelPrefix + "BtnPause", InpPanelX + 121, yOffset, 103, 26, "PAUSE", clrWhite, C'255,152,0');
   CreateButton(panelPrefix + "BtnTakeProfit", InpPanelX + 230, yOffset, 98, 26, "TAKE TP", clrWhite, C'34,139,34');
   yOffset += 32;
   
   //--- TORAMA CAPITAL branding
   CreateText(panelPrefix + "Brand", InpPanelX + panelWidth - 130, yOffset - 6, "TORAMA CAPITAL", clrGold, 9, "Arial Black");
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update display panel                                             |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   double totalProfit = GetTotalProfit();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double buyLots = GetTotalLots(true);
   double sellLots = GetTotalLots(false);
   
   int buyCount = GetGridLevelCount(true);
   int sellCount = GetGridLevelCount(false);
   
   //--- Update peak equity
   if(equity > peakEquity)
      peakEquity = equity;
   
   double drawdown = 0;
   if(peakEquity > 0)
      drawdown = ((peakEquity - equity) / peakEquity) * 100.0;
   
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
   
   //--- Equity & Peak
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT, "$" + DoubleToString(equity, 2));
   ObjectSetString(0, panelPrefix + "PeakEquity", OBJPROP_TEXT, "$" + DoubleToString(peakEquity, 2));
   
   //--- Spread
   double spreadPoints = currentSpread / pt;
   color spreadColor = clrLimeGreen;
   string spreadText = DoubleToString(spreadPoints, 1);
   
   if(maxAllowedSpread > 0)
   {
      double maxSpreadPoints = maxAllowedSpread / pt;
      if(currentSpread > maxAllowedSpread)
         spreadColor = clrRed;
      else if(currentSpread > maxAllowedSpread * 0.8)
         spreadColor = clrOrange;
      
      spreadText = DoubleToString(spreadPoints, 1) + "/" + DoubleToString(maxSpreadPoints, 0);
   }
   
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_TEXT, spreadText);
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_COLOR, spreadColor);
   
   //--- Grid gap
   ObjectSetString(0, panelPrefix + "GridGap", OBJPROP_TEXT, 
                  StringFormat("%.2f%% (%.5f)", InpGridGapPercent, gridGapPrice));
   
   //--- Watermarks
   string wmText = "B:";
   if(buyWatermarkActive)
      wmText += IntegerToString(highBuyWatermark);
   else
      wmText += "--";
   
   wmText += " | S:";
   if(sellWatermarkActive)
      wmText += IntegerToString(lowSellWatermark);
   else
      wmText += "--";
   
   ObjectSetString(0, panelPrefix + "Watermarks", OBJPROP_TEXT, wmText);
   
   //--- Buy/Sell Lots
   ObjectSetString(0, panelPrefix + "BuyLots", OBJPROP_TEXT, DoubleToString(buyLots, 2));
   ObjectSetString(0, panelPrefix + "SellLots", OBJPROP_TEXT, DoubleToString(sellLots, 2));
   
   //--- Grid levels
   ObjectSetString(0, panelPrefix + "BuyGrid", OBJPROP_TEXT, IntegerToString(buyCount) + " lvls");
   ObjectSetString(0, panelPrefix + "SellGrid", OBJPROP_TEXT, IntegerToString(sellCount) + " lvls");
   
   //--- Profit
   color profitColor = totalProfit >= 0 ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "Profit", OBJPROP_TEXT, "$" + DoubleToString(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "Profit", OBJPROP_COLOR, profitColor);
   
   //--- Drawdown
   color ddColor = clrWhite;
   if(drawdown >= InpMaxDrawdownPercent * 0.8) 
      ddColor = clrOrange;
   if(drawdown >= InpMaxDrawdownPercent) 
      ddColor = clrRed;
      
   ObjectSetString(0, panelPrefix + "Drawdown", OBJPROP_TEXT, DoubleToString(drawdown, 2) + "%");
   ObjectSetInteger(0, panelPrefix + "Drawdown", OBJPROP_COLOR, ddColor);
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Delete display panel                                              |
//+------------------------------------------------------------------+
void DeletePanel()
{
   ObjectsDeleteAll(0, panelPrefix);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Create rectangle label                                            |
//+------------------------------------------------------------------+
void CreateRectLabel(string name, int x, int y, int width, int height, color bgColor, int corner, bool back = true)
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
//| Create text object                                                |
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
//| Create button object                                              |
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
//| Get uninitialization reason text                                  |
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
