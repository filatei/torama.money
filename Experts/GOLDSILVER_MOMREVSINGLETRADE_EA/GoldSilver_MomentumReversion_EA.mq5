//+------------------------------------------------------------------+
//|                            GoldSilver_MomentumReversion_EA.mq5   |
//|                                    Copyright 2026, TORAMA CAPITAL |
//|                                          https://torama.money      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.00"
#property description "Gold/Silver Momentum Reversion EA"
#property description "Multi-Timeframe Analysis with Aggressive Trailing"
#property description "Contact: ea@torama.money"

//--- Input Parameters
input group "===== STRATEGY SETTINGS ====="
input int      MomentumPips = 30;               // Minimum Momentum Move (pips)
input int      ConfirmationCandles = 3;         // Confirmation Candles (M5)
input bool     UseBollingerFilter = true;       // Use Bollinger Band Filter
input bool     UseEMAFilter = true;             // Use EMA Trend Filter

input group "===== ENTRY FILTERS ====="
input double   MaxSpreadPips = 3.0;             // Maximum Spread (pips)
input double   MinATR_M15 = 0.5;                // Minimum ATR(14) on M15
input double   MaxATR_M15 = 3.0;                // Maximum ATR(14) on M15
input bool     TradeOnlyTrending = true;        // Trade Only in Trending Markets

input group "===== STOP LOSS ====="
input int      InitialSL_Pips = 20;             // Initial Stop Loss (pips)
input bool     UseATRBasedSL = true;            // Use ATR-Based Stop Loss
input double   ATR_SL_Multiplier = 1.5;         // ATR Multiplier for SL

input group "===== BREAK-EVEN & TRAILING ====="
input int      BreakEvenPips = 15;              // Move to Break-Even at (pips)
input int      ProfitLockPips = 25;             // Lock Profit at (pips)
input int      ProfitLockAmount = 10;           // Profit Amount to Lock (pips)
input int      TrailingActivation = 30;         // Activate Trailing at (pips)
input int      TrailingDistance = 20;           // Trailing Distance (pips)
input bool     TrailBySwing = false;            // Trail by M5 Swing Points
input int      MaxTradeHours = 6;               // Maximum Trade Duration (hours)

input group "===== RISK MANAGEMENT ====="
input double   RiskPercent = 1.0;               // Risk Per Trade (%)
input int      MaxDailyTrades = 5;              // Maximum Daily Trades
input double   MaxDailyLossPercent = 3.0;       // Daily Loss Limit (%)
input int      CooldownMinutes = 30;            // Cooldown Between Trades (minutes)

input group "===== TIME FILTERS ====="
input bool     UseTimeFilter = true;            // Enable Time Filter
input int      StartHour = 8;                   // Trading Start Hour (London)
input int      EndHour = 20;                    // Trading End Hour (NY Close)
input bool     AvoidNews = true;                // Avoid Major News Times

input group "===== ADVANCED SETTINGS ====="
input int      MagicNumber = 200200;            // Magic Number
input string   TradeComment = "TORAMA_GS";      // Trade Comment
input bool     ShowPanel = true;                // Show Statistics Panel

//--- Global Variables
int handleATR_M15, handleATR_H1;
int handleBB_M5, handleBB_H1;
int handleEMA20_H1, handleEMA50_H1;
int handleEMA20_H4, handleEMA50_H4;

datetime lastTradeTime = 0;
int dailyTradeCount = 0;
datetime lastDayReset = 0;
double dailyStartBalance = 0;
double dailyProfitLoss = 0;

// Statistics
int totalTrades = 0;
int winningTrades = 0;
int losingTrades = 0;
int breakEvenTrades = 0;
double totalProfit = 0;
double totalLoss = 0;
double largestWin = 0;
double largestLoss = 0;

// Multi-timeframe data
string trendDirection = "NEUTRAL";
double currentATR_M15 = 0;
double currentATR_H1 = 0;
double currentSpread = 0;
double currentVolatility = 0;

// Panel objects
string panelPrefix = "TORAMA_GS_";

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize indicators
   handleATR_M15 = iATR(_Symbol, PERIOD_M15, 14);
   handleATR_H1 = iATR(_Symbol, PERIOD_H1, 14);
   handleBB_M5 = iBands(_Symbol, PERIOD_M5, 20, 0, 2, PRICE_CLOSE);
   handleBB_H1 = iBands(_Symbol, PERIOD_H1, 20, 0, 2, PRICE_CLOSE);
   handleEMA20_H1 = iMA(_Symbol, PERIOD_H1, 20, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA50_H1 = iMA(_Symbol, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA20_H4 = iMA(_Symbol, PERIOD_H4, 20, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA50_H4 = iMA(_Symbol, PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE);
   
   if(handleATR_M15 == INVALID_HANDLE || handleATR_H1 == INVALID_HANDLE ||
      handleBB_M5 == INVALID_HANDLE || handleBB_H1 == INVALID_HANDLE ||
      handleEMA20_H1 == INVALID_HANDLE || handleEMA50_H1 == INVALID_HANDLE ||
      handleEMA20_H4 == INVALID_HANDLE || handleEMA50_H4 == INVALID_HANDLE)
   {
      Print("Error creating indicators");
      return(INIT_FAILED);
   }
   
   // Initialize daily counters
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastDayReset = TimeCurrent();
   
   // Create statistics panel
   if(ShowPanel)
      CreateStatsPanel();
   
   Print("========================================");
   Print("TORAMA CAPITAL - Gold/Silver Momentum Reversion EA");
   Print("Symbol: ", _Symbol);
   Print("Version 1.00 - Initialized Successfully");
   Print("Contact: ea@torama.money");
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicator handles
   IndicatorRelease(handleATR_M15);
   IndicatorRelease(handleATR_H1);
   IndicatorRelease(handleBB_M5);
   IndicatorRelease(handleBB_H1);
   IndicatorRelease(handleEMA20_H1);
   IndicatorRelease(handleEMA50_H1);
   IndicatorRelease(handleEMA20_H4);
   IndicatorRelease(handleEMA50_H4);
   
   // Remove panel
   RemoveStatsPanel();
   
   Print("EA Stopped. Total Trades: ", totalTrades, 
         " | Wins: ", winningTrades, 
         " | Losses: ", losingTrades,
         " | BE: ", breakEvenTrades);
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for new day
   CheckDailyReset();
   
   // Update multi-timeframe analysis
   UpdateMarketAnalysis();
   
   // Update panel
   if(ShowPanel)
      UpdateStatsPanel();
   
   // Manage existing position
   if(PositionsTotal() > 0)
   {
      ManagePosition();
      return; // Only one position at a time
   }
   
   // Check if we can open new trade
   if(!CanTrade())
      return;
   
   // Look for entry signals
   CheckForEntry();
}

//+------------------------------------------------------------------+
//| Update market analysis                                             |
//+------------------------------------------------------------------+
void UpdateMarketAnalysis()
{
   // Get ATR values
   double atr_m15[], atr_h1[];
   ArraySetAsSeries(atr_m15, true);
   ArraySetAsSeries(atr_h1, true);
   
   if(CopyBuffer(handleATR_M15, 0, 0, 3, atr_m15) > 0)
      currentATR_M15 = atr_m15[0];
   
   if(CopyBuffer(handleATR_H1, 0, 0, 3, atr_h1) > 0)
      currentATR_H1 = atr_h1[0];
   
   // Get spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   currentSpread = spread * _Point / GetPipValue();
   
   // Calculate volatility (normalized ATR)
   double close = iClose(_Symbol, PERIOD_M15, 0);
   currentVolatility = (currentATR_M15 / close) * 100;
   
   // Determine trend direction
   double ema20_h1[], ema50_h1[], ema20_h4[], ema50_h4[];
   ArraySetAsSeries(ema20_h1, true);
   ArraySetAsSeries(ema50_h1, true);
   ArraySetAsSeries(ema20_h4, true);
   ArraySetAsSeries(ema50_h4, true);
   
   if(CopyBuffer(handleEMA20_H1, 0, 0, 2, ema20_h1) > 0 &&
      CopyBuffer(handleEMA50_H1, 0, 0, 2, ema50_h1) > 0 &&
      CopyBuffer(handleEMA20_H4, 0, 0, 2, ema20_h4) > 0 &&
      CopyBuffer(handleEMA50_H4, 0, 0, 2, ema50_h4) > 0)
   {
      bool h1_bullish = ema20_h1[0] > ema50_h1[0];
      bool h4_bullish = ema20_h4[0] > ema50_h4[0];
      
      if(h1_bullish && h4_bullish)
         trendDirection = "BULLISH";
      else if(!h1_bullish && !h4_bullish)
         trendDirection = "BEARISH";
      else
         trendDirection = "NEUTRAL";
   }
}

//+------------------------------------------------------------------+
//| Check if we can trade                                              |
//+------------------------------------------------------------------+
bool CanTrade()
{
   // Check time filter
   if(UseTimeFilter)
   {
      MqlDateTime dt;
      TimeCurrent(dt);
      if(dt.hour < StartHour || dt.hour >= EndHour)
         return false;
   }
   
   // Check daily trade limit
   if(dailyTradeCount >= MaxDailyTrades)
      return false;
   
   // Check daily loss limit
   if(dailyProfitLoss <= -(MaxDailyLossPercent / 100.0 * dailyStartBalance))
   {
      Print("Daily loss limit reached: $", DoubleToString(-dailyProfitLoss, 2));
      return false;
   }
   
   // Check cooldown
   if((TimeCurrent() - lastTradeTime) < CooldownMinutes * 60)
      return false;
   
   // Check spread
   if(currentSpread > MaxSpreadPips)
      return false;
   
   // Check ATR range
   if(currentATR_M15 < MinATR_M15 * GetPipValue() || 
      currentATR_M15 > MaxATR_M15 * GetPipValue())
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Check for entry signal                                             |
//+------------------------------------------------------------------+
void CheckForEntry()
{
   // Get H1 data to identify momentum move
   double h1_high[], h1_low[], h1_close[];
   ArraySetAsSeries(h1_high, true);
   ArraySetAsSeries(h1_low, true);
   ArraySetAsSeries(h1_close, true);
   
   if(CopyHigh(_Symbol, PERIOD_H1, 0, 10, h1_high) <= 0) return;
   if(CopyLow(_Symbol, PERIOD_H1, 0, 10, h1_low) <= 0) return;
   if(CopyClose(_Symbol, PERIOD_H1, 0, 10, h1_close) <= 0) return;
   
   // Find recent swing high and low
   double recent_high = h1_high[ArrayMaximum(h1_high, 0, 5)];
   double recent_low = h1_low[ArrayMinimum(h1_low, 0, 5)];
   double pip_value = GetPipValue();
   
   // Check for bullish setup (sharp move down + reversal)
   double down_move = (recent_high - recent_low) / pip_value;
   if(down_move >= MomentumPips)
   {
      if(CheckBuyConfirmation())
      {
         // Additional filters
         if(TradeOnlyTrending && trendDirection == "BEARISH")
            return;
         
         if(UseBollingerFilter && !CheckBollingerBuy())
            return;
         
         if(UseEMAFilter && !CheckEMABuy())
            return;
         
         OpenBuyPosition();
         return;
      }
   }
   
   // Check for bearish setup (sharp move up + reversal)
   double up_move = (recent_high - recent_low) / pip_value;
   if(up_move >= MomentumPips)
   {
      if(CheckSellConfirmation())
      {
         // Additional filters
         if(TradeOnlyTrending && trendDirection == "BULLISH")
            return;
         
         if(UseBollingerFilter && !CheckBollingerSell())
            return;
         
         if(UseEMAFilter && !CheckEMASell())
            return;
         
         OpenSellPosition();
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Check buy confirmation on M5                                       |
//+------------------------------------------------------------------+
bool CheckBuyConfirmation()
{
   double m5_close[];
   ArraySetAsSeries(m5_close, true);
   
   if(CopyClose(_Symbol, PERIOD_M5, 0, ConfirmationCandles + 1, m5_close) <= 0)
      return false;
   
   // Check for consecutive bullish candles
   for(int i = 0; i < ConfirmationCandles; i++)
   {
      if(m5_close[i] <= m5_close[i+1])
         return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check sell confirmation on M5                                      |
//+------------------------------------------------------------------+
bool CheckSellConfirmation()
{
   double m5_close[];
   ArraySetAsSeries(m5_close, true);
   
   if(CopyClose(_Symbol, PERIOD_M5, 0, ConfirmationCandles + 1, m5_close) <= 0)
      return false;
   
   // Check for consecutive bearish candles
   for(int i = 0; i < ConfirmationCandles; i++)
   {
      if(m5_close[i] >= m5_close[i+1])
         return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check Bollinger Band filter for buy                                |
//+------------------------------------------------------------------+
bool CheckBollingerBuy()
{
   double bb_lower[];
   ArraySetAsSeries(bb_lower, true);
   
   if(CopyBuffer(handleBB_M5, 2, 0, 2, bb_lower) <= 0)
      return false;
   
   double current_price = iClose(_Symbol, PERIOD_M5, 0);
   
   // Price should be near or below lower band for buy
   return (current_price <= bb_lower[0] * 1.002); // Within 0.2% of lower band
}

//+------------------------------------------------------------------+
//| Check Bollinger Band filter for sell                               |
//+------------------------------------------------------------------+
bool CheckBollingerSell()
{
   double bb_upper[];
   ArraySetAsSeries(bb_upper, true);
   
   if(CopyBuffer(handleBB_M5, 1, 0, 2, bb_upper) <= 0)
      return false;
   
   double current_price = iClose(_Symbol, PERIOD_M5, 0);
   
   // Price should be near or above upper band for sell
   return (current_price >= bb_upper[0] * 0.998); // Within 0.2% of upper band
}

//+------------------------------------------------------------------+
//| Check EMA filter for buy                                           |
//+------------------------------------------------------------------+
bool CheckEMABuy()
{
   double ema20[], ema50[];
   ArraySetAsSeries(ema20, true);
   ArraySetAsSeries(ema50, true);
   
   if(CopyBuffer(handleEMA20_H1, 0, 0, 2, ema20) <= 0) return false;
   if(CopyBuffer(handleEMA50_H1, 0, 0, 2, ema50) <= 0) return false;
   
   double current_price = iClose(_Symbol, PERIOD_H1, 0);
   
   // For buy: price above EMA20 or pullback to EMA area
   return (current_price >= ema20[0] || (current_price >= ema50[0] && ema20[0] > ema50[0]));
}

//+------------------------------------------------------------------+
//| Check EMA filter for sell                                          |
//+------------------------------------------------------------------+
bool CheckEMASell()
{
   double ema20[], ema50[];
   ArraySetAsSeries(ema20, true);
   ArraySetAsSeries(ema50, true);
   
   if(CopyBuffer(handleEMA20_H1, 0, 0, 2, ema20) <= 0) return false;
   if(CopyBuffer(handleEMA50_H1, 0, 0, 2, ema50) <= 0) return false;
   
   double current_price = iClose(_Symbol, PERIOD_H1, 0);
   
   // For sell: price below EMA20 or rally to EMA area
   return (current_price <= ema20[0] || (current_price <= ema50[0] && ema20[0] < ema50[0]));
}

//+------------------------------------------------------------------+
//| Open buy position                                                  |
//+------------------------------------------------------------------+
void OpenBuyPosition()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pip_value = GetPipValue();
   
   // Calculate stop loss
   double sl_distance = InitialSL_Pips * pip_value;
   if(UseATRBasedSL)
      sl_distance = currentATR_M15 * ATR_SL_Multiplier;
   
   double sl = ask - sl_distance;
   
   // Calculate lot size
   double lotSize = CalculateLotSize(sl_distance);
   
   // Normalize
   sl = NormalizeDouble(sl, _Digits);
   lotSize = NormalizeDouble(lotSize, 2);
   
   // Open position
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type = ORDER_TYPE_BUY;
   request.price = ask;
   request.sl = sl;
   request.tp = 0; // No TP, will trail
   request.deviation = 20;
   request.magic = MagicNumber;
   request.comment = TradeComment;
   
   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE)
      {
         Print("✓ BUY Position Opened: Ticket #", result.order,
               " | Price: ", ask,
               " | SL: ", sl,
               " | Lot: ", lotSize,
               " | Trend: ", trendDirection);
         
         lastTradeTime = TimeCurrent();
         dailyTradeCount++;
         totalTrades++;
         
         return;
      }
   }
   
   Print("✗ BUY Order Failed: ", result.retcode, " - ", result.comment);
}

//+------------------------------------------------------------------+
//| Open sell position                                                 |
//+------------------------------------------------------------------+
void OpenSellPosition()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double pip_value = GetPipValue();
   
   // Calculate stop loss
   double sl_distance = InitialSL_Pips * pip_value;
   if(UseATRBasedSL)
      sl_distance = currentATR_M15 * ATR_SL_Multiplier;
   
   double sl = bid + sl_distance;
   
   // Calculate lot size
   double lotSize = CalculateLotSize(sl_distance);
   
   // Normalize
   sl = NormalizeDouble(sl, _Digits);
   lotSize = NormalizeDouble(lotSize, 2);
   
   // Open position
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type = ORDER_TYPE_SELL;
   request.price = bid;
   request.sl = sl;
   request.tp = 0; // No TP, will trail
   request.deviation = 20;
   request.magic = MagicNumber;
   request.comment = TradeComment;
   
   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE)
      {
         Print("✓ SELL Position Opened: Ticket #", result.order,
               " | Price: ", bid,
               " | SL: ", sl,
               " | Lot: ", lotSize,
               " | Trend: ", trendDirection);
         
         lastTradeTime = TimeCurrent();
         dailyTradeCount++;
         totalTrades++;
         
         return;
      }
   }
   
   Print("✗ SELL Order Failed: ", result.retcode, " - ", result.comment);
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                   |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = accountBalance * (RiskPercent / 100.0);
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   double slPips = slDistance / _Point;
   double lotSize = (riskAmount) / (slPips * tickValue / tickSize);
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   if(lotSize < minLot) lotSize = minLot;
   if(lotSize > maxLot) lotSize = maxLot;
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Manage open position                                               |
//+------------------------------------------------------------------+
void ManagePosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double posOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
      double posSL = PositionGetDouble(POSITION_SL);
      datetime posOpenTime = (datetime)PositionGetInteger(POSITION_TIME);
      double pip_value = GetPipValue();
      
      // Calculate profit in pips
      double profitPips = 0;
      if(posType == POSITION_TYPE_BUY)
         profitPips = (currentPrice - posOpenPrice) / pip_value;
      else
         profitPips = (posOpenPrice - currentPrice) / pip_value;
      
      // Check time limit
      int hoursOpen = (int)((TimeCurrent() - posOpenTime) / 3600);
      if(hoursOpen >= MaxTradeHours)
      {
         if(profitPips > 0)
            ClosePosition(ticket, "Time Limit - In Profit");
         else
            ClosePosition(ticket, "Time Limit - Cut Loss");
         continue;
      }
      
      // Phase 1: Break-Even
      if(profitPips >= BreakEvenPips)
      {
         if(posType == POSITION_TYPE_BUY)
         {
            if(posSL < posOpenPrice)
               ModifyStopLoss(ticket, posOpenPrice, "Break-Even");
         }
         else
         {
            if(posSL > posOpenPrice || posSL == 0)
               ModifyStopLoss(ticket, posOpenPrice, "Break-Even");
         }
      }
      
      // Phase 2: Profit Lock
      if(profitPips >= ProfitLockPips)
      {
         double lockPrice = 0;
         if(posType == POSITION_TYPE_BUY)
         {
            lockPrice = posOpenPrice + (ProfitLockAmount * pip_value);
            if(posSL < lockPrice)
               ModifyStopLoss(ticket, lockPrice, "Profit Lock");
         }
         else
         {
            lockPrice = posOpenPrice - (ProfitLockAmount * pip_value);
            if(posSL > lockPrice || posSL == 0)
               ModifyStopLoss(ticket, lockPrice, "Profit Lock");
         }
      }
      
      // Phase 3: Trailing Stop
      if(profitPips >= TrailingActivation)
      {
         double newSL = 0;
         
         if(TrailBySwing)
         {
            // Trail by M5 swing points
            newSL = GetSwingTrailLevel(posType);
         }
         else
         {
            // Fixed trailing distance
            if(posType == POSITION_TYPE_BUY)
               newSL = currentPrice - (TrailingDistance * pip_value);
            else
               newSL = currentPrice + (TrailingDistance * pip_value);
         }
         
         newSL = NormalizeDouble(newSL, _Digits);
         
         // Only tighten, never widen
         if(posType == POSITION_TYPE_BUY)
         {
            if(newSL > posSL)
               ModifyStopLoss(ticket, newSL, "Trailing Stop");
         }
         else
         {
            if(newSL < posSL || posSL == 0)
               ModifyStopLoss(ticket, newSL, "Trailing Stop");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get swing-based trail level                                        |
//+------------------------------------------------------------------+
double GetSwingTrailLevel(ENUM_POSITION_TYPE posType)
{
   double m5_high[], m5_low[];
   ArraySetAsSeries(m5_high, true);
   ArraySetAsSeries(m5_low, true);
   
   if(CopyHigh(_Symbol, PERIOD_M5, 0, 10, m5_high) <= 0) return 0;
   if(CopyLow(_Symbol, PERIOD_M5, 0, 10, m5_low) <= 0) return 0;
   
   if(posType == POSITION_TYPE_BUY)
   {
      // Find recent swing low
      double swing_low = m5_low[ArrayMinimum(m5_low, 1, 5)]; // Skip current candle
      return swing_low - (5 * _Point); // Buffer
   }
   else
   {
      // Find recent swing high
      double swing_high = m5_high[ArrayMaximum(m5_high, 1, 5)]; // Skip current candle
      return swing_high + (5 * _Point); // Buffer
   }
}

//+------------------------------------------------------------------+
//| Modify stop loss                                                   |
//+------------------------------------------------------------------+
void ModifyStopLoss(ulong ticket, double newSL, string reason)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_SLTP;
   request.position = ticket;
   request.symbol = PositionGetString(POSITION_SYMBOL);
   request.sl = newSL;
   request.tp = PositionGetDouble(POSITION_TP);
   
   if(OrderSend(request, result))
   {
      Print("✓ SL Modified: Ticket #", ticket, " | New SL: ", newSL, " | Reason: ", reason);
   }
}

//+------------------------------------------------------------------+
//| Close position                                                     |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = PositionGetString(POSITION_SYMBOL);
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.type = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   request.price = (posType == POSITION_TYPE_BUY) ? 
                   SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   request.deviation = 20;
   request.magic = MagicNumber;
   
   double profit = PositionGetDouble(POSITION_PROFIT);
   
   if(OrderSend(request, result))
   {
      Print("✓ Position Closed: Ticket #", ticket, " | Reason: ", reason, " | Profit: $", DoubleToString(profit, 2));
      
      // Update statistics
      dailyProfitLoss += profit;
      
      if(profit > 1.0)
      {
         winningTrades++;
         totalProfit += profit;
         if(profit > largestWin) largestWin = profit;
      }
      else if(profit < -1.0)
      {
         losingTrades++;
         totalLoss += MathAbs(profit);
         if(profit < largestLoss) largestLoss = profit;
      }
      else
      {
         breakEvenTrades++;
      }
   }
}

//+------------------------------------------------------------------+
//| Get pip value                                                      |
//+------------------------------------------------------------------+
double GetPipValue()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // For 5-digit and 3-digit brokers
   if(digits == 5 || digits == 3)
      return point * 10;
   else
      return point;
}

//+------------------------------------------------------------------+
//| Check and reset daily counters                                     |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime dtCurrent, dtLast;
   TimeCurrent(dtCurrent);
   TimeToStruct(lastDayReset, dtLast);
   
   if(dtCurrent.day != dtLast.day)
   {
      Print("=== NEW TRADING DAY ===");
      Print("Yesterday's Trades: ", dailyTradeCount);
      Print("Yesterday's P&L: $", DoubleToString(dailyProfitLoss, 2));
      
      dailyTradeCount = 0;
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      dailyProfitLoss = 0;
      lastDayReset = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Create statistics panel                                            |
//+------------------------------------------------------------------+
void CreateStatsPanel()
{
   int xPos = 20;
   int yPos = 25;
   int width = 420;
   int lineHeight = 20;
   
   // Main background - solid and above all chart elements
   CreateRectangle(panelPrefix + "MainBG", xPos-5, yPos-5, width, 520, C'25,25,40', 2, clrWhite);
   ObjectSetInteger(0, panelPrefix + "MainBG", OBJPROP_BACK, false); // Foreground
   ObjectSetInteger(0, panelPrefix + "MainBG", OBJPROP_ZORDER, 1000); // Top layer
   
   // Header background
   CreateRectangle(panelPrefix + "HeaderBG", xPos, yPos, width-10, 30, C'0,102,204', 0, clrNONE);
   ObjectSetInteger(0, panelPrefix + "HeaderBG", OBJPROP_BACK, false);
   ObjectSetInteger(0, panelPrefix + "HeaderBG", OBJPROP_ZORDER, 1001);
   
   // EA Name
   CreateText(panelPrefix + "EAName", xPos + 10, yPos + 5, "GOLD/SILVER MOMENTUM EA", 11, "Arial Black", clrWhite);
   yPos += 35;
   
   // Account section header
   CreateText(panelPrefix + "AccHeader", xPos + 5, yPos, "━━━ ACCOUNT STATUS ━━━", 9, "Arial Bold", C'0,204,255');
   yPos += lineHeight;
   
   // Balance, Equity, Margin on same line (BOLD)
   CreateText(panelPrefix + "BalEqMar", xPos + 5, yPos, "BAL: $0 | EQ: $0 | MAR: 0%", 9, "Arial Black", clrLimeGreen);
   yPos += lineHeight + 3;
   
   // P/L section
   CreateText(panelPrefix + "PLHeader", xPos + 5, yPos, "━━━ PROFIT & LOSS ━━━", 9, "Arial Bold", C'0,204,255');
   yPos += lineHeight;
   
   CreateText(panelPrefix + "CurrentPL", xPos + 5, yPos, "Current P/L: $0.00", 9, "Consolas", clrWhite);
   yPos += lineHeight;
   
   CreateText(panelPrefix + "DailyPL", xPos + 5, yPos, "Daily P/L: $0.00", 9, "Consolas", clrWhite);
   yPos += lineHeight + 3;
   
   // Trade statistics
   CreateText(panelPrefix + "StatsHeader", xPos + 5, yPos, "━━━ TRADE STATISTICS ━━━", 9, "Arial Bold", C'0,204,255');
   yPos += lineHeight;
   
   CreateText(panelPrefix + "WinsLosses", xPos + 5, yPos, "Wins: 0 | Losses: 0 | BE: 0", 9, "Consolas", clrWhite);
   yPos += lineHeight;
   
   CreateText(panelPrefix + "TotalTrades", xPos + 5, yPos, "Total Trades: 0 | Daily: 0/5", 9, "Consolas", C'180,180,180');
   yPos += lineHeight;
   
   CreateText(panelPrefix + "WinRate", xPos + 5, yPos, "Win Rate: 0% | PF: 0.00", 9, "Consolas", C'180,180,180');
   yPos += lineHeight + 3;
   
   // Market conditions
   CreateText(panelPrefix + "MarketHeader", xPos + 5, yPos, "━━━ MARKET CONDITIONS ━━━", 9, "Arial Bold", C'0,204,255');
   yPos += lineHeight;
   
   CreateText(panelPrefix + "Trend", xPos + 5, yPos, "Trend: NEUTRAL", 9, "Consolas", clrYellow);
   yPos += lineHeight;
   
   CreateText(panelPrefix + "SpreadLot", xPos + 5, yPos, "Spread: 0.0 | Lot: 0.00", 9, "Consolas", C'180,180,180');
   yPos += lineHeight;
   
   CreateText(panelPrefix + "Volatility", xPos + 5, yPos, "Volatility: Normal | ATR: 0.00", 9, "Consolas", C'180,180,180');
   yPos += lineHeight + 3;
   
   // Position status
   CreateText(panelPrefix + "PosHeader", xPos + 5, yPos, "━━━ POSITION STATUS ━━━", 9, "Arial Bold", C'0,204,255');
   yPos += lineHeight;
   
   CreateText(panelPrefix + "Position", xPos + 5, yPos, "No Open Position", 9, "Consolas", C'150,150,150');
   yPos += lineHeight;
   
   CreateText(panelPrefix + "PosPL", xPos + 5, yPos, "Position P/L: $0.00 (0 pips)", 9, "Consolas", clrWhite);
   yPos += lineHeight;
   
   CreateText(panelPrefix + "Duration", xPos + 5, yPos, "Duration: 0h 0m | Next: BE", 9, "Consolas", C'180,180,180');
   yPos += lineHeight + 10;
   
   // Branding - LARGE BOLD WHITE CHALK
   CreateText(panelPrefix + "Brand", xPos + width - 200, yPos, "TORAMA CAPITAL", 14, "Arial Black", clrWhite);
   yPos += 22;
   CreateText(panelPrefix + "Contact", xPos + width - 200, yPos, "ea@torama.money", 8, "Arial", C'180,180,180');
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update statistics panel                                            |
//+------------------------------------------------------------------+
void UpdateStatsPanel()
{
   // Account info
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double usedMargin = AccountInfoDouble(ACCOUNT_MARGIN);
   double marginLevel = (usedMargin > 0) ? (equity / usedMargin * 100) : 0;
   
   string balEqMar = StringFormat("BAL: $%.0f | EQ: $%.0f | MAR: %.0f%%", 
                                  balance, equity, marginLevel);
   UpdateText(panelPrefix + "BalEqMar", balEqMar, clrLimeGreen);
   
   // P/L
   double currentPL = equity - balance;
   color plColor = (currentPL >= 0) ? clrLimeGreen : clrOrangeRed;
   UpdateText(panelPrefix + "CurrentPL", "Current P/L: $" + DoubleToString(currentPL, 2), plColor);
   
   color dailyColor = (dailyProfitLoss >= 0) ? clrLimeGreen : clrOrangeRed;
   UpdateText(panelPrefix + "DailyPL", "Daily P/L: $" + DoubleToString(dailyProfitLoss, 2), dailyColor);
   
   // Statistics
   UpdateText(panelPrefix + "WinsLosses", 
              StringFormat("Wins: %d | Losses: %d | BE: %d", winningTrades, losingTrades, breakEvenTrades));
   
   UpdateText(panelPrefix + "TotalTrades", 
              StringFormat("Total Trades: %d | Daily: %d/%d", totalTrades, dailyTradeCount, MaxDailyTrades));
   
   double winRate = (totalTrades > 0) ? ((double)(winningTrades) / totalTrades * 100) : 0;
   double profitFactor = (totalLoss > 0) ? (totalProfit / totalLoss) : 0;
   UpdateText(panelPrefix + "WinRate", 
              StringFormat("Win Rate: %.1f%% | PF: %.2f", winRate, profitFactor));
   
   // Market conditions
   color trendColor = (trendDirection == "BULLISH") ? clrLimeGreen : 
                     (trendDirection == "BEARISH") ? clrOrangeRed : clrYellow;
   UpdateText(panelPrefix + "Trend", "Trend: " + trendDirection, trendColor);
   
   double currentLot = 0;
   if(PositionsTotal() > 0)
   {
      PositionSelect(_Symbol);
      currentLot = PositionGetDouble(POSITION_VOLUME);
   }
   
   UpdateText(panelPrefix + "SpreadLot", 
              StringFormat("Spread: %.1f | Lot: %.2f", currentSpread, currentLot));
   
   string volStatus = (currentVolatility < 0.05) ? "Low" : 
                     (currentVolatility < 0.10) ? "Normal" : "High";
   UpdateText(panelPrefix + "Volatility", 
              StringFormat("Volatility: %s | ATR: %.2f", volStatus, currentATR_M15 / GetPipValue()));
   
   // Position status
   if(PositionsTotal() > 0)
   {
      if(PositionSelect(_Symbol))
      {
         ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double posOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
         double posProfit = PositionGetDouble(POSITION_PROFIT);
         datetime posOpenTime = (datetime)PositionGetInteger(POSITION_TIME);
         
         string posTypeStr = (posType == POSITION_TYPE_BUY) ? "LONG" : "SHORT";
         color posColor = (posType == POSITION_TYPE_BUY) ? clrDodgerBlue : clrOrangeRed;
         
         UpdateText(panelPrefix + "Position", 
                   StringFormat("%s @ %.3f", posTypeStr, posOpenPrice), posColor);
         
         double profitPips = 0;
         if(posType == POSITION_TYPE_BUY)
            profitPips = (currentPrice - posOpenPrice) / GetPipValue();
         else
            profitPips = (posOpenPrice - currentPrice) / GetPipValue();
         
         color posPLColor = (posProfit >= 0) ? clrLimeGreen : clrOrangeRed;
         UpdateText(panelPrefix + "PosPL", 
                   StringFormat("Position P/L: $%.2f (%.1f pips)", posProfit, profitPips), posPLColor);
         
         int durationSec = (int)(TimeCurrent() - posOpenTime);
         int hours = durationSec / 3600;
         int minutes = (durationSec % 3600) / 60;
         
         string nextAction = "Waiting";
         if(profitPips < BreakEvenPips)
            nextAction = StringFormat("BE @ %d pips", BreakEvenPips);
         else if(profitPips < ProfitLockPips)
            nextAction = StringFormat("Lock @ %d pips", ProfitLockPips);
         else if(profitPips < TrailingActivation)
            nextAction = StringFormat("Trail @ %d pips", TrailingActivation);
         else
            nextAction = "Trailing Active";
         
         UpdateText(panelPrefix + "Duration", 
                   StringFormat("Duration: %dh %dm | Next: %s", hours, minutes, nextAction));
      }
   }
   else
   {
      UpdateText(panelPrefix + "Position", "No Open Position", C'150,150,150');
      UpdateText(panelPrefix + "PosPL", "Position P/L: $0.00 (0 pips)", clrWhite);
      
      int cooldownRemain = CooldownMinutes - (int)((TimeCurrent() - lastTradeTime) / 60);
      if(cooldownRemain > 0)
         UpdateText(panelPrefix + "Duration", 
                   StringFormat("Cooldown: %d min remaining", cooldownRemain), clrYellow);
      else
         UpdateText(panelPrefix + "Duration", "Ready to Trade", clrLimeGreen);
   }
}

//+------------------------------------------------------------------+
//| Create rectangle object                                            |
//+------------------------------------------------------------------+
void CreateRectangle(string name, int x, int y, int width, int height, 
                     color bgColor, int borderType, color borderColor)
{
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, borderType);
   ObjectSetInteger(0, name, OBJPROP_COLOR, borderColor);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

//+------------------------------------------------------------------+
//| Create text object                                                 |
//+------------------------------------------------------------------+
void CreateText(string name, int x, int y, string text, int fontSize, 
                string font, color textColor)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1002);
}

//+------------------------------------------------------------------+
//| Update text object                                                 |
//+------------------------------------------------------------------+
void UpdateText(string name, string text, color textColor = clrNONE)
{
   if(ObjectFind(0, name) >= 0)
   {
      ObjectSetString(0, name, OBJPROP_TEXT, text);
      if(textColor != clrNONE)
         ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   }
}

//+------------------------------------------------------------------+
//| Remove statistics panel                                            |
//+------------------------------------------------------------------+
void RemoveStatsPanel()
{
   ObjectsDeleteAll(0, panelPrefix);
   ChartRedraw();
}

//+------------------------------------------------------------------+
