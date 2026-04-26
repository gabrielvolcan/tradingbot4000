//+------------------------------------------------------------------+
//|                        CrashBot500.mq5                          |
//|            BOT CRASH 500 — BUY POST-CRASH STRATEGY              |
//|       Solo BUY | M1 | RSI 14 | Crash 500 Index                  |
//+------------------------------------------------------------------+
#property copyright   "CrashBot 500"
#property version     "1.10"
#property strict
#property description "Bot BUY-only para Crash 500 — RSI M1 — SL/TP en USD con estadisticas de precision"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//|  INPUTS — todos modificables desde Propiedades del EA           |
//+------------------------------------------------------------------+
input group "=== RSI ==="
input int    InpRSIPeriod   = 14;       // Periodo del RSI
input double InpRSILevel    = 30.0;     // Nivel de cruce para compra

input group "=== GESTION DE OPERACION (USD) ==="
input double InpSL          = 2.00;     // Stop Loss en USD
input double InpTP          = 3.50;     // Take Profit en USD
input double InpBEAt        = 1.20;     // Mover a break-even cuando profit alcance ($)
input double InpTrailFrom   = 1.20;     // Activar trailing cuando profit alcance ($)
input double InpTrailDist   = 1.00;     // Distancia del trailing stop en USD

input group "=== RIESGO ==="
input double InpRiskPct     = 2.0;      // Riesgo por operacion (% del balance)
input int    InpMaxDiarias  = 4;        // Max operaciones permitidas por dia
input double InpMaxPerdDia  = 6.0;      // Perdida maxima diaria (% del balance del dia)
input int    InpMaxConsec   = 2;        // Pausar tras N perdidas consecutivas
input int    InpCooldown    = 5;        // Minutos de espera minima tras cierre

input group "=== DETECCION DE CRASH ==="
input double InpCrashPts    = 50.0;     // Puntos minimos de rango bajista para crash
input int    InpCrashVelas  = 3;        // Velas anteriores a revisar para el crash

input group "=== CONFIGURACION AVANZADA ==="
input int                    InpMagicNumber = 500500;          // Numero magico del EA
input int                    InpSlippage    = 50;              // Deslizamiento maximo en puntos
input ENUM_ORDER_TYPE_FILLING InpFilling    = ORDER_FILLING_IOC; // Modo de llenado (IOC para Deriv)

input group "=== TELEGRAM ==="
input bool   InpTelegram    = false;
input string InpTGToken     = "";       // Token del bot Telegram
input string InpTGChatID    = "";       // Chat ID de Telegram

input group "=== PANEL VISUAL ==="
input bool   InpShowPanel   = true;
input int    InpPanelX      = 15;       // Posicion X del panel
input int    InpPanelY      = 30;       // Posicion Y del panel

//+------------------------------------------------------------------+
//|  VARIABLES GLOBALES — control de sesion                         |
//+------------------------------------------------------------------+
CTrade   trade;
int      g_hRSI        = INVALID_HANDLE;

datetime g_lastBar     = 0;
datetime g_lastClose   = 0;
datetime g_tradingDay  = 0;

// Control diario
double   g_dayStartBal  = 0;
int      g_dayTrades    = 0;    // Operaciones abiertas hoy
int      g_dayWins      = 0;    // Operaciones ganadoras cerradas hoy
int      g_dayLossCount = 0;    // Operaciones perdedoras cerradas hoy
double   g_dayGrossWin  = 0;    // Suma total de ganancias brutas hoy ($)
double   g_dayGrossLoss = 0;    // Suma total de perdidas brutas hoy ($)

// Control de estado
int      g_consecLoss   = 0;
bool     g_paused       = false;
bool     g_dashEnabled  = true;   // Controlado desde el Dashboard web
bool     g_inImpulse    = false;

// Parámetros dinámicos — actualizados desde el Dashboard
double   gc_rsiLevel    = 30.0;
double   gc_sl          = 2.00;
double   gc_tp          = 3.50;
double   gc_riskPct     = 2.0;
int      gc_maxOpsDay   = 4;
double   gc_maxLossDay  = 6.0;
int      gc_maxConsec   = 2;
bool     g_beApplied    = false;
ulong    g_openTicket   = 0;

//+------------------------------------------------------------------+
//|  OBJETOS DEL PANEL                                              |
//+------------------------------------------------------------------+
string P_BG  = "CB_BG";
string P_T1  = "CB_T1";  string P_T2  = "CB_T2";
string P_L1  = "CB_L1";  string P_V1  = "CB_V1";   // RSI actual
string P_L2  = "CB_L2";  string P_V2  = "CB_V2";   // Senal
string P_SEP = "CB_SEP";                             // Separador
string P_L3  = "CB_L3";  string P_V3  = "CB_V3";   // Ops hoy
string P_L4  = "CB_L4";  string P_V4  = "CB_V4";   // W/L
string P_L5  = "CB_L5";  string P_V5  = "CB_V5";   // Precision
string P_L6  = "CB_L6";  string P_V6  = "CB_V6";   // Profit Factor
string P_L7  = "CB_L7";  string P_V7  = "CB_V7";   // P&L neto
string P_L8  = "CB_L8";  string P_V8  = "CB_V8";   // Perd. dia
string P_L9  = "CB_L9";  string P_V9  = "CB_V9";   // Consec.
string P_L10 = "CB_LA";  string P_V10 = "CB_VA";   // Estado

//+------------------------------------------------------------------+
//|  INICIALIZACION                                                  |
//+------------------------------------------------------------------+
int OnInit()
{
   g_hRSI = iRSI(_Symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);
   if(g_hRSI == INVALID_HANDLE)
   {
      Alert("ERROR: No se pudo crear RSI. Codigo: ", GetLastError());
      return INIT_FAILED;
   }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(InpFilling);

   g_dayStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   g_tradingDay  = DayStart();

   gc_rsiLevel   = InpRSILevel;
   gc_sl         = InpSL;
   gc_tp         = InpTP;
   gc_riskPct    = InpRiskPct;
   gc_maxOpsDay  = InpMaxDiarias;
   gc_maxLossDay = InpMaxPerdDia;
   gc_maxConsec  = InpMaxConsec;

   // Recuperar posicion abierta si el EA fue reiniciado
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC)  == (long)InpMagicNumber)
      {
         g_openTicket = t;
         g_inImpulse  = true;
         Print("Posicion existente recuperada: #", t);
         break;
      }
   }

   if(InpShowPanel) CreatePanel();

   Print("========================================");
   Print("  CRASHBOT 500 v1.10 - INICIADO");
   Print("  Simbolo : ", _Symbol, " | TF: M1 | Magic: ", InpMagicNumber);
   Print("  RSI(", InpRSIPeriod, ") cruce por encima de ", InpRSILevel);
   Print("  SL: $", InpSL, " | TP: $", InpTP, " | Riesgo: ", InpRiskPct, "%");
   Print("  BE en: $", InpBEAt, " | Trail desde: $", InpTrailFrom, " dist: $", InpTrailDist);
   Print("  Max ops/dia: ", InpMaxDiarias, " | Max perd/dia: ", InpMaxPerdDia, "%");
   Print("  Balance inicio: $", DoubleToString(g_dayStartBal, 2));
   Print("========================================");

   if(InpTelegram && InpTGToken != "" && InpTGChatID != "")
      SendTelegram(
         "CRASHBOT 500 CONECTADO\n"
         "Simbolo: " + _Symbol + " | M1 | Solo BUY\n"
         "RSI(" + IntegerToString(InpRSIPeriod) + ") nivel: " + DoubleToString(InpRSILevel, 0) + "\n"
         "SL: $" + DoubleToString(InpSL, 2) + " | TP: $" + DoubleToString(InpTP, 2) + "\n"
         "Riesgo: " + DoubleToString(InpRiskPct, 1) + "% | Max/dia: " + IntegerToString(InpMaxDiarias) + "\n"
         "Balance: $" + DoubleToString(g_dayStartBal, 2));

   RegisterWithDashboard();
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  REGISTRO EN DASHBOARD                                           |
//+------------------------------------------------------------------+
void RegisterWithDashboard()
{
   string fname = "mreg_" + IntegerToString(InpMagicNumber) + ".cfg";
   int fh = FileOpen(fname, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE) { Print("WARN: no se pudo crear ", fname); return; }
   FileWriteString(fh, "NAME=Crash 500 BUY\n");
   FileWriteString(fh, "SYMBOL=" + _Symbol + "\n");
   FileWriteString(fh, "MAGIC=" + IntegerToString(InpMagicNumber) + "\n");
   FileWriteString(fh, "EA=crash500\n");
   FileClose(fh);
   Print("Dashboard: registrado como crash500 en ", fname);
}

//+------------------------------------------------------------------+
//|  DESINICIALIZACION                                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hRSI != INVALID_HANDLE) IndicatorRelease(g_hRSI);
   if(InpShowPanel) DeletePanel();
   if(InpTelegram && InpTGToken != "" && InpTGChatID != "")
      SendTelegram("CRASHBOT 500 DETENIDO | " + _Symbol);
}

//+------------------------------------------------------------------+
//|  TICK PRINCIPAL                                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   ReadConfig();
   ResetDayIfNeeded();
   ManageOpenPosition();
   if(InpShowPanel) UpdatePanel();

   if(g_paused || !g_dashEnabled) return;

   // Logica de entrada solo al cierre de cada nueva vela M1
   datetime bar = iTime(_Symbol, PERIOD_M1, 0);
   if(bar == g_lastBar) return;
   g_lastBar = bar;

   if(g_openTicket != 0UL) return;

   double rsi[];
   ArraySetAsSeries(rsi, true);
   if(CopyBuffer(g_hRSI, 0, 1, 2, rsi) < 2) return;

   double rsiNow  = rsi[0]; // ultima vela cerrada
   double rsiPrev = rsi[1]; // vela anterior cerrada

   // RSI bajo nivel = nuevo ciclo potencial de crash
   if(rsiNow < gc_rsiLevel)
      g_inImpulse = false;

   if(PuedeEntrar(rsiNow, rsiPrev))
      AbrirCompra();
}

//+------------------------------------------------------------------+
//|  DETECCION DE CIERRE DE POSICION via transaccion                |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &,
                        const MqlTradeResult      &)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   ulong deal = trans.deal;
   if(!HistoryDealSelect(deal))                                            return;
   if(HistoryDealGetInteger(deal, DEAL_MAGIC)  != (long)InpMagicNumber)   return;
   if(HistoryDealGetInteger(deal, DEAL_ENTRY)  != DEAL_ENTRY_OUT) return;
   if(HistoryDealGetString(deal,  DEAL_SYMBOL) != _Symbol)        return;

   double profit = HistoryDealGetDouble(deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(deal, DEAL_COMMISSION)
                 + HistoryDealGetDouble(deal, DEAL_SWAP);
   double price  = HistoryDealGetDouble(deal, DEAL_PRICE);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   string razon = "";
   switch((int)HistoryDealGetInteger(deal, DEAL_REASON))
   {
      case DEAL_REASON_SL:     razon = "Stop Loss";   break;
      case DEAL_REASON_TP:     razon = "Take Profit"; break;
      case DEAL_REASON_EXPERT: razon = "Bot EA";      break;
      default:                 razon = "Manual/Otro"; break;
   }

   // Actualizar estado de posicion
   g_lastClose  = TimeCurrent();
   g_openTicket = 0;
   g_beApplied  = false;

   // ── Actualizar estadisticas de precision ──────────────────────
   if(profit >= 0.0)
   {
      g_dayWins++;
      g_dayGrossWin += profit;
      g_consecLoss   = 0;
      Print("GANANCIA cerrada: +$", DoubleToString(profit, 2),
            " | Wins hoy: ", g_dayWins,
            " | Precision: ", StatPrecision(), "%");
   }
   else
   {
      g_dayLossCount++;
      g_dayGrossLoss += MathAbs(profit);
      g_consecLoss++;
      Print("PERDIDA cerrada: $", DoubleToString(profit, 2),
            " | Losses hoy: ", g_dayLossCount,
            " | Consec: ", g_consecLoss,
            " | Perd.dia: $", DoubleToString(g_dayGrossLoss, 2));

      if(g_consecLoss >= gc_maxConsec)
      {
         g_paused = true;
         Print(">>> PAUSADO: ", g_consecLoss, " perdidas consecutivas <<<");
      }
   }

   if(!g_paused && DiaExcedido())
   {
      g_paused = true;
      Print(">>> PAUSADO: perdida diaria maxima ($", DoubleToString(g_dayGrossLoss, 2), ") <<<");
   }

   // ── Log y Telegram ───────────────────────────────────────────
   double netDia  = g_dayGrossWin - g_dayGrossLoss;
   string resultado = (profit >= 0.0) ? "GANANCIA" : "PERDIDA";
   string msg = resultado + " | COMPRA CERRADA\n"
      "Precio cierre: " + DoubleToString(price, digits) + "\n"
      "Razon: " + razon + "\n"
      "Resultado: " + (profit >= 0.0 ? "+" : "") + DoubleToString(profit, 2) + " USD\n"
      "─ Stats del dia ─\n"
      "W/L: " + IntegerToString(g_dayWins) + "W - " + IntegerToString(g_dayLossCount) + "L\n"
      "Precision: " + StatPrecision() + "%\n"
      "Fact.Profit: " + StatProfitFactor() + "\n"
      "P&L neto: " + (netDia >= 0.0 ? "+" : "") + DoubleToString(netDia, 2) + " USD\n"
      "Estado: " + (g_paused ? "PAUSADO" : "ACTIVO");
   Print(msg);
   if(InpTelegram && InpTGToken != "" && InpTGChatID != "")
      SendTelegram(msg);
}

//+------------------------------------------------------------------+
//|  CONDICIONES DE ENTRADA                                         |
//+------------------------------------------------------------------+
bool PuedeEntrar(double rsiNow, double rsiPrev)
{
   // 1+2: Cruce RSI hacia arriba del nivel en vela cerrada
   if(rsiPrev >= gc_rsiLevel || rsiNow < gc_rsiLevel)
      return false;

   // 3: Vela de confirmacion cierra verde
   if(iClose(_Symbol, PERIOD_M1, 1) <= iOpen(_Symbol, PERIOD_M1, 1))
      return false;

   // 4: Crash fuerte en las ultimas InpCrashVelas velas
   if(!CrashDetectado())
      return false;

   // 6: No repetir en el mismo impulso
   if(g_inImpulse)
      return false;

   // 7: Cooldown minimo tras ultimo cierre
   if(g_lastClose > 0 &&
      (TimeCurrent() - g_lastClose) < (datetime)(InpCooldown * 60))
      return false;

   // Limites diarios
   if(g_dayTrades >= gc_maxOpsDay)
   {
      Print("Limite diario alcanzado (", gc_maxOpsDay, ")");
      return false;
   }
   if(g_paused || DiaExcedido())
      return false;

   return true;
}

//+------------------------------------------------------------------+
//|  DETECCION DE CRASH                                             |
//+------------------------------------------------------------------+
bool CrashDetectado()
{
   int velas = MathMax(1, InpCrashVelas);
   for(int i = 1; i <= velas; i++)
   {
      double rango   = (iHigh(_Symbol, PERIOD_M1, i) - iLow(_Symbol, PERIOD_M1, i)) / _Point;
      bool   bajista = iClose(_Symbol, PERIOD_M1, i) < iOpen(_Symbol, PERIOD_M1, i);
      if(bajista && rango >= InpCrashPts) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//|  ABRIR COMPRA                                                   |
//+------------------------------------------------------------------+
void AbrirCompra()
{
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickVal <= 0.0 || tickSz <= 0.0)
   {
      Print("ERROR: datos del simbolo invalidos (tickVal=", tickVal, " tickSz=", tickSz, ")");
      return;
   }

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riesgo  = balance * gc_riskPct / 100.0;

   // lots = riesgo / gc_sl
   // Logica: para 1 lot la perdida al SL = gc_sl USD.
   // Con `lots` lotes: perdida total = lots * gc_sl = riesgo. Despejando: lots = riesgo / gc_sl
   double lots = riesgo / gc_sl;

   // SL y TP como distancia de precio (para 1 lot = gc_sl y gc_tp USD respectivamente)
   double slDist = gc_sl * tickSz / tickVal;
   double tpDist = gc_tp * tickSz / tickVal;

   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lots = MathMax(minL, MathMin(maxL, MathFloor(lots / step) * step));

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    dgt = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double sl = NormalizeDouble(ask - slDist, dgt);
   double tp = NormalizeDouble(ask + tpDist, dgt);

   if(sl <= 0.0)
   {
      Print("ERROR: SL invalido (", sl, "). Verificar parametros del simbolo.");
      return;
   }

   if(trade.Buy(lots, _Symbol, ask, sl, tp, "CrashBot"))
   {
      g_openTicket = trade.ResultOrder();
      g_inImpulse  = true;
      g_beApplied  = false;
      g_dayTrades++;

      string msg = "COMPRA ABIERTA\n"
         "Ticket: #" + IntegerToString(g_openTicket) + "\n"
         "Entrada: " + DoubleToString(ask, dgt) + "\n"
         "Lote: " + DoubleToString(lots, 2) + " | Riesgo: $" + DoubleToString(riesgo, 2) + "\n"
         "SL: " + DoubleToString(sl, dgt) + " (-$" + DoubleToString(gc_sl * lots, 2) + ")\n"
         "TP: " + DoubleToString(tp, dgt) + " (+$" + DoubleToString(gc_tp * lots, 2) + ")\n"
         "Ops hoy: " + IntegerToString(g_dayTrades) + "/" + IntegerToString(gc_maxOpsDay);
      Print(msg);
      if(InpTelegram && InpTGToken != "" && InpTGChatID != "")
         SendTelegram(msg);
   }
   else
   {
      Print("ERROR COMPRA: ", trade.ResultRetcode(), " | ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//|  GESTION DE POSICION — trailing stop + break-even               |
//+------------------------------------------------------------------+
void ManageOpenPosition()
{
   if(g_openTicket == 0UL) return;
   if(!PositionSelectByTicket(g_openTicket)) return;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return;

   double profit = PositionGetDouble(POSITION_PROFIT)
                 + PositionGetDouble(POSITION_SWAP);
   double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl     = PositionGetDouble(POSITION_SL);
   double tp     = PositionGetDouble(POSITION_TP);
   double lots   = PositionGetDouble(POSITION_VOLUME);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    dgt    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickVal <= 0.0 || tickSz <= 0.0 || lots <= 0.0) return;

   // BREAK-EVEN: mover SL a entrada cuando profit >= InpBEAt
   if(!g_beApplied && profit >= InpBEAt)
   {
      double newSL = NormalizeDouble(entry, dgt);
      if(newSL > sl)
      {
         if(trade.PositionModify(g_openTicket, newSL, tp))
         {
            Print("Break-even aplicado: SL -> ", newSL);
            sl = newSL;
         }
      }
      g_beApplied = true;
   }

   // TRAILING STOP: activar cuando profit >= InpTrailFrom
   // Distancia en precio: InpTrailDist USD para el volumen actual
   if(profit >= InpTrailFrom)
   {
      double trailDist = InpTrailDist * tickSz / (tickVal * lots);
      double newSL     = NormalizeDouble(bid - trailDist, dgt);
      if(newSL > sl)
         trade.PositionModify(g_openTicket, newSL, tp);
   }
}

//+------------------------------------------------------------------+
//|  CALCULOS DE ESTADISTICAS DE PRECISION                         |
//+------------------------------------------------------------------+
string StatPrecision()
{
   int total = g_dayWins + g_dayLossCount;
   if(total == 0) return "---";
   return DoubleToString(g_dayWins * 100.0 / total, 1);
}

string StatProfitFactor()
{
   if(g_dayGrossLoss <= 0.0)
      return g_dayGrossWin > 0.0 ? "Perfecto" : "---";
   return DoubleToString(g_dayGrossWin / g_dayGrossLoss, 2);
}

color StatPrecisionColor()
{
   int total = g_dayWins + g_dayLossCount;
   if(total == 0) return clrYellow;
   double pct = g_dayWins * 100.0 / total;
   if(pct >= 60) return clrLime;
   if(pct >= 40) return clrYellow;
   return clrRed;
}

color StatPFColor()
{
   if(g_dayGrossLoss <= 0.0) return (g_dayGrossWin > 0.0) ? clrLime : clrYellow;
   double pf = g_dayGrossWin / g_dayGrossLoss;
   if(pf >= 1.5) return clrLime;
   if(pf >= 1.0) return clrYellow;
   return clrRed;
}

//+------------------------------------------------------------------+
//|  HELPERS                                                        |
//+------------------------------------------------------------------+
bool DiaExcedido()
{
   return g_dayGrossLoss >= g_dayStartBal * gc_maxLossDay / 100.0;
}

void ReadConfig()
{
   static datetime s_last = 0;
   static datetime s_diag = 0;
   if(TimeCurrent() - s_last < 1) return;
   s_last = TimeCurrent();
   string fname = "mbot_" + IntegerToString(InpMagicNumber) + ".cfg";
   int fh = FileOpen(fname, FILE_READ | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE) { if(TimeCurrent()-s_diag>=30){s_diag=TimeCurrent();Print("DIAG C500: archivo NO encontrado: ",fname);} return; }
   bool en_found = false; int en_val = 1;
   while(!FileIsEnding(fh))
   {
      string line = FileReadString(fh);
      StringTrimRight(line); StringTrimLeft(line);
      if(StringLen(line) == 0) continue;
      int sep = StringFind(line, "=");
      if(sep < 0) continue;
      string key = StringSubstr(line, 0, sep);
      string val = StringSubstr(line, sep + 1);
      if(key == "ENABLED")      { en_found=true; en_val=(int)StringToInteger(val); bool ns = en_val != 0; if(g_dashEnabled != ns) { g_dashEnabled = ns; Print("Dashboard: bot ", g_dashEnabled ? "ACTIVADO" : "DETENIDO"); } }
      if(key == "RSI_LEVEL")    gc_rsiLevel   = StringToDouble(val);
      if(key == "SL")           gc_sl         = StringToDouble(val);
      if(key == "TP")           gc_tp         = StringToDouble(val);
      if(key == "RISK_PCT")     gc_riskPct    = StringToDouble(val);
      if(key == "MAX_OPS_DAY")  gc_maxOpsDay  = (int)StringToInteger(val);
      if(key == "MAX_LOSS_DAY") gc_maxLossDay = StringToDouble(val);
      if(key == "MAX_CONSEC")   gc_maxConsec  = (int)StringToInteger(val);
   }
   FileClose(fh);
   if(TimeCurrent()-s_diag>=30){s_diag=TimeCurrent();Print("DIAG C500: ENABLED=",en_val," g_dashEnabled=",g_dashEnabled);}
}

void ResetDayIfNeeded()
{
   datetime hoy = DayStart();
   if(hoy == g_tradingDay) return;

   // Resumen del dia anterior
   double netAyer = g_dayGrossWin - g_dayGrossLoss;
   Print("── Cierre del dia ── W:", g_dayWins, " L:", g_dayLossCount,
         " Precision:", StatPrecision(), "% PF:", StatProfitFactor(),
         " P&L: $", DoubleToString(netAyer, 2));
   if(InpTelegram && InpTGToken != "" && InpTGChatID != "")
      SendTelegram(
         "Resumen del dia\n"
         "W/L: " + IntegerToString(g_dayWins) + "W - " + IntegerToString(g_dayLossCount) + "L\n"
         "Precision: " + StatPrecision() + "%\n"
         "Fact.Profit: " + StatProfitFactor() + "\n"
         "P&L neto: " + (netAyer >= 0.0 ? "+" : "") + DoubleToString(netAyer, 2) + " USD");

   g_tradingDay   = hoy;
   g_dayStartBal  = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dayTrades    = 0;
   g_dayWins      = 0;
   g_dayLossCount = 0;
   g_dayGrossWin  = 0;
   g_dayGrossLoss = 0;
   g_consecLoss   = 0;
   g_paused       = false;
   g_inImpulse    = false;
   Print("Nuevo dia — Balance: $", DoubleToString(g_dayStartBal, 2));
   if(InpTelegram && InpTGToken != "" && InpTGChatID != "")
      SendTelegram("Nuevo dia de trading\nBalance: $" + DoubleToString(g_dayStartBal, 2) + "\nEstado: ACTIVO");
}

datetime DayStart()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}


//+------------------------------------------------------------------+
//|  TELEGRAM                                                       |
//+------------------------------------------------------------------+
bool SendTelegram(string message)
{
   if(!InpTelegram || InpTGToken == "" || InpTGChatID == "") return false;

   string token   = InpTGToken;
   string chat_id = InpTGChatID;
   StringTrimLeft(token);   StringTrimRight(token);
   StringTrimLeft(chat_id); StringTrimRight(chat_id);

   string url     = "https://api.telegram.org/bot" + token + "/sendMessage";
   string headers = "Content-Type: application/json\r\n";
   string safe    = message;
   StringReplace(safe, "\\", "\\\\");
   StringReplace(safe, "\"", "\\\"");
   StringReplace(safe, "\n", "\\n");
   string json = "{\"chat_id\":\"" + chat_id + "\",\"text\":\"" + safe + "\"}";

   char post[], result[];
   string rheaders;
   StringToCharArray(json, post, 0, StringLen(json));
   ResetLastError();
   int res = WebRequest("POST", url, headers, 10000, post, result, rheaders);
   if(res == -1)
   {
      int    err  = GetLastError();
      string hint = (err == 4060) ? " >> Agrega 'api.telegram.org' en Herramientas>Opciones>Expertos>URLs" : "";
      Print("TELEGRAM ERROR: ", err, hint);
      return false;
   }
   return StringFind(CharArrayToString(result), "\"ok\":true") >= 0;
}

//+------------------------------------------------------------------+
//|  PANEL VISUAL                                                   |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = InpPanelX, y = InpPanelY, w = 248, h = 268;

   ObjectCreate(0, P_BG, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, P_BG, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, P_BG, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, P_BG, OBJPROP_XSIZE,      w);
   ObjectSetInteger(0, P_BG, OBJPROP_YSIZE,      h);
   ObjectSetInteger(0, P_BG, OBJPROP_BGCOLOR,    C'15,18,28');
   ObjectSetInteger(0, P_BG, OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0, P_BG, OBJPROP_COLOR,      clrOrangeRed);
   ObjectSetInteger(0, P_BG, OBJPROP_WIDTH,      1);
   ObjectSetInteger(0, P_BG, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, P_BG, OBJPROP_BACK,       false);

   MakeLabel(P_T1, "CRASHBOT 500  v1.10",
             x+8, y+5,  9, clrOrangeRed, true);
   MakeLabel(P_T2, "M1 | Solo BUY | RSI(" + IntegerToString(InpRSIPeriod) +
             ") | Magic: " + IntegerToString(InpMagicNumber),
             x+8, y+20, 7, clrSilver, false);

   int r = y + 44, gap = 21;

   // Fila 1: RSI
   MakeLabel(P_L1,  "RSI actual:",    x+8,  r,       9, clrWhite,  false);
   MakeLabel(P_V1,  "---",            x+158, r,       9, clrCyan,   false);
   // Fila 2: Senal
   MakeLabel(P_L2,  "Senal:",         x+8,  r+gap,     9, clrWhite,  false);
   MakeLabel(P_V2,  "ESPERANDO",      x+158, r+gap,     9, clrYellow, false);

   // Separador
   MakeLabel(P_SEP, "──────────────────────", x+8, r+gap*2-3, 7, C'50,55,70', false);

   // Fila 3: Ops hoy
   MakeLabel(P_L3,  "Ops hoy:",       x+8,  r+gap*2+9, 9, clrWhite,  false);
   MakeLabel(P_V3,  "0/" + IntegerToString(InpMaxDiarias),
                                      x+158, r+gap*2+9, 9, clrYellow, false);
   // Fila 4: W/L
   MakeLabel(P_L4,  "W / L:",         x+8,  r+gap*3+9, 9, clrWhite,  false);
   MakeLabel(P_V4,  "0W - 0L",        x+158, r+gap*3+9, 9, clrYellow, false);
   // Fila 5: Precision
   MakeLabel(P_L5,  "Precision:",     x+8,  r+gap*4+9, 9, clrWhite,  false);
   MakeLabel(P_V5,  "---.-%",         x+158, r+gap*4+9, 9, clrYellow, false);
   // Fila 6: Profit Factor
   MakeLabel(P_L6,  "Fact.Profit:",   x+8,  r+gap*5+9, 9, clrWhite,  false);
   MakeLabel(P_V6,  "---",            x+158, r+gap*5+9, 9, clrYellow, false);
   // Fila 7: P&L neto
   MakeLabel(P_L7,  "P&L neto:",      x+8,  r+gap*6+9, 9, clrWhite,  false);
   MakeLabel(P_V7,  "$0.00",          x+158, r+gap*6+9, 9, clrYellow, false);
   // Fila 8: Perd. dia
   MakeLabel(P_L8,  "Perd. dia:",     x+8,  r+gap*7+9, 9, clrWhite,  false);
   MakeLabel(P_V8,  "$0.00",          x+158, r+gap*7+9, 9, clrYellow, false);
   // Fila 9: Consecutivas
   MakeLabel(P_L9,  "Consec.perd:",   x+8,  r+gap*8+9, 9, clrWhite,  false);
   MakeLabel(P_V9,  "0",              x+158, r+gap*8+9, 9, clrYellow, false);
   // Fila 10: Estado
   MakeLabel(P_L10, "Estado:",        x+8,  r+gap*9+9, 9, clrWhite,  false);
   MakeLabel(P_V10, "ACTIVO",         x+158, r+gap*9+9, 9, clrLime,   false);

   ChartRedraw(0);
}

void UpdatePanel()
{
   // RSI actual (vela en curso, no confirmada)
   double rsi[];
   ArraySetAsSeries(rsi, true);
   string rsiStr = "---";
   color  rsiCol = clrCyan;
   if(CopyBuffer(g_hRSI, 0, 0, 1, rsi) == 1)
   {
      rsiStr = DoubleToString(rsi[0], 2);
      rsiCol = (rsi[0] < InpRSILevel) ? clrLime : clrCyan;
   }
   ObjectSetString(0,  P_V1, OBJPROP_TEXT,  rsiStr);
   ObjectSetInteger(0, P_V1, OBJPROP_COLOR, rsiCol);

   // Senal / estado operativo
   string sig  = g_paused        ? "PAUSADO"       :
                 !g_dashEnabled  ? "PAUSADO ⏸"    :
                 g_openTicket!=0 ? "EN OPERACION"  : "ESPERANDO";
   color  scol = g_paused        ? clrRed          :
                 !g_dashEnabled  ? clrOrange        :
                 g_openTicket!=0 ? clrLime          : clrYellow;
   ObjectSetString(0,  P_V2, OBJPROP_TEXT,  sig);
   ObjectSetInteger(0, P_V2, OBJPROP_COLOR, scol);

   // Ops hoy
   bool maxOps = (g_dayTrades >= gc_maxOpsDay);
   ObjectSetString(0,  P_V3, OBJPROP_TEXT,
      IntegerToString(g_dayTrades) + "/" + IntegerToString(gc_maxOpsDay));
   ObjectSetInteger(0, P_V3, OBJPROP_COLOR, maxOps ? clrRed : clrYellow);

   // W/L
   string wl = IntegerToString(g_dayWins) + "W  -  " + IntegerToString(g_dayLossCount) + "L";
   color wlCol = (g_dayWins > g_dayLossCount) ? clrLime :
                 (g_dayLossCount > g_dayWins)  ? clrRed  : clrYellow;
   ObjectSetString(0,  P_V4, OBJPROP_TEXT,  wl);
   ObjectSetInteger(0, P_V4, OBJPROP_COLOR, wlCol);

   // Precision
   ObjectSetString(0,  P_V5, OBJPROP_TEXT,  StatPrecision() + "%");
   ObjectSetInteger(0, P_V5, OBJPROP_COLOR, StatPrecisionColor());

   // Profit Factor
   ObjectSetString(0,  P_V6, OBJPROP_TEXT,  StatProfitFactor());
   ObjectSetInteger(0, P_V6, OBJPROP_COLOR, StatPFColor());

   // P&L neto del dia
   double net = g_dayGrossWin - g_dayGrossLoss;
   ObjectSetString(0,  P_V7, OBJPROP_TEXT,
      (net >= 0.0 ? "+$" : "-$") + DoubleToString(MathAbs(net), 2));
   ObjectSetInteger(0, P_V7, OBJPROP_COLOR, net >= 0.0 ? clrLime : clrRed);

   // Perdida del dia
   ObjectSetString(0,  P_V8, OBJPROP_TEXT,
      "$" + DoubleToString(g_dayGrossLoss, 2));
   ObjectSetInteger(0, P_V8, OBJPROP_COLOR,
      g_dayGrossLoss > 0 ? clrRed : clrYellow);

   // Consecutivas
   ObjectSetString(0,  P_V9, OBJPROP_TEXT,  IntegerToString(g_consecLoss));
   ObjectSetInteger(0, P_V9, OBJPROP_COLOR,
      g_consecLoss >= gc_maxConsec   ? clrRed   :
      g_consecLoss == gc_maxConsec-1 ? clrOrange : clrYellow);

   // Estado general
   string estGen  = (g_paused || !g_dashEnabled) ? "PAUSADO" : "ACTIVO";
   color  estColor= g_paused      ? clrRed    :
                    !g_dashEnabled ? clrOrange : clrLime;
   ObjectSetString(0,  P_V10, OBJPROP_TEXT,  estGen);
   ObjectSetInteger(0, P_V10, OBJPROP_COLOR, estColor);

   ChartRedraw(0);
}

void MakeLabel(string name, string text, int x, int y, int fs, color clr, bool bold)
{
   ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
   ObjectSetString(0,  name, OBJPROP_TEXT,       text);
   ObjectSetString(0,  name, OBJPROP_FONT,       bold ? "Arial Bold" : "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   fs);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clr);
   ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_LEFT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_BACK,       false);
}

void DeletePanel()
{
   string o[] = {P_BG, P_T1, P_T2, P_SEP,
                 P_L1, P_V1, P_L2, P_V2, P_L3,  P_V3,  P_L4,  P_V4,
                 P_L5, P_V5, P_L6, P_V6, P_L7,  P_V7,  P_L8,  P_V8,
                 P_L9, P_V9, P_L10,P_V10};
   for(int i = 0; i < ArraySize(o); i++) ObjectDelete(0, o[i]);
   ChartRedraw(0);
}
//+------------------------------------------------------------------+
