# XAUUSD H1 — ONNX action model

Same pipeline as **`../xauusd_m15`**, but **H1** bars, **H1-scaled label windows** (~wall-clock parity with M15 defaults), and **`XAUUSD_H1_ActionEA.mq5`**.

## Label scaling (vs M15)

| M15 (bars) | Wall time | H1 (bars) |
|------------|-----------|-----------|
| horizon 32 | ~8 h      | 8         |
| local 24   | ~6 h      | 6         |
| pullback 20| ~5 h      | 5         |

## Setup

1. MT5: **XAUUSD** visible; download **H1** history.
2. Python:

```bash
cd ai/xauusd_h1
pip install -r requirements.txt
python main.py
```

Env: `XAU_SYMBOL`, **`XAU_H1_LOOKBACK`** (default **48**, must match EA **InpLookback**), `XAU_EPOCHS`, `XAU_BATCH`, `SESSION_HOUR_OFFSET`.

3. Copy **`models/XAUUSD_H1_action.onnx`** next to **`XAUUSD_H1_ActionEA.mq5`** (for `#resource` embed) or adjust include path per your workflow.
4. Compile EA on **H1** chart; paste **24** floats into **InpFeatMinStr** / **InpFeatMaxStr** from training stdout.

## Files

| File | Role |
|------|------|
| `main.py` | MT5 H1 fetch, train, `XAUUSD_H1_action.onnx` + meta |
| `labeling.py` | `compute_action_labels` (H1 default horizons) |
| `features.py` | 24-dim features (same order as M15 EA) |
| `XAUUSD_H1_ActionEA.mq5` | Inference + trading |
| `XAUUSD_H1_ActionEA_optimize.set` | Tester optimization skeleton |

Feature semantics: **`../xauusd_m15/FRONTLINE_RSI_INTEGRATION.md`**.

## ONNX

- Input: `[1, lookback, 24]` float32, row **0** = newest bar.
- Output: `[1, 5]` softmax.

Research tooling — not investment advice.
