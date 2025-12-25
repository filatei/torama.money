//+------------------------------------------------------------------+
//|                                    TORAMA_Momentum_Grid.mq5      |
//|                                    TORAMA CAPITAL                |
//|                                    ea@torama.money               |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "ea@torama.money"
#property version   "1.00"
#property description "Momentum Grid Trading - Directional Grid System"

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "=== Grid Settings ==="
input int      InpGridLevels = 10;              // Number of Grid Levels
input double   InpGapPercent = 0.5;             // Gap (% of price)

input group "=== Risk Management ==="
input bool     InpAutoLotSize = false;          // Auto Calculate Lot Size
input double   InpLotSize = 0.01;               // Manual Lot Size
input double   InpRiskPercent = 1.0;            // Risk per Trade (%)
input double   InpRiskRewardRatio = 1.0;        // Risk:Reward Ratio
input double   InpMaxDrawdownPercent = 20.0;    // Max Drawdown (%)
input double   InpDailyTargetPercent = 10.0;    // Daily Target (%)

input group "=== Broker Settings ==="
input int      InpSpreadPoints = 2000;          // Spread Filter (points)
input int      InpSlippage = 50;                // Max Slippage (points)

input group "=== EA Control ==="
input string   InpTradeComment = "TORAMA_MGrid"; // Trade Comment

//--- Global Variables
CTrade trade;
long magicNumber = 0;
datetime lastBarTime = 0;
bool isInitialized = false;
bool isPaused = false;
double referencePrice = 0.0;
bool gridActivated = false;
double initialBalance = 0.0;
double peakEquity = 0.0;
double startOfDayBalance = 0.0;
datetime lastDayCheck = 0;
bool dailyTargetReached = false;

//--- Grid initialization (fixed at EA start)
double initialGapPercent = 0.0;  // Gap at EA initialization
double initialGapDollar = 0.0;    // Dollar gap calculated at start
bool gridInitialized = false;      // Flag to prevent grid recalculation

//--- Broker properties
double symbolPoint = 0.0;
double symbolTickSize = 0.0;
double symbolTickValue = 0.0;
double symbolMinLot = 0.0;
double symbolMaxLot = 0.0;
double symbolLotStep = 0.0;
int symbolDigits = 0;
double symbolContractSize = 0.0;
long symbolTradeMode = 0;
ENUM_SYMBOL_TRADE_EXECUTION symbolExecMode;
ENUM_ORDER_TYPE_FILLING symbolFillMode;
int symbolStopsLevel = 0;
int symbolFreezeLevel = 0;

//--- Calculated lot size
double calculatedLotSize = 0.0;

//--- Grid tracking (bidirectional)
double buyGridLevels[];
double sellGridLevels[];
bool buyLevelTriggered[];
bool sellLevelTriggered[];
int buyLevelsFilled = 0;
int sellLevelsFilled = 0;

//--- Button names
string btnCloseAll = "TORAMA_BTN_CloseAll";
string btnTakeTP = "TORAMA_BTN_TakeTP";
string btnPause = "TORAMA_BTN_Pause";

//--- Lot tracking
double totalBuyLots = 0.0;
double totalSellLots = 0.0;
double netLots = 0.0;
string netDirection = "";

//--- UI Variables
int panelX = 20;
int panelY = 30;
int panelWidth = 340;
int panelHeight = 390;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Use unique chart ID as magic number
   magicNumber = ChartID();
   
   // Initialize broker properties and validate
   if(!InitializeBrokerProperties())
   {
      Print("CRITICAL ERROR: Failed to initialize broker properties");
      return INIT_FAILED;
   }
   
   // Configure trade object with broker-compliant settings
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(symbolFillMode);
   trade.SetAsyncMode(false);
   
   // Calculate optimal lot size if auto-sizing enabled
   if(InpAutoLotSize)
   {
      calculatedLotSize = CalculateOptimalLotSize();
      Print("Auto Lot Size calculated: ", calculatedLotSize);
   }
   else
   {
      calculatedLotSize = NormalizeLot(InpLotSize);
      Print("Manual Lot Size normalized: ", calculatedLotSize);
   }
   
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   startOfDayBalance = initialBalance;
   lastDayCheck = TimeCurrent();
   
   // Lock in initial gap percent at EA start
   initialGapPercent = InpGapPercent;
   gridInitialized = false; // Will be set when reference price is established
   
   Print("Grid parameters locked at initialization:");
   Print("  Gap Percent: ", initialGapPercent, "%");
   Print("  Note: Grid levels are fixed relative to reference price");
   Print("  Changing inputs after start will not affect existing grid");
   
   // Initialize bidirectional grid arrays
   ArrayResize(buyGridLevels, InpGridLevels);
   ArrayResize(sellGridLevels, InpGridLevels);
   ArrayResize(buyLevelTriggered, InpGridLevels);
   ArrayResize(sellLevelTriggered, InpGridLevels);
   ArrayInitialize(buyLevelTriggered, false);
   ArrayInitialize(sellLevelTriggered, false);
   
   CreateUIPanel();
   CreateButtons();
   
   isInitialized = true;
   
   Print("========================================");
   Print("TORAMA Momentum Grid EA initialized");
   Print("Symbol: ", _Symbol);
   Print("Broker: ", AccountInfoString(ACCOUNT_COMPANY));
   Print("Lot Size: ", calculatedLotSize);
   Print("Risk per Trade: ", InpRiskPercent, "%");
   Print("Daily Target: ", InpDailyTargetPercent, "%");
   Print("========================================");
   
   // Load account history for grid level reset detection
   HistorySelect(0, TimeCurrent());
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Initialize and validate broker properties                        |
//+------------------------------------------------------------------+
bool InitializeBrokerProperties()
{
   // Get symbol properties
   symbolPoint = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   symbolTickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   symbolTickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   symbolMinLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   symbolMaxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   symbolLotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   symbolDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   symbolContractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   symbolTradeMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   symbolExecMode = (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE);
   symbolStopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   symbolFreezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   
   // Validate critical properties
   if(symbolPoint <= 0)
   {
      Print("ERROR: Invalid symbol point: ", symbolPoint);
      return false;
   }
   
   if(symbolTickValue <= 0)
   {
      Print("ERROR: Invalid tick value: ", symbolTickValue);
      return false;
   }
   
   if(symbolMinLot <= 0 || symbolMaxLot <= 0)
   {
      Print("ERROR: Invalid lot limits - Min: ", symbolMinLot, " Max: ", symbolMaxLot);
      return false;
   }
   
   // Check if trading is allowed
   if(symbolTradeMode == SYMBOL_TRADE_MODE_DISABLED)
   {
      Print("ERROR: Trading is disabled for ", _Symbol);
      return false;
   }
   
   if(symbolTradeMode == SYMBOL_TRADE_MODE_CLOSEONLY)
   {
      Print("WARNING: Symbol is in close-only mode");
   }
   
   // Determine best fill mode
   int filling = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   
   if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      symbolFillMode = ORDER_FILLING_FOK;
   else if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      symbolFillMode = ORDER_FILLING_IOC;
   else
      symbolFillMode = ORDER_FILLING_RETURN;
   
   Print("Broker Properties:");
   Print("  Min Lot: ", symbolMinLot, " | Max: ", symbolMaxLot, " | Step: ", symbolLotStep);
   Print("  Stops Level: ", symbolStopsLevel, " | Fill Mode: ", EnumToString(symbolFillMode));
   Print("  Point: ", symbolPoint, " | Digits: ", symbolDigits);
   
   // Show current spread
   long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   Print("  Current Spread: ", currentSpread, " points | Ask: ", ask, " | Bid: ", bid);
   
   return true;
}

//+------------------------------------------------------------------+
//| Calculate optimal lot size based on account                      |
//+------------------------------------------------------------------+
double CalculateOptimalLotSize()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (InpRiskPercent / 100.0);
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(currentPrice <= 0) currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // Estimate SL distance as 0.7% of price
   double estimatedSLDistance = currentPrice * 0.007;
   double slDistanceInTicks = estimatedSLDistance / symbolTickSize;
   double lotSize = riskAmount / (slDistanceInTicks * symbolTickValue);
   
   // Normalize and apply safety limits
   lotSize = NormalizeLot(lotSize);
   double maxReasonableLot = symbolMaxLot * 0.5;
   if(lotSize > maxReasonableLot)
   {
      Print("WARNING: Calculated lot ", lotSize, " exceeds limit. Using ", maxReasonableLot);
      lotSize = maxReasonableLot;
   }
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Normalize lot size to broker specifications                      |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   if(lot < symbolMinLot) return symbolMinLot;
   if(lot > symbolMaxLot) return symbolMaxLot;
   
   double normalizedLot = MathFloor(lot / symbolLotStep) * symbolLotStep;
   if(normalizedLot < symbolMinLot) normalizedLot = symbolMinLot;
   
   return NormalizeDouble(normalizedLot, 2);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteUIPanel();
   DeleteButtons();
   Comment("");
}

//+------------------------------------------------------------------+
//| Chart event handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == btnCloseAll)
      {
         CloseAllTrades();
         ObjectSetInteger(0, btnCloseAll, OBJPROP_STATE, false);
         Print("Close All button clicked - All trades closed");
      }
      else if(sparam == btnTakeTP)
      {
         TakeAllProfits();
         ObjectSetInteger(0, btnTakeTP, OBJPROP_STATE, false);
         Print("Take Profit button clicked");
      }
      else if(sparam == btnPause)
      {
         isPaused = !isPaused;
         ObjectSetInteger(0, btnPause, OBJPROP_STATE, isPaused);
         ObjectSetString(0, btnPause, OBJPROP_TEXT, isPaused ? "RESUME" : "PAUSE");
         ObjectSetInteger(0, btnPause, OBJPROP_BGCOLOR, isPaused ? clrGreen : clrOrange);
         Print(isPaused ? "EA PAUSED" : "EA RESUMED");
      }
      
      ChartRedraw();
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!isInitialized) return;
   
   // Refresh account history for closed trade detection
   static int tickCount = 0;
   tickCount++;
   if(tickCount % 10 == 0) // Every 10 ticks
   {
      HistorySelect(TimeCurrent() - 60, TimeCurrent()); // Last 60 seconds
   }
   
   // Check for new day
   CheckNewDay();
   
   // Check for new bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   bool isNewBar = (currentBarTime != lastBarTime);
   if(isNewBar) lastBarTime = currentBarTime;
   
   // Update UI
   UpdateUIPanel();
   
   // Check drawdown
   CheckDrawdown();
   
   if(isPaused) return;
   
   // Get current price
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Check if grid needs to be activated
   if(!gridActivated)
   {
      // Set reference price on first tick
      if(referencePrice == 0.0)
      {
         referencePrice = currentPrice;
         CalculateGridLevels();
         return;
      }
      
      // Check if first grid level is triggered
      CheckFirstGridTrigger(currentPrice);
   }
   else
   {
      // Grid is active, check for new grid level triggers
      CheckGridLevelTriggers(currentPrice);
   }
}

//+------------------------------------------------------------------+
//| Calculate bidirectional grid levels based on reference price     |
//+------------------------------------------------------------------+
void CalculateGridLevels()
{
   // Calculate gap using initial settings (locked at EA start)
   initialGapDollar = referencePrice * (initialGapPercent / 100.0);
   
   // Calculate buy levels (above reference)
   for(int i = 0; i < InpGridLevels; i++)
   {
      buyGridLevels[i] = referencePrice + (initialGapDollar * (i + 1));
   }
   
   // Calculate sell levels (below reference)
   for(int i = 0; i < InpGridLevels; i++)
   {
      sellGridLevels[i] = referencePrice - (initialGapDollar * (i + 1));
   }
   
   // Mark grid as initialized - levels are now fixed
   gridInitialized = true;
   
   Print("========================================");
   Print("GRID LEVELS CALCULATED & LOCKED");
   Print("Reference Price: ", referencePrice);
   Print("Gap: ", initialGapPercent, "% ($", DoubleToString(initialGapDollar, 2), ")");
   Print("");
   Print("BUY LEVELS (Above Reference):");
   Print("  Level 1: ", buyGridLevels[0], " (+", DoubleToString(initialGapDollar, 2), ")");
   Print("  Level 2: ", buyGridLevels[1], " (+", DoubleToString(initialGapDollar * 2, 2), ")");
   Print("  ...");
   Print("  Level ", InpGridLevels, ": ", buyGridLevels[InpGridLevels-1]);
   Print("");
   Print("SELL LEVELS (Below Reference):");
   Print("  Level 1: ", sellGridLevels[0], " (-", DoubleToString(initialGapDollar, 2), ")");
   Print("  Level 2: ", sellGridLevels[1], " (-", DoubleToString(initialGapDollar * 2, 2), ")");
   Print("  ...");
   Print("  Level ", InpGridLevels, ": ", sellGridLevels[InpGridLevels-1]);
   Print("");
   Print("BIDIRECTIONAL: BUY above ref, SELL below ref");
   Print("Grid is now FIXED - immune to input changes");
   Print("========================================");
}

//+------------------------------------------------------------------+
//| Check if first grid level is triggered (bidirectional)          |
//+------------------------------------------------------------------+
void CheckFirstGridTrigger(double currentPrice)
{
   double gapDollar = GetGapInDollars();
   double firstBuyLevel = referencePrice + gapDollar;
   double firstSellLevel = referencePrice - gapDollar;
   
   // Check for buy trigger (price moved up)
   if(currentPrice >= firstBuyLevel && !buyLevelTriggered[0])
   {
      gridActivated = true;
      OpenGridTrade(ORDER_TYPE_BUY, 0);
      buyLevelTriggered[0] = true;
      buyLevelsFilled++;
      
      Print("First BUY grid level triggered at: ", firstBuyLevel);
   }
   
   // Check for sell trigger (price moved down)
   if(currentPrice <= firstSellLevel && !sellLevelTriggered[0])
   {
      gridActivated = true;
      OpenGridTrade(ORDER_TYPE_SELL, 0);
      sellLevelTriggered[0] = true;
      sellLevelsFilled++;
      
      Print("First SELL grid level triggered at: ", firstSellLevel);
   }
}

//+------------------------------------------------------------------+
//| Check grid level triggers (classic bidirectional)               |
//+------------------------------------------------------------------+
void CheckGridLevelTriggers(double currentPrice)
{
   // First, check if any levels should be reset (trades closed at TP)
   ResetClosedGridLevels();
   
   // Check buy levels (buy up)
   for(int i = 0; i < InpGridLevels; i++)
   {
      if(!buyLevelTriggered[i] && currentPrice >= buyGridLevels[i])
      {
         OpenGridTrade(ORDER_TYPE_BUY, i);
         buyLevelTriggered[i] = true;
         buyLevelsFilled++;
         
         Print("BUY grid level ", i + 1, " triggered at: ", buyGridLevels[i]);
         break; // Only trigger one level per tick
      }
   }
   
   // Check sell levels (sell down)
   for(int i = 0; i < InpGridLevels; i++)
   {
      if(!sellLevelTriggered[i] && currentPrice <= sellGridLevels[i])
      {
         OpenGridTrade(ORDER_TYPE_SELL, i);
         sellLevelTriggered[i] = true;
         sellLevelsFilled++;
         
         Print("SELL grid level ", i + 1, " triggered at: ", sellGridLevels[i]);
         break; // Only trigger one level per tick
      }
   }
}

//+------------------------------------------------------------------+
//| Reset grid levels where trades have closed at TP                 |
//+------------------------------------------------------------------+
void ResetClosedGridLevels()
{
   // Check history for recently closed trades
   int totalDeals = HistoryDealsTotal();
   datetime currentTime = TimeCurrent();
   
   // Look at deals from last 10 seconds
   for(int i = totalDeals - 1; i >= 0 && i >= totalDeals - 50; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0)
      {
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
            HistoryDealGetInteger(ticket, DEAL_MAGIC) == magicNumber &&
            HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         {
            datetime dealTime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
            
            // Only process recent deals (last 10 seconds)
            if(currentTime - dealTime > 10)
               continue;
            
            double closePrice = HistoryDealGetDouble(ticket, DEAL_PRICE);
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            string comment = HistoryDealGetString(ticket, DEAL_COMMENT);
            
            // Only reset if closed at profit (TP hit)
            if(profit > 0)
            {
               // Extract level from comment (format: TORAMA_MGrid_L1, L2, etc)
               int levelStart = StringFind(comment, "_L");
               if(levelStart >= 0)
               {
                  string levelStr = StringSubstr(comment, levelStart + 2);
                  int level = (int)StringToInteger(levelStr) - 1; // Convert to 0-based index
                  
                  if(level >= 0 && level < InpGridLevels)
                  {
                     // Check if it's a buy or sell level by comparing close price to grid levels
                     double buyLevel = buyGridLevels[level];
                     double sellLevel = sellGridLevels[level];
                     
                     // Determine which level was hit (with tolerance)
                     double tolerance = symbolPoint * 10;
                     
                     if(MathAbs(closePrice - buyLevel) < tolerance || closePrice > buyLevel)
                     {
                        // Buy level - reset it for replacement
                        if(buyLevelTriggered[level])
                        {
                           buyLevelTriggered[level] = false;
                           buyLevelsFilled--;
                           Print("✓ BUY Level ", level + 1, " reset - closed at TP. Level is now replaceable.");
                        }
                     }
                     else if(MathAbs(closePrice - sellLevel) < tolerance || closePrice < sellLevel)
                     {
                        // Sell level - reset it for replacement
                        if(sellLevelTriggered[level])
                        {
                           sellLevelTriggered[level] = false;
                           sellLevelsFilled--;
                           Print("✓ SELL Level ", level + 1, " reset - closed at TP. Level is now replaceable.");
                        }
                     }
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Open grid trade                                                   |
//+------------------------------------------------------------------+
void OpenGridTrade(ENUM_ORDER_TYPE orderType, int level)
{
   // Pre-trade validations
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      Print("ERROR: Trading not allowed in terminal");
      return;
   }
   
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      Print("ERROR: EA trading not allowed");
      return;
   }
   
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      Print("ERROR: Automated trading disabled for this account");
      return;
   }
   
   // Check spread - using helper function
   long spread = GetCurrentSpread();
   
   if(spread > InpSpreadPoints)
   {
      Print("Spread too high: ", spread, " points. Trade skipped.");
      return;
   }
   
   // Get current price
   double price = (orderType == ORDER_TYPE_BUY) ? 
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                  SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   if(price <= 0)
   {
      Print("ERROR: Invalid price: ", price);
      return;
   }
   
   // Calculate SL/TP based on risk percent
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (InpRiskPercent / 100.0);
   
   // Use broker-validated properties
   if(symbolTickValue <= 0 || symbolTickSize <= 0)
   {
      Print("ERROR: Invalid tick properties");
      return;
   }
   
   // Calculate SL distance
   double slDistanceInPrice = (riskAmount / (symbolTickValue * calculatedLotSize)) * symbolTickSize;
   
   // Adjust for contract size if applicable
   if(symbolContractSize > 0 && symbolContractSize != 1.0)
   {
      double pointValue = (symbolPoint / price) * symbolContractSize * calculatedLotSize;
      if(pointValue > 0)
      {
         double slDistancePoints = riskAmount / pointValue;
         slDistanceInPrice = slDistancePoints * symbolPoint;
      }
   }
   
   // Calculate TP
   double tpDistanceInPrice = slDistanceInPrice * InpRiskRewardRatio;
   
   double sl = 0.0;
   double tp = 0.0;
   
   if(orderType == ORDER_TYPE_BUY)
   {
      sl = price - slDistanceInPrice;
      tp = price + tpDistanceInPrice;
   }
   else
   {
      sl = price + slDistanceInPrice;
      tp = price - tpDistanceInPrice;
   }
   
   // Normalize prices
   sl = NormalizeDouble(sl, symbolDigits);
   tp = NormalizeDouble(tp, symbolDigits);
   
   // Validate against broker stops level
   double minStopDistance = symbolStopsLevel * symbolPoint;
   
   if(minStopDistance > 0)
   {
      if(orderType == ORDER_TYPE_BUY)
      {
         if(price - sl < minStopDistance)
         {
            sl = NormalizeDouble(price - minStopDistance, symbolDigits);
            tp = NormalizeDouble(price + (minStopDistance * InpRiskRewardRatio), symbolDigits);
            Print("SL/TP adjusted for broker stops level");
         }
      }
      else
      {
         if(sl - price < minStopDistance)
         {
            sl = NormalizeDouble(price + minStopDistance, symbolDigits);
            tp = NormalizeDouble(price - (minStopDistance * InpRiskRewardRatio), symbolDigits);
            Print("SL/TP adjusted for broker stops level");
         }
      }
   }
   
   // Validate freeze level
   double freezeDistance = symbolFreezeLevel * symbolPoint;
   if(freezeDistance > 0)
   {
      if(MathAbs(price - sl) < freezeDistance || MathAbs(price - tp) < freezeDistance)
      {
         Print("WARNING: Price too close to freeze level. Adjusting...");
         if(orderType == ORDER_TYPE_BUY)
         {
            sl = NormalizeDouble(price - freezeDistance * 1.5, symbolDigits);
            tp = NormalizeDouble(price + freezeDistance * 1.5 * InpRiskRewardRatio, symbolDigits);
         }
         else
         {
            sl = NormalizeDouble(price + freezeDistance * 1.5, symbolDigits);
            tp = NormalizeDouble(price - freezeDistance * 1.5 * InpRiskRewardRatio, symbolDigits);
         }
      }
   }
   
   // Final validation
   if(sl <= 0 || tp <= 0)
   {
      Print("ERROR: Invalid SL/TP - SL: ", sl, " TP: ", tp);
      return;
   }
   
   string comment = InpTradeComment + "_L" + IntegerToString(level + 1);
   
   // Execute trade with error handling
   bool result = false;
   int retries = 3;
   int attempt = 0;
   
   while(attempt < retries && !result)
   {
      attempt++;
      
      if(orderType == ORDER_TYPE_BUY)
         result = trade.Buy(calculatedLotSize, _Symbol, 0, sl, tp, comment);
      else
         result = trade.Sell(calculatedLotSize, _Symbol, 0, sl, tp, comment);
      
      if(!result)
      {
         int error = GetLastError();
         Print("Trade attempt ", attempt, " failed. Error: ", error, " - ", ErrorDescription(error));
         
         if(error == 10004 || error == 10018 || error == 10019) // Requote, price changed, no prices
         {
            Sleep(1000); // Wait 1 second and retry
            // Refresh price
            price = (orderType == ORDER_TYPE_BUY) ? 
                    SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                    SymbolInfoDouble(_Symbol, SYMBOL_BID);
         }
         else if(error == 10006) // Request rejected
         {
            Print("Request rejected by broker. Stopping retries.");
            break;
         }
         else
         {
            break; // Other errors, don't retry
         }
      }
   }
   
   if(result)
   {
      Print("✓ Grid trade opened: ", EnumToString(orderType), 
            " | Level: ", level + 1, 
            " | Lot: ", calculatedLotSize,
            " | Price: ", price,
            " | SL: ", sl,
            " | TP: ", tp,
            " | Risk: $", DoubleToString(riskAmount, 2));
   }
   else
   {
      Print("✗ Failed to open trade after ", attempt, " attempts");
   }
}

//+------------------------------------------------------------------+
//| Get error description                                             |
//+------------------------------------------------------------------+
string ErrorDescription(int error)
{
   switch(error)
   {
      case 10004: return "Requote";
      case 10006: return "Request rejected";
      case 10013: return "Invalid request";
      case 10014: return "Invalid volume";
      case 10015: return "Invalid price";
      case 10016: return "Invalid stops";
      case 10018: return "Market closed";
      case 10019: return "No prices";
      case 10021: return "Not enough money";
      case 10027: return "Trading disabled";
      default: return "Error " + IntegerToString(error);
   }
}

//+------------------------------------------------------------------+
//| Get current spread in points (with Ask-Bid fallback)            |
//+------------------------------------------------------------------+
long GetCurrentSpread()
{
   // Try to get spread from symbol properties
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   
   // If spread is 0 or invalid, calculate from Ask-Bid
   if(spread == 0)
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      
      if(ask > 0 && bid > 0)
      {
         double spreadPrice = ask - bid;
         double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
         
         if(point > 0)
            spread = (long)MathRound(spreadPrice / point);
      }
   }
   
   return spread;
}

//+------------------------------------------------------------------+
//| Check and update start of day balance                            |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   datetime currentTime = TimeCurrent();
   MqlDateTime currentDT, lastDT;
   
   TimeToStruct(currentTime, currentDT);
   TimeToStruct(lastDayCheck, lastDT);
   
   // Check if we've crossed into a new day
   if(currentDT.day != lastDT.day || currentDT.mon != lastDT.mon || currentDT.year != lastDT.year)
   {
      startOfDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastDayCheck = currentTime;
      dailyTargetReached = false;
      Print("New day started. Start of day balance: $", DoubleToString(startOfDayBalance, 2));
   }
   
   // Check daily target
   if(!dailyTargetReached && !isPaused)
   {
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      double dailyProfit = currentBalance - startOfDayBalance;
      double dailyProfitPercent = (dailyProfit / startOfDayBalance) * 100.0;
      
      if(dailyProfitPercent >= InpDailyTargetPercent)
      {
         dailyTargetReached = true;
         CloseAllTrades();
         isPaused = true;
         
         Print("========================================");
         Print("DAILY TARGET REACHED!");
         Print("Target: ", InpDailyTargetPercent, "%");
         Print("Achieved: ", DoubleToString(dailyProfitPercent, 2), "%");
         Print("Profit: $", DoubleToString(dailyProfit, 2));
         Print("EA PAUSED until tomorrow");
         Print("========================================");
         
         Alert("TORAMA Grid: Daily target of ", InpDailyTargetPercent, "% reached! EA paused.");
         
         // Update pause button
         ObjectSetInteger(0, btnPause, OBJPROP_STATE, true);
         ObjectSetString(0, btnPause, OBJPROP_TEXT, "RESUME");
         ObjectSetInteger(0, btnPause, OBJPROP_BGCOLOR, clrGreen);
      }
   }
}

//+------------------------------------------------------------------+
//| Format number with comma separation for 1000+                    |
//+------------------------------------------------------------------+
string FormatNumber(double value, int decimals = 2)
{
   string result = DoubleToString(value, decimals);
   
   // Only format if value >= 1000 or <= -1000
   if(MathAbs(value) < 1000.0)
      return result;
   
   // Split into integer and decimal parts
   int dotPos = StringFind(result, ".");
   string intPart = "";
   string decPart = "";
   
   if(dotPos > 0)
   {
      intPart = StringSubstr(result, 0, dotPos);
      decPart = StringSubstr(result, dotPos);
   }
   else
   {
      intPart = result;
      decPart = "";
   }
   
   // Add commas to integer part
   string formatted = "";
   int len = StringLen(intPart);
   bool isNegative = false;
   
   // Handle negative sign
   if(StringGetCharacter(intPart, 0) == '-')
   {
      isNegative = true;
      intPart = StringSubstr(intPart, 1);
      len = StringLen(intPart);
   }
   
   int count = 0;
   for(int i = len - 1; i >= 0; i--)
   {
      if(count == 3)
      {
         formatted = "," + formatted;
         count = 0;
      }
      formatted = StringSubstr(intPart, i, 1) + formatted;
      count++;
   }
   
   if(isNegative)
      formatted = "-" + formatted;
   
   return formatted + decPart;
}

//+------------------------------------------------------------------+
//| Calculate lot positions for all trades on symbol                 |
//+------------------------------------------------------------------+
void CalculateLotPositions()
{
   totalBuyLots = 0.0;
   totalSellLots = 0.0;
   
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol)
         {
            double lots = PositionGetDouble(POSITION_VOLUME);
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            
            if(type == POSITION_TYPE_BUY)
               totalBuyLots += lots;
            else if(type == POSITION_TYPE_SELL)
               totalSellLots += lots;
         }
      }
   }
   
   // Calculate net position
   netLots = totalBuyLots - totalSellLots;
   
   if(netLots > 0)
      netDirection = "B";
   else if(netLots < 0)
   {
      netDirection = "S";
      netLots = MathAbs(netLots);
   }
   else
      netDirection = "";
}

//+------------------------------------------------------------------+
//| Get gap in dollars (uses locked initial gap if grid established)|
//+------------------------------------------------------------------+
double GetGapInDollars()
{
   // If grid already initialized, always return the locked gap
   if(gridInitialized)
      return initialGapDollar;
   
   // Otherwise calculate from current reference (pre-initialization)
   return referencePrice * (initialGapPercent / 100.0);
}

//+------------------------------------------------------------------+
//| Check drawdown and pause if exceeded                             |
//+------------------------------------------------------------------+
void CheckDrawdown()
{
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Update peak equity
   if(currentEquity > peakEquity)
      peakEquity = currentEquity;
   
   // Calculate drawdown from peak
   double drawdown = ((peakEquity - currentEquity) / initialBalance) * 100.0;
   
   if(drawdown >= InpMaxDrawdownPercent && !isPaused)
   {
      // Close all trades
      CloseAllTrades();
      
      // Pause EA
      isPaused = true;
      
      Print("MAX DRAWDOWN REACHED: ", DoubleToString(drawdown, 2), "% - EA PAUSED");
      Alert("TORAMA Grid: Max Drawdown Reached! EA Paused.");
   }
}

//+------------------------------------------------------------------+
//| Close all trades                                                  |
//+------------------------------------------------------------------+
void CloseAllTrades()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == magicNumber)
         {
            trade.PositionClose(ticket);
         }
      }
   }
   
   Print("All trades closed manually");
}

//+------------------------------------------------------------------+
//| Take profit on all winning trades                                |
//+------------------------------------------------------------------+
void TakeAllProfits()
{
   int closedCount = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == magicNumber)
         {
            double profit = PositionGetDouble(POSITION_PROFIT);
            if(profit > 0)
            {
               if(trade.PositionClose(ticket))
                  closedCount++;
            }
         }
      }
   }
   
   Print("Closed ", closedCount, " profitable trades");
}

//+------------------------------------------------------------------+
//| Create control buttons                                            |
//+------------------------------------------------------------------+
void CreateButtons()
{
   int buttonWidth = 100;
   int buttonHeight = 28;
   int buttonY = panelY + panelHeight - 70;
   int spacing = 10;
   
   // Close All button
   ObjectCreate(0, btnCloseAll, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, btnCloseAll, OBJPROP_XDISTANCE, panelX + spacing);
   ObjectSetInteger(0, btnCloseAll, OBJPROP_YDISTANCE, buttonY);
   ObjectSetInteger(0, btnCloseAll, OBJPROP_XSIZE, buttonWidth);
   ObjectSetInteger(0, btnCloseAll, OBJPROP_YSIZE, buttonHeight);
   ObjectSetString(0, btnCloseAll, OBJPROP_TEXT, "CLOSE ALL");
   ObjectSetString(0, btnCloseAll, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, btnCloseAll, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, btnCloseAll, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, btnCloseAll, OBJPROP_BGCOLOR, clrCrimson);
   ObjectSetInteger(0, btnCloseAll, OBJPROP_BORDER_COLOR, clrRed);
   ObjectSetInteger(0, btnCloseAll, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, btnCloseAll, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, btnCloseAll, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, btnCloseAll, OBJPROP_ZORDER, 1002);
   
   // Take Profit button
   ObjectCreate(0, btnTakeTP, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, btnTakeTP, OBJPROP_XDISTANCE, panelX + spacing + buttonWidth + spacing);
   ObjectSetInteger(0, btnTakeTP, OBJPROP_YDISTANCE, buttonY);
   ObjectSetInteger(0, btnTakeTP, OBJPROP_XSIZE, buttonWidth);
   ObjectSetInteger(0, btnTakeTP, OBJPROP_YSIZE, buttonHeight);
   ObjectSetString(0, btnTakeTP, OBJPROP_TEXT, "TAKE TP");
   ObjectSetString(0, btnTakeTP, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, btnTakeTP, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, btnTakeTP, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, btnTakeTP, OBJPROP_BGCOLOR, clrGreen);
   ObjectSetInteger(0, btnTakeTP, OBJPROP_BORDER_COLOR, clrLime);
   ObjectSetInteger(0, btnTakeTP, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, btnTakeTP, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, btnTakeTP, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, btnTakeTP, OBJPROP_ZORDER, 1002);
   
   // Pause button
   ObjectCreate(0, btnPause, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, btnPause, OBJPROP_XDISTANCE, panelX + spacing + (buttonWidth + spacing) * 2);
   ObjectSetInteger(0, btnPause, OBJPROP_YDISTANCE, buttonY);
   ObjectSetInteger(0, btnPause, OBJPROP_XSIZE, buttonWidth);
   ObjectSetInteger(0, btnPause, OBJPROP_YSIZE, buttonHeight);
   ObjectSetString(0, btnPause, OBJPROP_TEXT, "PAUSE");
   ObjectSetString(0, btnPause, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, btnPause, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, btnPause, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, btnPause, OBJPROP_BGCOLOR, clrOrange);
   ObjectSetInteger(0, btnPause, OBJPROP_BORDER_COLOR, clrGold);
   ObjectSetInteger(0, btnPause, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, btnPause, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, btnPause, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, btnPause, OBJPROP_ZORDER, 1002);
}

//+------------------------------------------------------------------+
//| Delete control buttons                                            |
//+------------------------------------------------------------------+
void DeleteButtons()
{
   ObjectDelete(0, btnCloseAll);
   ObjectDelete(0, btnTakeTP);
   ObjectDelete(0, btnPause);
}

//+------------------------------------------------------------------+
//| Create UI Panel                                                   |
//+------------------------------------------------------------------+
void CreateUIPanel()
{
   string prefix = "TORAMA_UI_";
   
   // Panel background
   ObjectCreate(0, prefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_XDISTANCE, panelX);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_YDISTANCE, panelY);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_XSIZE, panelWidth);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_YSIZE, panelHeight);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_COLOR, clrGold);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_BACK, false);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_SELECTED, false);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, prefix + "BG", OBJPROP_ZORDER, 1000);
   
   // Title
   CreateLabel(prefix + "Title", "TORAMA MOMENTUM GRID", 
               panelX + 10, panelY + 8, clrGold, 12, true);
   
   // Stats labels - compact professional layout
   int yPos = panelY + 40;
   int lineHeight = 26;
   
   // Line 1: Status | Spread
   CreateLabel(prefix + "StatusSpread", "Status: Waiting | Spread: 0", 
               panelX + 10, yPos, clrWhite, 10, false);
   yPos += lineHeight;
   
   // Line 2: Grid | Gap
   CreateLabel(prefix + "GridGap", "Grid: 0/0 | Gap: 0.00% ($0.00)", 
               panelX + 10, yPos, clrCyan, 10, false);
   yPos += lineHeight;
   
   // Line 3: Price (BOLD, LARGE)
   CreateLabel(prefix + "Price", "Price: 0.00", 
               panelX + 10, yPos, clrYellow, 11, true);
   yPos += lineHeight;
   
   // Line 4: Reference Price (shows grid anchor)
   CreateLabel(prefix + "RefPrice", "Ref: N/A | Grid: Not Set", 
               panelX + 10, yPos, clrOrange, 10, false);
   yPos += lineHeight;
   
   // Line 5: Next Level
   CreateLabel(prefix + "NextLevel", "Next: Waiting...", 
               panelX + 10, yPos, clrYellow, 10, false);
   yPos += lineHeight;
   
   // Line 5: Lot Position
   CreateLabel(prefix + "LotPosition", "B: 0.00 | S: 0.00 (Net: 0.00)", 
               panelX + 10, yPos, clrMagenta, 10, false);
   yPos += lineHeight;
   
   // Line 6: Balance | Equity (BOLD)
   CreateLabel(prefix + "BalEq", "Bal: $0.00 | EQ: $0.00", 
               panelX + 10, yPos, clrLime, 11, true);
   yPos += lineHeight;
   
   // Line 7: P/L | Drawdown
   CreateLabel(prefix + "PLDrawdown", "P/L: $0.00 | DD: 0.00%", 
               panelX + 10, yPos, clrWhite, 10, false);
   yPos += lineHeight;
   
   // Line 8: Margin | Day's Profit
   CreateLabel(prefix + "MarginDay", "Margin: $0.00 | Day: $0.00", 
               panelX + 10, yPos, clrWhite, 10, false);
   yPos += lineHeight;
   
   // Branding with right margin
   CreateLabel(prefix + "Brand", "TORAMA CAPITAL", 
               panelX + panelWidth - 155, panelY + panelHeight - 32, clrGold, 10, true);
   CreateLabel(prefix + "Email", "ea@torama.money", 
               panelX + panelWidth - 140, panelY + panelHeight - 16, clrGold, 8, false);
}

//+------------------------------------------------------------------+
//| Create Label                                                      |
//+------------------------------------------------------------------+
void CreateLabel(string name, string text, int x, int y, color clr, int fontSize, bool bold)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Arial Black" : "Arial");
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 1001);
}

//+------------------------------------------------------------------+
//| Update UI Panel                                                   |
//+------------------------------------------------------------------+
void UpdateUIPanel()
{
   string prefix = "TORAMA_UI_";
   
   // Check if new day and reset start balance
   static datetime lastCheckDate = 0;
   datetime currentDate = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(currentDate != lastCheckDate && lastCheckDate != 0)
   {
      startOfDayBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastCheckDate = currentDate;
   }
   else if(lastCheckDate == 0)
   {
      lastCheckDate = currentDate;
   }
   
   // Calculate lot positions
   CalculateLotPositions();
   
   // Get account data
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   double pl = equity - balance;
   
   // Calculate day's profit
   double dayProfit = balance - startOfDayBalance;
   
   // Status line
   string status = isPaused ? "PAUSED" : (gridActivated ? "ACTIVE" : "Waiting");
   color statusColor = isPaused ? clrRed : (gridActivated ? clrLime : clrYellow);
   
   // Spread - using helper function
   long spread = GetCurrentSpread();
   color spreadColor = (spread > InpSpreadPoints) ? clrRed : clrLime;
   
   string spreadText = "";
   if(spread >= 1000)
      spreadText = FormatNumber((double)spread, 0);
   else
      spreadText = IntegerToString(spread);
   
   // Add "pts" suffix for clarity
   spreadText += " pts";
   
   // Line 1: Status | Spread
   string statusSpreadText = "Status: " + status + " | Spread: " + spreadText;
   ObjectSetString(0, prefix + "StatusSpread", OBJPROP_TEXT, statusSpreadText);
   ObjectSetInteger(0, prefix + "StatusSpread", OBJPROP_COLOR, statusColor);
   
   // Line 2: Grid | Gap (shows LOCKED initial gap)
   double displayGapPercent = gridInitialized ? initialGapPercent : InpGapPercent;
   double displayGapDollar = gridInitialized ? initialGapDollar : GetGapInDollars();
   string lockIndicator = gridInitialized ? " 🔒" : "";
   
   string gridGapText = "Grid: B:" + IntegerToString(buyLevelsFilled) + 
                        " S:" + IntegerToString(sellLevelsFilled) + 
                        " (" + IntegerToString(buyLevelsFilled + sellLevelsFilled) + "/" + 
                        IntegerToString(InpGridLevels * 2) + ") | Gap: " + 
                        DoubleToString(displayGapPercent, 2) + "% ($" + FormatNumber(displayGapDollar, 2) + ")" + lockIndicator;
   ObjectSetString(0, prefix + "GridGap", OBJPROP_TEXT, gridGapText);
   
   // Line 3: Price (BOLD, LARGE)
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   ObjectSetString(0, prefix + "Price", OBJPROP_TEXT, 
                   "Price: " + FormatNumber(currentPrice, digits));
   
   // Line 4: Reference Price
   string refPriceText = "";
   color refPriceColor = clrOrange;
   
   if(referencePrice > 0 && gridInitialized)
   {
      refPriceText = "Ref: " + FormatNumber(referencePrice, digits);
      
      // Show grid direction indicators
      string gridStatus = " | Grid: ";
      if(currentPrice > referencePrice)
      {
         gridStatus += "↑ ABOVE (Buy Zone)";
         refPriceColor = clrLime;
      }
      else if(currentPrice < referencePrice)
      {
         gridStatus += "↓ BELOW (Sell Zone)";
         refPriceColor = clrOrange;
      }
      else
      {
         gridStatus += "= AT REF";
         refPriceColor = clrYellow;
      }
      
      refPriceText += gridStatus;
   }
   else if(referencePrice > 0)
   {
      refPriceText = "Ref: " + FormatNumber(referencePrice, digits) + " | Grid: Calculating...";
      refPriceColor = clrYellow;
   }
   else
   {
      refPriceText = "Ref: N/A | Grid: Not Set";
      refPriceColor = clrGray;
   }
   
   ObjectSetString(0, prefix + "RefPrice", OBJPROP_TEXT, refPriceText);
   ObjectSetInteger(0, prefix + "RefPrice", OBJPROP_COLOR, refPriceColor);
   
   // Line 5: Next Level
   string nextLevelText = "Next: Waiting...";
   color nextLevelColor = clrYellow;
   double gapDollar = displayGapDollar; // Use the gap dollar from line 2
   
   if(!gridActivated)
   {
      double firstBuyLevel = referencePrice + gapDollar;
      double firstSellLevel = referencePrice - gapDollar;
      nextLevelText = "Next: B@" + FormatNumber(firstBuyLevel, digits) + 
                      " | S@" + FormatNumber(firstSellLevel, digits);
   }
   else
   {
      // Find next untriggered levels
      double nextBuyLevel = 0;
      double nextSellLevel = 0;
      
      for(int i = 0; i < InpGridLevels; i++)
      {
         if(!buyLevelTriggered[i])
         {
            nextBuyLevel = buyGridLevels[i];
            break;
         }
      }
      
      for(int i = 0; i < InpGridLevels; i++)
      {
         if(!sellLevelTriggered[i])
         {
            nextSellLevel = sellGridLevels[i];
            break;
         }
      }
      
      // Always show both levels (classic bidirectional)
      if(nextBuyLevel > 0 && nextSellLevel > 0)
      {
         nextLevelText = "Next: B@" + FormatNumber(nextBuyLevel, digits) + 
                        " | S@" + FormatNumber(nextSellLevel, digits);
         nextLevelColor = clrAqua;
      }
      else if(nextBuyLevel > 0)
      {
         nextLevelText = "Next: BUY @ " + FormatNumber(nextBuyLevel, digits);
         nextLevelColor = clrLime;
      }
      else if(nextSellLevel > 0)
      {
         nextLevelText = "Next: SELL @ " + FormatNumber(nextSellLevel, digits);
         nextLevelColor = clrOrange;
      }
      else
      {
         nextLevelText = "Next: All Grids Complete!";
         nextLevelColor = clrGold;
      }
   }
   
   ObjectSetString(0, prefix + "NextLevel", OBJPROP_TEXT, nextLevelText);
   ObjectSetInteger(0, prefix + "NextLevel", OBJPROP_COLOR, nextLevelColor);
   
   // Line 5: Lot Position
   string lotPositionText = "B: " + DoubleToString(totalBuyLots, 2) + 
                           " | S: " + DoubleToString(totalSellLots, 2);
   
   if(netDirection != "")
      lotPositionText += " (Net: " + DoubleToString(netLots, 2) + netDirection + ")";
   else
      lotPositionText += " (Net: 0.00)";
   
   ObjectSetString(0, prefix + "LotPosition", OBJPROP_TEXT, lotPositionText);
   
   // Line 6: Balance | Equity (BOLD)
   string balEqText = "Bal: $" + FormatNumber(balance, 2) + " | EQ: $" + FormatNumber(equity, 2);
   ObjectSetString(0, prefix + "BalEq", OBJPROP_TEXT, balEqText);
   
   // Line 7: P/L | Drawdown
   color plColor = (pl >= 0) ? clrLime : clrRed;
   double drawdown = ((peakEquity - equity) / initialBalance) * 100.0;
   color ddColor = clrWhite;
   if(drawdown > InpMaxDrawdownPercent * 0.8) ddColor = clrOrange;
   if(drawdown >= InpMaxDrawdownPercent) ddColor = clrRed;
   
   string plDDText = "P/L: $" + FormatNumber(pl, 2) + " | DD: " + DoubleToString(drawdown, 2) + "%";
   ObjectSetString(0, prefix + "PLDrawdown", OBJPROP_TEXT, plDDText);
   ObjectSetInteger(0, prefix + "PLDrawdown", OBJPROP_COLOR, plColor);
   
   // Line 8: Margin | Day's Profit
   color dayColor = (dayProfit >= 0) ? clrLime : clrRed;
   string marginDayText = "Margin: $" + FormatNumber(margin, 2) + " | Day: $" + FormatNumber(dayProfit, 2);
   ObjectSetString(0, prefix + "MarginDay", OBJPROP_TEXT, marginDayText);
   ObjectSetInteger(0, prefix + "MarginDay", OBJPROP_COLOR, dayColor);
}

//+------------------------------------------------------------------+
//| Delete UI Panel                                                   |
//+------------------------------------------------------------------+
void DeleteUIPanel()
{
   string prefix = "TORAMA_UI_";
   
   ObjectDelete(0, prefix + "BG");
   ObjectDelete(0, prefix + "Title");
   ObjectDelete(0, prefix + "StatusSpread");
   ObjectDelete(0, prefix + "GridGap");
   ObjectDelete(0, prefix + "Price");
   ObjectDelete(0, prefix + "RefPrice");
   ObjectDelete(0, prefix + "NextLevel");
   ObjectDelete(0, prefix + "LotPosition");
   ObjectDelete(0, prefix + "BalEq");
   ObjectDelete(0, prefix + "PLDrawdown");
   ObjectDelete(0, prefix + "MarginDay");
   ObjectDelete(0, prefix + "Brand");
   ObjectDelete(0, prefix + "Email");
}
//+------------------------------------------------------------------+
