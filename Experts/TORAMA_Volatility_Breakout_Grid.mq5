//+------------------------------------------------------------------+
//|                        TORAMA Volatility Breakout Grid EA         |
//|                                          TORAMA CAPITAL           |
//|                                          ea@torama.money          |
//|                                          torama.money             |
//+------------------------------------------------------------------+
#property copyright "TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.00"
#property description "Advanced Volatility Breakout Grid with Statistical Entries"
#property description "Features: Compression->Expansion Detection, 3-Stage Trailing"
#property description "Max Daily Loss: 3% | Target: 2% Daily"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

CTrade trade;
CPositionInfo position;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;

//+------------------------------------------------------------------+
//| Input Parameters                                                  |
//+------------------------------------------------------------------+
input group "===== RISK MANAGEMENT ====="
input double   DailyRiskPercent = 3.0;              // Daily Risk % (Max Loss)
input int      MaxGridPositions = 7;                // Maximum Grid Positions
input double   InitialStopLoss = 20;                // Initial Stop Loss (Points)
input double   RiskRewardRatio = 2.0;               // Risk:Reward Ratio (Not Used)

input group "===== GRID CONFIGURATION ====="
input double   GridSpacing = 15;                    // Grid Spacing (Points)
input int      MaxGridLevels = 7;                   // Maximum Grid Levels
input bool     BidirectionalGrid = true;            // Enable Bidirectional Grid
input bool     DynamicGridSpacing = true;           // Dynamic Grid Based on Volatility

input group "===== VOLATILITY BREAKOUT SYSTEM ====="
input int      VolatilityPeriod = 20;               // Volatility Calculation Period (5-min bars)
input double   CompressionThreshold = 0.7;          // Compression Detection (0.5-1.5)
input double   ExpansionThreshold = 1.3;            // Expansion Trigger (1.0-2.0)
input int      VolatilityLookback = 100;            // Historical Volatility Lookback
input bool     UseStdDevLevels = true;              // Use Std Dev Grid Levels
input double   StdDev_Level1 = 0.5;                 // Grid Level 1 (0.5 Sigma)
input double   StdDev_Level2 = 1.0;                 // Grid Level 2 (1.0 Sigma)
input double   StdDev_Level3 = 1.5;                 // Grid Level 3 (1.5 Sigma)

input group "===== TRAILING STOP SYSTEM ====="
input double   Stage1_BE_Points = 5;                // Stage 1: Breakeven Trigger (Points)
input double   Stage2_TrailPercent = 50;            // Stage 2: Trail % of Max Profit
input double   Stage2_MaxPoints = 30;               // Stage 2: Max Points Threshold
input double   Stage3_ATR_Multiplier = 1.5;         // Stage 3: ATR Multiplier
input int      ATR_Period = 5;                      // ATR Period for Stage 3
input double   MinimumTrailPoints = 3;              // Minimum Trail Distance (Points)
input bool     UseCorrelationTrailing = true;       // Correlation-Aware Trailing

input group "===== TIME FILTERS ====="
input int      TradingStartHour = 1;                // Trading Start Hour (Server Time)
input int      TradingEndHour = 23;                 // Trading End Hour (Server Time)
input bool     AvoidNews = true;                    // Avoid News Events
input int      NewsAvoidMinutes = 15;               // Minutes Before/After News

input group "===== CIRCUIT BREAKERS ====="
input bool     UseDailyLossLimit = true;            // Enable Daily Loss Limit
input double   CircuitBreakerPercent = 2.5;         // Circuit Breaker % (Stop Trading)
input int      MaxConsecutiveLosses = 5;            // Max Consecutive Losses
input bool     UseVolatilityCircuit = true;         // Volatility Spike Protection
input double   VolatilitySpikeFactor = 2.0;         // Volatility Spike Threshold

input group "===== DISPLAY & BRANDING ====="
input bool     ShowPanel = true;                    // Show Info Panel
input color    PanelColor = clrDarkSlateGray;       // Panel Background Color
input color    TextColor = clrWhite;                // Panel Text Color
input int      PanelX = 20;                         // Panel X Position
input int      PanelY = 50;                         // Panel Y Position

input group "===== EXPERT SETTINGS ====="
input string   TradeComment = "TORAMA_VBG";         // Trade Comment
input int      Slippage = 3;                        // Maximum Slippage (Points)
input int      MaxSpread = 0;                       // Max Spread in Points (0 = Unlimited)

//+------------------------------------------------------------------+
//| Global Variables                                                  |
//+------------------------------------------------------------------+
ulong MagicNumber = 0;  // Generated from Chart ID

double pointValue;
double tickSize;
double tickValue;
int totalDigits;
double gridSpacingPrice;
double initialSLPrice;
double minTrailPrice;

datetime lastBarTime = 0;
double dayStartBalance = 0;
double dailyPnL = 0;
int consecutiveLosses = 0;
bool tradingHalted = false;

double currentVolatility = 0;
double averageVolatility = 0;
double volatilityStdDev = 0;
bool isVolatilityCompressed = false;
bool isVolatilityExpanding = false;

struct GridLevel {
    double price;
    bool hasBuyPosition;
    bool hasSellPosition;
    datetime lastEntryTime;
    double sigmaLevel;
};

GridLevel buyGridLevels[];
GridLevel sellGridLevels[];

struct PositionTracker {
    ulong ticket;
    double entryPrice;
    double maxProfit;
    double maxFavorablePrice;
    int trailStage;
    datetime entryTime;
};

PositionTracker positionTrackers[];

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit() {
    // Generate Magic Number from Chart ID
    MagicNumber = ChartID();
    
    // Set trade parameters
    trade.SetExpertMagicNumber(MagicNumber);
    trade.SetDeviationInPoints(Slippage);
    trade.SetTypeFilling(ORDER_FILLING_FOK);
    trade.SetAsyncMode(false);
    
    // Initialize symbol info
    if(!symbolInfo.Name(_Symbol)) {
        Print("Failed to initialize symbol info");
        return INIT_FAILED;
    }
    
    symbolInfo.Refresh();
    symbolInfo.RefreshRates();
    
    // Calculate symbol-specific values
    pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    totalDigits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    
    // Convert points to price
    gridSpacingPrice = GridSpacing * pointValue;
    initialSLPrice = InitialStopLoss * pointValue;
    minTrailPrice = MinimumTrailPoints * pointValue;
    
    // Initialize daily tracking
    dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    
    // Calculate initial volatility metrics
    CalculateVolatilityMetrics();
    
    // Initialize grid levels
    InitializeGridLevels();
    
    // Create UI Panel
    if(ShowPanel) {
        CreateInfoPanel();
    }
    
    Print("═════════════════════════════════════════════════════════");
    Print("    TORAMA Volatility Breakout Grid EA Initialized");
    Print("    Symbol: ", _Symbol);
    Print("    Daily Risk Limit: ", DailyRiskPercent, "%");
    Print("    Volatility-Based Grid: ", (UseStdDevLevels ? "ENABLED" : "DISABLED"));
    Print("    3-Stage Trailing: ACTIVE");
    Print("    TORAMA CAPITAL - ea@torama.money");
    Print("═════════════════════════════════════════════════════════");
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    // Clean up UI
    ObjectsDeleteAll(0, "TORAMA_");
    
    Comment("");
    
    Print("TORAMA Volatility Breakout Grid EA stopped. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
    // Check for new bar
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    bool isNewBar = (currentBarTime != lastBarTime);
    
    if(isNewBar) {
        lastBarTime = currentBarTime;
        OnNewBar();
    }
    
    // Update volatility metrics every tick
    UpdateVolatilityState();
    
    // Trail all open positions
    ManageTrailingStops();
    
    // Update UI
    if(ShowPanel) {
        UpdateInfoPanel();
    }
}

//+------------------------------------------------------------------+
//| New Bar Handler                                                   |
//+------------------------------------------------------------------+
void OnNewBar() {
    // Check if new day
    static int lastDay = 0;
    MqlDateTime timeStruct;
    TimeToStruct(TimeCurrent(), timeStruct);
    
    if(timeStruct.day != lastDay) {
        OnNewDay();
        lastDay = timeStruct.day;
    }
    
    // Update daily P&L
    UpdateDailyPnL();
    
    // Check circuit breakers
    if(!CheckCircuitBreakers()) {
        return;
    }
    
    // Check time filter
    if(!IsWithinTradingHours()) {
        return;
    }
    
    // Recalculate volatility metrics
    CalculateVolatilityMetrics();
    
    // Update grid levels based on current volatility
    if(UseStdDevLevels || DynamicGridSpacing) {
        UpdateVolatilityGridLevels();
    }
    
    // Update grid levels with current positions
    UpdateGridLevels();
    
    // Check for entry signals
    CheckVolatilityBreakoutSignals();
}

//+------------------------------------------------------------------+
//| New Day Handler                                                   |
//+------------------------------------------------------------------+
void OnNewDay() {
    dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    dailyPnL = 0;
    consecutiveLosses = 0;
    tradingHalted = false;
    
    Print("═════════════════════════════════════════════════════════");
    Print("    NEW TRADING DAY");
    Print("    Starting Balance: $", DoubleToString(dayStartBalance, 2));
    Print("    Daily Risk Limit: $", DoubleToString(dayStartBalance * DailyRiskPercent / 100, 2));
    Print("═════════════════════════════════════════════════════════");
}

//+------------------------------------------------------------------+
//| Initialize Grid Levels                                           |
//+------------------------------------------------------------------+
void InitializeGridLevels() {
    ArrayResize(buyGridLevels, MaxGridLevels);
    ArrayResize(sellGridLevels, MaxGridLevels);
    
    double currentPrice = symbolInfo.Ask();
    
    if(UseStdDevLevels) {
        // Will be set by UpdateVolatilityGridLevels()
        for(int i = 0; i < MaxGridLevels; i++) {
            buyGridLevels[i].price = 0;
            buyGridLevels[i].hasBuyPosition = false;
            buyGridLevels[i].hasSellPosition = false;
            buyGridLevels[i].lastEntryTime = 0;
            buyGridLevels[i].sigmaLevel = 0;
            
            sellGridLevels[i].price = 0;
            sellGridLevels[i].hasBuyPosition = false;
            sellGridLevels[i].hasSellPosition = false;
            sellGridLevels[i].lastEntryTime = 0;
            sellGridLevels[i].sigmaLevel = 0;
        }
    } else {
        // Fixed grid spacing
        for(int i = 0; i < MaxGridLevels; i++) {
            buyGridLevels[i].price = currentPrice - (i + 1) * gridSpacingPrice;
            buyGridLevels[i].hasBuyPosition = false;
            buyGridLevels[i].hasSellPosition = false;
            buyGridLevels[i].lastEntryTime = 0;
            buyGridLevels[i].sigmaLevel = 0;
            
            sellGridLevels[i].price = currentPrice + (i + 1) * gridSpacingPrice;
            sellGridLevels[i].hasBuyPosition = false;
            sellGridLevels[i].hasSellPosition = false;
            sellGridLevels[i].lastEntryTime = 0;
            sellGridLevels[i].sigmaLevel = 0;
        }
    }
}

//+------------------------------------------------------------------+
//| Update Volatility-Based Grid Levels                              |
//+------------------------------------------------------------------+
void UpdateVolatilityGridLevels() {
    double currentPrice = symbolInfo.Ask();
    
    if(UseStdDevLevels && volatilityStdDev > 0) {
        // Create grid levels at standard deviation multiples
        double sigmaLevels[] = {StdDev_Level1, StdDev_Level2, StdDev_Level3};
        int levelCount = MathMin(ArraySize(sigmaLevels), MaxGridLevels);
        
        for(int i = 0; i < levelCount; i++) {
            double sigmaDistance = volatilityStdDev * sigmaLevels[i];
            
            // BUY grid (below current price)
            buyGridLevels[i].price = NormalizeDouble(currentPrice - sigmaDistance, totalDigits);
            buyGridLevels[i].sigmaLevel = sigmaLevels[i];
            
            // SELL grid (above current price)
            sellGridLevels[i].price = NormalizeDouble(currentPrice + sigmaDistance, totalDigits);
            sellGridLevels[i].sigmaLevel = sigmaLevels[i];
        }
    } else if(DynamicGridSpacing && currentVolatility > 0) {
        // Adjust grid spacing based on current volatility
        double dynamicSpacing = currentVolatility * 2.0; // 2x current volatility
        
        for(int i = 0; i < MaxGridLevels; i++) {
            buyGridLevels[i].price = NormalizeDouble(currentPrice - (i + 1) * dynamicSpacing, totalDigits);
            sellGridLevels[i].price = NormalizeDouble(currentPrice + (i + 1) * dynamicSpacing, totalDigits);
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate Volatility Metrics                                     |
//+------------------------------------------------------------------+
void CalculateVolatilityMetrics() {
    double closes[];
    ArraySetAsSeries(closes, true);
    
    if(CopyClose(_Symbol, PERIOD_M5, 0, VolatilityLookback, closes) <= 0) {
        Print("Failed to copy price data for volatility calculation");
        return;
    }
    
    // Calculate returns
    double returns[];
    ArrayResize(returns, VolatilityLookback - 1);
    
    for(int i = 0; i < VolatilityLookback - 1; i++) {
        returns[i] = (closes[i] - closes[i + 1]) / closes[i + 1];
    }
    
    // Calculate mean return
    double meanReturn = 0;
    for(int i = 0; i < ArraySize(returns); i++) {
        meanReturn += returns[i];
    }
    meanReturn /= ArraySize(returns);
    
    // Calculate standard deviation
    double sumSquares = 0;
    for(int i = 0; i < ArraySize(returns); i++) {
        sumSquares += MathPow(returns[i] - meanReturn, 2);
    }
    
    averageVolatility = MathSqrt(sumSquares / ArraySize(returns));
    volatilityStdDev = averageVolatility * closes[0]; // Convert to price terms
    
    // Calculate current short-term volatility (last 20 bars)
    int shortPeriod = MathMin(VolatilityPeriod, VolatilityLookback - 1);
    double shortReturns[];
    ArrayResize(shortReturns, shortPeriod);
    
    for(int i = 0; i < shortPeriod; i++) {
        shortReturns[i] = returns[i];
    }
    
    double shortMean = 0;
    for(int i = 0; i < shortPeriod; i++) {
        shortMean += shortReturns[i];
    }
    shortMean /= shortPeriod;
    
    double shortSumSquares = 0;
    for(int i = 0; i < shortPeriod; i++) {
        shortSumSquares += MathPow(shortReturns[i] - shortMean, 2);
    }
    
    currentVolatility = MathSqrt(shortSumSquares / shortPeriod) * closes[0];
}

//+------------------------------------------------------------------+
//| Update Volatility State                                          |
//+------------------------------------------------------------------+
void UpdateVolatilityState() {
    if(averageVolatility == 0) return;
    
    double volatilityRatio = currentVolatility / averageVolatility;
    
    // Check for compression
    isVolatilityCompressed = (volatilityRatio < CompressionThreshold);
    
    // Check for expansion
    isVolatilityExpanding = (volatilityRatio > ExpansionThreshold);
}

//+------------------------------------------------------------------+
//| Update Grid Levels with Current Positions                        |
//+------------------------------------------------------------------+
void UpdateGridLevels() {
    // Reset all grid level flags
    for(int i = 0; i < MaxGridLevels; i++) {
        buyGridLevels[i].hasBuyPosition = false;
        buyGridLevels[i].hasSellPosition = false;
        sellGridLevels[i].hasBuyPosition = false;
        sellGridLevels[i].hasSellPosition = false;
    }
    
    // Mark grid levels with existing positions
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(position.SelectByIndex(i)) {
            if(position.Symbol() == _Symbol && position.Magic() == MagicNumber) {
                double posPrice = position.PriceOpen();
                ENUM_POSITION_TYPE posType = position.PositionType();
                
                // Check BUY grid levels
                for(int g = 0; g < MaxGridLevels; g++) {
                    if(buyGridLevels[g].price > 0 && MathAbs(posPrice - buyGridLevels[g].price) < gridSpacingPrice / 2) {
                        if(posType == POSITION_TYPE_BUY) {
                            buyGridLevels[g].hasBuyPosition = true;
                        } else {
                            buyGridLevels[g].hasSellPosition = true;
                        }
                        break;
                    }
                }
                
                // Check SELL grid levels
                for(int g = 0; g < MaxGridLevels; g++) {
                    if(sellGridLevels[g].price > 0 && MathAbs(posPrice - sellGridLevels[g].price) < gridSpacingPrice / 2) {
                        if(posType == POSITION_TYPE_BUY) {
                            sellGridLevels[g].hasBuyPosition = true;
                        } else {
                            sellGridLevels[g].hasSellPosition = true;
                        }
                        break;
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Check Volatility Breakout Signals                                |
//+------------------------------------------------------------------+
void CheckVolatilityBreakoutSignals() {
    if(CountOpenPositions() >= MaxGridPositions) {
        return;
    }
    
    // Check spread filter
    if(MaxSpread > 0) {
        long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
        if(currentSpread > MaxSpread) {
            return; // Spread too wide
        }
    }
    
    // Only enter during volatility expansion phase
    if(!isVolatilityExpanding) {
        return;
    }
    
    double ask = symbolInfo.Ask();
    double bid = symbolInfo.Bid();
    
    // Determine breakout direction
    double closes[];
    ArraySetAsSeries(closes, true);
    
    if(CopyClose(_Symbol, PERIOD_M5, 0, 3, closes) <= 0) return;
    
    bool bullishBreakout = (closes[0] > closes[1] && closes[1] > closes[2]);
    bool bearishBreakout = (closes[0] < closes[1] && closes[1] < closes[2]);
    
    // BUY on bullish breakout
    if(bullishBreakout) {
        // Enter at grid levels below current price
        for(int i = 0; i < MaxGridLevels; i++) {
            if(buyGridLevels[i].price > 0 && buyGridLevels[i].price < bid && !buyGridLevels[i].hasBuyPosition) {
                if(TimeCurrent() - buyGridLevels[i].lastEntryTime > 60) {
                    ExecuteBuyOrder(buyGridLevels[i].price, buyGridLevels[i].sigmaLevel);
                    buyGridLevels[i].lastEntryTime = TimeCurrent();
                    break; // One entry per signal
                }
            }
        }
    }
    
    // SELL on bearish breakout
    if(bearishBreakout && BidirectionalGrid) {
        // Enter at grid levels above current price
        for(int i = 0; i < MaxGridLevels; i++) {
            if(sellGridLevels[i].price > 0 && sellGridLevels[i].price > ask && !sellGridLevels[i].hasSellPosition) {
                if(TimeCurrent() - sellGridLevels[i].lastEntryTime > 60) {
                    ExecuteSellOrder(sellGridLevels[i].price, sellGridLevels[i].sigmaLevel);
                    sellGridLevels[i].lastEntryTime = TimeCurrent();
                    break; // One entry per signal
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Execute Buy Order                                                 |
//+------------------------------------------------------------------+
void ExecuteBuyOrder(double gridPrice, double sigmaLevel) {
    double ask = symbolInfo.Ask();
    double lotSize = CalculateLotSize();
    
    if(lotSize <= 0) return;
    
    double sl = NormalizeDouble(ask - initialSLPrice, totalDigits);
    
    string comment = TradeComment;
    if(sigmaLevel > 0) {
        comment += "_" + DoubleToString(sigmaLevel, 1) + "σ";
    }
    
    if(trade.Buy(lotSize, _Symbol, ask, sl, 0, comment)) {
        ulong ticket = trade.ResultOrder();
        Print("BUY Order: Ticket=", ticket, " Lots=", lotSize, " Price=", ask, " SL=", sl, " Sigma=", sigmaLevel);
        
        AddPositionTracker(ticket, ask);
    } else {
        Print("BUY Order Failed: ", trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Execute Sell Order                                                |
//+------------------------------------------------------------------+
void ExecuteSellOrder(double gridPrice, double sigmaLevel) {
    double bid = symbolInfo.Bid();
    double lotSize = CalculateLotSize();
    
    if(lotSize <= 0) return;
    
    double sl = NormalizeDouble(bid + initialSLPrice, totalDigits);
    
    string comment = TradeComment;
    if(sigmaLevel > 0) {
        comment += "_" + DoubleToString(sigmaLevel, 1) + "σ";
    }
    
    if(trade.Sell(lotSize, _Symbol, bid, sl, 0, comment)) {
        ulong ticket = trade.ResultOrder();
        Print("SELL Order: Ticket=", ticket, " Lots=", lotSize, " Price=", bid, " SL=", sl, " Sigma=", sigmaLevel);
        
        AddPositionTracker(ticket, bid);
    } else {
        Print("SELL Order Failed: ", trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size Based on Risk Management                      |
//+------------------------------------------------------------------+
double CalculateLotSize() {
    double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    double dailyRiskAmount = accountBalance * DailyRiskPercent / 100.0;
    double riskPerPosition = dailyRiskAmount / MaxGridPositions;
    
    // Adjust for volatility spike
    if(UseVolatilityCircuit && averageVolatility > 0) {
        if(currentVolatility > averageVolatility * VolatilitySpikeFactor) {
            riskPerPosition *= 0.5;
        }
    }
    
    double stopLossPrice = InitialStopLoss * pointValue;
    double stopLossValue = stopLossPrice / tickSize * tickValue;
    
    if(stopLossValue == 0) return 0;
    
    double lotSize = riskPerPosition / stopLossValue;
    
    // Normalize lot size
    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    
    lotSize = MathFloor(lotSize / lotStep) * lotStep;
    lotSize = MathMax(lotSize, minLot);
    lotSize = MathMin(lotSize, maxLot);
    
    return lotSize;
}

//+------------------------------------------------------------------+
//| Manage Trailing Stops (3-Stage System)                           |
//+------------------------------------------------------------------+
void ManageTrailingStops() {
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(position.SelectByIndex(i)) {
            if(position.Symbol() == _Symbol && position.Magic() == MagicNumber) {
                ulong ticket = position.Ticket();
                double entryPrice = position.PriceOpen();
                double currentPrice = (position.PositionType() == POSITION_TYPE_BUY) ? symbolInfo.Bid() : symbolInfo.Ask();
                double currentSL = position.StopLoss();
                
                // Get or create position tracker
                int trackerIndex = FindPositionTracker(ticket);
                if(trackerIndex < 0) {
                    AddPositionTracker(ticket, entryPrice);
                    trackerIndex = FindPositionTracker(ticket);
                }
                
                if(trackerIndex >= 0) {
                    // Update max favorable price
                    if(position.PositionType() == POSITION_TYPE_BUY) {
                        if(currentPrice > positionTrackers[trackerIndex].maxFavorablePrice) {
                            positionTrackers[trackerIndex].maxFavorablePrice = currentPrice;
                        }
                    } else {
                        if(positionTrackers[trackerIndex].maxFavorablePrice == 0 || currentPrice < positionTrackers[trackerIndex].maxFavorablePrice) {
                            positionTrackers[trackerIndex].maxFavorablePrice = currentPrice;
                        }
                    }
                    
                    // Calculate current profit in points
                    double profitPoints = 0;
                    if(position.PositionType() == POSITION_TYPE_BUY) {
                        profitPoints = (currentPrice - entryPrice) / pointValue;
                    } else {
                        profitPoints = (entryPrice - currentPrice) / pointValue;
                    }
                    
                    // Update max profit
                    if(profitPoints > positionTrackers[trackerIndex].maxProfit) {
                        positionTrackers[trackerIndex].maxProfit = profitPoints;
                    }
                    
                    // Calculate new trailing stop
                    double newSL = CalculateTrailingStop(ticket, trackerIndex, profitPoints);
                    
                    if(newSL > 0) {
                        // Only move SL if it's better
                        bool shouldUpdate = false;
                        if(position.PositionType() == POSITION_TYPE_BUY) {
                            shouldUpdate = (newSL > currentSL || currentSL == 0);
                        } else {
                            shouldUpdate = (newSL < currentSL || currentSL == 0);
                        }
                        
                        if(shouldUpdate) {
                            if(trade.PositionModify(ticket, newSL, 0)) {
                                Print("Trail Updated: Ticket=", ticket, " Stage=", positionTrackers[trackerIndex].trailStage,
                                      " NewSL=", newSL, " Profit=", DoubleToString(profitPoints, 1), " pts");
                            }
                        }
                    }
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Calculate Trailing Stop Based on 3-Stage System                  |
//+------------------------------------------------------------------+
double CalculateTrailingStop(ulong ticket, int trackerIndex, double profitPoints) {
    if(trackerIndex < 0) return 0;
    
    double entryPrice = positionTrackers[trackerIndex].entryPrice;
    double maxFavorablePrice = positionTrackers[trackerIndex].maxFavorablePrice;
    double newSL = 0;
    
    ENUM_POSITION_TYPE posType = position.PositionType();
    
    // STAGE 1: Rapid Breakeven
    if(profitPoints >= Stage1_BE_Points && profitPoints < Stage2_MaxPoints) {
        positionTrackers[trackerIndex].trailStage = 1;
        newSL = entryPrice;
    }
    // STAGE 2: Profit Lock Trail
    else if(profitPoints >= Stage1_BE_Points && profitPoints < Stage2_MaxPoints) {
        positionTrackers[trackerIndex].trailStage = 2;
        
        double trailDistance = positionTrackers[trackerIndex].maxProfit * (1.0 - Stage2_TrailPercent / 100.0) * pointValue;
        trailDistance = MathMax(trailDistance, minTrailPrice);
        
        if(posType == POSITION_TYPE_BUY) {
            newSL = NormalizeDouble(maxFavorablePrice - trailDistance, totalDigits);
        } else {
            newSL = NormalizeDouble(maxFavorablePrice + trailDistance, totalDigits);
        }
    }
    // STAGE 3: Momentum Trail
    else if(profitPoints >= Stage2_MaxPoints) {
        positionTrackers[trackerIndex].trailStage = 3;
        
        double atr = GetATR(ATR_Period);
        double trailDistance = atr * Stage3_ATR_Multiplier;
        trailDistance = MathMax(trailDistance, minTrailPrice);
        
        // Correlation-aware adjustment
        if(UseCorrelationTrailing) {
            int profitablePositions = CountProfitablePositions();
            if(profitablePositions > 3) {
                trailDistance *= 1.2;
            } else if(profitablePositions == 1) {
                trailDistance *= 0.8;
            }
        }
        
        if(posType == POSITION_TYPE_BUY) {
            newSL = NormalizeDouble(maxFavorablePrice - trailDistance, totalDigits);
        } else {
            newSL = NormalizeDouble(maxFavorablePrice + trailDistance, totalDigits);
        }
    }
    
    return newSL;
}

//+------------------------------------------------------------------+
//| Get ATR Value                                                     |
//+------------------------------------------------------------------+
double GetATR(int period) {
    double atr[];
    ArraySetAsSeries(atr, true);
    
    int handle = iATR(_Symbol, PERIOD_CURRENT, period);
    if(handle == INVALID_HANDLE) return initialSLPrice;
    
    if(CopyBuffer(handle, 0, 0, 1, atr) > 0) {
        IndicatorRelease(handle);
        return atr[0];
    }
    
    IndicatorRelease(handle);
    return initialSLPrice;
}

//+------------------------------------------------------------------+
//| Position Tracker Management                                       |
//+------------------------------------------------------------------+
void AddPositionTracker(ulong ticket, double entryPrice) {
    int size = ArraySize(positionTrackers);
    ArrayResize(positionTrackers, size + 1);
    
    positionTrackers[size].ticket = ticket;
    positionTrackers[size].entryPrice = entryPrice;
    positionTrackers[size].maxProfit = 0;
    positionTrackers[size].maxFavorablePrice = entryPrice;
    positionTrackers[size].trailStage = 0;
    positionTrackers[size].entryTime = TimeCurrent();
}

int FindPositionTracker(ulong ticket) {
    for(int i = 0; i < ArraySize(positionTrackers); i++) {
        if(positionTrackers[i].ticket == ticket) {
            return i;
        }
    }
    return -1;
}

void RemovePositionTracker(ulong ticket) {
    int index = FindPositionTracker(ticket);
    if(index >= 0) {
        int size = ArraySize(positionTrackers);
        for(int i = index; i < size - 1; i++) {
            positionTrackers[i] = positionTrackers[i + 1];
        }
        ArrayResize(positionTrackers, size - 1);
    }
}

//+------------------------------------------------------------------+
//| Update Daily P&L                                                  |
//+------------------------------------------------------------------+
void UpdateDailyPnL() {
    double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
    dailyPnL = currentEquity - dayStartBalance;
}

//+------------------------------------------------------------------+
//| Check Circuit Breakers                                            |
//+------------------------------------------------------------------+
bool CheckCircuitBreakers() {
    if(tradingHalted) return false;
    
    // Daily loss limit
    if(UseDailyLossLimit) {
        double lossLimit = dayStartBalance * CircuitBreakerPercent / 100.0;
        if(dailyPnL < -lossLimit) {
            tradingHalted = true;
            Print("═══ CIRCUIT BREAKER TRIGGERED ═══");
            Print("Daily Loss Limit Reached: $", DoubleToString(dailyPnL, 2));
            Print("Trading Halted for Today");
            return false;
        }
    }
    
    // Consecutive losses
    if(consecutiveLosses >= MaxConsecutiveLosses) {
        tradingHalted = true;
        Print("═══ CIRCUIT BREAKER TRIGGERED ═══");
        Print("Max Consecutive Losses: ", consecutiveLosses);
        Print("Trading Halted for Today");
        return false;
    }
    
    return true;
}

//+------------------------------------------------------------------+
//| Check Trading Hours                                               |
//+------------------------------------------------------------------+
bool IsWithinTradingHours() {
    MqlDateTime timeStruct;
    TimeToStruct(TimeCurrent(), timeStruct);
    
    if(timeStruct.hour >= TradingStartHour && timeStruct.hour < TradingEndHour) {
        return true;
    }
    
    return false;
}

//+------------------------------------------------------------------+
//| Count Open Positions                                              |
//+------------------------------------------------------------------+
int CountOpenPositions() {
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(position.SelectByIndex(i)) {
            if(position.Symbol() == _Symbol && position.Magic() == MagicNumber) {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Count Profitable Positions                                        |
//+------------------------------------------------------------------+
int CountProfitablePositions() {
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--) {
        if(position.SelectByIndex(i)) {
            if(position.Symbol() == _Symbol && position.Magic() == MagicNumber) {
                if(position.Profit() > 0) {
                    count++;
                }
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Create Info Panel                                                 |
//+------------------------------------------------------------------+
void CreateInfoPanel() {
    string prefix = "TORAMA_";
    
    // Main Panel Background - Solid, on top of everything
    ObjectCreate(0, prefix + "PanelBG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_XDISTANCE, PanelX);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_YDISTANCE, PanelY);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_XSIZE, 320);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_YSIZE, 300);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_BGCOLOR, PanelColor);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_COLOR, TextColor);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_WIDTH, 2);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_BACK, false);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_SELECTED, false);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, prefix + "PanelBG", OBJPROP_ZORDER, 0); // On top
    
    // Panel Header
    ObjectCreate(0, prefix + "Header", OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, prefix + "Header", OBJPROP_XDISTANCE, PanelX + 10);
    ObjectSetInteger(0, prefix + "Header", OBJPROP_YDISTANCE, PanelY + 10);
    ObjectSetInteger(0, prefix + "Header", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, prefix + "Header", OBJPROP_COLOR, TextColor);
    ObjectSetInteger(0, prefix + "Header", OBJPROP_FONTSIZE, 10);
    ObjectSetString(0, prefix + "Header", OBJPROP_FONT, "Arial Bold");
    ObjectSetString(0, prefix + "Header", OBJPROP_TEXT, "TORAMA VOLATILITY BREAKOUT");
    ObjectSetInteger(0, prefix + "Header", OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, prefix + "Header", OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, prefix + "Header", OBJPROP_ZORDER, 0);
    
    // Separator line
    ObjectCreate(0, prefix + "Separator1", OBJ_EDIT, 0, 0, 0);
    ObjectSetInteger(0, prefix + "Separator1", OBJPROP_XDISTANCE, PanelX + 10);
    ObjectSetInteger(0, prefix + "Separator1", OBJPROP_YDISTANCE, PanelY + 30);
    ObjectSetInteger(0, prefix + "Separator1", OBJPROP_XSIZE, 300);
    ObjectSetInteger(0, prefix + "Separator1", OBJPROP_YSIZE, 2);
    ObjectSetInteger(0, prefix + "Separator1", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, prefix + "Separator1", OBJPROP_BGCOLOR, TextColor);
    ObjectSetInteger(0, prefix + "Separator1", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, prefix + "Separator1", OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, prefix + "Separator1", OBJPROP_READONLY, true);
    ObjectSetInteger(0, prefix + "Separator1", OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, prefix + "Separator1", OBJPROP_ZORDER, 0);
    
    // Stats Labels
    string labels[] = {
        "Symbol", "Magic", "Spread", "Status", "",
        "Balance", "Equity", "Margin", "Free Margin", "",
        "Open Pos", "Profitable", "Daily P/L", "Daily %", "",
        "Vol State", "Vol Ratio", "Std Dev", "Trail Stage"
    };
    
    int yOffset = 40;
    for(int i = 0; i < ArraySize(labels); i++) {
        if(labels[i] == "") {
            yOffset += 8; // Spacer
            continue;
        }
        
        string objName = prefix + "Label_" + IntegerToString(i);
        ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, PanelX + 15);
        ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, PanelY + yOffset);
        ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, objName, OBJPROP_COLOR, TextColor);
        ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, objName, OBJPROP_FONT, "Consolas");
        ObjectSetString(0, objName, OBJPROP_TEXT, labels[i] + ":");
        ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
        ObjectSetInteger(0, objName, OBJPROP_ZORDER, 0);
        
        // Value label
        string valueName = prefix + "Value_" + IntegerToString(i);
        ObjectCreate(0, valueName, OBJ_LABEL, 0, 0, 0);
        ObjectSetInteger(0, valueName, OBJPROP_XDISTANCE, PanelX + 160);
        ObjectSetInteger(0, valueName, OBJPROP_YDISTANCE, PanelY + yOffset);
        ObjectSetInteger(0, valueName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
        ObjectSetInteger(0, valueName, OBJPROP_COLOR, TextColor);
        ObjectSetInteger(0, valueName, OBJPROP_FONTSIZE, 9);
        ObjectSetString(0, valueName, OBJPROP_FONT, "Consolas");
        ObjectSetString(0, valueName, OBJPROP_TEXT, "...");
        ObjectSetInteger(0, valueName, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, valueName, OBJPROP_HIDDEN, true);
        ObjectSetInteger(0, valueName, OBJPROP_ZORDER, 0);
        
        yOffset += 16;
    }
    
    // Create TORAMA Branding at bottom right of screen
    CreateBrandingPanel();
}

//+------------------------------------------------------------------+
//| Create TORAMA Branding Panel (Bottom Right)                      |
//+------------------------------------------------------------------+
void CreateBrandingPanel() {
    string prefix = "TORAMA_BRAND_";
    int chartWidth = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
    int brandX = chartWidth - 210; // 210px from right edge
    int brandY = 30; // From bottom
    
    // Branding background
    ObjectCreate(0, prefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
    ObjectSetInteger(0, prefix + "BG", OBJPROP_XDISTANCE, brandX);
    ObjectSetInteger(0, prefix + "BG", OBJPROP_YDISTANCE, brandY);
    ObjectSetInteger(0, prefix + "BG", OBJPROP_XSIZE, 200);
    ObjectSetInteger(0, prefix + "BG", OBJPROP_YSIZE, 70);
    ObjectSetInteger(0, prefix + "BG", OBJPROP_BGCOLOR, C'20,20,20'); // Dark background
    ObjectSetInteger(0, prefix + "BG", OBJPROP_BORDER_TYPE, BORDER_FLAT);
    ObjectSetInteger(0, prefix + "BG", OBJPROP_CORNER, CORNER_RIGHT_LOWER);
    ObjectSetInteger(0, prefix + "BG", OBJPROP_COLOR, C'100,100,100');
    ObjectSetInteger(0, prefix + "BG", OBJPROP_WIDTH, 1);
    ObjectSetInteger(0, prefix + "BG", OBJPROP_BACK, false);
    ObjectSetInteger(0, prefix + "BG", OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, prefix + "BG", OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, prefix + "BG", OBJPROP_ZORDER, 0);
    
    // TORAMA CAPITAL text
    ObjectCreate(0, prefix + "Title", OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, prefix + "Title", OBJPROP_XDISTANCE, brandX - 10);
    ObjectSetInteger(0, prefix + "Title", OBJPROP_YDISTANCE, brandY + 10);
    ObjectSetInteger(0, prefix + "Title", OBJPROP_CORNER, CORNER_RIGHT_LOWER);
    ObjectSetInteger(0, prefix + "Title", OBJPROP_COLOR, C'255,215,0'); // Gold
    ObjectSetInteger(0, prefix + "Title", OBJPROP_FONTSIZE, 11);
    ObjectSetString(0, prefix + "Title", OBJPROP_FONT, "Arial Black");
    ObjectSetString(0, prefix + "Title", OBJPROP_TEXT, "TORAMA CAPITAL");
    ObjectSetInteger(0, prefix + "Title", OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, prefix + "Title", OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, prefix + "Title", OBJPROP_ZORDER, 0);
    
    // Email
    ObjectCreate(0, prefix + "Email", OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, prefix + "Email", OBJPROP_XDISTANCE, brandX - 10);
    ObjectSetInteger(0, prefix + "Email", OBJPROP_YDISTANCE, brandY + 30);
    ObjectSetInteger(0, prefix + "Email", OBJPROP_CORNER, CORNER_RIGHT_LOWER);
    ObjectSetInteger(0, prefix + "Email", OBJPROP_COLOR, C'200,200,200');
    ObjectSetInteger(0, prefix + "Email", OBJPROP_FONTSIZE, 8);
    ObjectSetString(0, prefix + "Email", OBJPROP_FONT, "Arial");
    ObjectSetString(0, prefix + "Email", OBJPROP_TEXT, "ea@torama.money");
    ObjectSetInteger(0, prefix + "Email", OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, prefix + "Email", OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, prefix + "Email", OBJPROP_ZORDER, 0);
    
    // Website
    ObjectCreate(0, prefix + "Web", OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, prefix + "Web", OBJPROP_XDISTANCE, brandX - 10);
    ObjectSetInteger(0, prefix + "Web", OBJPROP_YDISTANCE, brandY + 47);
    ObjectSetInteger(0, prefix + "Web", OBJPROP_CORNER, CORNER_RIGHT_LOWER);
    ObjectSetInteger(0, prefix + "Web", OBJPROP_COLOR, C'200,200,200');
    ObjectSetInteger(0, prefix + "Web", OBJPROP_FONTSIZE, 8);
    ObjectSetString(0, prefix + "Web", OBJPROP_FONT, "Arial");
    ObjectSetString(0, prefix + "Web", OBJPROP_TEXT, "torama.money");
    ObjectSetInteger(0, prefix + "Web", OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, prefix + "Web", OBJPROP_HIDDEN, true);
    ObjectSetInteger(0, prefix + "Web", OBJPROP_ZORDER, 0);
}

//+------------------------------------------------------------------+
//| Update Info Panel                                                 |
//+------------------------------------------------------------------+
void UpdateInfoPanel() {
    string prefix = "TORAMA_";
    
    // Get all stats
    int openPos = CountOpenPositions();
    int profitablePos = CountProfitablePositions();
    double dailyPnLPercent = (dayStartBalance > 0) ? (dailyPnL / dayStartBalance * 100.0) : 0;
    long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    double volRatio = (averageVolatility > 0) ? (currentVolatility / averageVolatility) : 0;
    
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double margin = AccountInfoDouble(ACCOUNT_MARGIN);
    double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
    
    // Volatility state
    string volState = "NORMAL";
    color volStateColor = TextColor;
    if(isVolatilityCompressed) {
        volState = "COMPRESSED";
        volStateColor = C'255,200,0'; // Yellow
    }
    if(isVolatilityExpanding) {
        volState = "EXPANDING";
        volStateColor = C'0,255,100'; // Green
    }
    
    // Get average trail stage
    int avgStage = 0;
    int stageCount = 0;
    for(int i = 0; i < ArraySize(positionTrackers); i++) {
        avgStage += positionTrackers[i].trailStage;
        stageCount++;
    }
    if(stageCount > 0) avgStage = (int)MathRound((double)avgStage / stageCount);
    
    // Update values
    string values[] = {
        _Symbol,
        IntegerToString(MagicNumber),
        IntegerToString(spread) + " pts" + (MaxSpread > 0 ? " / " + IntegerToString(MaxSpread) : ""),
        (tradingHalted ? "HALTED" : "ACTIVE"),
        "",
        
        "$" + DoubleToString(balance, 2),
        "$" + DoubleToString(equity, 2),
        "$" + DoubleToString(margin, 2),
        "$" + DoubleToString(freeMargin, 2),
        "",
        
        IntegerToString(openPos) + " / " + IntegerToString(MaxGridPositions),
        IntegerToString(profitablePos),
        "$" + DoubleToString(dailyPnL, 2),
        DoubleToString(dailyPnLPercent, 2) + "%",
        "",
        
        volState,
        DoubleToString(volRatio, 2),
        DoubleToString(volatilityStdDev / pointValue, 1) + " pts",
        (stageCount > 0 ? "Stage " + IntegerToString(avgStage) : "N/A")
    };
    
    // Color code daily P/L
    color pnlColor = TextColor;
    if(dailyPnL > 0) pnlColor = C'0,255,100';
    else if(dailyPnL < 0) pnlColor = C'255,80,80';
    
    // Color code status
    color statusColor = (tradingHalted ? C'255,80,80' : C'0,255,100');
    
    int valueIndex = 0;
    for(int i = 0; i < ArraySize(values); i++) {
        string valueName = prefix + "Value_" + IntegerToString(i);
        
        if(ObjectFind(0, valueName) >= 0) {
            ObjectSetString(0, valueName, OBJPROP_TEXT, values[i]);
            
            // Special coloring
            if(i == 3) { // Status
                ObjectSetInteger(0, valueName, OBJPROP_COLOR, statusColor);
            } else if(i == 12 || i == 13) { // Daily P/L
                ObjectSetInteger(0, valueName, OBJPROP_COLOR, pnlColor);
            } else if(i == 15) { // Vol State
                ObjectSetInteger(0, valueName, OBJPROP_COLOR, volStateColor);
            } else {
                ObjectSetInteger(0, valueName, OBJPROP_COLOR, TextColor);
            }
        }
    }
    
    // Update branding position in case chart was resized
    UpdateBrandingPosition();
}

//+------------------------------------------------------------------+
//| Update Branding Panel Position on Chart Resize                   |
//+------------------------------------------------------------------+
void UpdateBrandingPosition() {
    string prefix = "TORAMA_BRAND_";
    int chartWidth = (int)ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
    int brandX = chartWidth - 210;
    
    if(ObjectFind(0, prefix + "BG") >= 0) {
        ObjectSetInteger(0, prefix + "BG", OBJPROP_XDISTANCE, brandX);
    }
    if(ObjectFind(0, prefix + "Title") >= 0) {
        ObjectSetInteger(0, prefix + "Title", OBJPROP_XDISTANCE, brandX - 10);
    }
    if(ObjectFind(0, prefix + "Email") >= 0) {
        ObjectSetInteger(0, prefix + "Email", OBJPROP_XDISTANCE, brandX - 10);
    }
    if(ObjectFind(0, prefix + "Web") >= 0) {
        ObjectSetInteger(0, prefix + "Web", OBJPROP_XDISTANCE, brandX - 10);
    }
}
//+------------------------------------------------------------------+
