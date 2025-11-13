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
5. Review and adjust the EA inputs directly in MetaTrader to match your risk profile before running tests or going live.

---

## Trading Workflow

1. **Signal Detection** – Indicators update once per bar. If ≥3 components agree, a candidate trade is formed with a unique pattern mask.
2. **Probability & Lot Sizing** – The regression model projects win probability and confidence. Lots are computed from risk settings, clamped to `InpBaseLot`, and scaled by confidence when applicable.
3. **Trade Management** – The EA enters trades sequentially per direction. Grid recoveries respect the stored anchor lot/price and the configured step. You can defer adaptive spacing until a basket builds up by adjusting `InpDynamicStepStart`; early levels use the static `InpGridStepPoints`, while later ones switch to the adaptive ATR/indicator spacing. No hard stop-losses are placed; exits rely on virtual cluster profit targets.
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
