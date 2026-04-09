# Frontline RSI 经验 → `ai/xauusd_m15` 特征映射

本文把 `frontline/MQL5/_united/Strategies` 里与 RSI 相关的**可量化**逻辑，映射到训练用的 **24 维特征**（前 13 维与原版 EA 一致，后 11 维为 RSI/时段扩展）。

## 策略来源与特征对应

| Frontline 模块 | 经验要点 | 模型中的体现 |
|----------------|----------|----------------|
| **RSIReversalAsianStrategy** | 上穿超买 / 下穿超卖的**交叉**；亚洲时段（UTC 0–8）语境 | `rsi_cross_overbought` / `rsi_cross_oversold`（默认 70/30）；`session_asian_utc` |
| **RSICrossOverReversalStrategy** | 超买/超卖区附近的**反转入场**、RSI 退出位 | 交叉特征 + `rsi_velocity` / `rsi_accel` 描述短期摆动 |
| **RSIScalpingStrategy** | 极值区外的**回升/回落**（多根 RSI 结构） | `rsi_velocity`、`rsi_accel`（3 根 RSI14 近似） |
| **RSIMidPointHijackStrategy** | 相对 **50** 中轴、快慢 RSI 状态 | `rsi_dist_mid_50`；`rsi_fast_slow_spread`（RSI14 vs RSI7） |
| **多品种 RSI Scalping** | 更短周期敏感 | `rsi7_n`（快周期）、`rsi21_n`（慢周期） |

## 特征索引（与 Python / EA 顺序一致）

| 索引 | 名称 | 说明 |
|------|------|------|
| 0–4 | OHLC + tick_volume | 与原版一致 |
| 5 | rsi | Wilder RSI(14)/100 |
| 6–12 | EMA/ATR/价量 | 与原版一致 |
| 13 | rsi7_n | RSI(7)/100 |
| 14 | rsi21_n | RSI(21)/100 |
| 15 | rsi_fast_slow_spread | clip((RSI14−RSI7)/50, −1, 1) |
| 16 | rsi_velocity | (RSI14₀−RSI14₁)/25 |
| 17 | rsi_accel | ((RSI14₀−RSI14₁)−(RSI14₁−RSI14₂))/25 |
| 18 | rsi_dist_mid_50 | \|RSI14−50\|/50 |
| 19–22 | cross_* | 0/1，与 frontline 交叉定义一致（上一根→当前根） |
| 23 | session_asian_utc | 小时经偏移后 ∈ [0,8) 则为 1 |

## 时段偏移

MT5 K 线时间多为**服务器时区**。若要与 UTC 亚洲窗对齐，训练时设环境变量 `SESSION_HOUR_OFFSET`，EA 使用 `InpSessionHourOffset`，使 `(hour + offset) % 24` 与你在回测里认定的 UTC 一致。

## 未直接编码的规则（可后续扩展）

- **点差、最大持仓时长、Magic 分策略**：可作为额外标量特征或单独过滤层。
- **RSIMidPoint 的「先标记超买再下穿退出线」**：可用连续两 bar 的 cross 组合特征或 LSTM 隐式学习；当前用 cross + dist_mid 近似。
- **Darvas / EMA 等非 RSI 策略**：未并入本 ONNX 特征；可在 `features.py` 中追加列并同步改 `NUM_FEATURES` 与 EA。

## 再训练提醒

修改 `NUM_FEATURES` 后必须：**重新导出 ONNX**、更新 EA 中 `#resource` 模型、`OnnxSetInputShape` 第三维、**24 个 scaler min/max**。
