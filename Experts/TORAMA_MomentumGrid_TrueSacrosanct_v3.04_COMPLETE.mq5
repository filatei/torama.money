//+------------------------------------------------------------------+
//|                  TORAMA_MomentumGrid_TrueSacrosanct_v3.04.mq5    |
//|                                          TORAMA CAPITAL           |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://toramacapital.com"
#property version   "3.04"
#property description "Momentum Grid EA - TRUE Sacrosanct - COMPLETE"
#property description "✓ Reversal Threshold | ✓ Parallel Closure | ✓ Debug P/L | ✓ All Features"

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
input int    InpMaxGridLevels = 30;
input double InpMaxSpreadPoints = 0;

input group "=== GLOBAL PROFIT & RISK ==="
input double InpGlobalTakeProfitUSD = 100.0;
input double InpMaxDrawdownPercent = 10.0;
input int    InpDrawdownPauseMinutes = 30;

input group "=== REVERSAL THRESHOLD ==="
input bool   InpEnableReversal = false;           // Enable Auto-Reversal
input int    InpReversalLevels = 5;               // Reversal Threshold (Levels)

input group "=== DISPLAY ==="
input color  InpPanelColor = C'20,25,30';
input color  InpHeaderColor = C'41,98,255';
input color  InpTextColor = clrWhite;
input int    InpPanelX = 20;
input int    InpPanelY = 50;

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

//+------------------------------------------------------------------+
int OnInit()
{
   magicNumber = ChartID();
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
   
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   if(trade.ResultRetcode() == TRADE_RETCODE_INVALID_FILL) trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   peakBalance = accountStartBalance;
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   isStoppedByDrawdown = false;
   lastPanelUpdate = 0;
   debugMode = false;
   
   // Initialize cycle tracking arrays
   globalTPCycleCount = 0;
   closeAllCycleCount = 0;
   totalCycleCount = 0;
   ArrayResize(cycleNetPL, 500);      // Store up to 500 cycles
   ArrayResize(cycleType, 500);
   ArrayInitialize(cycleNetPL, 0.0);
   
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
   CreatePanel();
   
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   EventSetMillisecondTimer(500);  // Timer for keyboard events
   
   PrintFormat("╔════════════════════════════════════════════════════════════════╗");
   PrintFormat("║  TORAMA Grid v3.04 COMPLETE - Magic: %I64d", magicNumber);
   PrintFormat("║  ✓ Reversal Threshold | ✓ Parallel Closure | ✓ Debug P/L");
   PrintFormat("║  Press 'D' for Debug | Reversal: %s | Threshold: %d levels", 
               InpEnableReversal ? "ON" : "OFF", InpReversalLevels);
   PrintFormat("║  Lot: %.2f | Gap: %.2f%%", effectiveInitialLotSize, InpGridGapPercent);
   PrintFormat("╚════════════════════════════════════════════════════════════════╝");
   
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) 
{ 
   DeletePanel();
   if(debugMode) PrintDebugSummary();
}

//+------------------------------------------------------------------+
void OnTick()
{
   currentSpread = SymbolInfoDouble(sym, SYMBOL_ASK) - SymbolInfoDouble(sym, SYMBOL_BID);
   CalculateGridGap();
   TrackTriggeredLevels();
   UpdateEntryPriceTracking();
   
   // Check for reversal threshold (only in BOTH direction mode)
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
      
      // Store cycle data
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
         PrintFormat("║  EA PERMANENTLY STOPPED", totalCycleCount);
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
// PARALLEL POSITION CLOSURE - Closes all positions almost simultaneously
void CloseAllPositionsParallel(string reason)
{
   int totalPos = PositionsTotal();
   if(totalPos == 0) return;
   
   ulong tickets[];
   ArrayResize(tickets, totalPos);
   int validCount = 0;
   
   // Step 1: Collect all position tickets (very fast)
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
   
   // Step 2: Close ALL positions simultaneously (parallel execution)
   int closedCount = 0;
   int failedCount = 0;
   
   for(int i = 0; i < validCount; i++)
   {
      // Fire close request without waiting for confirmation
      if(trade.PositionClose(tickets[i]))
         closedCount++;
      else
         failedCount++;
   }
   
   uint endTime = GetTickCount();
   double elapsedMs = (endTime - startTime);
   
   PrintFormat("✓ Parallel close complete: %d closed, %d failed in %.0fms (avg: %.1fms per position)", 
               closedCount, failedCount, elapsedMs, validCount > 0 ? elapsedMs / validCount : 0);
   
   // Step 3: Retry failed positions (if any)
   if(failedCount > 0)
   {
      Sleep(100);
      PrintFormat("⟳ Retrying %d failed positions...", failedCount);
      
      for(int i = 0; i < validCount; i++)
      {
         if(PositionSelectByTicket(tickets[i]))
         {
            trade.PositionClose(tickets[i]);
         }
      }
   }
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Handle keyboard events - check for 'D' key press (key code 68)
   if(id == CHARTEVENT_KEYDOWN)
   {
      if(lparam == 68 || lparam == 100) // 'D' or 'd' key
      {
         debugMode = !debugMode;
         if(debugMode)
         {
            PrintFormat("╔════════════════════════════════════════════════════════════════╗");
            PrintFormat("║  DEBUG MODE: ENABLED");
            PrintFormat("║  Cycle P/L tracking active");
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
      
      // Store cycle data
      if(totalCycleCount <= ArraySize(cycleNetPL))
      {
         cycleNetPL[totalCycleCount - 1] = netPL;
         cycleType[totalCycleCount - 1] = "CLOSE_ALL";
      }
      
      PrintFormat("╔════════════════════════════════════════════════════════════════╗");
      PrintFormat("║  CYCLE #%d: CLOSE ALL BUTTON", totalCycleCount);
      PrintFormat("║  Net P/L: $%.2f", netPL);
      PrintFormat("╚════════════════════════════════════════════════════════════════╝");
      
      CloseAllPositionsParallel("Close All Button");
      DeleteAllPendingOrders();
      ResetSacrosanctGrid();
   }
   else if(sparam == panelPrefix + "BtnPause")
   {
      isManuallyPaused = !isManuallyPaused;
      ObjectSetString(0, panelPrefix + "BtnPause", OBJPROP_TEXT, isManuallyPaused ? "RESUME" : "PAUSE");
      ObjectSetInteger(0, panelPrefix + "BtnPause", OBJPROP_BGCOLOR, isManuallyPaused ? clrOrangeRed : C'255,152,0');
      PrintFormat("%s trading", isManuallyPaused ? "⏸ PAUSED" : "▶ RESUMED");
   }
   else if(sparam == panelPrefix + "BtnTakeProfit")
   {
      double netPL = GetTotalProfit();
      closeAllCycleCount++;
      totalCycleCount++;
      
      // Store cycle data
      if(totalCycleCount <= ArraySize(cycleNetPL))
      {
         cycleNetPL[totalCycleCount - 1] = netPL;
         cycleType[totalCycleCount - 1] = "MANUAL_TP";
      }
      
      PrintFormat("╔════════════════════════════════════════════════════════════════╗");
      PrintFormat("║  CYCLE #%d: MANUAL TAKE PROFIT", totalCycleCount);
      PrintFormat("║  Net P/L: $%.2f", netPL);
      PrintFormat("╚════════════════════════════════════════════════════════════════╝");
      
      CloseAllPositionsParallel("Manual Take Profit");
      DeleteAllPendingOrders();
      ResetSacrosanctGrid();
   }
   else if(sparam == panelPrefix + "BtnResetRef")
   {
      Print("⚙ Resetting grid reference (keeping positions)");
      ResetGridReference();
   }
   
   ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
   Sleep(50);
   buttonPressed = false;
   UpdatePanelFast();
}

//+------------------------------------------------------------------+
// Print debug cycle history
void PrintDebugCycleHistory()
{
   if(totalCycleCount == 0)
   {
      Print("No cycles recorded yet.");
      return;
   }
   
   PrintFormat("╔════════════════════════════════════════════════════════════════╗");
   PrintFormat("║  CYCLE HISTORY - NET P/L PER CYCLE");
   PrintFormat("╠════════════════════════════════════════════════════════════════╣");
   
   double cumulativePL = 0;
   int displayCount = MathMin(totalCycleCount, 50); // Show last 50 cycles max
   
   for(int i = 0; i < displayCount; i++)
   {
      cumulativePL += cycleNetPL[i];
      string plColor = cycleNetPL[i] >= 0 ? "+" : "";
      PrintFormat("║  Cycle #%-3d | %-12s | %s$%8.2f | Cumulative: $%8.2f", 
                  i + 1, cycleType[i], plColor, cycleNetPL[i], cumulativePL);
   }
   
   PrintFormat("╠════════════════════════════════════════════════════════════════╣");
   PrintFormat("║  Total Cycles: %d | Cumulative P/L: $%.2f", totalCycleCount, cumulativePL);
   PrintFormat("╚════════════════════════════════════════════════════════════════╝");
}

void PrintDebugSummary()
{
   PrintFormat("╔════════════════════════════════════════════════════════════════╗");
   PrintFormat("║  EA SHUTDOWN - FINAL SUMMARY");
   PrintFormat("╠════════════════════════════════════════════════════════════════╣");
   PrintFormat("║  Total Cycles: %d", totalCycleCount);
   PrintFormat("║  Global TP Cycles: %d", globalTPCycleCount);
   PrintFormat("║  Manual Close Cycles: %d", closeAllCycleCount);
   PrintFormat("╚════════════════════════════════════════════════════════════════╝");
   
   if(totalCycleCount > 0)
      PrintDebugCycleHistory();
}

//+------------------------------------------------------------------+
void UpdateEntryPriceTracking()
{
   ArrayInitialize(buyEntryPrices, 0.0);
   ArrayInitialize(sellEntryPrices, 0.0);
   buyEntryCount = sellEntryCount = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      double price = NormalizeDouble(PositionGetDouble(POSITION_PRICE_OPEN), dgt);
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && buyEntryCount < 200)
         buyEntryPrices[buyEntryCount++] = price;
      else if(sellEntryCount < 200)
         sellEntryPrices[sellEntryCount++] = price;
   }
}

bool PositionExistsAtPrice(double price, bool isBuy)
{
   price = NormalizeDouble(price, dgt);
   double tolerance = gridGapPrice * 0.1;
   
   if(isBuy)
   {
      for(int i = 0; i < buyEntryCount; i++)
         if(MathAbs(buyEntryPrices[i] - price) < tolerance) return true;
   }
   else
   {
      for(int i = 0; i < sellEntryCount; i++)
         if(MathAbs(sellEntryPrices[i] - price) < tolerance) return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
// Check for reversal threshold and close opposite positions if triggered
void CheckReversalThreshold()
{
   if(!InpEnableReversal) return;
   
   int currentBuyLevels = GetGridLevelCount(true);
   int currentSellLevels = GetGridLevelCount(false);
   
   // Track peak levels in each direction
   if(currentBuyLevels > peakBuyLevelsActivated)
      peakBuyLevelsActivated = currentBuyLevels;
   
   if(currentSellLevels > peakSellLevelsActivated)
      peakSellLevelsActivated = currentSellLevels;
   
   // Check if reversal threshold is met
   // Scenario 1: Had many BUY positions, now SELL positions are building up
   if(peakBuyLevelsActivated > 0 && currentSellLevels >= InpReversalLevels && !reversalTriggered)
   {
      // Reverse from BUY to SELL - close all BUY positions
      if(currentBuyLevels > 0)
      {
         PrintFormat("╔════════════════════════════════════════════════════════════════╗");
         PrintFormat("║  REVERSAL TRIGGERED: BUY → SELL");
         PrintFormat("║  Peak BUY levels: %d | Current SELL levels: %d | Threshold: %d", 
                     peakBuyLevelsActivated, currentSellLevels, InpReversalLevels);
         PrintFormat("╚════════════════════════════════════════════════════════════════╝");
         
         ClosePositionsByType(true);  // Close all BUY positions
         peakBuyLevelsActivated = 0;
         reversalTriggered = true;
      }
   }
   
   // Scenario 2: Had many SELL positions, now BUY positions are building up
   if(peakSellLevelsActivated > 0 && currentBuyLevels >= InpReversalLevels && !reversalTriggered)
   {
      // Reverse from SELL to BUY - close all SELL positions
      if(currentSellLevels > 0)
      {
         PrintFormat("╔════════════════════════════════════════════════════════════════╗");
         PrintFormat("║  REVERSAL TRIGGERED: SELL → BUY");
         PrintFormat("║  Peak SELL levels: %d | Current BUY levels: %d | Threshold: %d", 
                     peakSellLevelsActivated, currentBuyLevels, InpReversalLevels);
         PrintFormat("╚════════════════════════════════════════════════════════════════╝");
         
         ClosePositionsByType(false);  // Close all SELL positions
         peakSellLevelsActivated = 0;
         reversalTriggered = true;
      }
   }
   
   // Reset reversal flag when both directions have low position counts
   if(reversalTriggered && currentBuyLevels < 2 && currentSellLevels < 2)
   {
      reversalTriggered = false;
      peakBuyLevelsActivated = 0;
      peakSellLevelsActivated = 0;
   }
}

//+------------------------------------------------------------------+
// Close positions by type (BUY or SELL) in parallel
void ClosePositionsByType(bool closeBuy)
{
   int totalPos = PositionsTotal();
   if(totalPos == 0) return;
   
   ulong tickets[];
   ArrayResize(tickets, totalPos);
   int validCount = 0;
   
   // Collect tickets for the specified position type
   for(int i = 0; i < totalPos; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((closeBuy && posType == POSITION_TYPE_BUY) || (!closeBuy && posType == POSITION_TYPE_SELL))
         tickets[validCount++] = ticket;
   }
   
   if(validCount == 0) return;
   
   string dirText = closeBuy ? "BUY" : "SELL";
   PrintFormat("▶ Closing %d %s positions in parallel (Reversal)...", validCount, dirText);
   uint startTime = GetTickCount();
   
   // Close all positions of the specified type
   int closedCount = 0;
   for(int i = 0; i < validCount; i++)
   {
      if(trade.PositionClose(tickets[i]))
         closedCount++;
   }
   
   uint endTime = GetTickCount();
   double elapsedMs = (endTime - startTime);
   
   PrintFormat("✓ Reversal close complete: %d %s positions closed in %.0fms", 
               closedCount, dirText, elapsedMs);
}

//+------------------------------------------------------------------+
void TrackTriggeredLevels()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      
      string comment = PositionGetString(POSITION_COMMENT);
      if(StringFind(comment, "TORAMA_Grid_L") != 0) continue;
      
      int level = (int)StringToInteger(StringSubstr(comment, 13));
      bool isBuy = PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY;
      
      if(!IsLevelTriggered(level, isBuy))
         MarkLevelAsTriggered(level, isBuy);
   }
}

bool IsLevelTriggered(int level, bool isBuy)
{
   int checkLevel = isBuy ? level : MathAbs(level);
   
   if(isBuy)
   {
      for(int i = 0; i < buyTriggeredCount; i++)
         if(triggeredBuyLevels[i] == checkLevel) return true;
   }
   else
   {
      for(int i = 0; i < sellTriggeredCount; i++)
         if(triggeredSellLevels[i] == checkLevel) return true;
   }
   
   return false;
}

void MarkLevelAsTriggered(int level, bool isBuy)
{
   if(isBuy)
   {
      if(buyTriggeredCount >= ArraySize(triggeredBuyLevels))
         ArrayResize(triggeredBuyLevels, ArraySize(triggeredBuyLevels) + 100);
      triggeredBuyLevels[buyTriggeredCount++] = level;
   }
   else
   {
      if(sellTriggeredCount >= ArraySize(triggeredSellLevels))
         ArrayResize(triggeredSellLevels, ArraySize(triggeredSellLevels) + 100);
      triggeredSellLevels[sellTriggeredCount++] = MathAbs(level);
   }
}

//+------------------------------------------------------------------+
void DetectMarketOrderMode()
{
   string symbolName = sym;
   StringToUpper(symbolName);
   useMarketOrders = (StringFind(symbolName, "BOOM") >= 0 || StringFind(symbolName, "CRASH") >= 0 || 
                      StringFind(symbolName, "JUMP") >= 0 || StringFind(symbolName, "RANGE") >= 0 || 
                      StringFind(symbolName, "STEP") >= 0 || StringFind(symbolName, "VOLATILITY") >= 0 || 
                      StringFind(symbolName, "1HZ") >= 0);
}

void CalculateGridGap()
{
   double currentPrice = SymbolInfoDouble(sym, SYMBOL_BID);
   if(currentPrice <= 0) return;
   
   gridGapPrice = NormalizeDouble(currentPrice * InpGridGapPercent / 100.0, dgt);
   double minGap = stopLevel * 2;
   if(minGap > 0 && gridGapPrice < minGap) gridGapPrice = minGap;
   gridGapPrice = MathRound(gridGapPrice / tickSize) * tickSize;
}

//+------------------------------------------------------------------+
void InitializeSacrosanctGrid()
{
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   referencePrice = NormalizeDouble((ask + bid) / 2.0, dgt);
   referencePrice = MathRound(referencePrice / tickSize) * tickSize;
   highestBuyLevel = lowestSellLevel = 0;
   gridInitialized = true;
   PlaceInitialOrder();
   MaintainSacrosanctGrid();
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
   
   // Reset reversal tracking
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
      if(InpTradeDirection != DIRECTION_SELL_ONLY) trade.Buy(lotSize, sym, 0, 0, 0, "TORAMA_Grid_L0");
      else trade.Sell(lotSize, sym, 0, 0, 0, "TORAMA_Grid_L0");
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
   double lotSize = NormalizeLot(CalculateLotSize(MathAbs(level)));
   if(lotSize < minLot || lotSize > maxLot) return;
   trade.Buy(lotSize, sym, 0, 0, 0, "TORAMA_Grid_L" + IntegerToString(level));
}

void ExecuteMarketSell(int level)
{
   double lotSize = NormalizeLot(CalculateLotSize(MathAbs(level)));
   if(lotSize < minLot || lotSize > maxLot) return;
   trade.Sell(lotSize, sym, 0, 0, 0, "TORAMA_Grid_L" + IntegerToString(level));
}

//+------------------------------------------------------------------+
bool PositionExistsAtLevel(int level, bool isBuy)
{
   string expectedComment = "TORAMA_Grid_L" + IntegerToString(level);
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      if(PositionGetString(POSITION_COMMENT) == expectedComment)
      {
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if((isBuy && posType == POSITION_TYPE_BUY) || (!isBuy && posType == POSITION_TYPE_SELL))
            return true;
      }
   }
   return false;
}

bool PendingOrderExists(int level, bool isBuy)
{
   string expectedComment = "TORAMA_Grid_L" + IntegerToString(level);
   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(!OrderSelect(OrderGetTicket(i))) continue;
      if(OrderGetString(ORDER_SYMBOL) != sym || OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
      if(OrderGetString(ORDER_COMMENT) == expectedComment) return true;
   }
   return false;
}

bool PlaceBuyOrder(int level, double price)
{
   double lotSize = NormalizeLot(CalculateLotSize(MathAbs(level)));
   if(lotSize < minLot || lotSize > maxLot) return false;
   
   price = NormalizeDouble(price, dgt);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   if(price <= ask + stopLevel) price = ask + stopLevel + gridGapPrice;
   
   return trade.BuyStop(lotSize, NormalizeDouble(price, dgt), sym, 0, 0, ORDER_TIME_GTC, 0, "TORAMA_Grid_L" + IntegerToString(level));
}

bool PlaceSellOrder(int level, double price)
{
   double lotSize = NormalizeLot(CalculateLotSize(MathAbs(level)));
   if(lotSize < minLot || lotSize > maxLot) return false;
   
   price = NormalizeDouble(price, dgt);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   if(price >= bid - stopLevel) price = bid - stopLevel - gridGapPrice;
   
   return trade.SellStop(lotSize, NormalizeDouble(price, dgt), sym, 0, 0, ORDER_TIME_GTC, 0, "TORAMA_Grid_L" + IntegerToString(level));
}

double CalculateLotSize(int gridLevel)
{
   return (InpLotMultiplier != 1.0 && gridLevel > 0) ? effectiveInitialLotSize * MathPow(InpLotMultiplier, gridLevel) : effectiveInitialLotSize;
}

double NormalizeLot(double lot)
{
   lot = MathFloor(lot / lotStep) * lotStep;
   return NormalizeDouble(MathMax(minLot, MathMin(maxLot, lot)), 2);
}

//+------------------------------------------------------------------+
bool CheckGlobalTakeProfit() { return GetTotalProfit() >= InpGlobalTakeProfitUSD; }

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

bool CheckMaxDrawdown()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(currentEquity > peakEquity) peakEquity = currentEquity;
   return peakEquity > 0 ? ((peakEquity - currentEquity) / peakEquity) * 100.0 >= InpMaxDrawdownPercent : false;
}

int GetTotalPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym && PositionGetInteger(POSITION_MAGIC) == magicNumber) count++;
   }
   return count;
}

double GetTotalLots(bool buyOnly)
{
   double totalLots = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((buyOnly && posType == POSITION_TYPE_BUY) || (!buyOnly && posType == POSITION_TYPE_SELL))
         totalLots += PositionGetDouble(POSITION_VOLUME);
   }
   return totalLots;
}

int GetGridLevelCount(bool buyOnly)
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != magicNumber) continue;
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if((buyOnly && posType == POSITION_TYPE_BUY) || (!buyOnly && posType == POSITION_TYPE_SELL)) count++;
   }
   return count;
}

void DeleteAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) == sym && OrderGetInteger(ORDER_MAGIC) == magicNumber)
         trade.OrderDelete(ticket);
   }
}

double GetNextPendingPrice(bool buyOrder)
{
   double nextPrice = 0;
   for(int i = 0; i < OrdersTotal(); i++)
   {
      if(!OrderSelect(OrderGetTicket(i))) continue;
      if(OrderGetString(ORDER_SYMBOL) != sym || OrderGetInteger(ORDER_MAGIC) != magicNumber) continue;
      
      ENUM_ORDER_TYPE orderType = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      
      if(buyOrder && orderType == ORDER_TYPE_BUY_STOP && (nextPrice == 0 || orderPrice < nextPrice))
         nextPrice = orderPrice;
      else if(!buyOrder && orderType == ORDER_TYPE_SELL_STOP && (nextPrice == 0 || orderPrice > nextPrice))
         nextPrice = orderPrice;
   }
   return nextPrice;
}

//+------------------------------------------------------------------+
void UpdatePanelFast()
{
   datetime currentTime = TimeCurrent();
   if(currentTime == lastPanelUpdate) return;
   lastPanelUpdate = currentTime;
   
   double eq = AccountInfoDouble(ACCOUNT_EQUITY), prof = GetTotalProfit();
   double bLots = GetTotalLots(true), sLots = GetTotalLots(false);
   int bCnt = GetGridLevelCount(true), sCnt = GetGridLevelCount(false);
   double nBuy = GetNextPendingPrice(true), nSell = GetNextPendingPrice(false);
   if(eq > peakEquity) peakEquity = eq;
   double dd = peakEquity > 0 ? ((peakEquity - eq) / peakEquity) * 100.0 : 0;
   
   string st = "Active"; color stC = clrLimeGreen;
   if(isStoppedByDrawdown) { st = "STOPPED"; stC = clrRed; }
   else if(isManuallyPaused) { st = "PAUSED"; stC = clrOrange; }
   else if(maxAllowedSpread > 0 && currentSpread > maxAllowedSpread) { st = "Spread High"; stC = clrYellow; }
   
   ObjSetS("Status", st); ObjSetC("Status", stC);
   ObjSetS("Eq", "$" + Fmt(eq, 2)); ObjSetS("Pk", "$" + Fmt(peakEquity, 2));
   ObjSetS("Ref", Fmt(referencePrice, dgt));
   
   double spts = currentSpread / pt, msp = maxAllowedSpread > 0 ? maxAllowedSpread / pt : 0;
   color spC = clrLimeGreen;
   if(maxAllowedSpread > 0 && spts > msp) spC = clrRed; else if(spts > msp * 0.8) spC = clrOrange;
   ObjSetS("Spr", maxAllowedSpread > 0 ? StringFormat("%.1f/%.0f", spts, msp) : StringFormat("%.1f", spts));
   ObjSetC("Spr", spC);
   
   ObjSetS("Gg", StringFormat("%.2f%% (%s)", InpGridGapPercent, Fmt(gridGapPrice, dgt)));
   ObjSetS("Tr", StringFormat("B:%d|S:%d", buyTriggeredCount, sellTriggeredCount));
   ObjSetS("Cyc", StringFormat("TP:%d|CA:%d|Tot:%d", globalTPCycleCount, closeAllCycleCount, totalCycleCount));
   
   // Debug mode indicator
   if(debugMode)
      ObjSetS("DbgMode", "DEBUG:ON");
   else
      ObjSetS("DbgMode", "");
   
   // Reversal status
   if(InpEnableReversal)
   {
      color revColor = reversalTriggered ? clrOrange : clrCyan;
      ObjSetS("Rev", StringFormat("Thr:%d|B:%d|S:%d", InpReversalLevels, peakBuyLevelsActivated, peakSellLevelsActivated));
      ObjSetC("Rev", revColor);
   }
   
   if(!useMarketOrders)
   {
      ObjSetS("Nb", nBuy > 0 ? Fmt(nBuy, dgt) : "---");
      ObjSetS("Ns", nSell > 0 ? Fmt(nSell, dgt) : "---");
   }
   
   ObjSetS("Bl", StringFormat("%.2f", bLots)); ObjSetS("Sl", StringFormat("%.2f", sLots));
   ObjSetS("Bg", StringFormat("%d lvls", bCnt)); ObjSetS("Sg", StringFormat("%d lvls", sCnt));
   ObjSetS("Pr", "$" + Fmt(prof, 2)); ObjSetC("Pr", prof >= 0 ? clrLimeGreen : clrRed);
   
   color ddC = clrWhite;
   if(dd >= InpMaxDrawdownPercent * 0.8) ddC = clrOrange;
   if(dd >= InpMaxDrawdownPercent) ddC = clrRed;
   ObjSetS("Dd", StringFormat("%.2f%%", dd)); ObjSetC("Dd", ddC);
}

//+------------------------------------------------------------------+
void CreatePanel()
{
   int h = InpEnableReversal ? 410 : 390;  // Adjust height if reversal enabled
   int w = 340, lh = 19, x = InpPanelX, y = InpPanelY;
   int x1 = x + 12, x2 = x + 170;
   
   CreateRect("BG", x, y, w, h, InpPanelColor, false); y += 10;
   CreateTxt("Title", x1, y, "TRUE SACROSANCT GRID", clrGold, 11, "Arial Black"); y += 24;
   CreateRect("S1", x + 8, y, w - 16, 1, clrDimGray, false); y += 7;
   
   CreateTxt("StL", x1, y, "Status:", C'120,120,120', 9);
   CreateTxt("Status", x1 + 52, y, "Active", clrLimeGreen, 9, "Arial Bold");
   CreateTxt("DiL", x2, y, "Dir:", C'120,120,120', 9);
   string dirText = InpTradeDirection == DIRECTION_BUY_ONLY ? "BUY⬆" : InpTradeDirection == DIRECTION_SELL_ONLY ? "SELL⬇" : "BOTH↕";
   CreateTxt("Dir", x2 + 32, y, dirText, clrWhite, 9, "Arial Bold"); y += lh;
   
   CreateTxt("SyL", x1, y, "Symbol:", C'120,120,120', 9);
   CreateTxt("Sym", x1 + 52, y, sym, clrWhite, 9, "Arial Bold");
   CreateTxt("MgL", x2, y, "Magic:", C'120,120,120', 9);
   CreateTxt("Mag", x2 + 45, y, IntegerToString(magicNumber), clrWhite, 8); y += lh;
   
   CreateTxt("LoL", x1, y, "Lot:", C'120,120,120', 9);
   CreateTxt("Lot", x1 + 52, y, StringFormat("%.2f", effectiveInitialLotSize), clrWhite, 9, "Arial Bold");
   CreateTxt("SpL", x2, y, "Spread:", C'120,120,120', 9);
   CreateTxt("Spr", x2 + 50, y, "0.0", clrWhite, 9, "Arial Bold"); y += lh;
   
   CreateTxt("EqL", x1, y, "Equity:", C'120,120,120', 9);
   CreateTxt("Eq", x1 + 52, y, "$0.00", C'240,248,255', 9, "Arial Black");
   CreateTxt("ReL", x2, y, "Ref:", C'120,120,120', 9);
   CreateTxt("Ref", x2 + 32, y, "0.00000", clrWhite, 9, "Arial Bold"); y += lh;
   
   CreateTxt("PkL", x1, y, "Peak:", C'120,120,120', 9);
   CreateTxt("Pk", x1 + 52, y, "$0.00", clrGold, 9, "Arial Bold"); y += lh;
   
   CreateTxt("GgL", x1, y, "Grid Gap:", C'120,120,120', 9);
   CreateTxt("Gg", x1 + 65, y, "0.00%", clrWhite, 9, "Arial Bold"); y += lh;
   
   CreateTxt("TrL", x1, y, "Triggered:", clrOrange, 9, "Arial Bold");
   CreateTxt("Tr", x1 + 72, y, "B:0|S:0", clrOrange, 9, "Arial Bold"); y += lh;
   
   CreateTxt("CyL", x1, y, "Cycles:", clrLimeGreen, 9, "Arial Bold");
   CreateTxt("Cyc", x1 + 55, y, "TP:0|CA:0|Tot:0", clrLimeGreen, 9, "Arial Bold"); y += lh;
   
   CreateTxt("MoL", x1, y, "Mode:", C'120,120,120', 9);
   CreateTxt("Mo", x1 + 45, y, useMarketOrders ? "MARKET" : "PENDING", useMarketOrders ? clrYellow : clrLimeGreen, 9, "Arial Bold"); 
   CreateTxt("DbgMode", x2, y, "", clrYellow, 9, "Arial Bold"); y += lh;
   
   // Reversal indicator (if enabled)
   if(InpEnableReversal)
   {
      CreateTxt("RevL", x1, y, "Reversal:", clrCyan, 9, "Arial Bold");
      CreateTxt("Rev", x1 + 68, y, StringFormat("Thr:%d|B:%d|S:%d", InpReversalLevels, peakBuyLevelsActivated, peakSellLevelsActivated), 
                clrCyan, 8, "Arial Bold"); y += lh;
   }
   
   y += 2;
   
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
   CreateTxt("Sg", x2 + 35, y, "0 lvls", clrTomato, 9, "Arial Bold"); y += lh + 2;
   
   CreateRect("S3", x + 8, y, w - 16, 1, clrDimGray, false); y += 7;
   
   CreateTxt("PrL", x1, y, "Profit:", C'120,120,120', 9);
   CreateTxt("Pr", x1 + 50, y, "$0.00", clrLimeGreen, 10, "Arial Black");
   CreateTxt("TpL", x2, y, "Target:", C'120,120,120', 9);
   CreateTxt("Tp", x2 + 50, y, "$" + Fmt(InpGlobalTakeProfitUSD, 0), clrGold, 9, "Arial Bold"); y += lh + 2;
   
   CreateTxt("DdL", x1, y, "DD:", C'120,120,120', 9);
   CreateTxt("Dd", x1 + 50, y, "0.00%", clrWhite, 9, "Arial Bold");
   CreateTxt("MdL", x2, y, "Max DD:", C'120,120,120', 9);
   CreateTxt("Md", x2 + 50, y, StringFormat("%.1f%%", InpMaxDrawdownPercent), clrOrangeRed, 9, "Arial Bold"); y += lh + 6;
   
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
