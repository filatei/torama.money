//+------------------------------------------------------------------+
//|                    TORAMA Bitcoin Grid EA v2.1 CORRECTED         |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "2.10"
#property description "Bitcoin Grid EA - PROFIT-BASED TP/SL CALCULATION"
#property description "v2.1: FIXED - TP/SL now based on actual PROFIT, not price distance"
#property description "Works on ANY broker, ANY contract size, ANY lot size"

#define EA_VERSION "2.1"
#define EA_NAME "BTC GRID"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "=== TRADING MODE ==="
input bool     TradeBuyOnly = true;              // Trade BUY ONLY (false = SELL ONLY)
input bool     EnableSRSwitch = false;           // Auto-switch mode at Support/Resistance

input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.30;        // Grid spacing % (0.2-0.5 recommended)
input int      MaxPositions = 30;                // Maximum grid positions
input double   LotSize = 0.1;                    // Lot size per position

input group "=== PROFIT & RISK ==="
input double   IndividualTPDollars = 50.0;       // Take Profit per position ($)
input double   IndividualSLDollars = 5000.0;     // Stop Loss per position ($)
input double   GlobalTPDollars = 500.0;          // Global profit target ($)
input double   MaxDrawdownPercent = 20.0;        // Max drawdown % (emergency stop)

input group "=== SUPPORT/RESISTANCE ==="
input int      H4LookbackBars = 100;             // H4 bars for S/R calculation
input bool     ShowSRLines = true;               // Show S/R lines on chart

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                 // Maximum spread (points)
input int      MagicNumber = 77722;              // Magic number
input bool     ShowPanel = true;                 // Show info panel

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

struct Position
{
   ulong    ticket;
   double   entryPrice;
   datetime entryTime;
};

Position positions[];

// Trading state
bool currentlyBuyMode = true;      // Current trading direction
double referencePrice = 0;         // Reference for grid
double highestLevel = 0;           // Highest grid level
double lowestLevel = 0;            // Lowest grid level

// Support/Resistance
double currentSupport = 0;
double currentResistance = 0;
datetime lastSRUpdate = 0;

// Risk management
bool emergencyStop = false;
string emergencyReason = "";
double peakEquity = 0;
double totalProfit = 0;

// Statistics
int totalTrades = 0;
bool isPaused = false;

// Panel
string panelPrefix = "BTC_";

//+------------------------------------------------------------------+
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("═══════════════════════════════════════");
   Print("🚀 ", EA_NAME, " v", EA_VERSION);
   Print("═══════════════════════════════════════");
   
   currentlyBuyMode = TradeBuyOnly;
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   Print("Mode: ", currentlyBuyMode ? "BUY ONLY" : "SELL ONLY");
   Print("Grid Spacing: ", GridSpacingPercent, "%");
   Print("Individual TP: $", IndividualTPDollars);
   Print("Individual SL: $", IndividualSLDollars);
   Print("Global TP: $", GlobalTPDollars);
   Print("S/R Auto-Switch: ", EnableSRSwitch ? "ENABLED" : "DISABLED");
   Print("═══════════════════════════════════════");
   
   // Calculate initial S/R
   CalculateSupportResistance();
   lastSRUpdate = TimeCurrent();
   
   // Create panel
   if(ShowPanel) CreatePanel();
   
   // Sync existing positions
   SyncPositions();
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up panel objects
   ObjectsDeleteAll(0, panelPrefix);
   
   // Clean up S/R lines
   ObjectDelete(0, "SR_Support");
   ObjectDelete(0, "SR_Resistance");
   ObjectDelete(0, "SR_Support_Label");
   ObjectDelete(0, "SR_Resistance_Label");
   
   Print("EA stopped. Total trades: ", totalTrades);
}

//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // Emergency stop check
   if(emergencyStop)
   {
      UpdatePanel();
      return;
   }
   
   // Sync positions
   SyncPositions();
   
   // Check drawdown
   if(CheckDrawdown())
   {
      emergencyStop = true;
      emergencyReason = "Max Drawdown Exceeded";
      CloseAllPositions();
      Alert("🛑 EA STOPPED: Max Drawdown ", MaxDrawdownPercent, "% exceeded!");
      UpdatePanel();
      return;
   }
   
   // Check global TP
   CalculateTotalProfit();
   if(GlobalTPDollars > 0 && totalProfit >= GlobalTPDollars)
   {
      Print("✅ GLOBAL TP HIT: $", DoubleToString(totalProfit, 2));
      CloseAllPositions();
      ResetGrid();
      UpdatePanel();
      return;
   }
   
   // Update S/R every 4 hours
   if(TimeCurrent() - lastSRUpdate >= 14400)
   {
      CalculateSupportResistance();
      lastSRUpdate = TimeCurrent();
      
      // Check for S/R mode switch
      if(EnableSRSwitch) CheckSRSwitch();
   }
   
   // Check spread
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(currentSpread > MaxSpread) return;
   
   // Don't trade if paused
   if(isPaused)
   {
      UpdatePanel();
      return;
   }
   
   // Main trading logic
   ManageGrid();
   
   // Update panel
   if(ShowPanel) UpdatePanel();
}

//+------------------------------------------------------------------+
//| CHART EVENT HANDLER (Buttons)                                    |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      // SWITCH MODE button
      if(sparam == panelPrefix + "SwitchBtn")
      {
         currentlyBuyMode = !currentlyBuyMode;
         Print("🔄 Switched to ", currentlyBuyMode ? "BUY ONLY" : "SELL ONLY", " mode");
         ResetGrid();
         ObjectSetInteger(0, panelPrefix + "SwitchBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      
      // CLOSE PROFITS button
      else if(sparam == panelPrefix + "CloseProfitsBtn")
      {
         CloseAllProfitablePositions();
         ObjectSetInteger(0, panelPrefix + "CloseProfitsBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      
      // PAUSE button
      else if(sparam == panelPrefix + "PauseBtn")
      {
         isPaused = !isPaused;
         Print(isPaused ? "⏸️ EA PAUSED" : "▶️ EA RESUMED");
         ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      
      // CLOSE ALL button
      else if(sparam == panelPrefix + "CloseAllBtn")
      {
         CloseAllPositions();
         ResetGrid();
         ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
   }
}

//+------------------------------------------------------------------+
//| GRID MANAGEMENT - Core Trading Logic                             |
//+------------------------------------------------------------------+
void ManageGrid()
{
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double gridSpacing = currentPrice * (GridSpacingPercent / 100.0);
   
   int posCount = ArraySize(positions);
   
   // Initialize grid if no positions
   if(posCount == 0)
   {
      if(OpenPosition(currentPrice))
      {
         referencePrice = currentPrice;
         highestLevel = currentPrice;
         lowestLevel = currentPrice;
      }
      return;
   }
   
   // Check if we should add positions
   if(posCount >= MaxPositions) return;
   
   // REPLACEABLE GRID LOGIC
   // Add positions both above and below existing grid
   
   if(currentlyBuyMode)
   {
      // BUY MODE: Grid up and down
      // Add BUY above when price rises (follow momentum)
      if(currentPrice >= highestLevel + gridSpacing)
      {
         if(OpenPosition(currentPrice))
         {
            highestLevel = currentPrice;
         }
      }
      
      // Add BUY below when price falls (average down)
      else if(currentPrice <= lowestLevel - gridSpacing)
      {
         if(OpenPosition(currentPrice))
         {
            lowestLevel = currentPrice;
         }
      }
   }
   else
   {
      // SELL MODE: Grid up and down
      // Add SELL below when price falls (follow momentum)
      if(currentPrice <= lowestLevel - gridSpacing)
      {
         if(OpenPosition(currentPrice))
         {
            lowestLevel = currentPrice;
         }
      }
      
      // Add SELL above when price rises (average down)
      else if(currentPrice >= highestLevel + gridSpacing)
      {
         if(OpenPosition(currentPrice))
         {
            highestLevel = currentPrice;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TP/SL DISTANCE BASED ON DESIRED PROFIT                 |
//| This is the CORRECT way to handle micro/mini contracts          |
//+------------------------------------------------------------------+
double CalculateTPSLDistance(double desiredProfitDollars, double lotSize, string direction)
{
   // If desired profit is 0, return 0
   if(desiredProfitDollars <= 0) return 0;
   
   // Get current price for testing
   double currentPrice = (direction == "BUY") ? 
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                         SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Test with $100 price movement to find profit ratio
   double testDistance = 100.0;
   
   // CRITICAL: Test movement must be in PROFIT direction!
   // BUY: profit when price goes UP (+100)
   // SELL: profit when price goes DOWN (-100)
   double testPriceTo = (direction == "BUY") ? 
                        currentPrice + testDistance :   // BUY: test price above
                        currentPrice - testDistance;    // SELL: test price below
   
   double testProfit = 0;
   
   ENUM_ORDER_TYPE orderType = (direction == "BUY") ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   
   // Calculate what profit $100 movement gives with current lot size
   if(OrderCalcProfit(orderType, _Symbol, lotSize, currentPrice, testPriceTo, testProfit))
   {
      testProfit = MathAbs(testProfit);  // Ensure positive
      
      if(testProfit > 0.0001)  // Avoid division by zero
      {
         // Calculate profit per $1 price movement
         double profitPerDollar = testProfit / testDistance;
         
         // Calculate price distance needed for desired profit
         double neededDistance = desiredProfitDollars / profitPerDollar;
         
         Print("💡 TP/SL Calculation:");
         Print("   Desired profit: $", DoubleToString(desiredProfitDollars, 2));
         Print("   Test: $", testDistance, " movement = $", DoubleToString(testProfit, 2), " profit");
         Print("   Profit per $1: $", DoubleToString(profitPerDollar, 4));
         Print("   Needed distance: $", DoubleToString(neededDistance, 2));
         
         return neededDistance;
      }
   }
   
   // Fallback: if OrderCalcProfit fails, use simple distance
   // This works for standard contracts where 1 lot = 1 unit
   Print("⚠️ OrderCalcProfit failed, using simple distance");
   return desiredProfitDollars;
}

//+------------------------------------------------------------------+
//| OPEN POSITION - PROFIT-BASED TP/SL Calculation                   |
//+------------------------------------------------------------------+
bool OpenPosition(double price)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type = currentlyBuyMode ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   request.price = currentlyBuyMode ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = EA_NAME + " v" + EA_VERSION;
   request.type_filling = ORDER_FILLING_IOC;
   
   // ==================================================================
   // PROFIT-BASED TP/SL CALCULATION v2.1 - THE CORRECT WAY!
   // Calculates price distance needed to achieve desired PROFIT
   // Works on ANY broker, ANY contract size, ANY lot size
   // ==================================================================
   
   string direction = currentlyBuyMode ? "BUY" : "SELL";
   
   Print("📊 Opening ", direction, " position:");
   Print("   Entry price: $", DoubleToString(request.price, 2));
   Print("   Lot size: ", LotSize);
   
   // Calculate TP and SL distances based on DESIRED PROFIT
   double tpDistance = CalculateTPSLDistance(IndividualTPDollars, LotSize, direction);
   double slDistance = CalculateTPSLDistance(IndividualSLDollars, LotSize, direction);
   
   // Set TP and SL prices
   if(currentlyBuyMode)
   {
      // BUY: TP above entry, SL below entry
      request.tp = (tpDistance > 0) ? request.price + tpDistance : 0;
      request.sl = (slDistance > 0) ? request.price - slDistance : 0;
   }
   else  // SELL
   {
      // SELL: TP below entry, SL above entry
      request.tp = (tpDistance > 0) ? request.price - tpDistance : 0;
      request.sl = (slDistance > 0) ? request.price + slDistance : 0;
   }
   
   Print("   TP distance: $", DoubleToString(tpDistance, 2), " → TP price: $", DoubleToString(request.tp, 2));
   Print("   SL distance: $", DoubleToString(slDistance, 2), " → SL price: $", DoubleToString(request.sl, 2));
   
   // Verify minimum stop distance (broker requirements)
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   
   if(minStopLevel > 0)
   {
      if(currentlyBuyMode)
      {
         if(request.tp > 0 && request.tp - request.price < minStopLevel)
         {
            Print("⚠️ Adjusting TP to meet minimum stop level");
            request.tp = request.price + minStopLevel;
         }
         if(request.sl > 0 && request.price - request.sl < minStopLevel)
         {
            Print("⚠️ Adjusting SL to meet minimum stop level");
            request.sl = request.price - minStopLevel;
         }
      }
      else // SELL
      {
         if(request.tp > 0 && request.price - request.tp < minStopLevel)
         {
            Print("⚠️ Adjusting TP to meet minimum stop level");
            request.tp = request.price - minStopLevel;
         }
         if(request.sl > 0 && request.sl - request.price < minStopLevel)
         {
            Print("⚠️ Adjusting SL to meet minimum stop level");
            request.sl = request.price + minStopLevel;
         }
      }
   }
   
   // Normalize prices
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   request.price = NormalizeDouble(request.price, digits);
   request.tp = NormalizeDouble(request.tp, digits);
   request.sl = NormalizeDouble(request.sl, digits);
   
   // Send order
   if(!OrderSend(request, result))
   {
      Print("❌ Order failed: ", GetLastError());
      return false;
   }
   
   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      // Add to positions array
      int newSize = ArraySize(positions) + 1;
      ArrayResize(positions, newSize);
      positions[newSize-1].ticket = result.order;
      positions[newSize-1].entryPrice = result.price;
      positions[newSize-1].entryTime = TimeCurrent();
      
      totalTrades++;
      
      Print("✅ ", currentlyBuyMode ? "BUY" : "SELL", " @ ", DoubleToString(result.price, digits), 
            " | TP: $", IndividualTPDollars, " | SL: $", IndividualSLDollars,
            " | Positions: ", newSize, "/", MaxPositions);
      
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS                                                    |
//+------------------------------------------------------------------+
void SyncPositions()
{
   ArrayResize(positions, 0);
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      int newSize = ArraySize(positions) + 1;
      ArrayResize(positions, newSize);
      positions[newSize-1].ticket = ticket;
      positions[newSize-1].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      positions[newSize-1].entryTime = (datetime)PositionGetInteger(POSITION_TIME);
   }
   
   // Update grid levels
   if(ArraySize(positions) > 0)
   {
      highestLevel = positions[0].entryPrice;
      lowestLevel = positions[0].entryPrice;
      
      for(int i = 1; i < ArraySize(positions); i++)
      {
         if(positions[i].entryPrice > highestLevel)
            highestLevel = positions[i].entryPrice;
         if(positions[i].entryPrice < lowestLevel)
            lowestLevel = positions[i].entryPrice;
      }
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                           |
//+------------------------------------------------------------------+
void CalculateTotalProfit()
{
   totalProfit = 0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
}

//+------------------------------------------------------------------+
//| CHECK DRAWDOWN                                                    |
//+------------------------------------------------------------------+
bool CheckDrawdown()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(equity > peakEquity)
      peakEquity = equity;
   
   double drawdown = ((equity - peakEquity) / peakEquity) * 100.0;
   
   return (drawdown <= -MaxDrawdownPercent);
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                              |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      
      request.action = TRADE_ACTION_DEAL;
      request.position = ticket;
      request.symbol = _Symbol;
      request.volume = PositionGetDouble(POSITION_VOLUME);
      request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.deviation = 10;
      request.magic = MagicNumber;
      request.type_filling = ORDER_FILLING_IOC;
      
      if(!OrderSend(request, result))
      {
         Print("⚠️ Failed to close position #", ticket, ": ", result.retcode);
      }
   }
   
   Print("🔄 All positions closed");
}

//+------------------------------------------------------------------+
//| CLOSE PROFITABLE POSITIONS ONLY                                  |
//+------------------------------------------------------------------+
void CloseAllProfitablePositions()
{
   int closedCount = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      
      if(profit > 0)
      {
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         
         request.action = TRADE_ACTION_DEAL;
         request.position = ticket;
         request.symbol = _Symbol;
         request.volume = PositionGetDouble(POSITION_VOLUME);
         request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         request.deviation = 10;
         request.magic = MagicNumber;
         request.type_filling = ORDER_FILLING_IOC;
         
         if(OrderSend(request, result))
            closedCount++;
      }
   }
   
   Print("✅ Closed ", closedCount, " profitable positions");
}

//+------------------------------------------------------------------+
//| RESET GRID                                                        |
//+------------------------------------------------------------------+
void ResetGrid()
{
   referencePrice = 0;
   highestLevel = 0;
   lowestLevel = 0;
   ArrayResize(positions, 0);
}

//+------------------------------------------------------------------+
//| CALCULATE SUPPORT & RESISTANCE                                   |
//+------------------------------------------------------------------+
void CalculateSupportResistance()
{
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   
   int copiedHighs = CopyHigh(_Symbol, PERIOD_H4, 0, H4LookbackBars, highs);
   int copiedLows = CopyLow(_Symbol, PERIOD_H4, 0, H4LookbackBars, lows);
   
   if(copiedHighs > 0 && copiedLows > 0)
   {
      currentResistance = highs[ArrayMaximum(highs)];
      currentSupport = lows[ArrayMinimum(lows)];
      
      if(ShowSRLines) DrawSRLines();
      
      Print("📊 S/R Updated: Support=$", DoubleToString(currentSupport, 2), 
            " | Resistance=$", DoubleToString(currentResistance, 2));
   }
}

//+------------------------------------------------------------------+
//| DRAW SUPPORT & RESISTANCE LINES                                  |
//+------------------------------------------------------------------+
void DrawSRLines()
{
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Support line
   if(ObjectFind(0, "SR_Support") < 0)
   {
      ObjectCreate(0, "SR_Support", OBJ_HLINE, 0, 0, currentSupport);
      ObjectSetInteger(0, "SR_Support", OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, "SR_Support", OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, "SR_Support", OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, "SR_Support", OBJPROP_SELECTABLE, false);
   }
   else
      ObjectSetDouble(0, "SR_Support", OBJPROP_PRICE, currentSupport);
   
   // Resistance line
   if(ObjectFind(0, "SR_Resistance") < 0)
   {
      ObjectCreate(0, "SR_Resistance", OBJ_HLINE, 0, 0, currentResistance);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_COLOR, clrOrangeRed);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_SELECTABLE, false);
   }
   else
      ObjectSetDouble(0, "SR_Resistance", OBJPROP_PRICE, currentResistance);
   
   // Labels
   if(ObjectFind(0, "SR_Support_Label") < 0)
   {
      ObjectCreate(0, "SR_Support_Label", OBJ_TEXT, 0, TimeCurrent(), currentSupport);
      ObjectSetString(0, "SR_Support_Label", OBJPROP_TEXT, " SUPPORT: $" + DoubleToString(currentSupport, digits));
      ObjectSetInteger(0, "SR_Support_Label", OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, "SR_Support_Label", OBJPROP_FONTSIZE, 10);
      ObjectSetInteger(0, "SR_Support_Label", OBJPROP_SELECTABLE, false);
   }
   else
   {
      ObjectMove(0, "SR_Support_Label", 0, TimeCurrent(), currentSupport);
      ObjectSetString(0, "SR_Support_Label", OBJPROP_TEXT, " SUPPORT: $" + DoubleToString(currentSupport, digits));
   }
   
   if(ObjectFind(0, "SR_Resistance_Label") < 0)
   {
      ObjectCreate(0, "SR_Resistance_Label", OBJ_TEXT, 0, TimeCurrent(), currentResistance);
      ObjectSetString(0, "SR_Resistance_Label", OBJPROP_TEXT, " RESISTANCE: $" + DoubleToString(currentResistance, digits));
      ObjectSetInteger(0, "SR_Resistance_Label", OBJPROP_COLOR, clrOrangeRed);
      ObjectSetInteger(0, "SR_Resistance_Label", OBJPROP_FONTSIZE, 10);
      ObjectSetInteger(0, "SR_Resistance_Label", OBJPROP_SELECTABLE, false);
   }
   else
   {
      ObjectMove(0, "SR_Resistance_Label", 0, TimeCurrent(), currentResistance);
      ObjectSetString(0, "SR_Resistance_Label", OBJPROP_TEXT, " RESISTANCE: $" + DoubleToString(currentResistance, digits));
   }
}

//+------------------------------------------------------------------+
//| CHECK S/R MODE SWITCH                                            |
//+------------------------------------------------------------------+
void CheckSRSwitch()
{
   if(!EnableSRSwitch) return;
   if(currentSupport == 0 || currentResistance == 0) return;
   
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double priceRange = currentResistance - currentSupport;
   double threshold = priceRange * 0.02; // 2% of range
   
   // Near resistance and in BUY mode -> switch to SELL
   if(currentlyBuyMode && MathAbs(currentPrice - currentResistance) < threshold)
   {
      Print("🔄 Auto-switch to SELL at RESISTANCE: $", DoubleToString(currentResistance, 2));
      currentlyBuyMode = false;
      CloseAllProfitablePositions();
      ResetGrid();
   }
   // Near support and in SELL mode -> switch to BUY
   else if(!currentlyBuyMode && MathAbs(currentPrice - currentSupport) < threshold)
   {
      Print("🔄 Auto-switch to BUY at SUPPORT: $", DoubleToString(currentSupport, 2));
      currentlyBuyMode = true;
      CloseAllProfitablePositions();
      ResetGrid();
   }
}

//+------------------------------------------------------------------+
//| CREATE PANEL                                                      |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 10, y = 20;
   int width = 380, height = 240;  // REDUCED height from 380 to 240
   
   // Background
   ObjectCreate(0, panelPrefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YSIZE, height);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BGCOLOR, C'20,20,20');  // Solid dark background
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BACK, false);  // On top, not behind!
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_ZORDER, 0);  // Highest priority
   
   // Header - Title and Status on same line
   CreateLabel(panelPrefix + "Title", x + 10, y + 10, EA_NAME + " v" + EA_VERSION, clrGold, 12, "Arial Bold");
   CreateLabel(panelPrefix + "Status", x + 250, y + 10, "ACTIVE", clrLimeGreen, 10, "Arial Bold");
   
   // Mode indicator
   CreateLabel(panelPrefix + "Mode", x + 10, y + 35, "Mode:", clrWhite, 10, "Arial");
   CreateLabel(panelPrefix + "ModeValue", x + 70, y + 35, "BUY ONLY", clrDodgerBlue, 11, "Arial Bold");
   
   // Buttons - all in two rows
   CreateButton(panelPrefix + "SwitchBtn", x + 10, y + 60, 90, 28, "SWITCH", clrGold, clrBlack);
   CreateButton(panelPrefix + "CloseProfitsBtn", x + 105, y + 60, 90, 28, "CLOSE +P/L", clrGreen, clrBlack);
   CreateButton(panelPrefix + "PauseBtn", x + 200, y + 60, 80, 28, "PAUSE", clrOrange, clrBlack);
   CreateButton(panelPrefix + "CloseAllBtn", x + 285, y + 60, 85, 28, "CLOSE ALL", clrRed, clrWhite);
   
   // Price, Grid, and S/R on compact lines
   CreateLabel(panelPrefix + "PriceLabel", x + 10, y + 100, "Price:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Price", x + 55, y + 100, "$0", clrWhite, 10, "Arial Bold");
   CreateLabel(panelPrefix + "GridLabel", x + 180, y + 100, "Grid:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "GridSpacing", x + 220, y + 100, "0.30%", clrWhite, 9, "Arial");
   
   // S/R Levels - compact
   CreateLabel(panelPrefix + "SupportLabel", x + 10, y + 120, "Support:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Support", x + 70, y + 120, "$0", clrDodgerBlue, 9, "Arial Bold");
   CreateLabel(panelPrefix + "ResistanceLabel", x + 180, y + 120, "Resist:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Resistance", x + 235, y + 120, "$0", clrOrangeRed, 9, "Arial Bold");
   
   // S/R Switch status
   CreateLabel(panelPrefix + "SRSwitchLabel", x + 10, y + 140, "S/R Switch:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "SRSwitch", x + 85, y + 140, "OFF", clrGray, 9, "Arial Bold");
   
   // Positions and P/L on same line
   CreateLabel(panelPrefix + "PositionsLabel", x + 10, y + 165, "Positions:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Positions", x + 80, y + 165, "0/30", clrWhite, 11, "Arial Bold");
   CreateLabel(panelPrefix + "PnLLabel", x + 180, y + 165, "P/L:", clrGray, 10, "Arial Bold");
   CreateLabel(panelPrefix + "PnL", x + 215, y + 165, "$0.00", clrWhite, 13, "Arial Black");  // LARGER for visibility
   
   // Equity and DD on same line
   CreateLabel(panelPrefix + "EquityLabel", x + 10, y + 190, "Equity:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Equity", x + 65, y + 190, "$0", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "DDLabel", x + 180, y + 190, "DD:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "DD", x + 210, y + 190, "0.0%", clrLimeGreen, 9, "Arial");
   
   // TORAMA CAPITAL - BOLD and BIG on bottom right
   CreateLabel(panelPrefix + "Brand", x + 215, y + 215, "TORAMA CAPITAL", clrGold, 11, "Arial Black");
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!ShowPanel) return;
   
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Status (now just shows status without "Status:" label)
   if(emergencyStop)
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "🛑 STOP");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrRed);
   }
   else if(isPaused)
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "⏸️ PAUSED");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrOrange);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "✅ ACTIVE");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrLimeGreen);
   }
   
   // Mode (update value only)
   ObjectSetString(0, panelPrefix + "ModeValue", OBJPROP_TEXT, 
                   currentlyBuyMode ? "🔵 BUY ONLY" : "🔴 SELL ONLY");
   ObjectSetInteger(0, panelPrefix + "ModeValue", OBJPROP_COLOR, currentlyBuyMode ? clrDodgerBlue : clrOrangeRed);
   
   // Pause button text
   ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, isPaused ? "RESUME" : "PAUSE");
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, isPaused ? clrGreen : clrOrange);
   
   // Price (value only)
   ObjectSetString(0, panelPrefix + "Price", OBJPROP_TEXT, 
                   "$" + DoubleToString(currentPrice, digits));
   
   // Grid (value only)
   ObjectSetString(0, panelPrefix + "GridSpacing", OBJPROP_TEXT,
                   DoubleToString(GridSpacingPercent, 2) + "% ($" + 
                   DoubleToString(currentPrice * GridSpacingPercent / 100.0, 2) + ")");
   
   // S/R (values only)
   if(currentSupport > 0)
      ObjectSetString(0, panelPrefix + "Support", OBJPROP_TEXT,
                      "$" + DoubleToString(currentSupport, digits));
   
   if(currentResistance > 0)
      ObjectSetString(0, panelPrefix + "Resistance", OBJPROP_TEXT,
                      "$" + DoubleToString(currentResistance, digits));
   
   // S/R Switch (value only)
   ObjectSetString(0, panelPrefix + "SRSwitch", OBJPROP_TEXT,
                   EnableSRSwitch ? "ON" : "OFF");
   ObjectSetInteger(0, panelPrefix + "SRSwitch", OBJPROP_COLOR, EnableSRSwitch ? clrLimeGreen : clrGray);
   
   // Positions (value only)
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT,
                   IntegerToString(ArraySize(positions)) + "/" + IntegerToString(MaxPositions));
   
   // P/L (value only)
   CalculateTotalProfit();
   color pnlColor = (totalProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "PnL", OBJPROP_TEXT,
                   (totalProfit >= 0 ? "+" : "") + "$" + DoubleToString(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "PnL", OBJPROP_COLOR, pnlColor);
   
   // Equity (value only)
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT,
                   "$" + DoubleToString(equity, 2));
   
   // Drawdown (value only)
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   color ddColor = (dd >= -5) ? clrLimeGreen : (dd >= -10) ? clrYellow : clrRed;
   ObjectSetString(0, panelPrefix + "DD", OBJPROP_TEXT,
                   DoubleToString(dd, 1) + "%");
   ObjectSetInteger(0, panelPrefix + "DD", OBJPROP_COLOR, ddColor);
}

//+------------------------------------------------------------------+
//| CREATE LABEL                                                      |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, string font)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| CREATE BUTTON                                                     |
//+------------------------------------------------------------------+
void CreateButton(string name, int x, int y, int width, int height, string text, color bgColor, color txtColor)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, txtColor);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrGold);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
}

//+------------------------------------------------------------------+
