from __future__ import annotations

import pandas as pd


REQUIRED_COLUMNS = {"date", "asset", "close"}


def load_prices_csv(file) -> pd.DataFrame:
    df = pd.read_csv(file)
    missing = REQUIRED_COLUMNS - set(df.columns)
    if missing:
        raise ValueError(f"Missing required columns: {sorted(missing)}")

    df["date"] = pd.to_datetime(df["date"])
    df = df.sort_values(["date", "asset"]).reset_index(drop=True)
    return df

