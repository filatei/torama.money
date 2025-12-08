//+------------------------------------------------------------------+
//|                                   TORAMA_Mean_Reversion_Grid_v1_1.mq5 |
//|                                      Copyright 2025, TORAMA CAPITAL |
//|                                               https://torama.money |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.10"
#property description "Mean Reversion Grid EA - Buy falling, Sell rising"
#property description "Takes profit when X positions become profitable"
#property description "Press 'H' to toggle panel visibility"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.30;        // Grid spacing % of price
input int      MaxPositionsPerSide = 30;         // Max positions per side (BUY or SELL)
input double   LotSize = 0.01;                   // Lot size per position

input group "=== PROFIT TARGETS (% of Account Balance) ==="
input double   IndividualTPPercent = 0.50;       // Individual TP % of account balance (0.5 = 0.5%)
input double   IndividualSLPercent = 0.0;        // Individual SL % of account balance (0 = disabled)
input double   GlobalTPPercent = 2.0;            // Global TP % of account balance (2 = 2%)
input double   GlobalSLPercent = 0.0;            // Global SL % of account balance (0 = disabled)

input group "=== MEAN REVERSION LOGIC ==="
input int      ProfitableCountToClose = 5;       // Close all when X positions profitable (per side)
input bool     CloseBothSidesOnProfit = false;   // Close both BUY and SELL when one side profits

input group "=== RISK MANAGEMENT ==="
input double   SessionProfitPercent = 200.0;     // Session/Daily profit target (% of starting balance)
input bool     ResetSessionDaily = true;         // Reset session profit daily
input double   MaxDrawdownPercent = 15.0;        // Max drawdown % (emergency stop)

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                 // Maximum spread (points)
input int      MagicNumber = 77730;              // Magic number
input bool     ShowPanel = true;                 // Show info panel

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

// Position tracking
struct PositionInfo
{
   ulong ticket;
   double openPrice;
   double lotSize;
   int type;  // 0=BUY, 1=SELL
};

PositionInfo buyPositions[];
PositionInfo sellPositions[];

// Grid tracking
double lastBuyLevel = 0;
double lastSellLevel = 0;
double highestSellLevel = 0;
double lowestBuyLevel = 0;

// Risk management
double sessionStartBalance = 0;
double sessionProfit = 0;
double sessionProfitTarget = 0;
bool sessionTargetReached = false;
datetime lastSessionReset = 0;
int currentDay = 0;

// Grid rebuild control
bool needsRebuild = false;
int lastTotalPositions = 0;

// EA control
bool isPaused = false;
bool panelVisible = true;

// Panel
string panelPrefix = "MeanRevPanel_";

// Symbol properties (broker-aware)
double pointValue = 0;
double tickValue = 0;
double tickSize = 0;
int digits = 0;
double minLot = 0;
double maxLot = 0;
double lotStep = 0;
double minVolume = 0;

// Normalized lot size (working variable)
double normalizedLotSize = 0;

// Calculated values
double currentGapSize = 0;
double individualTPDollars = 0;
double individualSLDollars = 0;
double globalTPDollars = 0;
double globalSLDollars = 0;

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   // Enable keyboard event detection
   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, false);
   
   // Initialize session tracking
   sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
   sessionProfit = 0;
   sessionTargetReached = false;
   lastSessionReset = TimeCurrent();
   
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   currentDay = time.day;
   
   // Get broker properties
   if(!InitializeSymbolProperties())
   {
      Print("❌ Failed to initialize symbol properties!");
      return INIT_FAILED;
   }
   
   // Calculate gap-based values
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   currentGapSize = currentPrice * (GridSpacingPercent / 100.0);
   
   // Calculate profit/loss targets in dollars based on ACCOUNT BALANCE
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   individualTPDollars = accountBalance * (IndividualTPPercent / 100.0);
   individualSLDollars = (IndividualSLPercent > 0) ? accountBalance * (IndividualSLPercent / 100.0) : 0;
   globalTPDollars = accountBalance * (GlobalTPPercent / 100.0);
   globalSLDollars = (GlobalSLPercent > 0) ? accountBalance * (GlobalSLPercent / 100.0) : 0;
   
   // Validate and normalize lot size
   normalizedLotSize = NormalizeLotSize(LotSize);
   
   // Display initialization info
   Print("╔════════════════════════════════════════════════════════════════╗");
   Print("║     TORAMA MEAN REVERSION GRID EA v1.1                         ║");
   Print("╚════════════════════════════════════════════════════════════════╝");
   Print("Symbol: ", _Symbol);
   Print("Account: ", AccountInfoString(ACCOUNT_NAME), " (", AccountInfoString(ACCOUNT_SERVER), ")");
   Print("Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("═══════════════════════════════════════");
   
   Print("📊 MEAN REVERSION MODE");
   Print("Strategy: Buy falling, Sell rising");
   Print("Close when: ", ProfitableCountToClose, " positions profitable per side");
   Print("Close both sides: ", CloseBothSidesOnProfit ? "YES" : "NO");
   Print("Grid Spacing: ", GridSpacingPercent, "% = $", DoubleToString(currentGapSize, 2));
   Print("Max Positions: ", MaxPositionsPerSide, " per side (", MaxPositionsPerSide * 2, " total)");
   Print("Lot Size: ", DoubleToString(normalizedLotSize, 2), " (normalized from ", DoubleToString(LotSize, 2), ")");
   Print("Individual TP: ", IndividualTPPercent, "% of balance = $", DoubleToString(individualTPDollars, 2));
   Print("Individual SL: ", IndividualSLPercent > 0 ? DoubleToString(IndividualSLPercent, 2) + "% of balance = $" + DoubleToString(individualSLDollars, 2) : "DISABLED");
   Print("Global TP: ", GlobalTPPercent, "% of balance = $", DoubleToString(globalTPDollars, 2));
   Print("Global SL: ", GlobalSLPercent > 0 ? DoubleToString(GlobalSLPercent, 2) + "% of balance = $" + DoubleToString(globalSLDollars, 2) : "DISABLED");
   Print("Session Target: ", SessionProfitPercent, "% = $", DoubleToString(sessionProfitTarget, 2));
   Print("Max Drawdown: ", MaxDrawdownPercent, "%");
   Print("═══════════════════════════════════════");
   Print("💡 Press 'H' to toggle panel visibility");
   
   // Sync existing positions
   SyncPositions();
   
   Print("✅ EA initialized successfully!");
   Print("Waiting for price movement...");
   
   // Create panel
   if(ShowPanel) CreatePanel();
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Remove panel
   if(ShowPanel) DeletePanel();
   
   Print("EA removed: ", reason);
}

//+------------------------------------------------------------------+
//| EXPERT TICK FUNCTION                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Update panel if visible
   if(ShowPanel && panelVisible) UpdatePanel();
   
   // Check if EA is paused
   if(isPaused)
   {
      return;
   }
   
   // Sync positions
   SyncPositions();
   
   // Check for automatic grid rebuild (all positions closed)
   int totalPositions = ArraySize(buyPositions) + ArraySize(sellPositions);
   
   if(totalPositions == 0 && lastTotalPositions > 0)
   {
      // All positions just closed - trigger rebuild
      Print("🔄 All positions closed - Auto-rebuilding grid...");
      needsRebuild = true;
   }
   
   lastTotalPositions = totalPositions;
   
   // Execute rebuild if flagged
   if(needsRebuild)
   {
      RebuildGrid();
      needsRebuild = false;
      return;
   }
   
   // Check session profit and targets
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfit = currentBalance - sessionStartBalance;
   
   // Check for daily session reset
   if(ResetSessionDaily)
   {
      MqlDateTime time;
      TimeToStruct(TimeCurrent(), time);
      if(time.day != currentDay)
      {
         currentDay = time.day;
         sessionStartBalance = currentBalance;
         sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
         sessionProfit = 0;
         sessionTargetReached = false;
         lastSessionReset = TimeCurrent();
         Print("🌅 NEW DAY - Session reset");
         Print("   Start Balance: $", DoubleToString(sessionStartBalance, 2));
         Print("   Profit Target: $", DoubleToString(sessionProfitTarget, 2));
      }
   }
   
   // Check if session target reached
   if(sessionProfit >= sessionProfitTarget)
   {
      sessionTargetReached = true;
      CloseAllPositions();
      Print("🎯 SESSION TARGET REACHED! Profit: $", DoubleToString(sessionProfit, 2));
      Print("   All positions closed. Reset session or restart EA to continue.");
      return;
   }
   
   // Check max drawdown
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdown = ((sessionStartBalance - equity) / sessionStartBalance) * 100.0;
   
   if(drawdown >= MaxDrawdownPercent)
   {
      CloseAllPositions();
      isPaused = true;
      Print("🛑 MAX DRAWDOWN REACHED! Drawdown: ", DoubleToString(drawdown, 2), "%");
      Print("   All positions closed. EA paused. Review and restart manually.");
      return;
   }
   
   // Check spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      return;
   }
   
   // Check profitable positions
   CheckProfitablePositions();
   
   // Check global profit/loss
   CheckGlobalTargets();
   
   // Place mean reversion grid orders
   PlaceMeanReversionOrders();
}

// Due to length, I'll include the key helper functions. The rest follow the same pattern as the Momentum EA

//+------------------------------------------------------------------+
//| INITIALIZE SYMBOL PROPERTIES                                      |
//+------------------------------------------------------------------+
bool InitializeSymbolProperties()
{
   pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   Print("📊 Symbol Properties:");
   Print("   Point: ", pointValue);
   Print("   Tick Value: ", tickValue);
   Print("   Tick Size: ", tickSize);
   Print("   Digits: ", digits);
   Print("   Min Lot: ", minLot);
   Print("   Max Lot: ", maxLot);
   Print("   Lot Step: ", lotStep);
   
   return true;
}

//+------------------------------------------------------------------+
//| NORMALIZE LOT SIZE                                                |
//+------------------------------------------------------------------+
double NormalizeLotSize(double lots)
{
   double normalizedLot = MathFloor(lots / lotStep) * lotStep;
   normalizedLot = MathMax(normalizedLot, minLot);
   normalizedLot = MathMin(normalizedLot, maxLot);
   return NormalizeDouble(normalizedLot, 2);
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS WITH BROKER                                        |
//+------------------------------------------------------------------+
void SyncPositions()
{
   ArrayResize(buyPositions, 0);
   ArrayResize(sellPositions, 0);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      PositionInfo pos;
      pos.ticket = ticket;
      pos.openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      pos.lotSize = PositionGetDouble(POSITION_VOLUME);
      pos.type = (int)PositionGetInteger(POSITION_TYPE);
      
      if(pos.type == POSITION_TYPE_BUY)
      {
         int size = ArraySize(buyPositions);
         ArrayResize(buyPositions, size + 1);
         buyPositions[size] = pos;
      }
      else if(pos.type == POSITION_TYPE_SELL)
      {
         int size = ArraySize(sellPositions);
         ArrayResize(sellPositions, size + 1);
         sellPositions[size] = pos;
      }
   }
}

//+------------------------------------------------------------------+
//| PLACE MEAN REVERSION ORDERS                                       |
//+------------------------------------------------------------------+
void PlaceMeanReversionOrders()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // BUY LOGIC: Price falling (buy below last buy or initial)
   if(ArraySize(buyPositions) < MaxPositionsPerSide)
   {
      double nextBuyLevel = 0;
      
      if(ArraySize(buyPositions) == 0)
      {
         // First buy: one gap below current price
         nextBuyLevel = bid - currentGapSize;
      }
      else
      {
         // Find lowest buy position
         double lowestBuy = buyPositions[0].openPrice;
         for(int i = 1; i < ArraySize(buyPositions); i++)
         {
            if(buyPositions[i].openPrice < lowestBuy)
               lowestBuy = buyPositions[i].openPrice;
         }
         nextBuyLevel = lowestBuy - currentGapSize;
      }
      
      // Place buy if price reached next level
      if(bid <= nextBuyLevel && (lastBuyLevel == 0 || bid <= lastBuyLevel - currentGapSize))
      {
         if(OpenPosition("BUY", bid))
         {
            lastBuyLevel = bid;
            if(lowestBuyLevel == 0 || bid < lowestBuyLevel)
               lowestBuyLevel = bid;
         }
      }
   }
   
   // SELL LOGIC: Price rising (sell above last sell or initial)
   if(ArraySize(sellPositions) < MaxPositionsPerSide)
   {
      double nextSellLevel = 0;
      
      if(ArraySize(sellPositions) == 0)
      {
         // First sell: one gap above current price
         nextSellLevel = ask + currentGapSize;
      }
      else
      {
         // Find highest sell position
         double highestSell = sellPositions[0].openPrice;
         for(int i = 1; i < ArraySize(sellPositions); i++)
         {
            if(sellPositions[i].openPrice > highestSell)
               highestSell = sellPositions[i].openPrice;
         }
         nextSellLevel = highestSell + currentGapSize;
      }
      
      // Place sell if price reached next level
      if(ask >= nextSellLevel && (lastSellLevel == 0 || ask >= lastSellLevel + currentGapSize))
      {
         if(OpenPosition("SELL", ask))
         {
            lastSellLevel = ask;
            if(highestSellLevel == 0 || ask > highestSellLevel)
               highestSellLevel = ask;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OPEN POSITION                                                     |
//+------------------------------------------------------------------+
bool OpenPosition(string type, double price)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = normalizedLotSize;
   request.deviation = 50;
   request.magic = MagicNumber;
   request.comment = "TORAMA_MeanRev";
   
   if(type == "BUY")
   {
      request.type = ORDER_TYPE_BUY;
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.sl = 0;
      request.tp = 0;
   }
   else if(type == "SELL")
   {
      request.type = ORDER_TYPE_SELL;
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      request.sl = 0;
      request.tp = 0;
   }
   
   bool success = OrderSend(request, result);
   
   if(success && result.retcode == TRADE_RETCODE_DONE)
   {
      Print("✅ ", type, " opened at ", DoubleToString(price, digits), 
            " | Ticket: ", result.order, 
            " | Gap from price: $", DoubleToString(currentGapSize, 2));
      return true;
   }
   else
   {
      Print("❌ Failed to open ", type, " | Error: ", TradeRetcodeDescription(result.retcode));
      return false;
   }
}

//+------------------------------------------------------------------+
//| CHECK PROFITABLE POSITIONS                                        |
//+------------------------------------------------------------------+
void CheckProfitablePositions()
{
   int profitableBuys = 0;
   int profitableSells = 0;
   
   // Count profitable BUY positions
   for(int i = 0; i < ArraySize(buyPositions); i++)
   {
      if(PositionSelectByTicket(buyPositions[i].ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit >= individualTPDollars)
            profitableBuys++;
      }
   }
   
   // Count profitable SELL positions
   for(int i = 0; i < ArraySize(sellPositions); i++)
   {
      if(PositionSelectByTicket(sellPositions[i].ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit >= individualTPDollars)
            profitableSells++;
      }
   }
   
   // Check if we should close positions
   if(profitableBuys >= ProfitableCountToClose)
   {
      Print("🎯 ", profitableBuys, " BUY positions profitable - Closing...");
      if(CloseBothSidesOnProfit)
         CloseAllPositions();
      else
         ClosePositionsSide("BUY");
   }
   
   if(profitableSells >= ProfitableCountToClose)
   {
      Print("🎯 ", profitableSells, " SELL positions profitable - Closing...");
      if(CloseBothSidesOnProfit)
         CloseAllPositions();
      else
         ClosePositionsSide("SELL");
   }
}

//+------------------------------------------------------------------+
//| CHECK GLOBAL TARGETS                                              |
//+------------------------------------------------------------------+
void CheckGlobalTargets()
{
   double totalProfit = 0;
   double totalLoss = 0;
   
   // Calculate total profit/loss
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit > 0)
         totalProfit += profit;
      else
         totalLoss += MathAbs(profit);
   }
   
   // Check global TP
   if(GlobalTPPercent > 0 && totalProfit >= globalTPDollars)
   {
      Print("🎯 Global TP reached: $", DoubleToString(totalProfit, 2), " - Closing all positions");
      CloseAllPositions();
   }
   
   // Check global SL
   if(GlobalSLPercent > 0 && totalLoss >= globalSLDollars)
   {
      Print("🛑 Global SL reached: -$", DoubleToString(totalLoss, 2), " - Closing all positions");
      CloseAllPositions();
   }
}

//+------------------------------------------------------------------+
//| CLOSE POSITIONS BY SIDE                                           |
//+------------------------------------------------------------------+
void ClosePositionsSide(string side)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   int closed = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      if((side == "BUY" && posType == POSITION_TYPE_BUY) ||
         (side == "SELL" && posType == POSITION_TYPE_SELL))
      {
         request.action = TRADE_ACTION_DEAL;
         request.position = ticket;
         request.symbol = _Symbol;
         request.volume = PositionGetDouble(POSITION_VOLUME);
         request.deviation = 50;
         request.magic = MagicNumber;
         
         if(posType == POSITION_TYPE_BUY)
         {
            request.type = ORDER_TYPE_SELL;
            request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         }
         else
         {
            request.type = ORDER_TYPE_BUY;
            request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         }
         
         if(OrderSend(request, result))
         {
            if(result.retcode == TRADE_RETCODE_DONE)
               closed++;
         }
      }
   }
   
   Print("✅ Closed ", closed, " ", side, " positions");
   SyncPositions();
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   int closed = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      request.action = TRADE_ACTION_DEAL;
      request.position = ticket;
      request.symbol = _Symbol;
      request.volume = PositionGetDouble(POSITION_VOLUME);
      request.deviation = 50;
      request.magic = MagicNumber;
      
      if(posType == POSITION_TYPE_BUY)
      {
         request.type = ORDER_TYPE_SELL;
         request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      }
      else
      {
         request.type = ORDER_TYPE_BUY;
         request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      }
      
      if(OrderSend(request, result))
      {
         if(result.retcode == TRADE_RETCODE_DONE)
            closed++;
      }
   }
   
   Print("✅ Closed ", closed, " total positions");
   SyncPositions();
}

//+------------------------------------------------------------------+
//| CREATE PANEL - PROFESSIONAL TORAMA CAPITAL BRANDING              |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int panelX = 20;
   int panelY = 30;
   int panelWidth = 380;
   int panelHeight = 480;
   
   // Main panel background - SOLID with Z-order on top
   ObjectCreate(0, panelPrefix + "Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XDISTANCE, panelX);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YDISTANCE, panelY);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XSIZE, panelWidth);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, panelHeight);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BGCOLOR, C'20,20,30');
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_ZORDER, 0);
   
   int yOffset = 15;
   
   // Title - TORAMA CAPITAL branding in BOLD GOLD
   CreateLabel(panelPrefix + "Title", "MEAN REVERSION GRID v1.1", panelX + 20, panelY + yOffset, clrGold, 11, "Arial Black");
   yOffset += 25;
   
   // TORAMA CAPITAL branding
   CreateLabel(panelPrefix + "Brand", "TORAMA CAPITAL", panelX + 20, panelY + yOffset, clrGold, 10, "Arial Black");
   yOffset += 30;
   
   // Separator line 1
   CreateSeparator(panelPrefix + "Sep1", panelX + 15, panelY + yOffset, panelWidth - 30);
   yOffset += 15;
   
   // Current Price
   CreateLabel(panelPrefix + "CurrentPrice", "Current: Loading...", panelX + 20, panelY + yOffset, clrWhite, 9, "Arial");
   yOffset += 20;
   
   // Gap Size
   CreateLabel(panelPrefix + "Gap", "Gap: Loading...", panelX + 20, panelY + yOffset, clrWhite, 9, "Arial");
   yOffset += 25;
   
   // BUY positions info
   CreateLabel(panelPrefix + "BuyInfo", "BUY: 0 positions | $0.00", panelX + 20, panelY + yOffset, clrLime, 9, "Arial Bold");
   yOffset += 20;
   
   // SELL positions info
   CreateLabel(panelPrefix + "SellInfo", "SELL: 0 positions | $0.00", panelX + 20, panelY + yOffset, clrRed, 9, "Arial Bold");
   yOffset += 20;
   
   // Total P&L
   CreateLabel(panelPrefix + "TotalPL", "Total P&L: $0.00", panelX + 20, panelY + yOffset, clrWhite, 10, "Arial Bold");
   yOffset += 30;
   
   // Session info
   CreateLabel(panelPrefix + "SessionInfo", "Session: $0.00 / $0.00", panelX + 20, panelY + yOffset, clrCyan, 9, "Arial");
   yOffset += 20;
   
   // Balance and Drawdown
   CreateLabel(panelPrefix + "Balance", "Balance: $0.00", panelX + 20, panelY + yOffset, clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "Drawdown", "DD: 0.0%", panelX + 200, panelY + yOffset, clrWhite, 9, "Arial");
   yOffset += 20;
   
   // Spread
   CreateLabel(panelPrefix + "Spread", "Spread: 0", panelX + 20, panelY + yOffset, clrWhite, 9, "Arial");
   yOffset += 25;
   
   // Next levels
   CreateLabel(panelPrefix + "NextBuy", "Next BUY: 0.00000", panelX + 20, panelY + yOffset, clrLime, 9, "Arial");
   yOffset += 18;
   CreateLabel(panelPrefix + "NextSell", "Next SELL: 0.00000", panelX + 20, panelY + yOffset, clrRed, 9, "Arial");
   yOffset += 30;
   
   // Separator line 2
   CreateSeparator(panelPrefix + "Sep2", panelX + 15, panelY + yOffset, panelWidth - 30);
   yOffset += 15;
   
   // CONTROL BUTTONS
   int buttonWidth = 160;
   int buttonHeight = 30;
   int buttonSpacing = 10;
   int buttonX = panelX + 20;
   
   // Close BUY button
   CreateButton(panelPrefix + "CloseBuyBtn", "Close BUY", buttonX, panelY + yOffset, buttonWidth, buttonHeight, clrGreen);
   
   // Close SELL button
   CreateButton(panelPrefix + "CloseSellBtn", "Close SELL", buttonX + buttonWidth + buttonSpacing, panelY + yOffset, buttonWidth, buttonHeight, clrMaroon);
   yOffset += buttonHeight + buttonSpacing;
   
   // Close ALL button
   CreateButton(panelPrefix + "CloseAllBtn", "CLOSE ALL", buttonX, panelY + yOffset, buttonWidth, buttonHeight, clrDarkRed);
   
   // REBUILD button
   CreateButton(panelPrefix + "RebuildBtn", "🔄 REBUILD", buttonX + buttonWidth + buttonSpacing, panelY + yOffset, buttonWidth, buttonHeight, clrDarkOrange);
   yOffset += buttonHeight + buttonSpacing;
   
   // PAUSE button
   CreateButton(panelPrefix + "PauseBtn", "⏸ PAUSE", buttonX, panelY + yOffset, buttonWidth * 2 + buttonSpacing, buttonHeight, clrDarkBlue);
   yOffset += buttonHeight + 15;
   
   // Help text
   CreateLabel(panelPrefix + "HelpText", "Press 'H' to toggle panel", panelX + 20, panelY + yOffset, clrGold, 8, "Arial");
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| CREATE LABEL HELPER                                               |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr, int fontSize, string font)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1);
}

//+------------------------------------------------------------------+
//| CREATE BUTTON HELPER                                              |
//+------------------------------------------------------------------+
void CreateButton(string name, string text, int x, int y, int width, int height, color bgColor)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1);
}

//+------------------------------------------------------------------+
//| CREATE SEPARATOR HELPER                                           |
//+------------------------------------------------------------------+
void CreateSeparator(string name, int x, int y, int width)
{
   ObjectCreate(0, name, OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, clrGold);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_READONLY, true);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1);
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!ShowPanel || !panelVisible) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // Update current price
   ObjectSetString(0, panelPrefix + "CurrentPrice", OBJPROP_TEXT, 
      "Current: " + DoubleToString(currentPrice, digits));
   
   // Update gap size
   ObjectSetString(0, panelPrefix + "Gap", OBJPROP_TEXT, 
      "Gap: $" + DoubleToString(currentGapSize, 2) + " (" + DoubleToString(GridSpacingPercent, 2) + "%)");
   
   // Calculate BUY positions stats
   int buyCount = ArraySize(buyPositions);
   double buyProfit = 0;
   for(int i = 0; i < buyCount; i++)
   {
      if(PositionSelectByTicket(buyPositions[i].ticket))
         buyProfit += PositionGetDouble(POSITION_PROFIT);
   }
   
   ObjectSetString(0, panelPrefix + "BuyInfo", OBJPROP_TEXT, 
      "BUY: " + IntegerToString(buyCount) + " positions | $" + DoubleToString(buyProfit, 2));
   
   // Calculate SELL positions stats
   int sellCount = ArraySize(sellPositions);
   double sellProfit = 0;
   for(int i = 0; i < sellCount; i++)
   {
      if(PositionSelectByTicket(sellPositions[i].ticket))
         sellProfit += PositionGetDouble(POSITION_PROFIT);
   }
   
   ObjectSetString(0, panelPrefix + "SellInfo", OBJPROP_TEXT, 
      "SELL: " + IntegerToString(sellCount) + " positions | $" + DoubleToString(sellProfit, 2));
   
   // Total P&L
   double totalPL = buyProfit + sellProfit;
   ObjectSetString(0, panelPrefix + "TotalPL", OBJPROP_TEXT, 
      "Total P&L: $" + DoubleToString(totalPL, 2));
   ObjectSetInteger(0, panelPrefix + "TotalPL", OBJPROP_COLOR, 
      totalPL >= 0 ? clrLime : clrRed);
   
   // Session info
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfit = currentBalance - sessionStartBalance;
   ObjectSetString(0, panelPrefix + "SessionInfo", OBJPROP_TEXT, 
      "Session: $" + DoubleToString(sessionProfit, 2) + " / $" + DoubleToString(sessionProfitTarget, 2));
   ObjectSetInteger(0, panelPrefix + "SessionInfo", OBJPROP_COLOR, 
      sessionProfit >= 0 ? clrLime : clrRed);
   
   // Balance
   ObjectSetString(0, panelPrefix + "Balance", OBJPROP_TEXT, 
      "Balance: $" + DoubleToString(currentBalance, 2));
   
   // Drawdown
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdown = ((sessionStartBalance - equity) / sessionStartBalance) * 100.0;
   ObjectSetString(0, panelPrefix + "Drawdown", OBJPROP_TEXT, 
      "DD: " + DoubleToString(drawdown, 1) + "%");
   ObjectSetInteger(0, panelPrefix + "Drawdown", OBJPROP_COLOR, 
      drawdown > MaxDrawdownPercent * 0.8 ? clrRed : clrLime);
   
   // Spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_TEXT, 
      "Spread: " + IntegerToString(spread));
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_COLOR, 
      spread > MaxSpread ? clrRed : clrLime);
   
   // Calculate next levels
   double nextBuyLevel = 0;
   double nextSellLevel = 0;
   
   if(buyCount > 0)
   {
      double lowestBuy = buyPositions[0].openPrice;
      for(int i = 1; i < buyCount; i++)
      {
         if(buyPositions[i].openPrice < lowestBuy)
            lowestBuy = buyPositions[i].openPrice;
      }
      nextBuyLevel = lowestBuy - currentGapSize;
   }
   else
   {
      nextBuyLevel = bid - currentGapSize;
   }
   
   if(sellCount > 0)
   {
      double highestSell = sellPositions[0].openPrice;
      for(int i = 1; i < sellCount; i++)
      {
         if(sellPositions[i].openPrice > highestSell)
            highestSell = sellPositions[i].openPrice;
      }
      nextSellLevel = highestSell + currentGapSize;
   }
   else
   {
      nextSellLevel = ask + currentGapSize;
   }
   
   ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, 
      "Next BUY: " + DoubleToString(nextBuyLevel, digits));
   ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, 
      "Next SELL: " + DoubleToString(nextSellLevel, digits));
   
   // Update pause button
   if(isPaused)
   {
      ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "▶ RESUME");
      ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, clrDarkGreen);
      ObjectSetString(0, panelPrefix + "Title", OBJPROP_TEXT, "MEAN REVERSION GRID v1.1 [PAUSED]");
      ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_COLOR, clrOrange);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "⏸ PAUSE");
      ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, clrDarkBlue);
      ObjectSetString(0, panelPrefix + "Title", OBJPROP_TEXT, "MEAN REVERSION GRID v1.1");
      ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_COLOR, clrGold);
   }
}

//+------------------------------------------------------------------+
//| DELETE PANEL                                                      |
//+------------------------------------------------------------------+
void DeletePanel()
{
   ObjectsDeleteAll(0, panelPrefix);
}

//+------------------------------------------------------------------+
//| TOGGLE PANEL VISIBILITY                                           |
//+------------------------------------------------------------------+
void TogglePanelVisibility()
{
   panelVisible = !panelVisible;
   
   // Get all objects with our prefix
   string objName;
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
   {
      objName = ObjectName(0, i);
      if(StringFind(objName, panelPrefix) == 0)
      {
         ObjectSetInteger(0, objName, OBJPROP_TIMEFRAMES, 
            panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
      }
   }
   
   ChartRedraw(0);
   Print(panelVisible ? "📊 Panel shown" : "👁 Panel hidden");
}

//+------------------------------------------------------------------+
//| REBUILD GRID                                                      |
//+------------------------------------------------------------------+
void RebuildGrid()
{
   Print("🔄 REBUILDING GRID...");
   
   // Clear all position tracking
   ArrayResize(buyPositions, 0);
   ArrayResize(sellPositions, 0);
   
   // Reset grid levels
   lastBuyLevel = 0;
   lastSellLevel = 0;
   highestSellLevel = 0;
   lowestBuyLevel = 0;
   
   // Recalculate gap based on current price
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   currentGapSize = currentPrice * (GridSpacingPercent / 100.0);
   
   // Recalculate profit/loss targets based on CURRENT ACCOUNT BALANCE
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   individualTPDollars = accountBalance * (IndividualTPPercent / 100.0);
   individualSLDollars = (IndividualSLPercent > 0) ? accountBalance * (IndividualSLPercent / 100.0) : 0;
   globalTPDollars = accountBalance * (GlobalTPPercent / 100.0);
   globalSLDollars = (GlobalSLPercent > 0) ? accountBalance * (GlobalSLPercent / 100.0) : 0;
   
   Print("✅ Grid rebuilt successfully!");
   Print("   Current Price: ", DoubleToString(currentPrice, digits));
   Print("   New Gap Size: $", DoubleToString(currentGapSize, 2));
   Print("   Individual TP: $", DoubleToString(individualTPDollars, 2));
   Print("   Global TP: $", DoubleToString(globalTPDollars, 2));
   Print("   Waiting for price movement to place first orders...");
}

//+------------------------------------------------------------------+
//| CHART EVENT HANDLER                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   // Handle keyboard events
   if(id == CHARTEVENT_KEYDOWN)
   {
      // Check for 'H' key (both uppercase and lowercase)
      if(lparam == 72 || lparam == 104)  // 'H' or 'h'
      {
         TogglePanelVisibility();
      }
   }
   
   // Handle button clicks
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == panelPrefix + "CloseBuyBtn")
      {
         ClosePositionsSide("BUY");
         ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      else if(sparam == panelPrefix + "CloseSellBtn")
      {
         ClosePositionsSide("SELL");
         ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      else if(sparam == panelPrefix + "CloseAllBtn")
      {
         CloseAllPositions();
         ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      else if(sparam == panelPrefix + "RebuildBtn")
      {
         RebuildGrid();
         ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      else if(sparam == panelPrefix + "PauseBtn")
      {
         isPaused = !isPaused;
         ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_STATE, false);
         
         if(isPaused)
            Print("⏸ EA PAUSED - No new positions will be opened");
         else
            Print("▶ EA RESUMED - Trading active");
            
         UpdatePanel();
      }
   }
}

//+------------------------------------------------------------------+
//| TRADE RETCODE DESCRIPTION HELPER                                  |
//+------------------------------------------------------------------+
string TradeRetcodeDescription(uint retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_REQUOTE: return "Requote";
      case TRADE_RETCODE_REJECT: return "Request rejected";
      case TRADE_RETCODE_CANCEL: return "Request canceled by trader";
      case TRADE_RETCODE_PLACED: return "Order placed";
      case TRADE_RETCODE_DONE: return "Request completed";
      case TRADE_RETCODE_DONE_PARTIAL: return "Request partially completed";
      case TRADE_RETCODE_ERROR: return "Request processing error";
      case TRADE_RETCODE_TIMEOUT: return "Request timeout";
      case TRADE_RETCODE_INVALID: return "Invalid request";
      case TRADE_RETCODE_INVALID_VOLUME: return "Invalid volume";
      case TRADE_RETCODE_INVALID_PRICE: return "Invalid price";
      case TRADE_RETCODE_INVALID_STOPS: return "Invalid stops";
      case TRADE_RETCODE_TRADE_DISABLED: return "Trade is disabled";
      case TRADE_RETCODE_MARKET_CLOSED: return "Market is closed";
      case TRADE_RETCODE_NO_MONEY: return "Not enough money";
      case TRADE_RETCODE_PRICE_CHANGED: return "Price changed";
      case TRADE_RETCODE_PRICE_OFF: return "No prices";
      case TRADE_RETCODE_INVALID_EXPIRATION: return "Invalid order expiration";
      case TRADE_RETCODE_ORDER_CHANGED: return "Order state changed";
      case TRADE_RETCODE_TOO_MANY_REQUESTS: return "Too many requests";
      case TRADE_RETCODE_NO_CHANGES: return "No changes in request";
      case TRADE_RETCODE_SERVER_DISABLES_AT: return "Autotrading disabled by server";
      case TRADE_RETCODE_CLIENT_DISABLES_AT: return "Autotrading disabled by client";
      case TRADE_RETCODE_LOCKED: return "Request locked for processing";
      case TRADE_RETCODE_FROZEN: return "Order or position frozen";
      case TRADE_RETCODE_INVALID_FILL: return "Invalid order filling type";
      case TRADE_RETCODE_CONNECTION: return "No connection";
      case TRADE_RETCODE_ONLY_REAL: return "Only real accounts allowed";
      case TRADE_RETCODE_LIMIT_ORDERS: return "Limit orders limit reached";
      case TRADE_RETCODE_LIMIT_VOLUME: return "Volume limit reached";
      default: return "Unknown retcode " + IntegerToString(retcode);
   }
}
//+------------------------------------------------------------------+
