//+------------------------------------------------------------------+
//|                    TORAMA Aggressive Trader EA v5.7              |
//|                                           TORAMA CAPITAL          |
//|                                      https://www.torama.money     |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://www.torama.money"
#property version   "5.7"
#property description "Aggressive Directional Grid Trader with Trend Exhaustion Detection"
#property description "Trades ONLY in chosen direction as price moves"
#property description "Detects trend exhaustion and protects capital"
#property description ""
#property description "V5.7: RSI exhaustion, profit protection, consecutive loss detection, ATR squeeze"

#define EA_VERSION "5.7"
#define EA_NAME "TORAMA AGGRESSIVE TRADER"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

enum ENUM_TRADE_DIRECTION
{
   BUYONLY,    // BUY ONLY - Buys up and down the grid
   SELLONLY    // SELL ONLY - Sells up and down the grid
};

enum ENUM_EXHAUSTION_ACTION
{
   PAUSE_ONLY,      // Pause new trades only (let existing run)
   CLOSE_AND_PAUSE  // Close all positions and pause
};

input group "=== DIRECTION & ATR MODE SWITCHING ==="
input ENUM_TRADE_DIRECTION StartDirection = BUYONLY;  // Starting Direction
input bool     EnableATRSwitch = true;                // Enable ATR-based mode switching
input int      ATRPeriod = 14;                        // ATR Period for mode switching
input double   ATRThresholdPercent = 70.0;            // ATR Threshold % (70 = 0.7 × ATR)
input bool     CloseOnModeSwitch = false;             // Close positions on mode switch

input group "=== TREND EXHAUSTION DETECTION (NEW v5.7) ==="
input bool     EnableExhaustionDetection = true;      // Enable trend exhaustion detection
input ENUM_EXHAUSTION_ACTION ExhaustionAction = PAUSE_ONLY;  // Action on exhaustion
input int      RSIPeriod = 14;                        // RSI Period
input double   RSIOverBought = 70.0;                  // RSI Overbought level
input double   RSIOverSold = 30.0;                    // RSI Oversold level
input int      ConsecutiveLossLimit = 3;              // Consecutive losses before pause
input double   ProfitProtectionPercent = 5.0;         // Protect profit % (5 = close at 5% equity gain)
input double   ATRContractionPercent = 50.0;          // ATR squeeze % (50 = ATR drops to 50% of average)
input int      ATRContractionPeriod = 20;             // Period to measure ATR average

input group "=== GRID SETTINGS ==="
input double   GridGapPercent = 0.01;                 // Grid gap % (0.01 = tight, 0.3 = wide)
input int      MaxPositions = 100;                    // Maximum positions
input double   LotSize = 0.2;                         // Lot size per position

input group "=== TAKE PROFIT ==="
input double   IndividualTPDollars = 50.0;            // Individual TP target ($50 per position)
input double   GroupTPDollars = 200.0;                // Group TP target ($200 total profit closes all)

input group "=== STOP LOSS ==="
input double   IndividualSLDollars = 100.0;           // SL risk per trade ($100 max loss, 0 = disabled)

input group "=== RISK MANAGEMENT ==="
input double   MaxDrawdownPercent = 25.0;             // Max drawdown % (emergency stop)
input double   DailyTargetPercent = 100.0;            // Daily profit target (% of start balance)

input group "=== SETTINGS ==="
input int      MaxSpread = 2000;                      // Maximum spread (points)
input bool     ShowPanel = true;                      // Show info panel

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

struct Position
{
   ulong    ticket;
   double   entryPrice;
   datetime entryTime;
   bool     isWinner;
};

Position positions[];

// Current trading mode
ENUM_TRADE_DIRECTION CurrentDirection;

// ATR Mode Switching
int atrHandle = INVALID_HANDLE;
double dayOpenPrice = 0;
double currentATR = 0;
datetime lastDayOpenUpdate = 0;
datetime lastModeSwitchTime = 0;
int modeSwitchCooldownBars = 100;

// Grid tracking
double referencePrice = 0;
double currentGapSize = 0;
double nextBuyLevel = 0;
double nextSellLevel = 0;

// Risk management
bool emergencyStop = false;
string emergencyReason = "";
double peakEquity = 0;
double totalProfit = 0;

// Daily profit tracking
double dailyStartBalance = 0;
double dailyProfit = 0;
double dailyTarget = 0;
datetime lastDayCheck = 0;
int currentDay = 0;
bool dailyTargetReached = false;

// Statistics
int totalTrades = 0;
bool isPaused = false;
int modeSwitchCount = 0;

// Magic number
int MagicNumber = 0;

// Panel
string panelPrefix = "TORAMA_AGG_";
bool panelVisible = true;

// Fast market optimization
datetime lastGridCheck = 0;
uint gridCheckIntervalMs = 100;

// TREND EXHAUSTION DETECTION (NEW in v5.7)
int rsiHandle = INVALID_HANDLE;
double currentRSI = 50.0;
int consecutiveLosses = 0;
int consecutiveWins = 0;
double exhaustionStartEquity = 0;
bool trendExhausted = false;
string exhaustionReason = "";
datetime exhaustionTime = 0;
int exhaustionCount = 0;

// Profit protection tracking
double profitProtectionEquity = 0;
bool profitProtectionActive = false;

// ATR contraction tracking
double averageATR = 0;
bool atrSqueezeDetected = false;

// Trade history for consecutive loss tracking
struct TradeHistory
{
   ulong    ticket;
   bool     isWinner;
   double   profit;
   datetime closeTime;
};

TradeHistory recentTrades[];
int maxTradeHistory = 10;

// Symbol specifications (cached)
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
};

SymbolSpecs specs;
double validatedLotSize = 0;

//+------------------------------------------------------------------+
//| GENERATE PERSISTENT CHART-BASED MAGIC NUMBER                     |
//+------------------------------------------------------------------+
int GenerateChartBasedMagicNumber()
{
   long chartId = ChartID();
   
   string symbolStr = _Symbol;
   int symbolHash = 0;
   
   for(int i = 0; i < StringLen(symbolStr); i++)
   {
      symbolHash = (symbolHash * 31 + StringGetCharacter(symbolStr, i)) % 1000000;
   }
   
   int magic = (int)((chartId % 1000000) * 1000 + symbolHash) % 2147483647;
   
   if(magic == 0) magic = (int)(chartId % 2147483647);
   if(magic == 0) magic = 123456;
   
   return magic;
}

//+------------------------------------------------------------------+
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("═══════════════════════════════════════");
   Print("🚀 ", EA_NAME, " v", EA_VERSION);
   Print("═══════════════════════════════════════");
   
   Print("💰 ACCOUNT INFO:");
   Print("   Balance: $", DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2));
   Print("   Equity: $", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2));
   Print("   Leverage: 1:", IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE)));
   Print("   Currency: ", AccountInfoString(ACCOUNT_CURRENCY));
   
   MagicNumber = GenerateChartBasedMagicNumber();
   Print("🔢 Magic Number (Chart ID: ", ChartID(), "): ", MagicNumber);
   
   if(!InitializeSymbolSpecs())
   {
      Print("❌ FAILED: Could not initialize symbol specifications");
      return(INIT_FAILED);
   }
   
   validatedLotSize = ValidateLotSize(LotSize);
   
   Print("📊 CONFIGURATION:");
   Print("   Starting Direction: ", StartDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   Print("   Symbol: ", _Symbol);
   Print("   Lot Size: ", DoubleToString(validatedLotSize, 3));
   Print("   Max Positions: ", MaxPositions);
   
   CurrentDirection = StartDirection;
   
   // Initialize ATR
   if(EnableATRSwitch)
   {
      Print("═══════════════════════════════════════");
      Print("📈 ATR MODE SWITCHING: ENABLED");
      Print("   ATR Period: ", ATRPeriod);
      Print("   ATR Threshold: ", DoubleToString(ATRThresholdPercent, 1), "% of ATR");
      Print("   Close on Switch: ", CloseOnModeSwitch ? "YES" : "NO");
      
      atrHandle = iATR(_Symbol, PERIOD_D1, ATRPeriod);
      if(atrHandle == INVALID_HANDLE)
      {
         Print("❌ FAILED: Could not create ATR indicator handle");
         return(INIT_FAILED);
      }
      
      UpdateDayOpenPrice();
      
      if(!WaitForIndicator(atrHandle))
      {
         Print("⚠️ WARNING: ATR indicator not ready");
      }
      else
      {
         double atr_buffer[];
         ArraySetAsSeries(atr_buffer, true);
         if(CopyBuffer(atrHandle, 0, 0, 1, atr_buffer) > 0)
         {
            currentATR = atr_buffer[0];
            Print("   Current Daily ATR: $", DoubleToString(currentATR, 2));
         }
      }
   }
   
   // Initialize RSI for trend exhaustion detection (NEW in v5.7)
   if(EnableExhaustionDetection)
   {
      Print("═══════════════════════════════════════");
      Print("🛡️ TREND EXHAUSTION DETECTION: ENABLED");
      Print("   RSI Period: ", RSIPeriod);
      Print("   RSI Overbought: ", DoubleToString(RSIOverBought, 1));
      Print("   RSI Oversold: ", DoubleToString(RSIOverSold, 1));
      Print("   Consecutive Loss Limit: ", ConsecutiveLossLimit);
      Print("   Profit Protection: ", DoubleToString(ProfitProtectionPercent, 1), "% equity gain");
      Print("   ATR Contraction Alert: ", DoubleToString(ATRContractionPercent, 1), "% of average");
      Print("   Action on Exhaustion: ", ExhaustionAction == PAUSE_ONLY ? "PAUSE ONLY" : "CLOSE & PAUSE");
      
      rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RSIPeriod, PRICE_CLOSE);
      if(rsiHandle == INVALID_HANDLE)
      {
         Print("❌ FAILED: Could not create RSI indicator handle");
         return(INIT_FAILED);
      }
      
      if(!WaitForIndicator(rsiHandle))
      {
         Print("⚠️ WARNING: RSI indicator not ready");
      }
      else
      {
         double rsi_buffer[];
         ArraySetAsSeries(rsi_buffer, true);
         if(CopyBuffer(rsiHandle, 0, 0, 1, rsi_buffer) > 0)
         {
            currentRSI = rsi_buffer[0];
            Print("   Current RSI: ", DoubleToString(currentRSI, 1));
         }
      }
      
      // Initialize profit protection equity
      profitProtectionEquity = AccountInfoDouble(ACCOUNT_EQUITY) * (1.0 + ProfitProtectionPercent / 100.0);
      Print("   Profit Protection Triggers at: $", DoubleToString(profitProtectionEquity, 2));
   }
   else
   {
      Print("═══════════════════════════════════════");
      Print("🛡️ TREND EXHAUSTION DETECTION: DISABLED");
      Print("   EA will trade until hard stops only");
   }
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(ask <= 0 || bid <= 0)
   {
      Print("❌ FAILED: Invalid price data");
      return(INIT_FAILED);
   }
   
   referencePrice = (ask + bid) / 2.0;
   currentGapSize = referencePrice * GridGapPercent / 100.0;
   
   if(!ValidateGridGap())
   {
      Print("⚠️ WARNING: Grid gap validation failed");
   }
   
   Print("📍 STARTING REFERENCE: $", DoubleToString(referencePrice, specs.digits));
   Print("📏 Grid Gap: $", DoubleToString(currentGapSize, specs.digits));
   
   CalculateNextGridLevels();
   
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyTarget = dailyStartBalance * DailyTargetPercent / 100.0;
   Print("🎯 Daily Target: $", DoubleToString(dailyTarget, 2));
   
   PrintRiskAnalysis();
   
   Print("═══════════════════════════════════════");
   Print("🎯 PROFIT & LOSS TARGETS:");
   Print("   Individual TP: $", DoubleToString(IndividualTPDollars, 2));
   Print("   Group TP: $", DoubleToString(GroupTPDollars, 2));
   Print("   Individual SL: ", IndividualSLDollars > 0 ? "$" + DoubleToString(IndividualSLDollars, 2) : "DISABLED");
   
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   currentDay = time.day;
   lastDayCheck = TimeCurrent();
   
   Print("═══════════════════════════════════════");
   Print("⚡ AGGRESSIVE STRATEGY WITH SAFETY:");
   Print("   Opens positions as price moves through grid");
   Print("   Monitors RSI for trend exhaustion");
   Print("   Tracks consecutive losses");
   Print("   Protects profits automatically");
   Print("   Detects volatility squeeze (ATR contraction)");
   Print("═══════════════════════════════════════");
   Print("🆕 v5.7 SAFETY FEATURES:");
   Print("   ✓ RSI exhaustion detection");
   Print("   ✓ Consecutive loss protection");
   Print("   ✓ Automatic profit lock-in");
   Print("   ✓ ATR squeeze detection");
   Print("   ✓ Smart pause/resume logic");
   Print("═══════════════════════════════════════");
   Print("🔍 DEBUG: Press 'D' for status");
   Print("👁️ PANEL: Press 'H' to hide/show");
   Print("▶️ RESUME: Press 'R' to resume after exhaustion pause");
   Print("═══════════════════════════════════════");
   
   if(ShowPanel) CreatePanel();
   
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
   
   time.hour = 0;
   time.min = 0;
   time.sec = 0;
   datetime todayOpen = StructToTime(time);
   
   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_D1, 0, 1, rates);
   
   if(copied > 0)
   {
      dayOpenPrice = rates[0].open;
      lastDayOpenUpdate = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| CHECK TREND EXHAUSTION (NEW in v5.7)                            |
//+------------------------------------------------------------------+
bool CheckTrendExhaustion()
{
   if(!EnableExhaustionDetection) return false;
   
   bool exhaustionDetected = false;
   string reason = "";
   
   // 1. RSI EXHAUSTION CHECK
   if(rsiHandle != INVALID_HANDLE)
   {
      double rsi_buffer[];
      ArraySetAsSeries(rsi_buffer, true);
      
      if(CopyBuffer(rsiHandle, 0, 0, 1, rsi_buffer) > 0)
      {
         currentRSI = rsi_buffer[0];
         
         // BUY mode: Check if RSI is overbought (trend may be exhausted)
         if(CurrentDirection == BUYONLY && currentRSI > RSIOverBought)
         {
            exhaustionDetected = true;
            reason = StringFormat("RSI Overbought (%.1f > %.1f)", currentRSI, RSIOverBought);
         }
         
         // SELL mode: Check if RSI is oversold (trend may be exhausted)
         if(CurrentDirection == SELLONLY && currentRSI < RSIOverSold)
         {
            exhaustionDetected = true;
            reason = StringFormat("RSI Oversold (%.1f < %.1f)", currentRSI, RSIOverSold);
         }
      }
   }
   
   // 2. CONSECUTIVE LOSSES CHECK
   if(consecutiveLosses >= ConsecutiveLossLimit)
   {
      exhaustionDetected = true;
      reason = StringFormat("Consecutive Losses (%d >= %d)", consecutiveLosses, ConsecutiveLossLimit);
   }
   
   // 3. PROFIT PROTECTION CHECK
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(ProfitProtectionPercent > 0 && currentEquity >= profitProtectionEquity)
   {
      exhaustionDetected = true;
      reason = StringFormat("Profit Protection (%.1f%% gain reached)", ProfitProtectionPercent);
      profitProtectionActive = true;
   }
   
   // 4. ATR CONTRACTION CHECK (Volatility Squeeze)
   if(EnableATRSwitch && atrHandle != INVALID_HANDLE && ATRContractionPercent > 0)
   {
      double atr_buffer[];
      ArraySetAsSeries(atr_buffer, true);
      
      if(CopyBuffer(atrHandle, 0, 0, ATRContractionPeriod, atr_buffer) > 0)
      {
         // Calculate average ATR
         double sum = 0;
         for(int i = 0; i < ATRContractionPeriod; i++)
         {
            sum += atr_buffer[i];
         }
         averageATR = sum / ATRContractionPeriod;
         
         // Check if current ATR has contracted significantly
         double contractionThreshold = averageATR * (ATRContractionPercent / 100.0);
         if(currentATR < contractionThreshold)
         {
            exhaustionDetected = true;
            reason = StringFormat("ATR Squeeze (%.2f < %.2f)", currentATR, contractionThreshold);
            atrSqueezeDetected = true;
         }
         else
         {
            atrSqueezeDetected = false;
         }
      }
   }
   
   // Handle exhaustion detection
   if(exhaustionDetected && !trendExhausted)
   {
      trendExhausted = true;
      exhaustionReason = reason;
      exhaustionTime = TimeCurrent();
      exhaustionCount++;
      exhaustionStartEquity = currentEquity;
      
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      Print("⚠️ TREND EXHAUSTION DETECTED #", exhaustionCount);
      Print("   Reason: ", reason);
      Print("   RSI: ", DoubleToString(currentRSI, 1));
      Print("   Consecutive Losses: ", consecutiveLosses);
      Print("   Current Equity: $", DoubleToString(currentEquity, 2));
      Print("   Positions: ", ArraySize(positions));
      
      if(ExhaustionAction == CLOSE_AND_PAUSE)
      {
         Print("   Action: CLOSING ALL POSITIONS + PAUSE");
         CloseAllPositions();
         isPaused = true;
      }
      else
      {
         Print("   Action: PAUSE NEW TRADES (existing positions continue)");
         isPaused = true;
      }
      
      Print("   Press 'R' to resume or wait for conditions to improve");
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
   }
   
   return trendExhausted;
}

//+------------------------------------------------------------------+
//| CHECK EXHAUSTION RECOVERY (NEW in v5.7)                         |
//+------------------------------------------------------------------+
void CheckExhaustionRecovery()
{
   if(!trendExhausted) return;
   
   bool canResume = true;
   string blockingReason = "";
   
   // Check RSI has recovered to neutral zone
   if(CurrentDirection == BUYONLY)
   {
      if(currentRSI > RSIOverBought - 10)  // Still too high
      {
         canResume = false;
         blockingReason = "RSI still high";
      }
   }
   else  // SELLONLY
   {
      if(currentRSI < RSIOverSold + 10)  // Still too low
      {
         canResume = false;
         blockingReason = "RSI still low";
      }
   }
   
   // Check if enough time has passed (cooldown)
   if(TimeCurrent() - exhaustionTime < 300)  // 5 minutes minimum
   {
      canResume = false;
      blockingReason = "Cooldown period";
   }
   
   // Auto-resume if conditions are favorable
   if(canResume)
   {
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      Print("✅ EXHAUSTION RECOVERY DETECTED");
      Print("   Previous reason: ", exhaustionReason);
      Print("   Current RSI: ", DoubleToString(currentRSI, 1));
      Print("   Time paused: ", (TimeCurrent() - exhaustionTime) / 60, " minutes");
      Print("   Auto-resuming trading...");
      Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
      
      ResumeFromExhaustion();
   }
}

//+------------------------------------------------------------------+
//| RESUME FROM EXHAUSTION (NEW in v5.7)                            |
//+------------------------------------------------------------------+
void ResumeFromExhaustion()
{
   trendExhausted = false;
   isPaused = false;
   exhaustionReason = "";
   consecutiveLosses = 0;  // Reset counter
   profitProtectionActive = false;
   
   // Reset profit protection threshold
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   profitProtectionEquity = currentEquity * (1.0 + ProfitProtectionPercent / 100.0);
   
   Print("▶️ TRADING RESUMED");
   Print("   New profit protection level: $", DoubleToString(profitProtectionEquity, 2));
}

//+------------------------------------------------------------------+
//| TRACK TRADE OUTCOME (NEW in v5.7)                               |
//+------------------------------------------------------------------+
void TrackTradeOutcome(ulong ticket, double profit)
{
   // Add to recent trades history
   TradeHistory trade;
   trade.ticket = ticket;
   trade.isWinner = (profit > 0);
   trade.profit = profit;
   trade.closeTime = TimeCurrent();
   
   int size = ArraySize(recentTrades);
   if(size >= maxTradeHistory)
   {
      // Remove oldest trade
      for(int i = 0; i < size - 1; i++)
      {
         recentTrades[i] = recentTrades[i + 1];
      }
      recentTrades[size - 1] = trade;
   }
   else
   {
      ArrayResize(recentTrades, size + 1);
      recentTrades[size] = trade;
   }
   
   // Update consecutive counters
   if(profit > 0)
   {
      consecutiveWins++;
      consecutiveLosses = 0;
      Print("✅ Trade #", ticket, " WINNER: +$", DoubleToString(profit, 2), " (", consecutiveWins, " in a row)");
   }
   else
   {
      consecutiveLosses++;
      consecutiveWins = 0;
      Print("❌ Trade #", ticket, " LOSER: $", DoubleToString(profit, 2), " (", consecutiveLosses, " in a row)");
      
      if(consecutiveLosses >= ConsecutiveLossLimit)
      {
         Print("⚠️ WARNING: Consecutive loss limit reached!");
      }
   }
}

//+------------------------------------------------------------------+
//| CHECK ATR MODE SWITCHING                                         |
//+------------------------------------------------------------------+
void CheckATRModeSwitch()
{
   if(!EnableATRSwitch) return;
   
   if(TimeCurrent() - lastModeSwitchTime < modeSwitchCooldownBars * PeriodSeconds())
      return;
   
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
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   double distanceFromOpen = currentPrice - dayOpenPrice;
   double atrThreshold = currentATR * (ATRThresholdPercent / 100.0);
   
   bool shouldSwitch = false;
   ENUM_TRADE_DIRECTION newDirection = CurrentDirection;
   
   if(distanceFromOpen >= atrThreshold && CurrentDirection == BUYONLY)
   {
      newDirection = SELLONLY;
      shouldSwitch = true;
   }
   else if(distanceFromOpen <= -atrThreshold && CurrentDirection == SELLONLY)
   {
      newDirection = BUYONLY;
      shouldSwitch = true;
   }
   
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
   {
      return;
   }
   
   ENUM_TRADE_DIRECTION oldDirection = CurrentDirection;
   CurrentDirection = newDirection;
   modeSwitchCount++;
   
   lastModeSwitchTime = TimeCurrent();
   
   Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
   Print("🔄 MODE SWITCH #", modeSwitchCount);
   Print("   Reason: ", reason);
   Print("   From: ", oldDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   Print("   To: ", CurrentDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   
   if(ArraySize(positions) > 0)
   {
      if(CloseOnModeSwitch)
      {
         CloseAllPositions();
      }
   }
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   referencePrice = (ask + bid) / 2.0;
   currentGapSize = referencePrice * GridGapPercent / 100.0;
   
   // Reset exhaustion on mode switch
   if(trendExhausted)
   {
      Print("   Exhaustion reset due to mode switch");
      ResumeFromExhaustion();
   }
   
   CalculateNextGridLevels();
   
   Print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
   
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| CALCULATE NEXT GRID LEVELS                                       |
//+------------------------------------------------------------------+
void CalculateNextGridLevels()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   double distanceFromReference = currentPrice - referencePrice;
   int currentLevelIndex = (int)MathRound(distanceFromReference / currentGapSize);
   
   if(CurrentDirection == BUYONLY)
   {
      nextBuyLevel = referencePrice + ((currentLevelIndex - 1) * currentGapSize);
      double nextBuyLevelUp = referencePrice + ((currentLevelIndex + 1) * currentGapSize);
      
      if(MathAbs(currentPrice - nextBuyLevel) > MathAbs(currentPrice - nextBuyLevelUp))
      {
         nextBuyLevel = nextBuyLevelUp;
      }
      
      nextSellLevel = 0;
   }
   else
   {
      nextSellLevel = referencePrice + ((currentLevelIndex + 1) * currentGapSize);
      double nextSellLevelDown = referencePrice + ((currentLevelIndex - 1) * currentGapSize);
      
      if(MathAbs(currentPrice - nextSellLevel) > MathAbs(currentPrice - nextSellLevelDown))
      {
         nextSellLevel = nextSellLevelDown;
      }
      
      nextBuyLevel = 0;
   }
   
   AdjustNextLevelsForExistingPositions();
}

//+------------------------------------------------------------------+
//| ADJUST NEXT LEVELS FOR EXISTING POSITIONS                        |
//+------------------------------------------------------------------+
void AdjustNextLevelsForExistingPositions()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   double minDistanceBetweenPositions = currentGapSize * 0.8;
   
   if(CurrentDirection == BUYONLY && nextBuyLevel > 0)
   {
      bool levelOccupied = true;
      int iterations = 0;
      
      while(levelOccupied && iterations < 50)
      {
         levelOccupied = false;
         
         for(int i = 0; i < ArraySize(positions); i++)
         {
            if(MathAbs(positions[i].entryPrice - nextBuyLevel) < minDistanceBetweenPositions)
            {
               levelOccupied = true;
               if(nextBuyLevel < currentPrice)
                  nextBuyLevel -= currentGapSize;
               else
                  nextBuyLevel += currentGapSize;
               break;
            }
         }
         
         iterations++;
      }
   }
   else if(CurrentDirection == SELLONLY && nextSellLevel > 0)
   {
      bool levelOccupied = true;
      int iterations = 0;
      
      while(levelOccupied && iterations < 50)
      {
         levelOccupied = false;
         
         for(int i = 0; i < ArraySize(positions); i++)
         {
            if(MathAbs(positions[i].entryPrice - nextSellLevel) < minDistanceBetweenPositions)
            {
               levelOccupied = true;
               if(nextSellLevel > currentPrice)
                  nextSellLevel += currentGapSize;
               else
                  nextSellLevel -= currentGapSize;
               break;
            }
         }
         
         iterations++;
      }
   }
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
   
   if(specs.contractSize <= 0 || specs.point <= 0 || specs.minLot <= 0)
   {
      return false;
   }
   
   specs.minStopDistance = specs.stopLevel * specs.point;
   
   if(specs.minStopDistance == 0 || specs.stopLevel == 0)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      specs.minStopDistance = MathMax(spread * specs.point * 2, specs.point * 10);
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| WAIT FOR INDICATOR TO BE READY                                   |
//+------------------------------------------------------------------+
bool WaitForIndicator(int handle, int timeout_ms = 5000)
{
   int start = (int)GetTickCount();
   
   while((int)GetTickCount() - start < timeout_ms)
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
   if(requestedLots < specs.minLot)
      return specs.minLot;
   
   if(requestedLots > specs.maxLot)
      return specs.maxLot;
   
   double normalizedLots = MathFloor(requestedLots / specs.lotStep) * specs.lotStep;
   
   if(normalizedLots < specs.minLot)
      normalizedLots = specs.minLot;
   
   return normalizedLots;
}

//+------------------------------------------------------------------+
//| VALIDATE GRID GAP                                                 |
//+------------------------------------------------------------------+
bool ValidateGridGap()
{
   if(currentGapSize < specs.minStopDistance)
   {
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| PRINT RISK ANALYSIS                                               |
//+------------------------------------------------------------------+
void PrintRiskAnalysis()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskPerTrade = IndividualSLDollars;
   double totalRisk = riskPerTrade * MaxPositions;
   double totalRiskPercent = (totalRisk / balance) * 100.0;
   
   Print("═══════════════════════════════════════");
   Print("💰 RISK ANALYSIS:");
   Print("   Account Balance: $", DoubleToString(balance, 2));
   
   if(IndividualSLDollars > 0)
   {
      Print("   SL Risk Per Trade: $", DoubleToString(riskPerTrade, 2));
      Print("   Max Positions: ", MaxPositions);
      Print("   Total Portfolio Risk: $", DoubleToString(totalRisk, 2), " (", DoubleToString(totalRiskPercent, 1), "%)");
   }
}

//+------------------------------------------------------------------+
//| DEINITIALIZATION                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(atrHandle != INVALID_HANDLE)
      IndicatorRelease(atrHandle);
   
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
   
   ObjectsDeleteAll(0, panelPrefix);
   ChartRedraw();
   
   Print("═══════════════════════════════════════");
   Print("👋 ", EA_NAME, " stopped");
   Print("Total trades: ", totalTrades);
   Print("Exhaustion events: ", exhaustionCount);
   Print("═══════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| ON TICK - WITH EXHAUSTION DETECTION                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check trend exhaustion FIRST
   if(CheckTrendExhaustion())
   {
      UpdatePanel();
      return;
   }
   
   // Check for auto-recovery from exhaustion
   if(trendExhausted)
   {
      CheckExhaustionRecovery();
      UpdatePanel();
      return;
   }
   
   // Standard pause/stop checks
   if(isPaused || emergencyStop || dailyTargetReached)
   {
      UpdatePanel();
      return;
   }
   
   // Spread check
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpread)
   {
      UpdatePanel();
      return;
   }
   
   // Daily reset
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   if(time.day != currentDay)
   {
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyProfit = 0;
      dailyTarget = dailyStartBalance * DailyTargetPercent / 100.0;
      dailyTargetReached = false;
      currentDay = time.day;
      
      // Reset exhaustion counters daily
      consecutiveLosses = 0;
      consecutiveWins = 0;
      
      if(EnableATRSwitch)
         UpdateDayOpenPrice();
   }
   
   // ATR mode switching
   CheckATRModeSwitch();
   
   // Update peak equity
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > peakEquity)
      peakEquity = equity;
   
   // Drawdown check
   double drawdown = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   if(drawdown < -MaxDrawdownPercent)
   {
      emergencyStop = true;
      emergencyReason = "Max drawdown exceeded";
      CloseAllPositions();
      UpdatePanel();
      return;
   }
   
   // Daily profit target
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - dailyStartBalance;
   
   if(dailyProfit >= dailyTarget)
   {
      dailyTargetReached = true;
      CloseAllPositions();
      UpdatePanel();
      return;
   }
   
   // Sync positions
   SyncPositions();
   
   // Calculate profit
   CalculateTotalProfit();
   
   // Check group TP
   CheckGroupTP();
   
   // Grid logic
   if(ArraySize(positions) < MaxPositions)
   {
      static uint lastTickCheck = 0;
      uint currentTick = GetTickCount();
      
      if(currentTick - lastTickCheck >= gridCheckIntervalMs || lastTickCheck == 0)
      {
         CheckGridOptimized();
         lastTickCheck = currentTick;
      }
   }
   
   // Update panel
   static uint lastPanelUpdate = 0;
   uint currentTick = GetTickCount();
   
   if(currentTick - lastPanelUpdate >= 500 || lastPanelUpdate == 0)
   {
      UpdatePanel();
      lastPanelUpdate = currentTick;
   }
}

//+------------------------------------------------------------------+
//| OPTIMIZED GRID LOGIC                                             |
//+------------------------------------------------------------------+
void CheckGridOptimized()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   double distanceFromReference = currentPrice - referencePrice;
   int levelIndex = (int)MathRound(distanceFromReference / currentGapSize);
   double nearestGridLevel = referencePrice + (levelIndex * currentGapSize);
   
   double triggerPercent = 0.05;
   
   if(currentPrice > 10000)
      triggerPercent = 0.02;
   else if(currentPrice > 1000)
      triggerPercent = 0.03;
   
   double triggerZone = currentGapSize * triggerPercent;
   double distanceToNearestLevel = MathAbs(currentPrice - nearestGridLevel);
   
   if(distanceToNearestLevel > triggerZone)
      return;
   
   bool levelHasPosition = false;
   double minDistanceBetweenPositions = currentGapSize * 0.8;
   
   int posCount = ArraySize(positions);
   for(int i = 0; i < posCount; i++)
   {
      double dist = MathAbs(positions[i].entryPrice - nearestGridLevel);
      
      if(dist < minDistanceBetweenPositions)
      {
         levelHasPosition = true;
         break;
      }
   }
   
   if(!levelHasPosition && posCount < MaxPositions)
   {
      ENUM_ORDER_TYPE orderType = (CurrentDirection == BUYONLY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double openPrice = (CurrentDirection == BUYONLY) ? ask : bid;
      
      if(OpenPositionFast(orderType, openPrice, nearestGridLevel))
      {
         CalculateNextGridLevels();
      }
   }
}

//+------------------------------------------------------------------+
//| FAST POSITION OPENING                                            |
//+------------------------------------------------------------------+
bool OpenPositionFast(ENUM_ORDER_TYPE orderType, double price, double levelPrice)
{
   if(ArraySize(positions) >= MaxPositions)
      return false;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = validatedLotSize;
   request.type = orderType;
   request.price = price;
   request.deviation = 20;
   request.magic = MagicNumber;
   request.comment = StringFormat("AGG_%.2f", levelPrice);
   
   double pointValue = specs.tickValue / specs.tickSize;
   double positionValue = pointValue * validatedLotSize;
   
   if(IndividualTPDollars > 0)
   {
      double tpDistance = IndividualTPDollars / positionValue;
      
      if(orderType == ORDER_TYPE_BUY)
         request.tp = NormalizeDouble(price + tpDistance, specs.digits);
      else
         request.tp = NormalizeDouble(price - tpDistance, specs.digits);
   }
   
   if(IndividualSLDollars > 0)
   {
      double slDistance = IndividualSLDollars / positionValue;
      
      if(orderType == ORDER_TYPE_BUY)
         request.sl = NormalizeDouble(price - slDistance, specs.digits);
      else
         request.sl = NormalizeDouble(price + slDistance, specs.digits);
   }
   
   if(!OrderSend(request, result))
      return false;
   
   if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
   {
      totalTrades++;
      return true;
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| SYNC POSITIONS - WITH TRADE OUTCOME TRACKING                     |
//+------------------------------------------------------------------+
void SyncPositions()
{
   // Track closed positions for consecutive loss detection
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(!PositionSelectByTicket(positions[i].ticket))
      {
         // Position was closed - check if it was in history
         if(HistorySelectByPosition(positions[i].ticket))
         {
            int deals = HistoryDealsTotal();
            for(int d = deals - 1; d >= 0; d--)
            {
               ulong dealTicket = HistoryDealGetTicket(d);
               if(dealTicket > 0)
               {
                  if(HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) == positions[i].ticket)
                  {
                     if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
                     {
                        double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
                        TrackTradeOutcome(positions[i].ticket, profit);
                        break;
                     }
                  }
               }
            }
         }
      }
   }
   
   // Rebuild positions array
   ArrayResize(positions, 0);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            Position pos;
            pos.ticket = ticket;
            pos.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            pos.entryTime = (datetime)PositionGetInteger(POSITION_TIME);
            pos.isWinner = (PositionGetDouble(POSITION_PROFIT) > 0);
            
            int size = ArraySize(positions);
            ArrayResize(positions, size + 1);
            positions[size] = pos;
         }
      }
   }
   
   static int lastPosCount = -1;
   if(ArraySize(positions) != lastPosCount)
   {
      CalculateNextGridLevels();
      lastPosCount = ArraySize(positions);
   }
}

//+------------------------------------------------------------------+
//| CALCULATE TOTAL PROFIT                                            |
//+------------------------------------------------------------------+
double CalculateTotalProfit()
{
   double profit = 0;
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(PositionSelectByTicket(positions[i].ticket))
      {
         profit += PositionGetDouble(POSITION_PROFIT);
      }
   }
   
   totalProfit = profit;
   return profit;
}

//+------------------------------------------------------------------+
//| CHECK GROUP TP                                                    |
//+------------------------------------------------------------------+
void CheckGroupTP()
{
   if(GroupTPDollars <= 0) return;
   
   if(totalProfit >= GroupTPDollars)
   {
      Print("🎯 GROUP TP HIT: $", DoubleToString(totalProfit, 2));
      CloseAllPositions();
   }
}

//+------------------------------------------------------------------+
//| CLOSE PROFITABLE TRADES ONLY (NEW in v5.7)                       |
//+------------------------------------------------------------------+
void CloseProfitableTrades()
{
   Print("💰 Closing profitable trades only...");
   
   int closed = 0;
   double totalProfitClosed = 0;
   
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
               totalProfitClosed += profit;
            }
         }
      }
   }
   
   Print("✅ Closed ", closed, " profitable trades | Total profit: $", DoubleToString(totalProfitClosed, 2));
   SyncPositions();
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
   
   SyncPositions();
}

//+------------------------------------------------------------------+
//| CLOSE SINGLE POSITION                                             |
//+------------------------------------------------------------------+
bool ClosePosition(ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.position = ticket;
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.deviation = 10;
   request.magic = MagicNumber;
   
   ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   request.type = (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   return OrderSend(request, result) && (result.retcode == TRADE_RETCODE_DONE);
}

//+------------------------------------------------------------------+
//| FORMAT PRICE                                                      |
//+------------------------------------------------------------------+
string FormatPrice(double price, int digits)
{
   return DoubleToString(price, digits);
}

//+------------------------------------------------------------------+
//| ON CHART EVENT                                                    |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == panelPrefix + "PauseBtn")
      {
         isPaused = !isPaused;
         ObjectSetInteger(0, panelPrefix + "PauseBtn", OBJPROP_STATE, false);
         Print(isPaused ? "⏸️ EA PAUSED" : "▶️ EA RESUMED");
         UpdatePanel();
      }
      else if(sparam == panelPrefix + "CloseAllBtn")
      {
         CloseAllPositions();
         ObjectSetInteger(0, panelPrefix + "CloseAllBtn", OBJPROP_STATE, false);
      }
      else if(sparam == panelPrefix + "CloseProfitBtn")
      {
         CloseProfitableTrades();
         ObjectSetInteger(0, panelPrefix + "CloseProfitBtn", OBJPROP_STATE, false);
      }
      else if(sparam == panelPrefix + "SwitchBtn")
      {
         ENUM_TRADE_DIRECTION newDir = (CurrentDirection == BUYONLY) ? SELLONLY : BUYONLY;
         SwitchTradingMode(newDir, "Manual Switch");
         ObjectSetInteger(0, panelPrefix + "SwitchBtn", OBJPROP_STATE, false);
      }
      else if(sparam == panelPrefix + "ResumeBtn")
      {
         if(trendExhausted)
         {
            ResumeFromExhaustion();
            Print("▶️ Manual resume from exhaustion");
         }
         ObjectSetInteger(0, panelPrefix + "ResumeBtn", OBJPROP_STATE, false);
      }
   }
   
   if(id == CHARTEVENT_KEYDOWN)
   {
      if(lparam == 'H' || lparam == 'h')
      {
         panelVisible = !panelVisible;
         ShowHidePanel();
      }
      else if(lparam == 'D' || lparam == 'd')
      {
         PrintDebugInfo();
      }
      else if(lparam == 'R' || lparam == 'r')
      {
         if(trendExhausted)
         {
            ResumeFromExhaustion();
            Print("▶️ Manual resume from exhaustion");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| SHOW/HIDE PANEL                                                   |
//+------------------------------------------------------------------+
void ShowHidePanel()
{
   // Hide/show background first
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_TIMEFRAMES, panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
   
   int total = ObjectsTotal(0, 0, OBJ_LABEL);
   
   for(int i = 0; i < total; i++)
   {
      string name = ObjectName(0, i, 0, OBJ_LABEL);
      if(StringFind(name, panelPrefix) == 0)
      {
         ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
      }
   }
   
   total = ObjectsTotal(0, 0, OBJ_BUTTON);
   for(int i = 0; i < total; i++)
   {
      string name = ObjectName(0, i, 0, OBJ_BUTTON);
      if(StringFind(name, panelPrefix) == 0)
      {
         ObjectSetInteger(0, name, OBJPROP_TIMEFRAMES, panelVisible ? OBJ_ALL_PERIODS : OBJ_NO_PERIODS);
      }
   }
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| PRINT DEBUG INFO                                                  |
//+------------------------------------------------------------------+
void PrintDebugInfo()
{
   Print("═══════════════════════════════════════");
   Print("🔍 DEBUG INFO - ", EA_NAME, " v", EA_VERSION);
   Print("═══════════════════════════════════════");
   Print("TREND EXHAUSTION STATUS:");
   Print("  Exhausted: ", trendExhausted ? "YES" : "NO");
   if(trendExhausted)
   {
      Print("  Reason: ", exhaustionReason);
      Print("  Time: ", (TimeCurrent() - exhaustionTime) / 60, " minutes ago");
   }
   Print("  RSI: ", DoubleToString(currentRSI, 1));
   Print("  Consecutive Losses: ", consecutiveLosses);
   Print("  Consecutive Wins: ", consecutiveWins);
   Print("  Profit Protection: ", profitProtectionActive ? "ACTIVE" : "INACTIVE");
   Print("  ATR Squeeze: ", atrSqueezeDetected ? "YES" : "NO");
   Print("═══════════════════════════════════════");
   Print("CURRENT MODE: ", CurrentDirection == BUYONLY ? "BUY ONLY" : "SELL ONLY");
   Print("POSITIONS: ", ArraySize(positions), "/", MaxPositions);
   Print("P/L: $", DoubleToString(totalProfit, 2));
   Print("═══════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| CREATE PANEL                                                      |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 10;
   int y = 30;
   int lineHeight = 16;
   
   // Calculate panel dimensions - more compact
   int panelWidth = 280;
   int panelHeight = 380;  // Increased slightly for branding
   
   // Create fully solid background rectangle (NO transparency)
   ObjectCreate(0, panelPrefix + "Background", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XDISTANCE, x - 5);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YDISTANCE, y - 5);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_XSIZE, panelWidth);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_YSIZE, panelHeight);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BGCOLOR, C'20,20,20');  // Dark gray, fully solid
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BORDER_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_BACK, false);  // Always on top
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, panelPrefix + "Background", OBJPROP_ZORDER, 0);  // Top layer
   
   // Header - Professional font
   CreateLabel(panelPrefix + "Header", x, y, "TORAMA AGGRESSIVE v" + EA_VERSION, clrGold, 10, "Arial Black");
   y += lineHeight + 2;
   
   // Status line - Professional fonts
   CreateLabel(panelPrefix + "StatusLabel", x, y, "Status:", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "Status", x + 60, y, "ACTIVE", clrLimeGreen, 8, "Consolas Bold");
   CreateLabel(panelPrefix + "Direction", x + 140, y, "BUY", clrDodgerBlue, 8, "Consolas Bold");
   y += lineHeight;
   
   // Exhaustion status
   CreateLabel(panelPrefix + "ExhaustionLabel", x, y, "Safety:", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "Exhaustion", x + 60, y, "OK", clrLimeGreen, 8, "Consolas Bold");
   y += lineHeight;
   
   // RSI and Losses on same line
   CreateLabel(panelPrefix + "RSILabel", x, y, "RSI:", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "RSI", x + 40, y, "50", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "LossesLabel", x + 100, y, "Loss:", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "Losses", x + 140, y, "0", clrWhite, 8, "Consolas");
   y += lineHeight + 3;
   
   // === GRID SETTINGS SECTION ===
   CreateLabel(panelPrefix + "GridHeader", x, y, "── GRID ──", clrGold, 9, "Arial Black");
   y += lineHeight;
   
   // Gap % and Dollar
   CreateLabel(panelPrefix + "GapPercentLabel", x, y, "Gap:", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "GapPercent", x + 45, y, "0.00%", clrLimeGreen, 8, "Consolas Bold");
   CreateLabel(panelPrefix + "GapDollar", x + 120, y, "$0.00", clrLimeGreen, 8, "Consolas Bold");
   y += lineHeight;
   
   // Reference Price
   CreateLabel(panelPrefix + "RefLabel", x, y, "Ref:", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "RefPrice", x + 45, y, "$0.00", clrWhite, 8, "Consolas Bold");
   y += lineHeight + 3;
   
   // === NEXT LEVELS SECTION ===
   CreateLabel(panelPrefix + "NextHeader", x, y, "── NEXT LEVELS ──", clrGold, 9, "Arial Black");
   y += lineHeight;
   
   // Next BUY levels (up and down)
   CreateLabel(panelPrefix + "NextBuyLabel", x, y, "BUY ▲:", clrDodgerBlue, 8, "Consolas Bold");
   CreateLabel(panelPrefix + "NextBuyUp", x + 60, y, "$0.00", clrDodgerBlue, 8, "Consolas");
   y += lineHeight;
   
   CreateLabel(panelPrefix + "NextBuyDownLabel", x, y, "BUY ▼:", clrDodgerBlue, 8, "Consolas Bold");
   CreateLabel(panelPrefix + "NextBuyDown", x + 60, y, "$0.00", clrDodgerBlue, 8, "Consolas");
   y += lineHeight;
   
   // Next SELL levels (up and down)
   CreateLabel(panelPrefix + "NextSellLabel", x, y, "SELL ▲:", clrOrangeRed, 8, "Consolas Bold");
   CreateLabel(panelPrefix + "NextSellUp", x + 60, y, "$0.00", clrOrangeRed, 8, "Consolas");
   y += lineHeight;
   
   CreateLabel(panelPrefix + "NextSellDownLabel", x, y, "SELL ▼:", clrOrangeRed, 8, "Consolas Bold");
   CreateLabel(panelPrefix + "NextSellDown", x + 60, y, "$0.00", clrOrangeRed, 8, "Consolas");
   y += lineHeight + 3;
   
   // === POSITIONS SECTION ===
   CreateLabel(panelPrefix + "PosHeader", x, y, "── POSITIONS ──", clrGold, 9, "Arial Black");
   y += lineHeight;
   
   // EA Positions and Account Lots on same line
   CreateLabel(panelPrefix + "PosLabel", x, y, "EA:", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "Positions", x + 40, y, "0/100", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "AccLabel", x + 110, y, "Acc:", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "AccCounts", x + 145, y, "B:0 S:0", clrWhite, 8, "Consolas");
   y += lineHeight + 3;
   
   // === PROFIT/LOSS SECTION ===
   CreateLabel(panelPrefix + "PLHeader", x, y, "── P/L ──", clrGold, 9, "Arial Black");
   y += lineHeight;
   
   // Current P/L and Equity on same line
   CreateLabel(panelPrefix + "PnLLabel", x, y, "P/L:", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "PnL", x + 40, y, "+$0.00", clrLimeGreen, 8, "Consolas Bold");
   CreateLabel(panelPrefix + "EquityLabel", x + 135, y, "Eq:", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "Equity", x + 165, y, "$0", clrWhite, 8, "Consolas");
   y += lineHeight;
   
   // Drawdown and Daily on same line
   CreateLabel(panelPrefix + "DDLabel", x, y, "DD:", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "DD", x + 40, y, "0%", clrLimeGreen, 8, "Consolas Bold");
   CreateLabel(panelPrefix + "DailyLabel", x + 105, y, "Day:", clrWhite, 8, "Consolas");
   CreateLabel(panelPrefix + "DailyProfit", x + 145, y, "+$0", clrLimeGreen, 8, "Consolas Bold");
   y += lineHeight + 8;
   
   // DD Trigger Price
   CreateLabel(panelPrefix + "DDTriggerLabel", x, y, "DD@:", clrOrangeRed, 7, "Consolas Bold");
   CreateLabel(panelPrefix + "DDTrigger", x + 40, y, "$0.00", clrOrangeRed, 7, "Consolas");
   
   // === CONTROL BUTTONS ===
   // Row 1: Pause and Close All
   CreateButton(panelPrefix + "PauseBtn", x, y, 80, 22, "PAUSE", clrNavy, clrWhite);
   CreateButton(panelPrefix + "CloseAllBtn", x + 90, y, 80, 22, "CLOSE ALL", clrDarkRed, clrWhite);
   CreateButton(panelPrefix + "SwitchBtn", x + 180, y, 85, 22, "SWITCH", clrDarkSlateGray, clrGold);
   
   y += 27;
   
   // Row 2: Close Profitable and Resume
   CreateButton(panelPrefix + "CloseProfitBtn", x, y, 130, 22, "CLOSE PROFIT", clrDarkGreen, clrWhite);
   CreateButton(panelPrefix + "ResumeBtn", x + 140, y, 125, 22, "RESUME (R)", clrDarkOliveGreen, clrWhite);
   
   y += 32;
   
   // === TORAMA CAPITAL BRANDING (Bottom Right) ===
   // Calculate position for right-aligned branding with 10px right margin
   int brandingX = x + panelWidth - 155;  // 155px width + 10px margin from right edge
   
   CreateLabel(panelPrefix + "BrandingLabel", brandingX, y, "TORAMA", clrGold, 11, "Arial Black");
   CreateLabel(panelPrefix + "BrandingLabel2", brandingX + 65, y, "CAPITAL", clrGold, 11, "Arial Black");
   y += 16;
   CreateLabel(panelPrefix + "BrandingURL", brandingX + 10, y, "money.torama.biz", C'180,180,180', 7, "Consolas");
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| UPDATE PANEL                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   if(!ShowPanel) return;
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double currentPrice = (ask + bid) / 2.0;
   
   // Status
   string statusText = "ACTIVE";
   color statusColor = clrLimeGreen;
   
   if(trendExhausted)
   {
      statusText = "EXHAUSTED";
      statusColor = clrOrange;
   }
   else if(isPaused)
   {
      statusText = "PAUSED";
      statusColor = clrYellow;
   }
   else if(emergencyStop)
   {
      statusText = "EMERGENCY";
      statusColor = clrRed;
   }
   
   ObjectSetString(0, panelPrefix + "Status", OBJPROP_TEXT, statusText);
   ObjectSetInteger(0, panelPrefix + "Status", OBJPROP_COLOR, statusColor);
   
   // Direction
   string dirText = (CurrentDirection == BUYONLY) ? "BUY" : "SELL";
   color dirColor = (CurrentDirection == BUYONLY) ? clrDodgerBlue : clrOrangeRed;
   ObjectSetString(0, panelPrefix + "Direction", OBJPROP_TEXT, dirText);
   ObjectSetInteger(0, panelPrefix + "Direction", OBJPROP_COLOR, dirColor);
   
   // Exhaustion status
   string exhaustionText = "OK";
   color exhaustionColor = clrLimeGreen;
   
   if(trendExhausted)
   {
      if(StringFind(exhaustionReason, "RSI") >= 0)
         exhaustionText = "RSI";
      else if(StringFind(exhaustionReason, "Loss") >= 0)
         exhaustionText = "LOSS";
      else if(StringFind(exhaustionReason, "Profit") >= 0)
         exhaustionText = "PROFIT";
      else if(StringFind(exhaustionReason, "ATR") >= 0)
         exhaustionText = "ATR";
      else
         exhaustionText = "PAUSED";
      
      exhaustionColor = clrOrange;
   }
   
   ObjectSetString(0, panelPrefix + "Exhaustion", OBJPROP_TEXT, exhaustionText);
   ObjectSetInteger(0, panelPrefix + "Exhaustion", OBJPROP_COLOR, exhaustionColor);
   
   // RSI
   color rsiColor = clrWhite;
   if(CurrentDirection == BUYONLY && currentRSI > RSIOverBought - 5)
      rsiColor = clrOrange;
   else if(CurrentDirection == SELLONLY && currentRSI < RSIOverSold + 5)
      rsiColor = clrOrange;
   
   ObjectSetString(0, panelPrefix + "RSI", OBJPROP_TEXT, DoubleToString(currentRSI, 0));
   ObjectSetInteger(0, panelPrefix + "RSI", OBJPROP_COLOR, rsiColor);
   
   // Consecutive Losses
   color lossColor = consecutiveLosses >= ConsecutiveLossLimit - 1 ? clrRed : 
                     consecutiveLosses >= ConsecutiveLossLimit / 2 ? clrOrange : clrWhite;
   
   ObjectSetString(0, panelPrefix + "Losses", OBJPROP_TEXT, IntegerToString(consecutiveLosses));
   ObjectSetInteger(0, panelPrefix + "Losses", OBJPROP_COLOR, lossColor);
   
   // === GRID SECTION ===
   ObjectSetString(0, panelPrefix + "GapPercent", OBJPROP_TEXT, DoubleToString(GridGapPercent, 2) + "%");
   ObjectSetString(0, panelPrefix + "GapDollar", OBJPROP_TEXT, "$" + FormatPrice(currentGapSize, specs.digits));
   ObjectSetString(0, panelPrefix + "RefPrice", OBJPROP_TEXT, "$" + FormatPrice(referencePrice, specs.digits));
   
   // === NEXT LEVELS - SHOW BOTH UP AND DOWN ===
   double distanceFromReference = currentPrice - referencePrice;
   int currentLevelIndex = (int)MathRound(distanceFromReference / currentGapSize);
   
   double nextBuyUp = referencePrice + ((currentLevelIndex + 1) * currentGapSize);
   double nextBuyDown = referencePrice + ((currentLevelIndex - 1) * currentGapSize);
   double nextSellUp = referencePrice + ((currentLevelIndex + 1) * currentGapSize);
   double nextSellDown = referencePrice + ((currentLevelIndex - 1) * currentGapSize);
   
   if(CurrentDirection == BUYONLY)
   {
      ObjectSetString(0, panelPrefix + "NextBuyUp", OBJPROP_TEXT, "$" + FormatPrice(nextBuyUp, specs.digits));
      ObjectSetInteger(0, panelPrefix + "NextBuyUp", OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetString(0, panelPrefix + "NextBuyDown", OBJPROP_TEXT, "$" + FormatPrice(nextBuyDown, specs.digits));
      ObjectSetInteger(0, panelPrefix + "NextBuyDown", OBJPROP_COLOR, clrDodgerBlue);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "NextBuyUp", OBJPROP_TEXT, "N/A");
      ObjectSetInteger(0, panelPrefix + "NextBuyUp", OBJPROP_COLOR, clrGray);
      ObjectSetString(0, panelPrefix + "NextBuyDown", OBJPROP_TEXT, "N/A");
      ObjectSetInteger(0, panelPrefix + "NextBuyDown", OBJPROP_COLOR, clrGray);
   }
   
   if(CurrentDirection == SELLONLY)
   {
      ObjectSetString(0, panelPrefix + "NextSellUp", OBJPROP_TEXT, "$" + FormatPrice(nextSellUp, specs.digits));
      ObjectSetInteger(0, panelPrefix + "NextSellUp", OBJPROP_COLOR, clrOrangeRed);
      ObjectSetString(0, panelPrefix + "NextSellDown", OBJPROP_TEXT, "$" + FormatPrice(nextSellDown, specs.digits));
      ObjectSetInteger(0, panelPrefix + "NextSellDown", OBJPROP_COLOR, clrOrangeRed);
   }
   else
   {
      ObjectSetString(0, panelPrefix + "NextSellUp", OBJPROP_TEXT, "N/A");
      ObjectSetInteger(0, panelPrefix + "NextSellUp", OBJPROP_COLOR, clrGray);
      ObjectSetString(0, panelPrefix + "NextSellDown", OBJPROP_TEXT, "N/A");
      ObjectSetInteger(0, panelPrefix + "NextSellDown", OBJPROP_COLOR, clrGray);
   }
   
   // === POSITIONS SECTION ===
   ObjectSetString(0, panelPrefix + "Positions", OBJPROP_TEXT,
                   IntegerToString(ArraySize(positions)) + "/" + IntegerToString(MaxPositions));
   
   // Account Lots
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
   
   double netPosition = totalBuyLots - totalSellLots;
   string netText = "";
   
   if(MathAbs(netPosition) < 0.01)
      netText = "(0)";
   else if(netPosition > 0)
      netText = "(+" + DoubleToString(netPosition, 1) + "B)";
   else
      netText = "(" + DoubleToString(MathAbs(netPosition), 1) + "S)";
   
   string accLotsText = "B:" + DoubleToString(totalBuyLots, 1) + " S:" + DoubleToString(totalSellLots, 1) + " " + netText;
   ObjectSetString(0, panelPrefix + "AccCounts", OBJPROP_TEXT, accLotsText);
   
   // === P/L SECTION ===
   CalculateTotalProfit();
   color pnlColor = (totalProfit >= 0) ? clrLimeGreen : clrRed;
   ObjectSetString(0, panelPrefix + "PnL", OBJPROP_TEXT,
                   (totalProfit >= 0 ? "+" : "") + "$" + FormatPrice(totalProfit, 0));
   ObjectSetInteger(0, panelPrefix + "PnL", OBJPROP_COLOR, pnlColor);
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, panelPrefix + "Equity", OBJPROP_TEXT, "$" + FormatPrice(equity, 0));
   
   double dd = (peakEquity > 0) ? ((equity - peakEquity) / peakEquity * 100) : 0;
   color ddColor = (dd >= -5) ? clrLimeGreen : (dd >= -10) ? clrYellow : clrRed;
   ObjectSetString(0, panelPrefix + "DD", OBJPROP_TEXT, FormatPrice(dd, 1) + "%");
   ObjectSetInteger(0, panelPrefix + "DD", OBJPROP_COLOR, ddColor);
   
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfit = currentBalance - dailyStartBalance;
   
   color dailyColor = (dailyProfit >= dailyTarget) ? clrGold : 
                      (dailyProfit >= 0) ? clrLimeGreen : clrRed;
   
   ObjectSetString(0, panelPrefix + "DailyProfit", OBJPROP_TEXT,
                   (dailyProfit >= 0 ? "+" : "") + "$" + FormatPrice(dailyProfit, 0));
   ObjectSetInteger(0, panelPrefix + "DailyProfit", OBJPROP_COLOR, dailyColor);
   
   // DD Trigger Price calculation
   double ddTriggerEquity = peakEquity * (1.0 - MaxDrawdownPercent / 100.0);
   double plNeededForDDTrigger = ddTriggerEquity - equity;
   double ddTriggerPrice = currentPrice;
   
   if(ArraySize(positions) > 0)
   {
      double totalVolume = 0;
      for(int i = 0; i < ArraySize(positions); i++)
      {
         if(PositionSelectByTicket(positions[i].ticket))
            totalVolume += PositionGetDouble(POSITION_VOLUME);
      }
      
      if(totalVolume > 0)
      {
         double pointValue = specs.tickValue / specs.tickSize;
         double plPerPointMove = pointValue * totalVolume;
         
         if(plPerPointMove > 0)
         {
            double pointsMoveToDDTrigger = plNeededForDDTrigger / plPerPointMove;
            ddTriggerPrice = currentPrice + (CurrentDirection == BUYONLY ? pointsMoveToDDTrigger : -pointsMoveToDDTrigger);
         }
      }
   }
   
   ObjectSetString(0, panelPrefix + "DDTrigger", OBJPROP_TEXT, "$" + FormatPrice(ddTriggerPrice, specs.digits));
   
   // Update button text
   ObjectSetString(0, panelPrefix + "PauseBtn", OBJPROP_TEXT, isPaused ? "RESUME" : "PAUSE");
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
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
