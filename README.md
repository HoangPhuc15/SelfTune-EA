# SelfTune-EA v3.7 Adaptive Cluster

> // [v3.7 Update] BaseLot, AdaptiveClusterTP, LearningFix, Regression, Stability

SelfTune-EA v3.7 is a probabilistic, self-learning grid Expert Advisor for MetaTrader 5. It combines multi-indicator pattern detection, adaptive regression-based probability scoring, and a virtual take-profit cluster manager that can close baskets partially while respecting a configurable base lot size.

The EA is designed for **Every Tick** backtests and live trading on **hedging** accounts. It automatically retrains on recent trade history, adjusts recovery behavior based on model confidence, and enforces stability safeguards (file I/O throttling, trade context locks, Sleep(10) inside loops).

---

## Quick Start

1. Copy `SelfTune-EA_v3.7_AdaptiveCluster.mq5` to the `MQL5/Experts` folder of your MetaTrader 5 data directory.
2. Compile the EA in MetaEditor (F7).
3. Attach the EA to a symbol chart using the **Every Tick** modelling mode for backtests.
4. Set account type to hedging and enable algorithmic trading.
5. Adjust the input parameters according to the sections below.

---

## Input Parameters

The EA exposes its configuration through grouped input sections. Each parameter is listed with its purpose, default, and notes on interactions with other settings.

### Trend Filters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpMAType` | `MODE_EMA` | Moving-average calculation method (Simple, Exponential, Smoothed, Linear Weighted). |
| `InpMAPrice` | `PRICE_CLOSE` | Price source for all moving averages (close, open, median, etc.). |
| `InpFastMAPeriod` | `21` | Period for the fast trend MA; affects crossover patterns. |
| `InpSlowMAPeriod` | `55` | Period for the slow trend MA. Slower values smooth trend signals but increase lag. |
| `InpRSIPeriod` | `14` | Period used when calculating RSI-based overbought/oversold levels. |
| `InpRSIOversold` | `35.0` | RSI threshold triggering bullish contributions to the pattern mask. |
| `InpRSIOverbought` | `65.0` | RSI threshold triggering bearish contributions to the pattern mask. |
| `InpMFIPeriod` | `14` | Period for Money Flow Index calculations. |
| `InpMFIOversold` | `35.0` | MFI value considered oversold. |
| `InpMFIOverbought` | `65.0` | MFI value considered overbought. |
| `InpVolumePeriod` | `34` | Lookback window for normalized volume averaging. |
| `InpVolumeMultiplier` | `1.20` | Multiplier applied to baseline volume to flag high-activity conditions. |

> **Pattern Logic:** At least **3 of the 4** indicators (MA slope, RSI state, MFI state, volume impulse) must align for a trade idea. The resulting bitmask is converted into a `SignalPatternID` which the learning engine uses for probability lookups.

### Risk Management

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpRiskPerTrade` | `1.0` | Percentage of current equity risked on a fresh trade when no fixed lot is supplied. Drives the ATR-based position sizing logic. |
| `InpInitialLot` | `0.0` | Optional fixed lot baseline. When set > 0, it overrides risk-based sizing for the first order of a direction. |
| `InpBaseLot` | `0.01` | **Minimum starting lot** per cycle. All initial trades and grid recoveries are clamped to this floor even after confidence scaling. |
| `InpMaxDrawdown` | `20.0` | Equity drawdown percentage that pauses trading for the remainder of the session. |
| `InpDailyLoss` | `5.0` | Daily loss threshold; once breached, no new positions are opened until the next trading day. |
| `InpATRMultiplierTP` | `4.5` | Multiplier applied to ATR for baseline (non-cluster) virtual targets and trailing logic. |
| `InpATRPeriod` | `14` | ATR period used in the risk and TP calculations. |

### Virtual Take-Profit Cluster (Adaptive Basket Exit)

| Parameter | Default | Description |
|-----------|---------|-------------|
| `VirtualTPPoints` | `80` | Base profit (in points) required for a basket to close. Virtual TP replaces fixed SL/TP for grid baskets. |
| `ReduceTPPerOrder` | `14` | Amount (points) subtracted from the virtual TP for each additional order in the cluster, producing faster exits for later grid levels. |
| `AllowOverlapRecovery` | `true` | When enabled, retains a configurable number of the newest orders after a partial cluster exit to continue recovery. |
| `OverlapAfterOrders` | `3` | Number of orders allowed to persist after a partial close when `AllowOverlapRecovery` is true. |

> The EA scales the virtual TP by ±20–30% depending on `WinProbability` (≥0.75 increases the target by 20%, ≤0.55 cuts it by 30%). Logs include `Adaptive TP adjusted` and `Cluster closed` events detailing realized profit.

### Grid Control

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpUseGrid` | `true` | Master toggle for grid recovery. When false, only single trades are taken per signal. |
| `InpMaxGridLevels` | `4` | Maximum number of additional orders per direction (excluding the initial entry). |
| `InpGridStepPoints` | `350` | Baseline spacing (points) between successive grid orders. Adaptive logic may nudge spacing but keeps it anchored to this value. |
| `InpGridMultiplier` | `1.35` | Lot scaling multiplier for each new grid order. Combined with `InpBaseLot` to cap minimum size. |

### Adaptive Learning & Probability Controls

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpTradesPerTune` | `700` | Size of the rolling dataset maintained on disk. Older samples are dropped beyond this limit. |
| `InpAllowParamDecrease` | `true` | Permits the tuning engine to decrease indicator periods during optimization cycles. |
| `InpProbabilityThreshold` | `0.68` | Minimum predicted win probability required to open a new position (after the warm-up phase). |
| `InpConfidenceFloor` | `0.35` | Minimum confidence score; low confidence shrinks lot sizes and may block trades if combined with poor probabilities. |

> Learning starts after **100 closed trades** and retrains every **20 trades** thereafter. The dataset header is `TradeID,DateTime,SignalPatternID,WinProbability,ConfidenceScore,Profit,Result`. The EA logs `Learning activated`, `Learning updated`, and `Regression updated` when those events occur.

### Logging

| Parameter | Default | Description |
|-----------|---------|-------------|
| `InpVerboseLogging` | `true` | Enables detailed console output for trade management, clustering, and model updates. |
| `InpLogIndicators` | `false` | Records indicator snapshots when trades open (useful for debugging but heavier on logs). |
| `InpVerboseLearning` | `false` | Extends learning-related logs with per-pattern summaries and regression coefficients. |

---

## Trading Workflow

1. **Signal Detection** – Indicators update once per bar. If ≥3 components agree, a candidate trade is formed with a unique pattern mask.
2. **Probability & Lot Sizing** – The regression model projects win probability and confidence. Lots are computed from risk settings, clamped to `InpBaseLot`, and scaled by confidence when applicable.
3. **Trade Management** – The EA enters trades sequentially per direction. Grid recoveries respect the stored anchor lot/price and the configured step. No hard stop-losses are placed; exits rely on virtual cluster profit targets.
4. **Cluster Handling** – Basket profit is monitored on every tick. When the adaptive target is hit, the EA closes the oldest orders first, optionally leaving overlap positions to continue recovery.
5. **Learning Cycle** – On every trade close, the EA appends trade data to the dataset. After 100 closed trades, it activates learning, retraining regression coefficients every 20 trades.

---

## Files & Logs

- **Learning dataset** – Stored under `MQL5/Files` with the header listed above. Contains up to 700 of the most recent closed trades.
- **Logs** – MetaTrader's Experts log will contain status messages (learning updates, adaptive TP changes, grid actions). Enable `InpVerboseLearning` for coefficient dumps.

---

## Best Practices

- **Backtest in Every Tick mode** to verify stability and performance before deploying live.
- **Start with low risk** and verify that lot scaling remains within broker constraints.
- **Monitor the dataset file size**; if you delete it, the EA will rebuild the learning history from scratch.
- **Use VPS hosting** if running 24/7 to ensure low latency and avoid interruptions during learning updates.

---

## Disclaimer

Automated trading carries significant risk. Past performance does not guarantee future results. Test thoroughly on demo accounts before trading live capital.
