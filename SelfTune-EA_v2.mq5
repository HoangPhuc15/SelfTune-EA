//+------------------------------------------------------------------+
//|                                                SelfTune-EA_v2.mq5 |
//|                                                     SelfTune Labs |
//|                Probability enhanced adaptive grid Expert Advisor |
//+------------------------------------------------------------------+
#property copyright "SelfTune Labs"
#property link      "https://github.com/SelfTune"
#property version   "2.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/SymbolInfo.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/HistoryOrderInfo.mqh>

#ifndef DEAL_ENTRY_IN
#define DEAL_ENTRY_IN  ((ENUM_DEAL_ENTRY)0)
#endif
#ifndef DEAL_ENTRY_OUT
#define DEAL_ENTRY_OUT ((ENUM_DEAL_ENTRY)1)
#endif
#ifndef DEAL_ENTRY_IN_BY
#define DEAL_ENTRY_IN_BY ((ENUM_DEAL_ENTRY)2)
#endif
#ifndef DEAL_ENTRY_OUT_BY
#define DEAL_ENTRY_OUT_BY ((ENUM_DEAL_ENTRY)3)
#endif

const int     MAX_VOLUME_BUFFER = 512;
const int     PATTERN_BIT_COUNT = 4;
const int     PATTERN_COMBINATIONS = 1 << PATTERN_BIT_COUNT;

//--- input parameters -------------------------------------------------------
sinput string sep0="--- Trend Filters ---";
input ENUM_MA_METHOD    InpMAType          = MODE_EMA;       // Method for moving averages
input ENUM_APPLIED_PRICE InpMAPrice        = PRICE_CLOSE;    // Price applied to moving averages
input int               InpFastMAPeriod    = 21;             // Fast MA period
input int               InpSlowMAPeriod    = 55;             // Slow MA period
input int               InpRSIPeriod       = 14;             // RSI period
input double            InpRSIOversold     = 35.0;           // RSI oversold
input double            InpRSIOverbought   = 65.0;           // RSI overbought
input int               InpMFIPeriod       = 14;             // MFI period
input double            InpMFIOversold     = 35.0;           // MFI oversold
input double            InpMFIOverbought   = 65.0;           // MFI overbought
input int               InpVolumePeriod    = 34;             // Volume averaging period
input double            InpVolumeMultiplier= 1.20;           // Volume multiplier threshold

sinput string sep1="--- Risk Management ---";
input double            InpRiskPerTrade    = 1.0;            // Risk per trade (% of equity)
input double            InpMaxDrawdown     = 20.0;           // Max equity drawdown before halt (%)
input double            InpDailyLoss       = 5.0;            // Max daily loss before halt (%)
input double            InpATRMultiplierSL = 3.0;            // ATR multiplier for stop loss
input double            InpATRMultiplierTP = 4.5;            // ATR multiplier for take profit
input int               InpATRPeriod       = 14;             // ATR period

sinput string sep2="--- Grid Control ---";
input bool              InpUseGrid         = true;           // Enable grid module
input int               InpMaxGridLevels   = 4;              // Maximum number of grid levels per direction
input double            InpGridStepPoints  = 350;            // Baseline distance between grid orders (points)
input double            InpGridMultiplier  = 1.35;           // Lot multiplier across grid levels

sinput string sep3="--- Adaptive Learning ---";
input int               InpTradesPerTune   = 700;            // Trades before self-tune
input bool              InpAllowParamDecrease = true;        // Allow decreasing periods
input double            InpProbabilityThreshold = 0.68;      // Minimum probability to trade
input double            InpConfidenceFloor = 0.35;           // Minimum confidence factor for reduced sizing

sinput string sep4="--- Logging ---";
input bool              InpVerboseLogging  = true;           // Verbose logging
input bool              InpLogIndicators   = false;          // Log indicator snapshots

//--- structures -------------------------------------------------------------
struct SIndicatorParams
  {
   int      fast_period;
   int      slow_period;
   int      rsi_period;
   double   rsi_overbought;
   double   rsi_oversold;
   int      mfi_period;
   double   mfi_overbought;
   double   mfi_oversold;
   int      volume_period;
   double   volume_multiplier;
   ENUM_MA_METHOD    ma_method;
   ENUM_APPLIED_PRICE ma_price;
  };

struct SRiskState
  {
   double   start_equity;
   double   peak_equity;
   double   daily_start_equity;
   datetime daily_marker;
  };

struct STradeStats
  {
   ulong    total_trades;
   ulong    window_trades;
   ulong    window_wins;
   ulong    window_losses;
   double   total_profit;
   double   window_profit;
  };

struct SGridState
  {
   int      buy_levels;
   int      sell_levels;
   double   last_buy_price;
   double   last_sell_price;
   double   base_buy_lot;
   double   base_sell_lot;
  };

struct SPatternStats
  {
   ulong    trades;
  ulong    wins;
   double   sum_profit;
   double   sum_win_profit;
   double   sum_loss_profit;
  };

struct SPatternModel
  {
   double   probability;
   double   average_win;
   double   average_loss;
  };

struct SActiveTradeContext
  {
   ulong                position_id;
   int                  pattern_index;
   ENUM_POSITION_TYPE   direction;
   double               probability;
  };

struct SPatternCandidate
  {
   ENUM_POSITION_TYPE direction;
   int                pattern_index;
   double             probability;
  };

struct SSignalDecision
  {
   bool                signal;
   bool                conditions[PATTERN_BIT_COUNT];
   int                 confirmed;
   int                 pattern_index;
   double              estimated_probability;
   double              avg_win;
   double              avg_loss;
  };

//--- global variables -------------------------------------------------------
CTrade        g_trade;

SIndicatorParams g_params;
SRiskState       g_risk;
STradeStats      g_stats;
SGridState       g_grid = {0,0,0.0,0.0,0.0,0.0};
SPatternStats    g_patternStats[2][PATTERN_COMBINATIONS];
SPatternModel    g_patternModel[2][PATTERN_COMBINATIONS];
SActiveTradeContext g_activeTrades[];
SPatternCandidate   g_pendingPatterns[];
SSignalDecision     g_buyDecision;
SSignalDecision     g_sellDecision;

int g_fastMAHandle = INVALID_HANDLE;
int g_slowMAHandle = INVALID_HANDLE;
int g_rsiHandle    = INVALID_HANDLE;
int g_mfiHandle    = INVALID_HANDLE;
int g_volHandle    = INVALID_HANDLE;
int g_atrHandle    = INVALID_HANDLE;

double g_fastMABuffer[];
double g_slowMABuffer[];
double g_rsiBuffer[];
double g_mfiBuffer[];
double g_volBuffer[];
double g_atrBuffer[];

datetime g_lastBarTime = 0;

string g_logFileName        = "SelfTuneEA_log.csv";
string g_stateFileName      = "SelfTuneEA_state.csv";
string g_learningFileName   = "SelfTuneEA_learning.csv";

//--- forward declarations ---------------------------------------------------
void        InitializeParameters();
bool        CreateIndicatorHandles();
void        ReleaseIndicatorHandles();
bool        RefreshIndicators();
bool        IsNewBar();
void        EvaluateSignals(bool &buy_signal, bool &sell_signal, double &atr_points);
void        ExecuteSignal(const bool buy_signal, const bool sell_signal, const double atr_points);
double      CalculateLotSize(const double stop_loss_points);
bool        RiskChecks();
void        ManagePositions(const double atr_points);
void        ManageGrid(const double atr_points);
void        ResetGridStateIfNeeded();
void        LogEvent(const string message);
void        LogIndicatorSnapshot();
void        LogTrade(const ulong deal_ticket, const double deal_profit, const string direction);
void        LoadState();
void        SaveState();
void        ResetWindowStats();
void        SelfTuneParameters();
void        RecreateIndicators();
void        LoadLearningData();
void        SaveLearningData();
void        UpdateProbabilityModel();
void        UpdateProbabilityModel(const int dir_index, const int pattern_index);
int         PatternIndexFromConditions(const bool cond_ma,const bool cond_rsi,const bool cond_mfi,const bool cond_vol);
void        EvaluatePatternProbability(const bool cond_ma,const bool cond_rsi,const bool cond_mfi,const bool cond_vol,
                                       const ENUM_POSITION_TYPE direction,int &pattern_index,double &probability,
                                       double &avg_profit,double &avg_loss);
bool        PredictTradeOutcome(const SSignalDecision &decision,const double base_lot,double &adjusted_lot);
double      AdaptiveGridSpacing(const double atr_points);
void        PushPendingPattern(const SPatternCandidate &candidate);
bool        PopPendingPattern(const ENUM_POSITION_TYPE direction,SPatternCandidate &candidate);
void        RegisterActiveTrade(const ulong position_id,const int pattern_index,const ENUM_POSITION_TYPE direction,
                                const double probability);
bool        ExtractActiveTrade(const ulong position_id,int &pattern_index,ENUM_POSITION_TYPE &direction,double &probability);
void        RemoveActiveTradeByIndex(const int index);
void        RecordTradePattern(const ENUM_POSITION_TYPE direction,const int pattern_index,const double probability,
                               const double profit);


//--- global variables -------------------------------------------------------
SIndicatorParams g_params;
SRiskState       g_risk;
STradeStats      g_stats;
SGridState       g_grid = {0,0,0.0,0.0,0.0,0.0};
SPatternStats    g_patternStats[2][PATTERN_COMBINATIONS];
SPatternModel    g_patternModel[2][PATTERN_COMBINATIONS];
SActiveTradeContext g_activeTrades[];
SPatternCandidate   g_pendingPatterns[];
SSignalDecision     g_buyDecision;
SSignalDecision     g_sellDecision;

int g_fastMAHandle = INVALID_HANDLE;
int g_slowMAHandle = INVALID_HANDLE;
int g_rsiHandle    = INVALID_HANDLE;
int g_mfiHandle    = INVALID_HANDLE;
int g_volHandle    = INVALID_HANDLE;
int g_atrHandle    = INVALID_HANDLE;

double g_fastMABuffer[];
double g_slowMABuffer[];
double g_rsiBuffer[];
double g_mfiBuffer[];
double g_volBuffer[];
double g_atrBuffer[];

datetime g_lastBarTime = 0;

string g_logFileName        = "SelfTuneEA_log.csv";
string g_stateFileName      = "SelfTuneEA_state.csv";
string g_learningFileName   = "SelfTuneEA_learning.csv";

//--- forward declarations ---------------------------------------------------
void        InitializeParameters();
bool        CreateIndicatorHandles();
void        ReleaseIndicatorHandles();
bool        RefreshIndicators();
bool        IsNewBar();
void        EvaluateSignals(bool &buy_signal, bool &sell_signal, double &atr_points);
void        ExecuteSignal(const bool buy_signal, const bool sell_signal, const double atr_points);
double      CalculateLotSize(const double stop_loss_points);
bool        RiskChecks();
void        ManagePositions(const double atr_points);
void        ManageGrid(const double atr_points);
void        ResetGridStateIfNeeded();
void        LogEvent(const string message);
void        LogIndicatorSnapshot();
void        LogTrade(const ulong deal_ticket, const double deal_profit, const string direction);
void        LoadState();
void        SaveState();
void        ResetWindowStats();
void        SelfTuneParameters();
void        RecreateIndicators();
void        LoadLearningData();
void        SaveLearningData();
void        UpdateProbabilityModel();
void        UpdateProbabilityModel(const int dir_index, const int pattern_index);
int         PatternIndexFromConditions(const bool cond_ma,const bool cond_rsi,const bool cond_mfi,const bool cond_vol);
void        EvaluatePatternProbability(const bool cond_ma,const bool cond_rsi,const bool cond_mfi,const bool cond_vol,
                                       const ENUM_POSITION_TYPE direction,int &pattern_index,double &probability,
                                       double &avg_profit,double &avg_loss);
bool        PredictTradeOutcome(const SSignalDecision &decision,const double base_lot,double &adjusted_lot);
double      AdaptiveGridSpacing(const double atr_points);
void        PushPendingPattern(const SPatternCandidate &candidate);
bool        PopPendingPattern(const ENUM_POSITION_TYPE direction,SPatternCandidate &candidate);
void        RegisterActiveTrade(const ulong position_id,const int pattern_index,const ENUM_POSITION_TYPE direction,
                                const double probability);
bool        ExtractActiveTrade(const ulong position_id,int &pattern_index,ENUM_POSITION_TYPE &direction,double &probability);
void        RemoveActiveTradeByIndex(const int index);
void        RecordTradePattern(const ENUM_POSITION_TYPE direction,const int pattern_index,const double probability,
                               const double profit);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!SymbolSelect(_Symbol,true))
     {
      Print(__FUNCTION__,": failed to select symbol");
      return(INIT_FAILED);
     }

   InitializeParameters();
   LoadState();
   LoadLearningData();
   UpdateProbabilityModel();

   g_risk.start_equity       = AccountInfoDouble(ACCOUNT_EQUITY);
   g_risk.peak_equity        = g_risk.start_equity;
   g_risk.daily_start_equity = g_risk.start_equity;
   g_risk.daily_marker       = TimeCurrent();

   if(!CreateIndicatorHandles())
     {
      Print(__FUNCTION__,": indicator handle creation failed");
      return(INIT_FAILED);
     }

   MathSrand((uint)TimeLocal());
   g_trade.SetExpertMagicNumber((uint)MathRand());

   int log_handle = FileOpen(g_logFileName, FILE_READ|FILE_ANSI|FILE_COMMON);
   if(log_handle==INVALID_HANDLE)
     {
      log_handle = FileOpen(g_logFileName, FILE_WRITE|FILE_ANSI|FILE_COMMON);
      if(log_handle!=INVALID_HANDLE)
        {
         FileWriteString(log_handle, "timestamp,event,message\n");
         FileClose(log_handle);
        }
     }
   else
     FileClose(log_handle);

   LogEvent("EA initialized");
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   SaveState();
   SaveLearningData();
   ReleaseIndicatorHandles();
   LogEvent(StringFormat("EA deinitialized (%d)",reason));
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   bool trading_allowed = RiskChecks();
   double atr_points = (g_atrBuffer[0]>0.0 ? g_atrBuffer[0]/_Point : 0.0);
   bool buy_signal=false, sell_signal=false;

   if(IsNewBar())
     {
      if(RefreshIndicators())
        {
         EvaluateSignals(buy_signal, sell_signal, atr_points);
         if(InpLogIndicators)
            LogIndicatorSnapshot();
         if(trading_allowed)
            ExecuteSignal(buy_signal, sell_signal, atr_points);
        }
     }

  ManagePositions(atr_points);
  if(trading_allowed)
     ManageGrid(atr_points);
  }
//+------------------------------------------------------------------+
//| Trade transaction handler                                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(trans.deal==0 || trans.symbol!=_Symbol)
      return;

   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD && trans.type!=TRADE_TRANSACTION_DEAL_UPDATE)
      return;

   ENUM_DEAL_ENTRY entry_type = DEAL_ENTRY_IN;
   ENUM_DEAL_TYPE  deal_type  = DEAL_TYPE_BUY;
   double profit              = 0.0;
   double deal_volume         = (result.volume>0.0 ? result.volume : request.volume);
   double deal_price          = (result.price>0.0 ? result.price : request.price);

   bool history_ready = HistoryDealSelect(trans.deal);
   if(history_ready)
     {
      long entry_raw = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      if(entry_raw!=WRONG_VALUE)
         entry_type = (ENUM_DEAL_ENTRY)entry_raw;

      long type_raw = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
      if(type_raw!=WRONG_VALUE)
         deal_type = (ENUM_DEAL_TYPE)type_raw;

      double hist_profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
      if(MathIsValidNumber(hist_profit))
         profit = hist_profit;

      double hist_volume = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
      if(hist_volume>0.0)
         deal_volume = hist_volume;

      double hist_price = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
      if(hist_price>0.0)
         deal_price = hist_price;
     }

   if(!history_ready)
     {
      if(trans.deal_type==DEAL_TYPE_BUY || trans.deal_type==DEAL_TYPE_SELL)
         deal_type = trans.deal_type;

      if(request.volume>0.0)
         deal_volume = request.volume;
      if(result.volume>0.0)
         deal_volume = result.volume;

      if(request.price>0.0)
         deal_price = request.price;
      if(result.price>0.0)
         deal_price = result.price;
     }

   bool entry_is_in  = (entry_type==DEAL_ENTRY_IN || entry_type==DEAL_ENTRY_IN_BY);
   bool entry_is_out = (entry_type==DEAL_ENTRY_OUT || entry_type==DEAL_ENTRY_OUT_BY);

   if(entry_is_in)
     {
      g_stats.total_trades++;
      g_stats.window_trades++;
      if(deal_type==DEAL_TYPE_BUY)
        {
         if(g_grid.buy_levels==0)
            g_grid.base_buy_lot = deal_volume;
         g_grid.buy_levels++;
         g_grid.last_buy_price = deal_price;
        }
      else if(deal_type==DEAL_TYPE_SELL)
        {
         if(g_grid.sell_levels==0)
            g_grid.base_sell_lot = deal_volume;
         g_grid.sell_levels++;
         g_grid.last_sell_price = deal_price;
        }

      ENUM_POSITION_TYPE new_direction = (deal_type==DEAL_TYPE_SELL ? POSITION_TYPE_SELL : POSITION_TYPE_BUY);
      SPatternCandidate candidate;
      if(PopPendingPattern(new_direction, candidate))
        {
         ulong position_id = trans.position;
         if(position_id==0 && history_ready)
           {
            long pos_id = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
            if(pos_id>0)
               position_id = (ulong)pos_id;
           }
         if(position_id>0)
            RegisterActiveTrade(position_id, candidate.pattern_index, new_direction, candidate.probability);
        }
     }

   if(entry_is_out)
     {
      bool closing_buy = (deal_type==DEAL_TYPE_SELL);
      ENUM_POSITION_TYPE original_direction = closing_buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      string direction = closing_buy ? "CLOSE_BUY" : "CLOSE_SELL";
      if(profit>=0)
         g_stats.window_wins++;
      else
         g_stats.window_losses++;
      g_stats.total_profit += profit;
      g_stats.window_profit += profit;
      LogTrade(trans.deal, profit, direction);

      ulong position_id = trans.position;
      if(position_id==0 && history_ready)
        {
         long pos_id = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
         if(pos_id>0)
            position_id = (ulong)pos_id;
        }
      int pattern_index = -1;
      double probability_used = 0.0;
      ENUM_POSITION_TYPE recorded_direction = original_direction;
      if(position_id>0 && ExtractActiveTrade(position_id, pattern_index, recorded_direction, probability_used))
        {
         RecordTradePattern(recorded_direction, pattern_index, probability_used, profit);
        }

      if(deal_type==DEAL_TYPE_BUY)
        {
         if(g_grid.buy_levels>0)
            g_grid.buy_levels--;
         if(g_grid.buy_levels==0)
           {
            g_grid.last_buy_price = 0.0;
            g_grid.base_buy_lot  = 0.0;
           }
        }
      else if(deal_type==DEAL_TYPE_SELL)
        {
         if(g_grid.sell_levels>0)
            g_grid.sell_levels--;
         if(g_grid.sell_levels==0)
           {
            g_grid.last_sell_price = 0.0;
            g_grid.base_sell_lot   = 0.0;
           }
        }
     }

   if(g_stats.window_trades>= (ulong)MathMax(1, InpTradesPerTune))
     {
      SelfTuneParameters();
      ResetWindowStats();
      UpdateProbabilityModel();
      SaveLearningData();
      LogEvent("Learning window completed and parameters tuned");
     }

   ResetGridStateIfNeeded();
  }

//+------------------------------------------------------------------+
//| Initialize parameters from inputs                                 |
//+------------------------------------------------------------------+
void InitializeParameters()
  {
   g_params.fast_period        = MathMax(2, InpFastMAPeriod);
   g_params.slow_period        = MathMax(g_params.fast_period+2, InpSlowMAPeriod);
   g_params.rsi_period         = MathMax(3, InpRSIPeriod);
   g_params.rsi_oversold       = InpRSIOversold;
   g_params.rsi_overbought     = InpRSIOverbought;
   g_params.mfi_period         = MathMax(3, InpMFIPeriod);
   g_params.mfi_oversold       = InpMFIOversold;
   g_params.mfi_overbought     = InpMFIOverbought;
   g_params.volume_period      = MathMax(5, MathMin(MAX_VOLUME_BUFFER, InpVolumePeriod));
   g_params.volume_multiplier  = MathMax(0.5, InpVolumeMultiplier);
   g_params.ma_method          = InpMAType;
   g_params.ma_price           = InpMAPrice;
  }
//+------------------------------------------------------------------+
//| Create indicator handles                                         |
//+------------------------------------------------------------------+
bool CreateIndicatorHandles()
  {
   ReleaseIndicatorHandles();

   g_fastMAHandle = iMA(_Symbol, _Period, g_params.fast_period, 0, g_params.ma_method, g_params.ma_price);
  g_slowMAHandle = iMA(_Symbol, _Period, g_params.slow_period, 0, g_params.ma_method, g_params.ma_price);
  g_rsiHandle    = iRSI(_Symbol, _Period, g_params.rsi_period, g_params.ma_price);
  g_mfiHandle    = iMFI(_Symbol, _Period, g_params.mfi_period, VOLUME_TICK);
  g_volHandle    = iVolumes(_Symbol, _Period, VOLUME_TICK);
  g_atrHandle    = iATR(_Symbol, _Period, InpATRPeriod);

   if(g_fastMAHandle==INVALID_HANDLE || g_slowMAHandle==INVALID_HANDLE ||
      g_rsiHandle==INVALID_HANDLE || g_mfiHandle==INVALID_HANDLE ||
      g_volHandle==INVALID_HANDLE || g_atrHandle==INVALID_HANDLE)
     {
      Print(__FUNCTION__,": handle creation failed, error=",GetLastError());
      return(false);
     }

   ArrayResize(g_fastMABuffer,4);
   ArrayResize(g_slowMABuffer,4);
   ArrayResize(g_rsiBuffer,4);
   ArrayResize(g_mfiBuffer,4);
   ArrayResize(g_atrBuffer,4);
   int volume_size = MathMax(g_params.volume_period,5);
   ArrayResize(g_volBuffer,volume_size);

   ArraySetAsSeries(g_fastMABuffer,true);
   ArraySetAsSeries(g_slowMABuffer,true);
   ArraySetAsSeries(g_rsiBuffer,true);
   ArraySetAsSeries(g_mfiBuffer,true);
   ArraySetAsSeries(g_volBuffer,true);
   ArraySetAsSeries(g_atrBuffer,true);

   return(true);
  }
//+------------------------------------------------------------------+
//| Release indicator handles                                        |
//+------------------------------------------------------------------+
void ReleaseIndicatorHandles()
  {
   if(g_fastMAHandle!=INVALID_HANDLE)
     {
      IndicatorRelease(g_fastMAHandle);
      g_fastMAHandle = INVALID_HANDLE;
     }
   if(g_slowMAHandle!=INVALID_HANDLE)
     {
      IndicatorRelease(g_slowMAHandle);
      g_slowMAHandle = INVALID_HANDLE;
     }
   if(g_rsiHandle!=INVALID_HANDLE)
     {
      IndicatorRelease(g_rsiHandle);
      g_rsiHandle = INVALID_HANDLE;
     }
   if(g_mfiHandle!=INVALID_HANDLE)
     {
      IndicatorRelease(g_mfiHandle);
      g_mfiHandle = INVALID_HANDLE;
     }
   if(g_volHandle!=INVALID_HANDLE)
     {
      IndicatorRelease(g_volHandle);
      g_volHandle = INVALID_HANDLE;
     }
   if(g_atrHandle!=INVALID_HANDLE)
     {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
     }
  }
//+------------------------------------------------------------------+
//| Refresh indicator buffers                                         |
//+------------------------------------------------------------------+
bool RefreshIndicators()
  {
   if(g_fastMAHandle==INVALID_HANDLE || g_slowMAHandle==INVALID_HANDLE ||
      g_rsiHandle==INVALID_HANDLE || g_mfiHandle==INVALID_HANDLE ||
      g_volHandle==INVALID_HANDLE || g_atrHandle==INVALID_HANDLE)
      return(false);

   if(CopyBuffer(g_fastMAHandle,0,0,ArraySize(g_fastMABuffer),g_fastMABuffer)<=0)
      return(false);
   if(CopyBuffer(g_slowMAHandle,0,0,ArraySize(g_slowMABuffer),g_slowMABuffer)<=0)
      return(false);
   if(CopyBuffer(g_rsiHandle,0,0,ArraySize(g_rsiBuffer),g_rsiBuffer)<=0)
      return(false);
   if(CopyBuffer(g_mfiHandle,0,0,ArraySize(g_mfiBuffer),g_mfiBuffer)<=0)
      return(false);
   if(CopyBuffer(g_volHandle,0,0,ArraySize(g_volBuffer),g_volBuffer)<=0)
      return(false);
   if(CopyBuffer(g_atrHandle,0,0,ArraySize(g_atrBuffer),g_atrBuffer)<=0)
      return(false);

   return(true);
  }
//+------------------------------------------------------------------+
//| Detect new bars                                                   |
//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime current_time = iTime(_Symbol,_Period,0);
   if(current_time==0)
      return(false);
   if(current_time!=g_lastBarTime)
     {
      g_lastBarTime = current_time;
      return(true);
     }
   return(false);
  }
//+------------------------------------------------------------------+
//| Evaluate core signals and probability                             |
//+------------------------------------------------------------------+
void EvaluateSignals(bool &buy_signal, bool &sell_signal, double &atr_points)
  {
   buy_signal  = false;
   sell_signal = false;
   atr_points  = MathMax(1.0, g_atrBuffer[0]/_Point);

   double fast_ma_now = g_fastMABuffer[0];
   double slow_ma_now = g_slowMABuffer[0];
   double fast_ma_prev= g_fastMABuffer[1];
   double slow_ma_prev= g_slowMABuffer[1];

   double rsi_now = g_rsiBuffer[0];
   double mfi_now = g_mfiBuffer[0];

   double volume_now = g_volBuffer[0];
   double volume_avg = 0.0;
   int count = MathMin(g_params.volume_period,ArraySize(g_volBuffer));
   for(int i=0;i<count;i++)
      volume_avg += g_volBuffer[i];
   if(count>0)
      volume_avg /= count;

   bool ma_bullish = (fast_ma_now>slow_ma_now) && (fast_ma_prev<=slow_ma_prev);
   bool ma_bearish = (fast_ma_now<slow_ma_now) && (fast_ma_prev>=slow_ma_prev);

   bool rsi_oversold = (rsi_now<=g_params.rsi_oversold);
   bool rsi_overbought = (rsi_now>=g_params.rsi_overbought);

   bool mfi_oversold = (mfi_now<=g_params.mfi_oversold);
   bool mfi_overbought = (mfi_now>=g_params.mfi_overbought);

   bool volume_confirm = (volume_avg>0 && volume_now >= volume_avg*g_params.volume_multiplier);

   ArrayInitialize(g_buyDecision.conditions,false);
   g_buyDecision.conditions[0] = ma_bullish;
   g_buyDecision.conditions[1] = rsi_oversold;
   g_buyDecision.conditions[2] = mfi_oversold;
   g_buyDecision.conditions[3] = volume_confirm;
   g_buyDecision.confirmed = 0;
   for(int bi=0; bi<PATTERN_BIT_COUNT; ++bi)
      if(g_buyDecision.conditions[bi])
         g_buyDecision.confirmed++;

   EvaluatePatternProbability(g_buyDecision.conditions[0], g_buyDecision.conditions[1], g_buyDecision.conditions[2], g_buyDecision.conditions[3],
                              POSITION_TYPE_BUY, g_buyDecision.pattern_index, g_buyDecision.estimated_probability,
                              g_buyDecision.avg_win, g_buyDecision.avg_loss);
   buy_signal = (g_buyDecision.confirmed>=3);
   g_buyDecision.signal = buy_signal;

   ArrayInitialize(g_sellDecision.conditions,false);
   g_sellDecision.conditions[0] = ma_bearish;
   g_sellDecision.conditions[1] = rsi_overbought;
   g_sellDecision.conditions[2] = mfi_overbought;
   g_sellDecision.conditions[3] = volume_confirm;
   g_sellDecision.confirmed = 0;
   for(int si=0; si<PATTERN_BIT_COUNT; ++si)
      if(g_sellDecision.conditions[si])
         g_sellDecision.confirmed++;

   EvaluatePatternProbability(g_sellDecision.conditions[0], g_sellDecision.conditions[1], g_sellDecision.conditions[2], g_sellDecision.conditions[3],
                              POSITION_TYPE_SELL, g_sellDecision.pattern_index, g_sellDecision.estimated_probability,
                              g_sellDecision.avg_win, g_sellDecision.avg_loss);
   sell_signal = (g_sellDecision.confirmed>=3);
   g_sellDecision.signal = sell_signal;
  }
//+------------------------------------------------------------------+
//| Execute trade signals with probability control                    |
//+------------------------------------------------------------------+
void ExecuteSignal(const bool buy_signal, const bool sell_signal, const double atr_points)
  {
   if(!buy_signal && !sell_signal)
      return;

   double stop_loss_points = atr_points * InpATRMultiplierSL;
   double take_profit_points = atr_points * InpATRMultiplierTP;

   double base_lot = CalculateLotSize(stop_loss_points);
   if(base_lot<=0.0)
      return;

   double buy_lot = base_lot;
   double sell_lot = base_lot;
   bool buy_allowed = buy_signal;
   bool sell_allowed = sell_signal;

   if(buy_signal)
      buy_allowed = PredictTradeOutcome(g_buyDecision, base_lot, buy_lot);
   if(sell_signal)
      sell_allowed = PredictTradeOutcome(g_sellDecision, base_lot, sell_lot);

   double price = 0.0;
   bool trade_result = false;

   if(buy_allowed && (!sell_allowed || PositionSelect(_Symbol)==false || PositionGetInteger(POSITION_TYPE)!=POSITION_TYPE_SELL))
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      trade_result = g_trade.Buy(buy_lot, _Symbol, price, price - stop_loss_points*_Point, price + take_profit_points*_Point, "SelfTune BUY");
      if(trade_result)
        {
         SPatternCandidate candidate = {POSITION_TYPE_BUY, g_buyDecision.pattern_index, g_buyDecision.estimated_probability};
         PushPendingPattern(candidate);
        }
     }
   else if(sell_allowed && (!buy_allowed || PositionSelect(_Symbol)==false || PositionGetInteger(POSITION_TYPE)!=POSITION_TYPE_BUY))
     {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      trade_result = g_trade.Sell(sell_lot, _Symbol, price, price + stop_loss_points*_Point, price - take_profit_points*_Point, "SelfTune SELL");
      if(trade_result)
        {
         SPatternCandidate candidate = {POSITION_TYPE_SELL, g_sellDecision.pattern_index, g_sellDecision.estimated_probability};
         PushPendingPattern(candidate);
        }
     }

   if(trade_result)
     {
      double used_prob = buy_allowed ? g_buyDecision.estimated_probability : g_sellDecision.estimated_probability;
      double used_lot  = buy_allowed ? buy_lot : sell_lot;
      LogEvent(StringFormat("Order sent (lots=%.2f, prob=%.2f)", used_lot, used_prob));
     }
   else if(buy_signal || sell_signal)
     {
      LogEvent(StringFormat("Order send failed: %d", GetLastError()));
     }
  }
//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(const double stop_loss_points)
  {
   if(stop_loss_points<=0.0)
      return(0.0);

   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount = equity * InpRiskPerTrade / 100.0;

   double tick_value  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lot_step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_lot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(tick_value<=0 || tick_size<=0 || lot_step<=0)
      return(min_lot);

   double point_value = tick_value / tick_size;
   double lot = risk_amount / (stop_loss_points * _Point * point_value);

   lot = MathFloor(lot/lot_step) * lot_step;
   lot = MathMax(min_lot, MathMin(max_lot, lot));

   return(lot);
  }
//+------------------------------------------------------------------+
//| Perform risk guard checks                                        |
//+------------------------------------------------------------------+
bool RiskChecks()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_risk.peak_equity = MathMax(g_risk.peak_equity, equity);

   double drawdown = (g_risk.peak_equity - equity) / MathMax(0.01, g_risk.peak_equity) * 100.0;
   if(drawdown >= InpMaxDrawdown)
     {
      LogEvent("Trading halted: max drawdown reached");
      return(false);
     }

   datetime now_time = TimeCurrent();
   MqlDateTime now_struct, marker_struct;
   TimeToStruct(now_time, now_struct);
   TimeToStruct(g_risk.daily_marker, marker_struct);
   if(now_struct.year!=marker_struct.year || now_struct.mon!=marker_struct.mon || now_struct.day!=marker_struct.day)
     {
      g_risk.daily_marker = now_time;
      g_risk.daily_start_equity = equity;
     }

   double daily_loss = (g_risk.daily_start_equity - equity) / MathMax(0.01, g_risk.daily_start_equity) * 100.0;
   if(daily_loss >= InpDailyLoss)
     {
      LogEvent("Trading halted: daily loss limit reached");
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Manage open positions and trailing                               |
//+------------------------------------------------------------------+
void ManagePositions(const double atr_points)
  {
   if(!PositionSelect(_Symbol))
      return;

   double current_price = 0.0;
   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double stop_loss     = PositionGetDouble(POSITION_SL);
   double take_profit   = PositionGetDouble(POSITION_TP);
   double volume        = PositionGetDouble(POSITION_VOLUME);

   double atr_for_trail = MathMax(atr_points, g_atrBuffer[0]/_Point);
   if(atr_for_trail<=0.0)
      return;
   double trail_points  = atr_for_trail * (InpATRMultiplierSL/2.0);

   bool update_needed = false;

   if(pos_type==POSITION_TYPE_BUY)
     {
      current_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double new_sl = current_price - trail_points*_Point;
      if(stop_loss<new_sl)
        {
         stop_loss = new_sl;
         update_needed = true;
        }
     }
   else if(pos_type==POSITION_TYPE_SELL)
     {
      current_price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double new_sl = current_price + trail_points*_Point;
      if(stop_loss>new_sl || stop_loss==0.0)
        {
         stop_loss = new_sl;
         update_needed = true;
        }
     }

   if(update_needed)
     {
      if(g_trade.PositionModify(_Symbol, stop_loss, take_profit))
         LogEvent(StringFormat("Trailing stop adjusted (%.2f lots)", volume));
     }
  }
//+------------------------------------------------------------------+
//| Manage grid positions                                            |
//+------------------------------------------------------------------+
void ManageGrid(const double atr_points)
  {
   if(!InpUseGrid || InpMaxGridLevels<=0)
      return;

   if(!PositionSelect(_Symbol))
      return;

   ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double last_price      = (pos_type==POSITION_TYPE_BUY) ? g_grid.last_buy_price : g_grid.last_sell_price;
   double current_volume  = PositionGetDouble(POSITION_VOLUME);
   double base_lot        = (pos_type==POSITION_TYPE_BUY) ? (g_grid.base_buy_lot>0.0 ? g_grid.base_buy_lot : current_volume)
                                                          : (g_grid.base_sell_lot>0.0 ? g_grid.base_sell_lot : current_volume);
   double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl_points   = MathMax(atr_points, g_atrBuffer[0]/_Point) * InpATRMultiplierSL;
   double tp_points   = MathMax(atr_points, g_atrBuffer[0]/_Point) * InpATRMultiplierTP;

   double dynamic_step_points = AdaptiveGridSpacing(MathMax(atr_points, g_atrBuffer[0]/_Point));

   if(last_price<=0.0)
     {
      if(pos_type==POSITION_TYPE_BUY)
         g_grid.last_buy_price = PositionGetDouble(POSITION_PRICE_OPEN);
      else if(pos_type==POSITION_TYPE_SELL)
         g_grid.last_sell_price = PositionGetDouble(POSITION_PRICE_OPEN);
      return;
     }

   double min_lot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int    vol_digits = 2;
   if(lot_step>0.0)
     {
      double step = lot_step;
      int digits = 0;
      while(digits<8 && step<1.0)
        {
         step*=10.0;
         digits++;
        }
      vol_digits = MathMax(0, digits);
     }

   if(pos_type==POSITION_TYPE_BUY)
     {
      double trigger_price = last_price - dynamic_step_points * _Point;
      if(current_bid<=trigger_price && g_grid.buy_levels<InpMaxGridLevels)
        {
         double lot = base_lot * MathPow(InpGridMultiplier, g_grid.buy_levels);
         lot = MathMin(max_lot, MathMax(min_lot, lot));
         if(lot_step>0.0)
           lot = MathFloor(lot/lot_step)*lot_step;
         lot = NormalizeDouble(lot, vol_digits);
         if(g_trade.Buy(lot, _Symbol, current_ask, current_ask - sl_points*_Point, current_ask + tp_points*_Point, "Grid BUY"))
           {
            LogEvent(StringFormat("Grid BUY level %d opened (step=%.1f)", g_grid.buy_levels+1, dynamic_step_points));
            SPatternCandidate candidate = {POSITION_TYPE_BUY, g_buyDecision.pattern_index, g_buyDecision.estimated_probability};
            PushPendingPattern(candidate);
           }
        }
     }
   else if(pos_type==POSITION_TYPE_SELL)
     {
      double trigger_price = last_price + dynamic_step_points * _Point;
      if(current_ask>=trigger_price && g_grid.sell_levels<InpMaxGridLevels)
        {
         double lot = base_lot * MathPow(InpGridMultiplier, g_grid.sell_levels);
         lot = MathMin(max_lot, MathMax(min_lot, lot));
         if(lot_step>0.0)
           lot = MathFloor(lot/lot_step)*lot_step;
         lot = NormalizeDouble(lot, vol_digits);
         if(g_trade.Sell(lot, _Symbol, current_bid, current_bid + sl_points*_Point, current_bid - tp_points*_Point, "Grid SELL"))
           {
            LogEvent(StringFormat("Grid SELL level %d opened (step=%.1f)", g_grid.sell_levels+1, dynamic_step_points));
            SPatternCandidate candidate = {POSITION_TYPE_SELL, g_sellDecision.pattern_index, g_sellDecision.estimated_probability};
            PushPendingPattern(candidate);
           }
        }
     }
  }
//+------------------------------------------------------------------+
//| Update grid state after position closures                         |
//+------------------------------------------------------------------+
void ResetGridStateIfNeeded()
  {
   double buy_volume=0.0, sell_volume=0.0;
   int total_positions = PositionsTotal();
   for(int idx=0; idx<total_positions; idx++)
     {
      ulong ticket = PositionGetTicket(idx);
      if(ticket==0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      ENUM_POSITION_TYPE type=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(type==POSITION_TYPE_BUY)
         buy_volume += PositionGetDouble(POSITION_VOLUME);
      else if(type==POSITION_TYPE_SELL)
         sell_volume += PositionGetDouble(POSITION_VOLUME);
     }

   if(buy_volume==0.0)
     {
      g_grid.buy_levels = 0;
      g_grid.last_buy_price = 0.0;
      g_grid.base_buy_lot = 0.0;
     }
   if(sell_volume==0.0)
     {
      g_grid.sell_levels = 0;
      g_grid.last_sell_price = 0.0;
      g_grid.base_sell_lot = 0.0;
     }
  }
//+------------------------------------------------------------------+
//| Pattern helpers                                                   |
//+------------------------------------------------------------------+
int PatternIndexFromConditions(const bool cond_ma,const bool cond_rsi,const bool cond_mfi,const bool cond_vol)
  {
   int index = 0;
   if(cond_ma)
      index |= 1;
   if(cond_rsi)
      index |= 2;
   if(cond_mfi)
      index |= 4;
   if(cond_vol)
      index |= 8;
   return(index);
  }
//+------------------------------------------------------------------+
void EvaluatePatternProbability(const bool cond_ma,const bool cond_rsi,const bool cond_mfi,const bool cond_vol,
                                const ENUM_POSITION_TYPE direction,int &pattern_index,double &probability,
                                double &avg_profit,double &avg_loss)
  {
   pattern_index = PatternIndexFromConditions(cond_ma, cond_rsi, cond_mfi, cond_vol);
   int dir_index = (direction==POSITION_TYPE_SELL ? 1 : 0);
   SPatternModel model = g_patternModel[dir_index][pattern_index];
   probability = model.probability;
   avg_profit  = model.average_win;
   avg_loss    = model.average_loss;
   if(probability<=0.0)
      probability = 0.5;
  }
//+------------------------------------------------------------------+
bool PredictTradeOutcome(const SSignalDecision &decision,const double base_lot,double &adjusted_lot)
  {
   double probability = decision.estimated_probability;
   if(probability<=0.0)
      probability = 0.5;

   if(probability>=InpProbabilityThreshold)
     {
      adjusted_lot = base_lot;
      return(true);
     }

   double min_threshold = MathMax(0.05, InpProbabilityThreshold * InpConfidenceFloor);
   if(probability<=min_threshold)
     {
      LogEvent(StringFormat("Trade skipped due to low probability %.2f", probability));
      return(false);
     }

  double scale = probability / InpProbabilityThreshold;
  scale = MathMax(InpConfidenceFloor, MathMin(1.0, scale));
  double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
  double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
  adjusted_lot = MathMax(base_lot * scale, min_lot);
  if(lot_step>0.0)
     adjusted_lot = MathFloor(adjusted_lot/lot_step)*lot_step;
  adjusted_lot = MathMax(adjusted_lot, min_lot);
  LogEvent(StringFormat("Lot adjusted by probability %.2f -> scale %.2f", probability, scale));
  return(true);
 }
//+------------------------------------------------------------------+
double AdaptiveGridSpacing(const double atr_points)
  {
   double base = MathMax(InpGridStepPoints, atr_points * 1.2);
   double loss_ratio = (g_stats.window_trades>0) ? (double)g_stats.window_losses / (double)g_stats.window_trades : 0.0;
   double profit_bias = (g_stats.window_trades>0) ? g_stats.window_profit / MathMax(1.0, (double)g_stats.window_trades) : 0.0;
   double volatility_factor = MathMax(0.5, MathMin(2.5, atr_points / MathMax(1.0, InpGridStepPoints)));
   double scale = 1.0 + loss_ratio * 0.75;
   if(profit_bias>0.0)
      scale = MathMax(0.6, scale - 0.2);
   double adaptive = base * scale * volatility_factor;
   adaptive = MathMax(InpGridStepPoints*0.5, MathMin(InpGridStepPoints*4.0, adaptive));
   return(adaptive);
  }
//+------------------------------------------------------------------+
void PushPendingPattern(const SPatternCandidate &candidate)
  {
   int size = ArraySize(g_pendingPatterns);
   ArrayResize(g_pendingPatterns, size+1);
   g_pendingPatterns[size] = candidate;
  }
//+------------------------------------------------------------------+
bool PopPendingPattern(const ENUM_POSITION_TYPE direction,SPatternCandidate &candidate)
  {
   int size = ArraySize(g_pendingPatterns);
   for(int i=0;i<size;i++)
     {
      if(g_pendingPatterns[i].direction==direction)
        {
         candidate = g_pendingPatterns[i];
         for(int j=i;j<size-1;j++)
            g_pendingPatterns[j] = g_pendingPatterns[j+1];
         ArrayResize(g_pendingPatterns, size-1);
         return(true);
        }
     }
   return(false);
  }
//+------------------------------------------------------------------+
void RegisterActiveTrade(const ulong position_id,const int pattern_index,const ENUM_POSITION_TYPE direction,
                         const double probability)
  {
   if(position_id==0)
      return;
   int size = ArraySize(g_activeTrades);
   ArrayResize(g_activeTrades,size+1);
   g_activeTrades[size].position_id = position_id;
   g_activeTrades[size].pattern_index = pattern_index;
   g_activeTrades[size].direction = direction;
   g_activeTrades[size].probability = probability;
  }
//+------------------------------------------------------------------+
bool ExtractActiveTrade(const ulong position_id,int &pattern_index,ENUM_POSITION_TYPE &direction,double &probability)
  {
   int size = ArraySize(g_activeTrades);
   for(int i=0;i<size;i++)
     {
      if(g_activeTrades[i].position_id==position_id)
        {
         pattern_index = g_activeTrades[i].pattern_index;
         direction     = g_activeTrades[i].direction;
         probability   = g_activeTrades[i].probability;
         RemoveActiveTradeByIndex(i);
         return(true);
        }
     }
   return(false);
  }
//+------------------------------------------------------------------+
void RemoveActiveTradeByIndex(const int index)
  {
   int size = ArraySize(g_activeTrades);
   if(index<0 || index>=size)
      return;
   for(int i=index;i<size-1;i++)
      g_activeTrades[i] = g_activeTrades[i+1];
   ArrayResize(g_activeTrades,size-1);
  }
//+------------------------------------------------------------------+
void RecordTradePattern(const ENUM_POSITION_TYPE direction,const int pattern_index,const double probability,const double profit)
  {
   if(pattern_index<0 || pattern_index>=PATTERN_COMBINATIONS)
      return;
   int dir_index = (direction==POSITION_TYPE_SELL ? 1 : 0);
   SPatternStats &stats = g_patternStats[dir_index][pattern_index];
   stats.trades++;
   stats.sum_profit += profit;
   if(profit>=0.0)
     {
      stats.wins++;
      stats.sum_win_profit += profit;
     }
   else
     {
      stats.sum_loss_profit += profit;
     }

  UpdateProbabilityModel(dir_index, pattern_index);

  SaveLearningData();

  if(InpVerboseLogging)
     {
      double win_rate = (stats.trades>0) ? (double)stats.wins/(double)stats.trades : 0.0;
      double avg_win = (stats.wins>0) ? stats.sum_win_profit/(double)stats.wins : 0.0;
      double avg_loss = ((stats.trades-stats.wins)>0) ? stats.sum_loss_profit/(double)(stats.trades-stats.wins) : 0.0;
      LogEvent(StringFormat("Pattern %d dir %d updated: trades=%d winRate=%.2f avgWin=%.2f avgLoss=%.2f probUsed=%.2f",
                            pattern_index, dir_index, stats.trades, win_rate, avg_win, avg_loss, probability));
     }
  }
//+------------------------------------------------------------------+
void UpdateProbabilityModel()
  {
   for(int dir=0; dir<2; ++dir)
     {
      for(int pattern=0; pattern<PATTERN_COMBINATIONS; ++pattern)
         UpdateProbabilityModel(dir, pattern);
     }
  }
//+------------------------------------------------------------------+
void UpdateProbabilityModel(const int dir_index, const int pattern_index)
  {
   const SPatternStats &stats = g_patternStats[dir_index][pattern_index];
   SPatternModel &model = g_patternModel[dir_index][pattern_index];
   if(stats.trades==0)
     {
      model.probability = 0.0;
      model.average_win = 0.0;
      model.average_loss = 0.0;
      return;
     }
   ulong losses = stats.trades - stats.wins;
   model.probability = (double)stats.wins / (double)stats.trades;
   model.average_win = (stats.wins>0) ? stats.sum_win_profit / (double)stats.wins : 0.0;
   model.average_loss = (losses>0) ? stats.sum_loss_profit / (double)losses : 0.0;
  }

//+------------------------------------------------------------------+
void LoadState()
  {
   int handle = FileOpen(g_stateFileName, FILE_READ|FILE_CSV|FILE_COMMON);
   if(handle==INVALID_HANDLE)
      return;

   if(!FileIsEnding(handle))
    {
     g_params.fast_period       = (int)FileReadNumber(handle);
     g_params.slow_period       = (int)FileReadNumber(handle);
     g_params.rsi_period        = (int)FileReadNumber(handle);
     g_params.rsi_overbought    = FileReadNumber(handle);
     g_params.rsi_oversold      = FileReadNumber(handle);
     g_params.mfi_period        = (int)FileReadNumber(handle);
     g_params.mfi_overbought    = FileReadNumber(handle);
     g_params.mfi_oversold      = FileReadNumber(handle);
     g_params.volume_period     = (int)FileReadNumber(handle);
     g_params.volume_multiplier = FileReadNumber(handle);
     g_stats.total_trades       = (ulong)FileReadNumber(handle);
     g_stats.window_trades      = (ulong)FileReadNumber(handle);
     g_stats.window_wins        = (ulong)FileReadNumber(handle);
     g_stats.window_losses      = (ulong)FileReadNumber(handle);
     g_stats.total_profit       = FileReadNumber(handle);
     g_stats.window_profit      = FileReadNumber(handle);
    }
   g_params.fast_period   = MathMax(2, g_params.fast_period);
   g_params.slow_period   = MathMax(g_params.fast_period+2, g_params.slow_period);
   g_params.rsi_period    = MathMax(3, g_params.rsi_period);
   g_params.mfi_period    = MathMax(3, g_params.mfi_period);
   g_params.volume_period = MathMax(5, MathMin(MAX_VOLUME_BUFFER, g_params.volume_period));
   g_params.volume_multiplier = MathMax(0.5, MathMin(3.0, g_params.volume_multiplier));
   FileClose(handle);
  }
//+------------------------------------------------------------------+
void SaveState()
  {
   int handle = FileOpen(g_stateFileName, FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(handle==INVALID_HANDLE)
      return;

   FileWrite(handle,
             g_params.fast_period,
             g_params.slow_period,
             g_params.rsi_period,
             g_params.rsi_overbought,
             g_params.rsi_oversold,
             g_params.mfi_period,
             g_params.mfi_overbought,
             g_params.mfi_oversold,
             g_params.volume_period,
             g_params.volume_multiplier,
             g_stats.total_trades,
             g_stats.window_trades,
             g_stats.window_wins,
             g_stats.window_losses,
             g_stats.total_profit,
             g_stats.window_profit);
   FileClose(handle);
  }
//+------------------------------------------------------------------+
void ResetWindowStats()
  {
   g_stats.window_trades = 0;
   g_stats.window_wins   = 0;
   g_stats.window_losses = 0;
   g_stats.window_profit = 0.0;
   SaveState();
  }
//+------------------------------------------------------------------+
void SelfTuneParameters()
  {
   double trade_count = (double)g_stats.window_trades;
   double wins        = (double)g_stats.window_wins;
   double losses      = (double)g_stats.window_losses;
   double win_rate    = (wins+losses>0) ? wins/(wins+losses) : 0.5;
   double avg_profit  = (wins+losses>0) ? g_stats.window_profit/(wins+losses) : 0.0;

   double adjust_step = (avg_profit>=0.0 ? -1.0 : 1.0);

   if(win_rate>0.55)
     {
      if(InpAllowParamDecrease)
        {
         g_params.fast_period = MathMax(3, g_params.fast_period + (int)adjust_step);
         g_params.slow_period = MathMax(g_params.fast_period+2, g_params.slow_period + (int)adjust_step);
        }
      g_params.rsi_overbought = MathMin(90.0, g_params.rsi_overbought + 1.0);
      g_params.rsi_oversold   = MathMax(10.0, g_params.rsi_oversold - 1.0);
      g_params.mfi_overbought = MathMin(90.0, g_params.mfi_overbought + 1.0);
      g_params.mfi_oversold   = MathMax(10.0, g_params.mfi_oversold - 1.0);
      g_params.volume_multiplier = MathMax(0.5, g_params.volume_multiplier - 0.05);
     }
   else if(win_rate<0.45)
     {
      g_params.fast_period = MathMin(120, g_params.fast_period + 1);
      g_params.slow_period = MathMin(240, MathMax(g_params.fast_period+2, g_params.slow_period + 2));
      g_params.rsi_overbought = MathMax(55.0, g_params.rsi_overbought - 1.0);
      g_params.rsi_oversold   = MathMin(45.0, g_params.rsi_oversold + 1.0);
      g_params.mfi_overbought = MathMax(55.0, g_params.mfi_overbought - 1.0);
      g_params.mfi_oversold   = MathMin(45.0, g_params.mfi_oversold + 1.0);
      g_params.volume_multiplier = MathMin(3.0, g_params.volume_multiplier + 0.05);
     }
   else
     {
      g_params.volume_multiplier = MathMin(3.0, MathMax(0.5, g_params.volume_multiplier + (avg_profit>=0.0?-0.02:0.02)));
     }

   g_params.volume_period = MathMax(5, MathMin(MAX_VOLUME_BUFFER, g_params.volume_period + (avg_profit>=0.0?-1:1)));

   if(g_params.rsi_overbought - g_params.rsi_oversold < 5.0)
     {
      double mid = (g_params.rsi_overbought + g_params.rsi_oversold)/2.0;
      g_params.rsi_overbought = MathMin(90.0, mid + 2.5);
      g_params.rsi_oversold   = MathMax(10.0, mid - 2.5);
     }

   if(g_params.mfi_overbought - g_params.mfi_oversold < 5.0)
     {
      double mid = (g_params.mfi_overbought + g_params.mfi_oversold)/2.0;
      g_params.mfi_overbought = MathMin(90.0, mid + 2.5);
      g_params.mfi_oversold   = MathMax(10.0, mid - 2.5);
     }

   string report = StringFormat("Self-tune executed: trades=%d, winRate=%.2f, avgProfit=%.2f, fastMA=%d, slowMA=%d, RSI(%.1f/%.1f), MFI(%.1f/%.1f), VolMult=%.2f",
                                (int)trade_count, win_rate, avg_profit, g_params.fast_period, g_params.slow_period,
                                g_params.rsi_oversold, g_params.rsi_overbought,
                                g_params.mfi_oversold, g_params.mfi_overbought,
                                g_params.volume_multiplier);
   LogEvent(report);
   SaveState();
   RecreateIndicators();
  }
//+------------------------------------------------------------------+
void RecreateIndicators()
  {
   CreateIndicatorHandles();
  }
//+------------------------------------------------------------------+
void LoadLearningData()
  {
   for(int dir=0; dir<2; ++dir)
     {
      for(int pattern=0; pattern<PATTERN_COMBINATIONS; ++pattern)
        {
         g_patternStats[dir][pattern].trades = 0;
         g_patternStats[dir][pattern].wins = 0;
         g_patternStats[dir][pattern].sum_profit = 0.0;
         g_patternStats[dir][pattern].sum_win_profit = 0.0;
         g_patternStats[dir][pattern].sum_loss_profit = 0.0;
        }
     }
   int handle = FileOpen(g_learningFileName, FILE_READ|FILE_CSV|FILE_COMMON);
   if(handle==INVALID_HANDLE)
     {
      UpdateProbabilityModel();
      return;
     }

   while(!FileIsEnding(handle))
     {
      int dir = (int)FileReadNumber(handle);
      int pattern = (int)FileReadNumber(handle);
      ulong trades = (ulong)FileReadNumber(handle);
      ulong wins = (ulong)FileReadNumber(handle);
      double sum_profit = FileReadNumber(handle);
      double sum_win = FileReadNumber(handle);
      double sum_loss = FileReadNumber(handle);
      if(dir<0 || dir>1 || pattern<0 || pattern>=PATTERN_COMBINATIONS)
         continue;
      g_patternStats[dir][pattern].trades = trades;
      g_patternStats[dir][pattern].wins = wins;
      g_patternStats[dir][pattern].sum_profit = sum_profit;
      g_patternStats[dir][pattern].sum_win_profit = sum_win;
      g_patternStats[dir][pattern].sum_loss_profit = sum_loss;
     }
   FileClose(handle);
   UpdateProbabilityModel();
  }
//+------------------------------------------------------------------+
void SaveLearningData()
  {
   int handle = FileOpen(g_learningFileName, FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(handle==INVALID_HANDLE)
      return;

   for(int dir=0; dir<2; ++dir)
     {
      for(int pattern=0; pattern<PATTERN_COMBINATIONS; ++pattern)
        {
         const SPatternStats &stats = g_patternStats[dir][pattern];
         FileWrite(handle, dir, pattern, stats.trades, stats.wins, stats.sum_profit, stats.sum_win_profit, stats.sum_loss_profit);
        }
     }
   FileClose(handle);
  }
//+------------------------------------------------------------------+
void LogEvent(const string message)
  {
   datetime ts = TimeCurrent();
   string line = StringFormat("%s,EVENT,%s", TimeToString(ts, TIME_DATE|TIME_SECONDS), message);
   int handle = FileOpen(g_logFileName, FILE_WRITE|FILE_READ|FILE_ANSI|FILE_COMMON);
   if(handle==INVALID_HANDLE)
      return;
   FileSeek(handle, 0, SEEK_END);
   FileWriteString(handle, line+"\n");
   FileClose(handle);
  }
//+------------------------------------------------------------------+
void LogIndicatorSnapshot()
  {
   string detail = StringFormat("Indicators fastMA=%.5f slowMA=%.5f RSI=%.2f MFI=%.2f Volume=%.0f ATR=%.1f",
                               g_fastMABuffer[0], g_slowMABuffer[0], g_rsiBuffer[0], g_mfiBuffer[0], g_volBuffer[0], g_atrBuffer[0]);
   LogEvent(detail);
  }
//+------------------------------------------------------------------+
void LogTrade(const ulong deal_ticket, const double deal_profit, const string direction)
  {
   string line = StringFormat("%s,TRADE,%I64u,%s,%.2f", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), deal_ticket, direction, deal_profit);
   int handle = FileOpen(g_logFileName, FILE_WRITE|FILE_READ|FILE_ANSI|FILE_COMMON);
   if(handle==INVALID_HANDLE)
      return;
   FileSeek(handle,0,SEEK_END);
   FileWriteString(handle, line+"\n");
   FileClose(handle);
  }
//+------------------------------------------------------------------+
