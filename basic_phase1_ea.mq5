//+------------------------------------------------------------------+
//|                                           basic_phase1_ea.mq5    |
//|  Description: Minimal Expert Advisor using MA, RSI, MFI and      |
//|               Volume confirmation with risk controls.            |
//+------------------------------------------------------------------+
#property copyright ""
#property version   "1.00"

#include <Trade/Trade.mqh>

input double    InpLots                = 0.10;      // Lot size
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
input double    InpStopLossPoints      = 300;       // Stop Loss in points
input double    InpTakeProfitPoints    = 600;       // Take Profit in points
input double    InpMaxSpreadPoints     = 30;        // Maximum allowed spread in points
input double    InpMaxDrawdownPercent  = 20.0;      // Maximum total drawdown (%)
input double    InpDailyLossPercent    = 5.0;       // Maximum daily loss (%)
input ulong     InpMagic               = 20240901;  // Magic number

CTrade          trade;

int             fast_ma_handle = INVALID_HANDLE;
int             slow_ma_handle = INVALID_HANDLE;
int             rsi_handle     = INVALID_HANDLE;
int             mfi_handle     = INVALID_HANDLE;

MqlRates        rates[];
double          fast_ma_buffer[3];
double          slow_ma_buffer[3];
double          rsi_buffer[2];
double          mfi_buffer[2];

double          initial_equity = 0.0;
double          daily_start_equity = 0.0;
int             current_trading_date = -1;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   ArraySetAsSeries(fast_ma_buffer,true);
   ArraySetAsSeries(slow_ma_buffer,true);
   ArraySetAsSeries(rsi_buffer,true);
   ArraySetAsSeries(mfi_buffer,true);

   fast_ma_handle = iMA(_Symbol,_Period,InpFastMAPeriod,0,InpMAMethod,InpMAPrice);
   slow_ma_handle = iMA(_Symbol,_Period,InpSlowMAPeriod,0,InpMAMethod,InpMAPrice);
   rsi_handle     = iRSI(_Symbol,_Period,InpRSIPeriod,InpMAPrice);
   mfi_handle     = iMFI(_Symbol,_Period,InpMFIPeriod);

   if(fast_ma_handle==INVALID_HANDLE || slow_ma_handle==INVALID_HANDLE ||
      rsi_handle==INVALID_HANDLE || mfi_handle==INVALID_HANDLE)
     {
      Print("Failed to create indicator handles. Error: ",GetLastError());
      return(INIT_FAILED);
     }

   ArrayResize(rates,InpVolumeLookback);
   ArraySetAsSeries(rates,true);

   initial_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   daily_start_equity = initial_equity;
   current_trading_date = GetTradingDate();

   trade.SetExpertMagicNumber(InpMagic);

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

   if(PositionTotalByMagicSymbol(InpMagic,_Symbol)>0)
      return;

   bool buy_signal = CheckBuySignal();
   bool sell_signal = CheckSellSignal();

   if(buy_signal)
      OpenPosition(ORDER_TYPE_BUY);
   else if(sell_signal)
      OpenPosition(ORDER_TYPE_SELL);
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
   double current_volume = rates[0].tick_volume;
   bool volume_confirmed = (avg_volume>0.0 && current_volume >= avg_volume*InpVolumeMultiplier);

   bool ma_cross_up = (fast_ma_buffer[0]>slow_ma_buffer[0] && fast_ma_buffer[1]<=slow_ma_buffer[1]);
   bool rsi_confirm  = (rsi_buffer[0]>=InpRSIBullishLevel);
   bool mfi_confirm  = (mfi_buffer[0]>=InpMFIBullishLevel);

   return(ma_cross_up && rsi_confirm && mfi_confirm && volume_confirmed);
  }
//+------------------------------------------------------------------+
//| Sell signal                                                      |
//+------------------------------------------------------------------+
bool CheckSellSignal()
  {
   double avg_volume = AverageVolume();
   double current_volume = rates[0].tick_volume;
   bool volume_confirmed = (avg_volume>0.0 && current_volume >= avg_volume*InpVolumeMultiplier);

   bool ma_cross_down = (fast_ma_buffer[0]<slow_ma_buffer[0] && fast_ma_buffer[1]>=slow_ma_buffer[1]);
   bool rsi_confirm   = (rsi_buffer[0]<=InpRSIBearishLevel);
   bool mfi_confirm   = (mfi_buffer[0]<=InpMFIBearishLevel);

   return(ma_cross_down && rsi_confirm && mfi_confirm && volume_confirmed);
  }
//+------------------------------------------------------------------+
//| Open position helper                                             |
//+------------------------------------------------------------------+
void OpenPosition(ENUM_ORDER_TYPE type)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return;

   double price = (type==ORDER_TYPE_BUY) ? tick.ask : tick.bid;
   double sl = 0.0;
   double tp = 0.0;
   if(InpStopLossPoints>0)
     {
      if(type==ORDER_TYPE_BUY)
         sl = price - InpStopLossPoints*_Point;
      else
         sl = price + InpStopLossPoints*_Point;
     }
   if(InpTakeProfitPoints>0)
     {
      if(type==ORDER_TYPE_BUY)
         tp = price + InpTakeProfitPoints*_Point;
      else
         tp = price - InpTakeProfitPoints*_Point;
     }

   if(type==ORDER_TYPE_BUY)
      trade.Buy(InpLots,_Symbol,price,sl,tp);
   else
      trade.Sell(InpLots,_Symbol,price,sl,tp);
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
      total += rates[i].tick_volume;

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
