//+------------------------------------------------------------------+
//|                    TORAMA Bitcoin Grid EA v2.0 STREAMLINED       |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "2.00"
#property description "Bitcoin Grid EA - Streamlined & Optimized"
#property description "BUY ONLY or SELL ONLY modes | Replaceable grid levels"
#property description "Auto-switch at S/R levels | Clean & Efficient"

#define EA_VERSION "2.0"
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
//| OPEN POSITION - Simplified TP/SL Calculation                     |
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
   
   // SIMPLE TP/SL CALCULATION - Direct dollar distance
   if(currentlyBuyMode)
   {
      request.tp = (IndividualTPDollars > 0) ? request.price + IndividualTPDollars : 0;
      request.sl = (IndividualSLDollars > 0) ? request.price - IndividualSLDollars : 0;
   }
   else
   {
      request.tp = (IndividualTPDollars > 0) ? request.price - IndividualTPDollars : 0;
      request.sl = (IndividualSLDollars > 0) ? request.price + IndividualSLDollars : 0;
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
   int width = 350, height = 380;
   
   // Background
   ObjectCreate(0, panelPrefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_YSIZE, height);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, panelPrefix + "BG", OBJPROP_BACK, true);
   
   // Header
   CreateLabel(panelPrefix + "Title", x + 10, y + 10, EA_NAME + " v" + EA_VERSION, clrGold, 12, "Arial Bold");
   CreateLabel(panelPrefix + "Status", x + 10, y + 35, "Status: ACTIVE", clrLimeGreen, 10, "Arial Bold");
   
   // Mode indicator
   CreateLabel(panelPrefix + "Mode", x + 10, y + 60, "Mode: BUY ONLY", clrDodgerBlue, 11, "Arial Bold");
   
   // Buttons
   CreateButton(panelPrefix + "SwitchBtn", x + 10, y + 85, 100, 30, "SWITCH MODE", clrGold, clrBlack);
   CreateButton(panelPrefix + "CloseProfitsBtn", x + 120, y + 85, 100, 30, "CLOSE +P/L", clrGreen, clrBlack);
   CreateButton(panelPrefix + "PauseBtn", x + 230, y + 85, 100, 30, "PAUSE", clrOrange, clrBlack);
   CreateButton(panelPrefix + "CloseAllBtn", x + 10, y + 125, 100, 30, "CLOSE ALL", clrRed, clrWhite);
   
   // Price & Grid
   CreateLabel(panelPrefix + "Price", x + 10, y + 170, "Price: $0", clrWhite, 10, "Arial");
   CreateLabel(panelPrefix + "GridSpacing", x + 10, y + 190, "Grid: 0.30%", clrWhite, 9, "Arial");
   
   // S/R Levels
   CreateLabel(panelPrefix + "Support", x + 10, y + 215, "Support: $0", clrDodgerBlue, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Resistance", x + 10, y + 235, "Resistance: $0", clrOrangeRed, 9, "Arial Bold");
   CreateLabel(panelPrefix + "SRSwitch", x + 10, y + 255, "S/R Switch: OFF", clrGray, 9, "Arial");
   
   // Positions
   CreateLabel(panelPrefix + "Positions", x + 10, y + 280, "Positions: 0/30", clrWhite, 10, "Arial Bold");
   CreateLabel(panelPrefix + "PnL", x + 10, y + 300, "P/L: $0.00", clrWhite, 10, "Arial Bold");
   
   // Account
   CreateLabel(panelPrefix + "Equity", x + 10, y + 325, "Equity: $0", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "DD", x + 10, y + 345, "DD: 0.0%", clrLimeGreen, 9, "Arial");
   
   // Brand
   CreateLabel(panelPrefix + "Brand", x + 10, y + 365, "TORAMA CAPITAL", clrGold, 8, "Arial Bold");
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!ShowPanel) return;
   
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Status
   if(emergencyStop)
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "Status: 🛑 EMERGENCY STOP");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrRed);
   }
   else if(isPaused)
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "Status: ⏸️ PAUSED");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrOrange);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "Status: ✅ ACTIVE");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrLimeGreen);
   }
   
   // Mode
   ObjectSetString(0, panelPrefix + "Mode", OBJPROP_TEXT, 
                   "Mode: " + (currentlyBuyMode ? "🔵 BUY ONLY" : "🔴 SELL ONLY"));
   ObjectSetInteger(0, panelPrefix + "Mode", OBJPROP_COLOR, currentlyBuyMode ? clrDodgerBlue : clrOrangeRed);
   
   // Pause button text
   ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, isPaused ? "RESUME" : "PAUSE");
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, isPaused ? clrGreen : clrOrange);
   
   // Price
   ObjectSetString(0, panelPrefix + "Price", OBJPROP_TEXT, 
                   "Price: $" + DoubleToString(currentPrice, digits));
   
   // Grid
   ObjectSetString(0, panelPrefix + "GridSpacing", OBJPROP_TEXT,
                   "Grid: " + DoubleToString(GridSpacingPercent, 2) + "% ($" + 
                   DoubleToString(currentPrice * GridSpacingPercent / 100.0, 2) + ")");
   
   // S/R
   if(currentSupport > 0)
      ObjectSetString(0, panelPrefix + "Support", OBJPROP_TEXT,
                      "Support: $" + DoubleToString(currentSupport, digits));
   
   if(currentResistance > 0)
      ObjectSetString(0, panelPrefix + "Resistance", OBJPROP_TEXT,
                      "Resistance: $" + DoubleToString(currentResistance, digits));
   
   ObjectSetString(0, panelPrefix + "SRSwitch", OBJPROP_TEXT,
                   "S/R Switch: " + (EnableSRSwitch ? "ON" : "OFF"));
   ObjectSetInteger(0, panelPrefix + "SRSwitch", OBJPROP_COLOR, EnableSRSwitch ? clrLimeGreen : clrGray);
   
   // Positions
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT,
                   "Positions: " + IntegerToString(ArraySize(positions)) + "/" + IntegerToString(MaxPositions));
   
   // P/L
   CalculateTotalProfit();
   color pnlColor = (totalProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "PnL", OBJPROP_TEXT,
                   "P/L: " + (totalProfit >= 0 ? "+" : "") + "$" + DoubleToString(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "PnL", OBJPROP_COLOR, pnlColor);
   
   // Account
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT,
                   "Equity: $" + DoubleToString(equity, 2));
   
   // Drawdown
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   color ddColor = (dd >= -5) ? clrLimeGreen : (dd >= -10) ? clrYellow : clrRed;
   ObjectSetString(0, panelPrefix + "DD", OBJPROP_TEXT,
                   "DD: " + DoubleToString(dd, 1) + "%");
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
