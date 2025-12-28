//+------------------------------------------------------------------+
//|                                     Enhanced CandlePatternEA.mq5 |
//|                                    Educational Trading EA       |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Educational EA 2025"
#property version   "2.11"
#property description "Enhanced candle pattern EA with manual controls and dollar TP"
#property description "DEMO ACCOUNTS ONLY - Educational use"

#include <Trade/Trade.mqh>

enum ENUM_TRADE_DIRECTION
{
   TRADE_BOTH = 0,
   TRADE_BUY_ONLY = 1,
   TRADE_SELL_ONLY = 2
};

input ENUM_TRADE_DIRECTION TradeDirection = TRADE_BOTH;
input double   LotSize = 0.1;
input bool     UseAutoLotSizing = false;  // Enable automatic lot sizing based on equity
input double   AutoLotPer1000 = 0.01;    // Lot size per $1000 of equity
input int      StopLoss = 0;
input double   TakeProfitDollars = 50.0;  // Take profit in dollar value per trade
input double   GlobalProfitTarget = 100.0; // Global profit target - close all profitable when reached
input bool     EnableConsecutiveCandleExit = true;  // Enable exit after consecutive opposite candles
input int      ConsecutiveCandleCount = 3;          // Number of consecutive candles for exit signal
input int      TradesPerSignal = 1;       // Number of trades to open at once
input int      MaxPositions = 5;         // Maximum total positions per direction
input int      MagicNumber = 123456;
input string   TradeComment = "CandleEA";
input bool     ShowButtons = true;
input int      MaxRetries = 3;
input int      RetryDelay = 100;

CTrade trade;
datetime lastBarTime = 0;
int consecutiveBullish = 0;
int consecutiveBearish = 0;
bool tradingEnabled = true;
bool isInitialized = false;
int actualTradesPerSignal = 1;  // Working copy of TradesPerSignal

#define BTN_TOGGLE_TRADING "btnToggleTrading"
#define BTN_CLOSE_PROFITABLE "btnCloseProfitable"

void UpdateDisplay();
bool CreateButtons();
void DeleteButtons();
void OnNewBar();
bool IsMarketOpen();
void CountConsecutiveCandles();
void CheckEntrySignals();
void CheckExitSignals();
void OpenBuyPosition();
void OpenSellPosition();
void OpenMultipleBuyPositions(int numberOfTrades);
void OpenMultipleSellPositions(int numberOfTrades);
double NormalizeLotSize(double lots);
double CalculateAutoLotSize();
double GetEffectiveLotSize();
double CalculateTakeProfitPoints(double lotSize, double dollarValue);
int CountPositions(ENUM_POSITION_TYPE posType);
void ClosePositionsByType(ENUM_POSITION_TYPE posType);
void CloseAllPositions();
void CloseProfitablePositions();
void CloseProfitablePositionsByType(ENUM_POSITION_TYPE posType);
double CalculateTotalProfit();
int CountProfitablePositions();
int CountLosingPositions();
void ToggleTrading();
void CheckGlobalProfitTarget();

int OnInit()
{
   if(LotSize <= 0)
   {
      Print("ERROR: Invalid lot size");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(UseAutoLotSizing && AutoLotPer1000 <= 0)
   {
      Print("ERROR: AutoLotPer1000 must be greater than 0 when using auto lot sizing");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(TakeProfitDollars < 0)
   {
      Print("ERROR: Take profit dollars cannot be negative");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(GlobalProfitTarget <= 0)
   {
      Print("ERROR: Global profit target must be greater than 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(EnableConsecutiveCandleExit && ConsecutiveCandleCount <= 0)
   {
      Print("ERROR: ConsecutiveCandleCount must be greater than 0 when consecutive candle exit is enabled");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(TradesPerSignal <= 0)
   {
      Print("ERROR: Invalid TradesPerSignal. Must be greater than 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   if(MaxPositions <= 0)
   {
      Print("ERROR: Invalid MaxPositions");
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   // Set working copy and validate
   actualTradesPerSignal = TradesPerSignal;
   if(actualTradesPerSignal > MaxPositions)
   {
      Print("WARNING: TradesPerSignal (", TradesPerSignal, ") is greater than MaxPositions (", MaxPositions, ")");
      Print("Adjusting TradesPerSignal to MaxPositions for safety");
      actualTradesPerSignal = MaxPositions;
   }
   
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("ERROR: Trading not allowed");
      return(INIT_FAILED);
   }
   
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      Print("ERROR: EA trading not allowed");
      return(INIT_FAILED);
   }
   
   if(!SymbolSelect(_Symbol, true))
   {
      Print("ERROR: Symbol not available");
      return(INIT_FAILED);
   }
   
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetAsyncMode(false);
   
   datetime tempTime = iTime(_Symbol, PERIOD_M1, 0);
   if(tempTime <= 0)
   {
      Print("ERROR: Cannot get chart data");
      return(INIT_FAILED);
   }
   lastBarTime = tempTime;
   
   CountConsecutiveCandles();
   
   if(ShowButtons)
   {
      CreateButtons();
   }
   
   isInitialized = true;
   
   Print("Enhanced CandlePatternEA v2.11 initialized");
   
   if(UseAutoLotSizing)
   {
      double currentLot = GetEffectiveLotSize();
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      Print("Auto Lot Sizing ENABLED: $", equity, " equity = ", currentLot, " lot (", AutoLotPer1000, " per $1000)");
   }
   else
   {
      Print("Fixed Lot Size: ", LotSize);
   }
   
   Print("Trades Per Signal: ", actualTradesPerSignal, " | Max Positions: ", MaxPositions, " per direction");
   Print("Take Profit: $", TakeProfitDollars, " per trade");
   Print("Global Profit Target: $", GlobalProfitTarget, " (closes all profitable)");
   
   if(EnableConsecutiveCandleExit)
   {
      Print("Consecutive Candle Exit: ENABLED (", ConsecutiveCandleCount, " candles)");
   }
   else
   {
      Print("Consecutive Candle Exit: DISABLED");
   }
   
   Print("*** TRADES AT CANDLE CLOSE ***");
   Print("*** BEARISH = ", actualTradesPerSignal, " BUY trades | BULLISH = ", actualTradesPerSignal, " SELL trades ***");
   
   if(EnableConsecutiveCandleExit)
   {
      Print("*** CLOSES PROFITABLE ONLY AFTER ", ConsecutiveCandleCount, " CONSECUTIVE OPPOSITE CANDLES ***");
   }
   else
   {
      Print("*** CONSECUTIVE CANDLE EXIT DISABLED - RELIES ON TP/GLOBAL TARGET ***");
   }
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   DeleteButtons();
   isInitialized = false;
   Print("EA deinitialized");
}

void OnTick()
{
   if(!isInitialized) return;
   
   // Check global profit target on every tick
   CheckGlobalProfitTarget();
   
   datetime currentCandle = iTime(_Symbol, PERIOD_M1, 0);
   
   if(currentCandle != lastBarTime && currentCandle > 0)
   {
      if(lastBarTime > 0)
      {
         Print("*** NEW CANDLE *** Time: ", TimeToString(currentCandle, TIME_DATE|TIME_MINUTES));
         OnNewBar();
      }
      lastBarTime = currentCandle;
   }
   
   UpdateDisplay();
}

void OnChartEvent(const int id, const long& lparam, const double& dparam, const string& sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == BTN_TOGGLE_TRADING)
      {
         ToggleTrading();
         ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_STATE, false);
      }
      else if(sparam == BTN_CLOSE_PROFITABLE)
      {
         CloseProfitablePositions();
         ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_STATE, false);
      }
      ChartRedraw();
   }
}

void OnNewBar()
{
   Print("=== PROCESSING NEW BAR ===");
   
   CountConsecutiveCandles();
   
   if(!tradingEnabled)
   {
      Print("Trading DISABLED");
      return;
   }
   
   if(!IsMarketOpen())
   {
      Print("Market CLOSED");
      return;
   }
   
   CheckEntrySignals();
   CheckExitSignals();
   Print("=== BAR COMPLETE ===");
}

bool IsMarketOpen()
{
   return true;
}

void CountConsecutiveCandles()
{
   double open = iOpen(_Symbol, PERIOD_M1, 1);
   double close = iClose(_Symbol, PERIOD_M1, 1);
   
   if(open <= 0 || close <= 0)
   {
      Print("ERROR: Invalid candle data");
      return;
   }
   
   bool isBullish = (close > open);
   bool isBearish = (close < open);
   
   if(isBullish)
   {
      consecutiveBullish++;
      consecutiveBearish = 0;
   }
   else if(isBearish)
   {
      consecutiveBearish++;
      consecutiveBullish = 0;
   }
   
   Print("Consecutive - Bullish: ", consecutiveBullish, " Bearish: ", consecutiveBearish);
}

void CheckEntrySignals()
{
   double open = iOpen(_Symbol, PERIOD_M1, 1);
   double close = iClose(_Symbol, PERIOD_M1, 1);
   
   if(open <= 0 || close <= 0)
   {
      Print("ERROR: Invalid price data");
      return;
   }
   
   bool isBearish = (close < open);
   bool isBullish = (close > open);
   
   Print("Candle: Open=", open, " Close=", close, " Type=", (isBullish ? "BULLISH" : (isBearish ? "BEARISH" : "DOJI")));
   
   if(isBearish && (TradeDirection == TRADE_BOTH || TradeDirection == TRADE_BUY_ONLY))
   {
      int currentBuyPositions = CountPositions(POSITION_TYPE_BUY);
      int remainingSlots = MaxPositions - currentBuyPositions;
      int tradesToOpen = MathMin(actualTradesPerSignal, remainingSlots);
      
      Print("*** BEARISH CANDLE - BUY SIGNAL ***");
      Print("Current BUY positions: ", currentBuyPositions, " / Max: ", MaxPositions);
      Print("Remaining slots: ", remainingSlots, " | Will open: ", tradesToOpen, " trades");
      
      if(tradesToOpen > 0)
      {
         Print(">>> OPENING ", tradesToOpen, " BUY POSITIONS <<<");
         OpenMultipleBuyPositions(tradesToOpen);
      }
      else
      {
         Print("*** BUY SIGNAL IGNORED: Max positions reached ***");
      }
   }
   
   if(isBullish && (TradeDirection == TRADE_BOTH || TradeDirection == TRADE_SELL_ONLY))
   {
      int currentSellPositions = CountPositions(POSITION_TYPE_SELL);
      int remainingSlots = MaxPositions - currentSellPositions;
      int tradesToOpen = MathMin(actualTradesPerSignal, remainingSlots);
      
      Print("*** BULLISH CANDLE - SELL SIGNAL ***");
      Print("Current SELL positions: ", currentSellPositions, " / Max: ", MaxPositions);
      Print("Remaining slots: ", remainingSlots, " | Will open: ", tradesToOpen, " trades");
      
      if(tradesToOpen > 0)
      {
         Print(">>> OPENING ", tradesToOpen, " SELL POSITIONS <<<");
         OpenMultipleSellPositions(tradesToOpen);
      }
      else
      {
         Print("*** SELL SIGNAL IGNORED: Max positions reached ***");
      }
   }
}

void CheckExitSignals()
{
   if(!EnableConsecutiveCandleExit) return; // Skip if disabled
   
   if(consecutiveBullish >= ConsecutiveCandleCount && CountPositions(POSITION_TYPE_BUY) > 0)
   {
      Print("[EXIT] ", ConsecutiveCandleCount, "+ bullish candles (", consecutiveBullish, ") - closing PROFITABLE BUY only");
      CloseProfitablePositionsByType(POSITION_TYPE_BUY);
   }
   
   if(consecutiveBearish >= ConsecutiveCandleCount && CountPositions(POSITION_TYPE_SELL) > 0)
   {
      Print("[EXIT] ", ConsecutiveCandleCount, "+ bearish candles (", consecutiveBearish, ") - closing PROFITABLE SELL only");
      CloseProfitablePositionsByType(POSITION_TYPE_SELL);
   }
}

// NEW FUNCTION: Calculate TP points from dollar value
double CalculateTakeProfitPoints(double lotSize, double dollarValue)
{
   if(dollarValue <= 0 || lotSize <= 0) return 0;
   
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   if(tickValue <= 0 || tickSize <= 0 || pointValue <= 0)
   {
      Print("ERROR: Invalid symbol parameters for TP calculation");
      return 0;
   }
   
   // Calculate value per point for this lot size
   double valuePerPoint = (tickValue / tickSize) * pointValue * lotSize;
   
   if(valuePerPoint <= 0)
   {
      Print("ERROR: Invalid value per point calculation");
      return 0;
   }
   
   // Calculate points needed for desired dollar profit
   double pointsForDollarValue = dollarValue / valuePerPoint;
   
   Print("TP Calculation: $", dollarValue, " = ", pointsForDollarValue, " points (Lot: ", lotSize, ")");
   
   return pointsForDollarValue;
}

void OpenMultipleBuyPositions(int numberOfTrades)
{
   int successCount = 0;
   int failCount = 0;
   
   for(int trade_num = 1; trade_num <= numberOfTrades; trade_num++)
   {
      Print("Opening BUY trade ", trade_num, " of ", numberOfTrades);
      
      bool success = false;
      for(int attempt = 1; attempt <= MaxRetries; attempt++)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         
         if(ask <= 0)
         {
            Print("ERROR: Invalid ask price for trade ", trade_num);
            break;
         }
         
         double normalizedLot = GetEffectiveLotSize();
         if(normalizedLot <= 0)
         {
            Print("ERROR: Invalid effective lot size for trade ", trade_num);
            break;
         }
         
         double sl = (StopLoss > 0) ? ask - StopLoss * _Point : 0;
         double tp = 0;
         
         // Calculate TP from dollar value
         if(TakeProfitDollars > 0)
         {
            double tpPoints = CalculateTakeProfitPoints(normalizedLot, TakeProfitDollars);
            if(tpPoints > 0)
            {
               tp = ask + tpPoints * _Point;
               Print("BUY TP set at: ", tp, " (", tpPoints, " points for $", TakeProfitDollars, ")");
            }
         }
         
         if(trade.Buy(normalizedLot, _Symbol, ask, sl, tp, TradeComment))
         {
            Print("[SUCCESS] BUY trade ", trade_num, " opened! Ticket: ", trade.ResultOrder());
            if(tp > 0) Print("Take Profit: $", TakeProfitDollars, " at price ", tp);
            successCount++;
            success = true;
            break;
         }
         else
         {
            Print("[ATTEMPT ", attempt, "] BUY trade ", trade_num, " failed - Error: ", trade.ResultRetcode());
            if(attempt < MaxRetries) Sleep(RetryDelay);
         }
      }
      
      if(!success)
      {
         Print("[FAILED] Could not open BUY trade ", trade_num, " after ", MaxRetries, " attempts");
         failCount++;
      }
      
      // Small delay between trades to avoid server overload
      if(trade_num < numberOfTrades) Sleep(50);
   }
   
   Print("=== MULTIPLE BUY SUMMARY ===");
   Print("Requested: ", numberOfTrades, " | Successful: ", successCount, " | Failed: ", failCount);
   Print("==========================");
}

void OpenMultipleSellPositions(int numberOfTrades)
{
   int successCount = 0;
   int failCount = 0;
   
   for(int trade_num = 1; trade_num <= numberOfTrades; trade_num++)
   {
      Print("Opening SELL trade ", trade_num, " of ", numberOfTrades);
      
      bool success = false;
      for(int attempt = 1; attempt <= MaxRetries; attempt++)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         
         if(bid <= 0)
         {
            Print("ERROR: Invalid bid price for trade ", trade_num);
            break;
         }
         
         double normalizedLot = GetEffectiveLotSize();
         if(normalizedLot <= 0)
         {
            Print("ERROR: Invalid effective lot size for trade ", trade_num);
            break;
         }
         
         double sl = (StopLoss > 0) ? bid + StopLoss * _Point : 0;
         double tp = 0;
         
         // Calculate TP from dollar value
         if(TakeProfitDollars > 0)
         {
            double tpPoints = CalculateTakeProfitPoints(normalizedLot, TakeProfitDollars);
            if(tpPoints > 0)
            {
               tp = bid - tpPoints * _Point;
               Print("SELL TP set at: ", tp, " (", tpPoints, " points for $", TakeProfitDollars, ")");
            }
         }
         
         if(trade.Sell(normalizedLot, _Symbol, bid, sl, tp, TradeComment))
         {
            Print("[SUCCESS] SELL trade ", trade_num, " opened! Ticket: ", trade.ResultOrder());
            if(tp > 0) Print("Take Profit: $", TakeProfitDollars, " at price ", tp);
            successCount++;
            success = true;
            break;
         }
         else
         {
            Print("[ATTEMPT ", attempt, "] SELL trade ", trade_num, " failed - Error: ", trade.ResultRetcode());
            if(attempt < MaxRetries) Sleep(RetryDelay);
         }
      }
      
      if(!success)
      {
         Print("[FAILED] Could not open SELL trade ", trade_num, " after ", MaxRetries, " attempts");
         failCount++;
      }
      
      // Small delay between trades to avoid server overload
      if(trade_num < numberOfTrades) Sleep(50);
   }
   
   Print("=== MULTIPLE SELL SUMMARY ===");
   Print("Requested: ", numberOfTrades, " | Successful: ", successCount, " | Failed: ", failCount);
   Print("===========================");
}

double NormalizeLotSize(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   if(minLot <= 0 || maxLot <= 0 || stepLot <= 0)
   {
      Print("ERROR: Invalid symbol parameters");
      return 0;
   }
   
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   
   if(stepLot > 0)
      lots = MathRound(lots / stepLot) * stepLot;
   
   if(lots < minLot) lots = minLot;
   
   return lots;
}

double CalculateAutoLotSize()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(equity <= 0)
   {
      Print("ERROR: Invalid account equity for auto lot calculation");
      return LotSize; // Fallback to manual lot size
   }
   
   // Calculate lot size: every $1000 = AutoLotPer1000 lot
   double lotMultiplier = MathCeil(equity / 1000.0);
   double calculatedLot = lotMultiplier * AutoLotPer1000;
   
   Print("Auto Lot Calculation: $", equity, " equity -> ", lotMultiplier, " x ", AutoLotPer1000, " = ", calculatedLot, " lot");
   
   return calculatedLot;
}

double GetEffectiveLotSize()
{
   if(UseAutoLotSizing)
   {
      return NormalizeLotSize(CalculateAutoLotSize());
   }
   else
   {
      return NormalizeLotSize(LotSize);
   }
}

int CountPositions(ENUM_POSITION_TYPE posType)
{
   int count = 0;
   int total = PositionsTotal();
   
   for(int i = 0; i < total; i++)
   {
      if(PositionGetTicket(i))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetInteger(POSITION_TYPE) == posType)
         {
            count++;
         }
      }
   }
   
   return count;
}

void ClosePositionsByType(ENUM_POSITION_TYPE posType)
{
   int total = PositionsTotal();
   int closedCount = 0;
   
   for(int i = total - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetInteger(POSITION_TYPE) == posType)
         {
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            if(trade.PositionClose(ticket))
            {
               closedCount++;
            }
         }
      }
   }
   
   Print("Closed ", closedCount, " positions");
}

void CloseAllPositions()
{
   int total = PositionsTotal();
   int closedCount = 0;
   
   for(int i = total - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            if(trade.PositionClose(ticket))
            {
               closedCount++;
            }
         }
      }
   }
   
   Print("Manually closed ", closedCount, " positions");
}

void CloseProfitablePositions()
{
   int total = PositionsTotal();
   int closedCount = 0;
   
   for(int i = total - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(profit > 0)
            {
               ulong ticket = PositionGetInteger(POSITION_TICKET);
               if(trade.PositionClose(ticket))
               {
                  closedCount++;
               }
            }
         }
      }
   }
   
   Print("Manually closed ", closedCount, " profitable positions");
}

void CloseProfitablePositionsByType(ENUM_POSITION_TYPE posType)
{
   int total = PositionsTotal();
   int closedCount = 0;
   int losingCount = 0;
   
   for(int i = total - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            PositionGetInteger(POSITION_TYPE) == posType)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            ulong ticket = PositionGetInteger(POSITION_TICKET);
            
            if(profit > 0)
            {
               if(trade.PositionClose(ticket))
               {
                  closedCount++;
                  Print(">>> CLOSED PROFITABLE position #", ticket, " Profit: +", profit);
               }
            }
            else
            {
               losingCount++;
               Print(">>> KEEPING LOSING position #", ticket, " Loss: ", profit, " (LET RUN)");
            }
         }
      }
   }
   
   string posTypeStr = (posType == POSITION_TYPE_BUY) ? "BUY" : "SELL";
   Print("=== SUMMARY ===");
   Print("Closed ", closedCount, " PROFITABLE ", posTypeStr, " positions");
   Print("Kept ", losingCount, " LOSING ", posTypeStr, " positions open");
}

double CalculateTotalProfit()
{
   double totalProfit = 0;
   int total = PositionsTotal();
   
   for(int i = 0; i < total; i++)
   {
      if(PositionGetTicket(i))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            totalProfit += PositionGetDouble(POSITION_PROFIT);
         }
      }
   }
   
   return totalProfit;
}

int CountProfitablePositions()
{
   int count = 0;
   int total = PositionsTotal();
   
   for(int i = 0; i < total; i++)
   {
      if(PositionGetTicket(i))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            if(PositionGetDouble(POSITION_PROFIT) > 0)
               count++;
         }
      }
   }
   
   return count;
}

int CountLosingPositions()
{
   int count = 0;
   int total = PositionsTotal();
   
   for(int i = 0; i < total; i++)
   {
      if(PositionGetTicket(i))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         {
            if(PositionGetDouble(POSITION_PROFIT) < 0)
               count++;
         }
      }
   }
   
   return count;
}

void ToggleTrading()
{
   tradingEnabled = !tradingEnabled;
   Print("Trading ", (tradingEnabled ? "ENABLED" : "DISABLED"));
}

void CheckGlobalProfitTarget()
{
   if(GlobalProfitTarget <= 0) return;
   
   double totalProfit = CalculateTotalProfit();
   
   if(totalProfit >= GlobalProfitTarget)
   {
      int profitableCount = CountProfitablePositions();
      
      if(profitableCount > 0)
      {
         Print("========================================");
         Print("*** GLOBAL PROFIT TARGET REACHED ***");
         Print("Current Total Profit: $", DoubleToString(totalProfit, 2));
         Print("Target: $", DoubleToString(GlobalProfitTarget, 2));
         Print("Closing ", profitableCount, " profitable positions...");
         Print("========================================");
         
         CloseProfitablePositions();
         
         Print("Global profit target closure completed!");
         Print("Remaining losing positions will continue running...");
      }
   }
}

bool CreateButtons()
{
   int buttonWidth = 140;
   int buttonHeight = 25;
   int spacing = 10;
   
   long chartWidth = ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
   if(chartWidth <= 200) chartWidth = 800;
   
   // Calculate center position for 2 buttons
   int totalButtonsWidth = (buttonWidth * 2) + spacing;
   int startX = (int)(chartWidth - totalButtonsWidth) / 2;
   int startY = 10; // Top of screen
   
   // Toggle Trading Button (Center-Left)
   if(ObjectFind(0, BTN_TOGGLE_TRADING) < 0)
   {
      if(!ObjectCreate(0, BTN_TOGGLE_TRADING, OBJ_BUTTON, 0, 0, 0)) return false;
      
      ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_XDISTANCE, startX);
      ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_YDISTANCE, startY);
      ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_XSIZE, buttonWidth);
      ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_YSIZE, buttonHeight);
      ObjectSetString(0, BTN_TOGGLE_TRADING, OBJPROP_TEXT, "Toggle Trading");
      ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_BGCOLOR, clrBlue);
      ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_BORDER_COLOR, clrBlack);
      ObjectSetInteger(0, BTN_TOGGLE_TRADING, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   }
   
   // Close Profitable Button (Center-Right)
   if(ObjectFind(0, BTN_CLOSE_PROFITABLE) < 0)
   {
      if(!ObjectCreate(0, BTN_CLOSE_PROFITABLE, OBJ_BUTTON, 0, 0, 0)) return false;
      
      ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_XDISTANCE, startX + buttonWidth + spacing);
      ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_YDISTANCE, startY);
      ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_XSIZE, buttonWidth);
      ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_YSIZE, buttonHeight);
      ObjectSetString(0, BTN_CLOSE_PROFITABLE, OBJPROP_TEXT, "Close Profitable");
      ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_BGCOLOR, clrGreen);
      ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_BORDER_COLOR, clrBlack);
      ObjectSetInteger(0, BTN_CLOSE_PROFITABLE, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   }
   
   ChartRedraw();
   return true;
}

void DeleteButtons()
{
   ObjectDelete(0, BTN_TOGGLE_TRADING);
   ObjectDelete(0, BTN_CLOSE_PROFITABLE);
   ChartRedraw();
}

void UpdateDisplay()
{
   if(!isInitialized) return;
   
   int buyPositions = CountPositions(POSITION_TYPE_BUY);
   int sellPositions = CountPositions(POSITION_TYPE_SELL);
   int profitablePositions = CountProfitablePositions();
   int losingPositions = CountLosingPositions();
   double totalProfit = CalculateTotalProfit();
   
   string directionText = "";
   if(TradeDirection == TRADE_BOTH) directionText = "BOTH";
   else if(TradeDirection == TRADE_BUY_ONLY) directionText = "BUY ONLY";
   else directionText = "SELL ONLY";
   
   string tradingStatus = tradingEnabled ? "ENABLED" : "DISABLED";
   
   MqlDateTime dt;
   TimeCurrent(dt);
   string dayName = "";
   if(dt.day_of_week == 0) dayName = "SUNDAY";
   else if(dt.day_of_week == 1) dayName = "MONDAY";
   else if(dt.day_of_week == 2) dayName = "TUESDAY";
   else if(dt.day_of_week == 3) dayName = "WEDNESDAY";
   else if(dt.day_of_week == 4) dayName = "THURSDAY";
   else if(dt.day_of_week == 5) dayName = "FRIDAY";
   else dayName = "SATURDAY";
   
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPoints = (ask > 0 && bid > 0) ? (ask - bid) / _Point : 0;
   
   string tpText = (TakeProfitDollars > 0) ? DoubleToString(TakeProfitDollars, 2) + "$" : "None";
   string globalTargetProgress = DoubleToString(totalProfit, 2) + "$/" + DoubleToString(GlobalProfitTarget, 2) + "$";
   
   double effectiveLot = GetEffectiveLotSize();
   string lotText = "";
   if(UseAutoLotSizing)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      lotText = DoubleToString(effectiveLot, 2) + " (Auto: $" + DoubleToString(equity, 0) + ")";
   }
   else
   {
      lotText = DoubleToString(effectiveLot, 2) + " (Fixed)";
   }
   
   string info = "";
   info = info + "\n=== Enhanced Candle Pattern EA v2.11 ===\n";
   info = info + "Symbol: " + _Symbol + " | Spread: " + DoubleToString(spreadPoints, 1) + " pts\n";
   info = info + "Trading Status: " + tradingStatus + "\n";
   info = info + "Current Day: " + dayName + " (24/7)\n";
   info = info + "Direction: " + directionText + "\n";
   info = info + "Lot Size: " + lotText + " | Trades Per Signal: " + IntegerToString(actualTradesPerSignal) + "\n";
   info = info + "Max Positions: " + IntegerToString(MaxPositions) + " per direction\n";
   info = info + "Take Profit: " + tpText + " per trade\n";
   info = info + "Global Target: " + globalTargetProgress + "\n";
   
   string consecutiveExitText = EnableConsecutiveCandleExit ? 
      ("ENABLED (" + IntegerToString(ConsecutiveCandleCount) + " candles)") : "DISABLED";
   info = info + "Consecutive Exit: " + consecutiveExitText + "\n";
   
   info = info + "Consecutive Bullish: " + IntegerToString(consecutiveBullish) + "\n";
   info = info + "Consecutive Bearish: " + IntegerToString(consecutiveBearish) + "\n";
   info = info + "BUY: " + IntegerToString(buyPositions) + "/" + IntegerToString(MaxPositions) + " | SELL: " + IntegerToString(sellPositions) + "/" + IntegerToString(MaxPositions) + "\n";
   info = info + "Profitable: " + IntegerToString(profitablePositions) + " | Losing: " + IntegerToString(losingPositions) + "\n";
   info = info + "Total Profit: " + DoubleToString(totalProfit, 2) + "\n";
   info = info + "Last Bar: " + TimeToString(lastBarTime, TIME_DATE|TIME_MINUTES) + "\n";
   info = info + "===============================";
   
   Comment(info);
}