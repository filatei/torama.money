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
input int      InpReversalLevels = 3;           // Reversal Threshold (grid levels)

input group "=== Risk Management ==="
input double   InpLotSize = 0.01;               // Lot Size
input double   InpRiskPercent = 1.0;            // Risk per Trade (%)
input double   InpRiskRewardRatio = 1.0;        // Risk:Reward Ratio
input double   InpMaxDrawdownPercent = 20.0;    // Max Drawdown (%)

input group "=== Broker Settings ==="
input int      InpSpreadPoints = 2000;          // Spread Filter (points)

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

//--- Grid tracking (bidirectional)
double buyGridLevels[];
double sellGridLevels[];
bool buyLevelTriggered[];
bool sellLevelTriggered[];
int buyLevelsFilled = 0;
int sellLevelsFilled = 0;
int consecutiveBuys = 0;
int consecutiveSells = 0;
string currentMode = "Bidirectional"; // "Bidirectional", "BuyOnly", "SellOnly"

//--- Lot tracking
double totalBuyLots = 0.0;
double totalSellLots = 0.0;
double netLots = 0.0;
string netDirection = "";

//--- UI Variables
int panelX = 20;
int panelY = 30;
int panelWidth = 320;
int panelHeight = 370;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Use unique chart ID as magic number
   magicNumber = ChartID();
   trade.SetExpertMagicNumber(magicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetAsyncMode(false);
   
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   // Initialize bidirectional grid arrays
   ArrayResize(buyGridLevels, InpGridLevels);
   ArrayResize(sellGridLevels, InpGridLevels);
   ArrayResize(buyLevelTriggered, InpGridLevels);
   ArrayResize(sellLevelTriggered, InpGridLevels);
   ArrayInitialize(buyLevelTriggered, false);
   ArrayInitialize(sellLevelTriggered, false);
   
   CreateUIPanel();
   
   isInitialized = true;
   
   Print("TORAMA Momentum Grid EA initialized successfully");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   DeleteUIPanel();
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!isInitialized) return;
   
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
   double gapDollar = GetGapInDollars();
   
   // Calculate buy levels (above reference)
   for(int i = 0; i < InpGridLevels; i++)
   {
      buyGridLevels[i] = referencePrice + (gapDollar * (i + 1));
   }
   
   // Calculate sell levels (below reference)
   for(int i = 0; i < InpGridLevels; i++)
   {
      sellGridLevels[i] = referencePrice - (gapDollar * (i + 1));
   }
}

//+------------------------------------------------------------------+
//| Check if first grid level is triggered (bidirectional)          |
//+------------------------------------------------------------------+
void CheckFirstGridTrigger(double currentPrice)
{
   double gapDollar = GetGapInDollars();
   double firstBuyLevel = referencePrice + gapDollar;
   double firstSellLevel = referencePrice - gapDollar;
   
   bool buyTriggered = false;
   bool sellTriggered = false;
   
   // Check for buy trigger (price moved up)
   if(currentPrice >= firstBuyLevel && !buyLevelTriggered[0])
   {
      gridActivated = true;
      OpenGridTrade(ORDER_TYPE_BUY, 0);
      buyLevelTriggered[0] = true;
      buyLevelsFilled++;
      consecutiveBuys++;
      consecutiveSells = 0;
      buyTriggered = true;
      
      Print("First BUY grid level triggered at: ", firstBuyLevel);
      CheckReversal();
   }
   
   // Check for sell trigger (price moved down)
   if(currentPrice <= firstSellLevel && !sellLevelTriggered[0])
   {
      gridActivated = true;
      OpenGridTrade(ORDER_TYPE_SELL, 0);
      sellLevelTriggered[0] = true;
      sellLevelsFilled++;
      consecutiveSells++;
      consecutiveBuys = 0;
      sellTriggered = true;
      
      Print("First SELL grid level triggered at: ", firstSellLevel);
      CheckReversal();
   }
}

//+------------------------------------------------------------------+
//| Check grid level triggers (bidirectional with reversal)         |
//+------------------------------------------------------------------+
void CheckGridLevelTriggers(double currentPrice)
{
   // Check buy levels
   if(currentMode == "Bidirectional" || currentMode == "BuyOnly")
   {
      for(int i = 0; i < InpGridLevels; i++)
      {
         if(!buyLevelTriggered[i] && currentPrice >= buyGridLevels[i])
         {
            OpenGridTrade(ORDER_TYPE_BUY, i);
            buyLevelTriggered[i] = true;
            buyLevelsFilled++;
            consecutiveBuys++;
            consecutiveSells = 0;
            
            Print("BUY grid level ", i + 1, " triggered at: ", buyGridLevels[i]);
            CheckReversal();
            break; // Only trigger one level per tick
         }
      }
   }
   
   // Check sell levels
   if(currentMode == "Bidirectional" || currentMode == "SellOnly")
   {
      for(int i = 0; i < InpGridLevels; i++)
      {
         if(!sellLevelTriggered[i] && currentPrice <= sellGridLevels[i])
         {
            OpenGridTrade(ORDER_TYPE_SELL, i);
            sellLevelTriggered[i] = true;
            sellLevelsFilled++;
            consecutiveSells++;
            consecutiveBuys = 0;
            
            Print("SELL grid level ", i + 1, " triggered at: ", sellGridLevels[i]);
            CheckReversal();
            break; // Only trigger one level per tick
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if reversal threshold is reached                           |
//+------------------------------------------------------------------+
void CheckReversal()
{
   // Check if we need to reverse to BuyOnly mode
   if(consecutiveBuys >= InpReversalLevels && currentMode != "BuyOnly")
   {
      currentMode = "BuyOnly";
      Print("REVERSAL: Switching to BUY ONLY mode after ", consecutiveBuys, " consecutive buys");
      Alert("TORAMA Grid: Reversal to BUY ONLY mode!");
   }
   
   // Check if we need to reverse to SellOnly mode
   if(consecutiveSells >= InpReversalLevels && currentMode != "SellOnly")
   {
      currentMode = "SellOnly";
      Print("REVERSAL: Switching to SELL ONLY mode after ", consecutiveSells, " consecutive sells");
      Alert("TORAMA Grid: Reversal to SELL ONLY mode!");
   }
}

//+------------------------------------------------------------------+
//| Open grid trade                                                   |
//+------------------------------------------------------------------+
void OpenGridTrade(ENUM_ORDER_TYPE orderType, int level)
{
   // Check spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpSpreadPoints)
   {
      Print("Spread too high: ", spread, " points. Trade skipped.");
      return;
   }
   
   double price = (orderType == ORDER_TYPE_BUY) ? 
                  SymbolInfoDouble(_Symbol, SYMBOL_ASK) : 
                  SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Calculate SL based on 1% account risk
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (InpRiskPercent / 100.0);
   
   // Get tick value for the symbol
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   if(tickValue == 0)
   {
      Print("Error: Tick value is zero. Cannot calculate SL/TP");
      return;
   }
   
   // Calculate SL distance in price that risks exactly 1% of account
   // Risk = (Price Distance / Tick Size) * Tick Value * Lot Size
   // Therefore: Price Distance = (Risk / (Tick Value * Lot Size)) * Tick Size
   double slDistanceInPrice = (riskAmount / (tickValue * InpLotSize)) * tickSize;
   
   // For crypto/forex, adjust for contract size if needed
   double contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(contractSize > 0 && contractSize != 1.0)
   {
      // Recalculate considering contract size
      // Point value per lot = (Point / Quote) * Contract Size * Lot
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double pointValue = 0.0;
      
      if(orderType == ORDER_TYPE_BUY)
         pointValue = (point / price) * contractSize * InpLotSize;
      else
         pointValue = (point / price) * contractSize * InpLotSize;
      
      // SL distance in points
      double slDistancePoints = riskAmount / pointValue;
      slDistanceInPrice = slDistancePoints * point;
   }
   
   // Calculate TP based on Risk:Reward ratio
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
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   
   // Validate SL and TP
   double minStopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   if(orderType == ORDER_TYPE_BUY)
   {
      if(price - sl < minStopLevel)
      {
         sl = price - minStopLevel;
         tp = price + (minStopLevel * InpRiskRewardRatio);
         sl = NormalizeDouble(sl, digits);
         tp = NormalizeDouble(tp, digits);
         Print("SL adjusted to minimum stop level");
      }
   }
   else
   {
      if(sl - price < minStopLevel)
      {
         sl = price + minStopLevel;
         tp = price - (minStopLevel * InpRiskRewardRatio);
         sl = NormalizeDouble(sl, digits);
         tp = NormalizeDouble(tp, digits);
         Print("SL adjusted to minimum stop level");
      }
   }
   
   string comment = InpTradeComment + "_L" + IntegerToString(level + 1);
   
   bool result = false;
   if(orderType == ORDER_TYPE_BUY)
      result = trade.Buy(InpLotSize, _Symbol, 0, sl, tp, comment);
   else
      result = trade.Sell(InpLotSize, _Symbol, 0, sl, tp, comment);
   
   if(result)
   {
      Print("Grid trade opened: ", EnumToString(orderType), 
            " Level: ", level + 1, 
            " Price: ", price,
            " SL: ", sl, " (Risk: $", DoubleToString(riskAmount, 2), ")",
            " TP: ", tp, " (RR: ", DoubleToString(InpRiskRewardRatio, 2), ":1)");
   }
   else
   {
      Print("Failed to open trade. Error: ", GetLastError());
      Print("Details - Price: ", price, ", SL: ", sl, ", TP: ", tp);
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
//| Get gap in dollars                                                |
//+------------------------------------------------------------------+
double GetGapInDollars()
{
   return referencePrice * (InpGapPercent / 100.0);
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
   
   Print("All trades closed due to max drawdown");
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
               panelX + 10, panelY + 10, clrGold, 11, true);
   
   // Stats labels
   int yPos = panelY + 45;
   int lineHeight = 25;
   
   CreateLabel(prefix + "Status", "Status: Waiting", panelX + 10, yPos, clrWhite, 9, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "Spread", "Spread: 0", panelX + 10, yPos, clrWhite, 9, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "Gap", "Gap: 0.00% ($0.00)", panelX + 10, yPos, clrWhite, 9, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "Price", "Price: 0.00", panelX + 10, yPos, clrWhite, 9, true);
   yPos += lineHeight;
   
   CreateLabel(prefix + "NextLevel", "Next: Waiting...", panelX + 10, yPos, clrYellow, 9, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "GridFilled", "Grid Filled: 0/" + IntegerToString(InpGridLevels), 
               panelX + 10, yPos, clrWhite, 9, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "LotPosition", "B: 0.00 | S: 0.00 (Net: 0.00)", 
               panelX + 10, yPos, clrCyan, 9, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "Balance", "Balance: $0.00", panelX + 10, yPos, clrLime, 9, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "Equity", "Equity: $0.00", panelX + 10, yPos, clrAqua, 9, true);
   yPos += lineHeight;
   
   CreateLabel(prefix + "PL", "P/L: $0.00", panelX + 10, yPos, clrWhite, 9, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "Drawdown", "Drawdown: 0.00%", panelX + 10, yPos, clrWhite, 9, false);
   yPos += lineHeight;
   
   // Branding with right margin
   CreateLabel(prefix + "Brand", "TORAMA CAPITAL", 
               panelX + panelWidth - 155, panelY + panelHeight - 35, clrGold, 10, true);
   CreateLabel(prefix + "Email", "ea@torama.money", 
               panelX + panelWidth - 140, panelY + panelHeight - 18, clrGold, 8, false);
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
   
   // Calculate lot positions
   CalculateLotPositions();
   
   // Status
   string status = "Waiting";
   color statusColor = clrYellow;
   
   if(isPaused)
   {
      status = "PAUSED";
      statusColor = clrRed;
   }
   else if(gridActivated)
   {
      if(currentMode == "BuyOnly")
      {
         status = "BUY ONLY";
         statusColor = clrLime;
      }
      else if(currentMode == "SellOnly")
      {
         status = "SELL ONLY";
         statusColor = clrOrange;
      }
      else
      {
         status = "BIDIRECTIONAL";
         statusColor = clrAqua;
      }
   }
   
   ObjectSetString(0, prefix + "Status", OBJPROP_TEXT, "Status: " + status);
   ObjectSetInteger(0, prefix + "Status", OBJPROP_COLOR, statusColor);
   
   // Spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   color spreadColor = (spread > InpSpreadPoints) ? clrRed : clrLime;
   string spreadText = (spread >= 1000) ? FormatNumber((double)spread, 0) : IntegerToString(spread);
   ObjectSetString(0, prefix + "Spread", OBJPROP_TEXT, "Spread: " + spreadText);
   ObjectSetInteger(0, prefix + "Spread", OBJPROP_COLOR, spreadColor);
   
   // Gap - combined percent and dollar on same line
   double gapPercent = InpGapPercent;
   double gapDollar = GetGapInDollars();
   ObjectSetString(0, prefix + "Gap", OBJPROP_TEXT, 
                   "Gap: " + DoubleToString(gapPercent, 2) + "% ($" + FormatNumber(gapDollar, 2) + ")");
   
   // Current Price (BOLD)
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   ObjectSetString(0, prefix + "Price", OBJPROP_TEXT, 
                   "Price: " + FormatNumber(currentPrice, digits));
   
   // Next Level - show both buy and sell or just active direction
   string nextLevelText = "Next: Waiting...";
   color nextLevelColor = clrYellow;
   
   if(!gridActivated)
   {
      double firstBuyLevel = referencePrice + gapDollar;
      double firstSellLevel = referencePrice - gapDollar;
      nextLevelText = "Next: B@" + FormatNumber(firstBuyLevel, digits) + 
                      " | S@" + FormatNumber(firstSellLevel, digits);
      nextLevelColor = clrYellow;
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
      
      if(currentMode == "BuyOnly")
      {
         if(nextBuyLevel > 0)
         {
            nextLevelText = "Next: BUY @ " + FormatNumber(nextBuyLevel, digits);
            nextLevelColor = clrLime;
         }
         else
         {
            nextLevelText = "Next: Buy Grid Complete!";
            nextLevelColor = clrGold;
         }
      }
      else if(currentMode == "SellOnly")
      {
         if(nextSellLevel > 0)
         {
            nextLevelText = "Next: SELL @ " + FormatNumber(nextSellLevel, digits);
            nextLevelColor = clrOrange;
         }
         else
         {
            nextLevelText = "Next: Sell Grid Complete!";
            nextLevelColor = clrGold;
         }
      }
      else // Bidirectional
      {
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
   }
   
   ObjectSetString(0, prefix + "NextLevel", OBJPROP_TEXT, nextLevelText);
   ObjectSetInteger(0, prefix + "NextLevel", OBJPROP_COLOR, nextLevelColor);
   
   // Grid filled - show both buy and sell counts
   string gridFilledText = "Grid: B:" + IntegerToString(buyLevelsFilled) + 
                          " S:" + IntegerToString(sellLevelsFilled) + 
                          " (" + IntegerToString(buyLevelsFilled + sellLevelsFilled) + "/" + 
                          IntegerToString(InpGridLevels * 2) + ")";
   ObjectSetString(0, prefix + "GridFilled", OBJPROP_TEXT, gridFilledText);
   
   // Lot Position
   string lotPositionText = "B: " + DoubleToString(totalBuyLots, 2) + 
                           " | S: " + DoubleToString(totalSellLots, 2);
   
   if(netDirection != "")
      lotPositionText += " (Net: " + DoubleToString(netLots, 2) + netDirection + ")";
   else
      lotPositionText += " (Net: 0.00)";
   
   ObjectSetString(0, prefix + "LotPosition", OBJPROP_TEXT, lotPositionText);
   
   // Balance
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   ObjectSetString(0, prefix + "Balance", OBJPROP_TEXT, 
                   "Balance: $" + FormatNumber(balance, 2));
   
   // Equity (BOLD)
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, prefix + "Equity", OBJPROP_TEXT, 
                   "Equity: $" + FormatNumber(equity, 2));
   
   // P/L
   double pl = equity - balance;
   color plColor = (pl >= 0) ? clrLime : clrRed;
   ObjectSetString(0, prefix + "PL", OBJPROP_TEXT, 
                   "P/L: $" + FormatNumber(pl, 2));
   ObjectSetInteger(0, prefix + "PL", OBJPROP_COLOR, plColor);
   
   // Drawdown
   double drawdown = ((peakEquity - equity) / initialBalance) * 100.0;
   color ddColor = clrWhite;
   if(drawdown > InpMaxDrawdownPercent * 0.8) ddColor = clrOrange;
   if(drawdown >= InpMaxDrawdownPercent) ddColor = clrRed;
   
   ObjectSetString(0, prefix + "Drawdown", OBJPROP_TEXT, 
                   "Drawdown: " + DoubleToString(drawdown, 2) + "%");
   ObjectSetInteger(0, prefix + "Drawdown", OBJPROP_COLOR, ddColor);
}

//+------------------------------------------------------------------+
//| Delete UI Panel                                                   |
//+------------------------------------------------------------------+
void DeleteUIPanel()
{
   string prefix = "TORAMA_UI_";
   
   ObjectDelete(0, prefix + "BG");
   ObjectDelete(0, prefix + "Title");
   ObjectDelete(0, prefix + "Status");
   ObjectDelete(0, prefix + "Spread");
   ObjectDelete(0, prefix + "Gap");
   ObjectDelete(0, prefix + "Price");
   ObjectDelete(0, prefix + "NextLevel");
   ObjectDelete(0, prefix + "GridFilled");
   ObjectDelete(0, prefix + "LotPosition");
   ObjectDelete(0, prefix + "Balance");
   ObjectDelete(0, prefix + "Equity");
   ObjectDelete(0, prefix + "PL");
   ObjectDelete(0, prefix + "Drawdown");
   ObjectDelete(0, prefix + "Brand");
   ObjectDelete(0, prefix + "Email");
}
//+------------------------------------------------------------------+
