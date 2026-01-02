//+------------------------------------------------------------------+
//|                                 TORAMA_MeanReversion_Grid_EA.mq5 |
//|                                      Copyright 2025, TORAMA CAPITAL |
//|                                           https://torama.money      |
//|                                           ea@torama.money           |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, TORAMA CAPITAL"
#property link      "https://torama.money"
#property version   "1.00"
#property description "Mean Reversion Grid EA - Fixed percentage grid with directional trading"
#property description "Buys down, sells up with global profit target"

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== Grid Settings ==="
input double InpGridGapPercent = 0.5;              // Grid Gap (% of price)
input double InpInitialLot = 0.01;                 // Initial Lot Size
input double InpLotMultiplier = 1.0;               // Lot Multiplier
input int InpMaxPositions = 0;                     // Max Positions (0=Unlimited)
input double InpGlobalProfitPercent = 0.1;         // Global Profit Target (% of balance)

input group "=== Trading Direction ==="
enum ENUM_TRADE_DIRECTION
{
   DIRECTION_BOTH = 0,        // Both (Buy & Sell)
   DIRECTION_BUY_ONLY = 1,    // Buy Only (down from reference)
   DIRECTION_SELL_ONLY = 2    // Sell Only (up from reference)
};
input ENUM_TRADE_DIRECTION InpDirection = DIRECTION_BOTH; // Trading Direction

input group "=== Risk Management ==="
input double InpMaxDrawdownPercent = 5.0;         // Max Drawdown (% of balance)
input bool InpUseHardStop = true;                 // Use Hard Stop Loss
input bool InpCloseAllAtMaxDD = true;             // Close All at Max Drawdown
input bool InpPauseAfterHardStop = true;          // Pause After Hard Stop
input int InpHardStopCooldownMinutes = 30;        // Hard Stop Cooldown (minutes)

input group "=== Trend Filter ==="
input bool InpUseADXFilter = true;                // Use ADX Trend Filter
input int InpADXPeriod = 14;                      // ADX Period
input double InpADXThreshold = 25.0;              // ADX Threshold (trend > value)
input ENUM_TIMEFRAMES InpADXTimeframe = PERIOD_M15; // ADX Timeframe
input bool InpUseDirectionalBias = true;          // Use Directional Bias in Trends

input group "=== Order Execution ==="
input bool InpUsePendingOrders = true;            // Use Pending Orders
input int InpSlippage = 10;                       // Slippage (points)
input int InpMagicNumber = 0;                     // Magic Number (0=ChartID)

input group "=== EA Control ==="
input string InpCommentPrefix = "TORAMA_MR";      // Comment Prefix

//--- Global variables
CTrade trade;
int g_magic_number;
double g_reference_price = 0.0;
double g_grid_gap_points = 0.0;
bool g_ea_paused = false;
datetime g_last_daily_reset = 0;
double g_daily_start_balance = 0.0;
double g_daily_profit_loss = 0.0;
int g_cycle_count = 0;

//--- Hard stop tracking
datetime g_last_hard_stop_time = 0;
bool g_in_cooldown = false;
datetime g_cooldown_end_time = 0;

//--- Reinitialization protection
bool g_is_reinitialization = false;

//--- ADX indicator variables
int g_adx_handle = INVALID_HANDLE;
double g_adx_buffer[];
double g_plus_di_buffer[];
double g_minus_di_buffer[];
bool g_is_trending = false;
bool g_is_uptrend = false;
bool g_is_downtrend = false;
string g_market_condition = "RANGING";

//--- Panel variables
int g_panel_x = 20;
int g_panel_y = 50;
int g_panel_width = 280;
int g_panel_height = 420;
string g_panel_name = "TORAMA_MR_Panel";

//--- Button definitions
struct ButtonInfo
{
   string name;
   int x;
   int y;
   int width;
   int height;
   color bg_color;
   color text_color;
   string text;
};

ButtonInfo g_buttons[];

//--- Broker properties
double g_min_lot = 0.01;
double g_max_lot = 100.0;
double g_lot_step = 0.01;
int g_digits = 5;
double g_point = 0.00001;
double g_tick_size = 0.00001;
double g_tick_value = 0.0;
int g_freeze_level = 0;
int g_stop_level = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- First, set magic number to check against
   int temp_magic = (InpMagicNumber == 0) ? (int)ChartID() : InpMagicNumber;
   
   //--- Check if there are existing positions with this magic number
   g_is_reinitialization = false;
   int existing_positions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == temp_magic)
      {
         g_is_reinitialization = true;
         existing_positions++;
      }
   }
   
   if(g_is_reinitialization)
      Print("EA Reinitialization detected - ", existing_positions, " existing positions will be preserved");
   
   //--- Set magic number
   g_magic_number = temp_magic;
   trade.SetExpertMagicNumber(g_magic_number);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   trade.SetAsyncMode(false);
   
   //--- Get broker properties
   if(!InitializeBrokerProperties())
   {
      Print("Failed to initialize broker properties");
      return INIT_FAILED;
   }
   
   //--- Validate inputs
   if(!ValidateInputs())
   {
      Print("Invalid input parameters");
      return INIT_FAILED;
   }
   
   //--- Calculate grid gap
   CalculateGridGap();
   
   //--- Initialize ADX indicator
   if(InpUseADXFilter)
   {
      if(!InitializeADX())
      {
         Print("Failed to initialize ADX indicator");
         return INIT_FAILED;
      }
   }
   
   //--- Initialize reference price from existing positions or current price
   InitializeReferencePrice();
   
   //--- Initialize daily tracking
   InitializeDailyTracking();
   
   //--- Create UI panel
   CreatePanel();
   
   //--- Update panel
   UpdatePanel();
   
   Print("TORAMA Mean Reversion Grid EA initialized successfully");
   Print("Magic Number: ", g_magic_number);
   Print("Reference Price: ", g_reference_price);
   Print("Grid Gap: ", g_grid_gap_points, " points (", InpGridGapPercent, "%)");
   Print("Global Profit Target: ", InpGlobalProfitPercent, "%");
   Print("ADX Filter: ", (InpUseADXFilter ? "Enabled" : "Disabled"));
   Print("Directional Bias: ", (InpUseDirectionalBias ? "Enabled" : "Disabled"));
   Print("Hard Stop Loss: ", (InpUseHardStop ? "Enabled" : "Disabled"));
   if(InpUseHardStop)
   {
      Print("  Pause After Hard Stop: ", (InpPauseAfterHardStop ? "Yes" : "No"));
      Print("  Cooldown Period: ", InpHardStopCooldownMinutes, " minutes");
   }
   
   if(g_is_reinitialization)
   {
      Print("=================================================================");
      Print("REINITIALIZATION NOTICE:");
      Print("Settings have been changed while EA was active.");
      Print("All existing positions and pending orders have been preserved.");
      Print("New settings will apply to future trades only.");
      Print("=================================================================");
   }
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Release ADX indicator
   if(g_adx_handle != INVALID_HANDLE)
      IndicatorRelease(g_adx_handle);
   
   //--- Delete all panel objects
   DeletePanel();
   
   Comment("");
   
   Print("TORAMA Mean Reversion Grid EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Update daily tracking
   UpdateDailyTracking();
   
   //--- Update ADX and market conditions
   if(InpUseADXFilter)
      UpdateMarketConditions();
   
   //--- Check if in cooldown period
   if(g_in_cooldown)
   {
      datetime current_time = TimeCurrent();
      if(current_time >= g_cooldown_end_time)
      {
         g_in_cooldown = false;
         Print("Cooldown period ended. EA ready to trade.");
         
         // If pause after hard stop is disabled, resume automatically
         if(!InpPauseAfterHardStop)
         {
            g_ea_paused = false;
            Print("EA auto-resumed after cooldown.");
         }
      }
      else
      {
         int remaining_seconds = (int)(g_cooldown_end_time - current_time);
         int remaining_minutes = remaining_seconds / 60;
         // Comment(StringFormat("Cooldown: %d minutes remaining", remaining_minutes));
      }
      
      UpdatePanel();
      return;
   }
   
   //--- Check if EA is paused
   if(g_ea_paused)
   {
      UpdatePanel();
      return;
   }
   
   //--- Check drawdown limit with hard stop
   if(IsDrawdownLimitReached())
   {
      if(InpUseHardStop && InpCloseAllAtMaxDD)
      {
         Print("Max drawdown limit reached. Hard stop activated - closing all positions.");
         CloseAllPositions();
         g_cycle_count++;
         RecalculateReferencePrice();
         
         // Record hard stop time
         g_last_hard_stop_time = TimeCurrent();
         
         // Start cooldown period
         if(InpHardStopCooldownMinutes > 0)
         {
            g_in_cooldown = true;
            g_cooldown_end_time = g_last_hard_stop_time + (InpHardStopCooldownMinutes * 60);
            Print(StringFormat("Hard stop cooldown started. Will resume in %d minutes at %s", 
                  InpHardStopCooldownMinutes, 
                  TimeToString(g_cooldown_end_time, TIME_DATE|TIME_MINUTES)));
         }
         
         // Pause EA if configured
         if(InpPauseAfterHardStop)
         {
            g_ea_paused = true;
            Print("EA paused after hard stop. Click 'Resume EA' button to continue trading.");
         }
         else if(InpHardStopCooldownMinutes == 0)
         {
            // No cooldown and no pause - rebuild orders immediately
            if(InpUsePendingOrders)
               RebuildPendingOrders();
            Print("EA continuing immediately after hard stop (no cooldown, no pause).");
         }
      }
      else
      {
         Print("Max drawdown limit reached. Pausing EA.");
         g_ea_paused = true;
      }
      
      UpdatePanel();
      return;
   }
   
   //--- Check for global profit target
   if(CheckGlobalProfit())
   {
      Print("Global profit target reached. Taking profit.");
      CloseAllPositions();
      g_cycle_count++;
      RecalculateReferencePrice();
      if(InpUsePendingOrders)
         RebuildPendingOrders();
      UpdatePanel();
      return;
   }
   
   //--- Manage grid positions
   ManageGrid();
   
   //--- Update panel
   UpdatePanel();
}

//+------------------------------------------------------------------+
//| Chart event handler                                              |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      HandleButtonClick(sparam);
   }
}

//+------------------------------------------------------------------+
//| Initialize broker properties                                     |
//+------------------------------------------------------------------+
bool InitializeBrokerProperties()
{
   string symbol = _Symbol;
   
   g_min_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   g_max_lot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   g_lot_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   g_digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   g_point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   g_tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   g_tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   g_freeze_level = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   g_stop_level = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   
   //--- Validate critical properties
   if(g_min_lot <= 0 || g_max_lot <= 0 || g_lot_step <= 0 || g_point <= 0)
   {
      Print("Invalid broker properties detected");
      return false;
   }
   
   Print("Broker Properties:");
   Print("  Min Lot: ", g_min_lot);
   Print("  Max Lot: ", g_max_lot);
   Print("  Lot Step: ", g_lot_step);
   Print("  Digits: ", g_digits);
   Print("  Point: ", g_point);
   Print("  Freeze Level: ", g_freeze_level);
   Print("  Stop Level: ", g_stop_level);
   
   return true;
}

//+------------------------------------------------------------------+
//| Validate input parameters                                        |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   if(InpGridGapPercent <= 0 || InpGridGapPercent > 10)
   {
      Print("Invalid Grid Gap Percent: ", InpGridGapPercent);
      return false;
   }
   
   if(InpInitialLot < g_min_lot || InpInitialLot > g_max_lot)
   {
      Print("Invalid Initial Lot Size: ", InpInitialLot);
      return false;
   }
   
   if(InpLotMultiplier < 0.1 || InpLotMultiplier > 10)
   {
      Print("Invalid Lot Multiplier: ", InpLotMultiplier);
      return false;
   }
   
   if(InpGlobalProfitPercent <= 0 || InpGlobalProfitPercent > 100)
   {
      Print("Invalid Global Profit Percent: ", InpGlobalProfitPercent);
      return false;
   }
   
   if(InpMaxDrawdownPercent <= 0 || InpMaxDrawdownPercent > 100)
   {
      Print("Invalid Max Drawdown Percent: ", InpMaxDrawdownPercent);
      return false;
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Initialize ADX indicator                                         |
//+------------------------------------------------------------------+
bool InitializeADX()
{
   g_adx_handle = iADX(_Symbol, InpADXTimeframe, InpADXPeriod);
   
   if(g_adx_handle == INVALID_HANDLE)
   {
      Print("Failed to create ADX indicator handle. Error: ", GetLastError());
      return false;
   }
   
   ArraySetAsSeries(g_adx_buffer, true);
   ArraySetAsSeries(g_plus_di_buffer, true);
   ArraySetAsSeries(g_minus_di_buffer, true);
   
   Print("ADX indicator initialized successfully");
   Print("  Period: ", InpADXPeriod);
   Print("  Timeframe: ", EnumToString(InpADXTimeframe));
   Print("  Threshold: ", InpADXThreshold);
   
   return true;
}

//+------------------------------------------------------------------+
//| Update market conditions based on ADX                            |
//+------------------------------------------------------------------+
void UpdateMarketConditions()
{
   if(g_adx_handle == INVALID_HANDLE)
      return;
   
   //--- Copy ADX values
   if(CopyBuffer(g_adx_handle, 0, 0, 3, g_adx_buffer) <= 0)
   {
      Print("Failed to copy ADX main buffer");
      return;
   }
   
   if(CopyBuffer(g_adx_handle, 1, 0, 3, g_plus_di_buffer) <= 0)
   {
      Print("Failed to copy +DI buffer");
      return;
   }
   
   if(CopyBuffer(g_adx_handle, 2, 0, 3, g_minus_di_buffer) <= 0)
   {
      Print("Failed to copy -DI buffer");
      return;
   }
   
   //--- Current ADX value
   double adx_current = g_adx_buffer[0];
   double plus_di = g_plus_di_buffer[0];
   double minus_di = g_minus_di_buffer[0];
   
   //--- Determine if trending
   g_is_trending = (adx_current > InpADXThreshold);
   
   //--- Determine trend direction
   if(g_is_trending)
   {
      g_is_uptrend = (plus_di > minus_di);
      g_is_downtrend = (minus_di > plus_di);
      
      if(g_is_uptrend)
         g_market_condition = "UPTREND";
      else if(g_is_downtrend)
         g_market_condition = "DOWNTREND";
      else
         g_market_condition = "TRENDING";
   }
   else
   {
      g_is_uptrend = false;
      g_is_downtrend = false;
      g_market_condition = "RANGING";
   }
}

//+------------------------------------------------------------------+
//| Calculate grid gap in points                                     |
//+------------------------------------------------------------------+
void CalculateGridGap()
{
   double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double gap_in_price = current_price * (InpGridGapPercent / 100.0);
   g_grid_gap_points = NormalizeDouble(gap_in_price / g_point, 0);
   
   //--- Ensure minimum gap
   if(g_grid_gap_points < g_stop_level * 2)
   {
      g_grid_gap_points = g_stop_level * 2;
      Print("Grid gap adjusted to minimum: ", g_grid_gap_points, " points");
   }
}

//+------------------------------------------------------------------+
//| Initialize reference price                                       |
//+------------------------------------------------------------------+
void InitializeReferencePrice()
{
   //--- Try to get reference from existing positions
   double buy_avg = 0, sell_avg = 0;
   int buy_count = 0, sell_count = 0;
   bool has_existing_positions = false;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == g_magic_number)
      {
         has_existing_positions = true;
         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         
         if(type == POSITION_TYPE_BUY)
         {
            buy_avg += open_price;
            buy_count++;
         }
         else if(type == POSITION_TYPE_SELL)
         {
            sell_avg += open_price;
            sell_count++;
         }
      }
   }
   
   //--- Calculate reference based on existing positions
   if(buy_count > 0 && sell_count > 0)
   {
      buy_avg /= buy_count;
      sell_avg /= sell_count;
      g_reference_price = (buy_avg + sell_avg) / 2.0;
      if(g_is_reinitialization)
         Print("Reinitialization: Reference price calculated from existing positions: ", g_reference_price);
   }
   else if(buy_count > 0)
   {
      buy_avg /= buy_count;
      g_reference_price = buy_avg + (g_grid_gap_points * g_point);
      if(g_is_reinitialization)
         Print("Reinitialization: Reference price calculated from BUY positions: ", g_reference_price);
   }
   else if(sell_count > 0)
   {
      sell_avg /= sell_count;
      g_reference_price = sell_avg - (g_grid_gap_points * g_point);
      if(g_is_reinitialization)
         Print("Reinitialization: Reference price calculated from SELL positions: ", g_reference_price);
   }
   else
   {
      //--- No existing positions, use current price
      g_reference_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(g_is_reinitialization)
         Print("Reinitialization: No existing EA positions found, using current price: ", g_reference_price);
      else
         Print("Fresh start: Reference price set to current market: ", g_reference_price);
   }
   
   g_reference_price = NormalizeDouble(g_reference_price, g_digits);
   
   //--- If reinitialization with existing positions, preserve pending orders
   if(g_is_reinitialization && has_existing_positions)
   {
      int pending_count = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong ticket = OrderGetTicket(i);
         if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == g_magic_number)
         {
            pending_count++;
         }
      }
      Print("Reinitialization: Preserved ", buy_count + sell_count, " positions and ", pending_count, " pending orders");
   }
}

//+------------------------------------------------------------------+
//| Initialize daily tracking                                        |
//+------------------------------------------------------------------+
void InitializeDailyTracking()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   g_last_daily_reset = StructToTime(dt);
   g_daily_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_daily_profit_loss = 0.0;
}

//+------------------------------------------------------------------+
//| Update daily tracking                                            |
//+------------------------------------------------------------------+
void UpdateDailyTracking()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime today_start = StructToTime(dt);
   
   if(today_start > g_last_daily_reset)
   {
      g_last_daily_reset = today_start;
      g_daily_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   }
   
   g_daily_profit_loss = AccountInfoDouble(ACCOUNT_BALANCE) - g_daily_start_balance;
}

//+------------------------------------------------------------------+
//| Recalculate reference price to current market                    |
//+------------------------------------------------------------------+
void RecalculateReferencePrice()
{
   g_reference_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   g_reference_price = NormalizeDouble(g_reference_price, g_digits);
   Print("Reference price reset to: ", g_reference_price);
}

//+------------------------------------------------------------------+
//| Check if drawdown limit is reached                              |
//+------------------------------------------------------------------+
bool IsDrawdownLimitReached()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdown_amount = balance - equity;
   double drawdown_percent = (drawdown_amount / balance) * 100.0;
   
   return (drawdown_percent >= InpMaxDrawdownPercent);
}

//+------------------------------------------------------------------+
//| Check global profit target                                       |
//+------------------------------------------------------------------+
bool CheckGlobalProfit()
{
   double total_profit = 0.0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == g_magic_number)
      {
         total_profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double target_profit = balance * (InpGlobalProfitPercent / 100.0);
   
   return (total_profit >= target_profit);
}

//+------------------------------------------------------------------+
//| Manage grid positions                                            |
//+------------------------------------------------------------------+
void ManageGrid()
{
   double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   //--- Apply ADX filter and directional bias
   bool allow_buy = true;
   bool allow_sell = true;
   
   if(InpUseADXFilter && InpUseDirectionalBias && g_is_trending)
   {
      //--- In uptrend: only BUY (ride the trend), no SELL (counter-trend)
      if(g_is_uptrend)
      {
         allow_buy = true;
         allow_sell = false;
         // Comment("ADX: UPTREND - Buy Only Mode");
      }
      //--- In downtrend: only SELL (ride the trend), no BUY (counter-trend)
      else if(g_is_downtrend)
      {
         allow_buy = false;
         allow_sell = true;
         // Comment("ADX: DOWNTREND - Sell Only Mode");
      }
   }
   else if(InpUseADXFilter && !InpUseDirectionalBias && g_is_trending)
   {
      //--- If trending but no directional bias, pause trading
      // Comment("ADX: TRENDING - Trading Paused (No Directional Bias)");
      return;
   }
   
   if(InpUsePendingOrders)
   {
      ManagePendingOrders(allow_buy, allow_sell);
   }
   else
   {
      ManageMarketOrders(current_price, allow_buy, allow_sell);
   }
}

//+------------------------------------------------------------------+
//| Manage pending orders                                            |
//+------------------------------------------------------------------+
void ManagePendingOrders(bool allow_buy = true, bool allow_sell = true)
{
   //--- Count existing pending orders
   int buy_limit_count = 0;
   int sell_limit_count = 0;
   
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && 
         OrderGetInteger(ORDER_MAGIC) == g_magic_number)
      {
         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type == ORDER_TYPE_BUY_LIMIT) buy_limit_count++;
         else if(type == ORDER_TYPE_SELL_LIMIT) sell_limit_count++;
      }
   }
   
   //--- Place missing buy orders (if allowed)
   if(allow_buy && (InpDirection == DIRECTION_BOTH || InpDirection == DIRECTION_BUY_ONLY))
   {
      if(buy_limit_count == 0)
         PlaceBuyPendingOrders();
   }
   else if(!allow_buy)
   {
      //--- Delete existing buy orders if not allowed
      DeletePendingOrdersByType(ORDER_TYPE_BUY_LIMIT);
   }
   
   //--- Place missing sell orders (if allowed)
   if(allow_sell && (InpDirection == DIRECTION_BOTH || InpDirection == DIRECTION_SELL_ONLY))
   {
      if(sell_limit_count == 0)
         PlaceSellPendingOrders();
   }
   else if(!allow_sell)
   {
      //--- Delete existing sell orders if not allowed
      DeletePendingOrdersByType(ORDER_TYPE_SELL_LIMIT);
   }
}

//+------------------------------------------------------------------+
//| Place buy pending orders (below reference)                       |
//+------------------------------------------------------------------+
void PlaceBuyPendingOrders()
{
   double current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int grid_level = 1;
   double lot_size = InpInitialLot;
   
   //--- Count existing buy positions
   int buy_positions = CountPositionsByType(POSITION_TYPE_BUY);
   
   //--- Place BUY LIMIT orders below reference price (mean reversion)
   while(grid_level <= 50) // Max 50 levels
   {
      //--- Check max positions limit
      if(InpMaxPositions > 0 && buy_positions >= InpMaxPositions)
         break;
      
      double order_price = g_reference_price - (grid_level * g_grid_gap_points * g_point);
      order_price = NormalizeDouble(order_price, g_digits);
      
      //--- Only place if below current price
      if(order_price < current_price - (g_stop_level * g_point))
      {
         //--- Check if order already exists at this level
         if(!PendingOrderExistsAtPrice(ORDER_TYPE_BUY_LIMIT, order_price))
         {
            lot_size = CalculateLotSize(grid_level);
            
            if(trade.BuyLimit(lot_size, order_price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, InpCommentPrefix))
            {
               Print("Buy Limit placed at level ", grid_level, " price: ", order_price, " lot: ", lot_size);
            }
            else
            {
               Print("Failed to place Buy Limit: ", trade.ResultRetcodeDescription());
            }
         }
      }
      else
      {
         break; // Price too close to current market
      }
      
      grid_level++;
   }
}

//+------------------------------------------------------------------+
//| Place sell pending orders (above reference)                      |
//+------------------------------------------------------------------+
void PlaceSellPendingOrders()
{
   double current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int grid_level = 1;
   double lot_size = InpInitialLot;
   
   //--- Count existing sell positions
   int sell_positions = CountPositionsByType(POSITION_TYPE_SELL);
   
   //--- Place SELL LIMIT orders above reference price (mean reversion)
   while(grid_level <= 50) // Max 50 levels
   {
      //--- Check max positions limit
      if(InpMaxPositions > 0 && sell_positions >= InpMaxPositions)
         break;
      
      double order_price = g_reference_price + (grid_level * g_grid_gap_points * g_point);
      order_price = NormalizeDouble(order_price, g_digits);
      
      //--- Only place if above current price
      if(order_price > current_price + (g_stop_level * g_point))
      {
         //--- Check if order already exists at this level
         if(!PendingOrderExistsAtPrice(ORDER_TYPE_SELL_LIMIT, order_price))
         {
            lot_size = CalculateLotSize(grid_level);
            
            if(trade.SellLimit(lot_size, order_price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, InpCommentPrefix))
            {
               Print("Sell Limit placed at level ", grid_level, " price: ", order_price, " lot: ", lot_size);
            }
            else
            {
               Print("Failed to place Sell Limit: ", trade.ResultRetcodeDescription());
            }
         }
      }
      else
      {
         break; // Price too close to current market
      }
      
      grid_level++;
   }
}

//+------------------------------------------------------------------+
//| Check if pending order exists at price                          |
//+------------------------------------------------------------------+
bool PendingOrderExistsAtPrice(ENUM_ORDER_TYPE order_type, double price)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && 
         OrderGetInteger(ORDER_MAGIC) == g_magic_number &&
         OrderGetInteger(ORDER_TYPE) == order_type)
      {
         double order_price = OrderGetDouble(ORDER_PRICE_OPEN);
         if(MathAbs(order_price - price) < g_point)
            return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Manage market orders                                             |
//+------------------------------------------------------------------+
void ManageMarketOrders(double current_price, bool allow_buy = true, bool allow_sell = true)
{
   //--- Count existing positions
   int buy_positions = CountPositionsByType(POSITION_TYPE_BUY);
   int sell_positions = CountPositionsByType(POSITION_TYPE_SELL);
   
   //--- Calculate grid levels
   int buy_grid_level = CalculateGridLevel(current_price, true);
   int sell_grid_level = CalculateGridLevel(current_price, false);
   
   //--- Check if we should open buy position
   if(allow_buy && (InpDirection == DIRECTION_BOTH || InpDirection == DIRECTION_BUY_ONLY) && 
      buy_grid_level > 0)
   {
      //--- Check max positions limit
      if(InpMaxPositions == 0 || buy_positions < InpMaxPositions)
      {
         double buy_level_price = g_reference_price - (buy_grid_level * g_grid_gap_points * g_point);
         if(current_price <= buy_level_price && !PositionExistsAtLevel(buy_grid_level, true))
         {
            OpenMarketPosition(ORDER_TYPE_BUY, buy_grid_level);
         }
      }
   }
   
   //--- Check if we should open sell position
   if(allow_sell && (InpDirection == DIRECTION_BOTH || InpDirection == DIRECTION_SELL_ONLY) && 
      sell_grid_level > 0)
   {
      //--- Check max positions limit
      if(InpMaxPositions == 0 || sell_positions < InpMaxPositions)
      {
         double sell_level_price = g_reference_price + (sell_grid_level * g_grid_gap_points * g_point);
         if(current_price >= sell_level_price && !PositionExistsAtLevel(sell_grid_level, false))
         {
            OpenMarketPosition(ORDER_TYPE_SELL, sell_grid_level);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate grid level based on current price                      |
//+------------------------------------------------------------------+
int CalculateGridLevel(double price, bool is_buy)
{
   double distance = is_buy ? (g_reference_price - price) : (price - g_reference_price);
   
   if(distance <= 0)
      return 0;
   
   int level = (int)MathFloor(distance / (g_grid_gap_points * g_point));
   return level;
}

//+------------------------------------------------------------------+
//| Check if position exists at grid level                          |
//+------------------------------------------------------------------+
bool PositionExistsAtLevel(int level, bool is_buy)
{
   double target_price = is_buy ? 
      g_reference_price - (level * g_grid_gap_points * g_point) :
      g_reference_price + (level * g_grid_gap_points * g_point);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == g_magic_number)
      {
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
         
         bool is_buy_position = (type == POSITION_TYPE_BUY);
         if(is_buy_position == is_buy && MathAbs(open_price - target_price) < (g_grid_gap_points * g_point * 0.5))
         {
            return true;
         }
      }
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| Open market position                                             |
//+------------------------------------------------------------------+
void OpenMarketPosition(ENUM_ORDER_TYPE order_type, int grid_level)
{
   double lot_size = CalculateLotSize(grid_level);
   bool result = false;
   
   if(order_type == ORDER_TYPE_BUY)
   {
      result = trade.Buy(lot_size, _Symbol, 0, 0, 0, InpCommentPrefix);
   }
   else if(order_type == ORDER_TYPE_SELL)
   {
      result = trade.Sell(lot_size, _Symbol, 0, 0, 0, InpCommentPrefix);
   }
   
   if(result)
   {
      Print("Market ", (order_type == ORDER_TYPE_BUY ? "BUY" : "SELL"), 
            " opened at level ", grid_level, " lot: ", lot_size);
   }
   else
   {
      Print("Failed to open position: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on grid level                          |
//+------------------------------------------------------------------+
double CalculateLotSize(int grid_level)
{
   double lot = InpInitialLot * MathPow(InpLotMultiplier, grid_level - 1);
   
   //--- Normalize lot size
   lot = MathFloor(lot / g_lot_step) * g_lot_step;
   lot = MathMax(lot, g_min_lot);
   lot = MathMin(lot, g_max_lot);
   
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Close all positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == g_magic_number)
      {
         if(!trade.PositionClose(ticket))
         {
            Print("Failed to close position #", ticket, ": ", trade.ResultRetcodeDescription());
         }
      }
   }
   
   //--- Delete all pending orders
   DeleteAllPendingOrders();
}

//+------------------------------------------------------------------+
//| Close only profitable positions                                  |
//+------------------------------------------------------------------+
void CloseProfitablePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == g_magic_number)
      {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0)
         {
            if(!trade.PositionClose(ticket))
            {
               Print("Failed to close profitable position #", ticket, ": ", trade.ResultRetcodeDescription());
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Delete pending orders by type                                    |
//+------------------------------------------------------------------+
void DeletePendingOrdersByType(ENUM_ORDER_TYPE order_type)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && 
         OrderGetInteger(ORDER_MAGIC) == g_magic_number &&
         OrderGetInteger(ORDER_TYPE) == order_type)
      {
         if(!trade.OrderDelete(ticket))
         {
            Print("Failed to delete order #", ticket, ": ", trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Delete all pending orders                                        |
//+------------------------------------------------------------------+
void DeleteAllPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && 
         OrderGetInteger(ORDER_MAGIC) == g_magic_number)
      {
         if(!trade.OrderDelete(ticket))
         {
            Print("Failed to delete order #", ticket, ": ", trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Rebuild pending orders after close all                          |
//+------------------------------------------------------------------+
void RebuildPendingOrders()
{
   DeleteAllPendingOrders();
   
   if(InpDirection == DIRECTION_BOTH || InpDirection == DIRECTION_BUY_ONLY)
      PlaceBuyPendingOrders();
   
   if(InpDirection == DIRECTION_BOTH || InpDirection == DIRECTION_SELL_ONLY)
      PlaceSellPendingOrders();
}

//+------------------------------------------------------------------+
//| Create UI Panel                                                  |
//+------------------------------------------------------------------+
void CreatePanel()
{
   //--- Create main panel background
   if(!ObjectCreate(0, g_panel_name, OBJ_RECTANGLE_LABEL, 0, 0, 0))
   {
      Print("Failed to create panel background");
      return;
   }
   
   ObjectSetInteger(0, g_panel_name, OBJPROP_XDISTANCE, g_panel_x);
   ObjectSetInteger(0, g_panel_name, OBJPROP_YDISTANCE, g_panel_y);
   ObjectSetInteger(0, g_panel_name, OBJPROP_XSIZE, g_panel_width);
   ObjectSetInteger(0, g_panel_name, OBJPROP_YSIZE, g_panel_height);
   ObjectSetInteger(0, g_panel_name, OBJPROP_BGCOLOR, clrDarkSlateGray);
   ObjectSetInteger(0, g_panel_name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, g_panel_name, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, g_panel_name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, g_panel_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, g_panel_name, OBJPROP_BACK, false);
   ObjectSetInteger(0, g_panel_name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, g_panel_name, OBJPROP_SELECTED, false);
   ObjectSetInteger(0, g_panel_name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, g_panel_name, OBJPROP_ZORDER, 0);
   
   //--- Create title
   string title_name = g_panel_name + "_Title";
   if(ObjectCreate(0, title_name, OBJ_LABEL, 0, 0, 0))
   {
      ObjectSetInteger(0, title_name, OBJPROP_XDISTANCE, g_panel_x + 10);
      ObjectSetInteger(0, title_name, OBJPROP_YDISTANCE, g_panel_y + 10);
      ObjectSetInteger(0, title_name, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, title_name, OBJPROP_FONTSIZE, 11);
      ObjectSetString(0, title_name, OBJPROP_FONT, "Arial Bold");
      ObjectSetString(0, title_name, OBJPROP_TEXT, "TORAMA Mean Reversion Grid");
      ObjectSetInteger(0, title_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, title_name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, title_name, OBJPROP_BACK, false);
      ObjectSetInteger(0, title_name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, title_name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, title_name, OBJPROP_ZORDER, 1);
   }
   
   //--- Create info labels
   CreateInfoLabels();
   
   //--- Create buttons
   CreateButtons();
   
   //--- Create branding
   CreateBranding();
}

//+------------------------------------------------------------------+
//| Create info labels                                               |
//+------------------------------------------------------------------+
void CreateInfoLabels()
{
   string labels[] = {"Balance", "Equity", "Margin", "P/L", "Daily P/L", "Cycles", "Magic", "Market", "Cooldown"};
   int y_offset = 40;
   
   for(int i = 0; i < ArraySize(labels); i++)
   {
      string label_name = g_panel_name + "_Label_" + labels[i];
      string value_name = g_panel_name + "_Value_" + labels[i];
      
      //--- Create label
      if(ObjectCreate(0, label_name, OBJ_LABEL, 0, 0, 0))
      {
         ObjectSetInteger(0, label_name, OBJPROP_XDISTANCE, g_panel_x + 10);
         ObjectSetInteger(0, label_name, OBJPROP_YDISTANCE, g_panel_y + y_offset);
         ObjectSetInteger(0, label_name, OBJPROP_COLOR, clrLightGray);
         ObjectSetInteger(0, label_name, OBJPROP_FONTSIZE, 9);
         ObjectSetString(0, label_name, OBJPROP_FONT, "Arial");
         ObjectSetString(0, label_name, OBJPROP_TEXT, labels[i] + ":");
         ObjectSetInteger(0, label_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, label_name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
         ObjectSetInteger(0, label_name, OBJPROP_BACK, false);
         ObjectSetInteger(0, label_name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, label_name, OBJPROP_HIDDEN, true);
         ObjectSetInteger(0, label_name, OBJPROP_ZORDER, 1);
      }
      
      //--- Create value
      if(ObjectCreate(0, value_name, OBJ_LABEL, 0, 0, 0))
      {
         ObjectSetInteger(0, value_name, OBJPROP_XDISTANCE, g_panel_x + 120);
         ObjectSetInteger(0, value_name, OBJPROP_YDISTANCE, g_panel_y + y_offset);
         ObjectSetInteger(0, value_name, OBJPROP_COLOR, clrWhite);
         ObjectSetInteger(0, value_name, OBJPROP_FONTSIZE, 9);
         ObjectSetString(0, value_name, OBJPROP_FONT, "Arial Bold");
         ObjectSetString(0, value_name, OBJPROP_TEXT, "0.00");
         ObjectSetInteger(0, value_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, value_name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
         ObjectSetInteger(0, value_name, OBJPROP_BACK, false);
         ObjectSetInteger(0, value_name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, value_name, OBJPROP_HIDDEN, true);
         ObjectSetInteger(0, value_name, OBJPROP_ZORDER, 1);
      }
      
      y_offset += 22;
   }
}

//+------------------------------------------------------------------+
//| Create buttons                                                    |
//+------------------------------------------------------------------+
void CreateButtons()
{
   ArrayResize(g_buttons, 4);
   
   //--- Close All button
   g_buttons[0].name = g_panel_name + "_Btn_CloseAll";
   g_buttons[0].x = g_panel_x + 10;
   g_buttons[0].y = g_panel_y + 210;
   g_buttons[0].width = 125;
   g_buttons[0].height = 30;
   g_buttons[0].bg_color = clrCrimson;
   g_buttons[0].text_color = clrWhite;
   g_buttons[0].text = "Close All";
   
   //--- Take Profit button
   g_buttons[1].name = g_panel_name + "_Btn_TakeProfit";
   g_buttons[1].x = g_panel_x + 145;
   g_buttons[1].y = g_panel_y + 210;
   g_buttons[1].width = 125;
   g_buttons[1].height = 30;
   g_buttons[1].bg_color = clrGreen;
   g_buttons[1].text_color = clrWhite;
   g_buttons[1].text = "Take TP";
   
   //--- Pause EA button
   g_buttons[2].name = g_panel_name + "_Btn_Pause";
   g_buttons[2].x = g_panel_x + 10;
   g_buttons[2].y = g_panel_y + 250;
   g_buttons[2].width = 125;
   g_buttons[2].height = 30;
   g_buttons[2].bg_color = clrOrange;
   g_buttons[2].text_color = clrWhite;
   g_buttons[2].text = "Pause EA";
   
   //--- Reset Reference button
   g_buttons[3].name = g_panel_name + "_Btn_ResetRef";
   g_buttons[3].x = g_panel_x + 145;
   g_buttons[3].y = g_panel_y + 250;
   g_buttons[3].width = 125;
   g_buttons[3].height = 30;
   g_buttons[3].bg_color = clrDodgerBlue;
   g_buttons[3].text_color = clrWhite;
   g_buttons[3].text = "Reset Ref";
   
   //--- Create all buttons
   for(int i = 0; i < ArraySize(g_buttons); i++)
   {
      if(ObjectCreate(0, g_buttons[i].name, OBJ_BUTTON, 0, 0, 0))
      {
         ObjectSetInteger(0, g_buttons[i].name, OBJPROP_XDISTANCE, g_buttons[i].x);
         ObjectSetInteger(0, g_buttons[i].name, OBJPROP_YDISTANCE, g_buttons[i].y);
         ObjectSetInteger(0, g_buttons[i].name, OBJPROP_XSIZE, g_buttons[i].width);
         ObjectSetInteger(0, g_buttons[i].name, OBJPROP_YSIZE, g_buttons[i].height);
         ObjectSetInteger(0, g_buttons[i].name, OBJPROP_BGCOLOR, g_buttons[i].bg_color);
         ObjectSetInteger(0, g_buttons[i].name, OBJPROP_COLOR, g_buttons[i].text_color);
         ObjectSetInteger(0, g_buttons[i].name, OBJPROP_FONTSIZE, 10);
         ObjectSetString(0, g_buttons[i].name, OBJPROP_FONT, "Arial Bold");
         ObjectSetString(0, g_buttons[i].name, OBJPROP_TEXT, g_buttons[i].text);
         ObjectSetInteger(0, g_buttons[i].name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, g_buttons[i].name, OBJPROP_BACK, false);
         ObjectSetInteger(0, g_buttons[i].name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, g_buttons[i].name, OBJPROP_HIDDEN, true);
         ObjectSetInteger(0, g_buttons[i].name, OBJPROP_ZORDER, 1);
      }
   }
}

//+------------------------------------------------------------------+
//| Create branding                                                   |
//+------------------------------------------------------------------+
void CreateBranding()
{
   string brand_name = g_panel_name + "_Brand";
   if(ObjectCreate(0, brand_name, OBJ_LABEL, 0, 0, 0))
   {
      ObjectSetInteger(0, brand_name, OBJPROP_XDISTANCE, g_panel_x + g_panel_width - 10);
      ObjectSetInteger(0, brand_name, OBJPROP_YDISTANCE, g_panel_y + g_panel_height - 25);
      ObjectSetInteger(0, brand_name, OBJPROP_COLOR, clrGold);
      ObjectSetInteger(0, brand_name, OBJPROP_FONTSIZE, 9);
      ObjectSetString(0, brand_name, OBJPROP_FONT, "Arial Bold");
      ObjectSetString(0, brand_name, OBJPROP_TEXT, "TORAMA CAPITAL");
      ObjectSetInteger(0, brand_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, brand_name, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, brand_name, OBJPROP_BACK, false);
      ObjectSetInteger(0, brand_name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, brand_name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, brand_name, OBJPROP_ZORDER, 1);
   }
   
   string contact_name = g_panel_name + "_Contact";
   if(ObjectCreate(0, contact_name, OBJ_LABEL, 0, 0, 0))
   {
      ObjectSetInteger(0, contact_name, OBJPROP_XDISTANCE, g_panel_x + g_panel_width - 10);
      ObjectSetInteger(0, contact_name, OBJPROP_YDISTANCE, g_panel_y + g_panel_height - 10);
      ObjectSetInteger(0, contact_name, OBJPROP_COLOR, clrLightGray);
      ObjectSetInteger(0, contact_name, OBJPROP_FONTSIZE, 7);
      ObjectSetString(0, contact_name, OBJPROP_FONT, "Arial");
      ObjectSetString(0, contact_name, OBJPROP_TEXT, "torama.money");
      ObjectSetInteger(0, contact_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, contact_name, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
      ObjectSetInteger(0, contact_name, OBJPROP_BACK, false);
      ObjectSetInteger(0, contact_name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, contact_name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, contact_name, OBJPROP_ZORDER, 1);
   }
}

//+------------------------------------------------------------------+
//| Update panel information                                          |
//+------------------------------------------------------------------+
void UpdatePanel()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double margin = AccountInfoDouble(ACCOUNT_MARGIN);
   
   //--- Calculate total P/L
   double total_pl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == g_magic_number)
      {
         total_pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }
   
   //--- Update values
   ObjectSetString(0, g_panel_name + "_Value_Balance", OBJPROP_TEXT, DoubleToString(balance, 2));
   ObjectSetString(0, g_panel_name + "_Value_Equity", OBJPROP_TEXT, DoubleToString(equity, 2));
   ObjectSetString(0, g_panel_name + "_Value_Margin", OBJPROP_TEXT, DoubleToString(margin, 2));
   ObjectSetString(0, g_panel_name + "_Value_P/L", OBJPROP_TEXT, DoubleToString(total_pl, 2));
   ObjectSetString(0, g_panel_name + "_Value_Daily P/L", OBJPROP_TEXT, DoubleToString(g_daily_profit_loss, 2));
   ObjectSetString(0, g_panel_name + "_Value_Cycles", OBJPROP_TEXT, IntegerToString(g_cycle_count));
   ObjectSetString(0, g_panel_name + "_Value_Magic", OBJPROP_TEXT, IntegerToString(g_magic_number));
   ObjectSetString(0, g_panel_name + "_Value_Market", OBJPROP_TEXT, g_market_condition);
   
   //--- Update Cooldown status
   string cooldown_text = "None";
   color cooldown_color = clrLightGray;
   if(g_in_cooldown)
   {
      int remaining_seconds = (int)(g_cooldown_end_time - TimeCurrent());
      int remaining_minutes = remaining_seconds / 60;
      cooldown_text = StringFormat("%d min", remaining_minutes);
      cooldown_color = clrOrange;
   }
   ObjectSetString(0, g_panel_name + "_Value_Cooldown", OBJPROP_TEXT, cooldown_text);
   ObjectSetInteger(0, g_panel_name + "_Value_Cooldown", OBJPROP_COLOR, cooldown_color);
   
   //--- Update P/L color
   color pl_color = (total_pl >= 0) ? clrLimeGreen : clrRed;
   ObjectSetInteger(0, g_panel_name + "_Value_P/L", OBJPROP_COLOR, pl_color);
   
   //--- Update Daily P/L color
   color daily_color = (g_daily_profit_loss >= 0) ? clrLimeGreen : clrRed;
   ObjectSetInteger(0, g_panel_name + "_Value_Daily P/L", OBJPROP_COLOR, daily_color);
   
   //--- Update Market condition color
   color market_color = clrLightGray;
   if(g_market_condition == "UPTREND")
      market_color = clrLimeGreen;
   else if(g_market_condition == "DOWNTREND")
      market_color = clrRed;
   else if(g_market_condition == "TRENDING")
      market_color = clrOrange;
   ObjectSetInteger(0, g_panel_name + "_Value_Market", OBJPROP_COLOR, market_color);
   
   //--- Update pause button text
   string pause_text = g_ea_paused ? "Resume EA" : "Pause EA";
   ObjectSetString(0, g_panel_name + "_Btn_Pause", OBJPROP_TEXT, pause_text);
   
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| Delete panel                                                      |
//+------------------------------------------------------------------+
void DeletePanel()
{
   //--- Delete all objects with panel prefix
   int total = ObjectsTotal(0);
   for(int i = total - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i);
      if(StringFind(name, g_panel_name) == 0)
      {
         ObjectDelete(0, name);
      }
   }
}

//+------------------------------------------------------------------+
//| Count positions by type                                          |
//+------------------------------------------------------------------+
int CountPositionsByType(ENUM_POSITION_TYPE pos_type)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && 
         PositionGetInteger(POSITION_MAGIC) == g_magic_number)
      {
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if(type == pos_type)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Handle button clicks                                             |
//+------------------------------------------------------------------+
void HandleButtonClick(string clicked_object)
{
   if(clicked_object == g_panel_name + "_Btn_CloseAll")
   {
      Print("Close All button clicked");
      CloseAllPositions();
      g_cycle_count++;
      RecalculateReferencePrice();
      if(InpUsePendingOrders)
         RebuildPendingOrders();
      UpdatePanel();
   }
   else if(clicked_object == g_panel_name + "_Btn_TakeProfit")
   {
      Print("Take Profit button clicked");
      CloseProfitablePositions();
      UpdatePanel();
   }
   else if(clicked_object == g_panel_name + "_Btn_Pause")
   {
      g_ea_paused = !g_ea_paused;
      
      // If resuming, clear cooldown
      if(!g_ea_paused)
      {
         g_in_cooldown = false;
         Print("EA manually resumed. Cooldown cleared.");
      }
      
      Print("EA ", (g_ea_paused ? "Paused" : "Resumed"));
      UpdatePanel();
   }
   else if(clicked_object == g_panel_name + "_Btn_ResetRef")
   {
      Print("Reset Reference button clicked");
      RecalculateReferencePrice();
      if(InpUsePendingOrders)
         RebuildPendingOrders();
      UpdatePanel();
   }
   
   //--- Unpress button
   ObjectSetInteger(0, clicked_object, OBJPROP_STATE, false);
}

//+------------------------------------------------------------------+
