//+------------------------------------------------------------------+
//|                    TORAMA Bitcoin Grid EA v2.4                   |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "2.40"
#property description "Bitcoin Grid EA - GAP-BASED TP/SL PERCENTAGES"
#property description "v2.4: AUTO DIRECTION - EA intelligently decides BUY/SELL using market analysis"
#property description "v2.3: All TP/SL now as % of gap (300% TP, 500% Global TP default)"
#property description "v2.2: Added Session/Daily Profit Target"

#define EA_VERSION "2.4"
#define EA_NAME "BTC GRID AUTO"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

input group "=== TRADING MODE ==="
enum ENUM_DIRECTION_MODE
{
   MODE_BUY_ONLY,      // BUY ONLY - Manual mode
   MODE_SELL_ONLY,     // SELL ONLY - Manual mode
   MODE_AUTO           // AUTO - EA decides direction
};
input ENUM_DIRECTION_MODE DirectionMode = MODE_AUTO;  // Direction Mode
input bool     EnableSRSwitch = false;                // Auto-switch mode at Support/Resistance

input group "=== AUTO DIRECTION SETTINGS ==="
input int      AutoMA_Fast = 20;                      // Fast MA period (trend detection)
input int      AutoMA_Slow = 50;                      // Slow MA period (trend detection)
input int      AutoRSI_Period = 14;                   // RSI period (momentum)
input int      AutoADX_Period = 14;                   // ADX period (trend strength)
input double   AutoADX_Threshold = 20.0;              // ADX minimum for trend (15-25)
input int      AutoDecisionTimeout = 5;               // Max ticks to decide (fallback to price)

input group "=== GRID SETTINGS ==="
input double   GridSpacingPercent = 0.30;             // Grid spacing % (0.2-0.5 recommended)
input int      MaxPositions = 30;                     // Maximum grid positions
input double   LotSize = 0.1;                         // Lot size per position

input group "=== PROFIT & RISK (% of Gap) ==="
input double   IndividualTPPercent = 300.0;           // Individual TP as % of gap (300 = 3x gap)
input double   IndividualSLPercent = 0.0;             // Individual SL as % of gap (0 = disabled)
input double   GlobalTPPercent = 500.0;               // Global TP as % of gap (500 = 5x gap)
input double   GlobalSLPercent = 0.0;                 // Global SL as % of gap (0 = disabled)
input double   SessionProfitPercent = 100.0;          // Session/Daily profit target (% of starting balance)
input bool     ResetSessionDaily = true;              // Reset session profit daily (false = per session)
input double   MaxDrawdownPercent = 20.0;             // Max drawdown % (emergency stop)

input group "=== SUPPORT/RESISTANCE ==="
input int      H4LookbackBars = 100;                  // H4 bars for S/R calculation
input bool     ShowSRLines = true;                    // Show S/R lines on chart

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                      // Maximum spread (points)
input int      MagicNumber = 77722;                   // Magic number
input bool     ShowPanel = true;                      // Show info panel

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
bool directionDecided = false;     // Has AUTO mode decided?
int autoDecisionTicks = 0;         // Tick counter for AUTO decision
double autoStartPrice = 0;         // Price when AUTO started
double referencePrice = 0;         // Reference for grid
double highestLevel = 0;           // Highest grid level
double lowestLevel = 0;            // Lowest grid level
double currentGapSize = 0;         // Current grid spacing in dollars

// Support/Resistance
double currentSupport = 0;
double currentResistance = 0;
datetime lastSRUpdate = 0;

// Risk management
bool emergencyStop = false;
string emergencyReason = "";
double peakEquity = 0;
double totalProfit = 0;

// Session profit tracking
double sessionStartBalance = 0;
double sessionProfit = 0;
double sessionProfitTarget = 0;
datetime lastSessionReset = 0;
int currentDay = 0;
bool sessionTargetReached = false;

// Statistics
int totalTrades = 0;
bool isPaused = false;

// Panel
string panelPrefix = "BTC_";

// Indicator handles for AUTO mode
int handleMA_Fast = INVALID_HANDLE;
int handleMA_Slow = INVALID_HANDLE;
int handleRSI = INVALID_HANDLE;
int handleADX = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("═══════════════════════════════════════");
   Print("🚀 ", EA_NAME, " v", EA_VERSION);
   Print("═══════════════════════════════════════");
   
   // Initialize based on mode
   if(DirectionMode == MODE_AUTO)
   {
      Print("⚡ AUTO DIRECTION MODE - EA will analyze market");
      directionDecided = false;
      autoDecisionTicks = 0;
      autoStartPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
      
      // Initialize indicators for AUTO mode
      handleMA_Fast = iMA(_Symbol, PERIOD_H1, AutoMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
      handleMA_Slow = iMA(_Symbol, PERIOD_H1, AutoMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
      handleRSI = iRSI(_Symbol, PERIOD_H1, AutoRSI_Period, PRICE_CLOSE);
      handleADX = iADX(_Symbol, PERIOD_H1, AutoADX_Period);
      
      if(handleMA_Fast == INVALID_HANDLE || handleMA_Slow == INVALID_HANDLE || 
         handleRSI == INVALID_HANDLE || handleADX == INVALID_HANDLE)
      {
         Print("❌ ERROR: Failed to initialize indicators for AUTO mode");
         return INIT_FAILED;
      }
      
      Print("✅ Indicators initialized: MA(", AutoMA_Fast, ",", AutoMA_Slow, "), RSI(", AutoRSI_Period, "), ADX(", AutoADX_Period, ")");
   }
   else
   {
      currentlyBuyMode = (DirectionMode == MODE_BUY_ONLY);
      directionDecided = true;
      Print("Mode: ", currentlyBuyMode ? "BUY ONLY (Manual)" : "SELL ONLY (Manual)");
   }
   
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Calculate current gap size
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   currentGapSize = currentPrice * GridSpacingPercent / 100.0;
   
   // Calculate TP/SL values as % of gap
   double individualTPDollars = currentGapSize * IndividualTPPercent / 100.0;
   double individualSLDollars = (IndividualSLPercent > 0) ? (currentGapSize * IndividualSLPercent / 100.0) : 0;
   double globalTPDollars = currentGapSize * GlobalTPPercent / 100.0;
   double globalSLDollars = (GlobalSLPercent > 0) ? (currentGapSize * GlobalSLPercent / 100.0) : 0;
   
   // Initialize session profit tracking
   sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfitTarget = sessionStartBalance * SessionProfitPercent / 100.0;
   sessionProfit = 0;
   sessionTargetReached = false;
   lastSessionReset = TimeCurrent();
   
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   currentDay = time.day;
   
   Print("Grid Spacing: ", GridSpacingPercent, "% = $", DoubleToString(currentGapSize, 2));
   Print("Individual TP: ", IndividualTPPercent, "% of gap = $", DoubleToString(individualTPDollars, 2));
   Print("Individual SL: ", IndividualSLPercent > 0 ? DoubleToString(IndividualSLPercent, 0) + "% of gap = $" + DoubleToString(individualSLDollars, 2) : "DISABLED");
   Print("Global TP: ", GlobalTPPercent, "% of gap = $", DoubleToString(globalTPDollars, 2));
   Print("Global SL: ", GlobalSLPercent > 0 ? DoubleToString(GlobalSLPercent, 0) + "% of gap = $" + DoubleToString(globalSLDollars, 2) : "DISABLED");
   Print("Session Target: ", SessionProfitPercent, "% = $", DoubleToString(sessionProfitTarget, 2));
   Print("Reset Mode: ", ResetSessionDaily ? "DAILY" : "PER SESSION");
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
   // Release indicator handles
   if(handleMA_Fast != INVALID_HANDLE) IndicatorRelease(handleMA_Fast);
   if(handleMA_Slow != INVALID_HANDLE) IndicatorRelease(handleMA_Slow);
   if(handleRSI != INVALID_HANDLE) IndicatorRelease(handleRSI);
   if(handleADX != INVALID_HANDLE) IndicatorRelease(handleADX);
   
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
//| AUTO DIRECTION ANALYSIS                                           |
//+------------------------------------------------------------------+
bool AnalyzeMarketDirection()
{
   if(DirectionMode != MODE_AUTO || directionDecided) return true;
   
   autoDecisionTicks++;
   
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double firstGridLevelUp = autoStartPrice + currentGapSize;
   double firstGridLevelDown = autoStartPrice - currentGapSize;
   
   // FALLBACK: If price hit grid level before decision, lock direction
   if(currentPrice >= firstGridLevelUp)
   {
      currentlyBuyMode = true;
      directionDecided = true;
      Print("🔵 AUTO DECISION: BUY ONLY (price hit upper grid before analysis complete)");
      Print("   Start: $", DoubleToString(autoStartPrice, 2), " | Current: $", DoubleToString(currentPrice, 2));
      return true;
   }
   if(currentPrice <= firstGridLevelDown)
   {
      currentlyBuyMode = false;
      directionDecided = true;
      Print("🔴 AUTO DECISION: SELL ONLY (price hit lower grid before analysis complete)");
      Print("   Start: $", DoubleToString(autoStartPrice, 2), " | Current: $", DoubleToString(currentPrice, 2));
      return true;
   }
   
   // FALLBACK: Timeout - use simple price momentum
   if(autoDecisionTicks >= AutoDecisionTimeout)
   {
      currentlyBuyMode = (currentPrice > autoStartPrice);
      directionDecided = true;
      Print("⏱️ AUTO DECISION TIMEOUT: ", currentlyBuyMode ? "BUY ONLY" : "SELL ONLY", " (based on price momentum)");
      Print("   Start: $", DoubleToString(autoStartPrice, 2), " | Current: $", DoubleToString(currentPrice, 2));
      return true;
   }
   
   // Get indicator values
   double maFast[], maSlow[], rsi[], adx[];
   ArraySetAsSeries(maFast, true);
   ArraySetAsSeries(maSlow, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(adx, true);
   
   if(CopyBuffer(handleMA_Fast, 0, 0, 3, maFast) < 3 ||
      CopyBuffer(handleMA_Slow, 0, 0, 3, maSlow) < 3 ||
      CopyBuffer(handleRSI, 0, 0, 3, rsi) < 3 ||
      CopyBuffer(handleADX, 0, 0, 3, adx) < 3)
   {
      return false; // Wait for next tick
   }
   
   // SCORING SYSTEM: Multiple confirmations
   int bullishScore = 0;
   int bearishScore = 0;
   
   // 1. MA CROSSOVER (weight: 3 points)
   if(maFast[0] > maSlow[0])
      bullishScore += 3;
   else
      bearishScore += 3;
   
   // 2. MA TREND (weight: 2 points)
   if(maFast[0] > maFast[1] && maSlow[0] > maSlow[1])
      bullishScore += 2;
   else if(maFast[0] < maFast[1] && maSlow[0] < maSlow[1])
      bearishScore += 2;
   
   // 3. RSI MOMENTUM (weight: 2 points)
   if(rsi[0] > 50)
      bullishScore += 2;
   else
      bearishScore += 2;
   
   // 4. RSI TREND (weight: 1 point)
   if(rsi[0] > rsi[1])
      bullishScore += 1;
   else
      bearishScore += 1;
   
   // 5. PRICE MOMENTUM (weight: 2 points)
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(_Symbol, PERIOD_H1, 0, 10, close) == 10)
   {
      if(close[0] > close[5])
         bullishScore += 2;
      else
         bearishScore += 2;
   }
   
   // 6. ADX TREND STRENGTH VALIDATION (weight: modifier)
   bool strongTrend = (adx[0] >= AutoADX_Threshold);
   
   // MULTI-TIMEFRAME CONFIRMATION
   double close_H4[], close_D1[];
   ArraySetAsSeries(close_H4, true);
   ArraySetAsSeries(close_D1, true);
   
   if(CopyClose(_Symbol, PERIOD_H4, 0, 5, close_H4) == 5)
   {
      if(close_H4[0] > close_H4[2])
         bullishScore += 1;
      else
         bearishScore += 1;
   }
   
   if(CopyClose(_Symbol, PERIOD_D1, 0, 3, close_D1) == 3)
   {
      if(close_D1[0] > close_D1[1])
         bullishScore += 1;
      else
         bearishScore += 1;
   }
   
   // DECISION LOGIC
   int scoreDifference = bullishScore - bearishScore;
   
   // Need clear conviction (at least 3-point difference) OR strong trend
   if(MathAbs(scoreDifference) >= 3 || strongTrend)
   {
      currentlyBuyMode = (bullishScore > bearishScore);
      directionDecided = true;
      
      Print("═══════════════════════════════════════");
      Print("🎯 AUTO DIRECTION DECIDED: ", currentlyBuyMode ? "🔵 BUY ONLY" : "🔴 SELL ONLY");
      Print("   Analysis Complete on Tick #", autoDecisionTicks);
      Print("───────────────────────────────────────");
      Print("   Bullish Score: ", bullishScore, " | Bearish Score: ", bearishScore);
      Print("   MA Fast: ", DoubleToString(maFast[0], 2), " | Slow: ", DoubleToString(maSlow[0], 2));
      Print("   RSI: ", DoubleToString(rsi[0], 1), " | ADX: ", DoubleToString(adx[0], 1), (strongTrend ? " ✓ STRONG" : ""));
      Print("   Price: $", DoubleToString(currentPrice, 2));
      Print("═══════════════════════════════════════");
      
      return true;
   }
   
   return false; // Continue analysis on next tick
}

//+------------------------------------------------------------------+
//| MAIN TICK FUNCTION                                                |
//+------------------------------------------------------------------+
void OnTick()
{
   // AUTO DIRECTION: Analyze and decide before trading
   if(!AnalyzeMarketDirection())
   {
      UpdatePanel();
      return; // Wait for decision
   }
   
   // Emergency stop check
   if(emergencyStop)
   {
      UpdatePanel();
      return;
   }
   
   // Session target check
   if(sessionTargetReached)
   {
      UpdatePanel();
      return;
   }
   
   // Pause check
   if(isPaused)
   {
      UpdatePanel();
      return;
   }
   
   // Check session reset
   CheckSessionReset();
   
   // Update S/R every 15 minutes
   if(TimeCurrent() - lastSRUpdate >= 900)
   {
      CalculateSupportResistance();
      lastSRUpdate = TimeCurrent();
   }
   
   // Check S/R switch
   if(EnableSRSwitch) CheckSRSwitch();
   
   // Spread check
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      UpdatePanel();
      return;
   }
   
   // Sync positions
   SyncPositions();
   
   // Check risk management
   CheckDrawdown();
   CheckSessionProfitTarget();
   CheckGlobalTP();
   CheckGlobalSL();
   
   // Calculate current price and gap
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   currentGapSize = currentPrice * GridSpacingPercent / 100.0;
   
   // Initialize reference price if needed
   if(referencePrice == 0)
   {
      referencePrice = currentPrice;
      highestLevel = currentPrice;
      lowestLevel = currentPrice;
      Print("Reference price set: $", DoubleToString(referencePrice, 2));
   }
   
   // Check for new grid levels
   if(currentlyBuyMode)
   {
      double nextLevel = lowestLevel - currentGapSize;
      if(currentPrice <= nextLevel && ArraySize(positions) < MaxPositions)
      {
         OpenPosition(ORDER_TYPE_BUY);
         lowestLevel = nextLevel;
      }
   }
   else
   {
      double nextLevel = highestLevel + currentGapSize;
      if(currentPrice >= nextLevel && ArraySize(positions) < MaxPositions)
      {
         OpenPosition(ORDER_TYPE_SELL);
         highestLevel = nextLevel;
      }
   }
   
   // Check individual TPs
   CheckIndividualTPs();
   
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| OPEN POSITION                                                     |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE type)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type = type;
   request.price = price;
   request.deviation = 50;
   request.magic = MagicNumber;
   request.comment = EA_NAME;
   
   // NO TP/SL on individual orders - managed by EA
   request.sl = 0;
   request.tp = 0;
   
   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE)
      {
         // Add to positions array
         int size = ArraySize(positions);
         ArrayResize(positions, size + 1);
         positions[size].ticket = result.order;
         positions[size].entryPrice = price;
         positions[size].entryTime = TimeCurrent();
         
         totalTrades++;
         
         Print("✅ ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"), " #", result.order, 
               " opened at $", DoubleToString(price, 2), 
               " | Total positions: ", ArraySize(positions));
      }
      else
      {
         Print("❌ Order failed: ", result.retcode, " - ", GetTradeResultDescription(result.retcode));
      }
   }
   else
   {
      Print("❌ OrderSend failed: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| CHECK INDIVIDUAL TPs                                              |
//+------------------------------------------------------------------+
void CheckIndividualTPs()
{
   if(IndividualTPPercent <= 0) return;
   if(ArraySize(positions) == 0) return;
   
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double tpDollars = currentGapSize * IndividualTPPercent / 100.0;
   
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      if(!PositionSelectByTicket(positions[i].ticket)) continue;
      
      double entryPrice = positions[i].entryPrice;
      double positionProfit = PositionGetDouble(POSITION_PROFIT);
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      // Check if profit target reached
      if(positionProfit >= tpDollars)
      {
         ClosePosition(positions[i].ticket, "Individual TP");
         
         // Remove from array
         for(int j = i; j < ArraySize(positions) - 1; j++)
            positions[j] = positions[j + 1];
         ArrayResize(positions, ArraySize(positions) - 1);
      }
      // Check individual SL if enabled
      else if(IndividualSLPercent > 0)
      {
         double slDollars = currentGapSize * IndividualSLPercent / 100.0;
         if(positionProfit <= -slDollars)
         {
            ClosePosition(positions[i].ticket, "Individual SL");
            
            // Remove from array
            for(int j = i; j < ArraySize(positions) - 1; j++)
               positions[j] = positions[j + 1];
            ArrayResize(positions, ArraySize(positions) - 1);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CHECK GLOBAL TP                                                   |
//+------------------------------------------------------------------+
void CheckGlobalTP()
{
   if(GlobalTPPercent <= 0) return;
   if(ArraySize(positions) == 0) return;
   
   CalculateTotalProfit();
   double tpDollars = currentGapSize * GlobalTPPercent / 100.0;
   
   if(totalProfit >= tpDollars)
   {
      Print("🎯 GLOBAL TP HIT! Profit: $", DoubleToString(totalProfit, 2), " >= $", DoubleToString(tpDollars, 2));
      CloseAllPositions("Global TP");
   }
}

//+------------------------------------------------------------------+
//| CHECK GLOBAL SL                                                   |
//+------------------------------------------------------------------+
void CheckGlobalSL()
{
   if(GlobalSLPercent <= 0) return;
   if(ArraySize(positions) == 0) return;
   
   CalculateTotalProfit();
   double slDollars = currentGapSize * GlobalSLPercent / 100.0;
   
   if(totalProfit <= -slDollars)
   {
      Print("🛑 GLOBAL SL HIT! Loss: $", DoubleToString(totalProfit, 2), " <= -$", DoubleToString(slDollars, 2));
      CloseAllPositions("Global SL");
      emergencyStop = true;
      emergencyReason = "Global SL triggered";
   }
}

//+------------------------------------------------------------------+
//| CHECK SESSION PROFIT TARGET                                       |
//+------------------------------------------------------------------+
void CheckSessionProfitTarget()
{
   if(SessionProfitPercent <= 0) return;
   
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionProfit = currentBalance - sessionStartBalance;
   
   if(sessionProfit >= sessionProfitTarget && !sessionTargetReached)
   {
      sessionTargetReached = true;
      Print("🎯 SESSION TARGET REACHED! Profit: $", DoubleToString(sessionProfit, 2));
      CloseAllPositions("Session Target");
   }
}

//+------------------------------------------------------------------+
//| CHECK SESSION RESET                                               |
//+------------------------------------------------------------------+
void CheckSessionReset()
{
   if(!ResetSessionDaily) return;
   
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   
   if(time.day != currentDay)
   {
      currentDay = time.day;
      sessionStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      sessionProfit = 0;
      sessionTargetReached = false;
      Print("📅 New day - Session reset. New target: $", DoubleToString(sessionProfitTarget, 2));
   }
}

//+------------------------------------------------------------------+
//| CHECK DRAWDOWN                                                    |
//+------------------------------------------------------------------+
void CheckDrawdown()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(equity > peakEquity)
      peakEquity = equity;
   
   double drawdown = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   
   if(drawdown < -MaxDrawdownPercent)
   {
      emergencyStop = true;
      emergencyReason = StringFormat("Max drawdown %.1f%% exceeded", MathAbs(drawdown));
      Print("🛑 EMERGENCY STOP: ", emergencyReason);
      CloseAllPositions(emergencyReason);
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                            |
//+------------------------------------------------------------------+
void CalculateTotalProfit()
{
   totalProfit = 0;
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
         totalProfit += PositionGetDouble(POSITION_PROFIT);
   }
}

//+------------------------------------------------------------------+
//| CLOSE POSITION                                                    |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket)) return;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = _Symbol;
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.type = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (request.type == ORDER_TYPE_SELL) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   request.deviation = 50;
   request.magic = MagicNumber;
   
   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE)
      {
         Print("✅ Position #", ticket, " closed - ", reason);
      }
   }
}

//+------------------------------------------------------------------+
//| CLOSE ALL POSITIONS                                               |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   Print("Closing all ", ArraySize(positions), " positions - ", reason);
   
   for(int i = ArraySize(positions) - 1; i >= 0; i--)
   {
      ClosePosition(positions[i].ticket, reason);
   }
   
   ArrayResize(positions, 0);
   referencePrice = 0;
   highestLevel = 0;
   lowestLevel = 0;
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS                                                    |
//+------------------------------------------------------------------+
void SyncPositions()
{
   ArrayResize(positions, 0);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      int size = ArraySize(positions);
      ArrayResize(positions, size + 1);
      positions[size].ticket = ticket;
      positions[size].entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      positions[size].entryTime = (datetime)PositionGetInteger(POSITION_TIME);
   }
}

//+------------------------------------------------------------------+
//| CALCULATE SUPPORT/RESISTANCE                                      |
//+------------------------------------------------------------------+
void CalculateSupportResistance()
{
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   
   int copied_high = CopyHigh(_Symbol, PERIOD_H4, 0, H4LookbackBars, high);
   int copied_low = CopyLow(_Symbol, PERIOD_H4, 0, H4LookbackBars, low);
   
   if(copied_high < H4LookbackBars || copied_low < H4LookbackBars)
   {
      Print("Failed to copy H4 data for S/R calculation");
      return;
   }
   
   // Find highest high and lowest low
   double maxHigh = high[ArrayMaximum(high, 0, WHOLE_ARRAY)];
   double minLow = low[ArrayMinimum(low, 0, WHOLE_ARRAY)];
   
   // Calculate support/resistance zones
   currentSupport = minLow;
   currentResistance = maxHigh;
   
   // Draw S/R lines
   if(ShowSRLines)
   {
      DrawSRLines();
   }
}

//+------------------------------------------------------------------+
//| DRAW S/R LINES                                                    |
//+------------------------------------------------------------------+
void DrawSRLines()
{
   if(currentSupport > 0)
   {
      ObjectDelete(0, "SR_Support");
      ObjectCreate(0, "SR_Support", OBJ_HLINE, 0, 0, currentSupport);
      ObjectSetInteger(0, "SR_Support", OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, "SR_Support", OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, "SR_Support", OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, "SR_Support", OBJPROP_BACK, true);
      ObjectSetInteger(0, "SR_Support", OBJPROP_SELECTABLE, false);
      
      ObjectDelete(0, "SR_Support_Label");
      ObjectCreate(0, "SR_Support_Label", OBJ_TEXT, 0, TimeCurrent(), currentSupport);
      ObjectSetString(0, "SR_Support_Label", OBJPROP_TEXT, "  SUPPORT");
      ObjectSetInteger(0, "SR_Support_Label", OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, "SR_Support_Label", OBJPROP_FONTSIZE, 8);
   }
   
   if(currentResistance > 0)
   {
      ObjectDelete(0, "SR_Resistance");
      ObjectCreate(0, "SR_Resistance", OBJ_HLINE, 0, 0, currentResistance);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_COLOR, clrOrangeRed);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_BACK, true);
      ObjectSetInteger(0, "SR_Resistance", OBJPROP_SELECTABLE, false);
      
      ObjectDelete(0, "SR_Resistance_Label");
      ObjectCreate(0, "SR_Resistance_Label", OBJ_TEXT, 0, TimeCurrent(), currentResistance);
      ObjectSetString(0, "SR_Resistance_Label", OBJPROP_TEXT, "  RESISTANCE");
      ObjectSetInteger(0, "SR_Resistance_Label", OBJPROP_COLOR, clrOrangeRed);
      ObjectSetInteger(0, "SR_Resistance_Label", OBJPROP_FONTSIZE, 8);
   }
}

//+------------------------------------------------------------------+
//| CHECK S/R SWITCH                                                  |
//+------------------------------------------------------------------+
void CheckSRSwitch()
{
   if(currentSupport == 0 || currentResistance == 0) return;
   
   double currentPrice = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) + SymbolInfoDouble(_Symbol, SYMBOL_BID)) / 2.0;
   double tolerance = currentPrice * 0.001; // 0.1% tolerance
   
   // Switch to BUY mode near support
   if(!currentlyBuyMode && currentPrice <= currentSupport + tolerance)
   {
      Print("🔄 S/R SWITCH: Switching to BUY mode at support $", DoubleToString(currentSupport, 2));
      currentlyBuyMode = true;
      CloseAllPositions("S/R Switch to BUY");
   }
   // Switch to SELL mode near resistance
   else if(currentlyBuyMode && currentPrice >= currentResistance - tolerance)
   {
      Print("🔄 S/R SWITCH: Switching to SELL mode at resistance $", DoubleToString(currentResistance, 2));
      currentlyBuyMode = false;
      CloseAllPositions("S/R Switch to SELL");
   }
}

//+------------------------------------------------------------------+
//| CHART EVENT HANDLER                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == panelPrefix + "PauseBtn")
      {
         isPaused = !isPaused;
         Print(isPaused ? "⏸️ Trading PAUSED" : "▶️ Trading RESUMED");
         ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
      else if(sparam == panelPrefix + "CloseBtn")
      {
         Print("🔴 CLOSE ALL button pressed");
         CloseAllPositions("Manual close");
         ObjectSetInteger(0, panelPrefix + "CloseBtn", OBJPROP_STATE, false);
         UpdatePanel();
      }
   }
}

//+------------------------------------------------------------------+
//| GET TRADE RESULT DESCRIPTION                                      |
//+------------------------------------------------------------------+
string GetTradeResultDescription(uint retcode)
{
   switch(retcode)
   {
      case TRADE_RETCODE_DONE: return "Done";
      case TRADE_RETCODE_INVALID: return "Invalid request";
      case TRADE_RETCODE_INVALID_VOLUME: return "Invalid volume";
      case TRADE_RETCODE_INVALID_PRICE: return "Invalid price";
      case TRADE_RETCODE_INVALID_STOPS: return "Invalid stops";
      case TRADE_RETCODE_MARKET_CLOSED: return "Market closed";
      case TRADE_RETCODE_NO_MONEY: return "Not enough money";
      default: return "Error " + IntegerToString(retcode);
   }
}

//+------------------------------------------------------------------+
//| CREATE PANEL                                                      |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 20;
   int y = 30;
   
   // Background
   ObjectCreate(0, panelPrefix + "Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XSIZE, 360);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, 270);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BGCOLOR, C'20,20,30');
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BACK, true);
   
   // Title
   CreateLabel(panelPrefix + "Title", x + 10, y + 8, "⚡ " + EA_NAME + " v" + EA_VERSION, clrGold, 12, "Arial Black");
   
   // Status
   CreateLabel(panelPrefix + "Status", x + 270, y + 8, "✅ ACTIVE", clrLimeGreen, 10, "Arial Bold");
   
   // Control buttons
   CreateButton(panelPrefix + "PauseBtn", x + 10, y + 30, 70, 25, "PAUSE", clrOrange, clrWhite);
   CreateButton(panelPrefix + "CloseBtn", x + 90, y + 30, 70, 25, "CLOSE ALL", clrRed, clrWhite);
   
   // Mode label and value on same line
   CreateLabel(panelPrefix + "ModeLabel", x + 10, y + 65, "Mode:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "ModeValue", x + 55, y + 65, "🔵 BUY ONLY", clrDodgerBlue, 11, "Arial Bold");
   
   // Price
   CreateLabel(panelPrefix + "PriceLabel", x + 10, y + 90, "Price:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Price", x + 55, y + 90, "$0", clrWhite, 11, "Arial Bold");
   
   // Grid spacing
   CreateLabel(panelPrefix + "GridLabel", x + 225, y + 90, "Grid:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "GridSpacing", x + 265, y + 90, "0.3%", clrYellow, 9, "Arial");
   
   // Support
   CreateLabel(panelPrefix + "SupportLabel", x + 10, y + 120, "Support:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Support", x + 70, y + 120, "$0", clrDodgerBlue, 9, "Arial Bold");
   
   // Resistance
   CreateLabel(panelPrefix + "ResistanceLabel", x + 175, y + 120, "Resistance:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Resistance", x + 250, y + 120, "$0", clrOrangeRed, 9, "Arial Bold");
   
   // S/R Switch status
   CreateLabel(panelPrefix + "SRSwitchLabel", x + 10, y + 140, "S/R Switch:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "SRSwitch", x + 85, y + 140, "OFF", clrGray, 9, "Arial Bold");
   
   // AUTO Direction status (new)
   CreateLabel(panelPrefix + "AutoLabel", x + 175, y + 140, "AUTO:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "AutoStatus", x + 220, y + 140, "ANALYZING", clrYellow, 9, "Arial Bold");
   
   // Positions and P/L on same line
   CreateLabel(panelPrefix + "PositionsLabel", x + 10, y + 165, "Positions:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Positions", x + 80, y + 165, "0/30", clrWhite, 11, "Arial Bold");
   CreateLabel(panelPrefix + "PnLLabel", x + 180, y + 165, "P/L:", clrGray, 10, "Arial Bold");
   CreateLabel(panelPrefix + "PnL", x + 215, y + 165, "$0.00", clrWhite, 13, "Arial Black");
   
   // Equity and DD on same line
   CreateLabel(panelPrefix + "EquityLabel", x + 10, y + 190, "Equity:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "Equity", x + 65, y + 190, "$0", clrWhite, 9, "Arial");
   CreateLabel(panelPrefix + "DDLabel", x + 180, y + 190, "DD:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "DD", x + 210, y + 190, "0.0%", clrLimeGreen, 9, "Arial");
   
   // Session Profit on same line
   CreateLabel(panelPrefix + "SessionLabel", x + 10, y + 210, "Session:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "SessionProfit", x + 70, y + 210, "$0", clrWhite, 10, "Arial Bold");
   CreateLabel(panelPrefix + "TargetLabel", x + 180, y + 210, "Target:", clrGray, 9, "Arial");
   CreateLabel(panelPrefix + "SessionTarget", x + 230, y + 210, "$0", clrGray, 9, "Arial");
   
   // TORAMA CAPITAL
   CreateLabel(panelPrefix + "Brand", x + 215, y + 240, "TORAMA CAPITAL", clrGold, 11, "Arial Black");
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
   if(sessionTargetReached)
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
   
   // Mode
   string modeText = "";
   color modeColor = clrWhite;
   
   if(DirectionMode == MODE_AUTO)
   {
      if(!directionDecided)
      {
         modeText = "⚡ AUTO (ANALYZING)";
         modeColor = clrYellow;
      }
      else
      {
         modeText = currentlyBuyMode ? "⚡ AUTO → 🔵 BUY" : "⚡ AUTO → 🔴 SELL";
         modeColor = currentlyBuyMode ? clrDodgerBlue : clrOrangeRed;
      }
   }
   else
   {
      modeText = currentlyBuyMode ? "🔵 BUY ONLY" : "🔴 SELL ONLY";
      modeColor = currentlyBuyMode ? clrDodgerBlue : clrOrangeRed;
   }
   
   ObjectSetString(0, panelPrefix + "ModeValue", OBJPROP_TEXT, modeText);
   ObjectSetInteger(0, panelPrefix + "ModeValue", OBJPROP_COLOR, modeColor);
   
   // AUTO Status
   if(DirectionMode == MODE_AUTO)
   {
      if(!directionDecided)
      {
         ObjectSetString(0, panelPrefix + "AutoStatus", OBJPROP_TEXT, 
                        "TICK " + IntegerToString(autoDecisionTicks) + "/" + IntegerToString(AutoDecisionTimeout));
         ObjectSetInteger(0, panelPrefix + "AutoStatus", OBJPROP_COLOR, clrYellow);
      }
      else
      {
         ObjectSetString(0, panelPrefix + "AutoStatus", OBJPROP_TEXT, "DECIDED");
         ObjectSetInteger(0, panelPrefix + "AutoStatus", OBJPROP_COLOR, clrLimeGreen);
      }
   }
   else
   {
      ObjectSetString(0, panelPrefix + "AutoStatus", OBJPROP_TEXT, "MANUAL");
      ObjectSetInteger(0, panelPrefix + "AutoStatus", OBJPROP_COLOR, clrGray);
   }
   
   // Pause button
   ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, isPaused ? "RESUME" : "PAUSE");
   ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_BGCOLOR, isPaused ? clrGreen : clrOrange);
   
   // Price
   ObjectSetString(0, panelPrefix + "Price", OBJPROP_TEXT, 
                   "$" + DoubleToString(currentPrice, digits));
   
   // Grid
   ObjectSetString(0, panelPrefix + "GridSpacing", OBJPROP_TEXT,
                   DoubleToString(GridSpacingPercent, 2) + "% ($" + 
                   DoubleToString(currentPrice * GridSpacingPercent / 100.0, 2) + ")");
   
   // S/R
   if(currentSupport > 0)
      ObjectSetString(0, panelPrefix + "Support", OBJPROP_TEXT,
                      "$" + DoubleToString(currentSupport, digits));
   
   if(currentResistance > 0)
      ObjectSetString(0, panelPrefix + "Resistance", OBJPROP_TEXT,
                      "$" + DoubleToString(currentResistance, digits));
   
   // S/R Switch
   ObjectSetString(0, panelPrefix + "SRSwitch", OBJPROP_TEXT,
                   EnableSRSwitch ? "ON" : "OFF");
   ObjectSetInteger(0, panelPrefix + "SRSwitch", OBJPROP_COLOR, EnableSRSwitch ? clrLimeGreen : clrGray);
   
   // Positions
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT,
                   IntegerToString(ArraySize(positions)) + "/" + IntegerToString(MaxPositions));
   
   // P/L
   CalculateTotalProfit();
   color pnlColor = (totalProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "PnL", OBJPROP_TEXT,
                   (totalProfit >= 0 ? "+" : "") + "$" + DoubleToString(totalProfit, 2));
   ObjectSetInteger(0, panelPrefix + "PnL", OBJPROP_COLOR, pnlColor);
   
   // Equity
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT,
                   "$" + DoubleToString(equity, 2));
   
   // Drawdown
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   color ddColor = (dd >= -5) ? clrLimeGreen : (dd >= -10) ? clrYellow : clrRed;
   ObjectSetString(0, panelPrefix + "DD", OBJPROP_TEXT,
                   DoubleToString(dd, 1) + "%");
   ObjectSetInteger(0, panelPrefix + "DD", OBJPROP_COLOR, ddColor);
   
   // Session Profit
   if(SessionProfitPercent > 0)
   {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      sessionProfit = currentBalance - sessionStartBalance;
      double sessionPercent = (sessionStartBalance > 0) ? (sessionProfit / sessionStartBalance * 100.0) : 0;
      
      color sessionColor = (sessionProfit >= sessionProfitTarget) ? clrGold : 
                           (sessionProfit >= 0) ? clrLimeGreen : clrRed;
      
      ObjectSetString(0, panelPrefix + "SessionProfit", OBJPROP_TEXT,
                      (sessionProfit >= 0 ? "+" : "") + "$" + DoubleToString(sessionProfit, 2) + 
                      " (" + DoubleToString(sessionPercent, 1) + "%)");
      ObjectSetInteger(0, panelPrefix + "SessionProfit", OBJPROP_COLOR, sessionColor);
      
      ObjectSetString(0, panelPrefix + "SessionTarget", OBJPROP_TEXT,
                      "$" + DoubleToString(sessionProfitTarget, 2));
   }
   else
   {
      ObjectSetString(0, panelPrefix + "SessionProfit", OBJPROP_TEXT, "DISABLED");
      ObjectSetInteger(0, panelPrefix + "SessionProfit", OBJPROP_COLOR, clrGray);
      ObjectSetString(0, panelPrefix + "SessionTarget", OBJPROP_TEXT, "OFF");
   }
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
