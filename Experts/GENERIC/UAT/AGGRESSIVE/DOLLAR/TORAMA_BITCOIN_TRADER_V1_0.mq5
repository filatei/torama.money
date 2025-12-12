//+------------------------------------------------------------------+
//|                    TORAMA Bitcoin Trader EA v1.0                 |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "1.0"
#property description "Bitcoin-Optimized Grid Trader with ATR Mode Switching"
#property description "Designed for BTC's high spreads and volatility"
#property description "Wider grids, larger targets, spread-aware profit targets"

#define EA_VERSION "1.0"
#define EA_NAME "TORAMA BITCOIN TRADER"

//+------------------------------------------------------------------+
//| ENUMS                                                             |
//+------------------------------------------------------------------+
enum ENUM_TRADE_DIRECTION
{
   BUYONLY,   // BUY ONLY - Buys dips, sells at profit
   SELLONLY   // SELL ONLY - Sells rallies, buys back at profit
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS - BITCOIN OPTIMIZED                             |
//+------------------------------------------------------------------+

// === DIRECTION & ATR MODE SWITCHING ===
input group "=== DIRECTION & ATR MODE SWITCHING ==="
input ENUM_TRADE_DIRECTION StartDirection = BUYONLY;  // Starting Direction
input bool     EnableATRSwitch = true;                // Enable ATR-based mode switching
input int      ATRPeriod = 14;                        // ATR Period for mode switching
input double   ATRThresholdPercent = 70.0;            // ATR Threshold % (0.7 × ATR)
input bool     CloseOnModeSwitch = false;             // Close positions on mode switch (false = let run)

// === GRID SETTINGS - WIDER FOR BITCOIN ===
input group "=== GRID SETTINGS ==="
input double   GridGapPercent = 0.05;                 // Grid gap % (0.05% = ~$53 at $105K BTC)
input int      MaxPositions = 30;                     // Maximum positions

// === POSITION SIZING ===
input group "=== POSITION SIZING ==="
input double   LotSize = 0.02;                        // Lot size per position (0.02 BTC)

// === TAKE PROFIT - SPREAD AWARE ===
input group "=== TAKE PROFIT ==="
input double   IndividualTPDollars = 50.0;            // Individual TP target ($50 per position)
input double   GroupTPDollars = 200.0;                // Group TP ($200 total profit closes all)

// === STOP LOSS ===
input group "=== STOP LOSS ==="
input double   IndividualSLDollars = 100.0;           // SL risk per trade ($100 max loss)

// === RISK MANAGEMENT ===
input group "=== RISK MANAGEMENT ==="
input double   MaxDrawdownPercent = 20.0;             // Max drawdown % (emergency stop)
input double   DailyTargetPercent = 5.0;              // Daily profit target %
input int      MaxSpread = 2500;                      // Max spread in points (2500 = $25)

// === PANEL DISPLAY ===
input group "=== PANEL DISPLAY ==="
input bool     ShowPanel = true;                      // Show info panel

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

// Direction
ENUM_TRADE_DIRECTION CurrentDirection;

// ATR Mode Switching
int atrHandle = INVALID_HANDLE;
double dayOpenPrice = 0;
double currentATR = 0;
datetime lastDayOpenUpdate = 0;
datetime lastModeSwitchTime = 0;
int modeSwitchCooldownBars = 100;  // 100 M1 bars = ~1.5 hours

// Grid
double referencePrice = 0;
double currentGapSize = 0;

// Emergency stop
bool emergencyStop = false;
string emergencyReason = "";
double peakEquity = 0;
double totalProfit = 0;

// Daily tracking
double dailyStartBalance = 0;
double dailyProfit = 0;
double dailyTarget = 0;
datetime lastDayCheck = 0;
int currentDay = 0;
bool dailyTargetReached = false;

// Counters
int totalTrades = 0;
bool isPaused = false;
int modeSwitchCount = 0;

// Magic Number (unique identifier)
int MagicNumber = 0;

// Panel
string panelPrefix = "TORAMA_BTC_";
bool panelVisible = true;

// Symbol specifications
struct SymbolSpecs
{
   double contractSize;
   double tickValue;
   double tickSize;
   double point;
   long stopLevel;
   int digits;
   double minLot;
   double maxLot;
   double lotStep;
   double minStopDistance;
} specs;

// Position tracking
struct Position
{
   ulong ticket;
   double entryPrice;
   datetime entryTime;
};
Position positions[];

double validatedLotSize = 0;

//+------------------------------------------------------------------+
//| EXPERT INITIALIZATION                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set magic number based on chart
   MagicNumber = (int)ChartID() % 100000 + 70000;
   
   string separator = "";
   StringInit(separator, 70, '=');
   Print(separator);
   Print("🚀 ", EA_NAME, " v", EA_VERSION, " - Initializing...");
   Print(separator);
   
   CurrentDirection = StartDirection;
   
   // Initialize symbol specs
   if(!InitializeSymbolSpecs())
   {
      Print("❌ Failed to initialize symbol specs");
      return(INIT_FAILED);
   }
   
   // Validate lot size
   validatedLotSize = ValidateLotSize(LotSize);
   if(validatedLotSize == 0)
   {
      Print("❌ Invalid lot size");
      return(INIT_FAILED);
   }
   
   // Validate grid gap
   if(!ValidateGridGap())
   {
      Print("❌ Grid gap validation failed");
      return(INIT_FAILED);
   }
   
   // Initialize ATR for mode switching
   if(EnableATRSwitch)
   {
      atrHandle = iATR(_Symbol, PERIOD_D1, ATRPeriod);
      if(atrHandle == INVALID_HANDLE)
      {
         Print("❌ Failed to create ATR indicator");
         return(INIT_FAILED);
      }
      
      // Wait for indicator
      if(!WaitForIndicator(atrHandle))
      {
         Print("❌ ATR indicator initialization timeout");
         return(INIT_FAILED);
      }
      
      // Initialize day open price
      UpdateDayOpenPrice();
      
      Print("✅ ATR Mode Switching enabled (Period: ", ATRPeriod, ", Threshold: ", ATRThresholdPercent, "%)");
   }
   
   // Initialize tracking
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   dailyStartBalance = balance;
   dailyTarget = balance * DailyTargetPercent / 100.0;
   
   MqlDateTime timeStruct;
   TimeToStruct(TimeCurrent(), timeStruct);
   currentDay = timeStruct.day;
   lastDayCheck = TimeCurrent();
   
   // Initialize reference price
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   referencePrice = currentPrice;
   currentGapSize = referencePrice * GridGapPercent / 100.0;
   
   // Create panel
   if(ShowPanel)
      CreatePanel();
   
   // Print risk analysis
   PrintRiskAnalysis();
   
   // Sync existing positions
   SyncPositions();
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| UPDATE DAY OPEN PRICE                                            |
//+------------------------------------------------------------------+
void UpdateDayOpenPrice()
{
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   
   // Get the open price of the current day
   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_D1, 0, 1, rates);
   
   if(copied > 0)
   {
      dayOpenPrice = rates[0].open;
      lastDayOpenUpdate = TimeCurrent();
      
      Print("📅 Day Open Price Updated: $", DoubleToString(dayOpenPrice, specs.digits));
   }
   else
   {
      Print("⚠️ WARNING: Could not retrieve day's open price");
   }
}

//+------------------------------------------------------------------+
//| CHECK ATR MODE SWITCHING                                         |
//+------------------------------------------------------------------+
void CheckATRModeSwitch()
{
   if(!EnableATRSwitch) return;
   
   // Check cooldown period
   if(TimeCurrent() - lastModeSwitchTime < modeSwitchCooldownBars * PeriodSeconds())
      return;
   
   // Update ATR value
   if(atrHandle != INVALID_HANDLE)
   {
      double atr_buffer[];
      ArraySetAsSeries(atr_buffer, true);
      
      if(CopyBuffer(atrHandle, 0, 0, 1, atr_buffer) > 0)
      {
         currentATR = atr_buffer[0];
      }
      else
      {
         return;
      }
   }
   else
   {
      return;
   }
   
   if(currentATR <= 0) return;
   if(dayOpenPrice <= 0) return;
   
   // Get current price
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // Calculate distance from day's open
   double distanceFromOpen = currentPrice - dayOpenPrice;
   double atrThreshold = currentATR * (ATRThresholdPercent / 100.0);
   
   // Check for mode switch conditions
   bool shouldSwitch = false;
   ENUM_TRADE_DIRECTION newDirection = CurrentDirection;
   
   // Price moved ABOVE open by threshold → Switch to SELL
   if(distanceFromOpen >= atrThreshold && CurrentDirection == BUYONLY)
   {
      newDirection = SELLONLY;
      shouldSwitch = true;
   }
   // Price moved BELOW open by threshold → Switch to BUY
   else if(distanceFromOpen <= -atrThreshold && CurrentDirection == SELLONLY)
   {
      newDirection = BUYONLY;
      shouldSwitch = true;
   }
   
   // Execute mode switch
   if(shouldSwitch)
   {
      SwitchTradingMode(newDirection, "ATR Threshold");
   }
}

//+------------------------------------------------------------------+
//| SWITCH TRADING MODE                                              |
//+------------------------------------------------------------------+
void SwitchTradingMode(ENUM_TRADE_DIRECTION newDirection, string reason)
{
   if(newDirection == CurrentDirection)
      return;
   
   ENUM_TRADE_DIRECTION oldDirection = CurrentDirection;
   CurrentDirection = newDirection;
   modeSwitchCount++;
   
   // Set cooldown timestamp
   lastModeSwitchTime = TimeCurrent();
   
   string oldDirStr = (oldDirection == BUYONLY) ? "BUY" : "SELL";
   string newDirStr = (newDirection == BUYONLY) ? "BUY" : "SELL";
   
   Print("🔄 MODE SWITCH #", modeSwitchCount, ": ", oldDirStr, " → ", newDirStr);
   Print("   Reason: ", reason);
   Print("   Active Positions: ", ArraySize(positions));
   
   // Close positions if requested
   if(CloseOnModeSwitch)
   {
      int posCount = ArraySize(positions);
      if(posCount > 0)
      {
         double floatingPL = CalculateTotalProfit();
         CloseAllPositions();
         Print("   Closed ", posCount, " positions | P/L: $", DoubleToString(floatingPL, 2));
      }
   }
   else
   {
      // Count positions by direction
      int buyCount = 0, sellCount = 0;
      for(int i = 0; i < ArraySize(positions); i++)
      {
         if(PositionSelectByTicket(positions[i].ticket))
         {
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY)
               buyCount++;
            else
               sellCount++;
         }
      }
      Print("   Keeping positions open: ", buyCount, " BUYs, ", sellCount, " SELLs");
   }
   
   // Reset reference price for new direction
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   referencePrice = currentPrice;
   currentGapSize = referencePrice * GridGapPercent / 100.0;
   
   Print("   New Reference: $", DoubleToString(referencePrice, specs.digits));
   Print("   Grid Gap: $", DoubleToString(currentGapSize, 2));
   
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| INITIALIZE SYMBOL SPECIFICATIONS                                  |
//+------------------------------------------------------------------+
bool InitializeSymbolSpecs()
{
   specs.contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   specs.tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   specs.tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   specs.point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   specs.stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   specs.digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   specs.minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   specs.maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   specs.lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   // Bitcoin typically: $0.01 tick size, $0.01 tick value per lot
   // So $1 move = $1 per lot
   
   Print("📊 Symbol Specifications:");
   Print("   Symbol: ", _Symbol);
   Print("   Contract Size: ", specs.contractSize, " BTC");
   Print("   Tick Value: $", specs.tickValue);
   Print("   Tick Size: $", specs.tickSize);
   Print("   Point: ", specs.point);
   Print("   Digits: ", specs.digits);
   Print("   Lot Range: ", specs.minLot, " - ", specs.maxLot);
   
   return true;
}

//+------------------------------------------------------------------+
//| WAIT FOR INDICATOR                                                |
//+------------------------------------------------------------------+
bool WaitForIndicator(int handle, int timeout_ms = 5000)
{
   uint start = GetTickCount();
   while(GetTickCount() - start < (uint)timeout_ms)
   {
      if(BarsCalculated(handle) > 0)
         return true;
      Sleep(100);
   }
   return false;
}

//+------------------------------------------------------------------+
//| VALIDATE LOT SIZE                                                 |
//+------------------------------------------------------------------+
double ValidateLotSize(double requestedLots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   double lots = requestedLots;
   
   // Round to lot step
   lots = MathFloor(lots / lotStep) * lotStep;
   
   // Clamp to range
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   
   return lots;
}

//+------------------------------------------------------------------+
//| VALIDATE GRID GAP                                                 |
//+------------------------------------------------------------------+
bool ValidateGridGap()
{
   double testPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double gapSize = testPrice * GridGapPercent / 100.0;
   
   Print("🔲 Grid Gap Validation:");
   Print("   Grid Gap %: ", GridGapPercent, "%");
   Print("   Gap at $", DoubleToString(testPrice, specs.digits), ": $", DoubleToString(gapSize, 2));
   
   bool isValid = true;
   
   // For Bitcoin, gap should be wider than typical bar range (~$50-100)
   if(gapSize < 20.0)
   {
      Print("   ⚠️ WARNING: Grid gap ($", DoubleToString(gapSize, 2), ") may be too tight");
      Print("   Recommended: 0.03-0.05% (~$30-50) for Bitcoin");
      isValid = false;
   }
   
   return isValid;
}

//+------------------------------------------------------------------+
//| PRINT RISK ANALYSIS                                               |
//+------------------------------------------------------------------+
void PrintRiskAnalysis()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   Print("\n💰 Risk Analysis:");
   Print("   Account Balance: $", DoubleToString(balance, 2));
   Print("   Lot Size: ", validatedLotSize, " BTC");
   Print("   Max Positions: ", MaxPositions);
   
   // Calculate TP/SL distances for Bitcoin
   // Bitcoin: $1 move = $1 per lot
   double positionValue = validatedLotSize;  // Value per $1 move
   double tpDistance = IndividualTPDollars / positionValue;
   double slDistance = IndividualSLDollars / positionValue;
   
   Print("   Individual TP: $", DoubleToString(IndividualTPDollars, 2), " (", DoubleToString(tpDistance, 2), " price move)");
   Print("   Individual SL: $", DoubleToString(IndividualSLDollars, 2), " (", DoubleToString(slDistance, 2), " price move)");
   
   double riskPerTrade = IndividualSLDollars;
   double maxTotalRisk = riskPerTrade * MaxPositions;
   double riskPercent = (riskPerTrade / balance) * 100.0;
   double totalRiskPercent = (maxTotalRisk / balance) * 100.0;
   
   Print("   Risk per Trade: $", DoubleToString(riskPerTrade, 2), " (", DoubleToString(riskPercent, 2), "%)");
   Print("   Max Total Risk: $", DoubleToString(maxTotalRisk, 2), " (", DoubleToString(totalRiskPercent, 1), "%)");
   Print("   Max Drawdown Limit: ", DoubleToString(MaxDrawdownPercent, 1), "%");
   
   if(totalRiskPercent > MaxDrawdownPercent)
   {
      Print("   ⚠️ WARNING: Total risk exceeds max drawdown");
   }
   
   // Calculate expected TP at different fill levels
   double emergencyStopLoss = balance * (MaxDrawdownPercent / 100.0);
   int safeMaxPositions = (int)(emergencyStopLoss / riskPerTrade);
   
   Print("   Emergency Stop: $", DoubleToString(emergencyStopLoss, 2));
   Print("   Safe Max Positions: ", safeMaxPositions);
   
   Print("   Protection: Emergency stop at ", DoubleToString(MaxDrawdownPercent, 1), "%");
   Print("");
}

//+------------------------------------------------------------------+
//| SYNC EXISTING POSITIONS                                           |
//+------------------------------------------------------------------+
void SyncPositions()
{
   ArrayResize(positions, 0);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            int idx = ArraySize(positions);
            ArrayResize(positions, idx + 1);
            positions[idx].ticket = ticket;
            positions[idx].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            positions[idx].entryTime = (datetime)PositionGetInteger(POSITION_TIME);
         }
      }
   }
   
   if(ArraySize(positions) > 0)
   {
      Print("📍 Synced ", ArraySize(positions), " existing positions");
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                            |
//+------------------------------------------------------------------+
double CalculateTotalProfit()
{
   double totalPL = 0;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         totalPL += PositionGetDouble(POSITION_PROFIT);
      }
   }
   
   return totalPL;
}

//+------------------------------------------------------------------+
//| CHECK GROUP TP                                                    |
//+------------------------------------------------------------------+
bool CheckGroupTP()
{
   if(ArraySize(positions) == 0) return false;
   
   double floatingPL = CalculateTotalProfit();
   
   if(floatingPL >= GroupTPDollars)
   {
      Print("🎯 GROUP TP HIT: $", DoubleToString(floatingPL, 2));
      CloseAllPositions();
      
      // Reset reference
      double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
      referencePrice = currentPrice;
      currentGapSize = referencePrice * GridGapPercent / 100.0;
      
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| OPEN POSITION                                                     |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE orderType, double price, double levelPrice)
{
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = validatedLotSize;
   request.type = orderType;
   request.price = price;
   request.deviation = 50;
   request.magic = MagicNumber;
   request.comment = "TORAMA_BTC";
   
   // Calculate TP/SL prices
   double pointValue = specs.tickValue / specs.tickSize;
   double positionValue = pointValue * validatedLotSize;
   double tpDistance = IndividualTPDollars / positionValue;
   double slDistance = IndividualSLDollars / positionValue;
   
   if(orderType == ORDER_TYPE_BUY)
   {
      request.tp = price + tpDistance;
      request.sl = price - slDistance;
   }
   else
   {
      request.tp = price - tpDistance;
      request.sl = price + slDistance;
   }
   
   if(!OrderSend(request, result))
   {
      Print("❌ Order failed: ", GetLastError());
      return false;
   }
   
   if(result.retcode == TRADE_RETCODE_DONE)
   {
      int idx = ArraySize(positions);
      ArrayResize(positions, idx + 1);
      positions[idx].ticket = result.order;
      positions[idx].entryPrice = price;
      positions[idx].entryTime = TimeCurrent();
      
      totalTrades++;
      
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   int closed = 0;
   
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(ClosePosition(positions[i].ticket))
         closed++;
   }
   
   ArrayResize(positions, 0);
   
   if(closed > 0)
   {
      Print("🔒 Closed ", closed, " positions");
   }
}

//+------------------------------------------------------------------+
//| CLOSE PROFITABLE POSITIONS                                        |
//+------------------------------------------------------------------+
void CloseProfitablePositions()
{
   int closed = 0;
   
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0)
         {
            if(ClosePosition(positions[i].ticket))
            {
               closed++;
               ArrayRemove(positions, i, 1);
            }
         }
      }
   }
   
   if(closed > 0)
   {
      Print("💰 Closed ", closed, " profitable positions");
   }
}

//+------------------------------------------------------------------+
//| CLOSE POSITION                                                    |
//+------------------------------------------------------------------+
bool ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;
   
   MqlTradeRequest request;
   MqlTradeResult result;
   ZeroMemory(request);
   ZeroMemory(result);
   
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = _Symbol;
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   request.deviation = 50;
   request.magic = MagicNumber;
   
   return OrderSend(request, result) && result.retcode == TRADE_RETCODE_DONE;
}

//+------------------------------------------------------------------+
//| CHECK GRID                                                        |
//+------------------------------------------------------------------+
void CheckGrid()
{
   if(ArraySize(positions) >= MaxPositions) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   ENUM_ORDER_TYPE orderType = (CurrentDirection == BUYONLY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double triggerPrice = (orderType == ORDER_TYPE_BUY) ? ask : bid;
   
   // Calculate next grid level
   int posCount = ArraySize(positions);
   double nextLevel = 0;
   
   if(CurrentDirection == BUYONLY)
   {
      // BUY grid: open positions as price drops
      nextLevel = referencePrice - (posCount + 1) * currentGapSize;
      
      if(triggerPrice <= nextLevel)
      {
         // Check if level already has position
         bool levelHasPosition = false;
         for(int i = 0; i < ArraySize(positions); i++)
         {
            if(MathAbs(positions[i].entryPrice - nextLevel) < currentGapSize * 0.5)
            {
               levelHasPosition = true;
               break;
            }
         }
         
         if(!levelHasPosition)
         {
            if(OpenPosition(ORDER_TYPE_BUY, ask, nextLevel))
            {
               Print("📈 BUY @ $", DoubleToString(ask, specs.digits), 
                     " | Level: $", DoubleToString(nextLevel, specs.digits),
                     " | Pos: ", ArraySize(positions), "/", MaxPositions);
            }
         }
      }
   }
   else  // SELL
   {
      // SELL grid: open positions as price rises
      nextLevel = referencePrice + (posCount + 1) * currentGapSize;
      
      if(triggerPrice >= nextLevel)
      {
         bool levelHasPosition = false;
         for(int i = 0; i < ArraySize(positions); i++)
         {
            if(MathAbs(positions[i].entryPrice - nextLevel) < currentGapSize * 0.5)
            {
               levelHasPosition = true;
               break;
            }
         }
         
         if(!levelHasPosition)
         {
            if(OpenPosition(ORDER_TYPE_SELL, bid, nextLevel))
            {
               Print("📉 SELL @ $", DoubleToString(bid, specs.digits),
                     " | Level: $", DoubleToString(nextLevel, specs.digits),
                     " | Pos: ", ArraySize(positions), "/", MaxPositions);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| EXPERT TICK                                                       |
//+------------------------------------------------------------------+
void OnTick()
{
   // Daily reset check
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   if(time.day != currentDay)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyProfit = 0;
      dailyTarget = dailyStartBalance * DailyTargetPercent / 100.0;
      dailyTargetReached = false;
      currentDay = time.day;
      lastDayCheck = TimeCurrent();
      Print("📅 New day - Daily profit reset. Target: $", DoubleToString(dailyTarget, 2));
      
      // Update day's open price for ATR
      if(EnableATRSwitch)
      {
         UpdateDayOpenPrice();
      }
   }
   
   // Check spread FIRST
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      UpdatePanel();
      return;
   }
   
   // Update peak equity and check drawdown
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > peakEquity)
      peakEquity = equity;
   
   double drawdown = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   if(drawdown < -MaxDrawdownPercent)
   {
      emergencyStop = true;
      emergencyReason = "Max drawdown exceeded";
      CloseAllPositions();
      Print("🛑 EMERGENCY STOP: ", emergencyReason);
      UpdatePanel();
      return;
   }
   
   // Stop conditions
   if(emergencyStop || isPaused || dailyTargetReached)
   {
      UpdatePanel();
      return;
   }
   
   // Check ATR mode switching
   CheckATRModeSwitch();
   
   // Check group TP
   if(CheckGroupTP())
   {
      UpdatePanel();
      return;
   }
   
   // Check daily target
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - dailyStartBalance;
   
   if(dailyProfit >= dailyTarget)
   {
      dailyTargetReached = true;
      CloseAllPositions();
      Print("🎯 Daily target reached: $", DoubleToString(dailyProfit, 2));
      UpdatePanel();
      return;
   }
   
   // Trade the grid
   CheckGrid();
   
   // Update panel
   static datetime lastPanelUpdate = 0;
   if(TimeCurrent() - lastPanelUpdate >= 1)
   {
      UpdatePanel();
      lastPanelUpdate = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| EXPERT DEINITIALIZATION                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   
   // Remove panel
   ObjectsDeleteAll(0, panelPrefix);
   ChartRedraw();
   
   Print("👋 ", EA_NAME, " v", EA_VERSION, " stopped");
}

//+------------------------------------------------------------------+
//| CHART EVENT                                                       |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == panelPrefix + "CloseBtn")
      {
         CloseAllPositions();
         ObjectSetInteger(0, panelPrefix + "CloseBtn", OBJPROP_STATE, false);
      }
      else if(sparam == panelPrefix + "PauseBtn")
      {
         isPaused = !isPaused;
         ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      else if(sparam == panelPrefix + "TPBtn")
      {
         CloseProfitablePositions();
         ObjectSetInteger(0, panelPrefix + "TPBtn", OBJPROP_STATE, false);
      }
      else if(sparam == panelPrefix + "SwitchBtn")
      {
         ENUM_TRADE_DIRECTION newDirection = (CurrentDirection == BUYONLY) ? SELLONLY : BUYONLY;
         SwitchTradingMode(newDirection, "Manual");
         ObjectSetInteger(0, panelPrefix + "SwitchBtn", OBJPROP_STATE, false);
      }
      
      ChartRedraw();
   }
}

//+------------------------------------------------------------------+
//| PRINT DEBUG STATUS                                                |
//+------------------------------------------------------------------+
void PrintDebugStatus()
{
   Print("\n=== BITCOIN TRADER STATUS ===");
   Print("Direction:             ", CurrentDirection == BUYONLY ? "BUY" : "SELL");
   Print("Active Positions:      ", ArraySize(positions), "/", MaxPositions);
   
   // Count by direction
   int buyCount = 0, sellCount = 0;
   double buyPL = 0, sellPL = 0;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double pl = PositionGetDouble(POSITION_PROFIT);
         
         if(type == POSITION_TYPE_BUY)
         {
            buyCount++;
            buyPL += pl;
         }
         else
         {
            sellCount++;
            sellPL += pl;
         }
      }
   }
   
   if(buyCount > 0 || sellCount > 0)
   {
      Print("  └─ BUY Positions:    ", buyCount, " (P/L: $", DoubleToString(buyPL, 2), ")");
      Print("  └─ SELL Positions:   ", sellCount, " (P/L: $", DoubleToString(sellPL, 2), ")");
   }
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("Balance:               $", DoubleToString(balance, 2));
   Print("Equity:                $", DoubleToString(equity, 2));
   
   double floatingPL = CalculateTotalProfit();
   Print("Floating P/L:          $", DoubleToString(floatingPL, 2));
   
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   Print("Drawdown:              ", DoubleToString(dd, 2), "%");
   
   Print("Daily Profit:          $", DoubleToString(dailyProfit, 2), " / $", DoubleToString(dailyTarget, 2));
   Print("Total Trades:          ", totalTrades);
   Print("Mode Switches:         ", modeSwitchCount);
   
   if(EnableATRSwitch)
   {
      Print("ATR:                   $", DoubleToString(currentATR, 2));
      Print("Day Open:              $", DoubleToString(dayOpenPrice, specs.digits));
   }
   
   Print("Reference Price:       $", DoubleToString(referencePrice, specs.digits));
   Print("Grid Gap:              $", DoubleToString(currentGapSize, 2), " (", GridGapPercent, "%)");
   
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   Print("Current Spread:        ", spread, " (Max: ", MaxSpread, ")");
   Print("=============================\n");
}

//+------------------------------------------------------------------+
//| TOGGLE PANEL VISIBILITY                                           |
//+------------------------------------------------------------------+
void TogglePanelVisibility()
{
   panelVisible = !panelVisible;
   
   string objects[] = {
      "Background", "Title", "Status",
      "CloseBtn", "PauseBtn", "TPBtn", "SwitchBtn",
      "DirectionLabel", "Direction",
      "PriceLabel", "Price",
      "GridLabel", "GridSpacing",
      "SpreadLabel", "Spread",
      "ATRLabel", "ATRValue",
      "DayOpenLabel", "DayOpenValue",
      "ReversalLabel", "ReversalSell", "ReversalLabel2", "ReversalBuy",
      "RefLabel", "RefPrice",
      "PosLabel", "Positions",
      "AccLabel", "AccCounts",
      "PnLLabel", "PnL",
      "EquityLabel", "Equity",
      "DDLabel", "DD",
      "DailyLabel", "DailyProfit",
      "DDTriggerLabel", "DDTrigger",
      "SwitchCountLabel", "SwitchCount",
      "Brand", "Email"
   };
   
   for(int i = 0; i < ArraySize(objects); i++)
   {
      string objName = panelPrefix + objects[i];
      if(ObjectFind(0, objName) >= 0)
      {
         ObjectSetInteger(0, objName, OBJPROP_TIMEFRAMES, panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
      }
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| CREATE PANEL - BITCOIN VERSION                                    |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 20;
   int y = 30;
   int width = 300;
   int lineHeight = 20;
   
   // Background
   ObjectCreate(0, panelPrefix + "Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XSIZE, width);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, 370);  // Increased for DD trigger line
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BGCOLOR, C'20,20,25');
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_HIDDEN, true);
   
   int yPos = y + 10;
   
   // Title + Status
   CreateLabel(panelPrefix + "Title", x + 10, yPos, "BITCOIN TRADER", clrGold, 10, "Arial Black");
   CreateLabel(panelPrefix + "Status", x + width - 75, yPos, "✅ ACTIVE", clrLimeGreen, 9, "Arial Bold");
   yPos += 24;
   
   // Buttons
   CreateButton(panelPrefix + "CloseBtn", x + 10, yPos, 60, 24, "CLOSE", clrRed, clrWhite);
   CreateButton(panelPrefix + "PauseBtn", x + 75, yPos, 60, 24, "PAUSE", clrOrange, clrWhite);
   CreateButton(panelPrefix + "TPBtn", x + 140, yPos, 50, 24, "TP", clrGreen, clrWhite);
   CreateButton(panelPrefix + "SwitchBtn", x + 195, yPos, 50, 24, "MODE", clrDodgerBlue, clrWhite);
   yPos += 30;
   
   // Mode + Price
   color dirColor = (CurrentDirection == BUYONLY) ? clrDodgerBlue : clrOrangeRed;
   CreateLabel(panelPrefix + "DirectionLabel", x + 10, yPos, "Mode:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Direction", x + 60, yPos, CurrentDirection == BUYONLY ? "BUY" : "SELL", dirColor, 10, "Arial Black");
   CreateLabel(panelPrefix + "PriceLabel", x + 140, yPos, "Price:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Price", x + 190, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // Grid + Spread
   CreateLabel(panelPrefix + "GridLabel", x + 10, yPos, "Grid:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "GridSpacing", x + 60, yPos, "0%", clrWhite, 9, "Arial Bold");
   CreateLabel(panelPrefix + "SpreadLabel", x + 140, yPos, "Spread:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Spread", x + 200, yPos, "0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // ATR info
   if(EnableATRSwitch)
   {
      CreateLabel(panelPrefix + "ATRLabel", x + 10, yPos, "ATR:", clrGold, 9, "Arial Bold");
      CreateLabel(panelPrefix + "ATRValue", x + 60, yPos, "$0", clrAqua, 9, "Arial Bold");
      CreateLabel(panelPrefix + "DayOpenLabel", x + 140, yPos, "Open:", clrGold, 9, "Arial Bold");
      CreateLabel(panelPrefix + "DayOpenValue", x + 190, yPos, "$0", clrAqua, 9, "Arial Bold");
      yPos += lineHeight;
      
      // Reversal prices
      CreateLabel(panelPrefix + "ReversalLabel", x + 10, yPos, "↑SELL @:", clrOrangeRed, 9, "Arial Black");
      CreateLabel(panelPrefix + "ReversalSell", x + 75, yPos, "$0", clrOrangeRed, 9, "Arial Bold");
      CreateLabel(panelPrefix + "ReversalLabel2", x + 140, yPos, "↓BUY @:", clrDodgerBlue, 9, "Arial Black");
      CreateLabel(panelPrefix + "ReversalBuy", x + 200, yPos, "$0", clrDodgerBlue, 9, "Arial Bold");
      yPos += lineHeight;
   }
   
   // Reference
   CreateLabel(panelPrefix + "RefLabel", x + 10, yPos, "Reference:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "RefPrice", x + 90, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight + 3;
   
   // Positions + Account
   CreateLabel(panelPrefix + "PosLabel", x + 10, yPos, "⚡EA:", clrGold, 9, "Arial Black");
   CreateLabel(panelPrefix + "Positions", x + 55, yPos, "0/0", clrWhite, 9, "Arial Black");
   CreateLabel(panelPrefix + "AccLabel", x + 110, yPos, "Acc:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "AccCounts", x + 150, yPos, "B:0 S:0 (0)", clrWhite, 9, "Arial Bold");
   yPos += lineHeight + 3;
   
   // P/L + Equity
   CreateLabel(panelPrefix + "PnLLabel", x + 10, yPos, "P/L:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "PnL", x + 55, yPos, "$0", clrWhite, 10, "Arial Black");
   CreateLabel(panelPrefix + "EquityLabel", x + 140, yPos, "Equity:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "Equity", x + 195, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // DD + Daily
   CreateLabel(panelPrefix + "DDLabel", x + 10, yPos, "DD:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DD", x + 55, yPos, "0%", clrWhite, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DailyLabel", x + 140, yPos, "Daily:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DailyProfit", x + 195, yPos, "$0", clrWhite, 9, "Arial Bold");
   yPos += lineHeight;
   
   // DD Trigger Price - NEW
   CreateLabel(panelPrefix + "DDTriggerLabel", x + 10, yPos, "🛑 DD@:", clrOrangeRed, 9, "Arial Bold");
   CreateLabel(panelPrefix + "DDTrigger", x + 65, yPos, "$0", clrOrangeRed, 9, "Arial Bold");
   yPos += lineHeight;
   
   // Switches
   CreateLabel(panelPrefix + "SwitchCountLabel", x + 10, yPos, "Switches:", clrGold, 9, "Arial Bold");
   CreateLabel(panelPrefix + "SwitchCount", x + 90, yPos, "0", clrCyan, 9, "Arial Bold");
   yPos += lineHeight + 10;
   
   // Branding
   int brandX = x + width - 10;
   ObjectCreate(0, panelPrefix + "Brand", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_XDISTANCE, brandX);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_YDISTANCE, yPos);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_FONTSIZE, 11);
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_FONT, "Arial Black");
   ObjectSetString(0, panelPrefix + "Brand", OBJPROP_TEXT, "© TORAMA CAPITAL");
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Brand", OBJPROP_HIDDEN, true);
   
   // Email
   ObjectCreate(0, panelPrefix + "Email", OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_XDISTANCE, brandX);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_YDISTANCE, yPos + 15);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, panelPrefix + "Email", OBJPROP_FONT, "Arial");
   ObjectSetString(0, panelPrefix + "Email", OBJPROP_TEXT, "ea@torama.money");
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "Email", OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!ShowPanel) return;
   
   // Status
   if(dailyTargetReached)
   {
      ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, "🎯 TARGET");
      ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, clrGold);
   }
   else if(emergencyStop)
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
   
   // Pause button
   ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, isPaused ? "RESUME" : "PAUSE");
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, isPaused ? clrGreen : clrOrange);
   
   // Direction - with mixed mode indicator
   color dirColor = (CurrentDirection == BUYONLY) ? clrDodgerBlue : clrOrangeRed;
   string directionText = CurrentDirection == BUYONLY ? "BUY" : "SELL";
   
   // Check for mixed positions
   if(!CloseOnModeSwitch && ArraySize(positions) > 0)
   {
      bool hasBuyPositions = false;
      bool hasSellPositions = false;
      
      for(int i = 0; i < ArraySize(positions); i++)
      {
         if(PositionSelectByTicket(positions[i].ticket))
         {
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY)
               hasBuyPositions = true;
            else
               hasSellPositions = true;
         }
      }
      
      if(hasBuyPositions && hasSellPositions)
      {
         directionText = "MIXED";
         dirColor = clrYellow;
      }
   }
   
   ObjectSetString(0, panelPrefix + "Direction", OBJPROP_TEXT, directionText);
   ObjectSetInteger(0, panelPrefix + "Direction", OBJPROP_COLOR, dirColor);
   
   // Price
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   ObjectSetString(0, panelPrefix + "Price", OBJPROP_TEXT, "$" + FormatPrice(currentPrice, specs.digits));
   
   // Grid
   ObjectSetString(0, panelPrefix + "GridSpacing", OBJPROP_TEXT,
                   FormatPrice(GridGapPercent, 2) + "% ($" + FormatPrice(currentGapSize, 2) + ")");
   
   // Spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   color spreadColor = (spread > MaxSpread) ? clrRed : (spread > MaxSpread * 0.7) ? clrOrange : clrLimeGreen;
   ObjectSetString(0, panelPrefix + "Spread", OBJPROP_TEXT, IntegerToString(spread) + "/" + IntegerToString(MaxSpread));
   ObjectSetInteger(0, panelPrefix + "Spread", OBJPROP_COLOR, spreadColor);
   
   // ATR and reversal prices
   if(EnableATRSwitch)
   {
      ObjectSetString(0, panelPrefix + "ATRValue", OBJPROP_TEXT, "$" + FormatPrice(currentATR, 2));
      ObjectSetString(0, panelPrefix + "DayOpenValue", OBJPROP_TEXT, "$" + FormatPrice(dayOpenPrice, specs.digits));
      
      // Calculate reversal prices
      double atrThreshold = currentATR * (ATRThresholdPercent / 100.0);
      double reversalToSell = dayOpenPrice + atrThreshold;
      double reversalToBuy = dayOpenPrice - atrThreshold;
      
      ObjectSetString(0, panelPrefix + "ReversalSell", OBJPROP_TEXT, "$" + FormatPrice(reversalToSell, specs.digits));
      ObjectSetString(0, panelPrefix + "ReversalBuy", OBJPROP_TEXT, "$" + FormatPrice(reversalToBuy, specs.digits));
      
      // Color warnings if close
      double distToSell = reversalToSell - currentPrice;
      double distToBuy = currentPrice - reversalToBuy;
      
      color sellColor = (distToSell > 0 && distToSell < atrThreshold * 0.25) ? clrYellow : clrOrangeRed;
      color buyColor = (distToBuy > 0 && distToBuy < atrThreshold * 0.25) ? clrYellow : clrDodgerBlue;
      
      ObjectSetInteger(0, panelPrefix + "ReversalSell", OBJPROP_COLOR, sellColor);
      ObjectSetInteger(0, panelPrefix + "ReversalBuy", OBJPROP_COLOR, buyColor);
   }
   
   // Reference
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, "$" + FormatPrice(referencePrice, specs.digits));
   
   // EA Positions
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT,
                   IntegerToString(ArraySize(positions)) + "/" + IntegerToString(MaxPositions));
   
   // Account-wide lots
   double totalBuyLots = 0;
   double totalSellLots = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            double volume = PositionGetDouble(POSITION_VOLUME);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY)
               totalBuyLots += volume;
            else
               totalSellLots += volume;
         }
      }
   }
   
   // Calculate net position
   double netPosition = totalBuyLots - totalSellLots;
   string netText = "";
   color netColor = clrWhite;
   
   if(MathAbs(netPosition) < 0.01)
   {
      netText = "(0)";
      netColor = clrWhite;
   }
   else if(netPosition > 0)
   {
      netText = "(+" + DoubleToString(netPosition, 2) + "B)";
      netColor = clrDodgerBlue;
   }
   else
   {
      netText = "(" + DoubleToString(MathAbs(netPosition), 2) + "S)";
      netColor = clrOrangeRed;
   }
   
   string accLotsText = "B:" + DoubleToString(totalBuyLots, 2) + " S:" + DoubleToString(totalSellLots, 2) + " " + netText;
   ObjectSetString(0, panelPrefix + "AccCounts", OBJPROP_TEXT, accLotsText);
   ObjectSetInteger(0, panelPrefix + "AccCounts", OBJPROP_COLOR, netColor);
   
   // P/L
   CalculateTotalProfit();
   color pnlColor = (totalProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "PnL", OBJPROP_TEXT,
                   (totalProfit >= 0 ? "+" : "") + "$" + FormatPrice(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "PnL", OBJPROP_COLOR, pnlColor);
   
   // Equity
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT, "$" + FormatPrice(equity, 2));
   
   // Drawdown
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   color ddColor = (dd >= -5) ? clrLimeGreen : (dd >= -10) ? clrYellow : clrRed;
   ObjectSetString(0, panelPrefix + "DD", OBJPROP_TEXT, FormatPrice(dd, 1) + "%");
   ObjectSetInteger(0, panelPrefix + "DD", OBJPROP_COLOR, ddColor);
   
   // Daily
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - dailyStartBalance;
   
   color dailyColor = (dailyProfit >= dailyTarget) ? clrGold : 
                      (dailyProfit >= 0) ? clrLimeGreen : clrRed;
   
   ObjectSetString(0, panelPrefix + "DailyProfit", OBJPROP_TEXT,
                   (dailyProfit >= 0 ? "+" : "") + "$" + FormatPrice(dailyProfit, 2));
   ObjectSetInteger(0, panelPrefix + "DailyProfit", OBJPROP_COLOR, dailyColor);
   
   // Drawdown trigger price calculation
   // Calculate what equity level triggers emergency stop
   double ddTriggerEquity = peakEquity * (1.0 - MaxDrawdownPercent / 100.0);
   
   // Calculate current floating P/L
   double currentFloatingPL = CalculateTotalProfit();
   
   // Calculate how much more loss needed to hit DD trigger
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double plNeededForDDTrigger = ddTriggerEquity - currentEquity;
   
   // Calculate average price move per dollar of P/L for current positions
   // This estimates the price level where DD would trigger
   double ddTriggerPrice = currentPrice;  // Default to current price
   
   if(ArraySize(positions) > 0 && MathAbs(currentFloatingPL) > 0.01)
   {
      // Calculate weighted average entry price
      double totalVolume = 0;
      double weightedEntry = 0;
      
      for(int i = 0; i < ArraySize(positions); i++)
      {
         if(PositionSelectByTicket(positions[i].ticket))
         {
            double volume = PositionGetDouble(POSITION_VOLUME);
            double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            weightedEntry += entryPrice * volume;
            totalVolume += volume;
         }
      }
      
      if(totalVolume > 0)
      {
         weightedEntry /= totalVolume;
         
         // Calculate price move per dollar for current positions
         // P/L per $1 move = totalVolume (for Bitcoin, $1 move = $1 per lot)
         double plPerDollarMove = totalVolume;
         
         if(plPerDollarMove > 0)
         {
            // How much price move needed to hit DD trigger?
            double priceMoveToDDTrigger = plNeededForDDTrigger / plPerDollarMove;
            
            // Calculate trigger price based on direction
            if(CurrentDirection == BUYONLY)
            {
               // BUY positions: lose money when price drops
               ddTriggerPrice = currentPrice + priceMoveToDDTrigger;  // Negative move
            }
            else
            {
               // SELL positions: lose money when price rises
               ddTriggerPrice = currentPrice - priceMoveToDDTrigger;  // Positive move
            }
         }
      }
   }
   
   // Display DD trigger price
   string ddTriggerText = "$" + FormatPrice(ddTriggerPrice, specs.digits);
   color ddTriggerColor = clrOrangeRed;
   
   // Color code based on proximity
   double currentDD = (peakEquity > 0) ? ((currentEquity - peakEquity) / peakEquity * 100) : 0;
   double ddProximity = MathAbs(currentDD / MaxDrawdownPercent * 100);  // % of max DD used
   
   if(ddProximity > 80)
      ddTriggerColor = clrRed;        // Very close to trigger
   else if(ddProximity > 50)
      ddTriggerColor = clrOrange;     // Getting close
   else
      ddTriggerColor = clrOrangeRed;  // Normal
   
   ObjectSetString(0, panelPrefix + "DDTrigger", OBJPROP_TEXT, ddTriggerText);
   ObjectSetInteger(0, panelPrefix + "DDTrigger", OBJPROP_COLOR, ddTriggerColor);
   
   // Switches
   ObjectSetString(0, panelPrefix + "SwitchCount", OBJPROP_TEXT, IntegerToString(modeSwitchCount));
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
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| CREATE BUTTON                                                     |
//+------------------------------------------------------------------+
void CreateButton(string name, int x, int y, int width, int height, string text, color bgColor, color textColor)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrGold);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| FORMAT PRICE                                                      |
//+------------------------------------------------------------------+
string FormatPrice(double price, int digits)
{
   string priceStr = DoubleToString(price, digits);
   
   // Remove trailing zeros
   if(StringFind(priceStr, ".") >= 0)
   {
      while(StringSubstr(priceStr, StringLen(priceStr) - 1) == "0")
         priceStr = StringSubstr(priceStr, 0, StringLen(priceStr) - 1);
      
      if(StringSubstr(priceStr, StringLen(priceStr) - 1) == ".")
         priceStr = StringSubstr(priceStr, 0, StringLen(priceStr) - 1);
   }
   
   // Add thousands separators
   int dotPos = StringFind(priceStr, ".");
   int startPos = (dotPos >= 0) ? dotPos : StringLen(priceStr);
   
   string result = (dotPos >= 0) ? StringSubstr(priceStr, dotPos) : "";
   int count = 0;
   
   for(int i = startPos - 1; i >= 0; i--)
   {
      result = StringSubstr(priceStr, i, 1) + result;
      count++;
      
      if(count == 3 && i > 0)
      {
         result = "," + result;
         count = 0;
      }
   }
   
   return result;
}
