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
input double   InpTPPercent = 80.0;             // Take Profit (% of gap)
input double   InpSLPercent = 150.0;            // Stop Loss (% of gap)

input group "=== Risk Management ==="
input double   InpLotSize = 0.01;               // Lot Size
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
int gridDirection = 0; // 1 = Buy up, -1 = Sell down, 0 = Not activated
int gridLevelsFilled = 0;
double initialBalance = 0.0;
double peakEquity = 0.0;

//--- Grid tracking
double gridLevels[];
bool levelTriggered[];

//--- UI Variables
int panelX = 20;
int panelY = 30;
int panelWidth = 280;
int panelHeight = 320;

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
   
   // Initialize arrays
   ArrayResize(gridLevels, InpGridLevels);
   ArrayResize(levelTriggered, InpGridLevels);
   ArrayInitialize(levelTriggered, false);
   
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
//| Calculate grid levels based on reference price                   |
//+------------------------------------------------------------------+
void CalculateGridLevels()
{
   double gapDollar = GetGapInDollars();
   
   for(int i = 0; i < InpGridLevels; i++)
   {
      // Calculate levels both above and below reference
      gridLevels[i] = referencePrice + (gapDollar * (i + 1));
   }
}

//+------------------------------------------------------------------+
//| Check if first grid level is triggered                           |
//+------------------------------------------------------------------+
void CheckFirstGridTrigger(double currentPrice)
{
   double gapDollar = GetGapInDollars();
   double firstBuyLevel = referencePrice + gapDollar;
   double firstSellLevel = referencePrice - gapDollar;
   
   // Check for buy trigger (price moved up)
   if(currentPrice >= firstBuyLevel)
   {
      gridActivated = true;
      gridDirection = 1; // Buy up
      referencePrice = firstBuyLevel; // Update reference
      CalculateGridLevels(); // Recalculate from new reference
      
      // Open first buy trade
      OpenGridTrade(ORDER_TYPE_BUY, 0);
      levelTriggered[0] = true;
      gridLevelsFilled = 1;
      
      Print("Grid activated - BUY direction at price: ", firstBuyLevel);
   }
   // Check for sell trigger (price moved down)
   else if(currentPrice <= firstSellLevel)
   {
      gridActivated = true;
      gridDirection = -1; // Sell down
      referencePrice = firstSellLevel; // Update reference
      CalculateGridLevels(); // Recalculate from new reference (downward)
      
      // Open first sell trade
      OpenGridTrade(ORDER_TYPE_SELL, 0);
      levelTriggered[0] = true;
      gridLevelsFilled = 1;
      
      Print("Grid activated - SELL direction at price: ", firstSellLevel);
   }
}

//+------------------------------------------------------------------+
//| Check grid level triggers                                         |
//+------------------------------------------------------------------+
void CheckGridLevelTriggers(double currentPrice)
{
   if(gridLevelsFilled >= InpGridLevels) return; // All levels filled
   
   double gapDollar = GetGapInDollars();
   
   if(gridDirection == 1) // Buy up
   {
      double nextLevel = referencePrice + (gapDollar * (gridLevelsFilled + 1));
      
      if(currentPrice >= nextLevel && !levelTriggered[gridLevelsFilled])
      {
         OpenGridTrade(ORDER_TYPE_BUY, gridLevelsFilled);
         levelTriggered[gridLevelsFilled] = true;
         gridLevelsFilled++;
         Print("Buy grid level ", gridLevelsFilled, " triggered at: ", nextLevel);
      }
   }
   else if(gridDirection == -1) // Sell down
   {
      double nextLevel = referencePrice - (gapDollar * (gridLevelsFilled + 1));
      
      if(currentPrice <= nextLevel && !levelTriggered[gridLevelsFilled])
      {
         OpenGridTrade(ORDER_TYPE_SELL, gridLevelsFilled);
         levelTriggered[gridLevelsFilled] = true;
         gridLevelsFilled++;
         Print("Sell grid level ", gridLevelsFilled, " triggered at: ", nextLevel);
      }
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
   
   double gapDollar = GetGapInDollars();
   double tpDistance = gapDollar * (InpTPPercent / 100.0);
   double slDistance = gapDollar * (InpSLPercent / 100.0);
   
   double tp = 0.0;
   double sl = 0.0;
   
   if(orderType == ORDER_TYPE_BUY)
   {
      tp = price + tpDistance;
      sl = price - slDistance;
   }
   else
   {
      tp = price - tpDistance;
      sl = price + slDistance;
   }
   
   // Normalize prices
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   tp = NormalizeDouble(tp, digits);
   sl = NormalizeDouble(sl, digits);
   
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
            " TP: ", tp,
            " SL: ", sl);
   }
   else
   {
      Print("Failed to open trade. Error: ", GetLastError());
   }
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
               panelX + 10, panelY + 10, clrGold, 10, true);
   
   // Stats labels
   int yPos = panelY + 40;
   int lineHeight = 22;
   
   CreateLabel(prefix + "Status", "Status: Waiting", panelX + 10, yPos, clrWhite, 8, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "Spread", "Spread: 0", panelX + 10, yPos, clrWhite, 8, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "Gap", "Gap: 0.00%", panelX + 10, yPos, clrWhite, 8, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "GapDollar", "Gap $: 0.00", panelX + 10, yPos, clrWhite, 8, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "GridFilled", "Grid Filled: 0/" + IntegerToString(InpGridLevels), 
               panelX + 10, yPos, clrWhite, 8, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "Balance", "Balance: $0.00", panelX + 10, yPos, clrLime, 8, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "Equity", "Equity: $0.00", panelX + 10, yPos, clrAqua, 8, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "PL", "P/L: $0.00", panelX + 10, yPos, clrWhite, 8, false);
   yPos += lineHeight;
   
   CreateLabel(prefix + "Drawdown", "Drawdown: 0.00%", panelX + 10, yPos, clrWhite, 8, false);
   yPos += lineHeight;
   
   // Branding
   CreateLabel(prefix + "Brand", "TORAMA CAPITAL", 
               panelX + panelWidth - 125, panelY + panelHeight - 35, clrGold, 9, true);
   CreateLabel(prefix + "Email", "ea@torama.money", 
               panelX + panelWidth - 110, panelY + panelHeight - 18, clrGold, 7, false);
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
   
   // Status
   string status = isPaused ? "PAUSED" : (gridActivated ? (gridDirection == 1 ? "BUY UP" : "SELL DOWN") : "Waiting");
   color statusColor = isPaused ? clrRed : (gridActivated ? clrLime : clrYellow);
   ObjectSetString(0, prefix + "Status", OBJPROP_TEXT, "Status: " + status);
   ObjectSetInteger(0, prefix + "Status", OBJPROP_COLOR, statusColor);
   
   // Spread
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   color spreadColor = (spread > InpSpreadPoints) ? clrRed : clrLime;
   ObjectSetString(0, prefix + "Spread", OBJPROP_TEXT, "Spread: " + IntegerToString(spread));
   ObjectSetInteger(0, prefix + "Spread", OBJPROP_COLOR, spreadColor);
   
   // Gap
   double gapPercent = InpGapPercent;
   ObjectSetString(0, prefix + "Gap", OBJPROP_TEXT, 
                   "Gap: " + DoubleToString(gapPercent, 2) + "%");
   
   // Gap in dollars
   double gapDollar = GetGapInDollars();
   ObjectSetString(0, prefix + "GapDollar", OBJPROP_TEXT, 
                   "Gap $: " + DoubleToString(gapDollar, 2));
   
   // Grid filled
   ObjectSetString(0, prefix + "GridFilled", OBJPROP_TEXT, 
                   "Grid Filled: " + IntegerToString(gridLevelsFilled) + "/" + IntegerToString(InpGridLevels));
   
   // Balance
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   ObjectSetString(0, prefix + "Balance", OBJPROP_TEXT, 
                   "Balance: $" + DoubleToString(balance, 2));
   
   // Equity
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   ObjectSetString(0, prefix + "Equity", OBJPROP_TEXT, 
                   "Equity: $" + DoubleToString(equity, 2));
   
   // P/L
   double pl = equity - balance;
   color plColor = (pl >= 0) ? clrLime : clrRed;
   ObjectSetString(0, prefix + "PL", OBJPROP_TEXT, 
                   "P/L: $" + DoubleToString(pl, 2));
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
   ObjectDelete(0, prefix + "GapDollar");
   ObjectDelete(0, prefix + "GridFilled");
   ObjectDelete(0, prefix + "Balance");
   ObjectDelete(0, prefix + "Equity");
   ObjectDelete(0, prefix + "PL");
   ObjectDelete(0, prefix + "Drawdown");
   ObjectDelete(0, prefix + "Brand");
   ObjectDelete(0, prefix + "Email");
}
//+------------------------------------------------------------------+
