//+------------------------------------------------------------------+
//|                                    TORAMA_MomentumGrid_Global.mq5 |
//|                                          TORAMA CAPITAL           |
//|                                   Algorithmic Trading Solutions   |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://toramacapital.com"
#property version   "1.00"
#property description "Momentum Grid EA - Buy Up, Sell Down"
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
input int    InpMaxGridLevels = 100;            // Max Grid Levels (0 = Unlimited)
input double InpMaxSpreadMultiplier = 3.0;      // Max Spread Multiplier (x Historic)

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
long magicNumber = 0;
double effectiveInitialLotSize = 0;

//--- Spread tracking
double historicSpread = 0;
double maxAllowedSpread = 0;
double currentSpread = 0;

//--- Grid tracking
double lastBuyPrice = 0;
double lastSellPrice = 0;
int buyGridCount = 0;
int sellGridCount = 0;

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
   
   //--- Calculate historic spread
   CalculateHistoricSpread();
   
   //--- Set max allowed spread based on historic spread
   maxAllowedSpread = historicSpread * InpMaxSpreadMultiplier;
   
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
   
   if(InpMaxSpreadMultiplier <= 0)
   {
      Print("ERROR: Max spread multiplier must be positive!");
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
   
   //--- Calculate initial grid gap
   CalculateGridGap();
   
   //--- Initialize grid levels
   InitializeGridLevels();
   
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
   PrintFormat("Historic Spread: %.1f points, Max Allowed: %.1f points (%.1fx multiplier)", 
               historicSpread/pt, maxAllowedSpread/pt, InpMaxSpreadMultiplier);
   PrintFormat("Grid Gap: %.5f (%.2f%%), Global TP: $%.2f, Max DD: %.1f%%", 
               gridGapPrice, InpGridGapPercent, InpGlobalTakeProfitUSD, InpMaxDrawdownPercent);
   
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
   
   //--- Check for global take profit
   if(CheckGlobalTakeProfit())
   {
      CloseAllPositions();
      ResetGrid();
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
   
   //--- Check for drawdown pause
   if(CheckDrawdown())
   {
      if(!isDrawdownPaused)
      {
         isDrawdownPaused = true;
         lastDrawdownPauseTime = TimeCurrent();
         PrintFormat("Max drawdown reached: %.2f%% - Pausing for %d minutes", InpMaxDrawdownPercent, InpDrawdownPauseMinutes);
      }
      
      //--- Check if pause duration has elapsed
      if(TimeCurrent() - lastDrawdownPauseTime < InpDrawdownPauseMinutes * 60)
      {
         UpdatePanel();
         return; // Still in pause period
      }
      else
      {
         isDrawdownPaused = false;
         PrintFormat("Drawdown pause ended - Resuming trading");
      }
   }
   else
   {
      isDrawdownPaused = false; // Reset if drawdown is back within limits
   }
   
   //--- Get current price
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   
   if(ask <= 0 || bid <= 0)
   {
      Print("ERROR: Invalid prices received");
      return;
   }
   
   //--- Check for buy grid opportunities (price moving up)
   if(InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_BUY_ONLY)
   {
      if(lastBuyPrice == 0 || ask >= lastBuyPrice + gridGapPrice)
      {
         if(InpMaxGridLevels == 0 || buyGridCount < InpMaxGridLevels)
         {
            if(OpenBuyPosition(ask))
            {
               lastBuyPrice = ask;
               buyGridCount++;
            }
         }
      }
   }
   
   //--- Check for sell grid opportunities (price moving down)
   if(InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_SELL_ONLY)
   {
      if(lastSellPrice == 0 || bid <= lastSellPrice - gridGapPrice)
      {
         if(InpMaxGridLevels == 0 || sellGridCount < InpMaxGridLevels)
         {
            if(OpenSellPosition(bid))
            {
               lastSellPrice = bid;
               sellGridCount++;
            }
         }
      }
   }
   
   //--- Update display
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| ChartEvent function - Handle button clicks                        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      //--- Close All button
      if(sparam == panelPrefix + "BtnCloseAll")
      {
         if(!buttonPressed)
         {
            buttonPressed = true;
            ObjectSetInteger(0, panelPrefix + "BtnCloseAll", OBJPROP_STATE, false);
            
            Print("Close All button pressed - Closing all positions and resetting grid");
            CloseAllPositions();
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
            ResetGrid();
            
            Sleep(100);
            buttonPressed = false;
            UpdatePanel();
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate historic spread from chart data                         |
//+------------------------------------------------------------------+
void CalculateHistoricSpread()
{
   int spreadArray[];
   int copied = CopySpread(sym, PERIOD_CURRENT, 0, 1000, spreadArray);
   
   if(copied > 0)
   {
      //--- Calculate average spread from historic data
      long totalSpread = 0;
      for(int i = 0; i < copied; i++)
      {
         totalSpread += spreadArray[i];
      }
      
      double avgSpreadPoints = (double)totalSpread / copied;
      historicSpread = avgSpreadPoints * pt;
      
      PrintFormat("Historic spread calculated from %d bars: %.1f points", copied, avgSpreadPoints);
   }
   else
   {
      //--- Fallback to current spread if historic data unavailable
      historicSpread = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
      PrintFormat("WARNING: Could not load historic spread data, using current spread: %.1f points", historicSpread/pt);
   }
   
   //--- Ensure minimum spread value
   if(historicSpread <= 0)
   {
      historicSpread = 10 * pt; // Default 10 points minimum
      PrintFormat("WARNING: Invalid historic spread, using default: %.1f points", historicSpread/pt);
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
   if(gridGapPrice < minGap)
   {
      gridGapPrice = minGap;
   }
   
   //--- Align to tick size
   gridGapPrice = MathRound(gridGapPrice / tickSize) * tickSize;
}

//+------------------------------------------------------------------+
//| Initialize grid levels from existing positions                    |
//+------------------------------------------------------------------+
void InitializeGridLevels()
{
   int totalPositions = PositionsTotal();
   
   lastBuyPrice = 0;
   lastSellPrice = 0;
   buyGridCount = 0;
   sellGridCount = 0;
   
   for(int i = 0; i < totalPositions; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      if(posType == POSITION_TYPE_BUY)
      {
         if(lastBuyPrice == 0 || openPrice > lastBuyPrice)
            lastBuyPrice = openPrice;
         buyGridCount++;
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         if(lastSellPrice == 0 || openPrice < lastSellPrice)
            lastSellPrice = openPrice;
         sellGridCount++;
      }
   }
   
   if(buyGridCount > 0 || sellGridCount > 0)
   {
      PrintFormat("Grid initialized: %d Buy positions, %d Sell positions", buyGridCount, sellGridCount);
   }
}

//+------------------------------------------------------------------+
//| Open buy position                                                  |
//+------------------------------------------------------------------+
bool OpenBuyPosition(double price)
{
   //--- Calculate lot size
   double lotSize = CalculateLotSize(buyGridCount);
   
   //--- Validate lot size
   lotSize = NormalizeLot(lotSize);
   if(lotSize < minLot || lotSize > maxLot)
   {
      PrintFormat("ERROR: Invalid lot size %.2f (min: %.2f, max: %.2f)", lotSize, minLot, maxLot);
      return false;
   }
   
   //--- Check spread against max allowed (based on historic spread)
   if(currentSpread > maxAllowedSpread)
   {
      PrintFormat("WARNING: Spread %.1f points exceeds max allowed %.1f points (%.1fx historic) - Skipping trade", 
                  currentSpread/pt, maxAllowedSpread/pt, InpMaxSpreadMultiplier);
      return false;
   }
   
   //--- Open buy position (no SL/TP)
   if(trade.Buy(lotSize, sym, 0, 0, 0, "TORAMA_MomentumGrid_Buy"))
   {
      PrintFormat("BUY opened: Lot=%.2f, Price=%.5f, Spread=%.1f, Grid Level=%d", 
                  lotSize, price, currentSpread/pt, buyGridCount + 1);
      return true;
   }
   else
   {
      PrintFormat("BUY failed: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Open sell position                                                 |
//+------------------------------------------------------------------+
bool OpenSellPosition(double price)
{
   //--- Calculate lot size
   double lotSize = CalculateLotSize(sellGridCount);
   
   //--- Validate lot size
   lotSize = NormalizeLot(lotSize);
   if(lotSize < minLot || lotSize > maxLot)
   {
      PrintFormat("ERROR: Invalid lot size %.2f (min: %.2f, max: %.2f)", lotSize, minLot, maxLot);
      return false;
   }
   
   //--- Check spread against max allowed (based on historic spread)
   if(currentSpread > maxAllowedSpread)
   {
      PrintFormat("WARNING: Spread %.1f points exceeds max allowed %.1f points (%.1fx historic) - Skipping trade", 
                  currentSpread/pt, maxAllowedSpread/pt, InpMaxSpreadMultiplier);
      return false;
   }
   
   //--- Open sell position (no SL/TP)
   if(trade.Sell(lotSize, sym, 0, 0, 0, "TORAMA_MomentumGrid_Sell"))
   {
      PrintFormat("SELL opened: Lot=%.2f, Price=%.5f, Spread=%.1f, Grid Level=%d", 
                  lotSize, price, currentSpread/pt, sellGridCount + 1);
      return true;
   }
   else
   {
      PrintFormat("SELL failed: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
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
//| Check drawdown                                                     |
//+------------------------------------------------------------------+
bool CheckDrawdown()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   //--- Update peak balance
   if(currentBalance > peakBalance)
      peakBalance = currentBalance;
   
   //--- Calculate drawdown from peak
   double drawdown = 0;
   if(peakBalance > 0)
      drawdown = ((peakBalance - currentEquity) / peakBalance) * 100.0;
   
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
//| Reset grid                                                         |
//+------------------------------------------------------------------+
void ResetGrid()
{
   lastBuyPrice = 0;
   lastSellPrice = 0;
   buyGridCount = 0;
   sellGridCount = 0;
   
   //--- Update peak balance after successful close
   peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
}

//+------------------------------------------------------------------+
//| Create professional display panel                                  |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int yOffset = InpPanelY;
   int lineHeight = 22;
   int panelWidth = 280;
   
   //--- Background panel (solid, on top)
   CreateRectLabel(panelPrefix + "BG", InpPanelX, yOffset, panelWidth, 375, InpPanelColor, CORNER_LEFT_UPPER, false);
   yOffset += 5;
   
   //--- TORAMA CAPITAL Header with logo background
   CreateRectLabel(panelPrefix + "HeaderBG", InpPanelX + 5, yOffset, panelWidth - 10, 35, InpHeaderColor, CORNER_LEFT_UPPER, false);
   CreateText(panelPrefix + "Logo", InpPanelX + 15, yOffset + 8, "TORAMA CAPITAL", clrWhite, 12, "Arial Black");
   CreateText(panelPrefix + "Tagline", InpPanelX + 15, yOffset + 22, "Algorithmic Trading Solutions", clrWhiteSmoke, 7, "Arial");
   yOffset += 40;
   
   //--- EA Name
   CreateText(panelPrefix + "EAName", InpPanelX + 15, yOffset, "Momentum Grid EA v1.0", clrGold, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Separator line
   CreateRectLabel(panelPrefix + "Sep1", InpPanelX + 10, yOffset, panelWidth - 20, 1, clrDimGray, CORNER_LEFT_UPPER, false);
   yOffset += 8;
   
   //--- Status
   CreateText(panelPrefix + "StatusLabel", InpPanelX + 15, yOffset, "Status:", clrGray, 8);
   CreateText(panelPrefix + "Status", InpPanelX + 80, yOffset, "Active", clrLimeGreen, 8, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Direction
   CreateText(panelPrefix + "DirLabel", InpPanelX + 15, yOffset, "Direction:", clrGray, 8);
   CreateText(panelPrefix + "Direction", InpPanelX + 80, yOffset, "BOTH", InpTextColor, 8);
   yOffset += lineHeight;
   
   //--- Symbol
   CreateText(panelPrefix + "SymLabel", InpPanelX + 15, yOffset, "Symbol:", clrGray, 8);
   CreateText(panelPrefix + "Symbol", InpPanelX + 80, yOffset, sym, InpTextColor, 8);
   yOffset += lineHeight;
   
   //--- Magic Number (Chart ID)
   CreateText(panelPrefix + "MagicLabel", InpPanelX + 15, yOffset, "Magic #:", clrGray, 8);
   CreateText(panelPrefix + "Magic", InpPanelX + 80, yOffset, IntegerToString(magicNumber), InpTextColor, 7);
   yOffset += lineHeight;
   
   //--- Lot Size
   CreateText(panelPrefix + "LotLabel", InpPanelX + 15, yOffset, "Lot Size:", clrGray, 8);
   CreateText(panelPrefix + "LotSize", InpPanelX + 80, yOffset, 
              StringFormat("%.2f", effectiveInitialLotSize), 
              (effectiveInitialLotSize == InpInitialLotSize) ? InpTextColor : clrYellow, 8);
   yOffset += lineHeight;
   
   //--- Current Spread
   CreateText(panelPrefix + "SpreadLabel", InpPanelX + 15, yOffset, "Spread:", clrGray, 8);
   CreateText(panelPrefix + "Spread", InpPanelX + 80, yOffset, "0.0 pts", InpTextColor, 8);
   yOffset += lineHeight;
   
   //--- Grid Gap
   CreateText(panelPrefix + "GapLabel", InpPanelX + 15, yOffset, "Grid Gap:", clrGray, 8);
   CreateText(panelPrefix + "GridGap", InpPanelX + 80, yOffset, "0.00%", InpTextColor, 8);
   yOffset += lineHeight;
   
   //--- Separator
   CreateRectLabel(panelPrefix + "Sep2", InpPanelX + 10, yOffset, panelWidth - 20, 1, clrDimGray, CORNER_LEFT_UPPER, false);
   yOffset += 8;
   
   //--- Buy Grid
   CreateText(panelPrefix + "BuyLabel", InpPanelX + 15, yOffset, "Buy Grid:", clrDodgerBlue, 8);
   CreateText(panelPrefix + "BuyGrid", InpPanelX + 80, yOffset, "0 levels", InpTextColor, 8);
   yOffset += lineHeight;
   
   //--- Sell Grid
   CreateText(panelPrefix + "SellLabel", InpPanelX + 15, yOffset, "Sell Grid:", clrTomato, 8);
   CreateText(panelPrefix + "SellGrid", InpPanelX + 80, yOffset, "0 levels", InpTextColor, 8);
   yOffset += lineHeight;
   
   //--- Separator
   CreateRectLabel(panelPrefix + "Sep3", InpPanelX + 10, yOffset, panelWidth - 20, 1, clrDimGray, CORNER_LEFT_UPPER, false);
   yOffset += 8;
   
   //--- Profit
   CreateText(panelPrefix + "ProfitLabel", InpPanelX + 15, yOffset, "Profit:", clrGray, 8);
   CreateText(panelPrefix + "Profit", InpPanelX + 80, yOffset, "$0.00", clrLimeGreen, 9, "Arial Bold");
   yOffset += lineHeight;
   
   //--- Target TP
   CreateText(panelPrefix + "TPLabel", InpPanelX + 15, yOffset, "Target TP:", clrGray, 8);
   CreateText(panelPrefix + "GlobalTP", InpPanelX + 80, yOffset, StringFormat("$%.2f", InpGlobalTakeProfitUSD), clrGold, 8);
   yOffset += lineHeight;
   
   //--- Drawdown
   CreateText(panelPrefix + "DDLabel", InpPanelX + 15, yOffset, "Drawdown:", clrGray, 8);
   CreateText(panelPrefix + "Drawdown", InpPanelX + 80, yOffset, "0.00%", InpTextColor, 8);
   yOffset += lineHeight;
   
   //--- Max DD
   CreateText(panelPrefix + "MaxDDLabel", InpPanelX + 15, yOffset, "Max DD:", clrGray, 8);
   CreateText(panelPrefix + "MaxDD", InpPanelX + 80, yOffset, StringFormat("%.1f%%", InpMaxDrawdownPercent), clrOrangeRed, 8);
   yOffset += lineHeight + 5;
   
   //--- Separator
   CreateRectLabel(panelPrefix + "Sep4", InpPanelX + 10, yOffset, panelWidth - 20, 1, clrDimGray, CORNER_LEFT_UPPER, false);
   yOffset += 10;
   
   //--- Control Buttons
   CreateButton(panelPrefix + "BtnCloseAll", InpPanelX + 15, yOffset, 80, 28, "CLOSE ALL", clrWhite, clrCrimson);
   CreateButton(panelPrefix + "BtnPause", InpPanelX + 105, yOffset, 80, 28, "PAUSE", clrWhite, C'255,152,0');
   CreateButton(panelPrefix + "BtnTakeProfit", InpPanelX + 195, yOffset, 70, 28, "TAKE TP", clrWhite, C'34,139,34');
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update display panel                                               |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   //--- Calculate metrics
   double totalProfit = GetTotalProfit();
   
   //--- Calculate drawdown
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdown = 0;
   if(peakBalance > 0)
      drawdown = ((peakBalance - currentEquity) / peakBalance) * 100.0;
   
   //--- Status
   string status = "Active";
   color statusColor = clrLimeGreen;
   
   if(isManuallyPaused)
   {
      status = "PAUSED (Manual)";
      statusColor = clrOrange;
   }
   else if(isDrawdownPaused)
   {
      status = "PAUSED (Drawdown)";
      statusColor = clrOrangeRed;
   }
   
   ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, status);
   ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, statusColor);
   
   //--- Direction
   string direction = InpTradeDirection == DIRECTION_BOTH ? "BOTH" : 
                     (InpTradeDirection == DIRECTION_BUY_ONLY ? "BUY ONLY" : "SELL ONLY");
   ObjectSetString(0, panelPrefix + "Direction", OBJPROP_TEXT, direction);
   
   //--- Spread with color coding
   double spreadPoints = currentSpread / pt;
   double maxSpreadPoints = maxAllowedSpread / pt;
   color spreadColor = InpTextColor;
   
   if(currentSpread > maxAllowedSpread)
      spreadColor = clrRed;
   else if(currentSpread > maxAllowedSpread * 0.8)
      spreadColor = clrOrange;
   else if(currentSpread < historicSpread * 1.2)
      spreadColor = clrLimeGreen;
   
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_TEXT, 
                  StringFormat("%.1f pts (max %.1f)", spreadPoints, maxSpreadPoints));
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_COLOR, spreadColor);
   
   //--- Grid gap
   ObjectSetString(0, panelPrefix + "GridGap", OBJPROP_TEXT, 
                  StringFormat("%.2f%% (%.5f)", InpGridGapPercent, gridGapPrice));
   
   //--- Grid levels
   ObjectSetString(0, panelPrefix + "BuyGrid", OBJPROP_TEXT, 
                  StringFormat("%d levels", buyGridCount));
   ObjectSetString(0, panelPrefix + "SellGrid", OBJPROP_TEXT, 
                  StringFormat("%d levels", sellGridCount));
   
   //--- Profit
   color profitColor = totalProfit >= 0 ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "Profit", OBJPROP_TEXT, 
                  StringFormat("$%.2f", totalProfit));
   ObjectSetInteger(0, panelPrefix + "Profit", OBJPROP_COLOR, profitColor);
   
   //--- Drawdown
   color ddColor = InpTextColor;
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
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
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
