//+------------------------------------------------------------------+
//|                                               SR_Grid_EA_V3.mq5  |
//|                                                    TORAMA CAPITAL |
//|                                              https://torama.biz   |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://money.torama.biz"
#property version   "3.00"
#property description "Universal H4 Support/Resistance Infinite Grid Trading EA"
#property description "Works on all brokers and symbols with auto-adaptation"
#property description "Features: Hedge Recovery, Martingale, Breakeven, Trailing"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| ENUMERATIONS                                                      |
//+------------------------------------------------------------------+
enum ENUM_LOT_MODE
{
   LOT_FIXED = 0,           // Fixed Lot Size
   LOT_PERCENT_BALANCE = 1, // % of Balance
   LOT_PERCENT_EQUITY = 2   // % of Equity
};

enum ENUM_MARTINGALE_MODE
{
   MARTINGALE_OFF = 0,      // Disabled
   MARTINGALE_ON_LOSS = 1,  // Multiply on Loss
   MARTINGALE_ON_GRID = 2   // Multiply per Grid Level
};

enum ENUM_RECOVERY_MODE
{
   RECOVERY_OFF = 0,        // Disabled
   RECOVERY_AVERAGE = 1,    // Average Down
   RECOVERY_HEDGE = 2,      // Hedge Recovery
   RECOVERY_MARTINGALE = 3  // Martingale Recovery
};

enum ENUM_SR_METHOD
{
   SR_MANUAL = 0,           // Manual Input
   SR_PIVOT = 1,            // Pivot Points
   SR_SWING = 2,            // Swing High/Low
   SR_ATR = 3               // ATR-Based Levels
};

enum ENUM_BIAS {BIAS_NEUTRAL, BIAS_BUY, BIAS_SELL, BIAS_BOTH};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
input group "══════════ SUPPORT & RESISTANCE ══════════"
input ENUM_SR_METHOD InpSRMethod = SR_PIVOT;  // S/R Calculation Method
input double InpR3            = 0.0;          // R3 (0=Auto)
input double InpR2            = 0.0;          // R2 (0=Auto)
input double InpR1            = 0.0;          // R1 (0=Auto)
input double InpS1            = 0.0;          // S1 (0=Auto)
input double InpS2            = 0.0;          // S2 (0=Auto)
input double InpS3            = 0.0;          // S3 (0=Auto)
input ENUM_TIMEFRAMES InpSRTimeframe = PERIOD_H4; // S/R Timeframe
input int    InpLookbackBars  = 100;          // Lookback Bars for Auto S/R
input bool   InpAutoRefreshSR = true;         // Auto-refresh S/R

input group "══════════ GRID CONFIGURATION ══════════"
input double InpBaseGapPercent   = 0.3;       // Base Grid Gap (% of price)
input double InpMinGapPercent    = 0.05;      // Min Gap % (Fast Markets)
input double InpMaxGapPercent    = 1.0;       // Max Gap % (Slow Markets)
input bool   InpDynamicGap       = true;      // ATR-Based Dynamic Gap
input int    InpATRPeriod        = 14;        // ATR Period
input ENUM_TIMEFRAMES InpATRTimeframe = PERIOD_H1; // ATR Timeframe
input double InpSLPercent        = 50.0;      // Stop Loss (% of Gap)
input double InpTPPercent        = 100.0;     // Take Profit (% of Gap)
input int    InpMaxGridLevels    = 50;        // Max Grid Levels to Track

input group "══════════ LOT SIZING ══════════"
input ENUM_LOT_MODE InpLotMode   = LOT_FIXED; // Lot Size Mode
input double InpLotSize          = 0.01;      // Fixed Lot / Risk %
input double InpMaxLotSize       = 10.0;      // Maximum Lot Size
input double InpLotMultiplier    = 1.0;       // Base Lot Multiplier

input group "══════════ MARTINGALE SETTINGS ══════════"
input ENUM_MARTINGALE_MODE InpMartingaleMode = MARTINGALE_OFF; // Martingale Mode
input double InpMartingaleMultiplier = 1.5;   // Martingale Multiplier
input int    InpMartingaleMaxSteps   = 5;     // Max Martingale Steps
input bool   InpMartingaleReset      = true;  // Reset on Win

input group "══════════ HEDGE & RECOVERY ══════════"
input bool   InpAllowHedging         = false;         // Allow Hedging (if broker permits)
input double InpHedgeTriggerDD       = 10.0;          // Hedge Trigger DD %
input double InpHedgeLotMultiplier   = 1.0;           // Hedge Lot Multiplier
input ENUM_RECOVERY_MODE InpRecoveryMode = RECOVERY_OFF; // Recovery Mode
input double InpRecoveryTriggerDD    = 5.0;           // Recovery Trigger DD %
input int    InpRecoveryMaxPositions = 5;             // Max Recovery Positions

input group "══════════ BREAKEVEN & TRAILING ══════════"
input bool   InpUseBreakeven     = true;      // Enable Breakeven
input double InpBreakevenTrigger = 50.0;      // BE Trigger (% of TP distance)
input double InpBreakevenOffset  = 10.0;      // BE Offset (% of TP distance)
input bool   InpUseTrailing      = true;      // Enable Trailing Stop
input double InpTrailingTrigger  = 70.0;      // Trail Trigger (% of TP)
input double InpTrailingStep     = 20.0;      // Trail Step (% of Gap)

input group "══════════ PARTIAL CLOSE ══════════"
input bool   InpUsePartialTP     = false;     // Enable Partial Take Profit
input double InpPartialPercent   = 50.0;      // Partial Close %
input double InpPartialTrigger   = 70.0;      // Partial Trigger (% of TP)
input double InpRunnerMultiple   = 2.0;       // Runner TP Multiplier

input group "══════════ EXECUTION MODE ══════════"
input bool   InpTurboMode        = true;      // Turbo Mode (Tick-Based)
input int    InpMinSecondsBetween = 0;        // Min Seconds Between Trades
input bool   InpNewBarOnly       = false;     // Trade Only on New Bar
input int    InpMaxRetries       = 3;         // Order Retry Attempts
input int    InpRetryDelayMS     = 500;       // Retry Delay (ms)

input group "══════════ INFINITE GRID ══════════"
input bool   InpInfiniteGrid     = true;      // Enable Infinite Grid
input bool   InpCloseOldestAtMax = true;      // Close Oldest at Max Positions
input bool   InpRegenerateOnClose = true;     // Regenerate Level on Close

input group "══════════ RISK MANAGEMENT ══════════"
input double InpMaxDrawdownPct   = 20.0;      // Max Drawdown % (Capped at 20)
input int    InpMaxBuyPositions  = 10;        // Max Buy Positions
input int    InpMaxSellPositions = 10;        // Max Sell Positions
input int    InpMaxTotalPositions = 20;       // Max Total Positions
input double InpMaxDailyLossPct  = 0.0;       // Max Daily Loss % (0=Off)
input double InpMaxDailyLossAmt  = 0.0;       // Max Daily Loss $ (0=Off)
input int    InpMaxTradesPerDay  = 0;         // Max Trades/Day (0=Unlimited)
input double InpMaxSpreadPct     = 0.0;       // Max Spread % (0=No Filter)
input int    InpMaxSpreadPoints  = 0;         // Max Spread Points (0=No Filter)

input group "══════════ SESSION FILTERS ══════════"
input bool   InpUseSessionFilter = false;     // Enable Session Filter
input int    InpSessionStartHour = 8;         // Session Start (Server Hour)
input int    InpSessionEndHour   = 20;        // Session End (Server Hour)
input bool   InpTradeMonday      = true;      // Trade Monday
input bool   InpTradeTuesday     = true;      // Trade Tuesday
input bool   InpTradeWednesday   = true;      // Trade Wednesday
input bool   InpTradeThursday    = true;      // Trade Thursday
input bool   InpTradeFriday      = true;      // Trade Friday

input group "══════════ DISPLAY SETTINGS ══════════"
input bool   InpShowPanel        = true;      // Show Info Panel
input bool   InpShowSRLines      = true;      // Show S/R Lines
input bool   InpShowGridLevels   = true;      // Show Grid Levels
input color  InpResistanceColor  = clrRed;    // Resistance Color
input color  InpSupportColor     = clrLime;   // Support Color
input color  InpBuyGridColor     = clrDodgerBlue;  // Buy Grid Color
input color  InpSellGridColor    = clrOrange; // Sell Grid Color
input color  InpPanelBgColor     = C'20,20,35'; // Panel Background
input color  InpPanelTextColor   = clrWhite;  // Panel Text Color

input group "══════════ SYSTEM SETTINGS ══════════"
input int    InpMagicNumber      = 30241206;  // Magic Number
input string InpOrderComment     = "TORAMA_SR"; // Order Comment Prefix

//+------------------------------------------------------------------+
//| STRUCTURES                                                        |
//+------------------------------------------------------------------+
struct BrokerSpec
{
   string   name;
   string   server;
   bool     hedgingAllowed;
   bool     fifoRule;
   string   currency;
   double   leverage;
};

struct SymbolSpec
{
   string   name;
   int      digits;
   double   point;
   double   tickSize;
   double   tickValue;
   double   minLot;
   double   maxLot;
   double   lotStep;
   int      stopLevel;
   int      freezeLevel;
   double   contractSize;
   double   marginRequired;
   bool     isCrypto;
   bool     isForex;
   bool     isMetal;
   bool     isIndex;
};

struct GridLevel
{
   double   price;
   bool     isActive;
   bool     hasPosition;
   ulong    ticket;
   datetime openTime;
   int      direction;
   double   lotSize;
   int      martingaleStep;
};

struct PositionData
{
   ulong    ticket;
   double   openPrice;
   datetime openTime;
   int      direction;
   double   volume;
   double   sl;
   double   tp;
   double   profit;
   bool     isPartialClosed;
   int      gridIndex;
};

struct TradingStats
{
   int      totalBuys;
   int      totalSells;
   int      winTrades;
   int      lossTrades;
   double   netProfit;
   double   maxDrawdownPct;
   int      consecutiveWins;
   int      consecutiveLosses;
   int      maxConsecWins;
   int      maxConsecLosses;
   int      gridRegens;
   int      breakevenMoves;
   int      trailingMoves;
   int      partialCloses;
   int      hedgeTrades;
   int      recoveryTrades;
};

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CAccountInfo   accInfo;
CSymbolInfo    symInfo;

BrokerSpec     Broker;
SymbolSpec     SymSpec;

double R1, R2, R3, S1, S2, S3;

GridLevel BuyGridLevels[];
GridLevel SellGridLevels[];

PositionData BuyPositions[];
PositionData SellPositions[];
int BuyCount = 0;
int SellCount = 0;

ENUM_BIAS CurrentBias = BIAS_NEUTRAL;
string    CurrentZone = "Initializing";
double    CurrentGap = 0;
int       CurrentMartingaleStep = 0;
bool      IsHedging = false;
bool      IsRecovering = false;

double    SessionStartEquity = 0;
double    SessionHighEquity = 0;
datetime  SessionStartTime = 0;
datetime  LastTradeTime = 0;
datetime  LastBarTime = 0;
datetime  LastDayChecked = 0;
bool      EAStopped = false;
string    StopReason = "";

int       TodayTradeCount = 0;
double    TodayPL = 0;
double    TodayStartEquity = 0;

int       ATRHandle = INVALID_HANDLE;

TradingStats Stats;

const double SACROSANCT_MAX_DD = 20.0;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!symInfo.Name(_Symbol))
   {
      Print("❌ Failed to initialize symbol");
      return INIT_FAILED;
   }
   symInfo.Refresh();
   
   GetBrokerInfo();
   GetSymbolSpec();
   ConfigureTradeObject();
   
   if(InpDynamicGap)
   {
      ATRHandle = iATR(_Symbol, InpATRTimeframe, InpATRPeriod);
      if(ATRHandle == INVALID_HANDLE)
         Print("⚠️ ATR indicator failed, using fixed gap");
   }
   
   SessionStartEquity = accInfo.Equity();
   SessionHighEquity = SessionStartEquity;
   SessionStartTime = TimeCurrent();
   TodayStartEquity = SessionStartEquity;
   
   ZeroMemory(Stats);
   
   CalculateSRLevels();
   InitializeGridLevels();
   
   if(InpShowSRLines) DrawSRLines();
   if(InpShowPanel) CreateInfoPanel();
   
   PrintInitInfo();
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(ATRHandle != INVALID_HANDLE)
      IndicatorRelease(ATRHandle);
   
   ObjectsDeleteAll(0, "SR_");
   ObjectsDeleteAll(0, "Grid_");
   ObjectsDeleteAll(0, "Panel_");
   Comment("");
   
   Print("═══════════════════════════════════════════");
   Print("   SR GRID EA V3 - FINAL STATISTICS");
   Print("═══════════════════════════════════════════");
   Print("Net Profit: $", DoubleToString(Stats.netProfit, 2));
   Print("Total Trades: ", Stats.totalBuys + Stats.totalSells);
   Print("Win Rate: ", Stats.winTrades + Stats.lossTrades > 0 ? 
         DoubleToString(Stats.winTrades * 100.0 / (Stats.winTrades + Stats.lossTrades), 1) : "0", "%");
   Print("Max Drawdown: ", DoubleToString(Stats.maxDrawdownPct, 2), "%");
   Print("Grid Regenerations: ", Stats.gridRegens);
   Print("═══════════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   symInfo.Refresh();
   symInfo.RefreshRates();
   
   CheckDailyReset();
   UpdateEquityTracking();
   
   if(EAStopped)
   {
      if(InpShowPanel) UpdateInfoPanel();
      return;
   }
   
   if(!CheckTradingConditions())
   {
      if(InpShowPanel) UpdateInfoPanel();
      return;
   }
   
   if(InpAutoRefreshSR && IsNewBar(InpSRTimeframe))
   {
      CalculateSRLevels();
      if(InpShowSRLines) DrawSRLines();
   }
   
   if(!ShouldTradeThisTick())
   {
      ProcessBreakevenAndTrailing();
      if(InpShowPanel) UpdateInfoPanel();
      return;
   }
   
   UpdateDynamicGap();
   CountAndSyncPositions();
   
   if(InpRegenerateOnClose)
      CheckAndRegenerateGridLevels();
   
   DetermineZoneAndBias();
   
   if(InpRecoveryMode != RECOVERY_OFF)
      ProcessRecovery();
   
   if(InpAllowHedging && Broker.hedgingAllowed)
      ProcessHedging();
   
   ExecuteGridTrading();
   ProcessBreakevenAndTrailing();
   
   if(InpUsePartialTP)
      ProcessPartialCloses();
   
   if(InpShowGridLevels) DrawGridLevels();
   if(InpShowPanel) UpdateInfoPanel();
}

//+------------------------------------------------------------------+
//| Trade transaction handler                                         |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dealTicket = trans.deal;
      if(dealTicket == 0) return;
      
      if(!HistoryDealSelect(dealTicket)) return;
      
      long magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);
      if(magic != InpMagicNumber) return;
      
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
      {
         double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         double commission = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         double swap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
         double totalPL = profit + commission + swap;
         
         Stats.netProfit += totalPL;
         TodayPL += totalPL;
         
         if(totalPL >= 0)
         {
            Stats.winTrades++;
            Stats.consecutiveWins++;
            Stats.consecutiveLosses = 0;
            Stats.maxConsecWins = MathMax(Stats.maxConsecWins, Stats.consecutiveWins);
            
            if(InpMartingaleReset)
               CurrentMartingaleStep = 0;
         }
         else
         {
            Stats.lossTrades++;
            Stats.consecutiveLosses++;
            Stats.consecutiveWins = 0;
            Stats.maxConsecLosses = MathMax(Stats.maxConsecLosses, Stats.consecutiveLosses);
            
            if(InpMartingaleMode == MARTINGALE_ON_LOSS && CurrentMartingaleStep < InpMartingaleMaxSteps)
               CurrentMartingaleStep++;
         }
         
         double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
         ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
         int direction = (dealType == DEAL_TYPE_SELL) ? 1 : -1;
         MarkGridLevelClosed(closePrice, direction);
      }
   }
}

//+------------------------------------------------------------------+
//| Get Broker Information                                            |
//+------------------------------------------------------------------+
void GetBrokerInfo()
{
   Broker.name = AccountInfoString(ACCOUNT_COMPANY);
   Broker.server = AccountInfoString(ACCOUNT_SERVER);
   Broker.currency = AccountInfoString(ACCOUNT_CURRENCY);
   Broker.leverage = (double)AccountInfoInteger(ACCOUNT_LEVERAGE);
   
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   Broker.hedgingAllowed = (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   Broker.fifoRule = !Broker.hedgingAllowed;
   
   Print("═══════════════════════════════════════════");
   Print("   BROKER: ", Broker.name);
   Print("   SERVER: ", Broker.server);
   Print("   LEVERAGE: 1:", (int)Broker.leverage);
   Print("   HEDGING: ", Broker.hedgingAllowed ? "ALLOWED" : "NOT ALLOWED");
   Print("═══════════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| Get Symbol Specifications                                         |
//+------------------------------------------------------------------+
void GetSymbolSpec()
{
   SymSpec.name = _Symbol;
   SymSpec.digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   SymSpec.point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   SymSpec.tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   SymSpec.tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   SymSpec.minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   SymSpec.maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   SymSpec.lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   SymSpec.stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   SymSpec.freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   SymSpec.contractSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 1.0, symInfo.Ask(), SymSpec.marginRequired))
      SymSpec.marginRequired = 1000;
   
   string symLower = _Symbol;
   StringToLower(symLower);
   
   SymSpec.isCrypto = (StringFind(symLower, "btc") >= 0 || StringFind(symLower, "eth") >= 0 ||
                       StringFind(symLower, "xrp") >= 0 || StringFind(symLower, "ltc") >= 0);
   SymSpec.isMetal = (StringFind(symLower, "xau") >= 0 || StringFind(symLower, "xag") >= 0 ||
                      StringFind(symLower, "gold") >= 0 || StringFind(symLower, "silver") >= 0);
   SymSpec.isIndex = (StringFind(symLower, "us30") >= 0 || StringFind(symLower, "spx") >= 0 ||
                      StringFind(symLower, "nas") >= 0 || StringFind(symLower, "dax") >= 0);
   SymSpec.isForex = (!SymSpec.isCrypto && !SymSpec.isMetal && !SymSpec.isIndex && SymSpec.digits >= 4);
   
   Print("═══════════════════════════════════════════");
   Print("   SYMBOL: ", SymSpec.name, " (", GetSymbolTypeString(), ")");
   Print("   DIGITS: ", SymSpec.digits);
   Print("   POINT: ", DoubleToString(SymSpec.point, SymSpec.digits + 2));
   Print("   LOT: ", DoubleToString(SymSpec.minLot, 2), " - ", DoubleToString(SymSpec.maxLot, 2));
   Print("   STOP LEVEL: ", SymSpec.stopLevel, " points");
   Print("   MARGIN/LOT: $", DoubleToString(SymSpec.marginRequired, 2));
   Print("═══════════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| Get symbol type as string                                         |
//+------------------------------------------------------------------+
string GetSymbolTypeString()
{
   if(SymSpec.isCrypto) return "CRYPTO";
   if(SymSpec.isMetal) return "METAL";
   if(SymSpec.isIndex) return "INDEX";
   if(SymSpec.isForex) return "FOREX";
   return "OTHER";
}

//+------------------------------------------------------------------+
//| Configure trade object                                            |
//+------------------------------------------------------------------+
void ConfigureTradeObject()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetMarginMode();
   
   // Set optimal slippage based on symbol type
   int slippage = 20;
   if(SymSpec.isCrypto) slippage = 100;
   else if(SymSpec.isMetal) slippage = 50;
   else if(SymSpec.isIndex) slippage = 30;
   
   trade.SetDeviationInPoints(slippage);
   
   // Set filling mode
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_IOC) != 0)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((filling & SYMBOL_FILLING_FOK) != 0)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

//+------------------------------------------------------------------+
//| Initialize grid levels                                            |
//+------------------------------------------------------------------+
void InitializeGridLevels()
{
   ArrayResize(BuyGridLevels, InpMaxGridLevels);
   ArrayResize(SellGridLevels, InpMaxGridLevels);
   
   for(int i = 0; i < InpMaxGridLevels; i++)
   {
      ZeroMemory(BuyGridLevels[i]);
      ZeroMemory(SellGridLevels[i]);
      BuyGridLevels[i].direction = 1;
      SellGridLevels[i].direction = -1;
   }
}

//+------------------------------------------------------------------+
//| Print initialization info                                         |
//+------------------------------------------------------------------+
void PrintInitInfo()
{
   Print("═══════════════════════════════════════════");
   Print("   SR GRID EA V3 INITIALIZED");
   Print("═══════════════════════════════════════════");
   Print("Start Equity: $", DoubleToString(SessionStartEquity, 2));
   Print("Max Drawdown: ", MathMin(InpMaxDrawdownPct, SACROSANCT_MAX_DD), "%");
   Print("Mode: ", InpTurboMode ? "TURBO" : "NORMAL");
   Print("Infinite Grid: ", InpInfiniteGrid ? "ON" : "OFF");
   Print("Martingale: ", EnumToString(InpMartingaleMode));
   Print("Recovery: ", EnumToString(InpRecoveryMode));
   Print("═══════════════════════════════════════════");
   PrintSRLevels();
}

//+------------------------------------------------------------------+
//| Print S/R Levels                                                  |
//+------------------------------------------------------------------+
void PrintSRLevels()
{
   Print("--- S/R Levels ---");
   Print("R3: ", DoubleToString(R3, SymSpec.digits));
   Print("R2: ", DoubleToString(R2, SymSpec.digits));
   Print("R1: ", DoubleToString(R1, SymSpec.digits));
   Print("S1: ", DoubleToString(S1, SymSpec.digits));
   Print("S2: ", DoubleToString(S2, SymSpec.digits));
   Print("S3: ", DoubleToString(S3, SymSpec.digits));
}

//+------------------------------------------------------------------+
//| Calculate S/R Levels                                              |
//+------------------------------------------------------------------+
void CalculateSRLevels()
{
   if(InpSRMethod == SR_MANUAL && InpR1 > 0 && InpS1 > 0)
   {
      R1 = InpR1;
      R2 = InpR2 > 0 ? InpR2 : R1 + (R1 - InpS1) * 0.618;
      R3 = InpR3 > 0 ? InpR3 : R1 + (R1 - InpS1);
      S1 = InpS1;
      S2 = InpS2 > 0 ? InpS2 : S1 - (R1 - S1) * 0.618;
      S3 = InpS3 > 0 ? InpS3 : S1 - (R1 - S1);
      return;
   }
   
   double highs[], lows[], closes[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   ArraySetAsSeries(closes, true);
   
   int copied = CopyHigh(_Symbol, InpSRTimeframe, 1, InpLookbackBars, highs);
   CopyLow(_Symbol, InpSRTimeframe, 1, InpLookbackBars, lows);
   CopyClose(_Symbol, InpSRTimeframe, 1, InpLookbackBars, closes);
   
   if(copied < 10) return;
   
   double HH = highs[ArrayMaximum(highs)];
   double LL = lows[ArrayMinimum(lows)];
   double close = closes[0];
   
   switch(InpSRMethod)
   {
      case SR_PIVOT:
      case SR_MANUAL:
      {
         double PP = (HH + LL + close) / 3.0;
         double range = HH - LL;
         R1 = 2 * PP - LL;
         R2 = PP + range;
         R3 = HH + 2 * (PP - LL);
         S1 = 2 * PP - HH;
         S2 = PP - range;
         S3 = LL - 2 * (HH - PP);
         break;
      }
      case SR_SWING:
      {
         double range = HH - LL;
         R1 = HH - range * 0.236;
         R2 = HH;
         R3 = HH + range * 0.382;
         S1 = LL + range * 0.236;
         S2 = LL;
         S3 = LL - range * 0.382;
         break;
      }
      case SR_ATR:
      {
         double atr = GetCurrentATR();
         if(atr == 0) atr = close * 0.01;
         R1 = close + atr;
         R2 = close + atr * 2;
         R3 = close + atr * 3;
         S1 = close - atr;
         S2 = close - atr * 2;
         S3 = close - atr * 3;
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| Get current ATR                                                   |
//+------------------------------------------------------------------+
double GetCurrentATR()
{
   if(ATRHandle == INVALID_HANDLE) return 0;
   
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(ATRHandle, 0, 0, 1, atr) > 0)
      return atr[0];
   return 0;
}

//+------------------------------------------------------------------+
//| Update dynamic gap                                                |
//+------------------------------------------------------------------+
void UpdateDynamicGap()
{
   double baseGap = InpBaseGapPercent;
   
   if(InpDynamicGap)
   {
      double atr = GetCurrentATR();
      if(atr > 0)
      {
         double price = symInfo.Bid();
         double atrPct = (atr / price) * 100.0;
         
         double expectedATR = 0.3;
         if(SymSpec.isCrypto) expectedATR = 2.0;
         else if(SymSpec.isMetal) expectedATR = 0.8;
         else if(SymSpec.isIndex) expectedATR = 0.6;
         
         double mult = MathMax(0.5, MathMin(2.0, atrPct / expectedATR));
         baseGap = InpBaseGapPercent * mult;
      }
   }
   
   CurrentGap = MathMax(InpMinGapPercent, MathMin(InpMaxGapPercent, baseGap));
}

//+------------------------------------------------------------------+
//| Calculate gap in price                                            |
//+------------------------------------------------------------------+
double CalculateGapPrice()
{
   return symInfo.Bid() * (CurrentGap / 100.0);
}

//+------------------------------------------------------------------+
//| Check trading conditions                                          |
//+------------------------------------------------------------------+
bool CheckTradingConditions()
{
   double ddPct = GetCurrentDrawdownPercent();
   double maxDD = MathMin(InpMaxDrawdownPct, SACROSANCT_MAX_DD);
   
   if(ddPct >= maxDD)
   {
      EmergencyCloseAll();
      EAStopped = true;
      StopReason = "Max DD " + DoubleToString(maxDD, 1) + "% reached";
      Alert("🛑 ", StopReason);
      return false;
   }
   
   if(InpMaxDailyLossPct > 0 && TodayStartEquity > 0)
   {
      double dailyDD = (-TodayPL / TodayStartEquity) * 100;
      if(dailyDD >= InpMaxDailyLossPct)
      {
         EAStopped = true;
         StopReason = "Daily loss limit";
         return false;
      }
   }
   
   if(InpMaxDailyLossAmt > 0 && TodayPL <= -InpMaxDailyLossAmt)
   {
      EAStopped = true;
      StopReason = "Daily $ limit";
      return false;
   }
   
   if(InpMaxTradesPerDay > 0 && TodayTradeCount >= InpMaxTradesPerDay)
      return false;
   
   if(InpUseSessionFilter && !IsWithinSession())
      return false;
   
   if(!IsTradingDay())
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Should trade this tick                                            |
//+------------------------------------------------------------------+
bool ShouldTradeThisTick()
{
   if(InpNewBarOnly && !IsNewBar(PERIOD_CURRENT))
      return false;
   
   if(InpMinSecondsBetween > 0 && TimeCurrent() - LastTradeTime < InpMinSecondsBetween)
      return false;
   
   if(!CheckSpreadFilter())
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Check spread filter                                               |
//+------------------------------------------------------------------+
bool CheckSpreadFilter()
{
   double spread = symInfo.Spread();
   
   if(InpMaxSpreadPoints > 0 && spread > InpMaxSpreadPoints)
      return false;
   
   if(InpMaxSpreadPct > 0)
   {
      double spreadPct = (spread * SymSpec.point / symInfo.Bid()) * 100;
      if(spreadPct > InpMaxSpreadPct)
         return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Check if within trading session                                   |
//+------------------------------------------------------------------+
bool IsWithinSession()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;
   
   if(InpSessionStartHour <= InpSessionEndHour)
      return (hour >= InpSessionStartHour && hour < InpSessionEndHour);
   else
      return (hour >= InpSessionStartHour || hour < InpSessionEndHour);
}

//+------------------------------------------------------------------+
//| Check if trading day                                              |
//+------------------------------------------------------------------+
bool IsTradingDay()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   
   switch(dt.day_of_week)
   {
      case 1: return InpTradeMonday;
      case 2: return InpTradeTuesday;
      case 3: return InpTradeWednesday;
      case 4: return InpTradeThursday;
      case 5: return InpTradeFriday;
      default: return false;
   }
}

//+------------------------------------------------------------------+
//| Check for new bar                                                 |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES tf)
{
   datetime currentBar = iTime(_Symbol, tf, 0);
   if(currentBar != LastBarTime)
   {
      LastBarTime = currentBar;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Update equity tracking                                            |
//+------------------------------------------------------------------+
void UpdateEquityTracking()
{
   double equity = accInfo.Equity();
   if(equity > SessionHighEquity)
      SessionHighEquity = equity;
   
   double ddPct = GetCurrentDrawdownPercent();
   if(ddPct > Stats.maxDrawdownPct)
      Stats.maxDrawdownPct = ddPct;
}

//+------------------------------------------------------------------+
//| Get current drawdown percent                                      |
//+------------------------------------------------------------------+
double GetCurrentDrawdownPercent()
{
   if(SessionHighEquity <= 0) return 0;
   double equity = accInfo.Equity();
   return ((SessionHighEquity - equity) / SessionHighEquity) * 100;
}

//+------------------------------------------------------------------+
//| Check daily reset                                                 |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   
   if(today != LastDayChecked)
   {
      LastDayChecked = today;
      TodayTradeCount = 0;
      TodayPL = 0;
      TodayStartEquity = accInfo.Equity();
      
      if(EAStopped && StringFind(StopReason, "Daily") >= 0)
      {
         EAStopped = false;
         StopReason = "";
         Print("📅 New day - EA resumed");
      }
   }
}

//+------------------------------------------------------------------+
//| Count and sync positions                                          |
//+------------------------------------------------------------------+
void CountAndSyncPositions()
{
   BuyCount = 0;
   SellCount = 0;
   ArrayResize(BuyPositions, 0);
   ArrayResize(SellPositions, 0);
   
   for(int i = 0; i < InpMaxGridLevels; i++)
   {
      BuyGridLevels[i].hasPosition = false;
      SellGridLevels[i].hasPosition = false;
   }
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;
      
      PositionData pd;
      pd.ticket = posInfo.Ticket();
      pd.openPrice = posInfo.PriceOpen();
      pd.openTime = posInfo.Time();
      pd.volume = posInfo.Volume();
      pd.sl = posInfo.StopLoss();
      pd.tp = posInfo.TakeProfit();
      pd.profit = posInfo.Profit();
      pd.isPartialClosed = false;
      pd.gridIndex = -1;
      
      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         pd.direction = 1;
         BuyCount++;
         int n = ArraySize(BuyPositions);
         ArrayResize(BuyPositions, n + 1);
         BuyPositions[n] = pd;
         MatchPositionToGrid(BuyGridLevels, pd);
      }
      else
      {
         pd.direction = -1;
         SellCount++;
         int n = ArraySize(SellPositions);
         ArrayResize(SellPositions, n + 1);
         SellPositions[n] = pd;
         MatchPositionToGrid(SellGridLevels, pd);
      }
   }
   
   SortPositionsByTime(BuyPositions);
   SortPositionsByTime(SellPositions);
}

//+------------------------------------------------------------------+
//| Match position to grid                                            |
//+------------------------------------------------------------------+
void MatchPositionToGrid(GridLevel &levels[], PositionData &pos)
{
   double tolerance = CalculateGapPrice() * 0.3;
   
   for(int i = 0; i < ArraySize(levels); i++)
   {
      if(levels[i].isActive && MathAbs(levels[i].price - pos.openPrice) <= tolerance)
      {
         levels[i].hasPosition = true;
         levels[i].ticket = pos.ticket;
         pos.gridIndex = i;
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Sort positions by time                                            |
//+------------------------------------------------------------------+
void SortPositionsByTime(PositionData &positions[])
{
   int size = ArraySize(positions);
   for(int i = 0; i < size - 1; i++)
   {
      for(int j = i + 1; j < size; j++)
      {
         if(positions[j].openTime < positions[i].openTime)
         {
            PositionData temp = positions[i];
            positions[i] = positions[j];
            positions[j] = temp;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check and regenerate grid levels                                  |
//+------------------------------------------------------------------+
void CheckAndRegenerateGridLevels()
{
   for(int i = 0; i < InpMaxGridLevels; i++)
   {
      if(BuyGridLevels[i].isActive && !BuyGridLevels[i].hasPosition && BuyGridLevels[i].ticket > 0)
      {
         BuyGridLevels[i].ticket = 0;
         BuyGridLevels[i].openTime = 0;
         BuyGridLevels[i].martingaleStep = 0;
         Stats.gridRegens++;
      }
      
      if(SellGridLevels[i].isActive && !SellGridLevels[i].hasPosition && SellGridLevels[i].ticket > 0)
      {
         SellGridLevels[i].ticket = 0;
         SellGridLevels[i].openTime = 0;
         SellGridLevels[i].martingaleStep = 0;
         Stats.gridRegens++;
      }
   }
}

//+------------------------------------------------------------------+
//| Mark grid level closed                                            |
//+------------------------------------------------------------------+
void MarkGridLevelClosed(double price, int direction)
{
   double tolerance = CalculateGapPrice() * 0.5;
   
   if(direction == 1)
   {
      for(int i = 0; i < InpMaxGridLevels; i++)
      {
         if(BuyGridLevels[i].isActive && MathAbs(BuyGridLevels[i].price - price) <= tolerance)
         {
            BuyGridLevels[i].hasPosition = false;
            break;
         }
      }
   }
   else
   {
      for(int i = 0; i < InpMaxGridLevels; i++)
      {
         if(SellGridLevels[i].isActive && MathAbs(SellGridLevels[i].price - price) <= tolerance)
         {
            SellGridLevels[i].hasPosition = false;
            break;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Determine zone and bias                                           |
//+------------------------------------------------------------------+
void DetermineZoneAndBias()
{
   double mid = (symInfo.Bid() + symInfo.Ask()) / 2.0;
   
   if(mid >= R2)
   {
      CurrentZone = "Above R2";
      CurrentBias = BIAS_SELL;
   }
   else if(mid > R1 && mid < R2)
   {
      CurrentZone = "R1-R2";
      double pos = (mid - R1) / (R2 - R1);
      if(pos < 0.3) CurrentBias = BIAS_BUY;
      else if(pos > 0.7) CurrentBias = BIAS_SELL;
      else CurrentBias = BIAS_BOTH;
   }
   else if(mid >= S1 && mid <= R1)
   {
      double midpoint = (R1 + S1) / 2.0;
      double range = R1 - S1;
      
      if(MathAbs(mid - midpoint) <= range * 0.05)
      {
         CurrentZone = "S1-R1 Mid";
         CurrentBias = BIAS_NEUTRAL;
      }
      else if(mid > midpoint)
      {
         CurrentZone = "S1-R1 Upper";
         CurrentBias = BIAS_SELL;
      }
      else
      {
         if(R1 - mid <= range * 0.2)
         {
            CurrentZone = "S1-R1 Near R1";
            CurrentBias = BIAS_SELL;
         }
         else
         {
            CurrentZone = "S1-R1 Lower";
            CurrentBias = BIAS_BUY;
         }
      }
   }
   else if(mid < S1 && mid >= S2)
   {
      CurrentZone = "S2-S1";
      double pos = (mid - S2) / (S1 - S2);
      if(pos > 0.7) CurrentBias = BIAS_SELL;
      else if(pos < 0.3) CurrentBias = BIAS_BUY;
      else CurrentBias = BIAS_BOTH;
   }
   else
   {
      CurrentZone = "Below S2";
      CurrentBias = BIAS_BUY;
   }
}

//+------------------------------------------------------------------+
//| Execute grid trading                                              |
//+------------------------------------------------------------------+
void ExecuteGridTrading()
{
   double gapPrice = CalculateGapPrice();
   double slPrice = gapPrice * (InpSLPercent / 100.0);
   double tpPrice = gapPrice * (InpTPPercent / 100.0);
   
   if(CurrentBias == BIAS_BUY || CurrentBias == BIAS_BOTH)
      ExecuteBuyGrid(gapPrice, slPrice, tpPrice);
   
   if(CurrentBias == BIAS_SELL || CurrentBias == BIAS_BOTH)
      ExecuteSellGrid(gapPrice, slPrice, tpPrice);
}

//+------------------------------------------------------------------+
//| Execute buy grid                                                  |
//+------------------------------------------------------------------+
void ExecuteBuyGrid(double gapPrice, double slPrice, double tpPrice)
{
   int totalPos = BuyCount + SellCount;
   
   if(BuyCount >= InpMaxBuyPositions || totalPos >= InpMaxTotalPositions)
   {
      if(InpInfiniteGrid && InpCloseOldestAtMax && ArraySize(BuyPositions) > 0)
      {
         ClosePosition(BuyPositions[0].ticket);
         return;
      }
      return;
   }
   
   double ask = symInfo.Ask();
   int gridIdx = FindOrCreateGridLevel(BuyGridLevels, ask, gapPrice);
   
   if(gridIdx < 0 || BuyGridLevels[gridIdx].hasPosition)
      return;
   
   double lotSize = CalculateLotSize(BuyGridLevels[gridIdx].martingaleStep);
   double sl = ValidateStopLoss(ask, slPrice, true);
   double tp = ValidateTakeProfit(ask, tpPrice, true);
   
   string comment = InpOrderComment + "_BUY_" + IntegerToString(gridIdx);
   
   if(OpenPosition(ORDER_TYPE_BUY, lotSize, sl, tp, comment))
   {
      BuyGridLevels[gridIdx].hasPosition = true;
      BuyGridLevels[gridIdx].ticket = trade.ResultOrder();
      BuyGridLevels[gridIdx].openTime = TimeCurrent();
      BuyGridLevels[gridIdx].lotSize = lotSize;
      
      Stats.totalBuys++;
      TodayTradeCount++;
      LastTradeTime = TimeCurrent();
      
      Print("✅ BUY @ ", DoubleToString(ask, SymSpec.digits), " Lot:", DoubleToString(lotSize, 2));
   }
}

//+------------------------------------------------------------------+
//| Execute sell grid                                                 |
//+------------------------------------------------------------------+
void ExecuteSellGrid(double gapPrice, double slPrice, double tpPrice)
{
   int totalPos = BuyCount + SellCount;
   
   if(SellCount >= InpMaxSellPositions || totalPos >= InpMaxTotalPositions)
   {
      if(InpInfiniteGrid && InpCloseOldestAtMax && ArraySize(SellPositions) > 0)
      {
         ClosePosition(SellPositions[0].ticket);
         return;
      }
      return;
   }
   
   double bid = symInfo.Bid();
   int gridIdx = FindOrCreateGridLevel(SellGridLevels, bid, gapPrice);
   
   if(gridIdx < 0 || SellGridLevels[gridIdx].hasPosition)
      return;
   
   double lotSize = CalculateLotSize(SellGridLevels[gridIdx].martingaleStep);
   double sl = ValidateStopLoss(bid, slPrice, false);
   double tp = ValidateTakeProfit(bid, tpPrice, false);
   
   string comment = InpOrderComment + "_SELL_" + IntegerToString(gridIdx);
   
   if(OpenPosition(ORDER_TYPE_SELL, lotSize, sl, tp, comment))
   {
      SellGridLevels[gridIdx].hasPosition = true;
      SellGridLevels[gridIdx].ticket = trade.ResultOrder();
      SellGridLevels[gridIdx].openTime = TimeCurrent();
      SellGridLevels[gridIdx].lotSize = lotSize;
      
      Stats.totalSells++;
      TodayTradeCount++;
      LastTradeTime = TimeCurrent();
      
      Print("✅ SELL @ ", DoubleToString(bid, SymSpec.digits), " Lot:", DoubleToString(lotSize, 2));
   }
}

//+------------------------------------------------------------------+
//| Find or create grid level                                         |
//+------------------------------------------------------------------+
int FindOrCreateGridLevel(GridLevel &levels[], double price, double gapPrice)
{
   double tolerance = gapPrice * 0.3;
   
   for(int i = 0; i < InpMaxGridLevels; i++)
   {
      if(levels[i].isActive && MathAbs(levels[i].price - price) <= tolerance)
         return i;
   }
   
   double nearestPrice = 0;
   double minDist = DBL_MAX;
   
   for(int i = 0; i < InpMaxGridLevels; i++)
   {
      if(levels[i].isActive && levels[i].price > 0)
      {
         double dist = MathAbs(levels[i].price - price);
         if(dist < minDist)
         {
            minDist = dist;
            nearestPrice = levels[i].price;
         }
      }
   }
   
   if(nearestPrice == 0 || minDist >= gapPrice * 0.9)
   {
      int freeIdx = FindFreeGridIndex(levels);
      if(freeIdx >= 0)
      {
         levels[freeIdx].price = NormalizeDouble(price, SymSpec.digits);
         levels[freeIdx].isActive = true;
         levels[freeIdx].hasPosition = false;
         levels[freeIdx].martingaleStep = CurrentMartingaleStep;
         return freeIdx;
      }
   }
   
   return -1;
}

//+------------------------------------------------------------------+
//| Find free grid index                                              |
//+------------------------------------------------------------------+
int FindFreeGridIndex(GridLevel &levels[])
{
   for(int i = 0; i < ArraySize(levels); i++)
   {
      if(!levels[i].isActive || levels[i].price == 0)
         return i;
   }
   
   datetime oldest = TimeCurrent();
   int oldestIdx = -1;
   
   for(int i = 0; i < ArraySize(levels); i++)
   {
      if(!levels[i].hasPosition && levels[i].openTime < oldest)
      {
         oldest = levels[i].openTime;
         oldestIdx = i;
      }
   }
   
   return oldestIdx;
}

//+------------------------------------------------------------------+
//| Calculate lot size                                                |
//+------------------------------------------------------------------+
double CalculateLotSize(int martingaleStep)
{
   double baseLot = InpLotSize;
   
   if(InpLotMode == LOT_PERCENT_BALANCE)
      baseLot = (accInfo.Balance() * InpLotSize / 100.0) / SymSpec.marginRequired;
   else if(InpLotMode == LOT_PERCENT_EQUITY)
      baseLot = (accInfo.Equity() * InpLotSize / 100.0) / SymSpec.marginRequired;
   
   baseLot *= InpLotMultiplier;
   
   if(InpMartingaleMode != MARTINGALE_OFF && martingaleStep > 0)
   {
      for(int i = 0; i < martingaleStep; i++)
         baseLot *= InpMartingaleMultiplier;
   }
   
   baseLot = NormalizeLot(baseLot);
   baseLot = MathMax(SymSpec.minLot, MathMin(InpMaxLotSize, baseLot));
   baseLot = MathMin(SymSpec.maxLot, baseLot);
   
   return baseLot;
}

//+------------------------------------------------------------------+
//| Normalize lot                                                     |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   if(SymSpec.lotStep == 0) return lot;
   return MathFloor(lot / SymSpec.lotStep) * SymSpec.lotStep;
}

//+------------------------------------------------------------------+
//| Validate stop loss                                                |
//+------------------------------------------------------------------+
double ValidateStopLoss(double price, double slDistance, bool isBuy)
{
   double minStop = SymSpec.stopLevel * SymSpec.point;
   double spread = symInfo.Spread() * SymSpec.point;
   double minRequired = minStop + spread;
   
   slDistance = MathMax(slDistance, minRequired + 10 * SymSpec.point);
   
   double sl = isBuy ? (price - slDistance) : (price + slDistance);
   return NormalizeDouble(sl, SymSpec.digits);
}

//+------------------------------------------------------------------+
//| Validate take profit                                              |
//+------------------------------------------------------------------+
double ValidateTakeProfit(double price, double tpDistance, bool isBuy)
{
   double minStop = SymSpec.stopLevel * SymSpec.point;
   double spread = symInfo.Spread() * SymSpec.point;
   double minRequired = minStop + spread;
   
   tpDistance = MathMax(tpDistance, minRequired + 10 * SymSpec.point);
   
   double tp = isBuy ? (price + tpDistance) : (price - tpDistance);
   return NormalizeDouble(tp, SymSpec.digits);
}

//+------------------------------------------------------------------+
//| Open position with retries                                        |
//+------------------------------------------------------------------+
bool OpenPosition(ENUM_ORDER_TYPE orderType, double lots, double sl, double tp, string comment)
{
   for(int attempt = 0; attempt < InpMaxRetries; attempt++)
   {
      symInfo.RefreshRates();
      double price = (orderType == ORDER_TYPE_BUY) ? symInfo.Ask() : symInfo.Bid();
      
      bool result = (orderType == ORDER_TYPE_BUY) ?
                    trade.Buy(lots, _Symbol, price, sl, tp, comment) :
                    trade.Sell(lots, _Symbol, price, sl, tp, comment);
      
      if(result) return true;
      
      uint retcode = trade.ResultRetcode();
      if(retcode == TRADE_RETCODE_NO_MONEY || retcode == TRADE_RETCODE_MARKET_CLOSED ||
         retcode == TRADE_RETCODE_TRADE_DISABLED)
      {
         Print("❌ Fatal: ", trade.ResultRetcodeDescription());
         break;
      }
      
      Print("⚠️ Retry ", attempt + 1, ": ", trade.ResultRetcodeDescription());
      Sleep(InpRetryDelayMS);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Close position                                                    |
//+------------------------------------------------------------------+
bool ClosePosition(ulong ticket)
{
   for(int attempt = 0; attempt < InpMaxRetries; attempt++)
   {
      if(trade.PositionClose(ticket)) return true;
      Sleep(InpRetryDelayMS);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Process recovery                                                  |
//+------------------------------------------------------------------+
void ProcessRecovery()
{
   double ddPct = GetCurrentDrawdownPercent();
   if(ddPct < InpRecoveryTriggerDD)
   {
      IsRecovering = false;
      return;
   }
   
   IsRecovering = true;
   
   if(InpRecoveryMode == RECOVERY_MARTINGALE && CurrentMartingaleStep < InpMartingaleMaxSteps)
      CurrentMartingaleStep++;
   
   Stats.recoveryTrades++;
}

//+------------------------------------------------------------------+
//| Process hedging                                                   |
//+------------------------------------------------------------------+
void ProcessHedging()
{
   double ddPct = GetCurrentDrawdownPercent();
   IsHedging = (ddPct >= InpHedgeTriggerDD);
   
   if(IsHedging)
   {
      double buyPL = GetDirectionPL(1);
      double sellPL = GetDirectionPL(-1);
      
      if(buyPL < -100 && SellCount < InpRecoveryMaxPositions)
      {
         double gapPrice = CalculateGapPrice();
         double lots = CalculateLotSize(0) * InpHedgeLotMultiplier;
         double bid = symInfo.Bid();
         double sl = ValidateStopLoss(bid, gapPrice * 0.5, false);
         double tp = ValidateTakeProfit(bid, gapPrice, false);
         
         if(OpenPosition(ORDER_TYPE_SELL, lots, sl, tp, InpOrderComment + "_HEDGE"))
            Stats.hedgeTrades++;
      }
      
      if(sellPL < -100 && BuyCount < InpRecoveryMaxPositions)
      {
         double gapPrice = CalculateGapPrice();
         double lots = CalculateLotSize(0) * InpHedgeLotMultiplier;
         double ask = symInfo.Ask();
         double sl = ValidateStopLoss(ask, gapPrice * 0.5, true);
         double tp = ValidateTakeProfit(ask, gapPrice, true);
         
         if(OpenPosition(ORDER_TYPE_BUY, lots, sl, tp, InpOrderComment + "_HEDGE"))
            Stats.hedgeTrades++;
      }
   }
}

//+------------------------------------------------------------------+
//| Get P/L for direction                                             |
//+------------------------------------------------------------------+
double GetDirectionPL(int direction)
{
   double pl = 0;
   
   if(direction == 1)
   {
      for(int i = 0; i < ArraySize(BuyPositions); i++)
         pl += BuyPositions[i].profit;
   }
   else
   {
      for(int i = 0; i < ArraySize(SellPositions); i++)
         pl += SellPositions[i].profit;
   }
   
   return pl;
}

//+------------------------------------------------------------------+
//| Process breakeven and trailing                                    |
//+------------------------------------------------------------------+
void ProcessBreakevenAndTrailing()
{
   ProcessBETrailArray(BuyPositions, true);
   ProcessBETrailArray(SellPositions, false);
}

//+------------------------------------------------------------------+
//| Process BE/Trail for array                                        |
//+------------------------------------------------------------------+
void ProcessBETrailArray(PositionData &positions[], bool isBuy)
{
   double gapPrice = CalculateGapPrice();
   double tpDistance = gapPrice * (InpTPPercent / 100.0);
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      double currentPrice = isBuy ? symInfo.Bid() : symInfo.Ask();
      double openPrice = positions[i].openPrice;
      double currentSL = positions[i].sl;
      double currentTP = positions[i].tp;
      
      double profitDist = isBuy ? (currentPrice - openPrice) : (openPrice - currentPrice);
      double profitPct = (profitDist / tpDistance) * 100;
      
      // Breakeven
      if(InpUseBreakeven && profitPct >= InpBreakevenTrigger)
      {
         double beOffset = tpDistance * (InpBreakevenOffset / 100.0);
         double bePrice = isBuy ? (openPrice + beOffset) : (openPrice - beOffset);
         
         bool shouldMove = isBuy ? (currentSL < bePrice) : (currentSL > bePrice || currentSL == 0);
         
         if(shouldMove)
         {
            if(ModifyPosition(positions[i].ticket, bePrice, currentTP))
               Stats.breakevenMoves++;
         }
      }
      
      // Trailing
      if(InpUseTrailing && profitPct >= InpTrailingTrigger)
      {
         double trailStep = gapPrice * (InpTrailingStep / 100.0);
         double newSL = isBuy ? (currentPrice - trailStep) : (currentPrice + trailStep);
         
         bool shouldTrail = isBuy ? (newSL > currentSL + SymSpec.point) : 
                                     (newSL < currentSL - SymSpec.point || currentSL == 0);
         
         if(shouldTrail)
         {
            if(ModifyPosition(positions[i].ticket, newSL, currentTP))
               Stats.trailingMoves++;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Modify position                                                   |
//+------------------------------------------------------------------+
bool ModifyPosition(ulong ticket, double sl, double tp)
{
   sl = NormalizeDouble(sl, SymSpec.digits);
   tp = NormalizeDouble(tp, SymSpec.digits);
   return trade.PositionModify(ticket, sl, tp);
}

//+------------------------------------------------------------------+
//| Process partial closes                                            |
//+------------------------------------------------------------------+
void ProcessPartialCloses()
{
   ProcessPartialArray(BuyPositions, true);
   ProcessPartialArray(SellPositions, false);
}

//+------------------------------------------------------------------+
//| Process partial for array                                         |
//+------------------------------------------------------------------+
void ProcessPartialArray(PositionData &positions[], bool isBuy)
{
   double gapPrice = CalculateGapPrice();
   double tpDistance = gapPrice * (InpTPPercent / 100.0);
   
   for(int i = 0; i < ArraySize(positions); i++)
   {
      if(positions[i].isPartialClosed) continue;
      
      double currentPrice = isBuy ? symInfo.Bid() : symInfo.Ask();
      double profitDist = isBuy ? (currentPrice - positions[i].openPrice) : 
                                   (positions[i].openPrice - currentPrice);
      double profitPct = (profitDist / tpDistance) * 100;
      
      if(profitPct >= InpPartialTrigger)
      {
         double closeVol = NormalizeLot(positions[i].volume * (InpPartialPercent / 100.0));
         
         if(closeVol >= SymSpec.minLot)
         {
            if(trade.PositionClosePartial(positions[i].ticket, closeVol))
            {
               Stats.partialCloses++;
               
               double newTP = isBuy ? 
                  (positions[i].openPrice + tpDistance * InpRunnerMultiple) :
                  (positions[i].openPrice - tpDistance * InpRunnerMultiple);
               
               ModifyPosition(positions[i].ticket, positions[i].sl, newTP);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Emergency close all                                               |
//+------------------------------------------------------------------+
void EmergencyCloseAll()
{
   Print("🚨 EMERGENCY CLOSE ALL");
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
            ClosePosition(posInfo.Ticket());
      }
   }
   
   InitializeGridLevels();
}

//+------------------------------------------------------------------+
//| Draw S/R lines                                                    |
//+------------------------------------------------------------------+
void DrawSRLines()
{
   DrawHLine("SR_R3", R3, InpResistanceColor, STYLE_DASH, 1, "R3");
   DrawHLine("SR_R2", R2, InpResistanceColor, STYLE_SOLID, 2, "R2");
   DrawHLine("SR_R1", R1, InpResistanceColor, STYLE_SOLID, 2, "R1");
   DrawHLine("SR_S1", S1, InpSupportColor, STYLE_SOLID, 2, "S1");
   DrawHLine("SR_S2", S2, InpSupportColor, STYLE_SOLID, 2, "S2");
   DrawHLine("SR_S3", S3, InpSupportColor, STYLE_DASH, 1, "S3");
}

//+------------------------------------------------------------------+
//| Draw grid levels                                                  |
//+------------------------------------------------------------------+
void DrawGridLevels()
{
   ObjectsDeleteAll(0, "Grid_");
   
   for(int i = 0; i < InpMaxGridLevels; i++)
   {
      if(BuyGridLevels[i].isActive && BuyGridLevels[i].price > 0)
      {
         color clr = BuyGridLevels[i].hasPosition ? clrLime : InpBuyGridColor;
         DrawHLine("Grid_B" + IntegerToString(i), BuyGridLevels[i].price, clr, STYLE_DOT, 1, "");
      }
      
      if(SellGridLevels[i].isActive && SellGridLevels[i].price > 0)
      {
         color clr = SellGridLevels[i].hasPosition ? clrRed : InpSellGridColor;
         DrawHLine("Grid_S" + IntegerToString(i), SellGridLevels[i].price, clr, STYLE_DOT, 1, "");
      }
   }
}

//+------------------------------------------------------------------+
//| Draw horizontal line                                              |
//+------------------------------------------------------------------+
void DrawHLine(string name, double price, color clr, ENUM_LINE_STYLE style, int width, string label)
{
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
   if(label != "")
      ObjectSetString(0, name, OBJPROP_TEXT, label + ": " + DoubleToString(price, SymSpec.digits));
}

//+------------------------------------------------------------------+
//| Create info panel                                                 |
//+------------------------------------------------------------------+
void CreateInfoPanel()
{
   ObjectDelete(0, "Panel_Bg");
   ObjectCreate(0, "Panel_Bg", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, "Panel_Bg", OBJPROP_XDISTANCE, 5);
   ObjectSetInteger(0, "Panel_Bg", OBJPROP_YDISTANCE, 25);
   ObjectSetInteger(0, "Panel_Bg", OBJPROP_XSIZE, 330);
   ObjectSetInteger(0, "Panel_Bg", OBJPROP_YSIZE, 480);
   ObjectSetInteger(0, "Panel_Bg", OBJPROP_BGCOLOR, InpPanelBgColor);
   ObjectSetInteger(0, "Panel_Bg", OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, "Panel_Bg", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "Panel_Bg", OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| Create text                                                       |
//+------------------------------------------------------------------+
void CreateText(string name, int x, int y, string text, color clr, int size = 9)
{
   ObjectDelete(0, name);
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
}

//+------------------------------------------------------------------+
//| Update info panel                                                 |
//+------------------------------------------------------------------+
void UpdateInfoPanel()
{
   int x = 10, y = 30, lh = 15;
   
   double equity = accInfo.Equity();
   double ddPct = GetCurrentDrawdownPercent();
   double maxDD = MathMin(InpMaxDrawdownPct, SACROSANCT_MAX_DD);
   
   CreateText("P_H1", x, y, "═══ SR GRID EA V3 ═══", clrGold, 10);
   y += lh;
   CreateText("P_H2", x, y, "   TORAMA CAPITAL", clrGold, 9);
   
   y += lh + 3;
   string status = EAStopped ? "⛔ STOPPED" : "🟢 ACTIVE";
   color stClr = EAStopped ? clrRed : clrLime;
   CreateText("P_Status", x, y, "Status: " + status, stClr);
   
   if(EAStopped && StopReason != "")
   {
      y += lh;
      CreateText("P_Reason", x, y, "Reason: " + StopReason, clrOrange);
   }
   
   y += lh;
   string biasStr = "NEUTRAL";
   color biasClr = clrYellow;
   if(CurrentBias == BIAS_BUY) { biasStr = "▲ BUY"; biasClr = clrLime; }
   else if(CurrentBias == BIAS_SELL) { biasStr = "▼ SELL"; biasClr = clrRed; }
   else if(CurrentBias == BIAS_BOTH) { biasStr = "◆ BOTH"; biasClr = clrCyan; }
   CreateText("P_Bias", x, y, "Bias: " + biasStr + " | Zone: " + CurrentZone, biasClr);
   
   y += lh;
   CreateText("P_Sep1", x, y, "─────────────────────────────────", clrGray);
   
   y += lh;
   CreateText("P_Sym", x, y, "Symbol: " + _Symbol + " (" + GetSymbolTypeString() + ")", clrCyan);
   
   y += lh;
   CreateText("P_Spread", x, y, "Spread: " + IntegerToString(symInfo.Spread()) + " pts", InpPanelTextColor);
   
   y += lh;
   CreateText("P_Sep2", x, y, "─────────────────────────────────", clrGray);
   
   y += lh;
   CreateText("P_R3", x, y, "R3: " + DoubleToString(R3, SymSpec.digits), InpResistanceColor);
   y += lh;
   CreateText("P_R2", x, y, "R2: " + DoubleToString(R2, SymSpec.digits), InpResistanceColor);
   y += lh;
   CreateText("P_R1", x, y, "R1: " + DoubleToString(R1, SymSpec.digits), InpResistanceColor);
   y += lh;
   CreateText("P_Price", x, y, ">> " + DoubleToString(symInfo.Bid(), SymSpec.digits) + " <<", clrWhite, 10);
   y += lh;
   CreateText("P_S1", x, y, "S1: " + DoubleToString(S1, SymSpec.digits), InpSupportColor);
   y += lh;
   CreateText("P_S2", x, y, "S2: " + DoubleToString(S2, SymSpec.digits), InpSupportColor);
   y += lh;
   CreateText("P_S3", x, y, "S3: " + DoubleToString(S3, SymSpec.digits), InpSupportColor);
   
   y += lh;
   CreateText("P_Sep3", x, y, "─────────────────────────────────", clrGray);
   
   y += lh;
   CreateText("P_Gap", x, y, "Gap: " + DoubleToString(CalculateGapPrice(), SymSpec.digits) + 
              " (" + DoubleToString(CurrentGap, 2) + "%)", clrCyan);
   
   y += lh;
   CreateText("P_Buys", x, y, "Buys: " + IntegerToString(BuyCount) + "/" + 
              IntegerToString(InpMaxBuyPositions), clrLime);
   y += lh;
   CreateText("P_Sells", x, y, "Sells: " + IntegerToString(SellCount) + "/" + 
              IntegerToString(InpMaxSellPositions), clrRed);
   
   y += lh;
   CreateText("P_Grid", x, y, "Grid: " + (InpInfiniteGrid ? "♾️ INFINITE" : "LIMITED") + 
              " | Regens: " + IntegerToString(Stats.gridRegens), clrCyan);
   
   y += lh;
   CreateText("P_Sep4", x, y, "─────────────────────────────────", clrGray);
   
   y += lh;
   color ddClr = ddPct > maxDD * 0.8 ? clrRed : (ddPct > maxDD * 0.5 ? clrOrange : clrLime);
   CreateText("P_DD", x, y, "DD: " + DoubleToString(ddPct, 2) + "% / " + 
              DoubleToString(maxDD, 1) + "%", ddClr);
   
   y += lh;
   CreateText("P_MaxDD", x, y, "Peak DD: " + DoubleToString(Stats.maxDrawdownPct, 2) + "%", InpPanelTextColor);
   
   y += lh;
   CreateText("P_Equity", x, y, "Equity: $" + DoubleToString(equity, 2), InpPanelTextColor);
   
   y += lh;
   color plClr = Stats.netProfit >= 0 ? clrLime : clrRed;
   CreateText("P_PL", x, y, "Net P/L: $" + DoubleToString(Stats.netProfit, 2), plClr);
   
   y += lh;
   color tdClr = TodayPL >= 0 ? clrLime : clrRed;
   CreateText("P_Today", x, y, "Today: $" + DoubleToString(TodayPL, 2), tdClr);
   
   y += lh;
   CreateText("P_Sep5", x, y, "─────────────────────────────────", clrGray);
   
   y += lh;
   int total = Stats.winTrades + Stats.lossTrades;
   double winRate = total > 0 ? (Stats.winTrades * 100.0 / total) : 0;
   CreateText("P_WR", x, y, "Win: " + DoubleToString(winRate, 1) + "% (" + 
              IntegerToString(Stats.winTrades) + "/" + IntegerToString(total) + ")", InpPanelTextColor);
   
   y += lh;
   CreateText("P_Consec", x, y, "Consec W/L: " + IntegerToString(Stats.consecutiveWins) + "/" + 
              IntegerToString(Stats.consecutiveLosses), InpPanelTextColor);
   
   y += lh;
   CreateText("P_Trades", x, y, "Today Trades: " + IntegerToString(TodayTradeCount), InpPanelTextColor);
   
   y += lh;
   string feat = "";
   if(InpMartingaleMode != MARTINGALE_OFF) feat += "M" + IntegerToString(CurrentMartingaleStep) + " ";
   if(IsHedging) feat += "HEDGE ";
   if(IsRecovering) feat += "RECOV ";
   if(InpUseBreakeven) feat += "BE:" + IntegerToString(Stats.breakevenMoves) + " ";
   if(InpUseTrailing) feat += "TR:" + IntegerToString(Stats.trailingMoves) + " ";
   if(feat == "") feat = "Standard";
   CreateText("P_Feat", x, y, feat, clrCyan);
   
   y += lh;
   CreateText("P_Broker", x, y, StringSubstr(Broker.name, 0, 30), clrGray);
}
//+------------------------------------------------------------------+
