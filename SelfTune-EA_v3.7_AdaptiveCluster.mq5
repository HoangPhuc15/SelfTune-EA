//+------------------------------------------------------------------+
//|                                          SelfTune-EA_v3.7_AdaptiveCluster.mq5 | // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
//|                                                     SelfTune Labs |
//|                Probability enhanced adaptive grid Expert Advisor |
//+------------------------------------------------------------------+
#property copyright "SelfTune Labs"
#property link      "https://github.com/SelfTune"
#property version   "3.70" // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
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

const int     MAX_VOLUME_BUFFER       = 512;
const int     MAX_LEARNING_RECORDS    = 700;
const int     MIN_LEARNING_ACTIVATION = 100;
const int     MIN_LEARNING_CLOSED_TRADES = MIN_LEARNING_ACTIVATION; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
const int     REGRESSION_RETRAIN_STEP = 20;   // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
const int     INT_SAFE_MAX            = 2147483647; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
const int     RECENT_METRIC_WINDOW    = 50;
const int     PATTERN_LOOKBACK_WINDOW = 60;   // [v3.5 Update] Self-learning, cluster TP, and regression integration

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
input double            InpBaseLot         = 0.01;           // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability - Minimum base lot for the first trade
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
input int               InpDynamicStepStart= 3;              // Orders required before adaptive grid spacing engages

sinput string sep3="--- Adaptive Learning ---";
input int               InpTradesPerTune   = 700;            // Trades before self-tune
input bool              InpAllowParamDecrease = true;        // Allow decreasing periods
input double            InpProbabilityThreshold = 0.68;      // Minimum probability to trade
input double            InpConfidenceFloor = 0.35;           // Minimum confidence factor for reduced sizing

sinput string sep4="--- Logging ---";
input bool              InpVerboseLogging  = true;           // Verbose logging
input bool              InpLogIndicators   = false;          // Log indicator snapshots
input bool              InpVerboseLearning = false;          // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability - Detailed learning logs

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
   ulong    closed_trades;      // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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
   double   base_buy_step;
   double   base_sell_step;
   double   anchor_buy_lot;
   double   anchor_sell_lot;
   double   anchor_buy_price;
   double   anchor_sell_price;
   double   max_buy_lot;
   double   max_sell_lot;
   datetime buy_cycle_start;
   datetime sell_cycle_start;
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
SGridState       g_grid = {0,0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0.0,0,0};
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

datetime           g_lastTradeAttemptTime = 0;  // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
datetime           g_lastGridAttemptTime  = 0;  // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
bool               g_tradeAttemptPending  = false; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

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
bool        IsTradeContextBusy(); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
int         CountOpenPositionsByDirection(const ENUM_POSITION_TYPE direction); // [v3.7 Update] BaseLot enforcement per direction
void        EvaluateSignals(bool &buy_signal, bool &sell_signal, double &atr_points);
void        ExecuteSignal(const bool buy_signal, const bool sell_signal, const double atr_points);
double      CalculateLotSize(const double risk_points); // [v3.3] Adaptive TakeProfit based on learning data
double      AlignVolumeToStep(const double volume); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
double      AlignVolumeToBase(const double volume); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
double      NormalizeVolumeToStep(const double volume,const double lot_step,const double min_lot,const double max_lot); // [v3.7 Update] Grid sizing guard
double      NormalizeGridStep(const double raw_points);                        // [v3.7 Update] Grid spacing guard
bool        CollectDirectionMetrics(const ENUM_POSITION_TYPE direction,int &levels,double &base_lot,double &last_price,double &max_lot); // [v3.7 Update] Grid anchoring sync
void        SyncGridState(); // [v3.7 Update] Grid anchoring sync
bool        ProcessGridDirection(const ENUM_POSITION_TYPE direction,const int levels,const double base_lot,const double atr_points,const datetime now); // [v3.7 Update] Grid anchoring sync
bool        RiskChecks();
void        ManagePositions(const double atr_points);
void        ManageGrid(const double atr_points);
void        ResetGridStateIfNeeded();
int         SafeClosedTradeCount(); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
void        InitializeAdaptiveTakeProfit(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
void        UpdateAdaptiveTakeProfitState(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
double      DetermineAdaptiveTakeProfitPoints(const int recovery_level,const double probability_hint); // [v3.5 Update] Self-learning, cluster TP, and regression integration
void        ManageCluster(const ENUM_POSITION_TYPE direction,const double atr_points); // [v3.5 Update] Self-learning, cluster TP, and regression integration
double      ComputeClusterTarget(const int order_count,const double base_points,const double probability,const double confidence,const double atr_points,double &pre_adjust_target,bool &logged); // [v3.5 Update] Self-learning, cluster TP, and regression integration
double      ApplyProbabilityTargetAdjustment(const double base_target,const double probability,const double confidence,bool &logged); // [v3.5 Update] Self-learning, cluster TP, and regression integration
double      ComputeWindowWinRate(const int window); // [v3.3] Adaptive TakeProfit based on learning data
void        LogEvent(const string message,const bool essential=false); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
void        LogLearningEvent(const string message,const bool essential=false); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
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
bool        PredictTradeOutcome(const SSignalDecision &decision,const ENUM_POSITION_TYPE direction,const double base_lot,double &adjusted_lot); // [v3.5 Update] Self-learning, cluster TP, and regression integration
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
double      EstimateBootstrapProbability(const SSignalDecision &decision,const ENUM_POSITION_TYPE direction); // [v3.5 Update] Self-learning, cluster TP, and regression integration
double      EstimateBootstrapConfidence(const SSignalDecision &decision,const ENUM_POSITION_TYPE direction); // [v3.5 Update] Self-learning, cluster TP, and regression integration
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

   double effective_base_lot = AlignVolumeToBase(MathMax(InpBaseLot, 0.0)); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   LogEvent(StringFormat("Base lot initialized at %.2f lots", effective_base_lot), true); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   LogEvent("EA initialized", true); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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
   LogEvent(StringFormat("EA deinitialized (%d)",reason), true); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
  }
//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(IsStopped())
      return; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

   bool trading_allowed = RiskChecks();
   double atr_points = (g_atrBuffer[0]>0.0 ? g_atrBuffer[0]/_Point : 0.0);
   bool buy_signal=false, sell_signal=false;

   UpdateActiveTradeExtents(); // [v3.1] refresh equity peaks/troughs for open trades

   datetime now = TimeCurrent(); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
   if(g_tradeAttemptPending && (now - g_lastTradeAttemptTime) > 10)
      g_tradeAttemptPending = false; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

   bool trade_context_busy = (IsTradeContextBusy() || g_tradeAttemptPending); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
   if(trade_context_busy)
     {
      Sleep(10); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
      trading_allowed = false; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
     }

   bool new_bar = IsNewBar(); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   if(!new_bar)
     {
      ManagePositions(atr_points); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
      if(trading_allowed)
         ManageGrid(atr_points); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
      return; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
     }

   if(RefreshIndicators())
     {
      EvaluateSignals(buy_signal, sell_signal, atr_points);
      if(InpLogIndicators)
         LogIndicatorSnapshot();
      if(trading_allowed)
         ExecuteSignal(buy_signal, sell_signal, atr_points);
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

   g_tradeAttemptPending = false; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

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

   bool regression_updated = false; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

   if(entry_is_in)
     {
      g_stats.total_trades++;
      g_stats.window_trades++;
      if(deal_type==DEAL_TYPE_BUY)
        {
        double normalized_entry = AlignVolumeToBase(MathMax(deal_volume, InpBaseLot)); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
        if(g_grid.buy_levels==0)
          {
           g_grid.base_buy_lot  = normalized_entry;
           g_grid.base_buy_step = 0.0;
           g_grid.anchor_buy_lot   = normalized_entry;
           g_grid.anchor_buy_price = deal_price;
           g_grid.buy_cycle_start  = deal_time;
          }
         g_grid.buy_levels++;
         if(g_grid.buy_levels==1)
            g_grid.buy_cycle_start = deal_time;
        g_grid.max_buy_lot = AlignVolumeToBase(MathMax(g_grid.max_buy_lot, normalized_entry));
        double anchor_candidate = AlignVolumeToBase(MathMax(normalized_entry, InpBaseLot));
        if(g_grid.anchor_buy_lot<=0.0)
           g_grid.anchor_buy_lot = anchor_candidate;
        else
           g_grid.anchor_buy_lot = AlignVolumeToBase(MathMax(MathMin(g_grid.anchor_buy_lot, anchor_candidate), InpBaseLot));
        g_grid.last_buy_price = deal_price;
       }
      else if(deal_type==DEAL_TYPE_SELL)
        {
        double normalized_entry = AlignVolumeToBase(MathMax(deal_volume, InpBaseLot)); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
        if(g_grid.sell_levels==0)
          {
           g_grid.base_sell_lot  = normalized_entry;
           g_grid.base_sell_step = 0.0;
           g_grid.anchor_sell_lot   = normalized_entry;
           g_grid.anchor_sell_price = deal_price;
           g_grid.sell_cycle_start  = deal_time;
          }
         g_grid.sell_levels++;
         if(g_grid.sell_levels==1)
            g_grid.sell_cycle_start = deal_time;
        g_grid.max_sell_lot = AlignVolumeToBase(MathMax(g_grid.max_sell_lot, normalized_entry));
        double anchor_candidate = AlignVolumeToBase(MathMax(normalized_entry, InpBaseLot));
        if(g_grid.anchor_sell_lot<=0.0)
           g_grid.anchor_sell_lot = anchor_candidate;
        else
           g_grid.anchor_sell_lot = AlignVolumeToBase(MathMax(MathMin(g_grid.anchor_sell_lot, anchor_candidate), InpBaseLot));
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
      g_stats.closed_trades++; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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

      if(closing_buy)
        {
        if(g_grid.buy_levels>0)
           g_grid.buy_levels--;
         if(g_grid.buy_levels==0)
          {
           g_grid.last_buy_price = 0.0;
           g_grid.base_buy_lot   = 0.0;
           g_grid.base_buy_step  = 0.0;
           g_grid.anchor_buy_lot   = 0.0;
           g_grid.anchor_buy_price = 0.0;
           g_grid.max_buy_lot      = 0.0;
           g_grid.buy_cycle_start  = 0;
          }
        }
      else
        {
         if(g_grid.sell_levels>0)
           g_grid.sell_levels--;
         if(g_grid.sell_levels==0)
          {
           g_grid.last_sell_price = 0.0;
           g_grid.base_sell_lot   = 0.0;
           g_grid.base_sell_step  = 0.0;
           g_grid.anchor_sell_lot   = 0.0;
           g_grid.anchor_sell_price = 0.0;
           g_grid.max_sell_lot      = 0.0;
           g_grid.sell_cycle_start  = 0;
          }
        }

      int closed_trades = SafeClosedTradeCount();
      if(closed_trades>=MIN_LEARNING_CLOSED_TRADES && (closed_trades % REGRESSION_RETRAIN_STEP)==0)
         regression_updated = UpdateRegressionModelIfNeeded(); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
     }

   ResetGridStateIfNeeded();
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
                   "TotalTrades","ClosedTrades","TotalWins","TotalLosses","TotalProfit"); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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
                   "TradeID","Symbol","DateTime","FastMA","SlowMA","RSI","MFI","Volume", // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
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
//| Check trade permissions to emulate context availability          |
//+------------------------------------------------------------------+
bool IsTradeContextBusy()
  {
   if(MQLInfoInteger(MQL_TRADE_ALLOWED)==0)
      return(true);

   if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)==0)
      return(true);

   if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)==0)
      return(true);

   return(false);
  }
//+------------------------------------------------------------------+
//| Count open positions per direction (hedge friendly)              |
//+------------------------------------------------------------------+
int CountOpenPositionsByDirection(const ENUM_POSITION_TYPE direction)
  {
   int total = 0;
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
      ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(pos_type==direction)
         total++;
     }
   return(total);
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
   if(IsStopped())
      return; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

   datetime now = TimeCurrent(); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
   if(IsTradeContextBusy())
     {
      g_tradeAttemptPending = true; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
      g_lastTradeAttemptTime = now; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
      Sleep(10); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
      return;
     }

   if(g_tradeAttemptPending && (now - g_lastTradeAttemptTime) < 2)
      return; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

   if(!buy_signal && !sell_signal)
      return;

   double probability_hint = g_lastDecisionProbability; // [v3.4] Learning-based probability system and adaptive entry
   double take_profit_points = DetermineAdaptiveTakeProfitPoints(0, probability_hint); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double atr_floor = atr_points * InpATRMultiplierTP; // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double risk_points = MathMax(take_profit_points, MathMax(atr_floor, 10.0)); // [v3.5 Update] Self-learning, cluster TP, and regression integration

   double base_lot = CalculateLotSize(risk_points); // [v3.3] Adaptive TakeProfit based on learning data
   if(base_lot<=0.0)
      return;

   double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(min_volume<=0.0)
      min_volume = (step_volume>0.0 ? step_volume : 0.01);
   double enforced_base = AlignVolumeToBase(MathMax(InpBaseLot, min_volume)); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability

   bool has_symbol_position = PositionSelect(_Symbol);
   if(!has_symbol_position && base_lot>enforced_base+0.0000001)
     {
      base_lot = enforced_base;
      if(InpVerboseLogging)
         LogEvent(StringFormat("Base lot aligned to minimum %.2f", base_lot));
     }

   base_lot = AlignVolumeToBase(base_lot); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability

   double buy_lot = base_lot;
   double sell_lot = base_lot;
   int open_buy_positions = CountOpenPositionsByDirection(POSITION_TYPE_BUY);
   int open_sell_positions = CountOpenPositionsByDirection(POSITION_TYPE_SELL);
   bool buy_allowed = (buy_signal && ConfirmPatternForEntry(g_buyDecision, POSITION_TYPE_BUY));  // [v3.4] Learning-based probability system and adaptive entry
   bool sell_allowed = (sell_signal && ConfirmPatternForEntry(g_sellDecision, POSITION_TYPE_SELL)); // [v3.4] Learning-based probability system and adaptive entry

   if(buy_allowed)
      buy_allowed = PredictTradeOutcome(g_buyDecision, POSITION_TYPE_BUY, base_lot, buy_lot); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(sell_allowed)
      sell_allowed = PredictTradeOutcome(g_sellDecision, POSITION_TYPE_SELL, base_lot, sell_lot); // [v3.5 Update] Self-learning, cluster TP, and regression integration

   if(buy_allowed)
     {
      if(open_buy_positions==0)
         buy_lot = enforced_base;
      buy_lot = AlignVolumeToBase(MathMax(buy_lot, enforced_base));
     }
   if(sell_allowed)
     {
      if(open_sell_positions==0)
         sell_lot = enforced_base;
      sell_lot = AlignVolumeToBase(MathMax(sell_lot, enforced_base));
     }

  if(buy_allowed && open_sell_positions>0)
     buy_allowed = false;
  if(sell_allowed && open_buy_positions>0)
     sell_allowed = false;

  if(buy_allowed && sell_allowed)
    {
     if(g_buyDecision.estimated_probability >= g_sellDecision.estimated_probability)
        sell_allowed = false;
     else
        buy_allowed = false;
    }

  bool trade_result = false;

  if(buy_allowed)
    {
      g_tradeAttemptPending = true; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
      g_lastTradeAttemptTime = now; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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
      else
        {
         g_tradeAttemptPending = false; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
        }
    }
  else if(sell_allowed)
     {
      g_tradeAttemptPending = true; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
      g_lastTradeAttemptTime = now; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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
      else
        {
         g_tradeAttemptPending = false; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
        }
     }

   if(trade_result)
     {
      double used_prob = buy_allowed ? g_buyDecision.estimated_probability : g_sellDecision.estimated_probability;
      double used_lot  = buy_allowed ? buy_lot : sell_lot;
      LogEvent(StringFormat("Order sent (lots=%.2f, prob=%.2f)", used_lot, used_prob), true); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
     }
   else if(buy_signal || sell_signal)
     {
      LogEvent(StringFormat("Order send failed: %d", GetLastError()), true); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
     }
  }
//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double NormalizeVolumeToStep(const double volume,const double lot_step,const double min_lot,const double max_lot) // [v3.7 Update] Grid sizing guard
  {
   double aligned = MathMax(volume, min_lot);
   if(lot_step>0.0)
     {
      double steps = MathCeil((aligned - 1e-9) / lot_step);
      if(steps<1.0)
         steps = 1.0;
      aligned = steps * lot_step;
     }

   if(max_lot>0.0)
      aligned = MathMin(aligned, max_lot);

   return(MathMax(min_lot, aligned));
  }

double AlignVolumeToStep(const double volume) // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
  {
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability

   if(min_lot<=0.0)
      min_lot = 0.01; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   if(max_lot<=0.0)
      max_lot = min_lot * 100.0; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability

   double aligned = NormalizeVolumeToStep(volume, lot_step, min_lot, max_lot);

   int volume_digits = 2; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   if(lot_step>0.0)
     {
      double step = lot_step;
      volume_digits = 0;
      while(volume_digits<8 && step<1.0)
        {
         step *= 10.0;
         volume_digits++;
        }
     }

   return(NormalizeDouble(aligned, volume_digits)); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
  }

double AlignVolumeToBase(const double volume) // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
  {
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(min_lot<=0.0)
      min_lot = 0.01;
   if(max_lot<=0.0)
      max_lot = min_lot * 100.0;

   double base_floor = MathMax(MathMax(volume, InpBaseLot), min_lot);
   double aligned    = NormalizeVolumeToStep(base_floor, lot_step, min_lot, max_lot);

   int volume_digits = 2;
   if(lot_step>0.0)
     {
      double step = lot_step;
      volume_digits = 0;
      while(volume_digits<8 && step<1.0)
        {
         step *= 10.0;
         volume_digits++;
        }
     }

   return(NormalizeDouble(aligned, volume_digits));
  }

double NormalizeGridStep(const double raw_points) // [v3.7 Update] Grid spacing guard
  {
   double baseline = MathMax(1.0, InpGridStepPoints);
   double adjusted = raw_points;
   if(adjusted<=0.0 || !MathIsValidNumber(adjusted))
      adjusted = baseline;

   double lower = baseline*0.9;
   double upper = baseline*1.1;
   adjusted = MathMax(lower, MathMin(upper, adjusted));

   double rounded = MathRound(adjusted);
   if(rounded<=0.0)
      rounded = baseline;
   return(MathMax(1.0, rounded));
  }

int SafeClosedTradeCount() // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
  {
   long closed = (long)g_stats.closed_trades;
   if(closed<0)
      closed = 0;
   if(closed>INT_SAFE_MAX)
      closed = INT_SAFE_MAX;
   return((int)closed);
  }

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

  double base_floor = AlignVolumeToBase(MathMax(InpBaseLot, min_lot)); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
  double lot = risk_lot;
  bool base_override_used = false; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
  if(lot<=0.0 || !MathIsValidNumber(lot))
    {
     lot = base_floor;
     base_override_used = true; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
    }

  if(lot < base_floor - 0.0000001)
    {
     lot = base_floor;
     base_override_used = true; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
    }

  lot = MathMax(min_lot, MathMin(max_lot, lot));
  lot = NormalizeDouble(lot, volume_digits);

  lot = AlignVolumeToBase(MathMax(lot, base_floor)); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability

  if(InpVerboseLogging && base_override_used)
     LogEvent(StringFormat("Base lot enforced at %.2f lots", lot), true); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability

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
      LogEvent("Trading halted: max drawdown reached", true); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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
      LogEvent("Trading halted: daily loss limit reached", true); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
      return(false);
     }

   return(true);
  }

//+------------------------------------------------------------------+
//| Manage open positions and adaptive TP                             |
//+------------------------------------------------------------------+
void ManagePositions(const double atr_points) // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   if(IsStopped())
      return; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
   if(IsTradeContextBusy())
      return; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

   ManageCluster(POSITION_TYPE_BUY, atr_points);  // [v3.5 Update] Self-learning, cluster TP, and regression integration
   ManageCluster(POSITION_TYPE_SELL, atr_points); // [v3.5 Update] Self-learning, cluster TP, and regression integration
  }
//+------------------------------------------------------------------+
//| Cluster-based virtual take-profit handler                         |
//+------------------------------------------------------------------+
void ManageCluster(const ENUM_POSITION_TYPE direction,const double atr_points) // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   if(IsStopped())
      return; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

   int total_positions = PositionsTotal(); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(total_positions<=0)
      return; // [v3.5 Update] Self-learning, cluster TP, and regression integration

   double   total_volume = 0.0;
   double   weighted_price = 0.0;
   double   probability_sum = 0.0;
   double   confidence_sum = 0.0;
   double   profit_sum = 0.0;
   int      order_count = 0;
   ulong    cluster_tickets[];
   datetime cluster_open_times[];
   double   cluster_profits[];
   double   cluster_volumes[];
   double   cluster_open_prices[];
   double   cluster_profit_points[];
   ArrayResize(cluster_tickets, 0);
   ArrayResize(cluster_open_times, 0);

    for(int i=0;i<total_positions;i++)
      {
       ulong ticket = PositionGetTicket(i);
       if(ticket==0)
          continue; // [v3.5 Update] Self-learning, cluster TP, and regression integration
       if(!PositionSelectByTicket(ticket))
          continue; // [v3.5 Update] Self-learning, cluster TP, and regression integration
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

       ArrayResize(cluster_tickets, order_count+1);
       ArrayResize(cluster_open_times, order_count+1);
       ArrayResize(cluster_profits, order_count+1);
       ArrayResize(cluster_volumes, order_count+1);
       ArrayResize(cluster_open_prices, order_count+1);
       cluster_tickets[order_count]    = ticket;
       cluster_open_times[order_count] = (datetime)PositionGetInteger(POSITION_TIME);
       cluster_profits[order_count]    = PositionGetDouble(POSITION_PROFIT);
       cluster_volumes[order_count]    = volume;
       cluster_open_prices[order_count]= open_price;
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

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double point_value = 0.0;
   if(tick_value>0.0 && tick_size>0.0)
      point_value = tick_value / tick_size;

   double avg_profit_points = 0.0;
   double avg_profit_currency = (order_count>0 ? profit_sum / (double)order_count : profit_sum);
   if(point_value>0.0)
      avg_profit_points = profit_sum / MathMax(0.0000001, total_volume * point_value * _Point);

   double avg_price = weighted_price / MathMax(total_volume, 0.0000001);
   double market_price = (direction==POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(order_count>0)
     {
      ArrayResize(cluster_profit_points, order_count);
      for(int i=0;i<order_count;i++)
        {
         double vol    = cluster_volumes[i];
         double profit = cluster_profits[i];
         double points = 0.0;
         if(point_value>0.0 && vol>0.0)
            points = profit / MathMax(0.0000001, vol * point_value * _Point);
         else
           {
            double price_diff = (direction==POSITION_TYPE_BUY ? (market_price - cluster_open_prices[i])
                                                              : (cluster_open_prices[i] - market_price));
            points = price_diff / _Point;
           }
         cluster_profit_points[i] = points;
        }
     }
   double price_based_points = (direction==POSITION_TYPE_BUY) ? (market_price - avg_price) / _Point
                                                             : (avg_price - market_price) / _Point;
   if(MathAbs(avg_profit_points)<0.0001)
      avg_profit_points = price_based_points;

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
      LogEvent(StringFormat("Adaptive TP adjusted: base=%.1f, winProb=%.2f, finalTP=%.1f", pre_adjust_target, cluster_probability, final_target), true); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   g_takeProfitState.last_cluster_target = final_target;             // [v3.5 Update] Self-learning, cluster TP, and regression integration

   double average_volume_per_order = total_volume / (double)order_count;
   double target_profit_currency = 0.0;
   if(point_value>0.0)
      target_profit_currency = final_target * _Point * point_value * average_volume_per_order;

   bool hit_point_target = (avg_profit_points>=final_target-0.0001);
   bool hit_currency_target = (target_profit_currency>0.0 && avg_profit_currency>=target_profit_currency);

   if(hit_point_target || hit_currency_target)
     {
      string dir_label = (direction==POSITION_TYPE_BUY ? "BUY" : "SELL");
      int indexes[];
      ArrayResize(indexes, order_count);
      for(int i=0;i<order_count;i++)
         indexes[i] = i;

      // oldest positions first so recovery overlap keeps the most recent trades
      for(int i=0;i<order_count-1;i++)
        {
         for(int j=i+1;j<order_count;j++)
           {
            int left  = indexes[i];
            int right = indexes[j];
            if(cluster_open_times[left] > cluster_open_times[right])
              {
               int temp = indexes[i];
               indexes[i] = indexes[j];
               indexes[j] = temp;
              }
           }
        }

      int max_keep = 0;
      if(g_takeProfitState.overlap_enabled && order_count>g_takeProfitState.overlap_threshold)
         max_keep = MathMin(order_count-1, g_takeProfitState.overlap_threshold);

      int max_close = order_count - max_keep;
      if(max_close<=0)
         return;

      double per_order_currency = target_profit_currency;
      double per_order_points   = final_target;
      double cumulative_profit  = 0.0;
      double cumulative_points  = 0.0;
      int close_plan[];
      ArrayResize(close_plan, 0);

      for(int i=0; i<order_count && ArraySize(close_plan)<max_close; i++)
        {
         int index = indexes[i];
         int next_count = ArraySize(close_plan) + 1;
         ArrayResize(close_plan, next_count);
         close_plan[next_count-1] = index;
         cumulative_profit += cluster_profits[index];
         double point_contrib = (ArraySize(cluster_profit_points)>index ? cluster_profit_points[index] : price_based_points);
         cumulative_points += point_contrib;

         bool requirement_met = false;
         if(per_order_currency>0.0)
            requirement_met = (cumulative_profit >= per_order_currency * next_count);
         else
            requirement_met = (cumulative_points >= per_order_points * next_count);

         if(requirement_met && next_count>0)
            break;
        }

      int close_count = ArraySize(close_plan);
      if(close_count==0 && max_close>0)
        {
         ArrayResize(close_plan, 1);
         close_plan[0] = indexes[0];
         close_count = 1;
         cumulative_profit = cluster_profits[indexes[0]];
         cumulative_points = (ArraySize(cluster_profit_points)>indexes[0] ? cluster_profit_points[indexes[0]] : price_based_points);
        }

      double executed_profit = 0.0;
      double executed_points = 0.0;
      int actual_closed = 0;
      for(int t=0; t<close_count; t++)
        {
         if(IsStopped())
            break; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
         if(IsTradeContextBusy())
           {
            Sleep(10); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
            break;
           }
         int index = close_plan[t];
         if(index<0 || index>=order_count)
            continue;
         ulong ticket = cluster_tickets[index];
         if(ticket>0)
           {
            double position_profit = cluster_profits[index];
            double position_points = (ArraySize(cluster_profit_points)>index ? cluster_profit_points[index] : 0.0);
            if(g_trade.PositionClose(ticket))
              {
               actual_closed++;
               executed_profit += position_profit;
               executed_points += position_points;
              }
            else
              {
               LogEvent(StringFormat("Cluster close retry required: %s ticket=%I64u", dir_label, ticket), true); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
              }
           }
        }

      int keep_count = MathMax(0, order_count - actual_closed);
      LogEvent(StringFormat("Cluster closed: %s closed=%d kept=%d avgPoints=%.1f target=%.1f avgProfit=%.2f targetProfit=%.2f total=%.2f realizedProfit=%.2f realizedPoints=%.1f", dir_label, actual_closed, keep_count, avg_profit_points, final_target, avg_profit_currency, target_profit_currency, profit_sum, executed_profit, executed_points)); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
     }
  }
//+------------------------------------------------------------------+
double ComputeClusterTarget(const int order_count,const double base_points,const double probability,const double confidence,const double atr_points,double &pre_adjust_target,bool &logged) // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   double adjusted = base_points;
   bool adjustment_flag = false;
   if(order_count>0)
     {
      int effective_orders = order_count;
      if(!g_takeProfitState.overlap_enabled && effective_orders>g_takeProfitState.overlap_threshold)
         effective_orders = g_takeProfitState.overlap_threshold;
      int reduction_index = MathMax(0, effective_orders-1);
      if(reduction_index>0 && g_takeProfitState.dynamic_reduction_points>0.0)
         adjustment_flag = true;
      adjusted -= g_takeProfitState.dynamic_reduction_points * reduction_index;
     }

   adjusted = MathMax(5.0, adjusted);
   if(atr_points>0.0)
      adjusted = MathMax(adjusted, atr_points*0.25);

   pre_adjust_target = adjusted;
   bool probability_logged = false;
   double final_target = ApplyProbabilityTargetAdjustment(adjusted, probability, confidence, probability_logged);
   logged = (adjustment_flag || probability_logged);
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
   if(IsStopped())
      return; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
   if(!InpUseGrid || InpMaxGridLevels<=0)
      return;

   datetime now = TimeCurrent(); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
   if(IsTradeContextBusy())
     {
      g_tradeAttemptPending = true; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
      g_lastTradeAttemptTime = now; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
      Sleep(10); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
      return;
     }

   SyncGridState();

  bool both_active = (g_grid.buy_levels>0 && g_grid.sell_levels>0);
  bool try_buy_first = (g_grid.buy_levels>0 && g_grid.base_buy_lot>0.0);
  bool try_sell_first = (g_grid.sell_levels>0 && g_grid.base_sell_lot>0.0);

  if(both_active)
    {
     if(g_grid.buy_cycle_start>0 && g_grid.sell_cycle_start>0)
        try_buy_first = (g_grid.buy_cycle_start<=g_grid.sell_cycle_start);
     else
        try_buy_first = (g_grid.buy_levels>=g_grid.sell_levels);
     try_sell_first = !try_buy_first;
    }

  if(try_buy_first && g_grid.base_buy_lot>0.0)
    {
     if(ProcessGridDirection(POSITION_TYPE_BUY, g_grid.buy_levels, g_grid.base_buy_lot, atr_points, now))
        return;
    }

  if(try_sell_first && g_grid.base_sell_lot>0.0)
    {
     ProcessGridDirection(POSITION_TYPE_SELL, g_grid.sell_levels, g_grid.base_sell_lot, atr_points, now);
    }
  }
//+------------------------------------------------------------------+
//| Update grid state after position closures                         |
//+------------------------------------------------------------------+
void ResetGridStateIfNeeded()
  {
   SyncGridState();
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
bool PredictTradeOutcome(const SSignalDecision &decision,const ENUM_POSITION_TYPE direction,const double base_lot,double &adjusted_lot) // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   //--- enforce the 3-of-4 confirmation rule before looking at probabilities
   if(decision.confirmations_required>0 && decision.confirmed<decision.confirmations_required)
     {
      LogEvent("Trade skipped: insufficient indicator confirmations");
      return(false);
     }
   double normalized_base = AlignVolumeToBase(MathMax(base_lot, InpBaseLot)); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   double probability = decision.estimated_probability;
   double bootstrap_probability = EstimateBootstrapProbability(decision, direction); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(probability<bootstrap_probability)
      probability = bootstrap_probability; // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(g_learningCount<MIN_LEARNING_ACTIVATION)
      probability = MathMax(probability, 0.58); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(probability<=0.0)
      probability = 0.5;

   bool fully_confirmed = (decision.confirmed>=PATTERN_BIT_COUNT);             // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(fully_confirmed)                                                         // [v3.5 Update] Self-learning, cluster TP, and regression integration
     {
      adjusted_lot = normalized_base;                                          // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
      if(probability<InpProbabilityThreshold)                                  // [v3.5 Update] Self-learning, cluster TP, and regression integration
        {
         string dir_label = (direction==POSITION_TYPE_SELL ? "SELL" : "BUY"); // [v3.5 Update] Self-learning, cluster TP, and regression integration
         LogEvent(StringFormat("Full confirmation probability override: %s pattern %s prob=%.2f conf=%.2f", dir_label, decision.signal_pattern_id, probability, decision.confidence_score)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
        }
      return(true);
     }

   if(probability>=InpProbabilityThreshold)
     {
      adjusted_lot = normalized_base; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
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
   double lot_value = MathMax(normalized_base * scale, min_lot); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   if(lot_step>0.0)
      lot_value = MathFloor(lot_value/lot_step)*lot_step;
   lot_value = MathMax(lot_value, min_lot);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot_value>max_lot)
      lot_value = max_lot;
   adjusted_lot = AlignVolumeToBase(lot_value); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   LogEvent(StringFormat("Lot adjusted by probability %.2f -> scale %.2f", probability, scale));
   return(true);
  }
//+------------------------------------------------------------------+
double AdaptiveGridSpacing(const double atr_points)
  {
   double baseline = MathMax(1.0, InpGridStepPoints);
   double atr_reference = (atr_points>0.0 ? atr_points : baseline);
   double rsi_dev = ComputeRSIDeviation();
   double volume_dev = ComputeVolumeDeviation();
   double win_rate = RecentWinRate();

   double volatility_bias = atr_reference / baseline;
   volatility_bias = MathMax(0.85, MathMin(1.20, volatility_bias));

   double performance_bias = 1.0;
   if(win_rate>0.55)
      performance_bias -= MathMin(0.15, (win_rate-0.55)*0.5);
   else if(win_rate<0.45)
      performance_bias += MathMin(0.20, (0.45-win_rate)*0.6);
   performance_bias = MathMax(0.85, MathMin(1.20, performance_bias));

   double indicator_bias = 1.0 + MathMax(-0.12, MathMin(0.12, (rsi_dev + volume_dev) * 0.25));

   double adaptive = baseline * volatility_bias * performance_bias * indicator_bias;
   adaptive = MathMax(baseline*0.8, MathMin(baseline*1.2, adaptive));
   return(adaptive);
  }
//+------------------------------------------------------------------+
bool CollectDirectionMetrics(const ENUM_POSITION_TYPE direction,int &levels,double &base_lot,double &last_price,double &max_lot) // [v3.7 Update] Grid anchoring sync
  {
   levels = 0;
   base_lot = 0.0;
   max_lot  = 0.0;
   double min_volume = 0.0;
   datetime latest_time = 0;
   double latest_price = last_price;

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

      ENUM_POSITION_TYPE pos_type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(pos_type!=direction)
         continue;

      double volume = PositionGetDouble(POSITION_VOLUME);
      if(volume<=0.0)
         continue;

      levels++;
      if(min_volume==0.0 || volume<min_volume)
         min_volume = volume;
      if(volume>max_lot)
         max_lot = volume;

      datetime open_time = (datetime)PositionGetInteger(POSITION_TIME);
      double open_price = PositionGetDouble(POSITION_PRICE_OPEN);
      if(open_price>0.0 && (latest_time==0 || open_time>=latest_time))
        {
         latest_time  = open_time;
         latest_price = open_price;
        }
     }

   if(levels==0)
     {
      last_price = 0.0;
      base_lot   = 0.0;
      return(false);
     }

   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   int volume_digits = 2;
   if(lot_step>0.0)
     {
      double step = lot_step;
      volume_digits = 0;
      while(step<1.0 && volume_digits<8)
        {
         step *= 10.0;
         volume_digits++;
        }
     }

   double normalized_base = AlignVolumeToBase(MathMax(min_volume, InpBaseLot));
   if(max_lot>0.0)
      max_lot = AlignVolumeToBase(MathMax(max_lot, normalized_base));
   base_lot   = NormalizeDouble(normalized_base, volume_digits);
   last_price = latest_price;
   return(true);
  }
//+------------------------------------------------------------------+
void SyncGridState() // [v3.7 Update] Grid anchoring sync
  {
   double buy_base   = g_grid.base_buy_lot;
   double sell_base  = g_grid.base_sell_lot;
   double buy_price  = g_grid.last_buy_price;
   double sell_price = g_grid.last_sell_price;
   double buy_max    = g_grid.max_buy_lot;
   double sell_max   = g_grid.max_sell_lot;
   int buy_levels = 0;
   int sell_levels = 0;

  bool buy_active  = CollectDirectionMetrics(POSITION_TYPE_BUY, buy_levels, buy_base, buy_price, buy_max);
  bool sell_active = CollectDirectionMetrics(POSITION_TYPE_SELL, sell_levels, sell_base, sell_price, sell_max);

  if(buy_active)
    {
     g_grid.buy_levels = buy_levels;
     double base_candidate = AlignVolumeToBase(MathMax(buy_base, InpBaseLot));
     if(g_grid.anchor_buy_lot<=0.0 || base_candidate < g_grid.anchor_buy_lot-0.0000001)
        g_grid.anchor_buy_lot = base_candidate;
     g_grid.base_buy_lot   = AlignVolumeToBase(MathMax(g_grid.anchor_buy_lot, InpBaseLot));
     g_grid.max_buy_lot    = AlignVolumeToBase(MathMax(buy_max, g_grid.base_buy_lot));
     if(g_grid.anchor_buy_price<=0.0)
        g_grid.anchor_buy_price = buy_price;
     g_grid.last_buy_price = (buy_price>0.0 ? buy_price : g_grid.anchor_buy_price);
    }
  else
    {
     g_grid.buy_levels      = 0;
     g_grid.base_buy_lot    = 0.0;
     g_grid.last_buy_price  = 0.0;
     g_grid.base_buy_step   = 0.0;
     g_grid.anchor_buy_lot  = 0.0;
     g_grid.anchor_buy_price= 0.0;
     g_grid.max_buy_lot     = 0.0;
     g_grid.buy_cycle_start = 0;
    }

  if(sell_active)
    {
     g_grid.sell_levels = sell_levels;
     double base_candidate = AlignVolumeToBase(MathMax(sell_base, InpBaseLot));
     if(g_grid.anchor_sell_lot<=0.0 || base_candidate < g_grid.anchor_sell_lot-0.0000001)
        g_grid.anchor_sell_lot = base_candidate;
     g_grid.base_sell_lot  = AlignVolumeToBase(MathMax(g_grid.anchor_sell_lot, InpBaseLot));
     g_grid.max_sell_lot   = AlignVolumeToBase(MathMax(sell_max, g_grid.base_sell_lot));
     if(g_grid.anchor_sell_price<=0.0)
        g_grid.anchor_sell_price = sell_price;
     g_grid.last_sell_price = (sell_price>0.0 ? sell_price : g_grid.anchor_sell_price);
    }
  else
    {
     g_grid.sell_levels      = 0;
     g_grid.base_sell_lot    = 0.0;
     g_grid.last_sell_price  = 0.0;
     g_grid.base_sell_step   = 0.0;
     g_grid.anchor_sell_lot  = 0.0;
     g_grid.anchor_sell_price= 0.0;
     g_grid.max_sell_lot     = 0.0;
     g_grid.sell_cycle_start = 0;
    }
  }
//+------------------------------------------------------------------+
bool ProcessGridDirection(const ENUM_POSITION_TYPE direction,const int levels,const double base_lot,const double atr_points,const datetime now) // [v3.7 Update] Grid anchoring sync
  {
   if(levels<=0 || base_lot<=0.0)
      return(false);

   double baseline_step = NormalizeGridStep(InpGridStepPoints);
   double dynamic_reference = MathMax(atr_points, g_atrBuffer[0]/_Point);
   double dynamic_step_points = NormalizeGridStep(AdaptiveGridSpacing(dynamic_reference));

   int dynamic_start = MathMax(1, InpDynamicStepStart);
   bool use_dynamic = (levels >= dynamic_start);

   double cluster_step = use_dynamic ? dynamic_step_points : baseline_step;
   if(cluster_step<=0.0 || !MathIsValidNumber(cluster_step))
      cluster_step = baseline_step;
   cluster_step = NormalizeGridStep(cluster_step);

   if(direction==POSITION_TYPE_BUY)
      g_grid.base_buy_step = cluster_step;
   else
      g_grid.base_sell_step = cluster_step;

  double last_price = (direction==POSITION_TYPE_BUY ? (g_grid.last_buy_price>0.0 ? g_grid.last_buy_price : g_grid.anchor_buy_price)
                                                   : (g_grid.last_sell_price>0.0 ? g_grid.last_sell_price : g_grid.anchor_sell_price));
   if(last_price<=0.0)
      return(false);

   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(min_lot<=0.0)
      min_lot = (lot_step>0.0 ? lot_step : 0.01);
   if(max_lot<=0.0)
      max_lot = min_lot * 100.0;

  double anchor_lot = (direction==POSITION_TYPE_BUY ? g_grid.anchor_buy_lot : g_grid.anchor_sell_lot);
  if(anchor_lot<=0.0 || !MathIsValidNumber(anchor_lot))
     anchor_lot = base_lot;
  double normalized_anchor = AlignVolumeToBase(MathMax(anchor_lot, InpBaseLot));
  double cycle_floor = MathMax(MathMax(normalized_anchor, InpBaseLot), min_lot);
  double normalized_base = AlignVolumeToBase(cycle_floor);

   double current_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double current_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(direction==POSITION_TYPE_BUY)
     {
      double trigger_price = last_price - cluster_step * _Point;
      if(current_bid>trigger_price)
         return(false);
     }
   else
     {
      double trigger_price = last_price + cluster_step * _Point;
      if(current_ask<trigger_price)
         return(false);
     }

   if(levels>=InpMaxGridLevels)
      return(false);

   if((now - g_lastGridAttemptTime) < 2)
      return(false);

   int volume_digits = 2;
   if(lot_step>0.0)
     {
      double step = lot_step;
      volume_digits = 0;
      while(step<1.0 && volume_digits<8)
        {
         step *= 10.0;
        volume_digits++;
       }
     }

   double lot = normalized_base;
   lot = MathMax(min_lot, MathMin(max_lot, lot));
   lot = NormalizeDouble(lot, volume_digits);

   g_tradeAttemptPending = true;
   g_lastTradeAttemptTime = now;
   g_lastGridAttemptTime  = now;

   bool trade_result = false;
   if(direction==POSITION_TYPE_BUY)
      trade_result = g_trade.Buy(lot, _Symbol, 0.0, 0.0, 0.0, "Grid BUY");
   else
      trade_result = g_trade.Sell(lot, _Symbol, 0.0, 0.0, 0.0, "Grid SELL");

   if(!trade_result)
     {
      g_tradeAttemptPending = false;
      return(false);
     }

   string dir_label = (direction==POSITION_TYPE_BUY ? "BUY" : "SELL");
   string step_mode = use_dynamic ? "dynamic" : "static";
   LogEvent(StringFormat("Grid %s level %d opened lot=%.2f anchor=%.3f step=%.1f mode=%s",
                         dir_label, levels+1, lot, normalized_anchor, cluster_step, step_mode));

   SPatternCandidate candidate;
   if(direction==POSITION_TYPE_BUY)
     {
      candidate.direction      = POSITION_TYPE_BUY;
      candidate.pattern_index  = g_buyDecision.pattern_index;
      candidate.probability    = g_buyDecision.estimated_probability;
      candidate.fast_ma        = g_buyDecision.fast_ma;
      candidate.slow_ma        = g_buyDecision.slow_ma;
      candidate.rsi            = g_buyDecision.rsi;
      candidate.mfi            = g_buyDecision.mfi;
      candidate.volume         = g_buyDecision.volume;
      candidate.volume_ratio   = g_buyDecision.volume_ratio;
      candidate.atr_points     = g_buyDecision.atr_points;
      candidate.signal_pattern_id = g_buyDecision.signal_pattern_id;
      candidate.win_probability   = g_buyDecision.estimated_probability;
      candidate.confidence_score  = g_buyDecision.confidence_score;
     }
   else
     {
      candidate.direction      = POSITION_TYPE_SELL;
      candidate.pattern_index  = g_sellDecision.pattern_index;
      candidate.probability    = g_sellDecision.estimated_probability;
      candidate.fast_ma        = g_sellDecision.fast_ma;
      candidate.slow_ma        = g_sellDecision.slow_ma;
      candidate.rsi            = g_sellDecision.rsi;
      candidate.mfi            = g_sellDecision.mfi;
      candidate.volume         = g_sellDecision.volume;
      candidate.volume_ratio   = g_sellDecision.volume_ratio;
      candidate.atr_points     = g_sellDecision.atr_points;
      candidate.signal_pattern_id = g_sellDecision.signal_pattern_id;
      candidate.win_probability   = g_sellDecision.estimated_probability;
      candidate.confidence_score  = g_sellDecision.confidence_score;
     }

   candidate.grid_level     = levels + 1;
   candidate.confirmations  = (direction==POSITION_TYPE_BUY ? g_buyDecision.confirmed : g_sellDecision.confirmed);
   candidate.lot_size       = lot;
   candidate.pattern_mask   = (direction==POSITION_TYPE_BUY ? g_buyDecision.pattern_mask : g_sellDecision.pattern_mask);
   candidate.open_time      = TimeCurrent();
   candidate.equity_before  = AccountInfoDouble(ACCOUNT_EQUITY);
   candidate.equity_peak    = candidate.equity_before;
   candidate.equity_trough  = candidate.equity_before;
   candidate.is_grid        = true;

   PushPendingPattern(candidate);
   return(true);
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
   if(record.win_probability<=0.0) // [v3.5 Update] Self-learning, cluster TP, and regression integration
      record.win_probability = (profit>=0.0 ? 0.65 : 0.45); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   record.confidence_score  = (context.confidence_score>0.0 ? context.confidence_score : ComputePatternConfidence(context.direction, context.pattern_index));  // [v3.5 Update] Self-learning, cluster TP, and regression integration
   record.win_probability   = MathMax(0.05, MathMin(0.95, record.win_probability)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   record.confidence_score  = MathMax(0.0, MathMin(1.0, record.confidence_score)); // [v3.5 Update] Self-learning, cluster TP, and regression integration

  AppendLearningRecord(record);
  LogLearningEvent(StringFormat("Pattern learned: ID=%s, WinProb=%.2f, Conf=%.2f", record.signal_pattern_id, record.win_probability, record.confidence_score)); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability

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

  if(g_learningCount >= MAX_LEARNING_RECORDS)
    {
     g_learningCount = MAX_LEARNING_RECORDS - 1; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
     g_learningHead = (g_learningHead + 1) % capacity; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
    }

  int insert_index = (g_learningHead + g_learningCount) % capacity; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
  g_learningRecords[insert_index] = record;
  g_learningCount++; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability

  int closed_trades = SafeClosedTradeCount();
  bool learning_active = (closed_trades>=MIN_LEARNING_CLOSED_TRADES); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
  bool hit_activation = (g_learningCount==MIN_LEARNING_ACTIVATION); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability

   TrimLearningBuffer();

  if(!persist)
     return;

  if(hit_activation)
     LogLearningEvent("Learning activated", true);

  if(learning_active)
    {
     RecalculateRecentMetrics();
     UpdateProbabilityModel();
     RefreshLearningProbabilities();
    }

  SaveLearningData();
  SaveState();

  if(learning_active)
    {
     LogLearningEvent("Learning updated", true);
     LogLearningEvent(StringFormat("Learning updated: records=%d", g_learningCount));
    }

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
   if(IsStopped())
      return(false); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

   if(g_learningCount<MIN_LEARNING_ACTIVATION)
      return(false);

   if(!g_regressionModel.initialized)
      InitializeRegressionModel();

   int closed_trades = SafeClosedTradeCount();
   if(closed_trades<MIN_LEARNING_CLOSED_TRADES)
      return(false); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

   if((closed_trades % REGRESSION_RETRAIN_STEP)!=0)
      return(false); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

   int trades_since_update = closed_trades - g_regressionModel.last_update_trades; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
   if(trades_since_update < REGRESSION_RETRAIN_STEP)
      return(false);

   if(g_regressionModel.last_update_trades==closed_trades)
      return(false); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

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
         if(IsStopped())
            break; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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
   closed_trades = SafeClosedTradeCount();
   g_regressionModel.last_update_trades = closed_trades; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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
     if(IsStopped())
        break; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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

   LogLearningEvent(StringFormat("Learning retrained at trade #%d", closed_trades), true); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   LogLearningEvent("Regression updated", true);
   LogLearningEvent(StringFormat("Regression updated: coeff_rsi=%.3f, coeff_mfi=%.3f, coeff_ma=%.3f, coeff_vol=%.3f", b1, b2, b3, b4), true); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   LogLearningEvent(StringFormat("Regression summary: trades=%d, winRate=%.2f, confidence=%.2f", sample_count, win_rate, g_regressionModel.dynamic_confidence), true); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
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
      double prior_prob = (record.win_probability>0.0 ? record.win_probability : (record.result>0 ? 0.65 : 0.35)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      double confidence = ComputePatternConfidence(direction, record.pattern_index);
      double regression_conf = g_regressionModel.dynamic_confidence; // [v3.5 Update] Self-learning, cluster TP, and regression integration
      double smoothing = MathMax(0.25, MathMin(0.75, regression_conf + 0.25)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      double outcome_bias = (record.result>0 ? 0.03 : -0.03); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      double target_prob = MathMax(0.05, MathMin(0.95, 0.6 * blended + 0.4 * prior_prob + outcome_bias)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      record.win_probability = prior_prob + (target_prob - prior_prob) * smoothing * 0.5; // [v3.5 Update] Self-learning, cluster TP, and regression integration
      record.win_probability = MathMax(0.05, MathMin(0.95, record.win_probability)); // [v3.5 Update] Self-learning, cluster TP, and regression integration

      double base_conf = (record.confidence_score>0.0 ? record.confidence_score : confidence); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      double combined_conf = 0.5 * base_conf + 0.5 * regression_conf; // [v3.5 Update] Self-learning, cluster TP, and regression integration
      if(record.result>0)
         combined_conf = MathMin(1.0, combined_conf + 0.05); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      else
         combined_conf = MathMax(0.0, combined_conf - 0.05); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      record.confidence_score = base_conf + (combined_conf - base_conf) * smoothing; // [v3.5 Update] Self-learning, cluster TP, and regression integration
      record.confidence_score = MathMax(0.0, MathMin(1.0, record.confidence_score)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
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
double EstimateBootstrapProbability(const SSignalDecision &decision,const ENUM_POSITION_TYPE direction) // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   int confirmations = MathMax(0, MathMin(PATTERN_BIT_COUNT, decision.confirmed)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double regression = (decision.regression_probability>0.0 ? decision.regression_probability : 0.5); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double base = 0.52 + (regression - 0.5) * 0.6; // [v3.5 Update] Self-learning, cluster TP, and regression integration
   base += 0.08 * MathMax(0, confirmations - 2); // [v3.5 Update] Self-learning, cluster TP, and regression integration

   double ma_strength = MathMax(-1.0, MathMin(1.0, decision.ma_strength)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   base += ma_strength * 0.08; // [v3.5 Update] Self-learning, cluster TP, and regression integration

   double volume_ratio = MathMax(0.1, MathMin(3.0, decision.volume_ratio)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(volume_ratio>1.05)
      base += MathMin(0.08, (volume_ratio-1.0)*0.05); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   else if(volume_ratio<0.95)
      base -= MathMin(0.08, (1.0-volume_ratio)*0.05); // [v3.5 Update] Self-learning, cluster TP, and regression integration

   if(direction==POSITION_TYPE_BUY)
     {
      if(decision.fast_ma>decision.slow_ma)
         base += 0.05; // [v3.5 Update] Self-learning, cluster TP, and regression integration
      if(decision.rsi<=g_params.rsi_oversold)
         base += 0.05; // [v3.5 Update] Self-learning, cluster TP, and regression integration
      if(decision.mfi<=g_params.mfi_oversold)
         base += 0.04; // [v3.5 Update] Self-learning, cluster TP, and regression integration
     }
   else
     {
      if(decision.fast_ma<decision.slow_ma)
         base += 0.05; // [v3.5 Update] Self-learning, cluster TP, and regression integration
      if(decision.rsi>=g_params.rsi_overbought)
         base += 0.05; // [v3.5 Update] Self-learning, cluster TP, and regression integration
      if(decision.mfi>=g_params.mfi_overbought)
         base += 0.04; // [v3.5 Update] Self-learning, cluster TP, and regression integration
     }

   return(MathMax(0.35, MathMin(0.92, base))); // [v3.5 Update] Self-learning, cluster TP, and regression integration
  }
//+------------------------------------------------------------------+
double EstimateBootstrapConfidence(const SSignalDecision &decision,const ENUM_POSITION_TYPE direction) // [v3.5 Update] Self-learning, cluster TP, and regression integration
  {
   double probability_hint = EstimateBootstrapProbability(decision, direction); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   int confirmations = MathMax(0, MathMin(PATTERN_BIT_COUNT, decision.confirmed)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double confidence = 0.46 + 0.07 * MathMax(0, confirmations - 2); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   confidence += MathMin(0.12, MathAbs(probability_hint-0.5)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double regression_conf = g_regressionModel.dynamic_confidence; // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(regression_conf>0.0)
      confidence = MathMax(confidence, 0.45 + (regression_conf-0.5)*0.6); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   return(MathMax(0.35, MathMin(0.90, confidence))); // [v3.5 Update] Self-learning, cluster TP, and regression integration
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
   double weight_sum = 0.0;
   double conf_sum = 0.0;
   double conf_weight = 0.0;
   int matches = 0;
   double last_prob = 0.0;
   double last_conf = 0.0;
   int last_pattern = 0;
   ENUM_POSITION_TYPE last_direction = POSITION_TYPE_BUY;

   int collected = 0;
   for(int ordinal=g_learningCount-1; ordinal>=0 && collected<PATTERN_LOOKBACK_WINDOW; ordinal--)
     {
      SLearningRecord record;
      if(!GetLearningRecord(ordinal, record))
         continue;
      if(StringCompare(record.signal_pattern_id, pattern_id)!=0)
         continue;
      collected++;
      matches++;
      double rec_prob = (record.win_probability>0.0 ? record.win_probability : (record.result>0 ? 0.65 : 0.35)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      double rec_conf = (record.confidence_score>0.0 ? record.confidence_score : 0.0); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      double weight = 1.0 + MathMax(0.0, rec_conf); // [v3.5 Update] Self-learning, cluster TP, and regression integration
      prob_sum += rec_prob * weight; // [v3.5 Update] Self-learning, cluster TP, and regression integration
      weight_sum += weight; // [v3.5 Update] Self-learning, cluster TP, and regression integration
      if(rec_conf>0.0)
        {
         conf_sum += rec_conf; // [v3.5 Update] Self-learning, cluster TP, and regression integration
         conf_weight += 1.0; // [v3.5 Update] Self-learning, cluster TP, and regression integration
         last_conf = rec_conf; // [v3.5 Update] Self-learning, cluster TP, and regression integration
        }
      last_prob = rec_prob;
      last_pattern = record.pattern_index;
      last_direction = (StringFind(SafeToUpper(record.signal_type), "SELL")!=-1) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
     }

   if(matches==0)
      return(false);

   double avg_prob = (weight_sum>0.0 ? prob_sum/MathMax(weight_sum, 0.0001) : last_prob); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double avg_conf = (conf_weight>0.0 ? conf_sum/conf_weight : last_conf); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(avg_conf<=0.0)
      avg_conf = ComputePatternConfidence(last_direction, last_pattern); // [v3.5 Update] Self-learning, cluster TP, and regression integration

   int dir_index = (last_direction==POSITION_TYPE_SELL ? 1 : 0); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   int bounded_pattern = MathMax(0, MathMin(PATTERN_COMBINATIONS-1, last_pattern)); // [v3.5 Update] Self-learning, cluster TP, and regression integration
   double model_prob = g_patternModel[dir_index][bounded_pattern].probability; // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(model_prob>0.0)
      avg_prob = 0.7 * avg_prob + 0.3 * MathMax(avg_prob, model_prob); // [v3.5 Update] Self-learning, cluster TP, and regression integration

   double regression_bias = g_regressionModel.dynamic_confidence - 0.5; // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(MathAbs(regression_bias)>0.0001)
      avg_prob = MathMax(0.05, MathMin(0.95, avg_prob + regression_bias * 0.08)); // [v3.5 Update] Self-learning, cluster TP, and regression integration

   double dynamic_conf = g_regressionModel.dynamic_confidence; // [v3.5 Update] Self-learning, cluster TP, and regression integration
   if(dynamic_conf>0.0)
      avg_conf = MathMax(avg_conf, 0.5*avg_conf + 0.5*dynamic_conf); // [v3.5 Update] Self-learning, cluster TP, and regression integration

   win_probability = MathMax(0.05, MathMin(0.95, avg_prob));
   confidence = MathMax(0.0, MathMin(1.0, avg_conf));
   return(true);
  }
//+------------------------------------------------------------------+
bool ConfirmPatternForEntry(SSignalDecision &decision,const ENUM_POSITION_TYPE direction)
  {
   if(decision.confirmations_required>0 && decision.confirmed<decision.confirmations_required)
      return(false);

   bool partial_confirmation = (decision.confirmed==decision.confirmations_required && decision.confirmed<PATTERN_BIT_COUNT);
   bool full_confirmation = (decision.confirmed>=PATTERN_BIT_COUNT);
   double bootstrap_probability = EstimateBootstrapProbability(decision, direction);
   double bootstrap_confidence = EstimateBootstrapConfidence(decision, direction);
   bool learning_active = (SafeClosedTradeCount()>=MIN_LEARNING_CLOSED_TRADES);

   if(g_learningCount==0)
     {
      if(partial_confirmation)
        {
         if(bootstrap_probability>=0.60 && bootstrap_confidence>=0.50)
           {
            decision.estimated_probability = MathMax(decision.estimated_probability, bootstrap_probability);
            decision.confidence_score = MathMax(decision.confidence_score, bootstrap_confidence);
            LogEvent(StringFormat("Bootstrap trade approval: prob=%.2f conf=%.2f", bootstrap_probability, bootstrap_confidence));
            return(true);
           }
         LogEvent("Trade skipped: learning cache empty for partial confirmation");
         return(false);
        }
      decision.estimated_probability = MathMax(decision.estimated_probability, bootstrap_probability);
      decision.confidence_score = MathMax(decision.confidence_score, bootstrap_confidence);
      return(true);
     }

   double stored_probability = 0.0;
   double stored_confidence = 0.0;
   bool has_history = QueryPatternFromLearning(decision.signal_pattern_id, stored_probability, stored_confidence);

   if(learning_active)
     {
      if(!has_history)
        {
         string dir_label = (direction==POSITION_TYPE_SELL ? "SELL" : "BUY");
         LogEvent(StringFormat("Trade skipped: pattern %s (%s) missing from learning cache", decision.signal_pattern_id, dir_label));
         return(false);
        }
      decision.estimated_probability = MathMax(decision.estimated_probability, stored_probability);
      decision.confidence_score = MathMax(decision.confidence_score, stored_confidence);
      if(decision.estimated_probability>=0.60 && decision.confidence_score>=0.50)
         return(true);
      LogLearningEvent(StringFormat("Pattern %s rejected: WinProb=%.2f, Conf=%.2f", decision.signal_pattern_id, decision.estimated_probability, decision.confidence_score), true);
      return(false);
     }

   if(!has_history)
     {
      if(full_confirmation)
        {
         decision.estimated_probability = MathMax(MathMax(decision.estimated_probability, bootstrap_probability), 0.60);
         double full_conf = MathMax(MathMax(decision.confidence_score, bootstrap_confidence), 0.55);
         decision.confidence_score = MathMin(1.0, full_conf);
         if(InpVerboseLogging)
            LogEvent(StringFormat("Full confirmation override: pattern %s prob=%.2f conf=%.2f", decision.signal_pattern_id, decision.estimated_probability, decision.confidence_score));
         return(true);
        }
      if(bootstrap_probability>=0.60 && bootstrap_confidence>=0.50)
        {
         decision.estimated_probability = MathMax(decision.estimated_probability, bootstrap_probability);
         decision.confidence_score = MathMax(decision.confidence_score, bootstrap_confidence);
         LogEvent(StringFormat("Bootstrap trade approval: pattern %s prob=%.2f conf=%.2f", decision.signal_pattern_id, bootstrap_probability, bootstrap_confidence));
         return(true);
        }
      string dir_label = (direction==POSITION_TYPE_SELL ? "SELL" : "BUY");
      LogEvent(StringFormat("Trade skipped: pattern %s (%s) not in learning cache", decision.signal_pattern_id, dir_label));
      return(false);
     }

   decision.estimated_probability = MathMax(MathMax(decision.estimated_probability, stored_probability), bootstrap_probability);
   decision.confidence_score = MathMax(MathMax(decision.confidence_score, stored_confidence), bootstrap_confidence);

   if(!partial_confirmation)
     {
      decision.estimated_probability = MathMax(decision.estimated_probability, 0.60);
      decision.confidence_score = MathMin(1.0, MathMax(decision.confidence_score, 0.55));
      if(InpVerboseLogging)
        {
         string dir_label3 = (direction==POSITION_TYPE_SELL ? "SELL" : "BUY");
         LogEvent(StringFormat("Full confirmation override: pattern %s (%s) prob=%.2f conf=%.2f", decision.signal_pattern_id, dir_label3, decision.estimated_probability, decision.confidence_score));
        }
      return(true);
     }

   if(decision.estimated_probability>=0.60 && decision.confidence_score>=0.50)
      return(true);

   LogLearningEvent(StringFormat("Pattern %s rejected: WinProb=%.2f, Conf=%.2f", decision.signal_pattern_id, decision.estimated_probability, decision.confidence_score), true);
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
   LogEvent(StringFormat("Probability model refreshed: winRate=%.2f avgWin=%.2f avgLoss=%.2f samples=%d", win_rate, avg_win, avg_loss, total_samples), true); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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

   string header_fields[];
   bool has_closed_trades = false; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

   // parse header line
   if(!FileIsEnding(handle))
     {
      while(true)
        {
         string field = FileReadString(handle);
         int idx = ArraySize(header_fields);
         ArrayResize(header_fields, idx+1);
         header_fields[idx] = field;
         if(StringCompare(field, "ClosedTrades")==0)
            has_closed_trades = true; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
         if(FileIsLineEnding(handle) || FileIsEnding(handle))
            break;
        }
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
      if(has_closed_trades)
         g_stats.closed_trades  = (ulong)FileReadNumber(handle); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
      g_stats.total_wins         = (ulong)FileReadNumber(handle);
      g_stats.total_losses       = (ulong)FileReadNumber(handle);
      g_stats.total_profit       = FileReadNumber(handle);
     }
   if(!has_closed_trades)
      g_stats.closed_trades = 0; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

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
   if(g_stats.closed_trades>g_stats.total_trades)
      g_stats.closed_trades = g_stats.total_trades; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
   if(g_stats.closed_trades==0 && g_stats.total_trades>0 && g_learningCount>0)
      g_stats.closed_trades = MathMin(g_stats.total_trades, (ulong)g_learningCount); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

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
             "TotalTrades","ClosedTrades","TotalWins","TotalLosses","TotalProfit"); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

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
             g_stats.closed_trades,
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
                         learningRate), true); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

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
    LogEvent(report, true); // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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
   if(IsStopped())
      return; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
   int handle = FileOpen(g_learningFileName, FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(handle==INVALID_HANDLE)
      return;

   FileWrite(handle,
             "TradeID","Symbol","DateTime","FastMA","SlowMA","RSI","MFI","Volume", // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
             "Profit","WinLoss","GridLevel","ATR","SignalType","Result",
             "EquityBefore","EquityAfter","DurationSec","DrawdownPct","TradeType","PatternIndex",
             "SignalPatternID","WinProbability","ConfidenceScore");

    for(int ordinal=0; ordinal<g_learningCount; ordinal++)
      {
      if(IsStopped())
         break; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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
void LogLearningEvent(const string message,const bool essential) // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
  {
   if(!essential && !InpVerboseLearning)
      return; // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   bool escalate = (essential || !InpVerboseLogging); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
   LogEvent(message, escalate); // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability
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
void LogEvent(const string message,const bool essential)
  {
   if(!essential && !InpVerboseLogging)
      return; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
   if(IsStopped() && !essential)
      return; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety

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
   if(IsStopped())
      return; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
   string detail = StringFormat("Indicators fastMA=%.5f slowMA=%.5f RSI=%.2f MFI=%.2f Volume=%.0f ATR=%.1f",
                               g_fastMABuffer[0], g_slowMABuffer[0], g_rsiBuffer[0], g_mfiBuffer[0], g_volBuffer[0], g_atrBuffer[0]);
   LogEvent(detail);
  }
//+------------------------------------------------------------------+
void LogTrade(const ulong deal_ticket, const double deal_profit, const string direction)
  {
   if(IsStopped())
      return; // [v3.6 Stability Fix] Improved tick handling, learning I/O, and context safety
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
