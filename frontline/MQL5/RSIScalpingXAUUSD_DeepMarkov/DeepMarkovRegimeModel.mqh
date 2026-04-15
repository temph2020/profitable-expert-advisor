//+------------------------------------------------------------------+
//|                                      DeepMarkovRegimeModel.mqh |
//| Hierarchical latent Markov stack + online regime-conditioned   |
//| RSI parameter blending and self-tuning from trade feedback.    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property strict

#define DMR_NUM_STATES 4

void DMR_NormalizePi(double &p[])
{
   double s = 0.0;
   for(int i = 0; i < DMR_NUM_STATES; i++)
      s += p[i];
   if(s <= 0.0)
   {
      for(int j = 0; j < DMR_NUM_STATES; j++)
         p[j] = 1.0 / DMR_NUM_STATES;
      return;
   }
   for(int k = 0; k < DMR_NUM_STATES; k++)
      p[k] /= s;
}

//+------------------------------------------------------------------+
//| Two-level "deep" Markov: macro volatility x micro RSI momentum  |
//| Combined state s in {0..3} = macro*2 + micro.                   |
//| Belief filtered each bar; transitions learned online.           |
//+------------------------------------------------------------------+
class CDeepMarkovRegimeModel
{
private:
   int    m_seed;
   double m_learning_trans;   // transition matrix EMA
   double m_learning_emit;      // emission center EMA
   double m_learning_param;     // per-state param nudge on wins
   double m_penalty_param;      // nudge on losses

   // Forward belief pi(s), row-stochastic T[s_prev][s_next]
   double m_pi[DMR_NUM_STATES];
   double m_T[DMR_NUM_STATES][DMR_NUM_STATES];

   // Gaussian emission centers in feature space (3D): RSI/100, dRSI norm, ATR ratio
   double m_center[DMR_NUM_STATES][3];
   double m_emit_sigma; // shared diagonal sigma^2 for simplicity

   // Per-state RSI strategy parameters (learned offsets around base inputs)
   double m_d_overbought[DMR_NUM_STATES];
   double m_d_oversold[DMR_NUM_STATES];
   double m_d_target_buy[DMR_NUM_STATES];
   double m_d_target_sell[DMR_NUM_STATES];
   double m_d_bars_scale[DMR_NUM_STATES]; // multiplicative around base BarsToWait

   double m_base_overbought;
   double m_base_oversold;
   double m_base_target_buy;
   double m_base_target_sell;
   int    m_base_bars_wait;

   void NormalizePi()
   {
      DMR_NormalizePi(m_pi);
   }

   void RowNormalizeT()
   {
      for(int i = 0; i < DMR_NUM_STATES; i++)
      {
         double row = 0.0;
         for(int j = 0; j < DMR_NUM_STATES; j++)
            row += m_T[i][j];
         if(row <= 0.0)
         {
            for(int j = 0; j < DMR_NUM_STATES; j++)
               m_T[i][j] = 1.0 / DMR_NUM_STATES;
         }
         else
         {
            for(int j = 0; j < DMR_NUM_STATES; j++)
               m_T[i][j] /= row;
         }
      }
   }

   double FeatureDist2(const double f0, const double f1, const double f2, const int state) const
   {
      double d0 = f0 - m_center[state][0];
      double d1 = f1 - m_center[state][1];
      double d2 = f2 - m_center[state][2];
      return d0 * d0 + d1 * d1 + d2 * d2;
   }

   static double Clamp(const double x, const double lo, const double hi)
   {
      if(x < lo) return lo;
      if(x > hi) return hi;
      return x;
   }

public:
   CDeepMarkovRegimeModel()
   {
      m_seed = 0;
      m_learning_trans = 0.05;
      m_learning_emit = 0.02;
      m_learning_param = 0.03;
      m_penalty_param = 0.015;
      m_emit_sigma = 0.35;
      for(int i = 0; i < DMR_NUM_STATES; i++)
      {
         m_pi[i] = 1.0 / DMR_NUM_STATES;
         for(int j = 0; j < DMR_NUM_STATES; j++)
            m_T[i][j] = (i == j) ? 0.55 : 0.15;
         m_d_overbought[i] = 0.0;
         m_d_oversold[i] = 0.0;
         m_d_target_buy[i] = 0.0;
         m_d_target_sell[i] = 0.0;
         m_d_bars_scale[i] = 1.0;
         // Spread default emission prototypes across feature cube corners
         m_center[i][0] = ((i & 1) != 0) ? 0.75 : 0.35;
         m_center[i][1] = ((i & 2) != 0) ? 0.6 : 0.25;
         m_center[i][2] = (double)(i % 3) * 0.25 + 0.2;
      }
      RowNormalizeT();
   }

   void SetLearningRates(const double lr_trans, const double lr_emit, const double lr_win, const double lr_loss)
   {
      m_learning_trans = lr_trans;
      m_learning_emit = lr_emit;
      m_learning_param = lr_win;
      m_penalty_param = lr_loss;
   }

   void SetBaseThresholds(const double ob, const double os, const double tb, const double ts, const int bars_wait)
   {
      m_base_overbought = ob;
      m_base_oversold = os;
      m_base_target_buy = tb;
      m_base_target_sell = ts;
      m_base_bars_wait = bars_wait;
   }

   void SetSeed(const int seed) { m_seed = seed; }

   // f0: RSI/100, f1: tanh-like scaled delta RSI, f2: ATR short/long ratio capped
   void Update(const double f0, const double f1, const double f2)
   {
      double emit[DMR_NUM_STATES];
      double max_ll = -1.0e100;
      for(int s = 0; s < DMR_NUM_STATES; s++)
      {
         double d2 = FeatureDist2(f0, f1, f2, s);
         emit[s] = MathExp(-0.5 * d2 / (m_emit_sigma * m_emit_sigma + 1.0e-12));
         if(emit[s] > max_ll) max_ll = emit[s];
      }
      // numerical safety
      for(int s2 = 0; s2 < DMR_NUM_STATES; s2++)
         if(emit[s2] != emit[s2] || emit[s2] < 1.0e-12)
            emit[s2] = 1.0e-12;

      double pi_new[DMR_NUM_STATES];
      for(int j = 0; j < DMR_NUM_STATES; j++)
      {
         double sum = 0.0;
         for(int i = 0; i < DMR_NUM_STATES; i++)
            sum += m_pi[i] * m_T[i][j];
         pi_new[j] = sum * emit[j];
      }
      DMR_NormalizePi(pi_new);

      int imax_prev = ArgMaxPi();
      int imax_new = 0;
      double best = pi_new[0];
      for(int j = 1; j < DMR_NUM_STATES; j++)
         if(pi_new[j] > best)
         {
            best = pi_new[j];
            imax_new = j;
         }

      // Online transition nudge toward observed edge imax_prev -> imax_new
      for(int j = 0; j < DMR_NUM_STATES; j++)
         m_T[imax_prev][j] *= (1.0 - m_learning_trans);
      m_T[imax_prev][imax_new] += m_learning_trans;
      RowNormalizeT();

      // Pull emission center of dominant new state toward observation
      for(int d = 0; d < 3; d++)
      {
         double obs[3] = {f0, f1, f2};
         m_center[imax_new][d] = (1.0 - m_learning_emit) * m_center[imax_new][d] + m_learning_emit * obs[d];
      }

      for(int k = 0; k < DMR_NUM_STATES; k++)
         m_pi[k] = pi_new[k];
      NormalizePi();
   }

   int ArgMaxPi() const
   {
      int idx = 0;
      double best = m_pi[0];
      for(int i = 1; i < DMR_NUM_STATES; i++)
         if(m_pi[i] > best)
         {
            best = m_pi[i];
            idx = i;
         }
      return idx;
   }

   double Belief(const int s) const
   {
      if(s < 0 || s >= DMR_NUM_STATES) return 0.0;
      return m_pi[s];
   }

   // Blended effective thresholds (self-optimized offsets)
   double EffectiveOverbought() const
   {
      double v = 0.0;
      for(int s = 0; s < DMR_NUM_STATES; s++)
         v += m_pi[s] * (m_base_overbought + m_d_overbought[s]);
      return Clamp(v, 50.0, 95.0);
   }

   double EffectiveOversold() const
   {
      double v = 0.0;
      for(int s = 0; s < DMR_NUM_STATES; s++)
         v += m_pi[s] * (m_base_oversold + m_d_oversold[s]);
      return Clamp(v, 5.0, 50.0);
   }

   double EffectiveTargetBuy() const
   {
      double v = 0.0;
      for(int s = 0; s < DMR_NUM_STATES; s++)
         v += m_pi[s] * (m_base_target_buy + m_d_target_buy[s]);
      return Clamp(v, 55.0, 99.0);
   }

   double EffectiveTargetSell() const
   {
      double v = 0.0;
      for(int s = 0; s < DMR_NUM_STATES; s++)
         v += m_pi[s] * (m_base_target_sell + m_d_target_sell[s]);
      return Clamp(v, 1.0, 50.0);
   }

   int EffectiveBarsToWait() const
   {
      double acc = 0.0;
      for(int s = 0; s < DMR_NUM_STATES; s++)
         acc += m_pi[s] * m_d_bars_scale[s];
      acc = Clamp(acc, 0.5, 2.0);
      int b = (int)MathRound((double)m_base_bars_wait * acc);
      return (int)Clamp((double)b, 1.0, 20.0);
   }

   // Reinforce or soften parameters for the regime active at entry
   void OnTradeClosed(const int dominant_state_at_entry, const double profit_money)
   {
      if(dominant_state_at_entry < 0 || dominant_state_at_entry >= DMR_NUM_STATES)
         return;
      const int s = dominant_state_at_entry;
      const double mag = MathMin(1.0, MathAbs(profit_money) / 100.0 + 0.2);
      if(profit_money > 0.0)
      {
         // Slightly widen capture: push targets outward in favorable direction
         m_d_target_buy[s] += m_learning_param * mag * 0.5;
         m_d_target_sell[s] -= m_learning_param * mag * 0.5;
         m_d_overbought[s] += m_learning_param * mag * 0.25;
         m_d_oversold[s] -= m_learning_param * mag * 0.25;
         m_d_bars_scale[s] += m_learning_param * 0.05 * mag;
      }
      else if(profit_money < 0.0)
      {
         // Tighten: mean-revert offsets toward 0 and shorten patience
         m_d_target_buy[s] *= (1.0 - m_penalty_param * mag);
         m_d_target_sell[s] *= (1.0 - m_penalty_param * mag);
         m_d_overbought[s] *= (1.0 - m_penalty_param * mag);
         m_d_oversold[s] *= (1.0 - m_penalty_param * mag);
         m_d_bars_scale[s] -= m_penalty_param * 0.05 * mag;
      }
      for(int i = 0; i < DMR_NUM_STATES; i++)
      {
         m_d_overbought[i] = Clamp(m_d_overbought[i], -15.0, 15.0);
         m_d_oversold[i] = Clamp(m_d_oversold[i], -15.0, 15.0);
         m_d_target_buy[i] = Clamp(m_d_target_buy[i], -20.0, 20.0);
         m_d_target_sell[i] = Clamp(m_d_target_sell[i], -20.0, 20.0);
         m_d_bars_scale[i] = Clamp(m_d_bars_scale[i], 0.5, 2.0);
      }
   }

   string DebugStateLine() const
   {
      string t = StringFormat("DMR pi=[%.2f,%.2f,%.2f,%.2f] OB=%.1f OS=%.1f TB=%.1f TS=%.1f BW=%d",
                              m_pi[0], m_pi[1], m_pi[2], m_pi[3],
                              EffectiveOverbought(), EffectiveOversold(),
                              EffectiveTargetBuy(), EffectiveTargetSell(),
                              EffectiveBarsToWait());
      return t;
   }

   bool SaveToGlobals(const string prefix) const
   {
      string p = prefix + IntegerToString(m_seed) + "_";
      GlobalVariableSet(p + "pi0", m_pi[0]);
      GlobalVariableSet(p + "pi1", m_pi[1]);
      GlobalVariableSet(p + "pi2", m_pi[2]);
      GlobalVariableSet(p + "pi3", m_pi[3]);
      for(int i = 0; i < DMR_NUM_STATES; i++)
      {
         GlobalVariableSet(p + "dob" + IntegerToString(i), m_d_overbought[i]);
         GlobalVariableSet(p + "dos" + IntegerToString(i), m_d_oversold[i]);
         GlobalVariableSet(p + "dtb" + IntegerToString(i), m_d_target_buy[i]);
         GlobalVariableSet(p + "dts" + IntegerToString(i), m_d_target_sell[i]);
         GlobalVariableSet(p + "dbs" + IntegerToString(i), m_d_bars_scale[i]);
      }
      return true;
   }

   bool LoadFromGlobals(const string prefix)
   {
      string p = prefix + IntegerToString(m_seed) + "_";
      if(!GlobalVariableCheck(p + "pi0"))
         return false;
      m_pi[0] = GlobalVariableGet(p + "pi0");
      m_pi[1] = GlobalVariableGet(p + "pi1");
      m_pi[2] = GlobalVariableGet(p + "pi2");
      m_pi[3] = GlobalVariableGet(p + "pi3");
      for(int i = 0; i < DMR_NUM_STATES; i++)
      {
         m_d_overbought[i] = GlobalVariableGet(p + "dob" + IntegerToString(i));
         m_d_oversold[i] = GlobalVariableGet(p + "dos" + IntegerToString(i));
         m_d_target_buy[i] = GlobalVariableGet(p + "dtb" + IntegerToString(i));
         m_d_target_sell[i] = GlobalVariableGet(p + "dts" + IntegerToString(i));
         m_d_bars_scale[i] = GlobalVariableGet(p + "dbs" + IntegerToString(i));
      }
      NormalizePi();
      return true;
   }
};
