//+------------------------------------------------------------------+
//|                                                SelfTune-EA_v3.5.mq5 | // [v3.5 Update] Self-learning, cluster TP, and regression integration
//|                                                     SelfTune Labs |
//|                Probability enhanced adaptive grid Expert Advisor |
//+------------------------------------------------------------------+
#property copyright "SelfTune Labs"
#property link      "https://github.com/SelfTune"
#property version   "3.50" // [v3.5 Update] Self-learning, cluster TP, and regression integration
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

const int     MAX_VOLUME_BUFFER      = 512;
const int     MAX_LEARNING_RECORDS   = 700;
const int     MIN_LEARNING_ACTIVATION= 100;
const int     RECENT_METRIC_WINDOW   = 50;

enum ENUM_PATTERN_CONSTANTS
  {
   PATTERN_BIT_COUNT    = 4,
   PATTERN_COMBINATIONS = 1 << PATTERN_BIT_COUNT
  };

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
input double            InpInitialLot      = 0.0;            // Optional fixed baseline lot (0 = risk based)
input double            InpMaxDrawdown     = 20.0;           // Max equity drawdown before halt (%)
input double            InpDailyLoss       = 5.0;            // Max daily loss before halt (%)
input double            InpATRMultiplierTP = 4.5;            // ATR multiplier for take profit
input int               InpATRPeriod       = 14;             // ATR period

sinput string sepTP="--- TakeProfit Settings ---"; // [v3.5 Update] Self-learning, cluster TP, and regression integration
input int               VirtualTPPoints     = 80;            // [v3.5 Update] Self-learning, cluster TP, and regression integration
input int               ReduceTPPerOrder    = 14;            // [v3.5 Update] Self-learning, cluster TP, and regression integration
input bool              AllowOverlapRecovery = true;         // [v3.5 Update] Self-learning, cluster TP, and regression integration
input int               OverlapAfterOrders  = 3;             // [v3.5 Update] Self-learning, cluster TP, and regression integration

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
   ulong    total_wins;
   ulong    total_losses;
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
   double               fast_ma;
   double               slow_ma;
   double               rsi;
   double               mfi;
   double               volume;
   double               volume_ratio;      // [v3.4] Learning-based probability system and adaptive entry
   double               atr_points;
   int                  grid_level;
   double               lot_size;
   int                  pattern_mask;
   datetime             open_time;      // [v3.1] track trade start for duration metrics
   double               equity_before;  // [v3.1] equity snapshot at entry
   double               equity_peak;    // [v3.1] rolling peak equity during trade
   double               equity_trough;  // [v3.1] rolling trough equity during trade
   bool                 is_grid;        // [v3.1] flag grid originated trades
   string               signal_pattern_id; // [v3.4] Learning-based probability system and adaptive entry
   double               win_probability;   // [v3.4] Learning-based probability system and adaptive entry
   double               confidence_score;  // [v3.4] Learning-based probability system and adaptive entry
  };

struct SPatternCandidate
  {
   ENUM_POSITION_TYPE direction;
   int                pattern_index;
   double             probability;
   double             fast_ma;
   double             slow_ma;
   double             rsi;
   double             mfi;
   double             volume;
   double             volume_ratio;     // [v3.4] Learning-based probability system and adaptive entry
   double             atr_points;
   int                grid_level;
   int                confirmations;
   double             lot_size;
   int                pattern_mask;
   datetime           open_time;      // [v3.1] capture order submission time
   double             equity_before;  // [v3.1] equity when order sent
   double             equity_peak;    // [v3.1] rolling equity peak seed
   double             equity_trough;  // [v3.1] rolling equity trough seed
   bool               is_grid;        // [v3.1] differentiate grid trades
   string             signal_pattern_id; // [v3.4] Learning-based probability system and adaptive entry
   double             win_probability;   // [v3.4] Learning-based probability system and adaptive entry
   double             confidence_score;  // [v3.4] Learning-based probability system and adaptive entry
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
   double              regression_probability; // [v3.4] Learning-based probability system and adaptive entry
   double              confidence_score;       // [v3.4] Learning-based probability system and adaptive entry
   string              signal_pattern_id;      // [v3.4] Learning-based probability system and adaptive entry
   double              volume_ratio;           // [v3.4] Learning-based probability system and adaptive entry
   double              ma_strength;            // [v3.4] Learning-based probability system and adaptive entry
   double              fast_ma;
   double              slow_ma;
   double              rsi;
   double              mfi;
   double              volume;
   double              volume_avg;             // [v3.4] Learning-based probability system and adaptive entry
   double              atr_points;
   int                 confirmations_required;
   int                 pattern_mask;
  };

struct STakeProfitState
  {
   double   base_virtual_points;     // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double   base_reduction_points;   // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double   dynamic_virtual_points;  // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double   dynamic_reduction_points;// [v3.5 Update] Self-learning, cluster TP, and regression integration
   int      overlap_threshold;       // [v3.5 Update] Self-learning, cluster TP, and regression integration
   bool     overlap_enabled;         // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double   last_win_rate;           // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double   probability_multiplier;  // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double   last_probability;        // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double   last_cluster_target;     // [v3.5 Update] Self-learning, cluster TP, and regression integration
  };

struct SLearningRecord
  {
   // snapshot written to SelfTuneEA_learning.csv for the rolling learning system
   ulong     trade_id;
   string    symbol;
   datetime  time;
   double    fast_ma;
   double    slow_ma;
   double    rsi;
   double    mfi;
   double    volume;
   double    profit;
   string    win_loss;
   int       grid_level;
   double    atr_points;
   string    signal_type;
   int       result;
   int       pattern_index;
   double    equity_before;  // [v3.1] equity snapshot before trade
   double    equity_after;   // [v3.1] equity snapshot after trade
   double    duration_sec;   // [v3.1] holding duration in seconds
   double    drawdown_pct;   // [v3.1] drawdown experienced during trade
   string    trade_type;     // [v3.1] classification for AI analysis
   string    signal_pattern_id; // [v3.4] Learning-based probability system and adaptive entry
   double    win_probability;   // [v3.4] Learning-based probability system and adaptive entry
   double    confidence_score;  // [v3.4] Learning-based probability system and adaptive entry
  };

struct SRegressionModel
  {
   double intercept;        // [v3.4] Learning-based probability system and adaptive entry
   double coeff_rsi;        // [v3.4] Learning-based probability system and adaptive entry
   double coeff_mfi;        // [v3.4] Learning-based probability system and adaptive entry
   double coeff_ma;         // [v3.4] Learning-based probability system and adaptive entry
   double coeff_volume;     // [v3.4] Learning-based probability system and adaptive entry
   int    last_update_trades; // [v3.4] Learning-based probability system and adaptive entry
   bool   initialized;      // [v3.4] Learning-based probability system and adaptive entry
   double error_variance;   // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double dynamic_confidence; // [v3.5 Update] Self-learning, cluster TP, and regression integration
   int    sample_size;      // [v3.5 Update] Self-learning, cluster TP, and regression integration
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
SLearningRecord     g_learningRecords[];
STakeProfitState    g_takeProfitState; // [v3.5 Update] Self-learning, cluster TP, and regression integration
SRegressionModel    g_regressionModel = {0.0,0.0,0.0,0.0,0.0,0,false,0.0,0.0,0}; // [v3.5 Update] Self-learning, cluster TP, and regression integration
double              g_lastDecisionProbability = 0.5; // [v3.4] Learning-based probability system and adaptive entry
double              g_lastDecisionConfidence  = 0.0; // [v3.4] Learning-based probability system and adaptive entry
int                 g_learningCount = 0;
int                 g_learningHead  = 0;        // [v3.1] circular buffer head index
int                 g_sinceLastTune = 0;        // [v3.1] trades since last tuning cycle
double              g_lastTuneWinRate = 0.0;    // [v3.1] snapshot win rate per tuning cycle
bool                g_hasTuneBaseline = false;  // [v3.1] guard for deviation-trigger logic
double              g_recentRSI[];
double              g_recentVolume[];
bool                g_initComplete = false;     // [v3.1] block tuning during initialization

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
void        InitializeFiles();
bool        CreateIndicatorHandles();
void        ReleaseIndicatorHandles();
bool        RefreshIndicators();
bool        IsNewBar();
void        EvaluateSignals(bool &buy_signal, bool &sell_signal, double &atr_points);
void        ExecuteSignal(const bool buy_signal, const bool sell_signal, const double atr_points);
double      CalculateLotSize(const double risk_points); // [v3.3] Adaptive TakeProfit based on learning data
bool        RiskChecks();
void        ManagePositions(const double atr_points);
void        ManageGrid(const double atr_points);
void        ResetGridStateIfNeeded();
void        InitializeAdaptiveTakeProfit(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
void        UpdateAdaptiveTakeProfitState(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
double      DetermineAdaptiveTakeProfitPoints(const int recovery_level,const double probability_hint); // [v3.5 Update] Self-learning, cluster TP, and regression integration
void        ManageCluster(const ENUM_POSITION_TYPE direction,const double atr_points); // [v3.5 Update] Self-learning, cluster TP, and regression integration
double      ComputeClusterTarget(const int order_count,const double base_points,const double probability,const double confidence,const double atr_points,double &pre_adjust_target,bool &logged); // [v3.5 Update] Self-learning, cluster TP, and regression integration
double      ApplyProbabilityTargetAdjustment(const double base_target,const double probability,const double confidence,bool &logged); // [v3.5 Update] Self-learning, cluster TP, and regression integration
double      ComputeWindowWinRate(const int window); // [v3.3] Adaptive TakeProfit based on learning data
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
int         EvaluatePatternProbability(const bool cond_ma,const bool cond_rsi,const bool cond_mfi,const bool cond_vol,
                                       const ENUM_POSITION_TYPE direction,double &probability,double &avg_profit,
                                       double &avg_loss);
bool        PredictTradeOutcome(const SSignalDecision &decision,const double base_lot,double &adjusted_lot);
double      AdaptiveGridSpacing(const double atr_points);
void        PushPendingPattern(const SPatternCandidate &candidate);
bool        PopPendingPattern(const ENUM_POSITION_TYPE direction,SPatternCandidate &candidate);
void        RegisterActiveTrade(const ulong position_id,const SPatternCandidate &candidate);
bool        ExtractActiveTrade(const ulong position_id,SActiveTradeContext &context);
void        RemoveActiveTradeByIndex(const int index);
void        RecordTradePattern(const SActiveTradeContext &context,const double profit,const ulong deal_ticket,const datetime deal_time);
void        AppendLearningRecord(const SLearningRecord &record);
void        TrimLearningBuffer();
void        RecalculateRecentMetrics();
double      ComputeRSIDeviation();
double      ComputeVolumeDeviation();
double      RecentWinRate();
void        StoreLearningRecord(const SLearningRecord &record,const bool persist);
void        EnsureLearningCapacity();
int         LearningBufferIndex(const int ordinal);
bool        GetLearningRecord(const int ordinal,SLearningRecord &record);
void        UpdateActiveTradeExtents();
string      CsvQuote(const string value);
string      CsvUnquote(const string value);
double      RecentAverageProfit(const int window);
double      SafeCsvToDouble(const string field,bool &malformed);
void        InitializeRegressionModel(); // [v3.4] Learning-based probability system and adaptive entry
double      RegressionPredictProbability(const double rsi,const double mfi,const double fast_ma,const double slow_ma,const double volume_ratio); // [v3.4] Learning-based probability system and adaptive entry
double      RegressionPredictProbability(const SLearningRecord &record); // [v3.4] Learning-based probability system and adaptive entry
bool        UpdateRegressionModelIfNeeded(); // [v3.4] Learning-based probability system and adaptive entry
void        RefreshLearningProbabilities(); // [v3.4] Learning-based probability system and adaptive entry
double      ComputePatternConfidence(const ENUM_POSITION_TYPE direction,const int pattern_index); // [v3.4] Learning-based probability system and adaptive entry
double      ComputeBlendedProbability(const ENUM_POSITION_TYPE direction,const int pattern_index,const double regression_prob); // [v3.4] Learning-based probability system and adaptive entry
string      BuildSignalPatternID(const ENUM_POSITION_TYPE direction,const int pattern_mask); // [v3.4] Learning-based probability system and adaptive entry
bool        ConfirmPatternForEntry(SSignalDecision &decision,const ENUM_POSITION_TYPE direction); // [v3.4] Learning-based probability system and adaptive entry
bool        QueryPatternFromLearning(const string pattern_id,double &win_probability,double &confidence); // [v3.4] Learning-based probability system and adaptive entry
bool        FindActiveTradeContext(const ulong position_id,SActiveTradeContext &context); // [v3.4] Learning-based probability system and adaptive entry

double SafeCsvToDouble(const string field,bool &malformed)
  {
   if(malformed)
      return(0.0);

   string field_unquoted = CsvUnquote(field);
   double value = 0.0;

   if(StringLen(field_unquoted)>0)
     {
      ResetLastError();
      value = StringToDouble(field_unquoted);
      if(GetLastError()!=0)
        {
         malformed = true;
         return(0.0);
        }
     }

   if(!MathIsValidNumber(value))
     {
      malformed = true;
      return(0.0);
     }

   return(value);
  }


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
   InitializeAdaptiveTakeProfit(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   InitializeFiles();
   InitializeRegressionModel(); // [v3.4] Learning-based probability system and adaptive entry
   LoadState();
   LoadLearningData();
   UpdateAdaptiveTakeProfitState(); // [v3.3] Adaptive TakeProfit based on learning data
   UpdateProbabilityModel();
   RefreshLearningProbabilities(); // [v3.4] Learning-based probability system and adaptive entry

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

   LogEvent("EA initialized");
   g_initComplete = true; // [v3.1] enable post-init learning cycles
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

   UpdateActiveTradeExtents(); // [v3.1] refresh equity peaks/troughs for open trades

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
   datetime deal_time         = TimeCurrent();

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
      long hist_time = HistoryDealGetInteger(trans.deal, DEAL_TIME);
      if(hist_time>0)
         deal_time = (datetime)hist_time;
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
            RegisterActiveTrade(position_id, candidate);
        }
     }

   if(entry_is_out)
     {
      bool closing_buy = (deal_type==DEAL_TYPE_SELL);
      ENUM_POSITION_TYPE original_direction = closing_buy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      string direction = closing_buy ? "CLOSE_BUY" : "CLOSE_SELL";
      if(profit>=0)
        {
         g_stats.window_wins++;
         g_stats.total_wins++;
        }
      else
        {
         g_stats.window_losses++;
         g_stats.total_losses++;
        }
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
      SActiveTradeContext context;
      context.direction = original_direction;
      if(position_id>0 && ExtractActiveTrade(position_id, context))
        {
         RecordTradePattern(context, profit, trans.deal, deal_time);
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

   ResetGridStateIfNeeded();
   bool regression_updated = UpdateRegressionModelIfNeeded(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(regression_updated) // [v3.5 Update] Self-learning, cluster TP, and regression integration
     {
      RefreshLearningProbabilities(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      SaveLearningData(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      UpdateAdaptiveTakeProfitState(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
     }
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
void InitializeAdaptiveTakeProfit() // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   g_takeProfitState.base_virtual_points      = MathMax(10.0, (double)VirtualTPPoints);   // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_takeProfitState.base_reduction_points    = MathMax(0.0, (double)ReduceTPPerOrder);   // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_takeProfitState.dynamic_virtual_points   = g_takeProfitState.base_virtual_points;    // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_takeProfitState.dynamic_reduction_points = g_takeProfitState.base_reduction_points;  // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_takeProfitState.overlap_threshold        = MathMax(1, OverlapAfterOrders);           // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_takeProfitState.overlap_enabled          = AllowOverlapRecovery;                     // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_takeProfitState.last_win_rate            = 0.5;                                       // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_takeProfitState.probability_multiplier   = 1.0;                                       // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_takeProfitState.last_probability         = 0.5;                                       // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_takeProfitState.last_cluster_target      = g_takeProfitState.base_virtual_points;     // [v3.5 Update] Self-learning, cluster TP, and regression integration
  }
//+------------------------------------------------------------------+
void InitializeFiles()
  {
   bool is_tester = (MQLInfoInteger(MQL_TESTER)==1);

   if(is_tester)
     {
      FileDelete(g_logFileName);
      FileDelete(g_stateFileName);
      FileDelete(g_learningFileName);
     }

   int handle = FileOpen(g_logFileName, FILE_READ|FILE_CSV|FILE_ANSI);
   bool need_log_header = (handle==INVALID_HANDLE || FileSize(handle)==0);
   if(handle!=INVALID_HANDLE)
      FileClose(handle);
   if(need_log_header)
     {
      handle = FileOpen(g_logFileName, FILE_WRITE|FILE_CSV|FILE_ANSI);
      if(handle!=INVALID_HANDLE)
        {
         FileWrite(handle, "timestamp","event","message");
         FileClose(handle);
        }
    }

   handle = FileOpen(g_stateFileName, FILE_READ|FILE_CSV|FILE_ANSI);
   bool need_state_header = (handle==INVALID_HANDLE || FileSize(handle)==0);
   if(handle!=INVALID_HANDLE)
      FileClose(handle);
   if(need_state_header)
     {
      handle = FileOpen(g_stateFileName, FILE_WRITE|FILE_CSV|FILE_ANSI);
      if(handle!=INVALID_HANDLE)
        {
         FileWrite(handle,
                   "FastMA","SlowMA","RSIPeriod","RSI_Overbought","RSI_Oversold",
                   "MFIPeriod","MFI_Overbought","MFI_Oversold",
                   "VolumePeriod","VolumeMultiplier",
                   "TotalTrades","TotalWins","TotalLosses","TotalProfit");
         FileClose(handle);
        }
     }

   handle = FileOpen(g_learningFileName, FILE_READ|FILE_CSV|FILE_ANSI);
   bool need_learning_header = (handle==INVALID_HANDLE || FileSize(handle)==0);
   if(handle!=INVALID_HANDLE)
      FileClose(handle);
   if(need_learning_header)
     {
      handle = FileOpen(g_learningFileName, FILE_WRITE|FILE_CSV|FILE_ANSI);
      if(handle!=INVALID_HANDLE)
        {
         // [v3.1] expanded header with equity/duration analytics for AI ingestion
         FileWrite(handle,
                   "TradeID","Symbol","Time","FastMA","SlowMA","RSI","MFI","Volume",
                   "Profit","WinLoss","GridLevel","ATR","SignalType","Result",
                   "EquityBefore","EquityAfter","DurationSec","DrawdownPct","TradeType","PatternIndex",
                   "SignalPatternID","WinProbability","ConfidenceScore");
         FileClose(handle);
        }
    }
  }
//+------------------------------------------------------------------+
//| Create indicator handles                                         |
//+------------------------------------------------------------------+
bool CreateIndicatorHandles()
  {
   ReleaseIndicatorHandles(); // [v3.1] guard against duplicate handles

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
   double fast_ma_prev= (ArraySize(g_fastMABuffer)>1 ? g_fastMABuffer[1] : fast_ma_now);
   double slow_ma_prev= (ArraySize(g_slowMABuffer)>1 ? g_slowMABuffer[1] : slow_ma_now);

   double rsi_now  = g_rsiBuffer[0];
   double rsi_prev = (ArraySize(g_rsiBuffer)>1 ? g_rsiBuffer[1] : rsi_now);
   double mfi_now  = g_mfiBuffer[0];
   double mfi_prev = (ArraySize(g_mfiBuffer)>1 ? g_mfiBuffer[1] : mfi_now);

   double volume_now  = g_volBuffer[0];
   double volume_prev = (ArraySize(g_volBuffer)>1 ? g_volBuffer[1] : volume_now);
   double volume_avg = 0.0;
   int count = MathMin(g_params.volume_period,ArraySize(g_volBuffer));
   for(int i=0;i<count;i++)
      volume_avg += g_volBuffer[i];
   if(count>0)
      volume_avg /= count;

   double volume_ratio_now = 1.0; // [v3.4] Learning-based probability system and adaptive entry
   if(volume_avg>0.0)
      volume_ratio_now = volume_now / MathMax(1.0, volume_avg); // [v3.4] Learning-based probability system and adaptive entry
   volume_ratio_now = MathMax(0.1, MathMin(10.0, volume_ratio_now)); // [v3.4] Learning-based probability system and adaptive entry

   double ma_strength_now = 0.0; // [v3.4] Learning-based probability system and adaptive entry
   double ma_den = MathMax(_Point, MathAbs(slow_ma_now)); // [v3.4] Learning-based probability system and adaptive entry
   if(ma_den>0.0)
      ma_strength_now = (fast_ma_now - slow_ma_now) / ma_den; // [v3.4] Learning-based probability system and adaptive entry
   ma_strength_now = MathMax(-5.0, MathMin(5.0, ma_strength_now)); // [v3.4] clamp for regression stability

   bool ma_bullish = (fast_ma_now>slow_ma_now) || (fast_ma_now>=slow_ma_now && fast_ma_prev>slow_ma_prev);
   bool ma_bearish = (fast_ma_now<slow_ma_now) || (fast_ma_now<=slow_ma_now && fast_ma_prev<slow_ma_prev);

   bool rsi_rising = (rsi_now>rsi_prev);
   bool mfi_rising = (mfi_now>mfi_prev);

   bool rsi_bullish = (rsi_now<=g_params.rsi_oversold) || (rsi_rising && rsi_now<g_params.rsi_overbought);
   bool rsi_bearish = (rsi_now>=g_params.rsi_overbought) || (!rsi_rising && rsi_now>g_params.rsi_oversold);

   bool mfi_bullish = (mfi_now<=g_params.mfi_oversold) || (mfi_rising && mfi_now<g_params.mfi_overbought);
   bool mfi_bearish = (mfi_now>=g_params.mfi_overbought) || (!mfi_rising && mfi_now>g_params.mfi_oversold);

   bool volume_confirm = false;
   if(volume_avg>0.0)
      volume_confirm = (volume_now >= volume_avg * g_params.volume_multiplier) ||
                       ((volume_now>volume_avg) && (volume_now>=volume_prev));
   else
      volume_confirm = (volume_now>=volume_prev && volume_now>0.0);

  ArrayInitialize(g_buyDecision.conditions,false);
  g_buyDecision.conditions[0] = ma_bullish;
  g_buyDecision.conditions[1] = rsi_bullish;
  g_buyDecision.conditions[2] = mfi_bullish;
  g_buyDecision.conditions[3] = volume_confirm;
  g_buyDecision.confirmed = 0;
  g_buyDecision.fast_ma = fast_ma_now;
  g_buyDecision.slow_ma = slow_ma_now;
  g_buyDecision.rsi     = rsi_now;
  g_buyDecision.mfi     = mfi_now;
  g_buyDecision.volume  = volume_now;
  g_buyDecision.volume_avg = volume_avg;            // [v3.4] Learning-based probability system and adaptive entry
  g_buyDecision.volume_ratio = volume_ratio_now;    // [v3.4] Learning-based probability system and adaptive entry
  g_buyDecision.ma_strength  = ma_strength_now;     // [v3.4] Learning-based probability system and adaptive entry
  g_buyDecision.atr_points = atr_points;
  g_buyDecision.confirmations_required = 3;
  for(int bi=0; bi<PATTERN_BIT_COUNT; ++bi)
     if(g_buyDecision.conditions[bi])
        g_buyDecision.confirmed++;

  g_buyDecision.pattern_index = EvaluatePatternProbability(g_buyDecision.conditions[0], g_buyDecision.conditions[1], g_buyDecision.conditions[2], g_buyDecision.conditions[3],
                                                           POSITION_TYPE_BUY, g_buyDecision.estimated_probability,
                                                           g_buyDecision.avg_win, g_buyDecision.avg_loss);
  g_buyDecision.pattern_mask = g_buyDecision.pattern_index;
  g_buyDecision.signal_pattern_id = BuildSignalPatternID(POSITION_TYPE_BUY, g_buyDecision.pattern_index); // [v3.4] Learning-based probability system and adaptive entry
  g_buyDecision.regression_probability = RegressionPredictProbability(g_buyDecision.rsi, g_buyDecision.mfi, g_buyDecision.fast_ma, g_buyDecision.slow_ma, g_buyDecision.volume_ratio); // [v3.4]
  g_buyDecision.confidence_score = ComputePatternConfidence(POSITION_TYPE_BUY, g_buyDecision.pattern_index); // [v3.4]
  g_buyDecision.estimated_probability = ComputeBlendedProbability(POSITION_TYPE_BUY, g_buyDecision.pattern_index, g_buyDecision.regression_probability); // [v3.4]
  buy_signal = (g_buyDecision.confirmed>=3);
  g_buyDecision.signal = buy_signal;

  ArrayInitialize(g_sellDecision.conditions,false);
  g_sellDecision.conditions[0] = ma_bearish;
  g_sellDecision.conditions[1] = rsi_bearish;
  g_sellDecision.conditions[2] = mfi_bearish;
  g_sellDecision.conditions[3] = volume_confirm;
  g_sellDecision.confirmed = 0;
  g_sellDecision.fast_ma = fast_ma_now;
  g_sellDecision.slow_ma = slow_ma_now;
  g_sellDecision.rsi     = rsi_now;
  g_sellDecision.mfi     = mfi_now;
  g_sellDecision.volume  = volume_now;
  g_sellDecision.volume_avg = volume_avg;           // [v3.4] Learning-based probability system and adaptive entry
  g_sellDecision.volume_ratio = volume_ratio_now;   // [v3.4] Learning-based probability system and adaptive entry
  g_sellDecision.ma_strength  = -ma_strength_now;   // [v3.4] mirror strength for sell context
  g_sellDecision.atr_points = atr_points;
  g_sellDecision.confirmations_required = 3;
  for(int si=0; si<PATTERN_BIT_COUNT; ++si)
     if(g_sellDecision.conditions[si])
        g_sellDecision.confirmed++;

  g_sellDecision.pattern_index = EvaluatePatternProbability(g_sellDecision.conditions[0], g_sellDecision.conditions[1], g_sellDecision.conditions[2], g_sellDecision.conditions[3],
                                                            POSITION_TYPE_SELL, g_sellDecision.estimated_probability,
                                                            g_sellDecision.avg_win, g_sellDecision.avg_loss);
  g_sellDecision.pattern_mask = g_sellDecision.pattern_index;
  g_sellDecision.signal_pattern_id = BuildSignalPatternID(POSITION_TYPE_SELL, g_sellDecision.pattern_index); // [v3.4] Learning-based probability system and adaptive entry
  g_sellDecision.regression_probability = RegressionPredictProbability(g_sellDecision.rsi, g_sellDecision.mfi, g_sellDecision.fast_ma, g_sellDecision.slow_ma, g_sellDecision.volume_ratio); // [v3.4]
  g_sellDecision.confidence_score = ComputePatternConfidence(POSITION_TYPE_SELL, g_sellDecision.pattern_index); // [v3.4]
  g_sellDecision.estimated_probability = ComputeBlendedProbability(POSITION_TYPE_SELL, g_sellDecision.pattern_index, g_sellDecision.regression_probability); // [v3.4]
  sell_signal = (g_sellDecision.confirmed>=3);
  g_sellDecision.signal = sell_signal;

  g_lastDecisionProbability = MathMax(g_buyDecision.estimated_probability, g_sellDecision.estimated_probability); // [v3.4]
  g_lastDecisionConfidence  = MathMax(g_buyDecision.confidence_score, g_sellDecision.confidence_score);          // [v3.4]
  }
//+------------------------------------------------------------------+
//| Execute trade signals with probability control                    |
//+------------------------------------------------------------------+
void ExecuteSignal(const bool buy_signal, const bool sell_signal, const double atr_points)
  {
   if(!buy_signal && !sell_signal)
      return;

   double probability_hint = g_lastDecisionProbability; // [v3.4] Learning-based probability system and adaptive entry
   double take_profit_points = DetermineAdaptiveTakeProfitPoints(0, probability_hint); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double atr_floor = atr_points * InpATRMultiplierTP; // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double risk_points = MathMax(take_profit_points, MathMax(atr_floor, 10.0)); // [v3.5 Update] Self-learning, cluster TP, and regression integration

   double base_lot = CalculateLotSize(risk_points); // [v3.3] Adaptive TakeProfit based on learning data
   if(base_lot<=0.0)
      return;

   double buy_lot = base_lot;
   double sell_lot = base_lot;
   bool buy_allowed = (buy_signal && ConfirmPatternForEntry(g_buyDecision, POSITION_TYPE_BUY));  // [v3.4] Learning-based probability system and adaptive entry
   bool sell_allowed = (sell_signal && ConfirmPatternForEntry(g_sellDecision, POSITION_TYPE_SELL)); // [v3.4] Learning-based probability system and adaptive entry

  if(buy_allowed)
     buy_allowed = PredictTradeOutcome(g_buyDecision, base_lot, buy_lot);
  if(sell_allowed)
     sell_allowed = PredictTradeOutcome(g_sellDecision, base_lot, sell_lot);

   bool trade_result = false;

   if(buy_allowed && (!sell_allowed || PositionSelect(_Symbol)==false || PositionGetInteger(POSITION_TYPE)!=POSITION_TYPE_SELL))
     {
      trade_result = g_trade.Buy(buy_lot, _Symbol, 0.0, 0.0, 0.0, "SelfTune BUY"); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      if(trade_result)
        {
         SPatternCandidate candidate;
         candidate.direction      = POSITION_TYPE_BUY;
         candidate.pattern_index  = g_buyDecision.pattern_index;
         candidate.probability    = g_buyDecision.estimated_probability;
         candidate.fast_ma        = g_buyDecision.fast_ma;
         candidate.slow_ma        = g_buyDecision.slow_ma;
         candidate.rsi            = g_buyDecision.rsi;
         candidate.mfi            = g_buyDecision.mfi;
         candidate.volume         = g_buyDecision.volume;
         candidate.volume_ratio   = g_buyDecision.volume_ratio; // [v3.4] Learning-based probability system and adaptive entry
         candidate.atr_points     = g_buyDecision.atr_points;      // [v3.5 Update] Self-learning, cluster TP, and regression integration
         candidate.grid_level     = g_grid.buy_levels + 1;
         candidate.confirmations  = g_buyDecision.confirmed;
         candidate.lot_size       = buy_lot;
         candidate.pattern_mask   = g_buyDecision.pattern_mask;
         candidate.open_time      = TimeCurrent();         // [v3.1] seed trade lifecycle metrics
         candidate.equity_before  = AccountInfoDouble(ACCOUNT_EQUITY); // [v3.1] equity snapshot pre-trade
         candidate.equity_peak    = candidate.equity_before;
         candidate.equity_trough  = candidate.equity_before;
         candidate.is_grid        = false;
         candidate.signal_pattern_id = g_buyDecision.signal_pattern_id; // [v3.4] Learning-based probability system and adaptive entry
         candidate.win_probability   = g_buyDecision.estimated_probability; // [v3.4] Learning-based probability system and adaptive entry
         candidate.confidence_score  = g_buyDecision.confidence_score; // [v3.4] Learning-based probability system and adaptive entry
         PushPendingPattern(candidate);
        }
     }
   else if(sell_allowed && (!buy_allowed || PositionSelect(_Symbol)==false || PositionGetInteger(POSITION_TYPE)!=POSITION_TYPE_BUY))
     {
      trade_result = g_trade.Sell(sell_lot, _Symbol, 0.0, 0.0, 0.0, "SelfTune SELL"); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      if(trade_result)
        {
         SPatternCandidate candidate;
         candidate.direction      = POSITION_TYPE_SELL;
         candidate.pattern_index  = g_sellDecision.pattern_index;
         candidate.probability    = g_sellDecision.estimated_probability;
         candidate.fast_ma        = g_sellDecision.fast_ma;
         candidate.slow_ma        = g_sellDecision.slow_ma;
         candidate.rsi            = g_sellDecision.rsi;
         candidate.mfi            = g_sellDecision.mfi;
         candidate.volume         = g_sellDecision.volume;
         candidate.volume_ratio   = g_sellDecision.volume_ratio; // [v3.4] Learning-based probability system and adaptive entry
         candidate.atr_points     = g_sellDecision.atr_points;     // [v3.5 Update] Self-learning, cluster TP, and regression integration
         candidate.grid_level     = g_grid.sell_levels + 1;
         candidate.confirmations  = g_sellDecision.confirmed;
         candidate.lot_size       = sell_lot;
         candidate.pattern_mask   = g_sellDecision.pattern_mask;
         candidate.open_time      = TimeCurrent();         // [v3.1] seed trade lifecycle metrics
         candidate.equity_before  = AccountInfoDouble(ACCOUNT_EQUITY);
         candidate.equity_peak    = candidate.equity_before;
         candidate.equity_trough  = candidate.equity_before;
         candidate.is_grid        = false;
         candidate.signal_pattern_id = g_sellDecision.signal_pattern_id; // [v3.4] Learning-based probability system and adaptive entry
         candidate.win_probability   = g_sellDecision.estimated_probability; // [v3.4] Learning-based probability system and adaptive entry
         candidate.confidence_score  = g_sellDecision.confidence_score; // [v3.4] Learning-based probability system and adaptive entry
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
double CalculateLotSize(const double risk_points) // [v3.3] Adaptive TakeProfit based on learning data
  {
   double lot_step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_lot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   int    volume_digits = 0;

   if(min_lot<=0.0)
     {
      if(lot_step>0.0)
         min_lot = lot_step;
      else
         min_lot = 0.01;
     }
   if(max_lot<=0.0)
      max_lot = min_lot * 100.0;
   if(volume_digits<0)
      volume_digits = 0;
   if(volume_digits==0 && lot_step>0.0)
     {
      double step = lot_step;
      while(step<1.0 && volume_digits<8)
        {
         step*=10.0;
         volume_digits++;
        }
     }
   if(volume_digits==0 && lot_step<=0.0)
      volume_digits = 2;

   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amount = equity * InpRiskPerTrade / 100.0;
   double tick_value  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double point_value = 0.0;
   if(tick_value>0.0 && tick_size>0.0)
      point_value = tick_value / tick_size;

   double risk_lot = 0.0;
   if(risk_points>0.0 && point_value>0.0)
      risk_lot = risk_amount / (risk_points * _Point * point_value); // [v3.3] Adaptive TakeProfit based on learning data

   if(lot_step>0.0 && risk_lot>0.0)
      risk_lot = MathFloor(risk_lot/lot_step) * lot_step;

   double lot = risk_lot;
   if(lot<=0.0 || !MathIsValidNumber(lot))
      lot = min_lot;

   lot = MathMax(min_lot, MathMin(max_lot, lot));
   lot = NormalizeDouble(lot, volume_digits);

   bool initial_override_used = false;
   if(InpInitialLot>0.0)
     {
      double override_lot = InpInitialLot;
      if(lot_step>0.0)
         override_lot = MathFloor(override_lot/lot_step + 0.5) * lot_step;
      override_lot = MathMax(min_lot, MathMin(max_lot, override_lot));
      override_lot = NormalizeDouble(override_lot, volume_digits);
      if(InpVerboseLogging && risk_lot>0.0 && override_lot>risk_lot)
         LogEvent(StringFormat("Initial lot %.2f exceeds risk-based %.2f; override applied", override_lot, risk_lot));

      if(risk_lot<=0.0 || override_lot>lot)
        {
         lot = override_lot;
         initial_override_used = true;
        }
     }

   lot = MathMax(min_lot, MathMin(max_lot, lot));
   lot = NormalizeDouble(lot, volume_digits);

   if(InpVerboseLogging && initial_override_used)
      LogEvent(StringFormat("Initial lot override applied (%.2f lots)", lot));

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
//| Manage open positions and adaptive TP                             |
//+------------------------------------------------------------------+
void ManagePositions(const double atr_points) // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   ManageCluster(POSITION_TYPE_BUY, atr_points);  // [v3.5 Update] Self-learning, cluster TP, and regression integration
   ManageCluster(POSITION_TYPE_SELL, atr_points); // [v3.5 Update] Self-learning, cluster TP, and regression integration
  }
//+------------------------------------------------------------------+
//| Cluster-based virtual take-profit handler                         |
//+------------------------------------------------------------------+
void ManageCluster(const ENUM_POSITION_TYPE direction,const double atr_points) // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   int total_positions = PositionsTotal(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(total_positions<=0)
      return; // [v3.5 Update] Self-learning, cluster TP, and regression integration

   double total_volume = 0.0;
   double weighted_price = 0.0;
   double probability_sum = 0.0;
   double confidence_sum = 0.0;
   double profit_sum = 0.0;
   int    order_count = 0;
   ulong  cluster_tickets[];
   ArrayResize(cluster_tickets, 0);

   for(int i=0;i<total_positions;i++)
     {
      if(!PositionSelectByIndex(i))
         continue;
      string pos_symbol = PositionGetString(POSITION_SYMBOL);
      if(pos_symbol!=_Symbol)
         continue;
      ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(pos_type!=direction)
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      if(volume<=0.0)
         continue;

      total_volume += volume;
      weighted_price += open_price * volume;
      profit_sum += PositionGetDouble(POSITION_PROFIT);

      ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      ArrayResize(cluster_tickets, order_count+1);
      cluster_tickets[order_count] = ticket;
      order_count++;

      SActiveTradeContext context;
      if(ticket>0 && FindActiveTradeContext(ticket, context))
        {
         double ctx_prob = (context.win_probability>0.0 ? context.win_probability : context.probability);
         double ctx_conf = (context.confidence_score>0.0 ? context.confidence_score : g_lastDecisionConfidence);
         probability_sum += ctx_prob;
         confidence_sum += ctx_conf;
        }
     }

   if(order_count<=0 || total_volume<=0.0)
      return;

   double avg_price = weighted_price / MathMax(total_volume, 0.0000001);
   double market_price = (direction==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double avg_profit_points = (direction==POSITION_TYPE_BUY) ? (market_price - avg_price) / _Point
                                                             : (avg_price - market_price) / _Point;

   double cluster_probability = (probability_sum>0.0 ? probability_sum / (double)order_count : g_lastDecisionProbability);
   double cluster_confidence  = (confidence_sum>0.0 ? confidence_sum / (double)order_count : g_lastDecisionConfidence);
   cluster_probability = MathMax(0.05, MathMin(0.95, cluster_probability));
   cluster_confidence  = MathMax(0.0, MathMin(1.0, cluster_confidence));

   double base_points = DetermineAdaptiveTakeProfitPoints(order_count-1, cluster_probability); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double previous_target = g_takeProfitState.last_cluster_target;    // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double pre_adjust_target = 0.0;                                    // [v3.5 Update] Self-learning, cluster TP, and regression integration
   bool adjustment_logged = false;                                   // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double final_target = ComputeClusterTarget(order_count, base_points, cluster_probability, cluster_confidence, atr_points, pre_adjust_target, adjustment_logged); // [v3.5 Update]

   g_takeProfitState.last_probability = cluster_probability;         // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(adjustment_logged && (previous_target<=0.0 || MathAbs(final_target - previous_target)>0.5))
      LogEvent(StringFormat("Adaptive TP adjusted: base=%.1f, probability=%.2f, finalTP=%.1f", pre_adjust_target, cluster_probability, final_target)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_takeProfitState.last_cluster_target = final_target;             // [v3.5 Update] Self-learning, cluster TP, and regression integration

   if(avg_profit_points>=final_target)
     {
      string dir_label = (direction==POSITION_TYPE_BUY ? "BUY" : "SELL");
      for(int t=0;t<order_count;t++)
        {
         ulong ticket = cluster_tickets[t];
         if(ticket>0)
           {
            if(!g_trade.PositionClose(ticket))
               LogEvent(StringFormat("Cluster close retry required: %s ticket=%I64u", dir_label, ticket)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
           }
        }
      LogEvent(StringFormat("Cluster TP hit: %s orders=%d avgPoints=%.1f target=%.1f profit=%.2f", dir_label, order_count, avg_profit_points, final_target, profit_sum)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
     }
  }
//+------------------------------------------------------------------+
double ComputeClusterTarget(const int order_count,const double base_points,const double probability,const double confidence,const double atr_points,double &pre_adjust_target,bool &logged) // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   double adjusted = base_points;
   if(order_count>0)
     {
      int effective_orders = order_count;
      if(!g_takeProfitState.overlap_enabled && effective_orders>g_takeProfitState.overlap_threshold)
         effective_orders = g_takeProfitState.overlap_threshold;
      int reduction_index = MathMax(0, effective_orders-1);
      adjusted -= g_takeProfitState.dynamic_reduction_points * reduction_index;
     }

   adjusted = MathMax(5.0, adjusted);
   if(atr_points>0.0)
      adjusted = MathMax(adjusted, atr_points*0.25);

   pre_adjust_target = adjusted;
   bool adjustment_flag = false;
   double final_target = ApplyProbabilityTargetAdjustment(adjusted, probability, confidence, adjustment_flag);
   logged = adjustment_flag;
   return(MathMax(5.0, final_target));
  }
//+------------------------------------------------------------------+
double ApplyProbabilityTargetAdjustment(const double base_target,const double probability,const double confidence,bool &logged) // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   double prob = MathMax(0.05, MathMin(0.95, probability));
   double conf = MathMax(0.0, MathMin(1.0, confidence));
   double adjustment = 1.0;

   if(prob<0.55)
     {
      double deficit = 0.55 - prob;
      double intensity = MathMin(1.0, deficit / 0.20);
      adjustment -= 0.30 * intensity;
     }
   else if(prob>0.75)
     {
      double surplus = prob - 0.75;
      double intensity = MathMin(1.0, surplus / 0.20);
      adjustment += 0.20 * intensity;
     }

   adjustment *= (0.9 + 0.2 * conf);
   double final_target = MathMax(5.0, base_target * adjustment);

   logged = (MathAbs(adjustment-1.0)>0.001);

   return(final_target);
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
         double tp_points = DetermineAdaptiveTakeProfitPoints(MathMax(0, g_grid.buy_levels), g_buyDecision.estimated_probability); // [v3.4] Learning-based probability system and adaptive entry
         if(atr_points>0.0) // [v3.3] Adaptive TakeProfit based on learning data
            tp_points = MathMax(tp_points, atr_points*0.5); // [v3.3] Adaptive TakeProfit based on learning data
         if(g_trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "Grid BUY")) // [v3.5 Update] Self-learning, cluster TP, and regression integration
              {
               LogEvent(StringFormat("Grid BUY level %d opened (step=%.1f)", g_grid.buy_levels+1, dynamic_step_points));
               SPatternCandidate candidate = {POSITION_TYPE_BUY, g_buyDecision.pattern_index, g_buyDecision.estimated_probability};
               candidate.fast_ma       = g_buyDecision.fast_ma;      // [v3.4] Learning-based probability system and adaptive entry
               candidate.slow_ma       = g_buyDecision.slow_ma;      // [v3.4] Learning-based probability system and adaptive entry
               candidate.rsi           = g_buyDecision.rsi;          // [v3.4] Learning-based probability system and adaptive entry
               candidate.mfi           = g_buyDecision.mfi;          // [v3.4] Learning-based probability system and adaptive entry
               candidate.volume        = g_buyDecision.volume;       // [v3.4] Learning-based probability system and adaptive entry
               candidate.volume_ratio  = g_buyDecision.volume_ratio; // [v3.4] Learning-based probability system and adaptive entry
               candidate.atr_points    = g_buyDecision.atr_points;   // [v3.4] Learning-based probability system and adaptive entry
               candidate.open_time      = TimeCurrent();      // [v3.1] log timing for grid trades
               candidate.equity_before  = AccountInfoDouble(ACCOUNT_EQUITY);
               candidate.equity_peak    = candidate.equity_before;
               candidate.equity_trough  = candidate.equity_before;
               candidate.is_grid        = true;
               candidate.signal_pattern_id = g_buyDecision.signal_pattern_id; // [v3.4] Learning-based probability system and adaptive entry
               candidate.win_probability   = g_buyDecision.estimated_probability; // [v3.4] Learning-based probability system and adaptive entry
               candidate.confidence_score  = g_buyDecision.confidence_score; // [v3.4] Learning-based probability system and adaptive entry
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
         double tp_points = DetermineAdaptiveTakeProfitPoints(MathMax(0, g_grid.sell_levels), g_sellDecision.estimated_probability); // [v3.4] Learning-based probability system and adaptive entry
         if(atr_points>0.0) // [v3.3] Adaptive TakeProfit based on learning data
            tp_points = MathMax(tp_points, atr_points*0.5); // [v3.3] Adaptive TakeProfit based on learning data
         if(g_trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, "Grid SELL")) // [v3.5 Update] Self-learning, cluster TP, and regression integration
              {
               LogEvent(StringFormat("Grid SELL level %d opened (step=%.1f)", g_grid.sell_levels+1, dynamic_step_points));
               SPatternCandidate candidate = {POSITION_TYPE_SELL, g_sellDecision.pattern_index, g_sellDecision.estimated_probability};
               candidate.fast_ma       = g_sellDecision.fast_ma;      // [v3.4] Learning-based probability system and adaptive entry
               candidate.slow_ma       = g_sellDecision.slow_ma;      // [v3.4] Learning-based probability system and adaptive entry
               candidate.rsi           = g_sellDecision.rsi;          // [v3.4] Learning-based probability system and adaptive entry
               candidate.mfi           = g_sellDecision.mfi;          // [v3.4] Learning-based probability system and adaptive entry
               candidate.volume        = g_sellDecision.volume;       // [v3.4] Learning-based probability system and adaptive entry
               candidate.volume_ratio  = g_sellDecision.volume_ratio; // [v3.4] Learning-based probability system and adaptive entry
               candidate.atr_points    = g_sellDecision.atr_points;   // [v3.4] Learning-based probability system and adaptive entry
               candidate.open_time      = TimeCurrent();
               candidate.equity_before  = AccountInfoDouble(ACCOUNT_EQUITY);
               candidate.equity_peak    = candidate.equity_before;
               candidate.equity_trough  = candidate.equity_before;
               candidate.is_grid        = true;
               candidate.signal_pattern_id = g_sellDecision.signal_pattern_id; // [v3.4] Learning-based probability system and adaptive entry
               candidate.win_probability   = g_sellDecision.estimated_probability; // [v3.4] Learning-based probability system and adaptive entry
               candidate.confidence_score  = g_sellDecision.confidence_score; // [v3.4] Learning-based probability system and adaptive entry
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
int EvaluatePatternProbability(const bool cond_ma,const bool cond_rsi,const bool cond_mfi,const bool cond_vol,
                               const ENUM_POSITION_TYPE direction,double &probability,double &avg_profit,
                               double &avg_loss)
  {
   //--- map the current signal conditions into a bit-pattern and query the rolling probability model
   int pattern_index = PatternIndexFromConditions(cond_ma, cond_rsi, cond_mfi, cond_vol);
   int dir_index = (direction==POSITION_TYPE_SELL ? 1 : 0);
   SPatternModel model = g_patternModel[dir_index][pattern_index];
   double prob = model.probability;
   double win_avg = model.average_win;
   double loss_avg = model.average_loss;
   if(g_learningCount<MIN_LEARNING_ACTIVATION && prob<0.5)
      prob = 0.5;
   if(prob<=0.0)
      prob = 0.5;
   probability = prob;
   avg_profit = win_avg;
   avg_loss = loss_avg;
   return(pattern_index); // [v3.1] expose pattern index while avoiding reference-based outputs
  }
//+------------------------------------------------------------------+
bool PredictTradeOutcome(const SSignalDecision &decision,const double base_lot,double &adjusted_lot)
  {
   //--- enforce the 3-of-4 confirmation rule before looking at probabilities
   if(decision.confirmations_required>0 && decision.confirmed<decision.confirmations_required)
     {
      LogEvent("Trade skipped: insufficient indicator confirmations");
      return(false);
     }
   double probability = decision.estimated_probability;
   if(g_learningCount<MIN_LEARNING_ACTIVATION)
      probability = MathMax(probability, 0.5);
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
   double lot_value = MathMax(base_lot * scale, min_lot);
   if(lot_step>0.0)
      lot_value = MathFloor(lot_value/lot_step)*lot_step;
   lot_value = MathMax(lot_value, min_lot);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot_value>max_lot)
      lot_value = max_lot;
   adjusted_lot = lot_value;
   LogEvent(StringFormat("Lot adjusted by probability %.2f -> scale %.2f", probability, scale));
   return(true);
  }
//+------------------------------------------------------------------+
double AdaptiveGridSpacing(const double atr_points)
  {
   //--- mix volatility, indicator dispersion, and recent performance to size the grid dynamically
   double baseline = MathMax(InpGridStepPoints, atr_points * 1.1);
   double atr_factor = MathMax(0.8, MathMin(2.5, atr_points / MathMax(1.0, InpGridStepPoints)));
   double rsi_dev = ComputeRSIDeviation();
   double volume_dev = ComputeVolumeDeviation();
   double win_rate = RecentWinRate();

   double performance_factor = 1.0;
   if(win_rate<0.5)
      performance_factor += (0.5 - win_rate) * 1.2;
   else
      performance_factor -= (win_rate - 0.5) * 0.8;
   performance_factor = MathMax(0.6, MathMin(1.6, performance_factor));

   double volatility_factor = 1.0 + atr_factor*0.25 + rsi_dev*0.3 + volume_dev*0.2;
   double adaptive = baseline * performance_factor * volatility_factor;
   adaptive = MathMax(InpGridStepPoints*0.5, MathMin(InpGridStepPoints*4.5, adaptive));
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
void RegisterActiveTrade(const ulong position_id,const SPatternCandidate &candidate)
  {
   if(position_id==0)
      return;
   int size = ArraySize(g_activeTrades);
   ArrayResize(g_activeTrades,size+1);
   g_activeTrades[size].position_id  = position_id;
   g_activeTrades[size].pattern_index= candidate.pattern_index;
   g_activeTrades[size].direction    = candidate.direction;
   g_activeTrades[size].probability  = candidate.probability;
   g_activeTrades[size].fast_ma      = candidate.fast_ma;
   g_activeTrades[size].slow_ma      = candidate.slow_ma;
   g_activeTrades[size].rsi          = candidate.rsi;
   g_activeTrades[size].mfi          = candidate.mfi;
   g_activeTrades[size].volume       = candidate.volume;
   g_activeTrades[size].volume_ratio = candidate.volume_ratio;      // [v3.4] Learning-based probability system and adaptive entry
   g_activeTrades[size].atr_points   = candidate.atr_points;
   g_activeTrades[size].grid_level   = candidate.grid_level;
   g_activeTrades[size].lot_size     = candidate.lot_size;
   g_activeTrades[size].pattern_mask = candidate.pattern_mask;
   g_activeTrades[size].open_time    = (candidate.open_time>0 ? candidate.open_time : TimeCurrent());         // [v3.1]
   g_activeTrades[size].equity_before= (candidate.equity_before>0.0 ? candidate.equity_before : AccountInfoDouble(ACCOUNT_EQUITY));
   g_activeTrades[size].equity_peak  = (candidate.equity_peak>0.0 ? candidate.equity_peak : g_activeTrades[size].equity_before);
   g_activeTrades[size].equity_trough= (candidate.equity_trough>0.0 ? candidate.equity_trough : g_activeTrades[size].equity_before);
   g_activeTrades[size].is_grid      = candidate.is_grid;
   g_activeTrades[size].signal_pattern_id = candidate.signal_pattern_id; // [v3.4] Learning-based probability system and adaptive entry
   g_activeTrades[size].win_probability   = candidate.win_probability;   // [v3.4] Learning-based probability system and adaptive entry
   g_activeTrades[size].confidence_score  = candidate.confidence_score;  // [v3.4] Learning-based probability system and adaptive entry
  }
//+------------------------------------------------------------------+
bool ExtractActiveTrade(const ulong position_id,SActiveTradeContext &context)
  {
   int size = ArraySize(g_activeTrades);
   for(int i=0;i<size;i++)
     {
      if(g_activeTrades[i].position_id==position_id)
        {
         context = g_activeTrades[i];
         RemoveActiveTradeByIndex(i);
         return(true);
        }
     }
   return(false);
  }
//+------------------------------------------------------------------+
bool FindActiveTradeContext(const ulong position_id,SActiveTradeContext &context)
  {
   int size = ArraySize(g_activeTrades);
   for(int i=0;i<size;i++)
     {
      if(g_activeTrades[i].position_id==position_id)
        {
         context = g_activeTrades[i];
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
void RecordTradePattern(const SActiveTradeContext &context,const double profit,const ulong deal_ticket,const datetime deal_time)
  {
   if(context.pattern_index<0 || context.pattern_index>=PATTERN_COMBINATIONS)
      return;

   SLearningRecord record;
   record.trade_id      = deal_ticket;
   record.symbol        = _Symbol;
   record.time          = deal_time;
   record.fast_ma       = context.fast_ma;
   record.slow_ma       = context.slow_ma;
   record.rsi           = context.rsi;
   record.mfi           = context.mfi;
   record.volume        = (context.volume_ratio>0.0 ? context.volume_ratio : context.volume); // [v3.4] Learning-based probability system and adaptive entry
   record.profit        = profit;
   record.win_loss      = (profit>=0.0 ? "Win" : "Loss");
   record.grid_level    = context.grid_level;
   record.atr_points    = context.atr_points;
   record.signal_type   = (context.direction==POSITION_TYPE_SELL ? "Sell" : "Buy");
   record.result        = (profit>=0.0 ? 1 : 0);
   record.pattern_index = context.pattern_index;
   record.equity_before = context.equity_before; // [v3.1] persist entry equity snapshot

   double equity_after  = AccountInfoDouble(ACCOUNT_EQUITY);
   double equity_peak   = MathMax(context.equity_peak, context.equity_before);
   double equity_floor  = MathMin(context.equity_trough, context.equity_before);
   if(equity_floor<=0.0)
      equity_floor = context.equity_before;
   double drawdown_pct  = 0.0;
   if(equity_peak>0.0)
      drawdown_pct = MathMax(0.0, (equity_peak - MathMin(equity_after, equity_floor)) / equity_peak * 100.0);

   record.equity_after  = equity_after;               // [v3.1] capture exit equity
   record.duration_sec  = (double)MathMax(0, (int)(deal_time - context.open_time)); // [v3.1]
   record.drawdown_pct  = drawdown_pct;              // [v3.1] store peak-to-valley drawdown
   record.trade_type    = (context.is_grid ? "Grid" : "Primary"); // [v3.1]
   record.signal_pattern_id = context.signal_pattern_id; // [v3.4] Learning-based probability system and adaptive entry
   record.win_probability   = (context.win_probability>0.0 ? context.win_probability : context.probability); // [v3.4] Learning-based probability system and adaptive entry
   record.confidence_score  = context.confidence_score;  // [v3.4] Learning-based probability system and adaptive entry

   AppendLearningRecord(record);

   if(InpVerboseLogging)
     {
      LogEvent(StringFormat("Pattern %d %s recorded profit %.2f (prob=%.2f)",
                            context.pattern_index,
                            record.signal_type,
                            profit,
                            context.probability));
     }
  }
//+------------------------------------------------------------------+
void AppendLearningRecord(const SLearningRecord &record)
  {
   StoreLearningRecord(record, true); // [v3.1] funnel through FIFO storage routine
  }
//+------------------------------------------------------------------+
void StoreLearningRecord(const SLearningRecord &record,const bool persist)
  {
   EnsureLearningCapacity();
   int capacity = ArraySize(g_learningRecords);
   if(capacity<=0)
      return;

   int insert_index = 0;
   if(g_learningCount<MAX_LEARNING_RECORDS)
     {
      insert_index = (g_learningHead + g_learningCount) % capacity;
      g_learningCount++;
     }
   else
     {
      g_learningHead = (g_learningHead + 1) % capacity; // [v3.1] discard oldest record (FIFO)
      insert_index = (g_learningHead + g_learningCount - 1 + capacity) % capacity;
     }

   g_learningRecords[insert_index] = record;

   if(g_learningCount==MIN_LEARNING_ACTIVATION) // [v3.5 Update] Self-learning, cluster TP, and regression integration
      LogEvent("Learning activated at trade #100, model training started."); // [v3.5 Update] Self-learning, cluster TP, and regression integration

   TrimLearningBuffer();

  if(!persist)
     return;

  RecalculateRecentMetrics();
  UpdateProbabilityModel();
  UpdateRegressionModelIfNeeded();
  RefreshLearningProbabilities();
  SaveLearningData();
  SaveState();

   if(!g_initComplete)
      return;

   g_sinceLastTune++;
   double win_rate = RecentWinRate();
   bool deviation = (g_hasTuneBaseline && MathAbs(win_rate - g_lastTuneWinRate) > 0.05); // [v3.1] deviation trigger
   if(g_learningCount>=MIN_LEARNING_ACTIVATION && (g_sinceLastTune>=100 || deviation))
     {
      SelfTuneParameters();
      g_sinceLastTune = 0;
      g_lastTuneWinRate = win_rate;
      g_hasTuneBaseline = true;
     }
  }
//+------------------------------------------------------------------+
void TrimLearningBuffer()
  {
   if(g_learningCount<=MAX_LEARNING_RECORDS)
      return;

   int overflow = g_learningCount - MAX_LEARNING_RECORDS;
   int capacity = MathMax(1, ArraySize(g_learningRecords));
   g_learningHead = (g_learningHead + overflow) % capacity; // [v3.1] advance head for overflowed samples
   g_learningCount = MAX_LEARNING_RECORDS;
  }
//+------------------------------------------------------------------+
void EnsureLearningCapacity()
  {
   if(ArraySize(g_learningRecords)<MAX_LEARNING_RECORDS)
      ArrayResize(g_learningRecords, MAX_LEARNING_RECORDS); // [v3.1] preallocate ring buffer storage
  }
//+------------------------------------------------------------------+
int LearningBufferIndex(const int ordinal)
  {
   if(ordinal<0 || ordinal>=g_learningCount)
      return(-1);
   int capacity = ArraySize(g_learningRecords);
   if(capacity<=0)
      return(-1);
   return((g_learningHead + ordinal) % capacity); // [v3.1] translate ordinal into ring index
  }
//+------------------------------------------------------------------+
bool GetLearningRecord(const int ordinal,SLearningRecord &record)
  {
   int idx = LearningBufferIndex(ordinal);
   if(idx<0)
      return(false);
   record = g_learningRecords[idx];
   return(true);
  }
//+------------------------------------------------------------------+
void UpdateActiveTradeExtents()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   int total = ArraySize(g_activeTrades);
   for(int i=0;i<total;i++)
     {
      if(equity>g_activeTrades[i].equity_peak)
         g_activeTrades[i].equity_peak = equity;    // [v3.1] track rolling equity peak
      if(g_activeTrades[i].equity_trough==0.0 || equity<g_activeTrades[i].equity_trough)
         g_activeTrades[i].equity_trough = equity;  // [v3.1] capture trough for drawdown calc
     }
  }
//+------------------------------------------------------------------+
void RecalculateRecentMetrics()
  {
   //--- rebuild rolling window statistics for probability gating and risk checks
   int stat_window = (int)MathMin((double)MathMax(1, InpTradesPerTune), (double)g_learningCount);
   if(stat_window<=0)
     {
      g_stats.window_trades = 0;
      g_stats.window_wins   = 0;
      g_stats.window_losses = 0;
      g_stats.window_profit = 0.0;
     }
   else
     {
      g_stats.window_trades = (ulong)stat_window;
      g_stats.window_wins   = 0;
      g_stats.window_losses = 0;
      g_stats.window_profit = 0.0;
      int start_index = g_learningCount - stat_window;
      if(start_index<0)
         start_index = 0;
      for(int ordinal=start_index; ordinal<g_learningCount; ordinal++)
        {
        SLearningRecord sample; // [v3.1] pull samples through FIFO helper
        if(!GetLearningRecord(ordinal, sample))
          continue;
         g_stats.window_profit += sample.profit;
         if(sample.result>0)
            g_stats.window_wins++;
         else
            g_stats.window_losses++;
        }
     }

   int sample_window = MathMin(RECENT_METRIC_WINDOW, g_learningCount);
   ArrayResize(g_recentRSI, sample_window);
   ArrayResize(g_recentVolume, sample_window);
   for(int i=0;i<sample_window;i++)
     {
      int ordinal = g_learningCount - sample_window + i;
        SLearningRecord sample;
        if(GetLearningRecord(ordinal, sample))
          {
           g_recentRSI[i] = sample.rsi;
         g_recentVolume[i] = sample.volume;
        }
      else
        {
         g_recentRSI[i] = 0.0;
         g_recentVolume[i] = 0.0;
        }
     }
  }
//+------------------------------------------------------------------+
double ComputeRSIDeviation()
  {
   int count = ArraySize(g_recentRSI);
   if(count<=0)
      return(0.0);
   double sum_dev = 0.0;
   for(int i=0;i<count;i++)
      sum_dev += MathAbs(g_recentRSI[i] - 50.0) / 50.0;
   return(sum_dev / (double)count);
  }
//+------------------------------------------------------------------+
double ComputeVolumeDeviation()
  {
   int count = ArraySize(g_recentVolume);
   if(count<=0)
      return(0.0);
   double mean = 0.0;
   for(int i=0;i<count;i++)
      mean += g_recentVolume[i];
   mean /= (double)count;
   if(mean<=0.0)
      mean = 1.0;
   double accum = 0.0;
   for(int i=0;i<count;i++)
      accum += MathAbs(g_recentVolume[i] - mean) / mean;
   return(accum / (double)count);
  }
//+------------------------------------------------------------------+
void InitializeRegressionModel()
  {
   g_regressionModel.intercept = 0.0;            // [v3.4] Learning-based probability system and adaptive entry
   g_regressionModel.coeff_rsi = 0.0;            // [v3.4]
  g_regressionModel.coeff_mfi = 0.0;            // [v3.4]
  g_regressionModel.coeff_ma  = 0.0;            // [v3.4]
  g_regressionModel.coeff_volume = 0.0;         // [v3.4]
  g_regressionModel.last_update_trades = 0;     // [v3.4]
  g_regressionModel.initialized = true;         // [v3.4]
   g_regressionModel.error_variance = 0.0;       // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_regressionModel.dynamic_confidence = 0.0;   // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_regressionModel.sample_size = 0;            // [v3.5 Update] Self-learning, cluster TP, and regression integration
  }
//+------------------------------------------------------------------+
double RegressionPredictProbability(const double rsi,const double mfi,const double fast_ma,const double slow_ma,const double volume_ratio)
  {
   if(!g_regressionModel.initialized)
      InitializeRegressionModel();

   double feature_rsi = (rsi - 50.0) / 50.0;                  // [v3.4]
   double feature_mfi = (mfi - 50.0) / 50.0;                  // [v3.4]
   double denom = MathMax(_Point, MathAbs(slow_ma));           // [v3.4]
   double feature_ma = (denom>0.0) ? (fast_ma - slow_ma) / denom : 0.0; // [v3.4]
   feature_ma = MathMax(-5.0, MathMin(5.0, feature_ma));      // [v3.4]
   double ratio = (volume_ratio>0.0 ? volume_ratio : 1.0);    // [v3.4]
   double feature_volume = MathLog(MathMax(0.1, MathMin(10.0, ratio))); // [v3.4]

   double z = g_regressionModel.intercept
              + g_regressionModel.coeff_rsi * feature_rsi
              + g_regressionModel.coeff_mfi * feature_mfi
              + g_regressionModel.coeff_ma  * feature_ma
              + g_regressionModel.coeff_volume * feature_volume; // [v3.4]
   z = MathMax(-8.0, MathMin(8.0, z));                         // [v3.4]
   double exp_val = MathExp(-z);
   double prob = 1.0 / (1.0 + exp_val);
   return(MathMax(0.05, MathMin(0.95, prob)));                 // [v3.4]
  }
//+------------------------------------------------------------------+
double RegressionPredictProbability(const SLearningRecord &record)
  {
   return(RegressionPredictProbability(record.rsi, record.mfi, record.fast_ma, record.slow_ma, (record.volume>0.0 ? record.volume : 1.0))); // [v3.4]
  }
//+------------------------------------------------------------------+
bool UpdateRegressionModelIfNeeded()
  {
   if(g_learningCount<100)
      return(false);

   if(!g_regressionModel.initialized)
      InitializeRegressionModel();

   int trades_since_update = (int)g_stats.total_trades - g_regressionModel.last_update_trades; // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(trades_since_update < 20)
      return(false);

   double b0 = g_regressionModel.intercept;
   double b1 = g_regressionModel.coeff_rsi;
   double b2 = g_regressionModel.coeff_mfi;
   double b3 = g_regressionModel.coeff_ma;
   double b4 = g_regressionModel.coeff_volume;

   const double alpha = 0.05;
   const double lambda = 0.001;                                     // [v3.5 Update] Self-learning, cluster TP, and regression integration
   const double grad_clip = 5.0;                                     // [v3.5 Update] Self-learning, cluster TP, and regression integration
   const int iterations = 40;

   for(int iter=0; iter<iterations; ++iter)
     {
      double grad0=0.0, grad1=0.0, grad2=0.0, grad3=0.0, grad4=0.0;
      int samples = 0;
      for(int ordinal=0; ordinal<g_learningCount; ordinal++)
        {
         SLearningRecord record;
         if(!GetLearningRecord(ordinal, record))
            continue;
         double feature_rsi = (record.rsi - 50.0) / 50.0;
         double feature_mfi = (record.mfi - 50.0) / 50.0;
         double denom = MathMax(_Point, MathAbs(record.slow_ma));
         double feature_ma = (denom>0.0) ? (record.fast_ma - record.slow_ma) / denom : 0.0;
         feature_ma = MathMax(-5.0, MathMin(5.0, feature_ma));
         double ratio = (record.volume>0.0 ? record.volume : 1.0);
         double feature_volume = MathLog(MathMax(0.1, MathMin(10.0, ratio)));
         double z = b0 + b1*feature_rsi + b2*feature_mfi + b3*feature_ma + b4*feature_volume;
         z = MathMax(-8.0, MathMin(8.0, z));
         double pred = 1.0 / (1.0 + MathExp(-z));
         double target = (record.result>0 ? 1.0 : 0.0);
         double error = pred - target;
         grad0 += error;
         grad1 += error * feature_rsi;
         grad2 += error * feature_mfi;
         grad3 += error * feature_ma;
         grad4 += error * feature_volume;
         samples++;
        }

      if(samples==0)
         break;

      grad1 += lambda * b1 * samples;                                // [v3.4] Learning-based probability system and adaptive entry
      grad2 += lambda * b2 * samples;                                // [v3.4] Learning-based probability system and adaptive entry
      grad3 += lambda * b3 * samples;                                // [v3.4] Learning-based probability system and adaptive entry
      grad4 += lambda * b4 * samples;                                // [v3.4] Learning-based probability system and adaptive entry

      double grad_norm = MathSqrt(grad0*grad0 + grad1*grad1 + grad2*grad2 + grad3*grad3 + grad4*grad4);
      if(grad_norm>grad_clip && grad_norm>0.0)
        {
         double clip_scale = grad_clip / grad_norm;                  // [v3.4] Learning-based probability system and adaptive entry
         grad0 *= clip_scale;                                        // [v3.4] Learning-based probability system and adaptive entry
         grad1 *= clip_scale;                                        // [v3.4] Learning-based probability system and adaptive entry
         grad2 *= clip_scale;                                        // [v3.4] Learning-based probability system and adaptive entry
         grad3 *= clip_scale;                                        // [v3.4] Learning-based probability system and adaptive entry
         grad4 *= clip_scale;                                        // [v3.4] Learning-based probability system and adaptive entry
        }

      double scale = alpha / (double)samples;
      b0 -= grad0 * scale;
      b1 -= grad1 * scale;
      b2 -= grad2 * scale;
      b3 -= grad3 * scale;
      b4 -= grad4 * scale;
     }

   g_regressionModel.intercept = b0;
   g_regressionModel.coeff_rsi = b1;
   g_regressionModel.coeff_mfi = b2;
   g_regressionModel.coeff_ma  = b3;
   g_regressionModel.coeff_volume = b4;
   g_regressionModel.last_update_trades = (int)g_stats.total_trades; // [v3.5 Update] Self-learning, cluster TP, and regression integration
   g_regressionModel.initialized = true;

   double error_sum = 0.0;                                          // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double error_sq_sum = 0.0;                                       // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double win_profit_sum = 0.0;                                     // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double loss_profit_sum = 0.0;                                    // [v3.5 Update] Self-learning, cluster TP, and regression integration
   int win_count = 0;
   int loss_count = 0;
   int sample_count = 0;

   for(int ordinal=0; ordinal<g_learningCount; ordinal++)
     {
      SLearningRecord record;
      if(!GetLearningRecord(ordinal, record))
         continue;
      double feature_rsi = (record.rsi - 50.0) / 50.0;
      double feature_mfi = (record.mfi - 50.0) / 50.0;
      double denom = MathMax(_Point, MathAbs(record.slow_ma));
      double feature_ma = (denom>0.0) ? (record.fast_ma - record.slow_ma) / denom : 0.0;
      feature_ma = MathMax(-5.0, MathMin(5.0, feature_ma));
      double ratio = (record.volume>0.0 ? record.volume : 1.0);
      double feature_volume = MathLog(MathMax(0.1, MathMin(10.0, ratio)));
      double z = b0 + b1*feature_rsi + b2*feature_mfi + b3*feature_ma + b4*feature_volume;
      z = MathMax(-8.0, MathMin(8.0, z));
      double pred = 1.0 / (1.0 + MathExp(-z));
      double target = (record.result>0 ? 1.0 : 0.0);
      double error = pred - target;
      error_sum += error;
      error_sq_sum += error*error;
      if(record.result>0)
        {
         win_profit_sum += record.profit;
         win_count++;
        }
      else
        {
         loss_profit_sum += record.profit;
         loss_count++;
        }
      sample_count++;
     }

   double mean_error = (sample_count>0 ? error_sum/(double)sample_count : 0.0);
   double variance = (sample_count>0 ? error_sq_sum/(double)sample_count - mean_error*mean_error : 0.0);
   if(variance<0.0)
      variance = 0.0;
   double dynamic_confidence = 1.0 / (1.0 + MathSqrt(variance)*3.0);
   if(sample_count<50 && sample_count>0)
      dynamic_confidence *= (double)sample_count / 50.0;
   g_regressionModel.error_variance = variance;
   g_regressionModel.dynamic_confidence = MathMax(0.0, MathMin(1.0, dynamic_confidence));
   g_regressionModel.sample_size = sample_count;

   double avg_win = (win_count>0 ? win_profit_sum/(double)win_count : 0.0);
   double avg_loss = (loss_count>0 ? MathAbs(loss_profit_sum/(double)loss_count) : 0.0);
   double win_rate = (sample_count>0 ? (double)win_count/(double)sample_count : 0.0);

   LogEvent(StringFormat("Regression updated: winRate=%.2f, confidence=%.2f, sampleSize=%d", win_rate, g_regressionModel.dynamic_confidence, sample_count)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   LogEvent(StringFormat("Regression coefficients: b0=%.4f b_rsi=%.4f b_mfi=%.4f b_ma=%.4f b_vol=%.4f avgWin=%.2f avgLoss=%.2f", b0, b1, b2, b3, b4, avg_win, avg_loss)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   return(true);
  }
//+------------------------------------------------------------------+
void RefreshLearningProbabilities()
  {
   if(g_learningCount<=0)                                           // [v3.4] Learning-based probability system and adaptive entry
      return;                                                       // [v3.4] Learning-based probability system and adaptive entry

   for(int ordinal=0; ordinal<g_learningCount; ordinal++)
     {
      int idx = LearningBufferIndex(ordinal);
      if(idx<0)
         continue;
      SLearningRecord record = g_learningRecords[idx];
      ENUM_POSITION_TYPE direction = (StringFind(SafeToUpper(record.signal_type), "SELL")!=-1) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
      if(StringLen(record.signal_pattern_id)==0)
         record.signal_pattern_id = BuildSignalPatternID(direction, record.pattern_index);
      double regression_prob = RegressionPredictProbability(record);
      double blended = ComputeBlendedProbability(direction, record.pattern_index, regression_prob);
      double confidence = ComputePatternConfidence(direction, record.pattern_index);
      double regression_conf = g_regressionModel.dynamic_confidence; // [v3.5 Update] Self-learning, cluster TP, and regression integration
      double combined_conf = 0.6 * confidence + 0.4 * regression_conf; // [v3.5 Update] Self-learning, cluster TP, and regression integration
      if(record.confidence_score>0.0)
         combined_conf = MathMax(combined_conf, record.confidence_score);
      record.win_probability = blended;
      record.confidence_score = MathMax(0.0, MathMin(1.0, combined_conf));
      g_learningRecords[idx] = record;
     }
  }
//+------------------------------------------------------------------+
double ComputePatternConfidence(const ENUM_POSITION_TYPE direction,const int pattern_index)
  {
   int dir_index = (direction==POSITION_TYPE_SELL ? 1 : 0);
   int bounded_index = MathMax(0, MathMin(PATTERN_COMBINATIONS-1, pattern_index));
   ulong trades = g_patternStats[dir_index][bounded_index].trades;
   if(trades==0)
      return(0.0);
   double win_rate = g_patternModel[dir_index][bounded_index].probability;
   double consistency = MathMin(1.0, MathAbs(win_rate - 0.5) * 2.0);
   double sample_factor = MathMin(1.0, (double)trades / 150.0);
   double confidence = 0.6 * sample_factor + 0.4 * consistency;
   return(MathMax(0.0, MathMin(1.0, confidence)));
  }
//+------------------------------------------------------------------+
double ComputeBlendedProbability(const ENUM_POSITION_TYPE direction,const int pattern_index,const double regression_prob)
  {
   int dir_index = (direction==POSITION_TYPE_SELL ? 1 : 0);
   int bounded_index = MathMax(0, MathMin(PATTERN_COMBINATIONS-1, pattern_index));
   double historical_prob = g_patternModel[dir_index][bounded_index].probability;
   if(historical_prob<=0.0)
      historical_prob = regression_prob;
   double model_prob = (regression_prob>0.0 ? regression_prob : historical_prob);
   if(model_prob<=0.0)
      model_prob = 0.5;
   double confidence = ComputePatternConfidence(direction, bounded_index);
   double historical_weight = MathMax(0.2, MathMin(0.8, confidence));
   double blended = model_prob * (1.0 - historical_weight) + historical_prob * historical_weight;
   return(MathMax(0.05, MathMin(0.95, blended)));
  }
//+------------------------------------------------------------------+
string BuildSignalPatternID(const ENUM_POSITION_TYPE direction,const int pattern_mask)
  {
   string prefix = (direction==POSITION_TYPE_SELL ? "SELL" : "BUY");
   int masked = MathMax(0, MathMin(PATTERN_COMBINATIONS-1, pattern_mask));
   return(StringFormat("%s-%02X", prefix, masked));
  }
//+------------------------------------------------------------------+
bool QueryPatternFromLearning(const string pattern_id,double &win_probability,double &confidence)
  {
   win_probability = 0.0;
   confidence = 0.0;
   if(StringLen(pattern_id)==0)
      return(false);

   double prob_sum = 0.0;
   double conf_sum = 0.0;
   int matches = 0;
   double last_prob = 0.0;
   double last_conf = 0.0;
   int last_pattern = 0;
   ENUM_POSITION_TYPE last_direction = POSITION_TYPE_BUY;

   for(int ordinal=0; ordinal<g_learningCount; ordinal++)
     {
      SLearningRecord record;
      if(!GetLearningRecord(ordinal, record))
         continue;
      if(StringCompare(record.signal_pattern_id, pattern_id)!=0)
         continue;
      matches++;
      double rec_prob = (record.win_probability>0.0 ? record.win_probability : (record.result>0 ? 1.0 : 0.0));
      double rec_conf = (record.confidence_score>0.0 ? record.confidence_score : 0.0);
      prob_sum += rec_prob;
      conf_sum += rec_conf;
      last_prob = rec_prob;
      last_conf = rec_conf;
      last_pattern = record.pattern_index;
      last_direction = (StringFind(SafeToUpper(record.signal_type), "SELL")!=-1) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
     }

   if(matches==0)
      return(false);

   win_probability = (prob_sum>0.0 ? prob_sum/(double)matches : last_prob);
   confidence = (conf_sum>0.0 ? conf_sum/(double)matches : last_conf);
   if(confidence<=0.0)
      confidence = ComputePatternConfidence(last_direction, last_pattern);
   win_probability = MathMax(0.05, MathMin(0.95, win_probability));
   confidence = MathMax(0.0, MathMin(1.0, confidence));
   return(true);
  }
//+------------------------------------------------------------------+
bool ConfirmPatternForEntry(SSignalDecision &decision,const ENUM_POSITION_TYPE direction)
  {
   if(decision.confirmations_required>0 && decision.confirmed<decision.confirmations_required)
      return(false);

   bool partial_confirmation = (decision.confirmed==decision.confirmations_required && decision.confirmed<PATTERN_BIT_COUNT); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   bool full_confirmation = (decision.confirmed>=PATTERN_BIT_COUNT); // [v3.5 Update] Self-learning, cluster TP, and regression integration

   if(g_learningCount==0)                                           // [v3.5 Update] Self-learning, cluster TP, and regression integration
     {
      if(partial_confirmation)
        {
         LogEvent("Trade skipped: learning cache empty for partial confirmation"); // [v3.5 Update] Self-learning, cluster TP, and regression integration
         return(false);
        }
      return(true);
     }

   double stored_probability = 0.0;
   double stored_confidence = 0.0;
   bool has_history = QueryPatternFromLearning(decision.signal_pattern_id, stored_probability, stored_confidence);
   if(!has_history)
     {
      if(full_confirmation)
         return(true); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      string dir_label = (direction==POSITION_TYPE_SELL ? "SELL" : "BUY");
      LogEvent(StringFormat("Trade skipped: pattern %s (%s) not in learning cache", decision.signal_pattern_id, dir_label)); // [v3.4]
      return(false);
     }

   decision.estimated_probability = MathMax(decision.estimated_probability, stored_probability);
   decision.confidence_score = MathMax(decision.confidence_score, stored_confidence);

   if(stored_probability>=0.60 && stored_confidence>=0.50)
      return(true);

   string dir_label2 = (direction==POSITION_TYPE_SELL ? "SELL" : "BUY");
   LogEvent(StringFormat("Trade deferred: pattern %s (%s) prob=%.2f conf=%.2f", decision.signal_pattern_id, dir_label2, stored_probability, stored_confidence)); // [v3.4]
   return(false);
  }
//+------------------------------------------------------------------+
string SafeToUpper(const string value)
  {
   string tmp = value;
   StringToUpper(tmp);
   return(tmp);
  }
//+------------------------------------------------------------------+
double RecentWinRate()
  {
   if(g_stats.window_trades==0)
      return(0.5);
   return((double)g_stats.window_wins / (double)g_stats.window_trades);
  }
//+------------------------------------------------------------------+
double ComputeWindowWinRate(const int window) // [v3.3] Adaptive TakeProfit based on learning data
  {
   if(window<=0 || g_learningCount<=0)
      return(0.5); // [v3.3] Adaptive TakeProfit based on learning data
   int sample = MathMin(window, g_learningCount); // [v3.3] Adaptive TakeProfit based on learning data
   int start = g_learningCount - sample; // [v3.3] Adaptive TakeProfit based on learning data
   if(start<0)
      start = 0; // [v3.3] Adaptive TakeProfit based on learning data
   int wins = 0; // [v3.3] Adaptive TakeProfit based on learning data
   int counted = 0; // [v3.3] Adaptive TakeProfit based on learning data
   for(int ordinal=start; ordinal<g_learningCount; ordinal++)
     {
      SLearningRecord rec; // [v3.3] Adaptive TakeProfit based on learning data
      if(!GetLearningRecord(ordinal, rec))
         continue; // [v3.3] Adaptive TakeProfit based on learning data
      if(rec.result>0)
         wins++; // [v3.3] Adaptive TakeProfit based on learning data
      counted++; // [v3.3] Adaptive TakeProfit based on learning data
     }
   if(counted<=0)
      return(0.5); // [v3.3] Adaptive TakeProfit based on learning data
   return((double)wins / (double)counted); // [v3.3] Adaptive TakeProfit based on learning data
  }
//+------------------------------------------------------------------+
double RecentAverageProfit(const int window)
  {
   if(window<=0 || g_learningCount<=0)
      return(0.0);
   int sample = MathMin(window, g_learningCount);
   double total = 0.0;
   int counted = 0;
   int start = g_learningCount - sample;
   if(start<0)
      start = 0;
   for(int ordinal=start; ordinal<g_learningCount; ordinal++)
     {
        SLearningRecord rec;
        if(!GetLearningRecord(ordinal, rec))
          continue;
      total += rec.profit;
      counted++;
     }
   if(counted<=0)
      return(0.0);
   return(total / (double)counted); // [v3.1] feed adaptive learning-rate logic
  }
//+------------------------------------------------------------------+
double DetermineAdaptiveTakeProfitPoints(const int recovery_level,const double probability_hint) // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   double base_points = g_takeProfitState.dynamic_virtual_points; // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double probability = (probability_hint>0.0 ? probability_hint : g_lastDecisionProbability); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(probability>0.0)
     {
      double centered = MathMax(-0.5, MathMin(0.5, probability - 0.5));
      double probability_scale = 1.0 + centered * 0.6;
      base_points *= probability_scale;
     }
   base_points *= g_takeProfitState.probability_multiplier;
   double floor_points = MathMax(10.0, g_takeProfitState.dynamic_virtual_points * 0.4);
   if(base_points<floor_points)
      base_points = floor_points;
   return(base_points);
  }
//+------------------------------------------------------------------+
void UpdateAdaptiveTakeProfitState() // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   double win_rate = ComputeWindowWinRate(100);
   double new_virtual = g_takeProfitState.base_virtual_points;
   double new_reduction = g_takeProfitState.base_reduction_points;

   if(win_rate<0.50)
     {
      new_virtual = g_takeProfitState.base_virtual_points * 0.85;
      new_reduction = g_takeProfitState.base_reduction_points * 0.9;
     }
   else if(win_rate>0.70)
     {
      new_virtual = g_takeProfitState.base_virtual_points * 1.10;
      new_reduction = g_takeProfitState.base_reduction_points;
     }

   new_virtual = MathMax(10.0, new_virtual);
   new_reduction = MathMax(0.0, new_reduction);

   bool changed = (MathAbs(new_virtual - g_takeProfitState.dynamic_virtual_points)>0.1 ||
                   MathAbs(new_reduction - g_takeProfitState.dynamic_reduction_points)>0.1);

   g_takeProfitState.dynamic_virtual_points   = new_virtual;
   g_takeProfitState.dynamic_reduction_points = new_reduction;
   g_takeProfitState.last_win_rate            = win_rate;

   double confidence = MathMax(0.0, MathMin(1.0, g_lastDecisionConfidence));
   double probability_bias = MathMax(-0.5, MathMin(0.5, g_lastDecisionProbability - 0.5));
   double multiplier = 1.0 + probability_bias * (0.4 + 0.3 * confidence);
   g_takeProfitState.probability_multiplier = MathMax(0.6, MathMin(1.4, multiplier));

   if(changed)
     {
      LogEvent(StringFormat("Adaptive TP updated: winRate=%.2f, base=%.1f", win_rate, new_virtual)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
     }
  }
//+------------------------------------------------------------------+
void UpdateProbabilityModel()
  {
   double total_win_sum = 0.0;                                    // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double total_loss_sum = 0.0;                                   // [v3.5 Update] Self-learning, cluster TP, and regression integration
   int    total_win_count = 0;                                    // [v3.5 Update] Self-learning, cluster TP, and regression integration
   int    total_loss_count = 0;                                   // [v3.5 Update] Self-learning, cluster TP, and regression integration

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

  for(int ordinal=0; ordinal<g_learningCount; ordinal++)
    {
      SLearningRecord record; // [v3.1] iterate over FIFO-ordered cache
      if(!GetLearningRecord(ordinal, record))
         continue;
      string signal_upper = SafeToUpper(record.signal_type);
     int dir_index = 0;
      if(StringFind(signal_upper, "SELL")!=-1)
         dir_index = 1;
      int pattern = MathMax(0, MathMin(PATTERN_COMBINATIONS-1, record.pattern_index));

      g_patternStats[dir_index][pattern].trades++;
      g_patternStats[dir_index][pattern].sum_profit += record.profit;
      if(record.result>0)
        {
         g_patternStats[dir_index][pattern].wins++;
         g_patternStats[dir_index][pattern].sum_win_profit += record.profit;
         total_win_sum += record.profit;                         // [v3.5 Update] Self-learning, cluster TP, and regression integration
         total_win_count++;                                      // [v3.5 Update] Self-learning, cluster TP, and regression integration
        }
      else
        {
         g_patternStats[dir_index][pattern].sum_loss_profit += record.profit;
         total_loss_sum += record.profit;                        // [v3.5 Update] Self-learning, cluster TP, and regression integration
         total_loss_count++;                                     // [v3.5 Update] Self-learning, cluster TP, and regression integration
        }
     }

   for(int dir=0; dir<2; ++dir)
     {
      for(int pattern=0; pattern<PATTERN_COMBINATIONS; ++pattern)
       UpdateProbabilityModel(dir, pattern);
     }
   int total_samples = total_win_count + total_loss_count;       // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double avg_win = (total_win_count>0 ? total_win_sum / (double)total_win_count : 0.0); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double avg_loss = (total_loss_count>0 ? MathAbs(total_loss_sum / (double)total_loss_count) : 0.0); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double win_rate = (total_samples>0 ? (double)total_win_count / (double)total_samples : 0.0); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   LogEvent(StringFormat("Probability model refreshed: winRate=%.2f avgWin=%.2f avgLoss=%.2f samples=%d", win_rate, avg_win, avg_loss, total_samples)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
  }
//+------------------------------------------------------------------+
void UpdateProbabilityModel(const int dir_index, const int pattern_index)
  {
   if(g_patternStats[dir_index][pattern_index].trades==0)
     {
      g_patternModel[dir_index][pattern_index].probability = 0.0;
      g_patternModel[dir_index][pattern_index].average_win = 0.0;
      g_patternModel[dir_index][pattern_index].average_loss = 0.0;
      return;
     }
   ulong pattern_trades = g_patternStats[dir_index][pattern_index].trades;
   ulong pattern_wins   = g_patternStats[dir_index][pattern_index].wins;
   ulong losses = pattern_trades - pattern_wins;
   g_patternModel[dir_index][pattern_index].probability = (double)pattern_wins / (double)pattern_trades;
   g_patternModel[dir_index][pattern_index].average_win = (pattern_wins>0) ? g_patternStats[dir_index][pattern_index].sum_win_profit / (double)pattern_wins : 0.0;
   g_patternModel[dir_index][pattern_index].average_loss = (losses>0) ? g_patternStats[dir_index][pattern_index].sum_loss_profit / (double)losses : 0.0;
  }

//+------------------------------------------------------------------+
void LoadState()
  {
   int handle = FileOpen(g_stateFileName, FILE_READ|FILE_CSV|FILE_ANSI);
   if(handle==INVALID_HANDLE)
      return;

   // skip header line
   if(!FileIsEnding(handle))
     {
      FileReadString(handle);
      while(!FileIsLineEnding(handle) && !FileIsEnding(handle))
         FileReadString(handle);
     }

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
      g_stats.total_wins         = (ulong)FileReadNumber(handle);
      g_stats.total_losses       = (ulong)FileReadNumber(handle);
      g_stats.total_profit       = FileReadNumber(handle);
     }

   g_params.fast_period   = MathMax(2, g_params.fast_period);
   g_params.slow_period   = MathMax(g_params.fast_period+2, g_params.slow_period);
   g_params.rsi_period    = MathMax(3, g_params.rsi_period);
   g_params.mfi_period    = MathMax(3, g_params.mfi_period);
   g_params.volume_period = MathMax(5, MathMin(MAX_VOLUME_BUFFER, g_params.volume_period));
   g_params.volume_multiplier = MathMax(0.5, MathMin(3.0, g_params.volume_multiplier));

   g_stats.window_trades = 0;
   g_stats.window_wins   = 0;
   g_stats.window_losses = 0;
   g_stats.window_profit = 0.0;

   FileClose(handle);
  }
//+------------------------------------------------------------------+
void SaveState()
  {
   int handle = FileOpen(g_stateFileName, FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(handle==INVALID_HANDLE)
      return;

   FileWrite(handle,
             "FastMA","SlowMA","RSIPeriod","RSI_Overbought","RSI_Oversold",
             "MFIPeriod","MFI_Overbought","MFI_Oversold",
             "VolumePeriod","VolumeMultiplier",
             "TotalTrades","TotalWins","TotalLosses","TotalProfit");

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
             g_stats.total_wins,
             g_stats.total_losses,
             g_stats.total_profit);
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
   if(g_learningCount<MIN_LEARNING_ACTIVATION)
      return;

   //--- compute dynamic learning rate based on rolling sample size
   double sample_trades = (double)MathMin(g_learningCount, MAX_LEARNING_RECORDS);
   double learningRate  = MathMin(1.0, sample_trades / 700.0);
   double win_rate      = RecentWinRate();
   double avg_profit    = (g_stats.window_trades>0) ? g_stats.window_profit / (double)g_stats.window_trades : 0.0;

   double recent_avg_profit = RecentAverageProfit(RECENT_METRIC_WINDOW); // [v3.1] evaluate short-term PnL
   if(recent_avg_profit<0.0)
      learningRate = MathMin(1.0, learningRate * 1.5); // [v3.1] accelerate recovery during drawdown
   else if(win_rate>0.65)
      learningRate = MathMax(0.0, learningRate * 0.75); // [v3.1] temper adjustments when win rate is elevated

   LogEvent(StringFormat("SelfTune cycle triggered: trades=%I64u, winRate=%.4f, learningRate=%.2f", // [v3.1]
                         g_stats.total_trades,
                         win_rate,
                         learningRate));

   //--- accumulate indicator snapshots for winners and losers to bias thresholds
   double win_rsi_sum=0.0, loss_rsi_sum=0.0, win_mfi_sum=0.0, loss_mfi_sum=0.0;
   int win_count=0, loss_count=0;
   for(int ordinal=0; ordinal<g_learningCount; ordinal++)
     {
      SLearningRecord rec;
      if(!GetLearningRecord(ordinal, rec))
         continue;
      if(rec.result>0)
        {
         win_count++;
         win_rsi_sum += rec.rsi;
         win_mfi_sum += rec.mfi;
        }
      else
        {
         loss_count++;
         loss_rsi_sum += rec.rsi;
         loss_mfi_sum += rec.mfi;
        }
     }

   double rsi_delta = 0.0;
   double mfi_delta = 0.0;
   if(win_count>0 && loss_count>0)
     {
      rsi_delta = (loss_rsi_sum/(double)loss_count) - (win_rsi_sum/(double)win_count);
      mfi_delta = (loss_mfi_sum/(double)loss_count) - (win_mfi_sum/(double)win_count);
     }

   double ma_shift = 0.0;
   if(win_rate>0.55)
      ma_shift = -1.0;
   else if(win_rate<0.45)
      ma_shift = 1.0;
   else if(avg_profit<0.0)
      ma_shift = 0.5;

   if(ma_shift<0.0 && !InpAllowParamDecrease)
      ma_shift = 0.0;

   double new_fast = (double)g_params.fast_period + ma_shift * learningRate;
   double new_slow = (double)g_params.slow_period + ma_shift * learningRate * 1.5;
   g_params.fast_period = (int)MathRound(MathMax(3.0, new_fast));
   g_params.slow_period = (int)MathRound(MathMax(g_params.fast_period+2.0, new_slow));

   g_params.rsi_oversold   = MathMax(10.0, g_params.rsi_oversold - rsi_delta * learningRate * 0.1);
   g_params.rsi_overbought = MathMin(90.0, g_params.rsi_overbought + rsi_delta * learningRate * 0.1);
   g_params.mfi_oversold   = MathMax(10.0, g_params.mfi_oversold - mfi_delta * learningRate * 0.1);
   g_params.mfi_overbought = MathMin(90.0, g_params.mfi_overbought + mfi_delta * learningRate * 0.1);

   double volume_adjust = (avg_profit>=0.0 ? -0.1 : 0.1) * learningRate;
   g_params.volume_multiplier = MathMax(0.5, MathMin(3.0, g_params.volume_multiplier + volume_adjust));

   int volume_period_shift = (int)MathRound(ma_shift * learningRate);
   g_params.volume_period = MathMax(5, MathMin(MAX_VOLUME_BUFFER, g_params.volume_period + volume_period_shift));

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

   //--- emit a detailed learning summary for audit trails
    string report = StringFormat("Self-tune v3 lr=%.2f winRate=%.2f avgProfit=%.2f fastMA=%d slowMA=%d RSI(%.1f/%.1f) MFI(%.1f/%.1f) VolMult=%.2f",
                                 learningRate, win_rate, avg_profit, g_params.fast_period, g_params.slow_period,
                                 g_params.rsi_oversold, g_params.rsi_overbought,
                                 g_params.mfi_oversold, g_params.mfi_overbought,
                                 g_params.volume_multiplier);
    LogEvent(report);
    UpdateAdaptiveTakeProfitState(); // [v3.3] Adaptive TakeProfit based on learning data
    g_lastTuneWinRate = win_rate;      // [v3.1] refresh deviation baseline
   g_hasTuneBaseline = true;
   SaveState();
   RecreateIndicators();
  }
//+------------------------------------------------------------------+
void RecreateIndicators()
  {
   ReleaseIndicatorHandles();    // [v3.1] release prior handles before recreation
   CreateIndicatorHandles();     // [v3.1] rebuild indicator stack safely
  }
//+------------------------------------------------------------------+
void LoadLearningData()
  {
   ArrayResize(g_learningRecords, MAX_LEARNING_RECORDS); // [v3.1] preallocate ring storage before load
   g_learningCount = 0;
   g_learningHead  = 0;
   g_sinceLastTune = 0;        // [v3.1] reset tuning cadence while rebuilding cache
   g_hasTuneBaseline = false;

   string header_fields[];
   bool   has_extended_columns = false;
   bool   has_probability_columns = false; // [v3.4] Learning-based probability system and adaptive entry
   SLearningRecord record;

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

   int handle = FileOpen(g_learningFileName, FILE_READ|FILE_CSV|FILE_ANSI);
   if(handle==INVALID_HANDLE)
     {
      UpdateProbabilityModel();
      RecalculateRecentMetrics();
      return;
     }

   //--- parse header to determine column availability
   if(!FileIsEnding(handle))
     {
      while(true)
        {
         string field = FileReadString(handle);
         int count = ArraySize(header_fields);
         ArrayResize(header_fields, count+1);
         header_fields[count] = field;
         if(FileIsLineEnding(handle) || FileIsEnding(handle))
            break;
        }
     }

   for(int i=0;i<ArraySize(header_fields);i++)
     {
      if(StringCompare(header_fields[i], "EquityBefore")==0)
        {
         has_extended_columns = true;
        }
      if(StringCompare(header_fields[i], "SignalPatternID")==0)
         has_probability_columns = true;
     }

   while(!FileIsEnding(handle))
     {
      string fields[];
      ArrayResize(fields, 0);

      bool blank_line = false;
      while(!FileIsEnding(handle))
        {
         string field = FileReadString(handle);
         if(ArraySize(fields)==0 && StringLen(field)==0 && FileIsLineEnding(handle))
           {
            blank_line = true;
            break;
           }

         int idx = ArraySize(fields);
         ArrayResize(fields, idx+1);
         fields[idx] = field;

         if(FileIsLineEnding(handle) || FileIsEnding(handle))
            break;
        }

      if(blank_line)
         continue;

      if(ArraySize(fields)==0)
        {
         if(FileIsEnding(handle))
            break;
         continue;
        }

      int expected_columns = (has_extended_columns ? 20 : 15);
      if(has_probability_columns)
         expected_columns += 3;
      if(ArraySize(fields) < expected_columns)
         continue;

      ZeroMemory(record);
      bool malformed = false;
      int field_index = 0;

      string trade_id_field = fields[field_index++];
      string trade_id_unquoted = CsvUnquote(trade_id_field);
      double tmp_val = 0.0;
      if(StringLen(trade_id_unquoted) > 0)
        {
         ResetLastError();
         tmp_val = StringToDouble(trade_id_unquoted);
         if(GetLastError()!=0)
            tmp_val = 0.0;
        }
      if(!MathIsValidNumber(tmp_val) || tmp_val < 0.0)
         tmp_val = 0.0;
      record.trade_id = (ulong)MathRound(tmp_val); // [v3.1.1] Safe parse for trade_id (quoted-safe, backward compatible)

      record.symbol = CsvUnquote(fields[field_index++]);

      double time_val = SafeCsvToDouble(fields[field_index++], malformed);
      record.time = (datetime)time_val;
      record.fast_ma = SafeCsvToDouble(fields[field_index++], malformed);
      record.slow_ma = SafeCsvToDouble(fields[field_index++], malformed);
      record.rsi     = SafeCsvToDouble(fields[field_index++], malformed);
      record.mfi     = SafeCsvToDouble(fields[field_index++], malformed);
      record.volume  = SafeCsvToDouble(fields[field_index++], malformed);
      record.profit  = SafeCsvToDouble(fields[field_index++], malformed);
      record.win_loss = CsvUnquote(fields[field_index++]);
      record.grid_level = (int)SafeCsvToDouble(fields[field_index++], malformed);
      record.atr_points = SafeCsvToDouble(fields[field_index++], malformed);
      record.signal_type = CsvUnquote(fields[field_index++]);
      record.result = (int)SafeCsvToDouble(fields[field_index++], malformed);

      if(has_extended_columns)
        {
         record.equity_before = SafeCsvToDouble(fields[field_index++], malformed);
         record.equity_after  = SafeCsvToDouble(fields[field_index++], malformed);
         record.duration_sec  = SafeCsvToDouble(fields[field_index++], malformed);
         record.drawdown_pct  = SafeCsvToDouble(fields[field_index++], malformed);
         record.trade_type    = CsvUnquote(fields[field_index++]);
        }
      else
        {
         record.equity_before = 0.0;
         record.equity_after  = 0.0;
         record.duration_sec  = 0.0;
         record.drawdown_pct  = 0.0;
         record.trade_type    = "Primary";
        }

      record.pattern_index = (int)SafeCsvToDouble(fields[field_index++], malformed);

      if(has_probability_columns && (field_index+2) < ArraySize(fields))
        {
         record.signal_pattern_id = CsvUnquote(fields[field_index++]);
         record.win_probability   = SafeCsvToDouble(fields[field_index++], malformed);
         record.confidence_score  = SafeCsvToDouble(fields[field_index++], malformed);
        }
      else
        {
         record.signal_pattern_id = "";
         record.win_probability = 0.0;
         record.confidence_score = 0.0;
        }

      if(malformed)
         continue;

      if(StringLen(record.signal_pattern_id)==0)
        {
         ENUM_POSITION_TYPE derived_dir = (StringFind(SafeToUpper(record.signal_type), "SELL")!=-1) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
         record.signal_pattern_id = BuildSignalPatternID(derived_dir, record.pattern_index);
        }

      StoreLearningRecord(record, false);
     }

   FileClose(handle);

   RecalculateRecentMetrics();
   UpdateProbabilityModel();
   bool regression_updated = UpdateRegressionModelIfNeeded(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   RefreshLearningProbabilities();
   if(regression_updated) // [v3.5 Update] Self-learning, cluster TP, and regression integration
      SaveLearningData(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   UpdateAdaptiveTakeProfitState(); // [v3.3] Adaptive TakeProfit based on learning data
  }
//+------------------------------------------------------------------+
void SaveLearningData()
  {
   int handle = FileOpen(g_learningFileName, FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(handle==INVALID_HANDLE)
      return;

   FileWrite(handle,
             "TradeID","Symbol","Time","FastMA","SlowMA","RSI","MFI","Volume",
             "Profit","WinLoss","GridLevel","ATR","SignalType","Result",
             "EquityBefore","EquityAfter","DurationSec","DrawdownPct","TradeType","PatternIndex",
             "SignalPatternID","WinProbability","ConfidenceScore");

   for(int ordinal=0; ordinal<g_learningCount; ordinal++)
     {
      SLearningRecord record;
      if(!GetLearningRecord(ordinal, record))
         continue;
      FileWrite(handle,
                record.trade_id,
                CsvQuote(record.symbol),
                record.time,
                record.fast_ma,
                record.slow_ma,
                record.rsi,
                record.mfi,
                record.volume,
                record.profit,
                CsvQuote(record.win_loss),
                record.grid_level,
                record.atr_points,
                CsvQuote(record.signal_type),
                record.result,
                record.equity_before,
                record.equity_after,
                record.duration_sec,
                record.drawdown_pct,
                CsvQuote(record.trade_type),
                record.pattern_index,
                CsvQuote(record.signal_pattern_id),
                record.win_probability,
                record.confidence_score);
     }
   FileClose(handle);
  }
//+------------------------------------------------------------------+
string CsvQuote(const string value)
  {
   string tmp = value;
   StringReplace(tmp, "\"", "\"\"");
   return("\""+tmp+"\""); // [v3.1] ensure AI-friendly quoting
  }
//+------------------------------------------------------------------+
string CsvUnquote(const string value)
  {
   string tmp = value;
   while(StringLen(tmp)>=2 && StringGetCharacter(tmp,0)=='"' && StringGetCharacter(tmp,StringLen(tmp)-1)=='"')
      tmp = StringSubstr(tmp,1,StringLen(tmp)-2);
   StringReplace(tmp, "\"\"", "\"");
   return(tmp);
  }
//+------------------------------------------------------------------+
void LogEvent(const string message)
  {
   datetime ts = TimeCurrent();
   int handle = FileOpen(g_logFileName, FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI);
   if(handle==INVALID_HANDLE)
      return;
   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle,
             CsvQuote(TimeToString(ts, TIME_DATE|TIME_SECONDS)),
             CsvQuote("EVENT"),
             CsvQuote(message)); // [v3.1] keep log CSV AI-compatible
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
   datetime ts = TimeCurrent();
   string message = StringFormat("ticket=%I64u,direction=%s,profit=%.2f", deal_ticket, direction, deal_profit); // [v3.1] structured log payload
   int handle = FileOpen(g_logFileName, FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI);
   if(handle==INVALID_HANDLE)
      return;
   FileSeek(handle,0,SEEK_END);
   FileWrite(handle,
             CsvQuote(TimeToString(ts, TIME_DATE|TIME_SECONDS)),
             CsvQuote("TRADE"),
             CsvQuote(message));
   FileClose(handle);
  }
//+------------------------------------------------------------------+
