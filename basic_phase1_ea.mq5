//+------------------------------------------------------------------+
//|                                           basic_phase1_ea.mq5    |
//|  Description: Minimal Expert Advisor using MA, RSI, MFI and      |
//|               Volume confirmation with risk controls.            |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "1.00"

#include <Trade/Trade.mqh>

input int       InpFastMAPeriod        = 21;        // Fast MA period
input int       InpSlowMAPeriod        = 55;        // Slow MA period
input ENUM_MA_METHOD InpMAMethod       = MODE_EMA;  // MA method
input ENUM_APPLIED_PRICE InpMAPrice    = PRICE_CLOSE; // Applied price for MA
input int       InpRSIPeriod           = 14;        // RSI period
input double    InpRSIBullishLevel     = 55.0;      // Minimum RSI for buy
input double    InpRSIBearishLevel     = 45.0;      // Maximum RSI for sell
input int       InpMFIPeriod           = 14;        // MFI period
input double    InpMFIBullishLevel     = 55.0;      // Minimum MFI for buy
input double    InpMFIBearishLevel     = 45.0;      // Maximum MFI for sell
input int       InpVolumeLookback      = 20;        // Bars for average volume
input double    InpVolumeMultiplier    = 1.10;      // Current volume must exceed average * multiplier
input double    InpMaxSpreadPoints     = 30;        // Maximum allowed spread in points
input double    InpMaxDrawdownPercent  = 20.0;      // Maximum total drawdown (%)
input double    InpDailyLossPercent    = 5.0;       // Maximum daily loss (%)
input ulong     InpMagic               = 20240901;  // Magic number

sinput string   sep1                   = "--- GRID SETTINGS ---";
input bool      EnableGrid             = true;      // Enable grid trading
input double    InpBaseLot             = 0.01;      // Base lot for each grid order
input double    InpLotMultiplier       = 1.35;      // Multiplier for each subsequent grid order
input double    InpGridStepPoints      = 200;       // Distance between grid orders (points)
input double    InpGridDistanceMultiplier = 1.0;    // Distance multiplier for each subsequent grid level
input int       InpMaxGridLevels       = 50;        // Maximum grid levels per cluster
input double    InpMaxTotalLot         = 1.0;       // Maximum total lot size across all orders
input bool      AllowOverlapRecovery   = true;      // Allow recovery overlap partial closes
input int       OverlapAfterOrders     = 3;         // Minimum orders before triggering overlap recovery

sinput string   sep2                   = "--- TAKEPROFIT SETTINGS ---";
input double    InpVirtualTP           = 60;        // Base virtual TP in points
input double    InpTPReductionPerOrder = 5;         // TP reduction per additional grid order

CTrade          trade;

int             fast_ma_handle = INVALID_HANDLE;
int             slow_ma_handle = INVALID_HANDLE;
int             rsi_handle     = INVALID_HANDLE;
int             mfi_handle     = INVALID_HANDLE;

MqlRates        rates[];
double          fast_ma_buffer[];
double          slow_ma_buffer[];
double          rsi_buffer[];
double          mfi_buffer[];

double          initial_equity = 0.0;
double          daily_start_equity = 0.0;
int             current_trading_date = -1;

int             g_gridLevels = 0;
double          g_lastGridPrice = 0.0;
ENUM_ORDER_TYPE g_currentClusterType = ORDER_TYPE_BUY;
ulong           g_currentClusterId = 0;
ulong           g_nextClusterId = 1;
bool            g_overlapPartialTriggered = false;
string          g_logFileName = "";
bool            g_logHeaderWritten = false;

struct GridClusterCounters
  {
   int buy_levels;
   int sell_levels;
  };

GridClusterCounters g_grid = {0,0};
ENUM_ORDER_TYPE     g_activeDirection = (ENUM_ORDER_TYPE)-1;
datetime            g_lastSignalTime = 0;
ENUM_ORDER_TYPE     g_lastSignalDirection = (ENUM_ORDER_TYPE)-1;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   fast_ma_handle = iMA(_Symbol,_Period,InpFastMAPeriod,0,InpMAMethod,InpMAPrice);
   slow_ma_handle = iMA(_Symbol,_Period,InpSlowMAPeriod,0,InpMAMethod,InpMAPrice);
   rsi_handle     = iRSI(_Symbol,_Period,InpRSIPeriod,InpMAPrice);
   mfi_handle     = iMFI(_Symbol,_Period,InpMFIPeriod,VOLUME_TICK);

   if(fast_ma_handle==INVALID_HANDLE || slow_ma_handle==INVALID_HANDLE ||
      rsi_handle==INVALID_HANDLE || mfi_handle==INVALID_HANDLE)
     {
      Print("Failed to create indicator handles. Error: ",GetLastError());
      return(INIT_FAILED);
     }

   ArrayResize(fast_ma_buffer,3);
   ArraySetAsSeries(fast_ma_buffer,true);
   ArrayResize(slow_ma_buffer,3);
   ArraySetAsSeries(slow_ma_buffer,true);
   ArrayResize(rsi_buffer,2);
   ArraySetAsSeries(rsi_buffer,true);
   ArrayResize(mfi_buffer,2);
   ArraySetAsSeries(mfi_buffer,true);

   ArrayResize(rates,InpVolumeLookback);
   ArraySetAsSeries(rates,true);

   initial_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   daily_start_equity = initial_equity;
   current_trading_date = GetTradingDate();

   trade.SetExpertMagicNumber(InpMagic);

   g_gridLevels = 0;
   g_lastGridPrice = 0.0;
   g_currentClusterType = ORDER_TYPE_BUY;
   g_currentClusterId = 0;
   g_nextClusterId = 1;
   g_overlapPartialTriggered = false;
   g_logFileName = StringFormat("SelfTuneEA_%s.csv",_Symbol);
   g_logHeaderWritten = false;
   g_grid.buy_levels = 0;
   g_grid.sell_levels = 0;
   g_activeDirection = (ENUM_ORDER_TYPE)-1;
   EnsureLogHeader();

   EntryCooldown("Init",false,true);

   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(fast_ma_handle!=INVALID_HANDLE)
      IndicatorRelease(fast_ma_handle);
   if(slow_ma_handle!=INVALID_HANDLE)
      IndicatorRelease(slow_ma_handle);
   if(rsi_handle!=INVALID_HANDLE)
      IndicatorRelease(rsi_handle);
   if(mfi_handle!=INVALID_HANDLE)
      IndicatorRelease(mfi_handle);
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!UpdateTradingDate())
      return;

   if(!CheckRiskLimits())
      return;

   if(!RefreshIndicators())
      return;

   double spread_points = GetCurrentSpreadPoints();
   if(spread_points>InpMaxSpreadPoints)
      return;

   bool buy_signal = CheckBuySignal();
   bool sell_signal = CheckSellSignal();

   if(buy_signal && sell_signal)
      return;

   SyncClusterState();

   ManageBasketControls();

   SyncClusterState();

   int total_positions = PositionTotalByMagicSymbol(InpMagic,_Symbol);

   if(!EnableGrid)
     {
      HandleBasicTrading(total_positions,buy_signal,sell_signal);
      return;
     }

   if(total_positions==0)
     {
      if(buy_signal)
         StartNewCluster(ORDER_TYPE_BUY);
      else if(sell_signal)
         StartNewCluster(ORDER_TYPE_SELL);
      return;
     }

   MaintainGrid();
  }
//+------------------------------------------------------------------+
//| Handle non-grid basic trading                                    |
//+------------------------------------------------------------------+
void HandleBasicTrading(int total_positions,bool buy_signal,bool sell_signal)
  {
   if(total_positions>0)
      return;

   if(!buy_signal && !sell_signal)
      return;

   if(GetTotalVolume(_Symbol)+InpBaseLot>InpMaxTotalLot+1e-6)
      return;

   if(buy_signal && !sell_signal)
      OpenBasicPosition(ORDER_TYPE_BUY);
   else if(sell_signal && !buy_signal)
      OpenBasicPosition(ORDER_TYPE_SELL);
  }
//+------------------------------------------------------------------+
//| Synchronize cluster state with current positions                  |
//+------------------------------------------------------------------+
void SyncClusterState()
  {
   int total = PositionTotalByMagicSymbol(InpMagic,_Symbol);
   if(total==0)
     {
      ResetGridState();
      return;
     }

   ulong max_cluster = 0;
   ENUM_ORDER_TYPE cluster_type = ORDER_TYPE_BUY;
   datetime latest_time = 0;
   double last_price = 0.0;

   for(int i=0;i<PositionsTotal();++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic)
         continue;

      string comment = PositionGetString(POSITION_COMMENT);
      ulong cluster_id = ExtractClusterId(comment);
      if(cluster_id==0)
         continue;

      ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);

      if(cluster_id>max_cluster)
        {
         max_cluster = cluster_id;
         cluster_type = (pos_type==POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         latest_time = open_time;
         last_price = PositionGetDouble(POSITION_PRICE_OPEN);
        }
      else if(cluster_id==max_cluster && open_time>=latest_time)
        {
         latest_time = open_time;
         last_price = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }

   if(max_cluster>0)
     {
      g_currentClusterId = max_cluster;
      g_currentClusterType = cluster_type;
      g_activeDirection = cluster_type;
      g_lastGridPrice = last_price;
      g_gridLevels = CountClusterOrders(max_cluster);
      if(g_nextClusterId<=max_cluster)
         g_nextClusterId = max_cluster+1;
     }
   else
     {
      ResetGridState();
    }
  }
//+------------------------------------------------------------------+
//| Compute next grid spacing (points) for the pending level          |
//+------------------------------------------------------------------+
double GetNextGridStepPoints(const int existing_orders)
  {
   double multiplier = (EnableGrid && InpGridDistanceMultiplier>1.0) ? InpGridDistanceMultiplier : 1.0;
   int level_index = MathMax(existing_orders-1,0);
   double step_points = InpGridStepPoints*MathPow(multiplier,(double)level_index);
   return(step_points);
  }
//+------------------------------------------------------------------+
//| Maintain active grid                                              |
//+------------------------------------------------------------------+
void MaintainGrid()
  {
   if(!EnableGrid)
      return;

   if(g_currentClusterId==0)
      return;

   if(g_activeDirection!=(ENUM_ORDER_TYPE)-1 && g_currentClusterType!=g_activeDirection)
      return;

   int cluster_orders = CountClusterOrders(g_currentClusterId);
   if(cluster_orders<=0)
      return;

   double step_points = GetNextGridStepPoints(cluster_orders);
   double step = step_points*_Point;
   if(step<=0.0)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return;

   double current_price = (g_currentClusterType==ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   if(g_lastGridPrice==0.0)
     {
      UpdateLastEntryFromPositions(g_currentClusterId);
      if(g_lastGridPrice==0.0)
         return;
     }

   double distance = MathAbs(current_price-g_lastGridPrice);
   if(distance<step)
      return;

   if(g_currentClusterType==ORDER_TYPE_BUY && current_price>g_lastGridPrice)
      return;

   if(g_currentClusterType==ORDER_TYPE_SELL && current_price<g_lastGridPrice)
      return;

   int current_level = CountClusterOrders(g_currentClusterId);
   int next_level = current_level+1;
   if(next_level>InpMaxGridLevels)
      return;

   double next_lot = GetNextGridLot(g_currentClusterType,g_currentClusterId,current_level);
   if(next_lot<=0.0)
      return;

   if(GetTotalVolume(_Symbol)+next_lot>InpMaxTotalLot+1e-6)
      return;

   static datetime lastGridOpenByCluster = 0;
   static ulong     lastClusterTracked = 0;
   if(lastClusterTracked!=g_currentClusterId)
     {
      lastClusterTracked = g_currentClusterId;
      lastGridOpenByCluster = 0;
     }

   datetime now = TimeCurrent();
   if(lastGridOpenByCluster!=0 && (now-lastGridOpenByCluster)<60)
      return;

   if(OpenGridOrder(g_currentClusterType,g_currentClusterId,next_level,next_lot,step_points))
     {
      lastGridOpenByCluster = now;
      UpdateLastEntryFromPositions(g_currentClusterId);
      g_gridLevels = CountClusterOrders(g_currentClusterId);
     }
  }
//+------------------------------------------------------------------+
//| Start new grid cluster                                            |
//+------------------------------------------------------------------+
bool StartNewCluster(ENUM_ORDER_TYPE type)
  {
   if(g_currentClusterId!=0)
      return(false);

   if(g_activeDirection!=(ENUM_ORDER_TYPE)-1 && type!=g_activeDirection)
      return(false);

   datetime signal_time = iTime(_Symbol,_Period,0);
   if(signal_time==g_lastSignalTime && type==g_lastSignalDirection)
      return(false);

   ulong new_cluster_id = g_nextClusterId;
   g_lastGridPrice = 0.0;

   g_grid.buy_levels = 0;
   g_grid.sell_levels = 0;

   int current_level = 0;
   int display_level = current_level+1;
   double initial_lot = GetNextGridLot(type,new_cluster_id,current_level);
   if(initial_lot<=0.0)
      return(false);

   if(GetTotalVolume(_Symbol)+initial_lot>InpMaxTotalLot+1e-6)
      return(false);

   double initial_step_points = GetNextGridStepPoints(display_level);

   if(OpenGridOrder(type,new_cluster_id,display_level,initial_lot,initial_step_points))
     {
      g_currentClusterId = new_cluster_id;
      g_nextClusterId = new_cluster_id+1;
      g_currentClusterType = type;
      g_activeDirection = type;
      g_lastSignalTime = signal_time;
      g_lastSignalDirection = type;
      UpdateLastEntryFromPositions(g_currentClusterId);
      g_gridLevels = CountClusterOrders(g_currentClusterId);
      if(type==ORDER_TYPE_BUY)
         g_grid.buy_levels = g_gridLevels;
      else
         g_grid.sell_levels = g_gridLevels;
      return(true);
     }
   return(false);
  }
//+------------------------------------------------------------------+
//| Open grid order                                                   |
//+------------------------------------------------------------------+
bool OpenGridOrder(ENUM_ORDER_TYPE type,ulong cluster_id,int level_index,double volume,double step_points=0.0)
  {
   if(volume<=0.0)
      return(false);

   if(g_activeDirection!=(ENUM_ORDER_TYPE)-1 && type!=g_activeDirection)
      return(false);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return(false);

   double price = (type==ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   double sl = 0.0;
   double tp = 0.0;

   if(!EntryCooldown("Grid",false,false))
      return(false);

   if(step_points<=0.0)
      step_points = GetNextGridStepPoints(level_index);

   string comment = BuildClusterComment(cluster_id);
   bool result = (type==ORDER_TYPE_BUY) ?
      trade.Buy(volume,_Symbol,price,sl,tp,comment) :
      trade.Sell(volume,_Symbol,price,sl,tp,comment);

   if(result)
     {
      EntryCooldown("Grid",true,false);
      g_gridLevels = CountClusterOrders(cluster_id);
      if(type==ORDER_TYPE_BUY)
         g_grid.buy_levels = g_gridLevels;
      else
         g_grid.sell_levels = g_gridLevels;
      g_lastGridPrice = price;
      string direction = (type==ORDER_TYPE_BUY) ? "BUY" : "SELL";
      int volume_digits = GetVolumeDigits(_Symbol);
      string price_str = DoubleToString(price,_Digits);
      string lot_str = DoubleToString(volume,volume_digits);
      string details = StringFormat("Cluster %I64u %s level %d at %s lot %s",cluster_id,direction,level_index,price_str,lot_str);
      LogEvent("GridEntry",details);
      double virtual_tp_points = GetVirtualTP(level_index-1);
      string virtual_tp_str = DoubleToString(virtual_tp_points,1);
      Print("Grid order opened WITHOUT real TP/SL — using virtual basket TP only");
      string dir_log = (type==ORDER_TYPE_BUY) ? "BUY" : "SELL";
      int calc_level = CountClusterOrders(cluster_id);
      string step_str = DoubleToString(step_points,0);
      PrintFormat("[GRID] Level=%d (calc=%d) | Direction=%s | Lot=%.2f | Multiplier=%.2f | Step=%s",level_index,calc_level,dir_log,volume,InpLotMultiplier,step_str);
      Print("New grid level ",g_gridLevels," opened at price ",price_str,", virtual TP ",virtual_tp_str," points");
      double basket_profit = 0.0;
      for(int i=PositionsTotal()-1;i>=0;--i)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket==0)
            continue;
         if(!PositionSelectByTicket(ticket))
            continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
            continue;
         if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic)
            continue;

         basket_profit += PositionGetDouble(POSITION_PROFIT);
        }
      PrintFormat("Grid Level: %d, Price: %s, Basket Profit: %s",g_gridLevels,price_str,DoubleToString(basket_profit,2));
     }

   return(result);
  }
//+------------------------------------------------------------------+
//| Compute dynamic TP reduction                                     |
//+------------------------------------------------------------------+
double GetVirtualTP(int level)
  {
   double tp_points = InpVirtualTP - level*InpTPReductionPerOrder;
   if(tp_points<0.0)
      tp_points = 0.0;
   return(tp_points);
  }
//+------------------------------------------------------------------+
//| Manage basket level controls                                     |
//+------------------------------------------------------------------+
void ManageBasketControls()
  {
   if(g_currentClusterId==0)
      return;

   int    order_count   = CountClusterOrders(g_currentClusterId);
   if(order_count<=0)
     {
      ResetGridState();
      return;
     }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return;

   double current_price = (g_currentClusterType==ORDER_TYPE_BUY) ? tick.bid : tick.ask;
   double price_move_points = 0.0;
   if(g_lastGridPrice>0.0)
     {
      price_move_points = (g_currentClusterType==ORDER_TYPE_BUY) ?
         (current_price-g_lastGridPrice)/_Point :
         (g_lastGridPrice-current_price)/_Point;
     }

   double cluster_profit = GetClusterProfit(g_currentClusterId);
   double virtual_tp_points = GetVirtualTP(order_count-1);

   if(AllowOverlapRecovery && !g_overlapPartialTriggered && order_count>=OverlapAfterOrders &&
      virtual_tp_points>0.0 && price_move_points+1e-8>=virtual_tp_points && cluster_profit>0.0)
     {
      double closed_volume = 0.0;
      int closed_positions = 0;
      if(CloseClusterEdgeOrders(g_currentClusterId,closed_volume,closed_positions))
        {
         g_overlapPartialTriggered = true;
         int volume_digits = GetVolumeDigits(_Symbol);
         string volume_str = DoubleToString(closed_volume,volume_digits);
         string profit_str = DoubleToString(cluster_profit,2);
         string details = StringFormat("Recovery partial close: %d edge orders %s lots at profit %s",closed_positions,volume_str,profit_str);
         LogEvent("RecoveryPartial",details);
         PrintFormat("[BASKET] Partial edge close triggered after %.0f pts move (target %.0f)",price_move_points,virtual_tp_points);
         g_gridLevels = CountClusterOrders(g_currentClusterId);
         UpdateLastEntryFromPositions(g_currentClusterId);
         if(PositionTotalByMagicSymbol(InpMagic,_Symbol)==0)
           {
            ResetGridState();
            return;
           }
         order_count = CountClusterOrders(g_currentClusterId);
         cluster_profit = GetClusterProfit(g_currentClusterId);
         virtual_tp_points = GetVirtualTP(MathMax(order_count-1,0));
        }
     }

   if(order_count>0 && virtual_tp_points>0.0 && price_move_points+1e-8>=virtual_tp_points && cluster_profit>0.0)
     {
      int closed_positions = 0;
      double closed_volume = 0.0;
      double price_snapshot = g_lastGridPrice;
      bool closed_any = CloseAllClusterOrders(g_currentClusterId,closed_positions,closed_volume);
      if(closed_any)
        {
         int volume_digits = GetVolumeDigits(_Symbol);
         string volume_str = DoubleToString(closed_volume,volume_digits);
         string profit_str = DoubleToString(cluster_profit,2);
         string details = StringFormat("Virtual TP basket close: %d positions %s lots at profit %s",closed_positions,volume_str,profit_str);
         LogEvent("BasketCloseVirtual",details);
         Print("[BASKET] Cluster fully closed – virtual TP target reached (profit ",profit_str,")");
         PrintFormat("Grid Level: %d, Price: %s, Basket Profit: %s, Cluster Reset Triggered (Cluster %I64u)",order_count,DoubleToString(price_snapshot,_Digits),profit_str,g_currentClusterId);
        }
      if(PositionTotalByMagicSymbol(InpMagic,_Symbol)==0)
        {
         ResetGridState();
        }
     }
  }
//+------------------------------------------------------------------+
//| Count orders within a cluster                                    |
//+------------------------------------------------------------------+
int CountClusterOrders(ulong cluster_id)
  {
   if(cluster_id==0)
      return(0);

   int count = 0;
   for(int i=0;i<PositionsTotal();++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic)
         continue;

      string comment = PositionGetString(POSITION_COMMENT);
      ulong id = ExtractClusterId(comment);
      if(id==0)
         continue;

      if(id==cluster_id)
         count++;
     }

   return(count);
  }
//+------------------------------------------------------------------+
//| Update last entry price from positions                            |
//+------------------------------------------------------------------+
void UpdateLastEntryFromPositions(ulong cluster_id)
  {
   if(cluster_id==0)
      return;

   datetime latest = 0;
   double price = g_lastGridPrice;

   for(int i=0;i<PositionsTotal();++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic)
         continue;

      string comment = PositionGetString(POSITION_COMMENT);
      ulong id = ExtractClusterId(comment);
      if(id==0)
         continue;

      if(id!=cluster_id)
         continue;

      datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
      if(open_time>=latest)
        {
         latest = open_time;
         price = PositionGetDouble(POSITION_PRICE_OPEN);
        }
     }

   if(latest>0)
      g_lastGridPrice = price;
  }
//+------------------------------------------------------------------+
//| Reset grid state                                                  |
//+------------------------------------------------------------------+
void ResetGridState()
  {
   bool had_cluster = (g_currentClusterId!=0 || g_gridLevels>0);
   g_gridLevels = 0;
   g_lastGridPrice = 0.0;
   g_currentClusterType = ORDER_TYPE_BUY;
   g_currentClusterId = 0;
   g_overlapPartialTriggered = false;
   g_grid.buy_levels = 0;
   g_grid.sell_levels = 0;
   g_activeDirection = (ENUM_ORDER_TYPE)-1;
   g_lastSignalTime = 0;
   g_lastSignalDirection = (ENUM_ORDER_TYPE)-1;
   if(g_nextClusterId<=0)
      g_nextClusterId = 1;
   EntryCooldown("Reset",false,true);
   if(had_cluster)
      Print("Cluster reset — ready for next grid cycle");
  }
//+------------------------------------------------------------------+
//| Get total profit for the active cluster                           |
//+------------------------------------------------------------------+
double GetClusterProfit(const ulong cluster_id)
  {
   double total = 0.0;
   if(cluster_id==0)
      return(0.0);

   for(int i=0;i<PositionsTotal();++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(!IsClusterPosition(ticket,cluster_id))
         continue;

      total += PositionGetDouble(POSITION_PROFIT);
     }
   return(total);
  }
//+------------------------------------------------------------------+
//| Get total profit for the symbol                                   |
//+------------------------------------------------------------------+
double GetSymbolProfit()
  {
   double total = 0.0;

   for(int i=0;i<PositionsTotal();++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic)
         continue;

      total += PositionGetDouble(POSITION_PROFIT);
     }

   return(total);
  }
//+------------------------------------------------------------------+
//| Get total volume for symbol                                       |
//+------------------------------------------------------------------+
double GetTotalVolume(const string symbol)
  {
   double total = 0.0;
   for(int i=0;i<PositionsTotal();++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic)
         continue;

      total += PositionGetDouble(POSITION_VOLUME);
     }
   return(total);
  }
//+------------------------------------------------------------------+
//| Determine the next lot to use for the grid                        |
//+------------------------------------------------------------------+
double GetNextGridLot(const ENUM_ORDER_TYPE type,const ulong cluster_id,const int existing_orders=-1)
  {
   if(type!=ORDER_TYPE_BUY && type!=ORDER_TYPE_SELL)
      return(0.0);

   double min_volume = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double max_volume = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   int volume_digits = GetVolumeDigits(_Symbol);

   int level = existing_orders;
   if(level<0)
      level = (cluster_id>0) ? CountClusterOrders(cluster_id) : 0;

   double multiplier = (EnableGrid && InpLotMultiplier>1.0) ? InpLotMultiplier : 1.0;
   double lot = InpBaseLot*MathPow(multiplier,(double)level);

   if(max_volume>0.0)
      lot = MathMin(lot,max_volume);

   bool round_up = (multiplier>1.0);
   double normalized = NormalizeVolumeValue(lot,min_volume,step,volume_digits,round_up);
   double base_normalized = NormalizeVolumeValue(InpBaseLot,min_volume,step,volume_digits,true);

   if(normalized<base_normalized)
      normalized = base_normalized;

   if(max_volume>0.0)
      normalized = MathMin(normalized,max_volume);

   normalized = NormalizeDouble(normalized,volume_digits);

   return(normalized);
  }
//+------------------------------------------------------------------+
//| Determine precision for volume formatting                        |
//+------------------------------------------------------------------+
int GetVolumeDigits(const string symbol)
  {
   double step = SymbolInfoDouble(symbol,SYMBOL_VOLUME_STEP);
   if(step<=0.0)
      return(2);

   int digits = 0;
   double scaled = step;
   while(scaled<1.0 && digits<8)
     {
      scaled *= 10.0;
      digits++;
     }

   return(digits);
  }
//+------------------------------------------------------------------+
//| Close all orders in the active cluster                            |
//+------------------------------------------------------------------+
bool CloseAllClusterOrders(const ulong cluster_id,int &closed_positions,double &closed_volume)
  {
   closed_positions = 0;
   closed_volume = 0.0;
   bool closed_any = false;

   ulong tickets[];
   ArrayResize(tickets,0);

   for(int i=0;i<PositionsTotal();++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(!IsClusterPosition(ticket,cluster_id))
         continue;

      int new_size = ArraySize(tickets)+1;
      ArrayResize(tickets,new_size);
      tickets[new_size-1] = ticket;
     }

   for(int i=0;i<ArraySize(tickets);++i)
     {
      ulong ticket = tickets[i];
      if(!PositionSelectByTicket(ticket))
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      if(trade.PositionClose(ticket))
        {
         closed_any = true;
         closed_positions++;
         closed_volume += volume;
        }
     }

   return(closed_any);
  }
//| Close the oldest and newest cluster orders                        |
//+------------------------------------------------------------------+
bool CloseClusterEdgeOrders(const ulong cluster_id,double &closed_volume,int &closed_positions)
  {
   closed_volume = 0.0;
   closed_positions = 0;

   if(cluster_id==0)
      return(false);

   ulong oldest_ticket = 0;
   ulong newest_ticket = 0;
   datetime oldest_time = 0;
   datetime newest_time = 0;
   bool initialized = false;

   for(int i=0;i<PositionsTotal();++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(!IsClusterPosition(ticket,cluster_id))
         continue;

      datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
      if(!initialized || open_time<oldest_time)
        {
         oldest_time = open_time;
         oldest_ticket = ticket;
        }
      if(!initialized || open_time>newest_time)
        {
         newest_time = open_time;
         newest_ticket = ticket;
        }
      initialized = true;
     }

   bool closed_any = false;
   ulong tickets[2] = {oldest_ticket,newest_ticket};

   for(int i=0;i<2;++i)
     {
      ulong ticket = tickets[i];
      if(ticket==0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      if(trade.PositionClose(ticket))
        {
         closed_any = true;
         closed_positions++;
         closed_volume += volume;
        }
     }

   return(closed_any);
  }
//+------------------------------------------------------------------+
//| Normalize volume to symbol constraints                            |
//+------------------------------------------------------------------+
double NormalizeVolumeValue(double volume,double min_volume,double step,int digits,bool round_up=false)
  {
   if(volume<min_volume)
     {
      if(!round_up)
         return(0.0);
      volume = min_volume;
     }

   double normalized = volume;
   if(step>0.0)
     {
      double steps = round_up ? MathCeil(volume/step - 1e-8) : MathFloor(volume/step + 1e-8);
      normalized = steps*step;
     }
   normalized = NormalizeDouble(normalized,digits);

   if(normalized<min_volume)
      normalized = min_volume;

   return(normalized);
  }
//+------------------------------------------------------------------+
//| Build cluster comment                                             |
//+------------------------------------------------------------------+
string BuildClusterComment(const ulong cluster_id)
  {
   return(StringFormat("STEA_CLUSTER_%I64u",cluster_id));
  }
//+------------------------------------------------------------------+
//| Check if position belongs to cluster                              |
//+------------------------------------------------------------------+
bool IsClusterPosition(const ulong ticket,const ulong cluster_id)
  {
   if(cluster_id==0 || ticket==0)
      return(false);

   if(!PositionSelectByTicket(ticket))
      return(false);

   if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
      return(false);

   if(PositionGetInteger(POSITION_MAGIC)!=(long)InpMagic)
      return(false);

   ulong id = ExtractClusterId(PositionGetString(POSITION_COMMENT));
   if(id==0)
      return(false);

   return(id==cluster_id);
  }
//+------------------------------------------------------------------+
//| Extract cluster identifier from comment                           |
//+------------------------------------------------------------------+
ulong ExtractClusterId(const string comment)
  {
   const string prefix = "STEA_CLUSTER_";
   int prefix_len = StringLen(prefix);

   if(StringLen(comment)<=prefix_len)
      return(0);

   if(StringSubstr(comment,0,prefix_len)!=prefix)
      return(0);

   string value = StringSubstr(comment,prefix_len);
   return((ulong)StringToInteger(value));
  }
//+------------------------------------------------------------------+
//| Ensure log header exists                                          |
//+------------------------------------------------------------------+
void EnsureLogHeader()
  {
   if(StringLen(g_logFileName)==0)
      return;

   int handle = FileOpen(g_logFileName,FILE_READ|FILE_WRITE|FILE_CSV|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(handle==INVALID_HANDLE)
     {
      handle = FileOpen(g_logFileName,FILE_WRITE|FILE_CSV|FILE_SHARE_READ|FILE_SHARE_WRITE);
      if(handle==INVALID_HANDLE)
        {
         Print("Failed to create log file: ",GetLastError());
         return;
        }
      FileWrite(handle,"time","event","details");
      FileClose(handle);
      g_logHeaderWritten = true;
      return;
     }

   if(FileSize(handle)==0)
      FileWrite(handle,"time","event","details");

   FileClose(handle);
   g_logHeaderWritten = true;
  }
//+------------------------------------------------------------------+
//| Log grid/partial events                                           |
//+------------------------------------------------------------------+
void LogEvent(const string event_type,const string details)
  {
   if(StringLen(g_logFileName)==0)
      return;

   if(!g_logHeaderWritten)
      EnsureLogHeader();

   int handle = FileOpen(g_logFileName,FILE_READ|FILE_WRITE|FILE_CSV|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(handle==INVALID_HANDLE)
     {
      Print("Failed to open log file: ",GetLastError());
      return;
     }

   FileSeek(handle,0,SEEK_END);

   string time_str = TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS);
   FileWrite(handle,time_str,event_type,details);
   FileClose(handle);
  }
//+------------------------------------------------------------------+
//| Refresh indicator buffers                                        |
//+------------------------------------------------------------------+
bool RefreshIndicators()
  {
   if(CopyBuffer(fast_ma_handle,0,0,ArraySize(fast_ma_buffer),fast_ma_buffer)<ArraySize(fast_ma_buffer))
      return(false);
   if(CopyBuffer(slow_ma_handle,0,0,ArraySize(slow_ma_buffer),slow_ma_buffer)<ArraySize(slow_ma_buffer))
      return(false);
   if(CopyBuffer(rsi_handle,0,0,ArraySize(rsi_buffer),rsi_buffer)<ArraySize(rsi_buffer))
      return(false);
   if(CopyBuffer(mfi_handle,0,0,ArraySize(mfi_buffer),mfi_buffer)<ArraySize(mfi_buffer))
      return(false);

   if(CopyRates(_Symbol,_Period,0,InpVolumeLookback,rates)<InpVolumeLookback)
      return(false);

   return(true);
  }
//+------------------------------------------------------------------+
//| Buy signal                                                       |
//+------------------------------------------------------------------+
bool CheckBuySignal()
  {
   double avg_volume = AverageVolume();
   double current_volume = (double)rates[0].tick_volume;
   double relaxed_multiplier = MathMax(0.3,InpVolumeMultiplier*0.5);
   bool volume_confirmed = (avg_volume<=0.0) || (current_volume >= avg_volume*relaxed_multiplier);

   bool ma_bias = (fast_ma_buffer[0]>=slow_ma_buffer[0]);
   bool ma_cross_up = (fast_ma_buffer[0]>slow_ma_buffer[0] && fast_ma_buffer[1]<=slow_ma_buffer[1]);
   double ma_tolerance = 0.1*_Point;
   bool ma_close = (MathAbs(fast_ma_buffer[0]-slow_ma_buffer[0])<=ma_tolerance);
   bool ma_confirm = (ma_bias || ma_cross_up || ma_close);

   double rsi_threshold = MathMax(0.0,InpRSIBullishLevel-10.0);
   bool rsi_confirm  = (rsi_buffer[0]>=rsi_threshold);

   double mfi_threshold  = MathMax(0.0,InpMFIBullishLevel-10.0);
   bool mfi_confirm  = (mfi_buffer[0]>=mfi_threshold);

   return(ma_confirm && rsi_confirm && mfi_confirm && volume_confirmed);
  }
//+------------------------------------------------------------------+
//| Sell signal                                                      |
//+------------------------------------------------------------------+
bool CheckSellSignal()
  {
   double avg_volume = AverageVolume();
   double current_volume = (double)rates[0].tick_volume;
   double relaxed_multiplier = MathMax(0.3,InpVolumeMultiplier*0.5);
   bool volume_confirmed = (avg_volume<=0.0) || (current_volume >= avg_volume*relaxed_multiplier);

   bool ma_bias = (fast_ma_buffer[0]<=slow_ma_buffer[0]);
   bool ma_cross_down = (fast_ma_buffer[0]<slow_ma_buffer[0] && fast_ma_buffer[1]>=slow_ma_buffer[1]);
   double ma_tolerance = 0.1*_Point;
   bool ma_close = (MathAbs(fast_ma_buffer[0]-slow_ma_buffer[0])<=ma_tolerance);
   bool ma_confirm = (ma_bias || ma_cross_down || ma_close);

   double rsi_threshold = MathMin(100.0,InpRSIBearishLevel+10.0);
   bool rsi_confirm   = (rsi_buffer[0]<=rsi_threshold);

   double mfi_threshold = MathMin(100.0,InpMFIBearishLevel+10.0);
   bool mfi_confirm   = (mfi_buffer[0]<=mfi_threshold);

   return(ma_confirm && rsi_confirm && mfi_confirm && volume_confirmed);
  }
//+------------------------------------------------------------------+
//| Open basic position helper                                       |
//+------------------------------------------------------------------+
void OpenBasicPosition(ENUM_ORDER_TYPE type)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return;

   double price = (type==ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   string comment = "STEA_BASIC";
   double sl = 0.0;
   double tp = 0.0;

   if(!EntryCooldown("Basic",false,false))
      return;

   bool result = (type==ORDER_TYPE_BUY) ?
      trade.Buy(InpBaseLot,_Symbol,price,sl,tp,comment) :
      trade.Sell(InpBaseLot,_Symbol,price,sl,tp,comment);

   if(result)
      EntryCooldown("Basic",true,false);
  }
//+------------------------------------------------------------------+
//| Average tick volume                                              |
//+------------------------------------------------------------------+
double AverageVolume()
  {
   if(ArraySize(rates)<=1)
      return(0.0);

   double total = 0.0;
   for(int i=1;i<ArraySize(rates);++i)
      total += (double)rates[i].tick_volume;

   return(total/MathMax(1,ArraySize(rates)-1));
  }
//+------------------------------------------------------------------+
//| Risk control                                                     |
//+------------------------------------------------------------------+
bool CheckRiskLimits()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(initial_equity<=0.0)
      initial_equity = equity;

   double drawdown_percent = 0.0;
   if(initial_equity>0.0)
      drawdown_percent = (initial_equity-equity)/initial_equity*100.0;

   if(drawdown_percent>=InpMaxDrawdownPercent)
     {
      Print("Trading disabled due to maximum drawdown limit.");
      return(false);
     }

   double daily_loss_percent = 0.0;
   if(daily_start_equity>0.0)
      daily_loss_percent = (daily_start_equity-equity)/daily_start_equity*100.0;

   if(daily_loss_percent>=InpDailyLossPercent)
     {
      Print("Trading disabled due to daily loss limit.");
      return(false);
     }

   return(true);
  }
//+------------------------------------------------------------------+
//| Spread helper                                                    |
//+------------------------------------------------------------------+
double GetCurrentSpreadPoints()
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return(0.0);
   return((tick.ask-tick.bid)/_Point);
  }
//+------------------------------------------------------------------+
//| Positions helper                                                 |
//+------------------------------------------------------------------+
int PositionTotalByMagicSymbol(ulong magic,const string symbol)
  {
   int count = 0;
   for(int i=0;i<PositionsTotal();++i)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)==symbol && PositionGetInteger(POSITION_MAGIC)==(long)magic)
         count++;
     }
   return(count);
  }
//+------------------------------------------------------------------+
//| Update trading date and reset daily metrics                      |
//+------------------------------------------------------------------+
bool UpdateTradingDate()
  {
   int today = GetTradingDate();
   if(today!=current_trading_date)
     {
      current_trading_date = today;
      daily_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(daily_start_equity<=0.0)
         return(false);
     }
   return(true);
  }
//+------------------------------------------------------------------+
//| Returns YYYYMMDD integer                                         |
//+------------------------------------------------------------------+
int GetTradingDate()
  {
   MqlDateTime tm;
   TimeCurrent(tm);
   return(tm.year*10000 + tm.mon*100 + tm.day);
  }
//+------------------------------------------------------------------+
//| Entry cooldown controller                                        |
//+------------------------------------------------------------------+
bool EntryCooldown(const string context,bool stamp,bool reset)
  {
   static datetime last_entry_time = 0;

   if(reset)
     {
      last_entry_time = 0;
      return(true);
     }

   datetime now = TimeCurrent();

   if(stamp)
     {
      last_entry_time = now;
      return(true);
     }

   if(last_entry_time!=0 && (now-last_entry_time)<=60)
     {
      PrintFormat("%s entry skipped due to cooldown. Seconds since last entry: %d",context,(int)(now-last_entry_time));
      return(false);
     }

   return(true);
  }
//+------------------------------------------------------------------+
