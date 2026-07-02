# RSIScalpingSuper — 多品种 Super EA

9 个品种 H1 RSI Scalping 组合：**EURUSD GBPUSD USDJPY AUDUSD USDCHF USDCAD NZDUSD EURJPY XAUUSD**

每个品种独立 magic、独立 RSI 参数（MT5 遗传算法 2004–2026 优化）。

## MT5 组合回测

```powershell
cd lab\EAs\RSIScalpingAdaptive

# 编译 + 启动 MT5 Strategy Tester（9 品种组合）
python run_mt5_tester.py backtest --expert super --symbol EURUSD --from 2004.01.01 --to 2026.01.01
```

手动测试：
1. 专家：`RSIScalpingAdaptive\SuperEA.ex5`（或 `RSIScalpingSuper.ex5`）
2. 挂到 **EURUSD H1**
3. Inputs → Load → `SuperEA_portfolio.set`
4. 日期 2004.01.01 – 2026.01.01

## 逐品种 MT5 遗传优化（更新参数表）

```powershell
# 全部 9 品种依次跑 MT5 Genetic（约 30min/品种）
python run_mt5_cluster.py optimize --all-forex

# 或单个
python run_mt5_tester.py optimize --symbol EURUSD --from 2004.01.01 --to 2026.01.01
```

优化完成后自动生成 `RSIScalpingSuperParams.mqh`。

## 文件

| 文件 | 说明 |
|------|------|
| `SuperEA.mq5` | 多品种 Super EA |
| `RSIScalpingSuperParams.mqh` | 每品种硬编码参数 |
| `SuperEA_portfolio.set` | Tester 输入 |
| `run_mt5_cluster.py` | 批量 MT5 遗传优化 |
| `run_mt5_tester.py` | 单 EA / Super EA Tester 启动器 |

## 已验证

| 品种 | 净利润 | PF | 回撤 | 参数来源 |
|------|--------|-----|------|----------|
| XAUUSD | $10,470 | 1.56 | 9.1% | MT5 genetic Pass 306 |

外汇品种需跑 `run_mt5_cluster.py optimize` 写入真实参数（不能共用 XAUUSD 参数）。
