//+------------------------------------------------------------------+
//|                                      TORAMA_Momentum_Grid_v1_0.mq5 |
//|                                      Copyright 2025, TORAMA CAPITAL |
//|                                               https://torama.money |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.00"
#property description "Momentum Grid EA - Buy rising, Sell falling"
#property description "Opens positions in direction of price movement from reference"
#property description "Press 'H' to toggle panel visibility"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.30;        // Grid spacing % of price
input int      MaxPositionsPerSide = 30;         // Max positions per side (BUY or SELL)
input double   LotSize = 0.01;                   // Lot size per position

input group "=== PROFIT TARGETS (Dollar Values) ==="
input double   IndividualTPDollars = 50.0;       // Individual TP in dollars per position
input double   IndividualSLDollars = 0.0;        // Individual SL in dollars per position (0 = disabled)
input double   GlobalTPDollars = 200.0;          // Global TP in dollars for all positions
input double   GlobalSLDollars = 0.0;            // Global SL in dollars for all positions (0 = disabled)

input group "=== MOMENTUM LOGIC ==="
input int      ProfitableCountToClose = 5;       // Close all when X positions profitable (per side)
input bool     CloseBothSidesOnProfit = false;   // Close both BUY and SELL when one side profits

input group "=== RISK MANAGEMENT ==="
input double   SessionProfitPercent = 200.0;     // Session/Daily profit target (% of starting balance)
input bool     ResetSessionDaily = true;         // Reset session profit daily
input double   MaxDrawdownPercent = 15.0;        // Max drawdown % (emergency stop)

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                 // Maximum spread (points)
input int      MagicNumber = 77740;              // Magic number
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
double referencePrice = 0;        // The reference price for momentum trades
double lastBuyLevel = 0;
double lastSellLevel = 0;
double highestBuyLevel = 0;
double lowestSellLevel = 0;

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
string panelPrefix = "MomentumPanel_";

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
   
   // Set initial reference price
   referencePrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   
   // Calculate gap-based values
   currentGapSize = referencePrice * (GridSpacingPercent / 100.0);
   
   // Validate and normalize lot size
   normalizedLotSize = NormalizeLotSize(LotSize);
   
   // Display initialization info
   Print("╔════════════════════════════════════════════════════════════════╗");
   Print("║     TORAMA MOMENTUM GRID EA v1.0                               ║");
   Print("╚════════════════════════════════════════════════════════════════╝");
   Print("Symbol: ", _Symbol);
   Print("Account: ", AccountInfoString(ACCOUNT_NAME), " (", AccountInfoString(ACCOUNT_SERVER), ")");
   Print("Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("═══════════════════════════════════════");
   
   Print("📈 MOMENTUM MODE");
   Print("Strategy: Buy rising, Sell falling");
   Print("Reference Price: ", DoubleToString(referencePrice, digits));
   Print("Close when: ", ProfitableCountToClose, " positions profitable per side");
   Print("Close both sides: ", CloseBothSidesOnProfit ? "YES" : "NO");
   Print("Grid Spacing: ", GridSpacingPercent, "% = $", DoubleToString(currentGapSize, 2));
   Print("Max Positions: ", MaxPositionsPerSide, " per side (", MaxPositionsPerSide * 2, " total)");
   Print("Lot Size: ", DoubleToString(normalizedLotSize, 2), " (normalized from ", DoubleToString(LotSize, 2), ")");
   Print("Individual TP: $", DoubleToString(IndividualTPDollars, 2), " per position");
   Print("Individual SL: ", IndividualSLDollars > 0 ? "$" + DoubleToString(IndividualSLDollars, 2) + " per position" : "DISABLED");
   Print("Global TP: $", DoubleToString(GlobalTPDollars, 2), " total");
   Print("Global SL: ", GlobalSLDollars > 0 ? "$" + DoubleToString(GlobalSLDollars, 2) + " total" : "DISABLED");
   Print("Session Target: ", SessionProfitPercent, "% = $", DoubleToString(sessionProfitTarget, 2));
   Print("Max Drawdown: ", MaxDrawdownPercent, "%");
   Print("═══════════════════════════════════════");
   Print("💡 Press 'H' to toggle panel visibility");
   
   // Sync existing positions
   SyncPositions();
   
   Print("✅ EA initialized successfully!");
   Print("Waiting for price movement from reference...");
   
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
   
   // Check for daily session reset
   if(ResetSessionDaily)
   {
      MqlDateTime time;
      TimeToStruct(TimeCurrent(), time);
      if(time.day != currentDay)
      {
         currentDay = time.day;
         sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
         sessionProfit = 0;
         sessionTargetReached = false;
         lastSessionReset = TimeCurrent();
         Print("🔄 Daily session reset - New target: $", DoubleToString(sessionProfitTarget, 2));
      }
   }
   
   // Check if paused or session target reached
   if(isPaused)
   {
      return;
   }
   
   if(sessionTargetReached)
   {
      return;
   }
   
   // Sync positions with broker
   SyncPositions();
   
   // Check if all positions closed (auto-rebuild trigger)
   int totalPositions = ArraySize(buyPositions) + ArraySize(sellPositions);
   
   if(totalPositions == 0 && lastTotalPositions > 0)
   {
      // All positions just closed - auto rebuild
      Print("✅ All positions closed - Auto-rebuilding grid...");
      RebuildGrid();
   }
   
   lastTotalPositions = totalPositions;
   
   // Check spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      return;
   }
   
   // Check session profit target
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfit = currentBalance - sessionStartBalance;
   
   if(sessionProfit >= sessionProfitTarget)
   {
      sessionTargetReached = true;
      CloseAllPositions();
      Print("🎯 SESSION TARGET REACHED! Profit: $", DoubleToString(sessionProfit, 2));
      Print("   All positions closed. Reset session or restart EA to continue.");
      return;
   }
   
   // Check max drawdown
   double currentDrawdown = (sessionStartBalance - currentBalance) / sessionStartBalance * 100.0;
   if(currentDrawdown >= MaxDrawdownPercent)
   {
      CloseAllPositions();
      isPaused = true;
      Print("🛑 MAX DRAWDOWN REACHED! Drawdown: ", DoubleToString(currentDrawdown, 2), "%");
      Print("   All positions closed. EA paused. Review and restart manually.");
      return;
   }
   
   // Check profitable positions and close if threshold reached
   CheckProfitablePositions();
   
   // Check global profit/loss targets
   CheckGlobalTargets();
   
   // Place new grid orders based on momentum
   PlaceMomentumOrders();
}

//+------------------------------------------------------------------+
//| SAFE HELPER FUNCTIONS - ERROR HANDLING                            |
//+------------------------------------------------------------------+

// Safe price retrieval with validation
double GetSafePrice(ENUM_SYMBOL_INFO_DOUBLE price_type)
{
   double price = SymbolInfoDouble(_Symbol, price_type);
   if(price <= 0)
   {
      Print("❌ ERROR: Invalid price retrieved for ", EnumToString(price_type));
      return 0;
   }
   return price;
}

// Safe account info with validation
double GetSafeAccountInfo(ENUM_ACCOUNT_INFO_DOUBLE info_type)
{
   double value = AccountInfoDouble(info_type);
   if(value < 0)
   {
      Print("❌ ERROR: Invalid account info for ", EnumToString(info_type));
      return 0;
   }
   return value;
}

// Safe position ticket retrieval
ulong GetSafePositionTicket(int index)
{
   ulong ticket = PositionGetTicket(index);
   if(ticket <= 0)
   {
      // Position already closed or invalid index
      return 0;
   }
   return ticket;
}

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
   
   // CRITICAL VALIDATION
   if(pointValue <= 0)
   {
      Print("❌ CRITICAL: Invalid SYMBOL_POINT value: ", pointValue);
      return false;
   }
   
   if(tickSize <= 0)
   {
      Print("❌ CRITICAL: Invalid SYMBOL_TRADE_TICK_SIZE: ", tickSize);
      return false;
   }
   
   if(minLot <= 0 || maxLot <= 0)
   {
      Print("❌ CRITICAL: Invalid lot size limits - Min: ", minLot, " Max: ", maxLot);
      return false;
   }
   
   if(lotStep <= 0)
   {
      Print("❌ CRITICAL: Invalid SYMBOL_VOLUME_STEP: ", lotStep, " - Setting to 0.01");
      lotStep = 0.01; // Safe fallback
   }
   
   if(digits < 0 || digits > 8)
   {
      Print("⚠️ WARNING: Unusual digits value: ", digits, " - Using 5");
      digits = 5;
   }
   
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
   // Validate input
   if(lots <= 0)
   {
      Print("❌ ERROR: Invalid lot size input: ", lots, " - Using minimum");
      return minLot;
   }
   
   // Protect against division by zero
   if(lotStep <= 0)
   {
      Print("❌ CRITICAL: lotStep is zero or negative - Using default 0.01");
      lotStep = 0.01;
   }
   
   double normalizedLot = MathFloor(lots / lotStep) * lotStep;
   normalizedLot = MathMax(normalizedLot, minLot);
   normalizedLot = MathMin(normalizedLot, maxLot);
   
   // Final validation
   if(normalizedLot < minLot)
   {
      Print("⚠️ WARNING: Normalized lot ", normalizedLot, " below minimum - Using ", minLot);
      normalizedLot = minLot;
   }
   
   return NormalizeDouble(normalizedLot, 2);
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS WITH BROKER                                        |
//+------------------------------------------------------------------+
void SyncPositions()
{
   ArrayResize(buyPositions, 0);
   ArrayResize(sellPositions, 0);
   
   int totalPositions = PositionsTotal();
   if(totalPositions < 0)
   {
      Print("❌ ERROR: PositionsTotal returned negative value");
      return;
   }
   
   for(int i = totalPositions - 1; i >= 0; i--)
   {
      ulong ticket = GetSafePositionTicket(i);
      if(ticket <= 0) continue; // Position already closed or invalid
      
      // Validate symbol matches
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      
      // Validate magic number
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      // Get position details with validation
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double volume = PositionGetDouble(POSITION_VOLUME);
      
      if(openPrice <= 0 || volume <= 0)
      {
         Print("⚠️ WARNING: Invalid position data - Ticket: ", ticket);
         continue;
      }
      
      PositionInfo pos;
      pos.ticket = ticket;
      pos.openPrice = openPrice;
      pos.lotSize = volume;
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
//| PLACE MOMENTUM ORDERS                                             |
//+------------------------------------------------------------------+
void PlaceMomentumOrders()
{
   // If no reference price set, initialize it
   if(referencePrice == 0)
   {
      referencePrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
      Print("📍 Reference price set: ", DoubleToString(referencePrice, digits));
      return;
   }
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // MOMENTUM LOGIC: Only trade in the direction of movement from reference
   
   // BUY LOGIC: Only when price is ABOVE reference (rising momentum)
   if(currentPrice > referencePrice)
   {
      // Place BUY positions as price rises
      if(ArraySize(buyPositions) < MaxPositionsPerSide)
      {
         double nextBuyLevel = 0;
         
         if(ArraySize(buyPositions) == 0)
         {
            // First buy when above reference
            nextBuyLevel = referencePrice + currentGapSize;
         }
         else
         {
            // Find highest buy position and place next one above it
            double highestBuy = buyPositions[0].openPrice;
            for(int i = 1; i < ArraySize(buyPositions); i++)
            {
               if(buyPositions[i].openPrice > highestBuy)
                  highestBuy = buyPositions[i].openPrice;
            }
            nextBuyLevel = highestBuy + currentGapSize;
         }
         
         // Place buy if price reached next level
         if(ask >= nextBuyLevel && (lastBuyLevel == 0 || ask >= lastBuyLevel + currentGapSize))
         {
            if(OpenPosition("BUY", ask))
            {
               lastBuyLevel = ask;
               if(highestBuyLevel == 0 || ask > highestBuyLevel)
                  highestBuyLevel = ask;
            }
         }
      }
   }
   
   // SELL LOGIC: Only when price is BELOW reference (falling momentum)
   if(currentPrice < referencePrice)
   {
      // Place SELL positions as price falls
      if(ArraySize(sellPositions) < MaxPositionsPerSide)
      {
         double nextSellLevel = 0;
         
         if(ArraySize(sellPositions) == 0)
         {
            // First sell when below reference
            nextSellLevel = referencePrice - currentGapSize;
         }
         else
         {
            // Find lowest sell position and place next one below it
            double lowestSell = sellPositions[0].openPrice;
            for(int i = 1; i < ArraySize(sellPositions); i++)
            {
               if(sellPositions[i].openPrice < lowestSell)
                  lowestSell = sellPositions[i].openPrice;
            }
            nextSellLevel = lowestSell - currentGapSize;
         }
         
         // Place sell if price reached next level
         if(bid <= nextSellLevel && (lastSellLevel == 0 || bid <= lastSellLevel - currentGapSize))
         {
            if(OpenPosition("SELL", bid))
            {
               lastSellLevel = bid;
               if(lowestSellLevel == 0 || bid < lowestSellLevel)
                  lowestSellLevel = bid;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| OPEN POSITION                                                     |
//+------------------------------------------------------------------+
bool OpenPosition(string type, double price)
{
   // Validate inputs
   if(type != "BUY" && type != "SELL")
   {
      Print("❌ ERROR: Invalid position type: ", type);
      return false;
   }
   
   if(normalizedLotSize <= 0)
   {
      Print("❌ ERROR: Invalid lot size: ", normalizedLotSize);
      return false;
   }
   
   // Get fresh prices with validation
   double ask = GetSafePrice(SYMBOL_ASK);
   double bid = GetSafePrice(SYMBOL_BID);
   
   if(ask <= 0 || bid <= 0)
   {
      Print("❌ ERROR: Invalid prices - Ask: ", ask, " Bid: ", bid);
      return false;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = normalizedLotSize;
   request.deviation = 50;
   request.magic = MagicNumber;
   request.comment = "TORAMA_Momentum";
   request.type_filling = ORDER_FILLING_FOK; // Fill or Kill
   
   double tp_price = 0;
   double sl_price = 0;
   double entry_price = 0;
   
   if(type == "BUY")
   {
      request.type = ORDER_TYPE_BUY;
      request.price = ask;
      entry_price = ask;
      
      // Calculate TP with validation
      if(normalizedLotSize > 0 && IndividualTPDollars > 0)
      {
         double tp_price_change = IndividualTPDollars / (normalizedLotSize * 100);
         tp_price = ask + tp_price_change;
      }
      
      // Calculate SL if enabled
      if(IndividualSLDollars > 0 && normalizedLotSize > 0)
      {
         double sl_price_change = IndividualSLDollars / (normalizedLotSize * 100);
         sl_price = ask - sl_price_change;
      }
   }
   else // SELL
   {
      request.type = ORDER_TYPE_SELL;
      request.price = bid;
      entry_price = bid;
      
      // Calculate TP with validation
      if(normalizedLotSize > 0 && IndividualTPDollars > 0)
      {
         double tp_price_change = IndividualTPDollars / (normalizedLotSize * 100);
         tp_price = bid - tp_price_change;
      }
      
      // Calculate SL if enabled
      if(IndividualSLDollars > 0 && normalizedLotSize > 0)
      {
         double sl_price_change = IndividualSLDollars / (normalizedLotSize * 100);
         sl_price = bid + sl_price_change;
      }
   }
   
   // Validate TP/SL distances
   double minDistance = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * pointValue;
   
   if(tp_price > 0)
   {
      double tp_distance = MathAbs(tp_price - entry_price);
      if(tp_distance < minDistance)
      {
         Print("⚠️ WARNING: TP too close to entry. Distance: ", tp_distance, " Min: ", minDistance);
         tp_price = 0; // Disable TP if too close
      }
   }
   
   if(sl_price > 0)
   {
      double sl_distance = MathAbs(sl_price - entry_price);
      if(sl_distance < minDistance)
      {
         Print("⚠️ WARNING: SL too close to entry. Distance: ", sl_distance, " Min: ", minDistance);
         sl_price = 0; // Disable SL if too close
      }
   }
   
   request.tp = tp_price;
   request.sl = sl_price;
   
   // Try to send order with retry logic
   int maxRetries = 3;
   for(int retry = 0; retry < maxRetries; retry++)
   {
      bool success = OrderSend(request, result);
      
      if(success && result.retcode == TRADE_RETCODE_DONE)
      {
         Print("✅ ", type, " opened at ", DoubleToString(entry_price, digits), 
               " | Ticket: ", result.order,
               " | TP: ", DoubleToString(tp_price, digits),
               (sl_price > 0 ? " | SL: " + DoubleToString(sl_price, digits) : ""),
               " | Gap from ref: $", DoubleToString(MathAbs(entry_price - referencePrice), 2));
         return true;
      }
      
      // Handle specific error cases
      if(result.retcode == TRADE_RETCODE_REQUOTE || 
         result.retcode == TRADE_RETCODE_PRICE_CHANGED ||
         result.retcode == TRADE_RETCODE_PRICE_OFF)
      {
         Print("⚠️ RETRY ", retry + 1, "/", maxRetries, ": ", TradeRetcodeDescription(result.retcode));
         
         // Update price and retry
         if(type == "BUY")
            request.price = GetSafePrice(SYMBOL_ASK);
         else
            request.price = GetSafePrice(SYMBOL_BID);
            
         Sleep(100); // Small delay before retry
         continue;
      }
      
      // Non-retryable error
      Print("❌ Failed to open ", type, " | Error: ", TradeRetcodeDescription(result.retcode), 
            " | Retcode: ", result.retcode);
      return false;
   }
   
   Print("❌ Failed to open ", type, " after ", maxRetries, " retries");
   return false;
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
         if(profit >= IndividualTPDollars)
            profitableBuys++;
      }
   }
   
   // Count profitable SELL positions
   for(int i = 0; i < ArraySize(sellPositions); i++)
   {
      if(PositionSelectByTicket(sellPositions[i].ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit >= IndividualTPDollars)
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
   if(GlobalTPDollars > 0 && totalProfit >= GlobalTPDollars)
   {
      Print("🎯 Global TP reached: $", DoubleToString(totalProfit, 2), " - Closing all positions");
      CloseAllPositions();
   }
   
   // Check global SL
   if(GlobalSLDollars > 0 && totalLoss >= GlobalSLDollars)
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
//| CREATE PANEL                                                      |
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
   ObjectCreate(0, panelPrefix + "Title", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "Title", OBJPROP_TEXT, "MOMENTUM GRID v1.0");
   ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_FONTSIZE, 12);
   ObjectSetString(0, panelPrefix + "Title", OBJPROP_FONT, "Arial Black");
   ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_ZORDER, 1);
   yOffset += 25;
   
   // TORAMA CAPITAL branding
   ObjectCreate(0, panelPrefix + "Brand", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_TEXT, "TORAMA CAPITAL");
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_FONT, "Arial Black");
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_ZORDER, 1);
   yOffset += 30;
   
   // Separator line 1
   ObjectCreate(0, panelPrefix + "Sep1", OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Sep1", OBJPROP_XDISTANCE, panelX + 15);
   ObjectSetInteger(0, panelPrefix + "Sep1", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetInteger(0, panelPrefix + "Sep1", OBJPROP_XSIZE, panelWidth - 30);
   ObjectSetInteger(0, panelPrefix + "Sep1", OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, panelPrefix + "Sep1", OBJPROP_BGCOLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Sep1", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Sep1", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Sep1", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Sep1", OBJPROP_READONLY, true);
   ObjectSetInteger(0, panelPrefix + "Sep1", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Sep1", OBJPROP_ZORDER, 1);
   yOffset += 15;
   
   // Reference Price
   ObjectCreate(0, panelPrefix + "RefPrice", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "RefPrice", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "RefPrice", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, "Reference: Loading...");
   ObjectSetInteger(0, panelPrefix + "RefPrice", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, panelPrefix + "RefPrice", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, panelPrefix + "RefPrice", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "RefPrice", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "RefPrice", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "RefPrice", OBJPROP_ZORDER, 1);
   yOffset += 20;
   
   // Current Price
   ObjectCreate(0, panelPrefix + "CurrentPrice", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "CurrentPrice", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "CurrentPrice", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "CurrentPrice", OBJPROP_TEXT, "Current: Loading...");
   ObjectSetInteger(0, panelPrefix + "CurrentPrice", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, panelPrefix + "CurrentPrice", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, panelPrefix + "CurrentPrice", OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, panelPrefix + "CurrentPrice", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "CurrentPrice", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "CurrentPrice", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "CurrentPrice", OBJPROP_ZORDER, 1);
   yOffset += 20;
   
   // Gap Size
   ObjectCreate(0, panelPrefix + "GapSize", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "GapSize", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "GapSize", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "GapSize", OBJPROP_TEXT, "Gap: Loading...");
   ObjectSetInteger(0, panelPrefix + "GapSize", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, panelPrefix + "GapSize", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, panelPrefix + "GapSize", OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, panelPrefix + "GapSize", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "GapSize", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "GapSize", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "GapSize", OBJPROP_ZORDER, 1);
   yOffset += 25;
   
   // BUY positions info
   ObjectCreate(0, panelPrefix + "BuyInfo", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "BuyInfo", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "BuyInfo", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "BuyInfo", OBJPROP_TEXT, "BUY: 0 positions | $0.00");
   ObjectSetInteger(0, panelPrefix + "BuyInfo", OBJPROP_COLOR, clrLime);
   ObjectSetInteger(0, panelPrefix + "BuyInfo", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, panelPrefix + "BuyInfo", OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, panelPrefix + "BuyInfo", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "BuyInfo", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "BuyInfo", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "BuyInfo", OBJPROP_ZORDER, 1);
   yOffset += 20;
   
   // SELL positions info
   ObjectCreate(0, panelPrefix + "SellInfo", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "SellInfo", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "SellInfo", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "SellInfo", OBJPROP_TEXT, "SELL: 0 positions | $0.00");
   ObjectSetInteger(0, panelPrefix + "SellInfo", OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, panelPrefix + "SellInfo", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, panelPrefix + "SellInfo", OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, panelPrefix + "SellInfo", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "SellInfo", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "SellInfo", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "SellInfo", OBJPROP_ZORDER, 1);
   yOffset += 20;
   
   // Total P&L
   ObjectCreate(0, panelPrefix + "TotalPL", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "TotalPL", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "TotalPL", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "TotalPL", OBJPROP_TEXT, "Total P&L: $0.00");
   ObjectSetInteger(0, panelPrefix + "TotalPL", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, panelPrefix + "TotalPL", OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, panelPrefix + "TotalPL", OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, panelPrefix + "TotalPL", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "TotalPL", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "TotalPL", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "TotalPL", OBJPROP_ZORDER, 1);
   yOffset += 30;
   
   // Session info
   ObjectCreate(0, panelPrefix + "SessionInfo", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "SessionInfo", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "SessionInfo", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "SessionInfo", OBJPROP_TEXT, "Session: $0.00 / $0.00");
   ObjectSetInteger(0, panelPrefix + "SessionInfo", OBJPROP_COLOR, clrCyan);
   ObjectSetInteger(0, panelPrefix + "SessionInfo", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, panelPrefix + "SessionInfo", OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, panelPrefix + "SessionInfo", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "SessionInfo", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "SessionInfo", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "SessionInfo", OBJPROP_ZORDER, 1);
   yOffset += 25;
   
   // Balance info
   ObjectCreate(0, panelPrefix + "Balance", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Balance", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "Balance", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "Balance", OBJPROP_TEXT, "Balance: $0.00");
   ObjectSetInteger(0, panelPrefix + "Balance", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, panelPrefix + "Balance", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, panelPrefix + "Balance", OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, panelPrefix + "Balance", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Balance", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Balance", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Balance", OBJPROP_ZORDER, 1);
   yOffset += 25;
   
   // Spread display
   ObjectCreate(0, panelPrefix + "Spread", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_TEXT, "Spread: 0 pts");
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_COLOR, clrLime);
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_ZORDER, 1);
   yOffset += 25;
   
   // Next BUY level
   ObjectCreate(0, panelPrefix + "NextBuy", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "NextBuy", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "NextBuy", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, "Next BUY: 0.00000");
   ObjectSetInteger(0, panelPrefix + "NextBuy", OBJPROP_COLOR, clrLime);
   ObjectSetInteger(0, panelPrefix + "NextBuy", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, panelPrefix + "NextBuy", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "NextBuy", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "NextBuy", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "NextBuy", OBJPROP_ZORDER, 1);
   yOffset += 18;
   
   // Next SELL level
   ObjectCreate(0, panelPrefix + "NextSell", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "NextSell", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "NextSell", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, "Next SELL: 0.00000");
   ObjectSetInteger(0, panelPrefix + "NextSell", OBJPROP_COLOR, clrRed);
   ObjectSetInteger(0, panelPrefix + "NextSell", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, panelPrefix + "NextSell", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "NextSell", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "NextSell", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "NextSell", OBJPROP_ZORDER, 1);
   yOffset += 25;
   
   // Separator line 2
   ObjectCreate(0, panelPrefix + "Sep2", OBJ_EDIT, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Sep2", OBJPROP_XDISTANCE, panelX + 15);
   ObjectSetInteger(0, panelPrefix + "Sep2", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetInteger(0, panelPrefix + "Sep2", OBJPROP_XSIZE, panelWidth - 30);
   ObjectSetInteger(0, panelPrefix + "Sep2", OBJPROP_YSIZE, 1);
   ObjectSetInteger(0, panelPrefix + "Sep2", OBJPROP_BGCOLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Sep2", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Sep2", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Sep2", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Sep2", OBJPROP_READONLY, true);
   ObjectSetInteger(0, panelPrefix + "Sep2", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Sep2", OBJPROP_ZORDER, 1);
   yOffset += 15;
   
   // CONTROL BUTTONS
   int buttonWidth = 160;
   int buttonHeight = 30;
   int buttonSpacing = 10;
   int buttonX = panelX + 20;
   
   // Close BUY button
   ObjectCreate(0, panelPrefix + "CloseBuyBtn", OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_XDISTANCE, buttonX);
   ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_XSIZE, buttonWidth);
   ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_YSIZE, buttonHeight);
   ObjectSetString(0, panelPrefix + "CloseBuyBtn", OBJPROP_TEXT, "Close BUY");
   ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_BGCOLOR, clrGreen);
   ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, panelPrefix + "CloseBuyBtn", OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "CloseBuyBtn", OBJPROP_ZORDER, 1);
   
   // Close SELL button
   ObjectCreate(0, panelPrefix + "CloseSellBtn", OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_XDISTANCE, buttonX + buttonWidth + buttonSpacing);
   ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_XSIZE, buttonWidth);
   ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_YSIZE, buttonHeight);
   ObjectSetString(0, panelPrefix + "CloseSellBtn", OBJPROP_TEXT, "Close SELL");
   ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_BGCOLOR, clrMaroon);
   ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, panelPrefix + "CloseSellBtn", OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "CloseSellBtn", OBJPROP_ZORDER, 1);
   yOffset += buttonHeight + buttonSpacing;
   
   // Close ALL button
   ObjectCreate(0, panelPrefix + "CloseAllBtn", OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_XDISTANCE, buttonX);
   ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_XSIZE, buttonWidth);
   ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_YSIZE, buttonHeight);
   ObjectSetString(0, panelPrefix + "CloseAllBtn", OBJPROP_TEXT, "CLOSE ALL");
   ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_BGCOLOR, clrDarkRed);
   ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, panelPrefix + "CloseAllBtn", OBJPROP_FONT, "Arial Black");
   ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_ZORDER, 1);
   
   // REBUILD button
   ObjectCreate(0, panelPrefix + "RebuildBtn", OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_XDISTANCE, buttonX + buttonWidth + buttonSpacing);
   ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_XSIZE, buttonWidth);
   ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_YSIZE, buttonHeight);
   ObjectSetString(0, panelPrefix + "RebuildBtn", OBJPROP_TEXT, "🔄 REBUILD");
   ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_BGCOLOR, clrDarkOrange);
   ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, panelPrefix + "RebuildBtn", OBJPROP_FONT, "Arial Black");
   ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "RebuildBtn", OBJPROP_ZORDER, 1);
   yOffset += buttonHeight + buttonSpacing;
   
   // PAUSE button
   ObjectCreate(0, panelPrefix + "PauseBtn", OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_XDISTANCE, buttonX);
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_XSIZE, buttonWidth * 2 + buttonSpacing);
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_YSIZE, buttonHeight);
   ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "⏸ PAUSE");
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, clrDarkBlue);
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_FONTSIZE, 10);
   ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_FONT, "Arial Black");
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_ZORDER, 1);
   yOffset += buttonHeight + 15;
   
   // Help text
   ObjectCreate(0, panelPrefix + "HelpText", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "HelpText", OBJPROP_XDISTANCE, panelX + 20);
   ObjectSetInteger(0, panelPrefix + "HelpText", OBJPROP_YDISTANCE, panelY + yOffset);
   ObjectSetString(0, panelPrefix + "HelpText", OBJPROP_TEXT, "Press 'H' to toggle panel");
   ObjectSetInteger(0, panelPrefix + "HelpText", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "HelpText", OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, panelPrefix + "HelpText", OBJPROP_FONT, "Arial");
   ObjectSetInteger(0, panelPrefix + "HelpText", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "HelpText", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "HelpText", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "HelpText", OBJPROP_ZORDER, 1);
   
   ChartRedraw(0);
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
   
   // Update reference price
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, 
      "Reference: " + DoubleToString(referencePrice, digits));
   
   // Update current price with direction indicator
   string direction = "";
   color priceColor = clrWhite;
   if(currentPrice > referencePrice)
   {
      direction = " ↑ ABOVE";
      priceColor = clrLime;
   }
   else if(currentPrice < referencePrice)
   {
      direction = " ↓ BELOW";
      priceColor = clrRed;
   }
   else
   {
      direction = " = AT REF";
      priceColor = clrYellow;
   }
   
   ObjectSetString(0, panelPrefix + "CurrentPrice", OBJPROP_TEXT, 
      "Current: " + DoubleToString(currentPrice, digits) + direction);
   ObjectSetInteger(0, panelPrefix + "CurrentPrice", OBJPROP_COLOR, priceColor);
   
   // Update gap size
   ObjectSetString(0, panelPrefix + "GapSize", OBJPROP_TEXT, 
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
   
   // Spread with color coding
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   color spreadColor = clrLime;
   if(currentSpread > MaxSpread * 0.8) // Over 80% of max
      spreadColor = clrOrange;
   if(currentSpread > MaxSpread)
      spreadColor = clrRed;
   
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_TEXT, 
      "Spread: " + IntegerToString(currentSpread) + " pts (Max: " + IntegerToString(MaxSpread) + ")");
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_COLOR, spreadColor);
   
   // Calculate next BUY level (MOMENTUM: Only buy when ABOVE reference)
   double nextBuyLevel = 0;
   string nextBuyText = "Next BUY: Waiting...";
   
   if(referencePrice > 0 && currentPrice > referencePrice)
   {
      // We're above reference, so BUY orders are active
      if(buyCount == 0)
      {
         // First buy at reference + 1 gap
         nextBuyLevel = referencePrice + currentGapSize;
      }
      else
      {
         // Find highest buy position
         double highestBuy = buyPositions[0].openPrice;
         for(int i = 1; i < buyCount; i++)
         {
            if(buyPositions[i].openPrice > highestBuy)
               highestBuy = buyPositions[i].openPrice;
         }
         nextBuyLevel = highestBuy + currentGapSize;
      }
      nextBuyText = "Next BUY: " + DoubleToString(nextBuyLevel, digits);
   }
   else if(referencePrice > 0)
   {
      nextBuyText = "Next BUY: N/A (below ref)";
   }
   
   // Calculate next SELL level (MOMENTUM: Only sell when BELOW reference)
   double nextSellLevel = 0;
   string nextSellText = "Next SELL: Waiting...";
   
   if(referencePrice > 0 && currentPrice < referencePrice)
   {
      // We're below reference, so SELL orders are active
      if(sellCount == 0)
      {
         // First sell at reference - 1 gap
         nextSellLevel = referencePrice - currentGapSize;
      }
      else
      {
         // Find lowest sell position
         double lowestSell = sellPositions[0].openPrice;
         for(int i = 1; i < sellCount; i++)
         {
            if(sellPositions[i].openPrice < lowestSell)
               lowestSell = sellPositions[i].openPrice;
         }
         nextSellLevel = lowestSell - currentGapSize;
      }
      nextSellText = "Next SELL: " + DoubleToString(nextSellLevel, digits);
   }
   else if(referencePrice > 0)
   {
      nextSellText = "Next SELL: N/A (above ref)";
   }
   
   ObjectSetString(0, panelPrefix + "NextBuy", OBJPROP_TEXT, nextBuyText);
   ObjectSetString(0, panelPrefix + "NextSell", OBJPROP_TEXT, nextSellText);
   
   // Update pause button
   if(isPaused)
   {
      ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "▶ RESUME");
      ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, clrDarkGreen);
      ObjectSetString(0, panelPrefix + "Title", OBJPROP_TEXT, "MOMENTUM GRID v1.0 [PAUSED]");
      ObjectSetInteger(0, panelPrefix + "Title", OBJPROP_COLOR, clrOrange);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, "⏸ PAUSE");
      ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, clrDarkBlue);
      ObjectSetString(0, panelPrefix + "Title", OBJPROP_TEXT, "MOMENTUM GRID v1.0");
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
   highestBuyLevel = 0;
   lowestSellLevel = 0;
   
   // Reset reference price to current with validation
   double ask = GetSafePrice(SYMBOL_ASK);
   double bid = GetSafePrice(SYMBOL_BID);
   
   if(ask <= 0 || bid <= 0)
   {
      Print("❌ ERROR: Cannot rebuild grid - Invalid prices");
      return;
   }
   
   double currentPrice = (ask + bid) / 2.0;
   referencePrice = currentPrice;
   
   // Recalculate gap based on new reference price with validation
   if(GridSpacingPercent <= 0 || GridSpacingPercent > 100)
   {
      Print("❌ ERROR: Invalid GridSpacingPercent: ", GridSpacingPercent);
      return;
   }
   
   currentGapSize = referencePrice * (GridSpacingPercent / 100.0);
   
   // Validate gap size
   if(currentGapSize <= 0)
   {
      Print("❌ CRITICAL: Gap size calculated as zero or negative: ", currentGapSize);
      currentGapSize = referencePrice * 0.001; // 0.1% fallback
      Print("   Using fallback gap: ", currentGapSize);
   }
   
   Print("✅ Grid rebuilt successfully!");
   Print("   Reference Price: ", DoubleToString(referencePrice, digits));
   Print("   New Gap Size: $", DoubleToString(currentGapSize, 2));
   Print("   Individual TP: $", DoubleToString(IndividualTPDollars, 2));
   Print("   Global TP: $", DoubleToString(GlobalTPDollars, 2));
   Print("   Waiting for price movement from reference...");
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
//| ERROR DESCRIPTION HELPER                                          |
//+------------------------------------------------------------------+
string ErrorDescription(int error)
{
   switch(error)
   {
      case 0: return "No error";
      case 1: return "No error, trade server returned no error code";
      case 2: return "Common error";
      case 3: return "Invalid trade parameters";
      case 4: return "Trade server is busy";
      case 5: return "Old version of the client terminal";
      case 6: return "No connection with trade server";
      case 7: return "Not enough rights";
      case 8: return "Too frequent requests";
      case 9: return "Malfunctional trade operation";
      case 64: return "Account disabled";
      case 65: return "Invalid account";
      case 128: return "Trade timeout";
      case 129: return "Invalid price";
      case 130: return "Invalid stops";
      case 131: return "Invalid trade volume";
      case 132: return "Market is closed";
      case 133: return "Trade is disabled";
      case 134: return "Not enough money";
      case 135: return "Price changed";
      case 136: return "Off quotes";
      case 137: return "Broker is busy";
      case 138: return "Requote";
      case 139: return "Order is locked";
      case 140: return "Long positions only allowed";
      case 141: return "Too many requests";
      case 145: return "Modification denied because order too close to market";
      case 146: return "Trade context is busy";
      case 147: return "Expirations are denied by broker";
      case 148: return "Amount of open and pending orders has reached the limit";
      case 149: return "Hedging is prohibited";
      case 150: return "Prohibited by FIFO rules";
      default: return "Unknown error " + IntegerToString(error);
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
