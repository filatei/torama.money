//+------------------------------------------------------------------+
//|                                       TORAMA_Boom1000_Grid.mq5   |
//|                                Copyright 2025, TORAMA CAPITAL    |
//|                                     https://toramacapital.com    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, TORAMA CAPITAL"
#property link      "https://toramacapital.com"
#property version   "1.00"
#property description "Adaptive Grid EA optimized for Boom 1000 Index"
#property description "Features: Spike Detection, Grid Trading, Daily Target"

//+------------------------------------------------------------------+
//| Includes                                                          |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "=== GRID SETTINGS ==="
input double   InpLotSize           = 0.01;     // Lot Size (Fixed)
input int      InpGridSpacing       = 100;      // Grid Spacing (Points)
input int      InpMaxGridLevels     = 8;        // Maximum Grid Levels
input double   InpBasketTP_Points   = 500;      // Basket Take Profit (Points)

input group "=== RISK MANAGEMENT ==="
input double   InpMaxDrawdownPct    = 20.0;     // Max Drawdown % (Hard Stop)
input double   InpDailyTargetPct    = 10.0;     // Daily Profit Target %
input double   InpMaxDailyLossPct   = 10.0;     // Max Daily Loss %

input group "=== SPIKE DETECTION ==="
input int      InpSpikeLookback     = 3;        // Spike Detection Bars
input double   InpSpikeMultiplier   = 3.0;      // Spike Size Multiplier (vs ATR)
input int      InpATRPeriod         = 14;       // ATR Period for Spike Detection

input group "=== TRADING SETTINGS ==="
input int      InpMagicNumber       = 100100;   // Magic Number
input int      InpSlippage          = 50;       // Max Slippage (Points)
input string   InpComment           = "TORAMA_B1000"; // Order Comment

input group "=== PANEL SETTINGS ==="
input int      InpPanelX            = 20;       // Panel X Position
input int      InpPanelY            = 50;       // Panel Y Position
input color    InpPanelBG           = C'25,25,35';     // Panel Background
input color    InpPanelBorder       = C'65,105,225';   // Panel Border
input color    InpTextColor         = clrWhite;        // Text Color
input color    InpProfitColor       = clrLime;         // Profit Color
input color    InpLossColor         = clrOrangeRed;    // Loss Color

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CAccountInfo   accInfo;

// Grid tracking
double         g_gridLevels[];
bool           g_levelFilled[];
int            g_activeOrders;
double         g_lowestEntry;
double         g_highestEntry;

// State management
bool           g_isPaused          = false;
bool           g_dailyTargetHit    = false;
bool           g_maxDrawdownHit    = false;
datetime       g_lastTradeDay      = 0;
double         g_dayStartBalance   = 0;
double         g_dailyPnL          = 0;
double         g_peakBalance       = 0;

// Spike detection
bool           g_spikeDetected     = false;
datetime       g_lastSpikeTime     = 0;

// Panel objects
string         g_panelPrefix       = "TORAMA_B1000_";
int            g_panelWidth        = 280;
int            g_panelHeight       = 420;

// Button states
bool           g_btnPauseState     = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validate symbol
   if(StringFind(_Symbol, "Boom 1000") < 0 && StringFind(_Symbol, "Boom1000") < 0)
   {
      Print("WARNING: This EA is optimized for Boom 1000 Index!");
   }
   
   // Initialize trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetAsyncMode(false);
   
   // Initialize arrays
   ArrayResize(g_gridLevels, InpMaxGridLevels);
   ArrayResize(g_levelFilled, InpMaxGridLevels);
   ArrayFree(g_gridLevels);
   ArrayFree(g_levelFilled);
   ArrayResize(g_gridLevels, InpMaxGridLevels);
   ArrayResize(g_levelFilled, InpMaxGridLevels);
   
   for(int i = 0; i < InpMaxGridLevels; i++)
   {
      g_gridLevels[i] = 0;
      g_levelFilled[i] = false;
   }
   
   // Initialize state
   g_dayStartBalance = accInfo.Balance();
   g_peakBalance = accInfo.Equity();
   g_lastTradeDay = iTime(_Symbol, PERIOD_D1, 0);
   
   // Create panel
   CreatePanel();
   
   // Check existing positions
   CountPositions();
   
   Print("TORAMA Boom 1000 Grid EA initialized successfully");
   Print("Account Balance: ", DoubleToString(accInfo.Balance(), 2));
   Print("Daily Target: ", DoubleToString(InpDailyTargetPct), "%");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Remove panel objects
   ObjectsDeleteAll(0, g_panelPrefix);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Check for new day
   CheckNewDay();
   
   // Update daily P&L
   UpdateDailyPnL();
   
   // Check drawdown
   CheckDrawdown();
   
   // Update panel
   UpdatePanel();
   
   // Check if trading allowed
   if(g_isPaused || g_dailyTargetHit || g_maxDrawdownHit)
      return;
   
   // Detect spikes
   DetectSpike();
   
   // Manage grid
   ManageGrid();
   
   // Check basket profit
   CheckBasketProfit();
}

//+------------------------------------------------------------------+
//| Chart event handler                                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      // Pause/Resume button
      if(sparam == g_panelPrefix + "BtnPause")
      {
         g_isPaused = !g_isPaused;
         UpdateButtonState("BtnPause", g_isPaused ? "▶ RESUME" : "⏸ PAUSE", 
                          g_isPaused ? clrOrange : C'50,50,70');
         Print(g_isPaused ? "EA Paused" : "EA Resumed");
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      }
      
      // Close All button
      if(sparam == g_panelPrefix + "BtnCloseAll")
      {
         CloseAllPositions();
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      }
      
      // Take Profit button
      if(sparam == g_panelPrefix + "BtnTakeTP")
      {
         if(GetTotalProfit() > 0)
         {
            CloseAllPositions();
            Print("Manual Take Profit executed");
         }
         else
         {
            Print("No profit to take");
         }
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      }
      
      // Reset Daily button
      if(sparam == g_panelPrefix + "BtnResetDaily")
      {
         g_dailyTargetHit = false;
         g_dayStartBalance = accInfo.Balance();
         g_dailyPnL = 0;
         Print("Daily counters reset");
         ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      }
   }
}

//+------------------------------------------------------------------+
//| Create Panel                                                      |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = InpPanelX;
   int y = InpPanelY;
   
   // Main panel background
   CreateRectangle(g_panelPrefix + "BG", x, y, g_panelWidth, g_panelHeight, InpPanelBG, InpPanelBorder);
   
   // Header
   CreateRectangle(g_panelPrefix + "Header", x, y, g_panelWidth, 45, InpPanelBorder, InpPanelBorder);
   CreateLabel(g_panelPrefix + "Title", x + 10, y + 8, "TORAMA CAPITAL", InpTextColor, 12, "Arial Bold");
   CreateLabel(g_panelPrefix + "Subtitle", x + 10, y + 26, "Boom 1000 Grid EA v1.0", C'180,180,180', 9, "Arial");
   
   int row = y + 55;
   int labelX = x + 15;
   int valueX = x + 150;
   int rowHeight = 22;
   
   // Account Info Section
   CreateLabel(g_panelPrefix + "SecAccount", labelX, row, "─── ACCOUNT ───", InpPanelBorder, 9, "Arial Bold");
   row += rowHeight;
   
   CreateLabel(g_panelPrefix + "LblBalance", labelX, row, "Balance:", InpTextColor, 10, "Arial");
   CreateLabel(g_panelPrefix + "ValBalance", valueX, row, "0.00", InpTextColor, 10, "Arial Bold");
   row += rowHeight;
   
   CreateLabel(g_panelPrefix + "LblEquity", labelX, row, "Equity:", InpTextColor, 10, "Arial");
   CreateLabel(g_panelPrefix + "ValEquity", valueX, row, "0.00", InpTextColor, 10, "Arial Bold");
   row += rowHeight;
   
   CreateLabel(g_panelPrefix + "LblDailyPnL", labelX, row, "Daily P&L:", InpTextColor, 10, "Arial");
   CreateLabel(g_panelPrefix + "ValDailyPnL", valueX, row, "0.00", InpProfitColor, 10, "Arial Bold");
   row += rowHeight;
   
   CreateLabel(g_panelPrefix + "LblDailyPct", labelX, row, "Daily %:", InpTextColor, 10, "Arial");
   CreateLabel(g_panelPrefix + "ValDailyPct", valueX, row, "0.00%", InpTextColor, 10, "Arial Bold");
   row += rowHeight + 5;
   
   // Grid Info Section
   CreateLabel(g_panelPrefix + "SecGrid", labelX, row, "─── GRID STATUS ───", InpPanelBorder, 9, "Arial Bold");
   row += rowHeight;
   
   CreateLabel(g_panelPrefix + "LblPositions", labelX, row, "Positions:", InpTextColor, 10, "Arial");
   CreateLabel(g_panelPrefix + "ValPositions", valueX, row, "0 / " + IntegerToString(InpMaxGridLevels), InpTextColor, 10, "Arial Bold");
   row += rowHeight;
   
   CreateLabel(g_panelPrefix + "LblFloating", labelX, row, "Floating P&L:", InpTextColor, 10, "Arial");
   CreateLabel(g_panelPrefix + "ValFloating", valueX, row, "0.00", InpTextColor, 10, "Arial Bold");
   row += rowHeight;
   
   CreateLabel(g_panelPrefix + "LblAvgPrice", labelX, row, "Avg Entry:", InpTextColor, 10, "Arial");
   CreateLabel(g_panelPrefix + "ValAvgPrice", valueX, row, "0.00", InpTextColor, 10, "Arial Bold");
   row += rowHeight;
   
   CreateLabel(g_panelPrefix + "LblTotalLots", labelX, row, "Total Lots:", InpTextColor, 10, "Arial");
   CreateLabel(g_panelPrefix + "ValTotalLots", valueX, row, "0.00", InpTextColor, 10, "Arial Bold");
   row += rowHeight + 5;
   
   // Status Section
   CreateLabel(g_panelPrefix + "SecStatus", labelX, row, "─── STATUS ───", InpPanelBorder, 9, "Arial Bold");
   row += rowHeight;
   
   CreateLabel(g_panelPrefix + "LblStatus", labelX, row, "Status:", InpTextColor, 10, "Arial");
   CreateLabel(g_panelPrefix + "ValStatus", valueX, row, "RUNNING", clrLime, 10, "Arial Bold");
   row += rowHeight;
   
   CreateLabel(g_panelPrefix + "LblSpike", labelX, row, "Last Spike:", InpTextColor, 10, "Arial");
   CreateLabel(g_panelPrefix + "ValSpike", valueX, row, "None", C'180,180,180', 10, "Arial Bold");
   row += rowHeight;
   
   CreateLabel(g_panelPrefix + "LblDrawdown", labelX, row, "Drawdown:", InpTextColor, 10, "Arial");
   CreateLabel(g_panelPrefix + "ValDrawdown", valueX, row, "0.00%", InpTextColor, 10, "Arial Bold");
   row += rowHeight + 10;
   
   // Buttons
   int btnWidth = 120;
   int btnHeight = 28;
   int btnSpacing = 10;
   
   CreateButton(g_panelPrefix + "BtnPause", x + 15, row, btnWidth, btnHeight, "⏸ PAUSE", C'50,50,70', InpTextColor);
   CreateButton(g_panelPrefix + "BtnCloseAll", x + 15 + btnWidth + btnSpacing, row, btnWidth, btnHeight, "✖ CLOSE ALL", C'139,0,0', InpTextColor);
   row += btnHeight + 8;
   
   CreateButton(g_panelPrefix + "BtnTakeTP", x + 15, row, btnWidth, btnHeight, "💰 TAKE TP", C'0,100,0', InpTextColor);
   CreateButton(g_panelPrefix + "BtnResetDaily", x + 15 + btnWidth + btnSpacing, row, btnWidth, btnHeight, "🔄 RESET DAY", C'70,70,50', InpTextColor);
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Create Rectangle                                                  |
//+------------------------------------------------------------------+
void CreateRectangle(string name, int x, int y, int width, int height, color bgColor, color borderColor)
{
   ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, borderColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_BACK, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Create Label                                                      |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, string font)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
   ObjectSetString(0, name, OBJPROP_FONT, font);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Create Button                                                     |
//+------------------------------------------------------------------+
void CreateButton(string name, int x, int y, int width, int height, string text, color bgColor, color textColor)
{
   ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE, width);
   ObjectSetInteger(0, name, OBJPROP_YSIZE, height);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
   ObjectSetInteger(0, name, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrGray);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
   ObjectSetString(0, name, OBJPROP_FONT, "Arial Bold");
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| Update Button State                                               |
//+------------------------------------------------------------------+
void UpdateButtonState(string btnName, string text, color bgColor)
{
   string name = g_panelPrefix + btnName;
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bgColor);
}

//+------------------------------------------------------------------+
//| Update Panel                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   double balance = accInfo.Balance();
   double equity = accInfo.Equity();
   double floatingPnL = GetTotalProfit();
   double dailyPct = g_dayStartBalance > 0 ? (g_dailyPnL / g_dayStartBalance) * 100 : 0;
   int posCount = CountPositions();
   double avgPrice = GetAverageEntryPrice();
   double totalLots = GetTotalLots();
   double drawdownPct = g_peakBalance > 0 ? ((g_peakBalance - equity) / g_peakBalance) * 100 : 0;
   
   // Update values
   ObjectSetString(0, g_panelPrefix + "ValBalance", OBJPROP_TEXT, DoubleToString(balance, 2));
   ObjectSetString(0, g_panelPrefix + "ValEquity", OBJPROP_TEXT, DoubleToString(equity, 2));
   
   ObjectSetString(0, g_panelPrefix + "ValDailyPnL", OBJPROP_TEXT, 
                   (g_dailyPnL >= 0 ? "+" : "") + DoubleToString(g_dailyPnL, 2));
   ObjectSetInteger(0, g_panelPrefix + "ValDailyPnL", OBJPROP_COLOR, 
                    g_dailyPnL >= 0 ? InpProfitColor : InpLossColor);
   
   ObjectSetString(0, g_panelPrefix + "ValDailyPct", OBJPROP_TEXT, 
                   (dailyPct >= 0 ? "+" : "") + DoubleToString(dailyPct, 2) + "%");
   ObjectSetInteger(0, g_panelPrefix + "ValDailyPct", OBJPROP_COLOR, 
                    dailyPct >= 0 ? InpProfitColor : InpLossColor);
   
   ObjectSetString(0, g_panelPrefix + "ValPositions", OBJPROP_TEXT, 
                   IntegerToString(posCount) + " / " + IntegerToString(InpMaxGridLevels));
   
   ObjectSetString(0, g_panelPrefix + "ValFloating", OBJPROP_TEXT, 
                   (floatingPnL >= 0 ? "+" : "") + DoubleToString(floatingPnL, 2));
   ObjectSetInteger(0, g_panelPrefix + "ValFloating", OBJPROP_COLOR, 
                    floatingPnL >= 0 ? InpProfitColor : InpLossColor);
   
   ObjectSetString(0, g_panelPrefix + "ValAvgPrice", OBJPROP_TEXT, 
                   avgPrice > 0 ? DoubleToString(avgPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) : "---");
   
   ObjectSetString(0, g_panelPrefix + "ValTotalLots", OBJPROP_TEXT, DoubleToString(totalLots, 2));
   
   // Status
   string statusText = "RUNNING";
   color statusColor = clrLime;
   
   if(g_isPaused)
   {
      statusText = "PAUSED";
      statusColor = clrOrange;
   }
   else if(g_dailyTargetHit)
   {
      statusText = "TARGET HIT";
      statusColor = clrGold;
   }
   else if(g_maxDrawdownHit)
   {
      statusText = "DD STOP";
      statusColor = clrRed;
   }
   
   ObjectSetString(0, g_panelPrefix + "ValStatus", OBJPROP_TEXT, statusText);
   ObjectSetInteger(0, g_panelPrefix + "ValStatus", OBJPROP_COLOR, statusColor);
   
   // Spike info
   if(g_lastSpikeTime > 0)
   {
      int secAgo = (int)(TimeCurrent() - g_lastSpikeTime);
      string spikeText = secAgo < 60 ? IntegerToString(secAgo) + "s ago" : 
                         IntegerToString(secAgo / 60) + "m ago";
      ObjectSetString(0, g_panelPrefix + "ValSpike", OBJPROP_TEXT, spikeText);
      ObjectSetInteger(0, g_panelPrefix + "ValSpike", OBJPROP_COLOR, clrGold);
   }
   
   // Drawdown
   ObjectSetString(0, g_panelPrefix + "ValDrawdown", OBJPROP_TEXT, DoubleToString(drawdownPct, 2) + "%");
   ObjectSetInteger(0, g_panelPrefix + "ValDrawdown", OBJPROP_COLOR, 
                    drawdownPct > 10 ? InpLossColor : (drawdownPct > 5 ? clrOrange : InpTextColor));
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| Check for New Trading Day                                         |
//+------------------------------------------------------------------+
void CheckNewDay()
{
   datetime currentDay = iTime(_Symbol, PERIOD_D1, 0);
   
   if(currentDay != g_lastTradeDay)
   {
      g_lastTradeDay = currentDay;
      g_dayStartBalance = accInfo.Balance();
      g_dailyPnL = 0;
      g_dailyTargetHit = false;
      
      Print("New trading day started. Balance: ", DoubleToString(g_dayStartBalance, 2));
   }
}

//+------------------------------------------------------------------+
//| Update Daily P&L                                                  |
//+------------------------------------------------------------------+
void UpdateDailyPnL()
{
   double currentEquity = accInfo.Equity();
   g_dailyPnL = currentEquity - g_dayStartBalance;
   
   // Update peak balance
   if(currentEquity > g_peakBalance)
      g_peakBalance = currentEquity;
   
   // Check daily target
   double dailyPct = (g_dailyPnL / g_dayStartBalance) * 100;
   
   if(dailyPct >= InpDailyTargetPct && !g_dailyTargetHit)
   {
      g_dailyTargetHit = true;
      Print("Daily target reached! Profit: ", DoubleToString(g_dailyPnL, 2), 
            " (", DoubleToString(dailyPct, 2), "%)");
      
      // Close all positions when target hit
      CloseAllPositions();
   }
   
   // Check daily loss limit
   if(dailyPct <= -InpMaxDailyLossPct)
   {
      Print("Daily loss limit reached! Loss: ", DoubleToString(g_dailyPnL, 2));
      CloseAllPositions();
      g_isPaused = true;
   }
}

//+------------------------------------------------------------------+
//| Check Drawdown                                                    |
//+------------------------------------------------------------------+
void CheckDrawdown()
{
   double equity = accInfo.Equity();
   double balance = accInfo.Balance();
   
   double drawdownPct = ((balance - equity) / balance) * 100;
   
   if(drawdownPct >= InpMaxDrawdownPct && !g_maxDrawdownHit)
   {
      g_maxDrawdownHit = true;
      Print("Max drawdown hit! Closing all positions. DD: ", DoubleToString(drawdownPct, 2), "%");
      CloseAllPositions();
   }
}

//+------------------------------------------------------------------+
//| Detect Price Spike                                                |
//+------------------------------------------------------------------+
void DetectSpike()
{
   double atr = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
   if(atr == 0) return;
   
   // Get handle and value
   int atrHandle = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
   if(atrHandle == INVALID_HANDLE) return;
   
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(atrHandle, 0, 0, 1, atrBuffer) <= 0)
   {
      IndicatorRelease(atrHandle);
      return;
   }
   
   double atrValue = atrBuffer[0];
   IndicatorRelease(atrHandle);
   
   // Check recent candles for spike
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   
   if(CopyRates(_Symbol, PERIOD_M1, 0, InpSpikeLookback + 1, rates) <= 0)
      return;
   
   // Look for bullish spike
   for(int i = 0; i < InpSpikeLookback; i++)
   {
      double candleSize = rates[i].close - rates[i].open;
      
      if(candleSize > atrValue * InpSpikeMultiplier)
      {
         // Spike detected
         if(rates[i].time > g_lastSpikeTime)
         {
            g_spikeDetected = true;
            g_lastSpikeTime = rates[i].time;
            
            Print("SPIKE DETECTED! Size: ", DoubleToString(candleSize, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
            
            // Check if we should take profit on spike
            double profit = GetTotalProfit();
            if(profit > 0 && CountPositions() > 0)
            {
               Print("Closing positions on spike with profit: ", DoubleToString(profit, 2));
               CloseAllPositions();
            }
         }
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Grid                                                       |
//+------------------------------------------------------------------+
void ManageGrid()
{
   int currentPositions = CountPositions();
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Initialize grid if no positions
   if(currentPositions == 0)
   {
      // Reset grid tracking
      g_lowestEntry = 0;
      g_highestEntry = 0;
      
      // Place first buy order
      if(OpenBuyOrder(InpLotSize))
      {
         g_lowestEntry = currentPrice;
         g_highestEntry = currentPrice;
         Print("Grid initialized at price: ", DoubleToString(currentPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
      }
      return;
   }
   
   // Check if we need to add grid level
   if(currentPositions < InpMaxGridLevels)
   {
      // Update lowest entry if needed
      if(g_lowestEntry == 0)
      {
         g_lowestEntry = GetLowestEntryPrice();
      }
      
      double gridSpacingPrice = InpGridSpacing * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      double nextGridLevel = g_lowestEntry - gridSpacingPrice;
      
      // Check if price has reached next grid level
      if(currentPrice <= nextGridLevel)
      {
         if(OpenBuyOrder(InpLotSize))
         {
            g_lowestEntry = currentPrice;
            Print("Grid level added at: ", DoubleToString(currentPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
                  " Total positions: ", currentPositions + 1);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check Basket Profit                                               |
//+------------------------------------------------------------------+
void CheckBasketProfit()
{
   int positions = CountPositions();
   if(positions == 0) return;
   
   double totalProfit = GetTotalProfit();
   double avgEntry = GetAverageEntryPrice();
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // Calculate basket TP in price terms
   double tpPrice = avgEntry + (InpBasketTP_Points * SymbolInfoDouble(_Symbol, SYMBOL_POINT));
   
   // Check if basket TP reached
   if(currentPrice >= tpPrice)
   {
      Print("Basket Take Profit reached! Profit: ", DoubleToString(totalProfit, 2));
      CloseAllPositions();
   }
}

//+------------------------------------------------------------------+
//| Open Buy Order                                                    |
//+------------------------------------------------------------------+
bool OpenBuyOrder(double lots)
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   // Normalize lot size
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = NormalizeDouble(MathRound(lots / lotStep) * lotStep, 2);
   
   if(trade.Buy(lots, _Symbol, price, 0, 0, InpComment))
   {
      Print("Buy order opened: ", lots, " lots at ", DoubleToString(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
      return true;
   }
   else
   {
      Print("Failed to open buy order. Error: ", GetLastError());
      return false;
   }
}

//+------------------------------------------------------------------+
//| Close All Positions                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   int total = PositionsTotal();
   
   for(int i = total - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         {
            trade.PositionClose(posInfo.Ticket());
         }
      }
   }
   
   // Reset grid tracking
   g_lowestEntry = 0;
   g_highestEntry = 0;
   
   Print("All positions closed");
}

//+------------------------------------------------------------------+
//| Count Positions                                                   |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   int total = PositionsTotal();
   
   for(int i = 0; i < total; i++)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         {
            count++;
         }
      }
   }
   
   return count;
}

//+------------------------------------------------------------------+
//| Get Total Profit                                                  |
//+------------------------------------------------------------------+
double GetTotalProfit()
{
   double profit = 0;
   int total = PositionsTotal();
   
   for(int i = 0; i < total; i++)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         {
            profit += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
         }
      }
   }
   
   return profit;
}

//+------------------------------------------------------------------+
//| Get Average Entry Price                                           |
//+------------------------------------------------------------------+
double GetAverageEntryPrice()
{
   double totalPrice = 0;
   double totalLots = 0;
   int total = PositionsTotal();
   
   for(int i = 0; i < total; i++)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         {
            totalPrice += posInfo.PriceOpen() * posInfo.Volume();
            totalLots += posInfo.Volume();
         }
      }
   }
   
   return totalLots > 0 ? totalPrice / totalLots : 0;
}

//+------------------------------------------------------------------+
//| Get Lowest Entry Price                                            |
//+------------------------------------------------------------------+
double GetLowestEntryPrice()
{
   double lowestPrice = DBL_MAX;
   int total = PositionsTotal();
   
   for(int i = 0; i < total; i++)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         {
            if(posInfo.PriceOpen() < lowestPrice)
               lowestPrice = posInfo.PriceOpen();
         }
      }
   }
   
   return lowestPrice == DBL_MAX ? 0 : lowestPrice;
}

//+------------------------------------------------------------------+
//| Get Total Lots                                                    |
//+------------------------------------------------------------------+
double GetTotalLots()
{
   double totalLots = 0;
   int total = PositionsTotal();
   
   for(int i = 0; i < total; i++)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         {
            totalLots += posInfo.Volume();
         }
      }
   }
   
   return totalLots;
}
//+------------------------------------------------------------------+
