//+------------------------------------------------------------------+
//|                  TORAMA_MomentumGrid_IndividualTP_v3.07.mq5      |
//|                                          TORAMA CAPITAL           |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://toramacapital.com"
#property version   "3.08"
#property description "Momentum Grid EA - Individual TP + Force Market Orders"
#property description "✓ Per-Position TP | ✓ Force Market Orders | ✓ Daily Profit Target"

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== TRADING DIRECTION ==="
enum ENUM_TRADE_DIRECTION { DIRECTION_BOTH = 0, DIRECTION_BUY_ONLY = 1, DIRECTION_SELL_ONLY = 2 };
input ENUM_TRADE_DIRECTION InpTradeDirection = DIRECTION_BOTH;
input bool InpBidirectionalGrid = false;

input group "=== GRID SETTINGS ==="
input double InpGridGapPercent = 0.5;
input double InpInitialLotSize = 0.01;
input double InpLotMultiplier = 1.0;
input int    InpMaxGridLevels = 30;               // Max Grid Levels (0 = Unlimited)
input double InpMaxSpreadPoints = 0;

input group "=== INDIVIDUAL TAKE PROFIT ==="
input bool   InpEnableIndividualTP = true;        // Enable Individual TP per Position
input double InpTPOffsetPercent = 95.0;           // TP Offset % of Grid Gap (95% = just before next level)

input group "=== GLOBAL PROFIT & RISK ==="
input double InpGlobalTakeProfitUSD = 100.0;
input double InpMaxDrawdownPercent = 10.0;
input int    InpDrawdownPauseMinutes = 30;
input double InpDailyProfitTargetPercent = 10.0;  // Daily Profit Target % (0 = Disabled)

input group "=== REVERSAL THRESHOLD ==="
input bool   InpEnableReversal = false;           // Enable Auto-Reversal
input int    InpReversalLevels = 5;               // Reversal Threshold (Levels)

input group "=== DISPLAY ==="
input color  InpPanelColor = C'20,25,30';
input color  InpHeaderColor = C'41,98,255';
input color  InpTextColor = clrWhite;
input int    InpPanelX = 20;
input int    InpPanelY = 50;

input group "=== EXPERT SETTINGS ==="
input int    InpMagicNumber = 0;                  // Magic Number (0 = Auto from ChartID)
input bool   InpForceMarketOrders = false;        // Force Market Orders (All Symbols)

//--- Global variables
CTrade trade;
string sym;
double pt, tickSize, tickValue, gridGapPrice, maxAllowedSpread, currentSpread;
double minLot, maxLot, lotStep, stopLevel, referencePrice, effectiveInitialLotSize;
double accountStartBalance, peakBalance, peakEquity;
int dgt, highestBuyLevel, lowestSellLevel;
long magicNumber;
bool gridInitialized, useMarketOrders, isDrawdownPaused, isManuallyPaused, isStoppedByDrawdown, buttonPressed;
datetime lastDrawdownPauseTime, lastPanelUpdate;
string panelPrefix = "TORAMA_Panel_";

//--- Daily profit target tracking
double dailyStartBalance = 0.0;
datetime lastDayCheck = 0;
bool dailyTargetReached = false;

//--- Cycle tracking with P/L history
int globalTPCycleCount = 0;
int closeAllCycleCount = 0;
int totalCycleCount = 0;
double cycleNetPL[];              // Array to store net P/L for each cycle
string cycleType[];               // Array to store cycle type (TP/CA/DD)
bool debugMode = false;           // Debug mode flag (press 'D' to toggle)

//--- Reversal tracking
int peakBuyLevelsActivated = 0;   // Peak number of buy levels activated before reversal
int peakSellLevelsActivated = 0;  // Peak number of sell levels activated before reversal
bool reversalTriggered = false;   // Flag to prevent multiple reversals in same trend

//--- Triggered level tracking
int triggeredBuyLevels[], triggeredSellLevels[], buyTriggeredCount, sellTriggeredCount;
double buyEntryPrices[], sellEntryPrices[];
int buyEntryCount, sellEntryCount;
double lastBuyTriggerPrice, lastSellTriggerPrice;

//--- Individual TP tracking
int individualTPClosedCount = 0;  // Count positions closed by individual TP

//+------------------------------------------------------------------+
int OnInit()
{
   // Set magic number: user-defined or auto from ChartID
   magicNumber = (InpMagicNumber > 0) ? InpMagicNumber : ChartID();
   sym = _Symbol;
   pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   dgt = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   tickSize = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   minLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   maxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   stopLevel = (int)SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL) * pt;
   
   maxAllowedSpread = InpMaxSpreadPoints > 0 ? InpMaxSpreadPoints * pt : 0;
   effectiveInitialLotSize = NormalizeLot(MathMax(minLot, MathMin(maxLot, InpInitialLotSize)));
   
   if(InpGridGapPercent <= 0 || InpGlobalTakeProfitUSD <= 0 || InpMaxDrawdownPercent <= 0 || InpMaxDrawdownPercent > 100)
      return INIT_PARAMETERS_INCORRECT;
   
   if(InpEnableIndividualTP && (InpTPOffsetPercent <= 0 || InpTPOffsetPercent > 100))
      return INIT_PARAMETERS_INCORRECT;
   
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   if(trade.ResultRetcode() == TRADE_RETCODE_INVALID_FILL) trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   peakBalance = accountStartBalance;
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   isStoppedByDrawdown = false;
   lastPanelUpdate = 0;
   
   // Initialize daily profit tracking
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   lastDayCheck = StructToTime(dt);
   dailyStartBalance = accountStartBalance;
   dailyTargetReached = false;
   
   // Only reset debug mode and cycles if no existing positions
   int existingPosCount = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetString(POSITION_SYMBOL) == sym && PositionGetInteger(POSITION_MAGIC) == magicNumber)
            existingPosCount++;
   }
   
   if(existingPosCount == 0)
   {
      // Fresh start - reset everything
      debugMode = false;
      globalTPCycleCount = 0;
      closeAllCycleCount = 0;
      totalCycleCount = 0;
      individualTPClosedCount = 0;
   }
   else
   {
      // Settings changed mid-trade - preserve counters
      PrintFormat("Settings changed with %d existing positions - preserving cycle counters", existingPosCount);
   }
   
   // Initialize cycle tracking arrays
   if(ArraySize(cycleNetPL) == 0)
   {
      ArrayResize(cycleNetPL, 500);
      ArrayResize(cycleType, 500);
      ArrayInitialize(cycleNetPL, 0.0);
   }
   
   // Initialize reversal tracking
   peakBuyLevelsActivated = 0;
   peakSellLevelsActivated = 0;
   reversalTriggered = false;
   
   ArrayResize(triggeredBuyLevels, 200);
   ArrayResize(triggeredSellLevels, 200);
   ArrayResize(buyEntryPrices, 200);
   ArrayResize(sellEntryPrices, 200);
   ArrayInitialize(triggeredBuyLevels, -999999);
   ArrayInitialize(triggeredSellLevels, -999999);
   ArrayInitialize(buyEntryPrices, 0.0);
   ArrayInitialize(sellEntryPrices, 0.0);
   buyTriggeredCount = sellTriggeredCount = buyEntryCount = sellEntryCount = 0;
   
   DetectMarketOrderMode();
   CalculateGridGap();
   InitializeSacrosanctGrid();
   
   // Apply individual TP to existing positions if enabled
   if(InpEnableIndividualTP)
      ApplyIndividualTPToAllPositions();
   
   CreatePanel();
   
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   EventSetMillisecondTimer(500);
   
   int currentPositions = CountExistingPositions();
   
   PrintFormat("╔════════════════════════════════════════════════════════════════╗");
   PrintFormat("║  TORAMA Grid v3.08 COMPLETE - Magic: %I64d", magicNumber);
   PrintFormat("║  ✓ Individual TP: %s | ✓ Force Market: %s | ✓ Daily Target", 
               InpEnableIndividualTP ? "ENABLED" : "DISABLED",
               InpForceMarketOrders ? "ON" : "OFF");
   PrintFormat("║  ✓ Position Preservation: %d existing positions maintained", currentPositions);
   PrintFormat("║  Press 'D' for Debug | Individual TP: %.1f%% of grid gap", InpTPOffsetPercent);
   PrintFormat("║  Daily Target: %s | Lot: %.2f | Gap: %.2f%%", 
               InpDailyProfitTargetPercent > 0 ? "ENABLED" : "DISABLED", 
               effectiveInitialLotSize, InpGridGapPercent);
   PrintFormat("╚════════════════════════════════════════════════════════════════╝");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeletePanel();
   EventKillTimer();
}

//+------------------------------------------------------------------+
void OnTick()
{
   currentSpread = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
   CalculateGridGap();
   TrackTriggeredLevels();
   UpdateEntryPriceTracking();
   
   // Monitor and maintain individual TPs
   if(InpEnableIndividualTP)
      MonitorIndividualTPs();
   
   // Check daily profit target
   CheckDailyProfitTarget();
   
   if(dailyTargetReached)
   {
      UpdatePanelFast();
      return;
   }
   
   // Check for reversal threshold
   if(InpEnableReversal && InpTradeDirection == DIRECTION_BOTH)
      CheckReversalThreshold();
   
   if(isStoppedByDrawdown) 
   { 
      UpdatePanelFast(); 
      return; 
   }
   
   // Check Global TP
   if(CheckGlobalTakeProfit())
   {
      double netPL = GetTotalProfit();
      globalTPCycleCount++;
      totalCycleCount++;
      
      if(totalCycleCount <= ArraySize(cycleNetPL))
      {
         cycleNetPL[totalCycleCount - 1] = netPL;
         cycleType[totalCycleCount - 1] = "GLOBAL_TP";
      }
      
      PrintFormat("╔════════════════════════════════════════════════════════════════╗");
      PrintFormat("║  CYCLE #%d: GLOBAL TP TRIGGERED", totalCycleCount);
      PrintFormat("║  Net P/L: $%.2f | Target: $%.2f", netPL, InpGlobalTakeProfitUSD);
      PrintFormat("╚════════════════════════════════════════════════════════════════╝");
      
      CloseAllPositionsParallel("Global TP");
      DeleteAllPendingOrders();
      ResetSacrosanctGrid();
      UpdatePanelFast();
      return;
   }
   
   if(isManuallyPaused) { UpdatePanelFast(); return; }
   
   // Check Max Drawdown
   if(CheckMaxDrawdown())
   {
      if(!isStoppedByDrawdown)
      {
         isStoppedByDrawdown = true;
         double netPL = GetTotalProfit();
         double dd = ((peakEquity - AccountInfoDouble(ACCOUNT_EQUITY)) / peakEquity) * 100.0;
         
         totalCycleCount++;
         if(totalCycleCount <= ArraySize(cycleNetPL))
         {
            cycleNetPL[totalCycleCount - 1] = netPL;
            cycleType[totalCycleCount - 1] = "MAX_DD";
         }
         
         PrintFormat("╔════════════════════════════════════════════════════════════════╗");
         PrintFormat("║  CYCLE #%d: MAX DRAWDOWN REACHED", totalCycleCount);
         PrintFormat("║  Drawdown: %.2f%% | Net P/L: $%.2f", dd, netPL);
         PrintFormat("║  EA PERMANENTLY STOPPED");
         PrintFormat("╚════════════════════════════════════════════════════════════════╝");
         
         CloseAllPositionsParallel("Max Drawdown");
         DeleteAllPendingOrders();
         UpdatePanelFast();
         return;
      }
   }
   
   if(GetTotalPositions() == 0 && gridInitialized && !isStoppedByDrawdown && (buyTriggeredCount > 0 || sellTriggeredCount > 0))
   {
      DeleteAllPendingOrders();
      ResetSacrosanctGrid();
   }
   
   MaintainSacrosanctGrid();
   UpdatePanelFast();
}

//+------------------------------------------------------------------+
// INDIVIDUAL TAKE PROFIT FUNCTIONS
//+------------------------------------------------------------------+

void MonitorIndividualTPs()
{
   // Check all positions and apply/update TP if needed
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double currentTP = PositionGetDouble(POSITION_TP);
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      
      // Calculate what TP should be
      double targetTP = CalculateIndividualTP(entryPrice, isBuy);
      
      // Apply TP if not set or different from target
      if(MathAbs(currentTP - targetTP) > pt)
      {
         if(!trade.PositionModify(ticket, 0, targetTP))
         {
            PrintFormat("Failed to set Individual TP for #%I64u: %s", ticket, trade.ResultRetcodeDescription());
         }
      }
   }
}

void ApplyIndividualTPToAllPositions()
{
   int appliedCount = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      
      double targetTP = CalculateIndividualTP(entryPrice, isBuy);
      
      if(trade.PositionModify(ticket, 0, targetTP))
         appliedCount++;
   }
   
   if(appliedCount > 0)
      PrintFormat("✓ Applied Individual TP to %d existing positions", appliedCount);
}

double CalculateIndividualTP(double entryPrice, bool isBuy)
{
   // Calculate TP distance: grid gap × offset percentage
   double tpDistance = gridGapPrice * (InpTPOffsetPercent / 100.0);
   
   double tp;
   if(isBuy)
   {
      // For buy: TP is above entry (next grid level minus offset)
      tp = entryPrice + tpDistance;
   }
   else
   {
      // For sell: TP is below entry (next grid level minus offset)
      tp = entryPrice - tpDistance;
   }
   
   // Normalize to tick size
   tp = NormalizeDouble(MathRound(tp / tickSize) * tickSize, dgt);
   
   // Ensure TP respects broker's stop level
   double minDistance = stopLevel;
   if(minDistance > 0)
   {
      if(isBuy)
         tp = MathMax(tp, entryPrice + minDistance);
      else
         tp = MathMin(tp, entryPrice - minDistance);
   }
   
   return tp;
}

//+------------------------------------------------------------------+
// PARALLEL POSITION CLOSURE
//+------------------------------------------------------------------+
void CloseAllPositionsParallel(string reason)
{
   int totalPos = PositionsTotal();
   if(totalPos == 0) return;
   
   ulong tickets[];
   ArrayResize(tickets, totalPos);
   int validCount = 0;
   
   for(int i = 0; i < totalPos; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      tickets[validCount++] = ticket;
   }
   
   if(validCount == 0) return;
   
   PrintFormat("▶ Closing %d positions in parallel (%s)...", validCount, reason);
   uint startTime = GetTickCount();
   
   int closedCount = 0;
   int failedCount = 0;
   
   for(int i = 0; i < validCount; i++)
   {
      if(trade.PositionClose(tickets[i]))
         closedCount++;
      else
         failedCount++;
   }
   
   uint endTime = GetTickCount();
   double elapsedMs = (endTime - startTime);
   
   PrintFormat("✓ Parallel close complete: %d closed, %d failed in %.0fms", 
               closedCount, failedCount, elapsedMs);
   
   if(failedCount > 0)
   {
      Sleep(100);
      PrintFormat("⟳ Retrying %d failed positions...", failedCount);
      
      for(int i = 0; i < validCount; i++)
      {
         if(PositionSelectByTicket(tickets[i]))
            trade.PositionClose(tickets[i]);
      }
   }
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Handle keyboard events
   if(id == CHARTEVENT_KEYDOWN)
   {
      if(lparam == 68 || lparam == 100) // 'D' or 'd'
      {
         debugMode = !debugMode;
         if(debugMode)
         {
            PrintFormat("╔════════════════════════════════════════════════════════════════╗");
            PrintFormat("║  DEBUG MODE: ENABLED");
            PrintFormat("║  Individual TP Closes: %d", individualTPClosedCount);
            PrintFormat("╚════════════════════════════════════════════════════════════════╝");
            PrintDebugCycleHistory();
         }
         else
         {
            PrintFormat("DEBUG MODE: DISABLED");
         }
         UpdatePanelFast();
      }
      return;
   }
   
   if(id != CHARTEVENT_OBJECT_CLICK || isStoppedByDrawdown || buttonPressed) return;
   
   buttonPressed = true;
   
   if(sparam == panelPrefix + "BtnCloseAll")
   {
      double netPL = GetTotalProfit();
      closeAllCycleCount++;
      totalCycleCount++;
      
      if(totalCycleCount <= ArraySize(cycleNetPL))
      {
         cycleNetPL[totalCycleCount - 1] = netPL;
         cycleType[totalCycleCount - 1] = "CLOSE_ALL";
      }
      
      PrintFormat("╔════════════════════════════════════════════════════════════════╗");
      PrintFormat("║  CYCLE #%d: CLOSE ALL BUTTON", totalCycleCount);
      PrintFormat("║  Net P/L: $%.2f", netPL);
      PrintFormat("╚════════════════════════════════════════════════════════════════╝");
      
      CloseAllPositionsParallel("Manual Close All");
      DeleteAllPendingOrders();
      ResetSacrosanctGrid();
   }
   else if(sparam == panelPrefix + "BtnPause")
   {
      isManuallyPaused = !isManuallyPaused;
      ObjectSetInteger(0, panelPrefix + "BtnPause", OBJPROP_BGCOLOR, isManuallyPaused ? clrGreen : C'255,152,0');
      ObjectSetString(0, panelPrefix + "BtnPause", OBJPROP_TEXT, isManuallyPaused ? "RESUME" : "PAUSE");
      PrintFormat(isManuallyPaused ? "⏸ EA Paused" : "▶ EA Resumed");
   }
   else if(sparam == panelPrefix + "BtnTakeProfit")
   {
      double netPL = GetTotalProfit();
      globalTPCycleCount++;
      totalCycleCount++;
      
      if(totalCycleCount <= ArraySize(cycleNetPL))
      {
         cycleNetPL[totalCycleCount - 1] = netPL;
         cycleType[totalCycleCount - 1] = "MANUAL_TP";
      }
      
      PrintFormat("╔════════════════════════════════════════════════════════════════╗");
      PrintFormat("║  CYCLE #%d: MANUAL TAKE PROFIT", totalCycleCount);
      PrintFormat("║  Net P/L: $%.2f", netPL);
      PrintFormat("╚════════════════════════════════════════════════════════════════╝");
      
      CloseAllPositionsParallel("Manual TP");
      DeleteAllPendingOrders();
      ResetSacrosanctGrid();
   }
   else if(sparam == panelPrefix + "BtnResetRef")
   {
      PrintFormat("🔄 Resetting Reference Price...");
      ResetGridReference();
      PrintFormat("✓ Reference Reset to: %s", DoubleToString(referencePrice, dgt));
   }
   
   Sleep(200);
   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   buttonPressed = false;
   ChartRedraw();
}

//+------------------------------------------------------------------+
void OnTimer()
{
   // Timer for UI responsiveness
}

//+------------------------------------------------------------------+
// GRID CALCULATION & MANAGEMENT
//+------------------------------------------------------------------+

void DetectMarketOrderMode()
{
   if(InpForceMarketOrders)
   {
      useMarketOrders = true;
      PrintFormat("Order Mode: MARKET (FORCED) | Force Market Orders: ON");
      return;
   }
   
   useMarketOrders = (stopLevel == 0 || stopLevel < gridGapPrice * 0.5);
   PrintFormat("Order Mode: %s | Stop Level: %.5f | Grid Gap: %.5f", 
               useMarketOrders ? "MARKET" : "PENDING", stopLevel, gridGapPrice);
}

void CalculateGridGap()
{
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double midPrice = (ask + bid) / 2.0;
   
   gridGapPrice = NormalizeDouble(midPrice * InpGridGapPercent / 100.0, dgt);
   gridGapPrice = MathMax(gridGapPrice, tickSize);
   gridGapPrice = MathRound(gridGapPrice / tickSize) * tickSize;
}

double NormalizeLot(double lot)
{
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathRound(lot / lotStep) * lotStep;
   return NormalizeDouble(lot, 2);
}

double CalculateLotSize(int level)
{
   if(InpLotMultiplier <= 1.0) return effectiveInitialLotSize;
   
   int absLevel = (int)MathAbs(level);
   double multiplier = MathPow(InpLotMultiplier, absLevel);
   return effectiveInitialLotSize * multiplier;
}

//+------------------------------------------------------------------+
// GRID INITIALIZATION & RESET
//+------------------------------------------------------------------+

void InitializeSacrosanctGrid()
{
   int existingPositions = CountExistingPositions();
   
   if(existingPositions == 0)
   {
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      referencePrice = NormalizeDouble((ask + bid) / 2.0, dgt);
      referencePrice = MathRound(referencePrice / tickSize) * tickSize;
      
      highestBuyLevel = lowestSellLevel = 0;
      
      PlaceInitialOrder();
      gridInitialized = true;
      
      PrintFormat("✓ Grid Initialized - Reference: %s", DoubleToString(referencePrice, dgt));
      return;
   }
   
   double highestBuyPrice = 0, lowestSellPrice = DBL_MAX;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         highestBuyPrice = MathMax(highestBuyPrice, entryPrice);
      else
         lowestSellPrice = MathMin(lowestSellPrice, entryPrice);
   }
   
   if(highestBuyPrice > 0 && lowestSellPrice < DBL_MAX)
      referencePrice = NormalizeDouble((highestBuyPrice + lowestSellPrice) / 2.0, dgt);
   else if(highestBuyPrice > 0)
      referencePrice = highestBuyPrice - gridGapPrice;
   else if(lowestSellPrice < DBL_MAX)
      referencePrice = lowestSellPrice + gridGapPrice;
   else
   {
      double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
      double bid = SymbolInfoDouble(sym, SYMBOL_BID);
      referencePrice = NormalizeDouble((ask + bid) / 2.0, dgt);
   }
   
   referencePrice = MathRound(referencePrice / tickSize) * tickSize;
   highestBuyLevel = lowestSellLevel = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      int level = (int)MathRound((entryPrice - referencePrice) / gridGapPrice);
      
      if(!IsLevelTriggered(level, PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY))
         MarkLevelAsTriggered(level, PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && level > highestBuyLevel)
         highestBuyLevel = level;
      else if(level < lowestSellLevel)
         lowestSellLevel = level;
   }
   
   gridInitialized = true;
   DeleteAllPendingOrders();
   
   PrintFormat("✓ Existing positions preserved - grid continues from current state");
}

void ResetSacrosanctGrid()
{
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   referencePrice = NormalizeDouble((ask + bid) / 2.0, dgt);
   referencePrice = MathRound(referencePrice / tickSize) * tickSize;
   highestBuyLevel = lowestSellLevel = 0;
   ArrayInitialize(triggeredBuyLevels, -999999);
   ArrayInitialize(triggeredSellLevels, -999999);
   ArrayInitialize(buyEntryPrices, 0.0);
   ArrayInitialize(sellEntryPrices, 0.0);
   buyTriggeredCount = sellTriggeredCount = buyEntryCount = sellEntryCount = 0;
   
   peakBuyLevelsActivated = 0;
   peakSellLevelsActivated = 0;
   reversalTriggered = false;
   
   PlaceInitialOrder();
   MaintainSacrosanctGrid();
}

void ResetGridReference()
{
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double currentMidPrice = NormalizeDouble((ask + bid) / 2.0, dgt);
   currentMidPrice = MathRound(currentMidPrice / tickSize) * tickSize;
   
   int levelsFromOldRef = (int)MathRound((currentMidPrice - referencePrice) / gridGapPrice);
   referencePrice = referencePrice + (levelsFromOldRef * gridGapPrice);
   referencePrice = MathRound(referencePrice / tickSize) * tickSize;
   
   RecalculateTriggeredLevels();
   DeleteAllPendingOrders();
   highestBuyLevel = lowestSellLevel = 0;
   UpdateGridLevelsFromPositions();
   MaintainSacrosanctGrid();
   
   // Reapply individual TPs after reference reset
   if(InpEnableIndividualTP)
      ApplyIndividualTPToAllPositions();
}

void RecalculateTriggeredLevels()
{
   ArrayInitialize(triggeredBuyLevels, -999999);
   ArrayInitialize(triggeredSellLevels, -999999);
   buyTriggeredCount = sellTriggeredCount = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      int level = (int)MathRound((entryPrice - referencePrice) / gridGapPrice);
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      
      if(!IsLevelTriggered(level, isBuy))
         MarkLevelAsTriggered(level, isBuy);
   }
}

void UpdateGridLevelsFromPositions()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      int level = (int)MathRound((entryPrice - referencePrice) / gridGapPrice);
      
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && level > highestBuyLevel)
         highestBuyLevel = level;
      else if(level < lowestSellLevel)
         lowestSellLevel = level;
   }
}

void PlaceInitialOrder()
{
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   
   if(ask < referencePrice && (InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_BUY_ONLY))
      PlaceBuyOrder(0, referencePrice);
   else if(bid > referencePrice && (InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_SELL_ONLY))
      PlaceSellOrder(0, referencePrice);
   else if(MathAbs(ask - referencePrice) < gridGapPrice / 2)
   {
      double lotSize = NormalizeLot(CalculateLotSize(0));
      if(InpTradeDirection != DIRECTION_SELL_ONLY) 
      {
         if(trade.Buy(lotSize, sym, 0, 0, 0, "TORAMA_Grid_L0"))
         {
            // Apply individual TP to initial order
            if(InpEnableIndividualTP)
            {
               ulong ticket = trade.ResultOrder();
               if(ticket > 0 && PositionSelectByTicket(ticket))
               {
                  double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                  double tp = CalculateIndividualTP(entryPrice, true);
                  trade.PositionModify(ticket, 0, tp);
               }
            }
         }
      }
      else 
      {
         if(trade.Sell(lotSize, sym, 0, 0, 0, "TORAMA_Grid_L0"))
         {
            // Apply individual TP to initial order
            if(InpEnableIndividualTP)
            {
               ulong ticket = trade.ResultOrder();
               if(ticket > 0 && PositionSelectByTicket(ticket))
               {
                  double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                  double tp = CalculateIndividualTP(entryPrice, false);
                  trade.PositionModify(ticket, 0, tp);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
void MaintainSacrosanctGrid()
{
   if(maxAllowedSpread > 0 && currentSpread > maxAllowedSpread) return;
   
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   
   if(useMarketOrders) { CheckAndExecuteMarketOrders(); return; }
   
   int levelsAbove = (int)MathFloor((ask - referencePrice) / gridGapPrice);
   int levelsBelow = (int)MathFloor((referencePrice - bid) / gridGapPrice);
   
   if(InpBidirectionalGrid && (InpTradeDirection == DIRECTION_BUY_ONLY || InpTradeDirection == DIRECTION_SELL_ONLY))
   {
      bool placeBuys = (InpTradeDirection == DIRECTION_BUY_ONLY);
      for(int level = 1; level <= levelsAbove + 10; level++)
      {
         if(InpMaxGridLevels > 0 && level > InpMaxGridLevels) break;
         if(IsLevelTriggered(level, placeBuys)) continue;
         double orderPrice = referencePrice + (level * gridGapPrice);
         if(!PendingOrderExists(level, placeBuys))
            placeBuys ? PlaceBuyOrder(level, orderPrice) : PlaceSellOrder(level, orderPrice);
      }
      for(int level = -1; level >= -(levelsBelow + 10); level--)
      {
         if(InpMaxGridLevels > 0 && MathAbs(level) > InpMaxGridLevels) break;
         if(IsLevelTriggered(level, placeBuys)) continue;
         double orderPrice = referencePrice + (level * gridGapPrice);
         if(!PendingOrderExists(level, placeBuys))
            placeBuys ? PlaceBuyOrder(level, orderPrice) : PlaceSellOrder(level, orderPrice);
      }
      return;
   }
   
   if(InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_BUY_ONLY)
   {
      for(int level = highestBuyLevel + 1; level <= levelsAbove + 10; level++)
      {
         if(InpMaxGridLevels > 0 && level > InpMaxGridLevels) break;
         if(IsLevelTriggered(level, true)) continue;
         double orderPrice = referencePrice + (level * gridGapPrice);
         if(!PendingOrderExists(level, true) && PlaceBuyOrder(level, orderPrice))
            highestBuyLevel = level;
         else
            highestBuyLevel = MathMax(highestBuyLevel, level);
      }
   }
   
   if(InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_SELL_ONLY)
   {
      for(int level = lowestSellLevel - 1; level >= -(levelsBelow + 10); level--)
      {
         if(InpMaxGridLevels > 0 && MathAbs(level) > InpMaxGridLevels) break;
         if(IsLevelTriggered(level, false)) continue;
         double orderPrice = referencePrice + (level * gridGapPrice);
         if(!PendingOrderExists(level, false) && PlaceSellOrder(level, orderPrice))
            lowestSellLevel = level;
         else
            lowestSellLevel = MathMin(lowestSellLevel, level);
      }
   }
}

//+------------------------------------------------------------------+
void CheckAndExecuteMarketOrders()
{
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   
   if(InpBidirectionalGrid && (InpTradeDirection == DIRECTION_BUY_ONLY || InpTradeDirection == DIRECTION_SELL_ONLY))
   {
      bool executeBuys = (InpTradeDirection == DIRECTION_BUY_ONLY);
      int levelsAbove = (int)MathFloor((ask - referencePrice) / gridGapPrice);
      for(int level = 1; level <= levelsAbove; level++)
      {
         if(InpMaxGridLevels > 0 && level > InpMaxGridLevels) break;
         double levelPrice = referencePrice + (level * gridGapPrice);
         if(executeBuys && !IsLevelTriggered(level, true) && !PositionExistsAtLevel(level, true) && ask >= levelPrice)
         {
            ExecuteMarketBuy(level);
            MarkLevelAsTriggered(level, true);
         }
         else if(!executeBuys && !IsLevelTriggered(level, false) && !PositionExistsAtLevel(level, false) && ask >= levelPrice)
         {
            ExecuteMarketSell(level);
            MarkLevelAsTriggered(level, false);
         }
      }
      int levelsBelow = (int)MathFloor((referencePrice - bid) / gridGapPrice);
      for(int level = -1; level >= -levelsBelow; level--)
      {
         if(InpMaxGridLevels > 0 && MathAbs(level) > InpMaxGridLevels) break;
         double levelPrice = referencePrice + (level * gridGapPrice);
         if(executeBuys && !IsLevelTriggered(level, true) && !PositionExistsAtLevel(level, true) && bid <= levelPrice)
         {
            ExecuteMarketBuy(level);
            MarkLevelAsTriggered(level, true);
         }
         else if(!executeBuys && !IsLevelTriggered(level, false) && !PositionExistsAtLevel(level, false) && bid <= levelPrice)
         {
            ExecuteMarketSell(level);
            MarkLevelAsTriggered(level, false);
         }
      }
      return;
   }
   
   if(InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_BUY_ONLY)
   {
      int currentLevel = (int)MathFloor((ask - referencePrice) / gridGapPrice);
      for(int level = currentLevel; level >= 1; level--)
      {
         if(InpMaxGridLevels > 0 && level > InpMaxGridLevels) continue;
         if(IsLevelTriggered(level, true) || PositionExistsAtLevel(level, true)) continue;
         if(PositionExistsAtPrice(ask, true)) continue;
         
         double levelPrice = referencePrice + (level * gridGapPrice);
         if(ask >= levelPrice)
         {
            ExecuteMarketBuy(level);
            MarkLevelAsTriggered(level, true);
            highestBuyLevel = MathMax(highestBuyLevel, level);
            break;
         }
      }
   }
   
   if(InpTradeDirection == DIRECTION_BOTH || InpTradeDirection == DIRECTION_SELL_ONLY)
   {
      int currentLevel = (int)MathFloor((referencePrice - bid) / gridGapPrice);
      for(int level = currentLevel; level >= 1; level--)
      {
         int sellLevel = -level;
         if(InpMaxGridLevels > 0 && level > InpMaxGridLevels) continue;
         if(IsLevelTriggered(sellLevel, false) || PositionExistsAtLevel(sellLevel, false)) continue;
         if(PositionExistsAtPrice(bid, false)) continue;
         
         double levelPrice = referencePrice - (level * gridGapPrice);
         if(bid <= levelPrice)
         {
            ExecuteMarketSell(sellLevel);
            MarkLevelAsTriggered(sellLevel, false);
            lowestSellLevel = MathMin(lowestSellLevel, sellLevel);
            break;
         }
      }
   }
}

void ExecuteMarketBuy(int level)
{
   double lotSize = NormalizeLot(CalculateLotSize(level));
   string comment = StringFormat("TORAMA_Grid_L%d", level);
   
   if(trade.Buy(lotSize, sym, 0, 0, 0, comment))
   {
      // Apply individual TP immediately after execution
      if(InpEnableIndividualTP)
      {
         ulong ticket = trade.ResultOrder();
         if(ticket > 0 && PositionSelectByTicket(ticket))
         {
            double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double tp = CalculateIndividualTP(entryPrice, true);
            trade.PositionModify(ticket, 0, tp);
         }
      }
   }
}

void ExecuteMarketSell(int level)
{
   double lotSize = NormalizeLot(CalculateLotSize(level));
   string comment = StringFormat("TORAMA_Grid_L%d", level);
   
   if(trade.Sell(lotSize, sym, 0, 0, 0, comment))
   {
      // Apply individual TP immediately after execution
      if(InpEnableIndividualTP)
      {
         ulong ticket = trade.ResultOrder();
         if(ticket > 0 && PositionSelectByTicket(ticket))
         {
            double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double tp = CalculateIndividualTP(entryPrice, false);
            trade.PositionModify(ticket, 0, tp);
         }
      }
   }
}

//+------------------------------------------------------------------+
// ORDER PLACEMENT FUNCTIONS
//+------------------------------------------------------------------+

bool PlaceBuyOrder(int level, double price)
{
   double lotSize = NormalizeLot(CalculateLotSize(level));
   string comment = StringFormat("TORAMA_Grid_L%d", level);
   
   price = NormalizeDouble(MathRound(price / tickSize) * tickSize, dgt);
   
   // Calculate individual TP for pending order
   double tp = 0;
   if(InpEnableIndividualTP)
      tp = CalculateIndividualTP(price, true);
   
   if(trade.BuyStop(lotSize, price, sym, 0, tp, ORDER_TIME_GTC, 0, comment))
      return true;
   
   return false;
}

bool PlaceSellOrder(int level, double price)
{
   double lotSize = NormalizeLot(CalculateLotSize(level));
   string comment = StringFormat("TORAMA_Grid_L%d", level);
   
   price = NormalizeDouble(MathRound(price / tickSize) * tickSize, dgt);
   
   // Calculate individual TP for pending order
   double tp = 0;
   if(InpEnableIndividualTP)
      tp = CalculateIndividualTP(price, false);
   
   if(trade.SellStop(lotSize, price, sym, 0, tp, ORDER_TIME_GTC, 0, comment))
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
// UTILITY FUNCTIONS
//+------------------------------------------------------------------+

bool IsLevelTriggered(int level, bool isBuy)
{
   if(isBuy)
   {
      for(int i = 0; i < buyTriggeredCount; i++)
         if(triggeredBuyLevels[i] == level) return true;
   }
   else
   {
      for(int i = 0; i < sellTriggeredCount; i++)
         if(triggeredSellLevels[i] == level) return true;
   }
   return false;
}

void MarkLevelAsTriggered(int level, bool isBuy)
{
   if(isBuy)
   {
      if(!IsLevelTriggered(level, true) && buyTriggeredCount < ArraySize(triggeredBuyLevels))
         triggeredBuyLevels[buyTriggeredCount++] = level;
   }
   else
   {
      if(!IsLevelTriggered(level, false) && sellTriggeredCount < ArraySize(triggeredSellLevels))
         triggeredSellLevels[sellTriggeredCount++] = level;
   }
}

void TrackTriggeredLevels()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      int level = (int)MathRound((entryPrice - referencePrice) / gridGapPrice);
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      
      if(!IsLevelTriggered(level, isBuy))
         MarkLevelAsTriggered(level, isBuy);
   }
}

void UpdateEntryPriceTracking()
{
   bool foundBuy = false, foundSell = false;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      
      if(isBuy)
      {
         foundBuy = true;
         bool priceExists = false;
         for(int j = 0; j < buyEntryCount; j++)
         {
            if(MathAbs(buyEntryPrices[j] - entryPrice) < pt)
            {
               priceExists = true;
               break;
            }
         }
         if(!priceExists && buyEntryCount < ArraySize(buyEntryPrices))
            buyEntryPrices[buyEntryCount++] = entryPrice;
      }
      else
      {
         foundSell = true;
         bool priceExists = false;
         for(int j = 0; j < sellEntryCount; j++)
         {
            if(MathAbs(sellEntryPrices[j] - entryPrice) < pt)
            {
               priceExists = true;
               break;
            }
         }
         if(!priceExists && sellEntryCount < ArraySize(sellEntryPrices))
            sellEntryPrices[sellEntryCount++] = entryPrice;
      }
   }
}

bool PendingOrderExists(int level, bool isBuy)
{
   double targetPrice = referencePrice + (level * gridGapPrice);
   
   for(int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != sym || OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
      
      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if((isBuy && orderType != ORDER_TYPE_BUY_STOP) || (!isBuy && orderType != ORDER_TYPE_SELL_STOP)) continue;
      
      double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(orderPrice - targetPrice) < tickSize) return true;
   }
   return false;
}

bool PositionExistsAtLevel(int level, bool isBuy)
{
   double targetPrice = referencePrice + (level * gridGapPrice);
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      bool posIsBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      if(posIsBuy != isBuy) continue;
      
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(entryPrice - targetPrice) < gridGapPrice / 2) return true;
   }
   return false;
}

bool PositionExistsAtPrice(double price, bool isBuy)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      bool posIsBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      if(posIsBuy != isBuy) continue;
      
      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(entryPrice - price) < tickSize) return true;
   }
   return false;
}

void DeleteAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket <= 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != sym || OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
      
      trade.OrderDelete(ticket);
   }
}

int CountExistingPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetString(POSITION_SYMBOL) == sym && PositionGetInteger(POSITION_MAGIC) == magicNumber)
            count++;
   }
   return count;
}

int GetTotalPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetString(POSITION_SYMBOL) == sym && PositionGetInteger(POSITION_MAGIC) == magicNumber)
            count++;
   }
   return count;
}

double GetTotalProfit()
{
   double totalProfit = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return totalProfit;
}

//+------------------------------------------------------------------+
// RISK MANAGEMENT
//+------------------------------------------------------------------+

bool CheckGlobalTakeProfit()
{
   double totalProfit = GetTotalProfit();
   return (totalProfit >= InpGlobalTakeProfitUSD);
}

bool CheckMaxDrawdown()
{
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   peakBalance = MathMax(peakBalance, currentBalance);
   peakEquity = MathMax(peakEquity, currentEquity);
   
   double balanceDD = ((peakBalance - currentBalance) / peakBalance) * 100.0;
   double equityDD = ((peakEquity - currentEquity) / peakEquity) * 100.0;
   double maxDD = MathMax(balanceDD, equityDD);
   
   return (maxDD >= InpMaxDrawdownPercent);
}

void CheckDailyProfitTarget()
{
   if(InpDailyProfitTargetPercent <= 0) return;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime todayStart = StructToTime(dt);
   
   if(todayStart != lastDayCheck)
   {
      lastDayCheck = todayStart;
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyTargetReached = false;
   }
   
   if(dailyTargetReached) return;
   
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyProfit = currentBalance - dailyStartBalance;
   double dailyProfitPercent = (dailyProfit / dailyStartBalance) * 100.0;
   
   if(dailyProfitPercent >= InpDailyProfitTargetPercent)
   {
      dailyTargetReached = true;
      PrintFormat("╔════════════════════════════════════════════════════════════════╗");
      PrintFormat("║  DAILY PROFIT TARGET REACHED!");
      PrintFormat("║  Target: %.2f%% | Achieved: %.2f%%", InpDailyProfitTargetPercent, dailyProfitPercent);
      PrintFormat("║  Daily Profit: $%.2f", dailyProfit);
      PrintFormat("║  Trading paused until next day");
      PrintFormat("╚════════════════════════════════════════════════════════════════╝");
   }
}

void CheckReversalThreshold()
{
   int currentBuyLevels = 0, currentSellLevels = 0;
   
   for(int i = 0; i < buyTriggeredCount; i++)
      if(triggeredBuyLevels[i] != -999999) currentBuyLevels++;
   
   for(int i = 0; i < sellTriggeredCount; i++)
      if(triggeredSellLevels[i] != -999999) currentSellLevels++;
   
   peakBuyLevelsActivated = MathMax(peakBuyLevelsActivated, currentBuyLevels);
   peakSellLevelsActivated = MathMax(peakSellLevelsActivated, currentSellLevels);
   
   if(!reversalTriggered && currentBuyLevels >= InpReversalLevels)
   {
      reversalTriggered = true;
      PrintFormat("⚡ REVERSAL TRIGGERED: %d buy levels reached - closing buys", currentBuyLevels);
      ClosePositionsByType(true);
      peakBuyLevelsActivated = 0;
   }
   else if(!reversalTriggered && currentSellLevels >= InpReversalLevels)
   {
      reversalTriggered = true;
      PrintFormat("⚡ REVERSAL TRIGGERED: %d sell levels reached - closing sells", currentSellLevels);
      ClosePositionsByType(false);
      peakSellLevelsActivated = 0;
   }
   
   if(reversalTriggered && currentBuyLevels == 0 && currentSellLevels == 0)
      reversalTriggered = false;
}

void ClosePositionsByType(bool closeBuys)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      if(isBuy == closeBuys)
         trade.PositionClose(PositionGetTicket(i));
   }
}

//+------------------------------------------------------------------+
// DEBUG & LOGGING
//+------------------------------------------------------------------+

void PrintDebugCycleHistory()
{
   Print("═══════════════════════════════════════════════════════════════");
   Print("CYCLE HISTORY (Last 20 cycles):");
   Print("═══════════════════════════════════════════════════════════════");
   
   int startIdx = MathMax(0, totalCycleCount - 20);
   for(int i = startIdx; i < totalCycleCount; i++)
   {
      if(i >= ArraySize(cycleNetPL)) break;
      
      string typeStr = cycleType[i];
      double pl = cycleNetPL[i];
      string plSign = pl >= 0 ? "+" : "";
      
      PrintFormat("Cycle #%d | %s | P/L: %s$%.2f", 
                  i + 1, typeStr, plSign, pl);
   }
   
   Print("═══════════════════════════════════════════════════════════════");
   PrintFormat("Global TP Cycles: %d | Close All Cycles: %d | Total: %d", 
               globalTPCycleCount, closeAllCycleCount, totalCycleCount);
   PrintFormat("Individual TP Closes: %d", individualTPClosedCount);
   Print("═══════════════════════════════════════════════════════════════");
}

//+------------------------------------------------------------------+
// PANEL UI
//+------------------------------------------------------------------+

void UpdatePanelFast()
{
   if(TimeCurrent() - lastPanelUpdate < 1) return;
   lastPanelUpdate = TimeCurrent();
   
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double profit = GetTotalProfit();
   double dd = ((peakEquity - equity) / peakEquity) * 100.0;
   
   ObjSetS("Spr", DoubleToString(currentSpread / pt, 1));
   ObjSetS("Ref", DoubleToString(referencePrice, dgt));
   ObjSetS("Eq", "$" + Fmt(equity, 2));
   ObjSetS("Pk", "$" + Fmt(peakEquity, 2));
   ObjSetS("Gg", StringFormat("%.2f%%", InpGridGapPercent));
   
   ObjSetS("Tr", StringFormat("B:%d|S:%d", buyTriggeredCount, sellTriggeredCount));
   ObjSetS("Cyc", StringFormat("TP:%d|CA:%d|T:%d", globalTPCycleCount, closeAllCycleCount, totalCycleCount));
   
   if(debugMode)
      ObjSetS("DbgMode", "DEBUG: ON");
   else
      ObjSetS("DbgMode", "");
   
   if(InpEnableReversal)
      ObjSetS("Rev", StringFormat("Thr:%d|B:%d|S:%d", InpReversalLevels, peakBuyLevelsActivated, peakSellLevelsActivated));
   
   double nextBuyPrice = referencePrice + ((highestBuyLevel + 1) * gridGapPrice);
   double nextSellPrice = referencePrice + ((lowestSellLevel - 1) * gridGapPrice);
   
   ObjSetS("Nb", DoubleToString(nextBuyPrice, dgt));
   ObjSetS("Ns", DoubleToString(nextSellPrice, dgt));
   
   double buyLots = 0, sellLots = 0;
   int buyLevels = 0, sellLevels = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double lot = PositionGetDouble(POSITION_VOLUME);
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      {
         buyLots += lot;
         buyLevels++;
      }
      else
      {
         sellLots += lot;
         sellLevels++;
      }
   }
   
   ObjSetS("Bl", Fmt(buyLots, 2));
   ObjSetS("Sl", Fmt(sellLots, 2));
   ObjSetS("Bg", StringFormat("%d lvls", buyLevels));
   ObjSetS("Sg", StringFormat("%d lvls", sellLevels));
   
   ObjSetS("Pr", "$" + Fmt(profit, 2));
   ObjSetC("Pr", profit >= 0 ? clrLimeGreen : clrTomato);
   
   ObjSetS("Dd", StringFormat("%.2f%%", dd));
   ObjSetC("Dd", dd < InpMaxDrawdownPercent * 0.5 ? clrLimeGreen : dd < InpMaxDrawdownPercent * 0.8 ? clrOrange : clrRed);
   
   if(InpDailyProfitTargetPercent > 0)
   {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double dailyProfit = currentBalance - dailyStartBalance;
      double dailyProfitPercent = (dailyProfit / dailyStartBalance) * 100.0;
      
      ObjSetS("Daily", StringFormat("$%.2f (%.2f%%)", dailyProfit, dailyProfitPercent));
      ObjSetC("Daily", dailyProfit >= 0 ? clrLimeGreen : clrTomato);
   }
   
   ChartRedraw();
}

void CreatePanel()
{
   DeletePanel();
   
   int x = InpPanelX, y = InpPanelY;
   int w = 340, lh = 20;
   
   CreateRect("BG", x, y, w, 420, InpPanelColor); y += 10;
   
   CreateRect("Hdr", x + 10, y, w - 20, 32, InpHeaderColor, false);
   CreateTxt("Title", x + 28, y + 8, "🔶 TORAMA GRID v3.08", clrWhite, 11, "Arial Black");
   CreateTxt("IndTP", x + w - 70, y + 10, InpEnableIndividualTP ? "IndTP✓" : "", clrLimeGreen, 9, "Arial Bold"); 
   y += 38;
   
   int x1 = x + 15, x2 = x + 170;
   
   CreateTxt("DirL", x1, y, "Direction:", C'120,120,120', 9);
   string dirText = InpTradeDirection == DIRECTION_BUY_ONLY ? "BUY⬆" : InpTradeDirection == DIRECTION_SELL_ONLY ? "SELL⬇" : "BOTH↕";
   CreateTxt("Dir", x2 + 32, y, dirText, clrWhite, 9, "Arial Bold"); y += lh;
   
   CreateTxt("SyL", x1, y, "Symbol:", C'120,120,120', 9);
   CreateTxt("Sym", x1 + 52, y, sym, clrWhite, 9, "Arial Bold");
   CreateTxt("MgL", x2, y, "Magic:", C'120,120,120', 9);
   CreateTxt("Mag", x2 + 45, y, IntegerToString(magicNumber), clrWhite, 8); y += lh;
   
   CreateTxt("LoL", x1, y, "Lot:", C'120,120,120', 9);
   CreateTxt("Lot", x1 + 32, y, StringFormat("%.2f", effectiveInitialLotSize), clrWhite, 8, "Arial Bold");
   CreateTxt("SpL", x1 + 90, y, "Spr:", C'120,120,120', 9);
   CreateTxt("Spr", x1 + 120, y, "0.0", clrWhite, 8, "Arial Bold");
   CreateTxt("ReL", x2 + 20, y, "Ref:", C'120,120,120', 9);
   CreateTxt("Ref", x2 + 50, y, "0.00000", clrWhite, 8, "Arial Bold"); y += lh;
   
   CreateTxt("EqL", x1, y, "Eq:", C'120,120,120', 9);
   CreateTxt("Eq", x1 + 28, y, "$0.00", C'240,248,255', 8, "Arial Bold");
   CreateTxt("PkL", x1 + 100, y, "Pk:", C'120,120,120', 9);
   CreateTxt("Pk", x1 + 125, y, "$0.00", clrGold, 8, "Arial Bold");
   CreateTxt("GgL", x2 + 20, y, "Gap:", C'120,120,120', 9);
   CreateTxt("Gg", x2 + 53, y, "0.00%", clrWhite, 8, "Arial Bold"); y += lh;
   
   CreateTxt("TrL", x1, y, "Trig:", clrOrange, 9, "Arial Bold");
   CreateTxt("Tr", x1 + 38, y, "B:0|S:0", clrOrange, 8, "Arial Bold");
   CreateTxt("CyL", x1 + 130, y, "Cyc:", clrLimeGreen, 9, "Arial Bold");
   CreateTxt("Cyc", x1 + 165, y, "TP:0|CA:0|T:0", clrLimeGreen, 8, "Arial Bold"); y += lh;
   
   CreateTxt("MoL", x1, y, "Mode:", C'120,120,120', 9);
   string modeText = useMarketOrders ? (InpForceMarketOrders ? "MARKET⚡" : "MARKET") : "PENDING";
   color modeColor = useMarketOrders ? (InpForceMarketOrders ? clrOrange : clrYellow) : clrLimeGreen;
   CreateTxt("Mo", x1 + 45, y, modeText, modeColor, 9, "Arial Bold"); 
   CreateTxt("DbgMode", x2, y, "", clrYellow, 9, "Arial Bold"); y += lh;
   
   if(InpEnableReversal)
   {
      CreateTxt("RevL", x1, y, "Rev:", clrCyan, 9, "Arial Bold");
      CreateTxt("Rev", x1 + 35, y, StringFormat("Thr:%d|B:%d|S:%d", InpReversalLevels, peakBuyLevelsActivated, peakSellLevelsActivated), 
                clrCyan, 8, "Arial Bold"); y += lh;
   }
   
   CreateRect("S2", x + 8, y, w - 16, 1, clrDimGray, false); y += 7;
   
   CreateTxt("NbL", x1, y, "Next Buy:", clrDodgerBlue, 9, "Arial Bold");
   CreateTxt("Nb", x1 + 65, y, "---", clrDodgerBlue, 9, "Arial Bold");
   CreateTxt("NsL", x2, y, "Next Sell:", clrTomato, 9, "Arial Bold");
   CreateTxt("Ns", x2 + 65, y, "---", clrTomato, 9, "Arial Bold"); y += lh;
   
   CreateTxt("BlL", x1, y, "Buy Lots:", clrDodgerBlue, 9, "Arial Bold");
   CreateTxt("Bl", x1 + 65, y, "0.00", clrDodgerBlue, 9, "Arial Bold");
   CreateTxt("SlL", x2, y, "Sell Lots:", clrTomato, 9, "Arial Bold");
   CreateTxt("Sl", x2 + 65, y, "0.00", clrTomato, 9, "Arial Bold"); y += lh;
   
   CreateTxt("BgL", x1, y, "Buy:", clrDodgerBlue, 9, "Arial Bold");
   CreateTxt("Bg", x1 + 35, y, "0 lvls", clrDodgerBlue, 9, "Arial Bold");
   CreateTxt("SgL", x2, y, "Sell:", clrTomato, 9, "Arial Bold");
   CreateTxt("Sg", x2 + 35, y, "0 lvls", clrTomato, 9, "Arial Bold"); y += lh;
   
   CreateRect("S3", x + 8, y, w - 16, 1, clrDimGray, false); y += 7;
   
   CreateTxt("PrL", x1, y, "Profit:", C'120,120,120', 9);
   CreateTxt("Pr", x1 + 50, y, "$0.00", clrLimeGreen, 10, "Arial Black");
   CreateTxt("TpL", x2, y, "Target:", C'120,120,120', 9);
   CreateTxt("Tp", x2 + 50, y, "$" + Fmt(InpGlobalTakeProfitUSD, 0), clrGold, 9, "Arial Bold"); y += lh;
   
   CreateTxt("DdL", x1, y, "DD:", C'120,120,120', 9);
   CreateTxt("Dd", x1 + 50, y, "0.00%", clrWhite, 9, "Arial Bold");
   CreateTxt("MdL", x2, y, "Max DD:", C'120,120,120', 9);
   CreateTxt("Md", x2 + 50, y, StringFormat("%.1f%%", InpMaxDrawdownPercent), clrOrangeRed, 9, "Arial Bold"); y += lh;
   
   if(InpDailyProfitTargetPercent > 0)
   {
      CreateTxt("DailyL", x1, y, "Daily:", C'120,120,120', 9);
      CreateTxt("Daily", x1 + 50, y, "$0.00 (0.00%)", clrLimeGreen, 9, "Arial Bold");
      CreateTxt("DailyTgtL", x2, y, "Tgt:", C'120,120,120', 9);
      CreateTxt("DailyTgt", x2 + 50, y, StringFormat("%.1f%%", InpDailyProfitTargetPercent), clrGold, 9, "Arial Bold"); y += lh;
   }
   
   y += 6;
   CreateRect("S4", x + 8, y, w - 16, 1, clrDimGray, false); y += 8;
   
   CreateBtn("BtnCloseAll", x + 12, y, 103, 26, "CLOSE ALL", clrWhite, clrCrimson);
   CreateBtn("BtnPause", x + 121, y, 103, 26, "PAUSE", clrWhite, C'255,152,0');
   CreateBtn("BtnTakeProfit", x + 230, y, 98, 26, "TAKE TP", clrWhite, C'34,139,34'); y += 30;
   CreateBtn("BtnResetRef", x + 12, y, 316, 26, "RESET REFERENCE", clrWhite, C'65,105,225'); y += 32;
   
   CreateTxt("Brand", x + w - 130, y - 6, "TORAMA CAPITAL", clrGold, 9, "Arial Black");
   CreateTxt("Debug", x + 12, y - 6, "Press 'D' for Debug", C'80,80,80', 7);
   ChartRedraw();
}

void DeletePanel() { ObjectsDeleteAll(0, panelPrefix); }

void CreateRect(string n, int x, int y, int w, int h, color c, bool b = true)
{
   n = panelPrefix + n;
   if(ObjectFind(0, n) >= 0) ObjectDelete(0, n);
   ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, c);
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clrDimGray);
   ObjectSetInteger(0, n, OBJPROP_BACK, b);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
}

void CreateTxt(string n, int x, int y, string t, color c, int sz = 8, string f = "Arial")
{
   n = panelPrefix + n;
   if(ObjectFind(0, n) >= 0) ObjectDelete(0, n);
   ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, n, OBJPROP_TEXT, t);
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, sz);
   ObjectSetString(0, n, OBJPROP_FONT, f);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
}

void CreateBtn(string n, int x, int y, int w, int h, string t, color tc, color bc)
{
   n = panelPrefix + n;
   if(ObjectFind(0, n) >= 0) ObjectDelete(0, n);
   ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE, w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE, h);
   ObjectSetString(0, n, OBJPROP_TEXT, t);
   ObjectSetInteger(0, n, OBJPROP_COLOR, tc);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR, bc);
   ObjectSetInteger(0, n, OBJPROP_BORDER_COLOR, clrBlack);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, n, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
}

void ObjSetS(string n, string v) { ObjectSetString(0, panelPrefix + n, OBJPROP_TEXT, v); }
void ObjSetC(string n, color c) { ObjectSetInteger(0, panelPrefix + n, OBJPROP_COLOR, c); }

string Fmt(double v, int d = 2)
{
   string r = "", s = "";
   if(v < 0) { s = "-"; v = MathAbs(v); }
   long ip = (long)MathFloor(v);
   double dp = v - ip;
   string is = IntegerToString(ip);
   int len = StringLen(is);
   for(int i = 0; i < len; i++)
   {
      if(i > 0 && (len - i) % 3 == 0) r += ",";
      r += StringSubstr(is, i, 1);
   }
   if(d > 0)
   {
      string ds = DoubleToString(dp, d);
      int pos = StringFind(ds, ".");
      if(pos >= 0) r += StringSubstr(ds, pos);
   }
   return s + r;
}
//+------------------------------------------------------------------+
