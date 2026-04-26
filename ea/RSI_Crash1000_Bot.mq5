//+------------------------------------------------------------------+
//|                        RSI_Crash1000_Bot.mq5                    |
//|              Bot RSI 14 - Nivel 27 - Compras en M1              |
//|         Estrategia: Cruce alcista del RSI desde nivel 27        |
//+------------------------------------------------------------------+
#property copyright   "Bot RSI Crash 1000 - M1"
#property version     "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Parámetros de entrada
input group "=== CONFIGURACIÓN RSI ==="
input int      RSI_Period      = 14;          // Período del RSI
input double   RSI_Level       = 27.0;        // Nivel RSI de activación
input ENUM_APPLIED_PRICE RSI_Price = PRICE_CLOSE;

input group "=== GESTIÓN DE RIESGO ==="
input double   SL_Dolares      = 3.0;         // Stop Loss en USD ($)
input double   TP_Dolares      = 1.0;         // Take Profit en USD ($)
input double   Lote            = 0.20;        // Tamaño del lote

input group "=== CONTROL DE RACHA ==="
input int      MaxPerdidasSeguidas  = 4;      // Máx. pérdidas seguidas para detener
input int      MaxGananciasSegidas  = 10;     // Máx. ganancias seguidas para detener

input group "=== CONFIGURACIÓN ==="
input bool                    BotActivo        = true;              // Bot activo al iniciar
input ulong                   MagicNumber      = 123456;            // Número mágico
input ENUM_ORDER_TYPE_FILLING InpFilling       = ORDER_FILLING_IOC; // Modo de relleno (IOC para Deriv)
input int                     InpSlippage      = 50;                // Deslizamiento máximo (puntos)

input group "=== TELEGRAM ==="
input string   TG_Token         = "";         // Token del bot
input string   TG_ChatID        = "";         // Chat ID
input bool     TG_Activo        = true;       // Activar notificaciones
input int      TG_PollSegundos  = 5;          // Frecuencia de lectura de comandos

//--- Variables globales
CTrade trade;
int    rsi_handle;
bool   bot_habilitado;
bool   g_dashEnabled  = true;   // Controlado desde el Dashboard web
int    racha_perdidas;

// Parámetros dinámicos — actualizados desde el Dashboard
double gc_rsiLevel     = 27.0;
double gc_sl           = 3.00;
double gc_tp           = 1.00;
double gc_lot          = 0.20;
int    gc_maxConsecLoss = 4;
int    gc_maxConsecWin  = 10;
int    racha_ganancias;
bool   operacion_abierta;
datetime ultima_barra;

//--- Variables para el panel
string panel_prefix = "RSI_BOT_";

//--- Estadísticas
int      ops_hoy        = 0;
double   dia_pnl        = 0;
int      dia_wins       = 0;
int      dia_losses     = 0;
datetime fecha_dia      = 0;

int      semana_trades  = 0;
int      semana_wins    = 0;
int      semana_losses  = 0;
double   semana_pnl     = 0;
double   semana_mejor   = 0;
double   semana_peor    = 0;

//--- Telegram
datetime tg_last_poll = 0;
string   GV_UID;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Configurar trade
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(InpFilling);
   trade.SetDeviationInPoints(InpSlippage);

   //--- Crear handle del RSI en M1
   rsi_handle = iRSI(_Symbol, PERIOD_M1, RSI_Period, RSI_Price);
   if(rsi_handle == INVALID_HANDLE)
     {
      Alert("Error al crear el indicador RSI. Código: ", GetLastError());
      return INIT_FAILED;
     }

   //--- Inicializar parámetros dinámicos desde inputs
   gc_rsiLevel      = RSI_Level;
   gc_sl            = SL_Dolares;
   gc_tp            = TP_Dolares;
   gc_lot           = Lote;
   gc_maxConsecLoss = MaxPerdidasSeguidas;
   gc_maxConsecWin  = MaxGananciasSegidas;

   //--- Inicializar variables
   bot_habilitado    = BotActivo;
   racha_perdidas    = 0;
   racha_ganancias   = 0;
   operacion_abierta = false;
   ultima_barra      = 0;

   //--- Telegram UID
   GV_UID = "RSIBOT_UID_" + IntegerToString(MagicNumber);

   //--- Verificar si hay posiciones abiertas de este bot al reiniciar
   VerificarPosicionesExistentes();

   //--- Dibujar panel visual
   DibujarPanel();

   Print("=== RSI Crash 1000 Bot INICIADO ===");
   Print("Símbolo: ", _Symbol, " | Timeframe: M1");
   Print("RSI: ", RSI_Period, " periodos, Nivel: ", RSI_Level);
   Print("SL: $", SL_Dolares, " | TP: $", TP_Dolares, " | Lote: ", Lote);
   Print("Máx. pérdidas seguidas: ", MaxPerdidasSeguidas);
   Print("Máx. ganancias seguidas: ", MaxGananciasSegidas);

   if(TG_Activo && StringLen(TG_Token) > 10)
   {
      string msg = "🤖 <b>RSI Bot Crash 1000</b> INICIADO\n"
                 + "📊 Símbolo: <b>" + _Symbol + "</b>\n"
                 + "⚙️ SL: $" + DoubleToString(SL_Dolares,2)
                 + " | TP: $" + DoubleToString(TP_Dolares,2)
                 + " | Lote: " + DoubleToString(Lote,2) + "\n"
                 + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2) + "\n"
                 + "📲 Comandos: /estado /comprar /cerrar /detener /activar /reporte /ayuda";
      EnviarTelegram(msg);
   }

   RegisterWithDashboard();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|  REGISTRO EN DASHBOARD                                           |
//+------------------------------------------------------------------+
void RegisterWithDashboard()
  {
   string fname = "mreg_" + IntegerToString(MagicNumber) + ".cfg";
   int fh = FileOpen(fname, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE) { Print("WARN: no se pudo crear ", fname); return; }
   FileWriteString(fh, "NAME=Crash 1000 BUY\n");
   FileWriteString(fh, "SYMBOL=" + _Symbol + "\n");
   FileWriteString(fh, "MAGIC=" + IntegerToString(MagicNumber) + "\n");
   FileWriteString(fh, "EA=crash1000\n");
   FileClose(fh);
   Print("Dashboard: registrado como crash1000 en ", fname);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(rsi_handle != INVALID_HANDLE)
      IndicatorRelease(rsi_handle);
   EliminarPanel();
   Print("Bot detenido. Razón: ", reason);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   RevisarNuevoDia();

   //--- Polling Telegram
   if(TG_Activo && StringLen(TG_Token) > 10)
      if(TimeCurrent() - tg_last_poll >= TG_PollSegundos)
        {
         ProcesarComandosTelegram();
         tg_last_poll = TimeCurrent();
        }

   //--- Control desde Dashboard web
   ReadConfig();

   //--- Verificar si el bot está habilitado
   if(!bot_habilitado || !g_dashEnabled)
     {
      ActualizarPanel();
      return;
     }

   //--- Obtener valores del RSI
   double rsi_buffer[];
   ArraySetAsSeries(rsi_buffer, true);

   if(CopyBuffer(rsi_handle, 0, 0, 3, rsi_buffer) < 3)
      return;

   double rsi_actual   = rsi_buffer[0]; // Barra actual (en formación)
   double rsi_cerrada  = rsi_buffer[1]; // Barra anterior cerrada
   double rsi_previa   = rsi_buffer[2]; // Dos barras atrás

   //--- Verificar si hay posición abierta de este bot
   operacion_abierta = HayPosicionAbierta();

   //--- Si hay posición abierta, solo monitorear
   if(operacion_abierta)
     {
      ActualizarPanel();
      return;
     }

   //--- Detectar nueva barra (para señales en cierre de vela)
   datetime barra_actual_time = iTime(_Symbol, PERIOD_M1, 0);

   //--- Detectar cruce alcista del RSI en la barra cerrada
   //    Condición: barra anterior (cerrada) estaba DEBAJO del nivel
   //    y la barra actual SUPERA el nivel → cruce confirmado
   bool cruce_alcista = (rsi_previa < gc_rsiLevel) && (rsi_cerrada >= gc_rsiLevel);

   //--- También podemos detectar en tiempo real con la barra en curso
   //    Solo si la barra cerrada estuvo debajo y la actual está por encima
   bool cruce_tiempo_real = (rsi_cerrada < gc_rsiLevel) && (rsi_actual >= gc_rsiLevel);

   //--- Usar cruce en tiempo real para entrada más rápida (Crash 1000 es volátil)
   if(cruce_tiempo_real || cruce_alcista)
     {
      //--- Verificar que no ejecutamos dos veces en la misma barra
      if(barra_actual_time != ultima_barra || cruce_alcista)
        {
         if(cruce_alcista)
            ultima_barra = iTime(_Symbol, PERIOD_M1, 1);
         else
            ultima_barra = barra_actual_time;

         AbrirCompra(rsi_actual);
        }
     }

   ActualizarPanel();
  }

//+------------------------------------------------------------------+
//| Función para abrir orden de compra                              |
//+------------------------------------------------------------------+
void AbrirCompra(double rsi_valor)
  {
   double precio_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double precio_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double punto      = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int    digitos    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //--- Calcular SL y TP en puntos basados en USD
   //    Fórmula: puntos = (USD_objetivo / tick_value) * tick_size / lote
   double valor_punto_por_lote = tick_value / tick_size;
   double puntos_sl = (gc_sl / (valor_punto_por_lote * gc_lot));
   double puntos_tp = (gc_tp / (valor_punto_por_lote * gc_lot));

   //--- Convertir a precio
   double sl_precio = NormalizeDouble(precio_ask - puntos_sl, digitos);
   double tp_precio = NormalizeDouble(precio_ask + puntos_tp, digitos);

   //--- Verificar niveles mínimos del broker
   long nivel_stops = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_distancia = nivel_stops * punto;

   if((precio_ask - sl_precio) < min_distancia)
      sl_precio = NormalizeDouble(precio_ask - min_distancia - punto * 2, digitos);

   if((tp_precio - precio_ask) < min_distancia)
      tp_precio = NormalizeDouble(precio_ask + min_distancia + punto * 2, digitos);

   //--- Ejecutar la orden
   string comentario = StringFormat("RSI_BOT|RSI=%.2f|SL=$%.2f|TP=$%.2f", rsi_valor, gc_sl, gc_tp);

   if(trade.Buy(gc_lot, _Symbol, precio_ask, sl_precio, tp_precio, comentario))
     {
      operacion_abierta = true;
      Print("✅ COMPRA abierta | Precio: ", precio_ask,
            " | SL: ", sl_precio, " ($", gc_sl, ")",
            " | TP: ", tp_precio, " ($", gc_tp, ")",
            " | RSI: ", DoubleToString(rsi_valor, 2));
      if(TG_Activo && StringLen(TG_Token) > 10)
        {
         string msg = "🟢 <b>COMPRA — Crash 1000 Index</b>\n"
                    + "💲 Precio: " + DoubleToString(precio_ask, digitos) + "\n"
                    + "📦 Lote: " + DoubleToString(gc_lot, 2) + "\n"
                    + "🛑 SL: $" + DoubleToString(gc_sl, 2)
                    + " | 🎯 TP: $" + DoubleToString(gc_tp, 2) + "\n"
                    + "📊 RSI: " + DoubleToString(rsi_valor, 2);
         EnviarTelegram(msg);
        }
     }
   else
     {
      int error = GetLastError();
      Print("❌ Error al abrir compra. Código: ", error, " - ", trade.ResultRetcodeDescription());
     }
  }

//+------------------------------------------------------------------+
//| Verificar si hay posición abierta del bot                       |
//+------------------------------------------------------------------+
bool HayPosicionAbierta()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
        {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
            return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Verificar posiciones existentes al reiniciar                    |
//+------------------------------------------------------------------+
void VerificarPosicionesExistentes()
  {
   operacion_abierta = HayPosicionAbierta();
   if(operacion_abierta)
      Print("ℹ️ Se detectó una posición abierta existente del bot.");
  }

//+------------------------------------------------------------------+
//| Evento al cerrar transacción                                    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
  {
   //--- Solo nos interesa cuando se cierra una posición
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
     {
      if(HistoryDealSelect(trans.deal))
        {
         long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
         if(magic != (long)MagicNumber) return;

         long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
           {
            double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                          + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION)
                          + HistoryDealGetDouble(trans.deal, DEAL_SWAP);
            ProcesarResultado(profit);
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Procesar resultado de operación cerrada                         |
//+------------------------------------------------------------------+
void ProcesarResultado(double profit)
  {
   operacion_abierta = false;
   ops_hoy++;
   dia_pnl      += profit;
   semana_trades++;
   semana_pnl   += profit;
   if(profit > semana_mejor) semana_mejor = profit;
   if(profit < semana_peor)  semana_peor  = profit;
   string tipo_resultado;

   if(profit >= 0.0)
     {
      racha_perdidas  = 0;
      racha_ganancias++;
      dia_wins++;
      semana_wins++;
      tipo_resultado  = StringFormat("GANANCIA +$%.2f", profit);

      Print("💰 ", tipo_resultado, " | Racha ganancias: ", racha_ganancias);

      if(TG_Activo && StringLen(TG_Token) > 10)
        {
         string msg = "✅ <b>GANANCIA — Crash 1000 Index</b>\n"
                    + "💵 +$" + DoubleToString(profit, 2) + "\n"
                    + "Racha ganancias: " + IntegerToString(racha_ganancias) + "\n"
                    + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2);
         EnviarTelegram(msg);
        }

      if(racha_ganancias >= gc_maxConsecWin)
        {
         bot_habilitado = false;
         Print("🛑 Bot DETENIDO: Se alcanzaron ", gc_maxConsecWin,
               " ganancias seguidas. Actívalo manualmente.");
         Alert("RSI Bot: DETENIDO por ", gc_maxConsecWin,
               " ganancias seguidas. Reactivar manualmente.");
         if(TG_Activo && StringLen(TG_Token) > 10)
            EnviarTelegram("🛑 <b>Bot DETENIDO</b>\n"
                          + IntegerToString(gc_maxConsecWin) + " ganancias seguidas.\n"
                          + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n"
                          + "Envía /activar para reanudar.");
        }
     }
   else
     {
      racha_ganancias = 0;
      racha_perdidas++;
      dia_losses++;
      semana_losses++;
      tipo_resultado  = StringFormat("PÉRDIDA -$%.2f", MathAbs(profit));

      Print("❌ ", tipo_resultado, " | Racha pérdidas: ", racha_perdidas);

      if(TG_Activo && StringLen(TG_Token) > 10)
        {
         string msg = "❌ <b>PÉRDIDA — Crash 1000 Index</b>\n"
                    + "💵 -$" + DoubleToString(MathAbs(profit), 2) + "\n"
                    + "Racha pérdidas: " + IntegerToString(racha_perdidas) + "\n"
                    + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2);
         EnviarTelegram(msg);
        }

      if(racha_perdidas >= gc_maxConsecLoss)
        {
         bot_habilitado = false;
         Print("🛑 Bot DETENIDO: Se alcanzaron ", gc_maxConsecLoss,
               " pérdidas seguidas. Actívalo manualmente.");
         Alert("RSI Bot: DETENIDO por ", gc_maxConsecLoss,
               " pérdidas seguidas. Reactivar manualmente.");
         if(TG_Activo && StringLen(TG_Token) > 10)
            EnviarTelegram("🛑 <b>Bot DETENIDO</b>\n"
                          + IntegerToString(gc_maxConsecLoss) + " pérdidas seguidas.\n"
                          + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + "\n"
                          + "Envía /activar para reanudar.");
        }
     }

   ActualizarPanel();
  }

//+------------------------------------------------------------------+
// Helpers de panel
void PRect(string n, int x, int y, int w, int h, color bg, color bd)
{
   ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);     ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);  ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,bd);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);  ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
}

void PSeccion(string pfx, int px, int py, int pw, color ac, string txt)
{
   PRect(pfx+"Bg", px+1, py, pw-2, 16, C'15,20,40', C'15,20,40');
   PRect(pfx+"Ac", px+1, py, 3,    16, ac, ac);
   CrearLabel(pfx+"Tx", txt, px+10, py+3, ac, 7, true);
}

//+------------------------------------------------------------------+
//| Control desde Dashboard web (lee archivo .ctrl cada 5 seg)     |
//+------------------------------------------------------------------+
void ReadConfig()
  {
   static datetime s_last = 0;
   static datetime s_diag = 0;
   if(TimeCurrent() - s_last < 1) return;
   s_last = TimeCurrent();
   string fname = "mbot_" + IntegerToString(MagicNumber) + ".cfg";
   int fh = FileOpen(fname, FILE_READ | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE) { if(TimeCurrent()-s_diag>=30){s_diag=TimeCurrent();Print("DIAG C1000: archivo NO encontrado: ",fname);} return; }
   int en_val = 1;
   while(!FileIsEnding(fh))
     {
      string line = FileReadString(fh);
      StringTrimRight(line); StringTrimLeft(line);
      if(StringLen(line) == 0) continue;
      int sep = StringFind(line, "=");
      if(sep < 0) continue;
      string key = StringSubstr(line, 0, sep);
      string val = StringSubstr(line, sep + 1);
      if(key == "ENABLED")       { en_val=(int)StringToInteger(val); bool ns = en_val != 0; if(g_dashEnabled != ns) { g_dashEnabled = ns; Print("Dashboard: bot ", g_dashEnabled ? "ACTIVADO" : "DETENIDO"); } }
      if(key == "RSI_LEVEL")     gc_rsiLevel      = StringToDouble(val);
      if(key == "SL")            gc_sl            = StringToDouble(val);
      if(key == "TP")            gc_tp            = StringToDouble(val);
      if(key == "LOT")           gc_lot           = StringToDouble(val);
      if(key == "MAX_CONSEC_LOSS") gc_maxConsecLoss = (int)StringToInteger(val);
      if(key == "MAX_CONSEC_WIN")  gc_maxConsecWin  = (int)StringToInteger(val);
     }
   FileClose(fh);
   if(TimeCurrent()-s_diag>=30){s_diag=TimeCurrent();Print("DIAG C1000: ENABLED=",en_val," g_dashEnabled=",g_dashEnabled);}
  }

//+------------------------------------------------------------------+
//|                    PANEL VISUAL EN EL GRÁFICO                   |
//+------------------------------------------------------------------+
void DibujarPanel()
  {
   int px=12, py=12, pw=312, ph=390;
   int lx=26, rx=204;

   ObjectsDeleteAll(0, panel_prefix);

   PRect(panel_prefix+"Main", px,py,pw,ph, C'8,8,20', C'0,180,220');
   PRect(panel_prefix+"Top",  px,py,pw,18, C'0,150,200', C'0,150,200');
   CrearLabel(panel_prefix+"Title", "RSI BOT  CRASH 1000  v1.1", px+10, py+3, C'220,240,255', 8, true);

   // Estado + Telegram
   CrearLabel(panel_prefix+"EstL",  "ESTADO",   lx,  py+24, C'100,120,150', 7, false);
   CrearLabel(panel_prefix+"EstV",  "ACTIVO ✓", rx,  py+24, C'0,220,120',   8, true);
   CrearLabel(panel_prefix+"TgL",   "Telegram", lx,  py+38, C'100,120,150', 7, false);
   CrearLabel(panel_prefix+"TgV",   "OFF",      rx,  py+38, C'180,60,60',   7, false);

   // CUENTA
   PSeccion(panel_prefix+"SCta", px, py+54, pw, C'0,180,220', "CUENTA");
   CrearLabel(panel_prefix+"BalL",  "Balance",     lx, py+74,  C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"BalV",  "--",           rx, py+74,  C'200,230,255', 8, true);
   CrearLabel(panel_prefix+"EqL",   "Equity",      lx, py+88,  C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"EqV",   "--",           rx, py+88,  C'200,230,255', 8, true);
   CrearLabel(panel_prefix+"LotL",  "Lote",        lx, py+102, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"LotV",  "--",           rx, py+102, C'200,230,255', 8, true);
   CrearLabel(panel_prefix+"PlFL",  "P&L flotante",lx, py+116, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"PlFV",  "--",           rx, py+116, C'200,230,255', 8, true);

   // HOY
   PSeccion(panel_prefix+"SHoy", px, py+134, pw, C'255,160,0', "HOY");
   CrearLabel(panel_prefix+"OpsL",  "Operaciones", lx, py+154, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"OpsV",  "--",           rx, py+154, C'200,230,255', 7, false);
   CrearLabel(panel_prefix+"PnlL",  "P&L hoy",     lx, py+168, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"PnlV",  "--",           rx, py+168, C'200,230,255', 8, true);
   CrearLabel(panel_prefix+"RcL",   "Racha P / G", lx, py+182, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"RcV",   "--",           rx, py+182, C'200,230,255', 7, false);

   // SEMANA
   PSeccion(panel_prefix+"SSem", px, py+200, pw, C'0,200,120', "SEMANA");
   CrearLabel(panel_prefix+"SwL",  "Trades / WR",  lx, py+220, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"SwV",  "--",            rx, py+220, C'200,230,255', 7, false);
   CrearLabel(panel_prefix+"SpL",  "P&L semanal",  lx, py+234, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"SpV",  "--",            rx, py+234, C'200,230,255', 8, true);

   // SEÑAL & MERCADO
   PSeccion(panel_prefix+"SSig", px, py+252, pw, C'180,100,255', "SEÑAL  &  MERCADO");
   CrearLabel(panel_prefix+"RsiL",  "RSI actual",  lx, py+272, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"RsiV",  "--",           rx, py+272, C'200,230,255', 7, false);
   CrearLabel(panel_prefix+"SprdL", "Spread",      lx, py+286, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"SprdV", "--",           rx, py+286, C'200,230,255', 7, false);
   CrearLabel(panel_prefix+"SlL",   "SL / TP",     lx, py+300, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"SlV",   "$"+DoubleToString(gc_sl,2)+" / $"+DoubleToString(gc_tp,2),
                                                    rx, py+300, C'200,230,255', 7, false);

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Actualizar panel con datos en tiempo real                       |
//+------------------------------------------------------------------+
void ActualizarPanel()
  {
   if(ObjectFind(0, panel_prefix+"Main") < 0) DibujarPanel();

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   // Estado
   string est_txt; color est_col;
   if(operacion_abierta)
     { est_txt = "EN POSICION"; est_col = clrAqua; }
   else if(!g_dashEnabled)
     { est_txt = "PAUSADO ⏸";  est_col = C'255,140,0'; }
   else if(bot_habilitado)
     { est_txt = "ACTIVO  ✓";  est_col = C'0,220,120'; }
   else
     { est_txt = "DETENIDO ✗"; est_col = C'255,60,60'; }
   ObjectSetString(0,  panel_prefix+"EstV", OBJPROP_TEXT,  est_txt);
   ObjectSetInteger(0, panel_prefix+"EstV", OBJPROP_COLOR, est_col);

   // Telegram
   string tgs = (TG_Activo && StringLen(TG_Token)>10) ? "ON" : "OFF";
   color  tgc = (TG_Activo && StringLen(TG_Token)>10) ? C'0,200,100' : C'180,60,60';
   ObjectSetString(0,  panel_prefix+"TgV", OBJPROP_TEXT,  tgs);
   ObjectSetInteger(0, panel_prefix+"TgV", OBJPROP_COLOR, tgc);

   // Cuenta
   ObjectSetString(0, panel_prefix+"BalV", OBJPROP_TEXT, "$"+DoubleToString(balance,2));
   ObjectSetString(0, panel_prefix+"EqV",  OBJPROP_TEXT, "$"+DoubleToString(equity,2));
   ObjectSetString(0, panel_prefix+"LotV", OBJPROP_TEXT, DoubleToString(gc_lot,2)+" lotes");
   ObjectSetString(0, panel_prefix+"SlV",  OBJPROP_TEXT, "$"+DoubleToString(gc_sl,2)+" / $"+DoubleToString(gc_tp,2));

   double pnl_fl = 0;
   if(operacion_abierta)
      for(int i=0; i<PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
         pnl_fl = PositionGetDouble(POSITION_PROFIT);
         break;
        }
   ObjectSetString(0,  panel_prefix+"PlFV", OBJPROP_TEXT,  "$"+DoubleToString(pnl_fl,2));
   ObjectSetInteger(0, panel_prefix+"PlFV", OBJPROP_COLOR, pnl_fl>=0.0 ? C'0,220,120' : C'255,80,80');

   // Hoy
   ObjectSetString(0, panel_prefix+"OpsV", OBJPROP_TEXT,
      IntegerToString(ops_hoy)+" ops | "+IntegerToString(dia_wins)+"W / "+IntegerToString(dia_losses)+"L");
   ObjectSetString(0,  panel_prefix+"PnlV", OBJPROP_TEXT,  "$"+DoubleToString(dia_pnl,2));
   ObjectSetInteger(0, panel_prefix+"PnlV", OBJPROP_COLOR, dia_pnl>=0.0 ? C'0,220,120' : C'255,80,80');
   ObjectSetString(0, panel_prefix+"RcV", OBJPROP_TEXT,
      IntegerToString(racha_perdidas)+"/"+IntegerToString(gc_maxConsecLoss)
      +"  —  "+IntegerToString(racha_ganancias)+"/"+IntegerToString(gc_maxConsecWin));

   // Semana
   int sw_tot = semana_wins+semana_losses;
   double sw_wr = sw_tot>0 ? (double)semana_wins/sw_tot*100 : 0;
   ObjectSetString(0, panel_prefix+"SwV", OBJPROP_TEXT,
      IntegerToString(semana_trades)+" / "+DoubleToString(sw_wr,1)+"%");
   ObjectSetString(0,  panel_prefix+"SpV", OBJPROP_TEXT,  "$"+DoubleToString(semana_pnl,2));
   ObjectSetInteger(0, panel_prefix+"SpV", OBJPROP_COLOR, semana_pnl>=0.0 ? C'0,220,120' : C'255,80,80');

   // RSI y mercado
   double rsi_buf[];
   ArraySetAsSeries(rsi_buf, true);
   if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_buf) > 0)
     {
      ObjectSetString(0,  panel_prefix+"RsiV", OBJPROP_TEXT,  DoubleToString(rsi_buf[0],2)+" pts");
      ObjectSetInteger(0, panel_prefix+"RsiV", OBJPROP_COLOR,
         rsi_buf[0] < gc_rsiLevel ? C'255,160,0' : C'0,200,120');
     }
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   ObjectSetString(0,  panel_prefix+"SprdV", OBJPROP_TEXT,  IntegerToString(spread)+" pts");
   ObjectSetInteger(0, panel_prefix+"SprdV", OBJPROP_COLOR, C'200,230,255');

   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
void RevisarNuevoDia()
{
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   tm.hour=0; tm.min=0; tm.sec=0;
   datetime hoy = StructToTime(tm);
   if(fecha_dia == hoy) return;

   if(fecha_dia > 0 && ops_hoy > 0 && TG_Activo && StringLen(TG_Token)>10)
   {
      int tot = dia_wins+dia_losses;
      double wr = tot>0 ? (double)dia_wins/tot*100 : 0;
      EnviarTelegram("📅 <b>Resumen del día</b>\n"
                   + "Ops: "+IntegerToString(ops_hoy)
                   + " | "+IntegerToString(dia_wins)+"W / "+IntegerToString(dia_losses)+"L"
                   + " | WR: "+DoubleToString(wr,1)+"%\n"
                   + "P&L: $"+DoubleToString(dia_pnl,2)+"\n"
                   + "💰 Balance: $"+DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
   }

   fecha_dia  = hoy;
   ops_hoy    = 0; dia_pnl   = 0;
   dia_wins   = 0; dia_losses = 0;
   if(tm.day_of_week == 1)
   {
      semana_trades=0; semana_wins=0; semana_losses=0;
      semana_pnl=0;    semana_mejor=0; semana_peor=0;
   }
}

//+------------------------------------------------------------------+
//| Eliminar todos los objetos del panel                            |
//+------------------------------------------------------------------+
void EliminarPanel()
  {
   ObjectsDeleteAll(0, panel_prefix);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Crear label en el gráfico                                       |
//+------------------------------------------------------------------+
void CrearLabel(string nombre, string texto, int x, int y,
                color col, int tam, bool negrita)
  {
   ObjectCreate(0, nombre, OBJ_LABEL, 0, 0, 0);
   ObjectSetString(0, nombre, OBJPROP_TEXT, texto);
   ObjectSetInteger(0, nombre, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nombre, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, nombre, OBJPROP_COLOR, col);
   ObjectSetInteger(0, nombre, OBJPROP_FONTSIZE, tam);
   ObjectSetString(0, nombre, OBJPROP_FONT, negrita ? "Arial Bold" : "Arial");
   ObjectSetInteger(0, nombre, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, nombre, OBJPROP_BACK, false);
   ObjectSetInteger(0, nombre, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| Reactivación manual: presionar botón o cambiar input            |
//| El operador puede reactivar el bot cambiando el parámetro       |
//| BotActivo = true desde los inputs del EA en el gráfico.         |
//+------------------------------------------------------------------+
//  NOTA: Para reactivar manualmente, el operador debe ir a:
//  Clic derecho en el gráfico → Asesores Expertos → Propiedades
//  → Parámetros de entrada → BotActivo = true → Aceptar
//  O bien usar el botón "Reiniciar" del EA en el panel.
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
string UrlEncode(string s)
{
   uchar utf8[];
   StringToCharArray(s, utf8, 0, WHOLE_ARRAY, 65001);
   int n = ArraySize(utf8);
   if(n > 0 && utf8[n-1] == 0) n--;
   string r = "";
   for(int i = 0; i < n; i++)
   {
      uchar c = utf8[i];
      if((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')
         ||c=='-'||c=='_'||c=='.'||c=='~')
         r += ShortToString(c);
      else if(c == ' ')
         r += "+";
      else
         r += "%" + StringFormat("%02X", c);
   }
   return r;
}

//+------------------------------------------------------------------+
void EnviarTelegram(string mensaje)
{
   if(!TG_Activo || StringLen(TG_Token) < 10 || StringLen(TG_ChatID) < 5) return;
   string url  = "https://api.telegram.org/bot" + TG_Token + "/sendMessage";
   string body = "chat_id=" + TG_ChatID + "&parse_mode=HTML&text=" + UrlEncode(mensaje);
   char req[], res[];
   string req_hdrs  = "Content-Type: application/x-www-form-urlencoded\r\n";
   string resp_hdrs = "";
   StringToCharArray(body, req, 0, StringLen(body));
   int code = WebRequest("POST", url, req_hdrs, 5000, req, res, resp_hdrs);
   if(code != 200)
      Print("⚠ Telegram error HTTP: ", code);
}

//+------------------------------------------------------------------+
void ProcesarComandosTelegram()
{
   string url = "https://api.telegram.org/bot" + TG_Token
              + "/getUpdates?offset=" + IntegerToString((int)GlobalVariableGet(GV_UID) + 1)
              + "&limit=5&timeout=1";
   char req[], res[];
   string hdrs;
   int code = WebRequest("GET", url, "", 5000, req, res, hdrs);
   if(code != 200 || ArraySize(res) == 0) return;

   string json = CharArrayToString(res);
   int desde = 0;
   while(true)
   {
      int pos = StringFind(json, "\"update_id\":", desde);
      if(pos < 0) break;
      double uid = ExtraerNum(json, "update_id", pos);
      if(uid <= GlobalVariableGet(GV_UID)) { desde = pos + 1; continue; }
      GlobalVariableSet(GV_UID, uid);
      string txt = ExtraerStr(json, "text", pos);
      if(StringLen(txt) > 0) ProcesarComando(txt);
      desde = pos + 1;
   }
}

//+------------------------------------------------------------------+
void ProcesarComando(string cmd)
{
   StringToLower(cmd);
   int sp = StringFind(cmd, " ");
   if(sp > 0) cmd = StringSubstr(cmd, 0, sp);

   // Comandos globales — ambos bots responden
   if(cmd == "/estado" || cmd == "/status")
   {
      double rsi_buf[];
      ArraySetAsSeries(rsi_buf, true);
      string rsi_str = "N/D";
      if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_buf) > 0)
         rsi_str = DoubleToString(rsi_buf[0], 2);
      EnviarTelegram((bot_habilitado ? "🟢" : "🔴") + " <b>Crash 1000</b>\n"
                   + "💰 $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2) + "\n"
                   + "📈 " + (operacion_abierta ? "En posición" : "Sin posición") + "\n"
                   + "Racha P/G: " + IntegerToString(racha_perdidas) + "/" + IntegerToString(racha_ganancias) + "\n"
                   + "RSI: " + rsi_str);
      return;
   }
   if(cmd == "/ayuda" || cmd == "/help")
   {
      EnviarTelegram("📋 <b>Crash 1000:</b>\n"
                   + "/estado  /ayuda\n\n"
                   + "/comprar1  /cerrar1\n"
                   + "/detener1  /activar1\n"
                   + "/reporte1");
      return;
   }

   // Comandos exclusivos Crash 1000 — sufijo 1
   if(cmd == "/detener1")
   {
      if(!bot_habilitado) { EnviarTelegram("ℹ️ Crash 1000 ya estaba detenido."); return; }
      bot_habilitado = false;
      EnviarTelegram("🛑 <b>Crash 1000 DETENIDO</b>\nEnvía /activar1 para reanudar.");
   }
   else if(cmd == "/activar1")
   {
      if(bot_habilitado) { EnviarTelegram("ℹ️ Crash 1000 ya estaba activo."); return; }
      bot_habilitado = true;
      racha_perdidas = 0; racha_ganancias = 0;
      EnviarTelegram("✅ <b>Crash 1000 REACTIVADO</b>");
   }
   else if(cmd == "/cerrar1")
   {
      if(!operacion_abierta) { EnviarTelegram("ℹ️ Crash 1000: Sin posición abierta."); return; }
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
         if(trade.PositionClose(t))
            EnviarTelegram("✅ Crash 1000: Posición cerrada.\n💰 $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
         else EnviarTelegram("❌ Crash 1000: Error al cerrar.");
         break;
      }
   }
   else if(cmd == "/comprar1")
   {
      if(!bot_habilitado) { EnviarTelegram("Crash 1000 detenido. Usa /activar1."); return; }
      if(operacion_abierta) { EnviarTelegram("Crash 1000: Ya hay posición."); return; }
      double rsi_now[];
      ArraySetAsSeries(rsi_now, true);
      if(CopyBuffer(rsi_handle, 0, 0, 1, rsi_now) < 1) return;
      EnviarTelegram("📲 Crash 1000: Abriendo compra...");
      AbrirCompra(rsi_now[0]);
   }
   else if(cmd == "/reporte1")
   {
      int tot = semana_wins+semana_losses;
      double wr = tot>0 ? (double)semana_wins/tot*100 : 0;
      EnviarTelegram("📊 <b>Semana — Crash 1000</b>\n"
                   + "Trades: "+IntegerToString(semana_trades)
                   + " | WR: "+DoubleToString(wr,1)+"%\n"
                   + "P&L: $"+DoubleToString(semana_pnl,2)+"\n"
                   + "Mejor: $"+DoubleToString(semana_mejor,2)
                   + " | Peor: $"+DoubleToString(semana_peor,2));
   }
   // Ignorar comandos del C900
}

//+------------------------------------------------------------------+
double ExtraerNum(const string& json, string clave, int desde)
{
   string b = "\"" + clave + "\":";
   int i = StringFind(json, b, desde);
   if(i < 0) return 0;
   i += StringLen(b);
   string n = "";
   while(i < StringLen(json))
   {
      ushort c = StringGetCharacter(json, i);
      if(c == ',' || c == '}' || c == ']' || c == ' ') break;
      n += ShortToString(c); i++;
   }
   return StringToDouble(n);
}

string ExtraerStr(const string& json, string clave, int desde)
{
   string b = "\"" + clave + "\":";
   int i = StringFind(json, b, desde);
   if(i < 0) return "";
   i += StringLen(b);
   while(i < StringLen(json) && StringGetCharacter(json, i) == ' ') i++;
   if(StringGetCharacter(json, i) != '"') return "";
   i++;
   string v = "";
   while(i < StringLen(json))
   {
      ushort c = StringGetCharacter(json, i);
      if(c == '"') break;
      v += ShortToString(c); i++;
   }
   return v;
}
