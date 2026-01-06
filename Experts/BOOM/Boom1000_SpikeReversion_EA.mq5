//+------------------------------------------------------------------+
//|                                  Boom1000_SpikeReversion_EA.mq5  |
//|                                    Copyright 2026, TORAMA CAPITAL |
//|                                          https://torama.money      |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.00"
#property description "Boom 1000 Spike Reversion EA"
#property description "Detects boom spikes and trades mean reversion"
#property description "Contact: ea@torama.money"

//--- Input Parameters
input group "===== SPIKE DETECTION ====="
input double   SpikeMultiplier = 5.0;           // Spike Detection Multiplier (x average range)
input int      LookbackCandles = 20;            // Candles for Average Range Calculation
input int      MinCandlesBetweenSpikes = 3;     // Minimum Candles Between Spikes

input group "===== ENTRY SETTINGS ====="
input int      ConfirmationCandles = 1;         // Bearish Candles After Spike for Entry
input bool     UseSpreadFilter = true;          // Enable Spread Filter
input int      MaxSpreadPoints = 50;            // Maximum Spread (points)

input group "===== TAKE PROFIT STRATEGY ====="
enum TP_MODE {
   TP_FIXED_PIPS,      // Fixed Pips
   TP_DYNAMIC_SPIKE,   // Dynamic (Based on Spike Size)
   TP_TIME_BASED,      // Time-Based (N Candles)
   TP_PARTIAL          // Partial TP (50% at 2 candles, rest at target)
};
input TP_MODE  TakeProfitMode = TP_PARTIAL;     // Take Profit Mode
input int      FixedTP_Pips = 100;              // Fixed TP (pips)
input double   DynamicTP_Ratio = 0.7;           // Dynamic TP Ratio (% of spike size)
input int      TimeBased_Candles = 3;           // Time-Based TP (candles)
input int      PartialTP_Candles = 2;           // Candles for Partial TP (50%)

input group "===== STOP LOSS & PROTECTION ====="
input int      StopLoss_Buffer = 20;            // SL Buffer Above Spike (pips)
input bool     UseBreakEven = true;             // Enable Break-Even
input int      BreakEven_Candles = 1;           // Move to BE After N Candles in Profit
input bool     UseTrailingStop = true;          // Enable Trailing Stop
input int      TrailingStart_Pips = 50;         // Start Trailing at (pips)
input int      TrailingStep_Pips = 30;          // Trailing Step (pips)

input group "===== RISK MANAGEMENT ====="
input double   RiskPercent = 1.0;               // Risk Per Trade (%)
input int      MaxConcurrentTrades = 2;         // Maximum Concurrent Positions
input int      MaxDailyTrades = 15;             // Maximum Daily Trades
input double   MaxDailyDrawdownPercent = 8.0;   // Maximum Daily Drawdown (%)
input int      CooldownSeconds = 120;           // Cooldown Between Trades (seconds)

input group "===== TIME FILTERS ====="
input bool     UseTimeFilter = false;           // Enable Time Filter
input int      StartHour = 0;                   // Trading Start Hour
input int      EndHour = 23;                    // Trading End Hour

input group "===== ADVANCED SETTINGS ====="
input int      MagicNumber = 100100;            // Magic Number
input string   TradeComment = "TORAMA_B1K";     // Trade Comment
input bool     ShowPanel = true;                // Show Info Panel

//--- Global Variables
datetime lastSpikeTime = 0;
datetime lastTradeTime = 0;
int dailyTradeCount = 0;
datetime lastDayReset = 0;
double dailyStartBalance = 0;
double lastSpikeHigh = 0;
double lastSpikeSize = 0;
bool spikeDetected = false;
int candlesSinceSpike = 0;
int tradesSinceStart = 0;
double totalProfitToday = 0;

// Statistics
int totalTrades = 0;
int winningTrades = 0;
int losingTrades = 0;
double totalProfit = 0;
double totalLoss = 0;

// Panel objects
string panelPrefix = "TORAMA_Panel_";

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // Reset daily counters
   dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastDayReset = TimeCurrent();
   
   // Create info panel
   if(ShowPanel)
      CreateInfoPanel();
   
   Print("========================================");
   Print("TORAMA CAPITAL - Boom 1000 Spike Reversion EA");
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
   // Remove panel objects
   RemoveInfoPanel();
   
   Print("EA Stopped. Total Trades: ", totalTrades, " | Win Rate: ", 
         (totalTrades > 0 ? DoubleToString((double)winningTrades/totalTrades*100, 1) : "0"), "%");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for new day and reset counters
   CheckDailyReset();
   
   // Update info panel
   if(ShowPanel)
      UpdateInfoPanel();
   
   // Check if we can trade
   if(!CanTrade())
      return;
   
   // Check for spike detection
   DetectSpike();
   
   // Manage open positions
   ManagePositions();
   
   // Check for entry signal after spike
   if(spikeDetected && candlesSinceSpike >= ConfirmationCandles)
   {
      if(IsNewBar())
      {
         // Check if we should enter
         if(ValidateEntry())
         {
            OpenSellPosition();
         }
      }
   }
   
   // Update candles since spike
   if(spikeDetected && IsNewBar())
   {
      candlesSinceSpike++;
      
      // Reset spike detection after too many candles
      if(candlesSinceSpike > 10)
      {
         spikeDetected = false;
         candlesSinceSpike = 0;
      }
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
   
   // Check max concurrent trades
   if(CountOpenPositions() >= MaxConcurrentTrades)
      return false;
   
   // Check daily trade limit
   if(dailyTradeCount >= MaxDailyTrades)
      return false;
   
   // Check daily drawdown
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyDrawdown = ((dailyStartBalance - currentBalance) / dailyStartBalance) * 100;
   if(dailyDrawdown >= MaxDailyDrawdownPercent)
   {
      Print("Daily drawdown limit reached: ", DoubleToString(dailyDrawdown, 2), "%");
      return false;
   }
   
   // Check cooldown period
   if((TimeCurrent() - lastTradeTime) < CooldownSeconds)
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Detect boom spike                                                  |
//+------------------------------------------------------------------+
void DetectSpike()
{
   if(Bars(_Symbol, PERIOD_CURRENT) < LookbackCandles + 2)
      return;
   
   // Get current candle data
   double high[], low[], close[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);
   
   if(CopyHigh(_Symbol, PERIOD_CURRENT, 0, LookbackCandles + 2, high) <= 0)
      return;
   if(CopyLow(_Symbol, PERIOD_CURRENT, 0, LookbackCandles + 2, low) <= 0)
      return;
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, LookbackCandles + 2, close) <= 0)
      return;
   
   // Calculate average candle range
   double totalRange = 0;
   for(int i = 2; i < LookbackCandles + 2; i++)
   {
      totalRange += (high[i] - low[i]);
   }
   double avgRange = totalRange / LookbackCandles;
   
   // Check if last completed candle is a spike
   double lastCandleRange = high[1] - low[1];
   
   // Check if it's a spike and enough time has passed since last spike
   if(lastCandleRange >= avgRange * SpikeMultiplier)
   {
      datetime currentCandleTime = iTime(_Symbol, PERIOD_CURRENT, 1);
      
      // Check minimum candles between spikes
      if(lastSpikeTime > 0)
      {
         int barsSinceLastSpike = Bars(_Symbol, PERIOD_CURRENT, lastSpikeTime, currentCandleTime);
         if(barsSinceLastSpike < MinCandlesBetweenSpikes)
            return;
      }
      
      // Spike detected!
      if(!spikeDetected || currentCandleTime != lastSpikeTime)
      {
         spikeDetected = true;
         lastSpikeTime = currentCandleTime;
         lastSpikeHigh = high[1];
         lastSpikeSize = lastCandleRange;
         candlesSinceSpike = 0;
         
         Print(">>> SPIKE DETECTED at ", TimeToString(currentCandleTime), 
               " | Size: ", DoubleToString(lastSpikeSize/_Point, 0), " points",
               " | High: ", DoubleToString(lastSpikeHigh, _Digits));
      }
   }
}

//+------------------------------------------------------------------+
//| Validate entry conditions                                          |
//+------------------------------------------------------------------+
bool ValidateEntry()
{
   // Check spread filter
   if(UseSpreadFilter)
   {
      long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(spread > MaxSpreadPoints)
      {
         Print("Spread too high: ", spread, " points");
         return false;
      }
   }
   
   // Verify price is still below spike high (reversion in progress)
   double currentClose = iClose(_Symbol, PERIOD_CURRENT, 0);
   if(currentClose >= lastSpikeHigh)
   {
      Print("Price above spike high, no entry");
      return false;
   }
   
   // Check that we have confirmation candles showing bearish movement
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, ConfirmationCandles + 1, close) <= 0)
      return false;
   
   // Verify downward movement
   for(int i = 0; i < ConfirmationCandles; i++)
   {
      if(close[i] >= close[i+1])
      {
         Print("Confirmation candles not bearish");
         return false;
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Open sell position                                                 |
//+------------------------------------------------------------------+
void OpenSellPosition()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Calculate stop loss
   double sl = lastSpikeHigh + (StopLoss_Buffer * _Point);
   
   // Calculate take profit based on mode
   double tp = 0;
   switch(TakeProfitMode)
   {
      case TP_FIXED_PIPS:
         tp = bid - (FixedTP_Pips * _Point);
         break;
         
      case TP_DYNAMIC_SPIKE:
         {
            double tpDistance = lastSpikeSize * DynamicTP_Ratio;
            tp = lastSpikeHigh - tpDistance;
         }
         break;
         
      case TP_TIME_BASED:
         // No TP set, will manage in ManagePositions
         tp = 0;
         break;
         
      case TP_PARTIAL:
         // Initial TP for full position
         tp = bid - (FixedTP_Pips * _Point);
         break;
   }
   
   // Calculate lot size based on risk
   double slDistance = MathAbs(sl - bid);
   double lotSize = CalculateLotSize(slDistance);
   
   // Normalize values
   sl = NormalizeDouble(sl, _Digits);
   tp = (tp > 0) ? NormalizeDouble(tp, _Digits) : 0;
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
   request.tp = tp;
   request.deviation = 10;
   request.magic = MagicNumber;
   request.comment = TradeComment;
   
   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED)
      {
         Print("✓ SELL Order Opened: Ticket #", result.order,
               " | Lot: ", lotSize,
               " | Price: ", bid,
               " | SL: ", sl,
               " | TP: ", (tp > 0 ? DoubleToString(tp, _Digits) : "None"));
         
         lastTradeTime = TimeCurrent();
         dailyTradeCount++;
         totalTrades++;
         tradesSinceStart++;
         spikeDetected = false; // Reset spike detection after entry
         
         return;
      }
   }
   
   Print("✗ Order Failed: ", result.retcode, " - ", result.comment);
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
   
   double slPoints = slDistance / _Point;
   double lotSize = (riskAmount) / (slPoints * tickValue / tickSize);
   
   // Get lot constraints
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   // Normalize to lot step
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   
   // Ensure within limits
   if(lotSize < minLot) lotSize = minLot;
   if(lotSize > maxLot) lotSize = maxLot;
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Manage open positions                                              |
//+------------------------------------------------------------------+
void ManagePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      
      double posOpenPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
      double posProfit = PositionGetDouble(POSITION_PROFIT);
      double posSL = PositionGetDouble(POSITION_SL);
      double posTP = PositionGetDouble(POSITION_TP);
      double posVolume = PositionGetDouble(POSITION_VOLUME);
      datetime posOpenTime = (datetime)PositionGetInteger(POSITION_TIME);
      
      // Calculate candles since position opened
      int barsSinceOpen = Bars(_Symbol, PERIOD_CURRENT, posOpenTime, TimeCurrent());
      
      // Time-based TP
      if(TakeProfitMode == TP_TIME_BASED && barsSinceOpen >= TimeBased_Candles)
      {
         if(posProfit > 0)
         {
            ClosePosition(ticket, "Time-based TP");
            continue;
         }
      }
      
      // Partial TP
      if(TakeProfitMode == TP_PARTIAL && barsSinceOpen >= PartialTP_Candles)
      {
         // Check if we haven't already taken partial
         if(posVolume > SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
         {
            double partialVolume = NormalizeDouble(posVolume * 0.5, 2);
            if(partialVolume >= SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN))
            {
               ClosePartialPosition(ticket, partialVolume, "Partial TP (50%)");
            }
         }
      }
      
      // Break-even stop
      if(UseBreakEven && barsSinceOpen >= BreakEven_Candles && posProfit > 0)
      {
         if(posSL > posOpenPrice || posSL == 0) // Not yet at break-even
         {
            ModifyStopLoss(ticket, posOpenPrice, "Break-Even");
         }
      }
      
      // Trailing stop
      if(UseTrailingStop)
      {
         double profitPoints = (posOpenPrice - currentPrice) / _Point;
         
         if(profitPoints >= TrailingStart_Pips)
         {
            double newSL = currentPrice + (TrailingStep_Pips * _Point);
            newSL = NormalizeDouble(newSL, _Digits);
            
            if(newSL < posSL || posSL == 0)
            {
               ModifyStopLoss(ticket, newSL, "Trailing Stop");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close position                                                     |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket, string reason)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = PositionGetString(POSITION_SYMBOL);
   request.volume = PositionGetDouble(POSITION_VOLUME);
   request.type = ORDER_TYPE_BUY; // Close sell with buy
   request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   request.deviation = 10;
   request.magic = MagicNumber;
   
   double profit = PositionGetDouble(POSITION_PROFIT);
   
   if(OrderSend(request, result))
   {
      Print("✓ Position Closed: Ticket #", ticket, " | Reason: ", reason, " | Profit: $", DoubleToString(profit, 2));
      
      // Update statistics
      if(profit > 0)
      {
         winningTrades++;
         totalProfit += profit;
      }
      else
      {
         losingTrades++;
         totalLoss += MathAbs(profit);
      }
      totalProfitToday += profit;
   }
}

//+------------------------------------------------------------------+
//| Close partial position                                             |
//+------------------------------------------------------------------+
void ClosePartialPosition(ulong ticket, double volume, string reason)
{
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.position = ticket;
   request.symbol = PositionGetString(POSITION_SYMBOL);
   request.volume = volume;
   request.type = ORDER_TYPE_BUY;
   request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   request.deviation = 10;
   request.magic = MagicNumber;
   
   if(OrderSend(request, result))
   {
      Print("✓ Partial Close: Ticket #", ticket, " | Volume: ", volume, " | Reason: ", reason);
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
//| Count open positions                                               |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Check if new bar formed                                            |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   
   if(currentBar != lastBar)
   {
      lastBar = currentBar;
      return true;
   }
   return false;
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
      Print("Yesterday's P&L: $", DoubleToString(totalProfitToday, 2));
      
      dailyTradeCount = 0;
      dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      totalProfitToday = 0;
      lastDayReset = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Create information panel                                           |
//+------------------------------------------------------------------+
void CreateInfoPanel()
{
   int xPos = 20;
   int yPos = 25;
   int lineHeight = 18;
   
   // Background
   CreateLabel(panelPrefix + "BG", xPos-5, yPos-5, 350, 420, clrNONE, C'20,20,35', 1);
   
   // Header
   CreateLabel(panelPrefix + "Header", xPos, yPos, 340, 25, clrWhite, C'30,144,255', 1, 
               "TORAMA CAPITAL - BOOM 1000", 10, "Arial Black");
   yPos += 30;
   
   // EA Info
   CreateLabel(panelPrefix + "EA", xPos, yPos, 340, 20, C'200,200,200', C'20,20,35', 0, 
               "Spike Reversion EA v1.00", 9, "Arial");
   yPos += lineHeight + 8;
   
   // Spike Status Section
   CreateLabel(panelPrefix + "SpikeHeader", xPos, yPos, 340, 18, C'30,144,255', C'20,20,35', 0,
               "━━━ SPIKE STATUS ━━━", 8, "Arial Bold");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "SpikeStatus", xPos, yPos, 340, 16, clrWhite, C'20,20,35', 0, 
               "Status: Monitoring...", 8, "Consolas");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "LastSpike", xPos, yPos, 340, 16, C'180,180,180', C'20,20,35', 0,
               "Last Spike: None", 8, "Consolas");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "SpikeSize", xPos, yPos, 340, 16, C'180,180,180', C'20,20,35', 0,
               "Spike Size: 0 pts", 8, "Consolas");
   yPos += lineHeight + 5;
   
   // Account Section
   CreateLabel(panelPrefix + "AccHeader", xPos, yPos, 340, 18, C'30,144,255', C'20,20,35', 0,
               "━━━ ACCOUNT STATUS ━━━", 8, "Arial Bold");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "Balance", xPos, yPos, 340, 16, clrLimeGreen, C'20,20,35', 0,
               "Balance: $0", 8, "Consolas");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "Equity", xPos, yPos, 340, 16, C'180,180,180', C'20,20,35', 0,
               "Equity: $0", 8, "Consolas");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "DailyPL", xPos, yPos, 340, 16, clrWhite, C'20,20,35', 0,
               "Today P&L: $0.00", 8, "Consolas");
   yPos += lineHeight + 5;
   
   // Trading Section
   CreateLabel(panelPrefix + "TradeHeader", xPos, yPos, 340, 18, C'30,144,255', C'20,20,35', 0,
               "━━━ TRADING STATUS ━━━", 8, "Arial Bold");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "OpenPos", xPos, yPos, 340, 16, clrWhite, C'20,20,35', 0,
               "Open Positions: 0/2", 8, "Consolas");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "DailyTrades", xPos, yPos, 340, 16, C'180,180,180', C'20,20,35', 0,
               "Daily Trades: 0/15", 8, "Consolas");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "Cooldown", xPos, yPos, 340, 16, C'180,180,180', C'20,20,35', 0,
               "Next Trade: Ready", 8, "Consolas");
   yPos += lineHeight + 5;
   
   // Statistics Section
   CreateLabel(panelPrefix + "StatsHeader", xPos, yPos, 340, 18, C'30,144,255', C'20,20,35', 0,
               "━━━ STATISTICS ━━━", 8, "Arial Bold");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "TotalTrades", xPos, yPos, 340, 16, clrWhite, C'20,20,35', 0,
               "Total Trades: 0", 8, "Consolas");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "WinRate", xPos, yPos, 340, 16, C'100,200,100', C'20,20,35', 0,
               "Win Rate: 0%", 8, "Consolas");
   yPos += lineHeight;
   
   CreateLabel(panelPrefix + "ProfitFactor", xPos, yPos, 340, 16, C'180,180,180', C'20,20,35', 0,
               "Profit Factor: 0.00", 8, "Consolas");
   yPos += lineHeight + 8;
   
   // Footer
   CreateLabel(panelPrefix + "Footer", xPos, yPos, 340, 16, C'100,100,120', C'20,20,35', 0,
               "ea@torama.money | torama.money", 7, "Arial");
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Update information panel                                           |
//+------------------------------------------------------------------+
void UpdateInfoPanel()
{
   // Spike Status
   string spikeStatusText = spikeDetected ? 
      "Status: SPIKE DETECTED! (" + IntegerToString(candlesSinceSpike) + " candles)" : 
      "Status: Monitoring...";
   color spikeColor = spikeDetected ? clrOrange : clrWhite;
   UpdateLabelText(panelPrefix + "SpikeStatus", spikeStatusText, spikeColor);
   
   if(lastSpikeTime > 0)
   {
      UpdateLabelText(panelPrefix + "LastSpike", "Last Spike: " + TimeToString(lastSpikeTime, TIME_MINUTES));
      UpdateLabelText(panelPrefix + "SpikeSize", "Spike Size: " + 
         DoubleToString(lastSpikeSize/_Point, 0) + " pts");
   }
   
   // Account Status
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   UpdateLabelText(panelPrefix + "Balance", "Balance: $" + DoubleToString(balance, 2), clrLimeGreen);
   UpdateLabelText(panelPrefix + "Equity", "Equity: $" + DoubleToString(equity, 2));
   
   color plColor = totalProfitToday >= 0 ? clrLimeGreen : clrOrangeRed;
   UpdateLabelText(panelPrefix + "DailyPL", "Today P&L: $" + DoubleToString(totalProfitToday, 2), plColor);
   
   // Trading Status
   int openPos = CountOpenPositions();
   UpdateLabelText(panelPrefix + "OpenPos", "Open Positions: " + IntegerToString(openPos) + 
      "/" + IntegerToString(MaxConcurrentTrades));
   UpdateLabelText(panelPrefix + "DailyTrades", "Daily Trades: " + IntegerToString(dailyTradeCount) + 
      "/" + IntegerToString(MaxDailyTrades));
   
   int cooldownRemaining = CooldownSeconds - (int)(TimeCurrent() - lastTradeTime);
   if(cooldownRemaining > 0)
      UpdateLabelText(panelPrefix + "Cooldown", "Next Trade: " + IntegerToString(cooldownRemaining) + "s", clrYellow);
   else
      UpdateLabelText(panelPrefix + "Cooldown", "Next Trade: Ready", clrLimeGreen);
   
   // Statistics
   UpdateLabelText(panelPrefix + "TotalTrades", "Total Trades: " + IntegerToString(totalTrades));
   
   double winRate = totalTrades > 0 ? ((double)winningTrades / totalTrades * 100) : 0;
   color wrColor = winRate >= 50 ? clrLimeGreen : (winRate >= 40 ? clrYellow : clrOrangeRed);
   UpdateLabelText(panelPrefix + "WinRate", "Win Rate: " + DoubleToString(winRate, 1) + "%", wrColor);
   
   double profitFactor = totalLoss > 0 ? (totalProfit / totalLoss) : 0;
   UpdateLabelText(panelPrefix + "ProfitFactor", "Profit Factor: " + DoubleToString(profitFactor, 2));
}

//+------------------------------------------------------------------+
//| Create label object                                                |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, int width, int height, color textColor, 
                 color bgColor, int borderType, string text="", int fontSize=8, string font="Arial")
{
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, borderType);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   
   if(text != "")
   {
      string textName = name + "_txt";
      ObjectCreate(0, textName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, textName, OBJPROP_XDISTANCE, x + 5);
      ObjectSetInteger(0, textName, OBJPROP_YDISTANCE, y + 2);
      ObjectSetInteger(0, textName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, textName, OBJPROP_COLOR, textColor);
      ObjectSetInteger(0, textName, OBJPROP_FONTSIZE, fontSize);
      ObjectSetString(0, textName, OBJPROP_FONT, font);
      ObjectSetString(0, textName, OBJPROP_TEXT, text);
      ObjectSetInteger(0, textName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, textName, OBJPROP_SELECTABLE, false);
   }
}

//+------------------------------------------------------------------+
//| Update label text                                                  |
//+------------------------------------------------------------------+
void UpdateLabelText(string name, string text, color textColor = clrNONE)
{
   string textName = name + "_txt";
   if(ObjectFind(0, textName) >= 0)
   {
      ObjectSetString(0, textName, OBJPROP_TEXT, text);
      if(textColor != clrNONE)
         ObjectSetInteger(0, textName, OBJPROP_COLOR, textColor);
   }
}

//+------------------------------------------------------------------+
//| Remove information panel                                           |
//+------------------------------------------------------------------+
void RemoveInfoPanel()
{
   ObjectsDeleteAll(0, panelPrefix);
   ChartRedraw();
}

//+------------------------------------------------------------------+
