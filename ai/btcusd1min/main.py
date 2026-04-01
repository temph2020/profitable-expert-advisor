"""
ONNX Model Training Script for BTCUSD 1-Minute Data
Uses yfinance (Yahoo Finance) for historical data

This script trains a neural network model for BTCUSD price prediction on 1-minute timeframe
and exports it to ONNX format.

Usage:
    python main.py
"""

import os
import sys
from datetime import datetime, timedelta
import numpy as np
import pandas as pd
import yfinance as yf
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers
from sklearn.preprocessing import MinMaxScaler
from sklearn.model_selection import train_test_split
import tf2onnx
import onnx
from tqdm import tqdm
import pickle


class BTCUSD1MinTrainer:
    """
    Trainer class for creating ONNX models from BTCUSD 1-minute MT5 data.
    """
    
    def __init__(self, symbol: str = "BTC-USD", lookback: int = 60, 
                 prediction_horizon: int = 1):
        """
        Initialize the trainer.
        
        Args:
            symbol: Trading symbol (default: 'BTC-USD' for Yahoo Finance)
            lookback: Number of bars to look back for prediction (default: 60)
            prediction_horizon: Number of bars ahead to predict (default: 1)
        """
        self.symbol = symbol
        self.lookback = lookback
        self.prediction_horizon = prediction_horizon
        
        self.scaler = MinMaxScaler()
        self.model = None
        
        print(f"Using yfinance for data source. Symbol: {self.symbol}")
    
    def fetch_data(self, start_date: datetime, end_date: datetime) -> pd.DataFrame:
        """
        Fetch historical data from Yahoo Finance using yfinance.
        
        Args:
            start_date: Start date for data
            end_date: End date for data
        
        Returns:
            DataFrame with OHLCV data
        """
        print(f"\nFetching {self.symbol} 1-minute data from {start_date.strftime('%Y-%m-%d')} to {end_date.strftime('%Y-%m-%d')}...")
        
        # yfinance can only fetch 7 days of 1-minute data at a time
        # For longer periods, we need to fetch in chunks
        all_data = []
        current_start = start_date
        
        # For 1-minute data, yfinance limits to last 7 days
        # So we'll fetch the most recent 7 days available
        print("Note: yfinance 1-minute data is limited to last 7 days")
        print("Fetching most recent available 1-minute data...")
        
        # Get ticker
        ticker = yf.Ticker(self.symbol)
        
        # Try to fetch 1-minute data (limited to 7 days)
        # If we need more data, we'll use daily data and resample
        try:
            # Fetch 1-minute data (max 7 days)
            df = ticker.history(start=start_date, end=end_date, interval='1m')
            
            if df is None or len(df) == 0:
                print("Warning: No 1-minute data available, trying daily data...")
                # Fall back to daily data
                df = ticker.history(start=start_date, end=end_date, interval='1d')
                if df is None or len(df) == 0:
                    raise ValueError(f"No data available for {self.symbol}")
                print(f"Using daily data instead (will resample to 1-minute for training)")
        except Exception as e:
            print(f"Error fetching 1-minute data: {e}")
            print("Falling back to daily data...")
            df = ticker.history(start=start_date, end=end_date, interval='1d')
            if df is None or len(df) == 0:
                raise ValueError(f"No data available for {self.symbol}: {e}")
        
        # Rename columns to match expected format
        df.columns = [col.lower().replace(' ', '_') for col in df.columns]
        
        # Ensure we have the required columns
        required_cols = ['open', 'high', 'low', 'close', 'volume']
        missing_cols = [col for col in required_cols if col not in df.columns]
        if missing_cols:
            raise ValueError(f"Missing required columns: {missing_cols}")
        
        # Rename 'volume' to 'tick_volume' for consistency
        if 'volume' in df.columns:
            df['tick_volume'] = df['volume']
            df = df.drop('volume', axis=1)
        
        # Remove duplicates and sort
        df = df[~df.index.duplicated(keep='first')]
        df = df.sort_index()
        
        print(f"Total fetched: {len(df)} bars")
        if len(df) > 0:
            print(f"Date range: {df.index[0]} to {df.index[-1]}")
            print(f"Timeframe: {df.index[1] - df.index[0] if len(df) > 1 else 'N/A'}")
        else:
            raise ValueError("DataFrame is empty after processing")
        
        return df
    
    def prepare_features(self, df: pd.DataFrame) -> pd.DataFrame:
        """
        Prepare features for training.
        
        Args:
            df: Raw OHLCV data
        
        Returns:
            DataFrame with features
        """
        print("\nPreparing features...")
        
        feature_df = df[['open', 'high', 'low', 'close', 'tick_volume']].copy()
        
        # Add technical indicators as features
        print("  Calculating RSI...")
        feature_df['rsi'] = self._calculate_rsi(df['close'], period=14)
        
        print("  Calculating EMAs...")
        feature_df['ema_20'] = df['close'].ewm(span=20, adjust=False).mean()
        feature_df['ema_50'] = df['close'].ewm(span=50, adjust=False).mean()
        
        print("  Calculating ATR...")
        feature_df['atr'] = self._calculate_atr(df, period=14)
        
        # Price changes
        feature_df['price_change'] = df['close'].pct_change()
        feature_df['high_low_ratio'] = df['high'] / df['low']
        
        # Volume features
        feature_df['volume_ma'] = df['tick_volume'].rolling(window=20).mean()
        feature_df['volume_ratio'] = df['tick_volume'] / feature_df['volume_ma']
        
        # Drop NaN values
        feature_df = feature_df.dropna()
        
        print(f"  Features prepared: {len(feature_df)} samples, {len(feature_df.columns)} features")
        print(f"  Features: {list(feature_df.columns)}")
        
        return feature_df
    
    def _calculate_rsi(self, prices: pd.Series, period: int = 14) -> pd.Series:
        """Calculate RSI indicator."""
        delta = prices.diff()
        gain = (delta.where(delta > 0, 0)).rolling(window=period).mean()
        loss = (-delta.where(delta < 0, 0)).rolling(window=period).mean()
        rs = gain / loss
        rsi = 100 - (100 / (1 + rs))
        return rsi
    
    def _calculate_atr(self, df: pd.DataFrame, period: int = 14) -> pd.Series:
        """Calculate ATR indicator."""
        high_low = df['high'] - df['low']
        high_close = np.abs(df['high'] - df['close'].shift())
        low_close = np.abs(df['low'] - df['close'].shift())
        tr = pd.concat([high_low, high_close, low_close], axis=1).max(axis=1)
        atr = tr.rolling(window=period).mean()
        return atr
    
    def create_sequences(self, data: np.ndarray, target: np.ndarray) -> tuple:
        """
        Create sequences for LSTM/RNN training.
        
        Args:
            data: Feature data
            target: Target values (price change percentages)
        
        Returns:
            Tuple of (X, y) sequences
        """
        print("\nCreating sequences...")
        X, y = [], []
        
        for i in tqdm(range(self.lookback, len(data) - self.prediction_horizon + 1), desc="Creating sequences"):
            X.append(data[i - self.lookback:i])
            y.append(target[i])
        
        X = np.array(X)
        y = np.array(y)
        
        print(f"  Sequences created: X shape {X.shape}, y shape {y.shape}")
        
        return X, y
    
    def build_model(self, input_shape: tuple) -> keras.Model:
        """
        Build the neural network model.
        
        Args:
            input_shape: Shape of input data (lookback, features)
        
        Returns:
            Compiled Keras model
        """
        print(f"\nBuilding model with input shape: {input_shape}")
        
        model = keras.Sequential([
            layers.LSTM(128, return_sequences=True, input_shape=input_shape),
            layers.Dropout(0.3),
            layers.LSTM(64, return_sequences=True),
            layers.Dropout(0.3),
            layers.LSTM(32),
            layers.Dropout(0.3),
            layers.Dense(32, activation='relu'),
            layers.Dense(16, activation='relu'),
            layers.Dense(1)  # Predict price change percentage
        ])
        
        model.compile(
            optimizer=keras.optimizers.Adam(learning_rate=0.0005),
            loss='mse',
            metrics=['mae']
        )
        
        print(f"  Model parameters: {model.count_params():,}")
        model.summary()
        
        return model
    
    def train(self, start_date: datetime, end_date: datetime, 
              epochs: int = 50, batch_size: int = 32, 
              validation_split: float = 0.2, verbose: int = 1):
        """
        Train the model.
        
        Args:
            start_date: Start date for training data
            end_date: End date for training data
            epochs: Number of training epochs
            batch_size: Batch size for training
            validation_split: Fraction of data to use for validation
            verbose: Verbosity level
        """
        # Fetch data
        df = self.fetch_data(start_date, end_date)
        feature_df = self.prepare_features(df)
        
        # Prepare target: price change percentage for next bar
        # Calculate future price change: (next_close - current_close) / current_close
        close_prices = feature_df['close'].values
        target = []
        for i in range(len(close_prices)):
            if i + self.prediction_horizon < len(close_prices):
                current_price = close_prices[i]
                future_price = close_prices[i + self.prediction_horizon]
                price_change_pct = (future_price - current_price) / current_price if current_price > 0 else 0.0
                target.append(price_change_pct)
            else:
                target.append(0.0)
        target = pd.Series(target, index=feature_df.index)
        
        # Keep 'close' in features - it's needed for the model
        
        # Align target with features
        valid_idx = ~(target.isna() | feature_df.isna().any(axis=1))
        feature_df = feature_df[valid_idx]
        target = target[valid_idx]
        
        print(f"\nValid samples after alignment: {len(feature_df)}")
        
        # Normalize features
        print("\nNormalizing features...")
        feature_array = self.scaler.fit_transform(feature_df.values)
        
        # Create sequences
        X, y = self.create_sequences(feature_array, target.values)
        
        # Split into train and validation
        split_idx = int(len(X) * (1 - validation_split))
        X_train, X_val = X[:split_idx], X[split_idx:]
        y_train, y_val = y[:split_idx], y[split_idx:]
        
        print(f"\nTrain set: {len(X_train)} samples")
        print(f"Validation set: {len(X_val)} samples")
        
        # Build model
        input_shape = (self.lookback, feature_array.shape[1])
        self.model = self.build_model(input_shape)
        
        # Train model
        print(f"\nTraining model for {epochs} epochs...")
        history = self.model.fit(
            X_train, y_train,
            batch_size=batch_size,
            epochs=epochs,
            validation_data=(X_val, y_val),
            verbose=verbose,
            callbacks=[
                keras.callbacks.EarlyStopping(
                    monitor='val_loss',
                    patience=10,
                    restore_best_weights=True
                ),
                keras.callbacks.ReduceLROnPlateau(
                    monitor='val_loss',
                    factor=0.5,
                    patience=5,
                    min_lr=1e-7
                )
            ]
        )
        
        # Evaluate
        print("\nEvaluating model...")
        train_loss = self.model.evaluate(X_train, y_train, verbose=0)
        val_loss = self.model.evaluate(X_val, y_val, verbose=0)
        
        print(f"Train Loss: {train_loss[0]:.6f}, MAE: {train_loss[1]:.6f}")
        print(f"Val Loss: {val_loss[0]:.6f}, MAE: {val_loss[1]:.6f}")
        
        return history
    
    def export_to_onnx(self, output_path: str):
        """
        Export the trained model to ONNX format.
        
        Args:
            output_path: Path to save ONNX model
        """
        if self.model is None:
            raise ValueError("Model must be trained before exporting")
        
        print(f"\nExporting model to ONNX format: {output_path}")
        
        # Get number of features
        num_features = self.model.input_shape[2] if len(self.model.input_shape) > 2 else self.model.input_shape[1]
        
        print(f"Using {num_features} features for ONNX export")
        
        # Create input signature
        input_shape = (None, self.lookback, num_features)
        spec = (tf.TensorSpec(input_shape, tf.float32, name="input"),)
        
        # Fix output_names for Sequential model
        if not hasattr(self.model, 'output_names'):
            if hasattr(self.model, 'outputs') and self.model.outputs:
                self.model.output_names = [f'output_{i}' for i in range(len(self.model.outputs))]
            else:
                self.model.output_names = ['output']
        
        # Convert to ONNX
        onnx_model, _ = tf2onnx.convert.from_keras(
            self.model,
            input_signature=spec,
            opset=13
        )
        
        # Save ONNX model
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        onnx.save_model(onnx_model, output_path)
        
        print(f"ONNX model saved to: {output_path}")
        
        # Save scaler
        scaler_path = output_path.replace('.onnx', '_scaler.pkl')
        with open(scaler_path, 'wb') as f:
            pickle.dump(self.scaler, f)
        print(f"Scaler saved to: {scaler_path}")
    
    def cleanup(self):
        """Clean up (no-op for yfinance)."""
        pass


def main():
    """Main function."""
    print("="*60)
    print("BTCUSD 1-Minute ONNX Model Training")
    print("="*60)
    
    # Training parameters
    symbol = "BTC-USD"  # Yahoo Finance symbol
    lookback = 60  # 60 minutes of history
    epochs = 50
    batch_size = 64  # Larger batch for 1-minute data
    
    # Date range: Use recent data (yfinance 1m data limited to 7 days)
    # For longer training, we'll use the most recent available data
    end_date = datetime.now()
    start_date = end_date - timedelta(days=7)  # Last 7 days for 1-minute data
    
    print(f"Note: yfinance 1-minute data is limited to last 7 days")
    print(f"Using date range: {start_date.strftime('%Y-%m-%d')} to {end_date.strftime('%Y-%m-%d')}")
    
    # Output paths
    output_dir = "models"
    os.makedirs(output_dir, exist_ok=True)
    model_path = os.path.join(output_dir, f"{symbol}_M1_model.onnx")
    
    trainer = None
    try:
        # Create trainer
        trainer = BTCUSD1MinTrainer(
            symbol=symbol,
            lookback=lookback
        )
        
        # Train model
        history = trainer.train(
            start_date=start_date,
            end_date=end_date,
            epochs=epochs,
            batch_size=batch_size,
            validation_split=0.2,
            verbose=1
        )
        
        # Export to ONNX
        trainer.export_to_onnx(model_path)
        
        print("\n" + "="*60)
        print("Training completed successfully!")
        print("="*60)
        print(f"Model saved to: {model_path}")
        
    except Exception as e:
        print(f"\nERROR: Training failed: {e}")
        import traceback
        traceback.print_exc()
        return 1
    
    finally:
        if trainer:
            trainer.cleanup()
    
    return 0


if __name__ == '__main__':
    sys.exit(main())
