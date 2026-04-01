"""
ONNX Model Training Script for EURUSD 15-Minute Data
MetaTrader 5

This script trains a neural network model for EURUSD price prediction on 15-minute timeframe
and exports it to ONNX format.

Usage:
    python main.py
"""

import os
import sys
from datetime import datetime, timedelta
import numpy as np
import pandas as pd
import MetaTrader5 as mt5
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers
from sklearn.preprocessing import MinMaxScaler
from sklearn.model_selection import train_test_split
import tf2onnx
import onnx
from tqdm import tqdm
import pickle


class EURUSD15MinTrainer:
    """
    Trainer class for creating ONNX models from EURUSD 15-minute MT5 data.
    """
    
    def __init__(self, symbol: str = "EURUSD", timeframe: int = mt5.TIMEFRAME_M15, 
                 lookback: int = 60, prediction_horizon: int = 1):
        """
        Initialize the trainer.
        
        Args:
            symbol: Trading symbol (default: 'EURUSD')
            timeframe: MT5 timeframe constant (default: M15)
            lookback: Number of bars to look back for prediction (default: 60 = 15 hours)
            prediction_horizon: Number of bars ahead to predict (default: 1)
        """
        self.symbol = symbol
        self.timeframe = timeframe
        self.lookback = lookback
        self.prediction_horizon = prediction_horizon
        
        self.scaler = MinMaxScaler()
        self.model = None
        
        # Initialize MT5
        if not mt5.initialize():
            raise RuntimeError(f"MT5 initialization failed: {mt5.last_error()}")
        
        print(f"MT5 initialized. Connected to: {mt5.terminal_info().name}")
        
        # Check if symbol is available
        symbol_info = mt5.symbol_info(self.symbol)
        if symbol_info is None:
            print(f"WARNING: Symbol {self.symbol} not found. Available symbols:")
            symbols = mt5.symbols_get()
            if symbols:
                for i, sym in enumerate(symbols[:10]):  # Show first 10
                    print(f"  {sym.name}")
            raise ValueError(f"Symbol {self.symbol} not available in MT5")
        
        if not symbol_info.visible:
            print(f"WARNING: Symbol {self.symbol} is not visible. Trying to enable...")
            if not mt5.symbol_select(self.symbol, True):
                raise ValueError(f"Failed to enable symbol {self.symbol}")
    
    def fetch_data(self, start_date: datetime, end_date: datetime) -> pd.DataFrame:
        """
        Fetch historical data from MT5.
        
        Args:
            start_date: Start date for data
            end_date: End date for data
        
        Returns:
            DataFrame with OHLCV data
        """
        print(f"\nFetching {self.symbol} 15-minute data from {start_date.strftime('%Y-%m-%d')} to {end_date.strftime('%Y-%m-%d')}...")
        print("Note: MT5 typically has 15-minute data available for longer periods than 1-minute data.")
        
        # First, try to find the actual date range with data
        # Start from end_date and work backwards to find where data starts
        print("\nFinding available data range...")
        test_end = end_date
        test_start = end_date - timedelta(days=365)  # Check last year first
        
        test_rates = mt5.copy_rates_range(self.symbol, self.timeframe, test_start, test_end)
        if test_rates is None or len(test_rates) == 0:
            # Try even more recent
            test_start = end_date - timedelta(days=30)
            test_rates = mt5.copy_rates_range(self.symbol, self.timeframe, test_start, test_end)
        
        if test_rates is None or len(test_rates) == 0:
            raise ValueError(f"No 15-minute data available for {self.symbol}. Make sure:")
            print("  1. Historical data is downloaded in MT5 (Tools → History Center)")
            print("  2. The symbol is available and enabled")
            print("  3. You have 15-minute data for the requested period")
        
        # Find actual data range by checking from end backwards
        actual_start = end_date
        chunk_size_days = 30
        
        # Work backwards to find where data actually starts
        print("Scanning backwards to find data availability...")
        for days_back in range(0, 365*2, chunk_size_days):  # Check up to 2 years back
            check_start = end_date - timedelta(days=days_back + chunk_size_days)
            check_end = end_date - timedelta(days=days_back)
            test_rates = mt5.copy_rates_range(self.symbol, self.timeframe, check_start, check_end)
            if test_rates is not None and len(test_rates) > 10:  # More than just 1 bar
                actual_start = check_start
                print(f"  Found data starting from: {actual_start.strftime('%Y-%m-%d')}")
                break
        
        # Now fetch all available data
        print(f"\nFetching available data from {actual_start.strftime('%Y-%m-%d')} to {end_date.strftime('%Y-%m-%d')}...")
        all_rates = []
        current_start = actual_start
        
        # Fetch in chunks (1 month at a time for 15-minute data)
        chunk_days = 30  # 1 month chunks for 15-minute data
        
        chunks_with_data = 0
        chunks_without_data = 0
        
        while current_start < end_date:
            chunk_end = min(current_start + timedelta(days=chunk_days), end_date)
            
            rates = mt5.copy_rates_range(self.symbol, self.timeframe, current_start, chunk_end)
            
            if rates is None or len(rates) == 0:
                chunks_without_data += 1
                current_start = chunk_end
                continue
            
            # Skip chunks with only 1 bar (likely invalid/placeholder data)
            if len(rates) <= 1:
                chunks_without_data += 1
                current_start = chunk_end
                continue
            
            chunks_with_data += 1
            
            # MT5 returns structured numpy array - convert properly
            if isinstance(rates, np.ndarray) and rates.dtype.names:
                # Structured array - convert each row to dict
                for row in rates:
                    all_rates.append({name: row[name] for name in rates.dtype.names})
            else:
                # Already a list or regular array
                all_rates.extend(rates if isinstance(rates, list) else rates.tolist())
            
            if chunks_with_data % 10 == 0:
                print(f"  Progress: {chunks_with_data} chunks with data, {len(all_rates)} total bars")
            
            current_start = chunk_end
        
        print(f"\nData fetch complete: {chunks_with_data} chunks with data, {chunks_without_data} chunks skipped")
        
        if len(all_rates) == 0:
            raise ValueError(f"No data available for {self.symbol} in the specified date range")
        
        # Convert to DataFrame
        df = pd.DataFrame(all_rates)
        
        # MT5 returns 'time' field - convert from Unix timestamp to datetime
        if 'time' in df.columns:
            df['time'] = pd.to_datetime(df['time'], unit='s')
            df.set_index('time', inplace=True)
        else:
            # Debug: print available columns
            print(f"Available columns: {df.columns.tolist()}")
            print(f"First row sample: {df.iloc[0] if len(df) > 0 else 'Empty'}")
            raise ValueError(f"Could not find 'time' column in MT5 data. Available columns: {df.columns.tolist()}")
        
        # Remove duplicates
        df = df[~df.index.duplicated(keep='first')]
        df = df.sort_index()
        
        print(f"\nTotal fetched: {len(df)} bars")
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
            target: Target values (price_change, sl_atr, tp_atr) - shape (n_samples, 3)
        
        Returns:
            Tuple of (X, y) sequences
        """
        print("\nCreating sequences...")
        X, y = [], []
        
        for i in tqdm(range(self.lookback, len(data) - self.prediction_horizon + 1), desc="Creating sequences"):
            X.append(data[i - self.lookback:i])
            # Target is already aligned with data index
            y.append(target[i])
        
        X = np.array(X)
        y = np.array(y)
        
        print(f"  Sequences created: X shape {X.shape}, y shape {y.shape}")
        
        return X, y
    
    def build_model(self, input_shape: tuple) -> keras.Model:
        """
        Build the neural network model with multi-output (price change, SL, TP).
        
        Args:
            input_shape: Shape of input data (lookback, features)
        
        Returns:
            Compiled Keras model
        """
        print(f"\nBuilding multi-output model with input shape: {input_shape}")
        
        # Shared LSTM layers
        inputs = layers.Input(shape=input_shape)
        x = layers.LSTM(128, return_sequences=True)(inputs)
        x = layers.Dropout(0.3)(x)
        x = layers.LSTM(64, return_sequences=True)(x)
        x = layers.Dropout(0.3)(x)
        x = layers.LSTM(32)(x)
        x = layers.Dropout(0.3)(x)
        
        # Shared dense layers
        shared = layers.Dense(32, activation='relu')(x)
        shared = layers.Dense(16, activation='relu')(shared)
        
        # Separate outputs
        # Output 1: Price change percentage
        price_change = layers.Dense(8, activation='relu')(shared)
        price_change = layers.Dense(1, name='price_change')(price_change)
        
        # Output 2: Stop Loss (ATR multiples)
        sl_output = layers.Dense(8, activation='relu')(shared)
        sl_output = layers.Dense(1, activation='relu', name='sl_atr')(sl_output)  # ReLU to ensure positive
        
        # Output 3: Take Profit (ATR multiples)
        tp_output = layers.Dense(8, activation='relu')(shared)
        tp_output = layers.Dense(1, activation='relu', name='tp_atr')(tp_output)  # ReLU to ensure positive
        
        model = keras.Model(inputs=inputs, outputs=[price_change, sl_output, tp_output])
        
        # Compile with separate losses and metrics for each output
        model.compile(
            optimizer=keras.optimizers.Adam(learning_rate=0.0005),
            loss={
                'price_change': 'mse',
                'sl_atr': 'mse',
                'tp_atr': 'mse'
            },
            loss_weights={
                'price_change': 1.0,
                'sl_atr': 0.5,  # Lower weight for SL/TP
                'tp_atr': 0.5
            },
            metrics={
                'price_change': ['mae'],
                'sl_atr': ['mae'],
                'tp_atr': ['mae']
            }
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
        
        # Prepare targets: price change, optimal SL, and optimal TP
        # Calculate future price change and optimal SL/TP by looking ahead
        close_prices = feature_df['close'].values
        high_prices = feature_df['high'].values
        low_prices = feature_df['low'].values
        atr_values = feature_df['atr'].values
        
        # Look ahead window for calculating optimal SL/TP (e.g., 20 bars = 5 hours for M15)
        look_ahead_bars = 20
        
        target_price_change = []
        target_sl = []  # SL in ATR multiples
        target_tp = []  # TP in ATR multiples
        
        for i in range(len(close_prices)):
            if i + self.prediction_horizon < len(close_prices):
                current_price = close_prices[i]
                current_atr = atr_values[i] if atr_values[i] > 0 else current_price * 0.001
                
                # Calculate price change
                future_price = close_prices[i + self.prediction_horizon]
                price_change_pct = (future_price - current_price) / current_price if current_price > 0 else 0.0
                
                # Calculate optimal SL/TP by looking ahead
                # For BUY signals (positive price change expected)
                if price_change_pct > 0:
                    # Look ahead to find maximum adverse and favorable excursions
                    max_adverse = 0.0  # Maximum price drop (SL would be hit)
                    max_favorable = 0.0  # Maximum price rise (TP could be set)
                    
                    for j in range(i + 1, min(i + look_ahead_bars + 1, len(close_prices))):
                        # Maximum adverse: lowest low below entry
                        adverse_move = (current_price - low_prices[j]) / current_price
                        max_adverse = max(max_adverse, adverse_move)
                        
                        # Maximum favorable: highest high above entry
                        favorable_move = (high_prices[j] - current_price) / current_price
                        max_favorable = max(max_favorable, favorable_move)
                    
                    # Optimal SL: Use 1.2x of maximum adverse excursion (slightly wider to avoid noise)
                    # Convert to ATR multiples
                    optimal_sl_pct = max_adverse * 1.2 if max_adverse > 0 else 0.005  # Default 0.5% if no adverse move
                    optimal_sl_atr = optimal_sl_pct * current_price / current_atr if current_atr > 0 else 1.5
                    optimal_sl_atr = max(0.5, min(optimal_sl_atr, 5.0))  # Clamp between 0.5 and 5.0 ATR
                    
                    # Optimal TP: Use 0.6x of maximum favorable excursion (conservative)
                    # Ensure minimum 1.5x risk/reward ratio
                    optimal_tp_pct = max_favorable * 0.6 if max_favorable > 0 else optimal_sl_pct * 1.5
                    optimal_tp_pct = max(optimal_sl_pct * 1.5, optimal_tp_pct)  # At least 1.5x SL
                    optimal_tp_atr = optimal_tp_pct * current_price / current_atr if current_atr > 0 else 2.0
                    optimal_tp_atr = max(1.0, min(optimal_tp_atr, 10.0))  # Clamp between 1.0 and 10.0 ATR
                
                # For SELL signals (negative price change expected)
                else:
                    max_adverse = 0.0  # Maximum price rise (SL would be hit for sell)
                    max_favorable = 0.0  # Maximum price drop (TP could be set)
                    
                    for j in range(i + 1, min(i + look_ahead_bars + 1, len(close_prices))):
                        # Maximum adverse: highest high above entry
                        adverse_move = (high_prices[j] - current_price) / current_price
                        max_adverse = max(max_adverse, adverse_move)
                        
                        # Maximum favorable: lowest low below entry
                        favorable_move = (current_price - low_prices[j]) / current_price
                        max_favorable = max(max_favorable, favorable_move)
                    
                    # Optimal SL: Use 1.2x of maximum adverse excursion
                    optimal_sl_pct = max_adverse * 1.2 if max_adverse > 0 else 0.005
                    optimal_sl_atr = optimal_sl_pct * current_price / current_atr if current_atr > 0 else 1.5
                    optimal_sl_atr = max(0.5, min(optimal_sl_atr, 5.0))
                    
                    # Optimal TP: Use 0.6x of maximum favorable excursion
                    optimal_tp_pct = max_favorable * 0.6 if max_favorable > 0 else optimal_sl_pct * 1.5
                    optimal_tp_pct = max(optimal_sl_pct * 1.5, optimal_tp_pct)
                    optimal_tp_atr = optimal_tp_pct * current_price / current_atr if current_atr > 0 else 2.0
                    optimal_tp_atr = max(1.0, min(optimal_tp_atr, 10.0))
                
                target_price_change.append(price_change_pct)
                target_sl.append(optimal_sl_atr)
                target_tp.append(optimal_tp_atr)
            else:
                target_price_change.append(0.0)
                target_sl.append(1.5)  # Default SL
                target_tp.append(2.0)  # Default TP
        
        # Create DataFrame with multiple targets
        target_df = pd.DataFrame({
            'price_change': target_price_change,
            'sl_atr': target_sl,
            'tp_atr': target_tp
        }, index=feature_df.index)
        
        # Align targets with features
        valid_idx = ~(target_df.isna().any(axis=1) | feature_df.isna().any(axis=1))
        feature_df = feature_df[valid_idx]
        target_df = target_df[valid_idx]
        
        print(f"\nValid samples after alignment: {len(feature_df)}")
        print(f"Target statistics:")
        print(f"  Price Change: mean={target_df['price_change'].mean():.6f}, std={target_df['price_change'].std():.6f}")
        print(f"  SL (ATR): mean={target_df['sl_atr'].mean():.2f}, std={target_df['sl_atr'].std():.2f}")
        print(f"  TP (ATR): mean={target_df['tp_atr'].mean():.2f}, std={target_df['tp_atr'].std():.2f}")
        
        # Normalize features
        print("\nNormalizing features...")
        feature_array = self.scaler.fit_transform(feature_df.values)
        
        # Prepare multi-output target
        target_array = target_df[['price_change', 'sl_atr', 'tp_atr']].values
        
        # Create sequences
        X, y = self.create_sequences(feature_array, target_array)
        
        # Split into train and validation
        split_idx = int(len(X) * (1 - validation_split))
        X_train, X_val = X[:split_idx], X[split_idx:]
        y_train, y_val = y[:split_idx], y[split_idx:]
        
        print(f"\nTrain set: {len(X_train)} samples")
        print(f"Validation set: {len(X_val)} samples")
        
        # Build model
        input_shape = (self.lookback, feature_array.shape[1])
        self.model = self.build_model(input_shape)
        
        # Prepare multi-output targets for training
        y_train_dict = {
            'price_change': y_train[:, 0],
            'sl_atr': y_train[:, 1],
            'tp_atr': y_train[:, 2]
        }
        y_val_dict = {
            'price_change': y_val[:, 0],
            'sl_atr': y_val[:, 1],
            'tp_atr': y_val[:, 2]
        }
        
        # Train model
        print(f"\nTraining model for {epochs} epochs...")
        history = self.model.fit(
            X_train, y_train_dict,
            batch_size=batch_size,
            epochs=epochs,
            validation_data=(X_val, y_val_dict),
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
        train_eval = self.model.evaluate(X_train, y_train_dict, verbose=0)
        val_eval = self.model.evaluate(X_val, y_val_dict, verbose=0)
        
        # Multi-output model returns list of losses/metrics
        print(f"Train - Total Loss: {train_eval[0]:.6f}")
        print(f"  Price Change Loss: {train_eval[1]:.6f}, MAE: {train_eval[4]:.6f}")
        print(f"  SL Loss: {train_eval[2]:.6f}, MAE: {train_eval[5]:.6f}")
        print(f"  TP Loss: {train_eval[3]:.6f}, MAE: {train_eval[6]:.6f}")
        print(f"Val - Total Loss: {val_eval[0]:.6f}")
        print(f"  Price Change Loss: {val_eval[1]:.6f}, MAE: {val_eval[4]:.6f}")
        print(f"  SL Loss: {val_eval[2]:.6f}, MAE: {val_eval[5]:.6f}")
        print(f"  TP Loss: {val_eval[3]:.6f}, MAE: {val_eval[6]:.6f}")
        
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
        """Clean up MT5 connection."""
        mt5.shutdown()


def main():
    """Main function."""
    print("="*60)
    print("EURUSD 15-Minute ONNX Model Training")
    print("="*60)
    
    # Training parameters
    symbol = "EURUSD"
    timeframe = mt5.TIMEFRAME_M15
    lookback = 60  # 60 bars = 15 hours of history
    epochs = 50
    batch_size = 64
    
    # Date range: 1990 to 2026
    start_date = datetime(1990, 1, 1)
    end_date = datetime(2026, 1, 1)
    
    # Output paths
    output_dir = "models"
    os.makedirs(output_dir, exist_ok=True)
    model_path = os.path.join(output_dir, f"{symbol}_M15_model.onnx")
    
    trainer = None
    try:
        # Create trainer
        trainer = EURUSD15MinTrainer(
            symbol=symbol,
            timeframe=timeframe,
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
