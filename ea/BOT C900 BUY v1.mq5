//+------------------------------------------------------------------+
//|                      BOT C900 BUY  v1.0                          |
//|        Estrategia RSI — Crash 900 Index — M1 Compras             |
//+------------------------------------------------------------------+
#property copyright "BOT C900 BUY v1.0"
#property version   "1.00"
#property strict
#include <Trade\Trade.mqh>

//--- CONFIG
input group "=== SEÑAL RSI ==="
input int      RSI_Period      = 14;
input double   RSI_LevelBuy    = 24.0;

input group "=== GESTIÓN DE RIESGO ==="
input double   LotSize         = 0.50;
input double   TakeProfit_USD  = 5.0;
input double   StopLoss_USD    = 5.0;

input group "=== LÍMITES DIARIOS ==="
input double   DailyProfit_USD = 25.0;
input int      MaxDailyLosses  = 3;

input group "=== CONFIGURACIÓN ==="
input ulong                    MagicNumber  = 789012;
input ENUM_ORDER_TYPE_FILLING  InpFilling   = ORDER_FILLING_IOC;
input int                      InpSlippage  = 50;

input group "=== TELEGRAM ==="
input string   TG_Token        = "";
input string   TG_ChatID       = "";
input bool     TG_Activo       = true;
input int      TG_PollSegundos = 5;

//--- VARIABLES
CTrade   trade;
int      rsiHandle;
bool     g_dashEnabled = true;   // Controlado desde el Dashboard web

// Parámetros dinámicos — actualizados desde el Dashboard
double   gc_rsiLevel   = 24.0;
double   gc_sl         = 5.00;
double   gc_tp         = 5.00;
double   gc_lot        = 0.50;
int      gc_maxLossDay = 3;
double   rsiBuffer[];
double   dailyProfit    = 0;
int      dailyLosses    = 0;
bool     tradingAllowed = true;
datetime lastDayChecked = 0;

//--- ESTADÍSTICAS
int      ops_hoy       = 0;
double   dia_pnl       = 0;
int      dia_wins      = 0;
int      dia_losses    = 0;
int      semana_trades = 0;
int      semana_wins   = 0;
int      semana_losses = 0;
double   semana_pnl    = 0;
double   semana_mejor  = 0;
double   semana_peor   = 0;

//--- PANEL Y TELEGRAM
string   panel_prefix  = "C900BUY_BOT_";
datetime tg_last_poll  = 0;
string   GV_UID;

//+------------------------------------------------------------------+
int OnInit()
{
   rsiHandle = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE) { Alert("Error al crear RSI"); return INIT_FAILED; }
   ArraySetAsSeries(rsiBuffer, true);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(InpFilling);
   trade.SetDeviationInPoints(InpSlippage);

   gc_rsiLevel   = RSI_LevelBuy;
   gc_sl         = StopLoss_USD;
   gc_tp         = TakeProfit_USD;
   gc_lot        = LotSize;
   gc_maxLossDay = MaxDailyLosses;

   GV_UID = "C900BUY_UID_" + IntegerToString(MagicNumber);

   DibujarPanel();

   Print("🤖 BOT C900 BUY v1.0 ACTIVO");

   if(TG_Activo && StringLen(TG_Token) > 10)
   {
      string msg = "🤖 <b>BOT C900 BUY v1.0</b> INICIADO\n"
                 + "📊 Símbolo: <b>" + _Symbol + "</b>\n"
                 + "⚙️ SL: $" + DoubleToString(StopLoss_USD,2)
                 + " | TP: $" + DoubleToString(TakeProfit_USD,2)
                 + " | Lote: " + DoubleToString(LotSize,2) + "\n"
                 + "🎯 Meta diaria: $" + DoubleToString(DailyProfit_USD,2)
                 + " | Máx pérd: " + IntegerToString(MaxDailyLosses) + "\n"
                 + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2) + "\n"
                 + "📲 Comandos: /estado /comprar9b /cerrar9b /detener9b /activar9b /reporte9b /ayuda";
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
   FileWriteString(fh, "NAME=Crash 900 BUY\n");
   FileWriteString(fh, "SYMBOL=" + _Symbol + "\n");
   FileWriteString(fh, "MAGIC=" + IntegerToString(MagicNumber) + "\n");
   FileWriteString(fh, "EA=crash900\n");
   FileClose(fh);
   Print("Dashboard: registrado como crash900 en ", fname);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   EliminarPanel();
   Print("Bot C900 BUY detenido. Razón: ", reason);
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckDailyReset();

   if(TG_Activo && StringLen(TG_Token) > 10)
      if(TimeCurrent() - tg_last_poll >= TG_PollSegundos)
        {
         ProcesarComandosTelegram();
         tg_last_poll = TimeCurrent();
        }

   ReadConfig();
   ManageOpenTrades();
   ActualizarPanel();

   if(!tradingAllowed || !g_dashEnabled)
      return;

   if(HasOpenPosition())
      return;

   if(CopyBuffer(rsiHandle, 0, 0, 2, rsiBuffer) <= 0)
      return;

   double rsiCurrent  = rsiBuffer[0];
   double rsiPrevious = rsiBuffer[1];

   // Compra cuando RSI cruza hacia arriba el nivel configurado (recuperación de sobreventa)
   if(rsiPrevious < gc_rsiLevel && rsiCurrent >= gc_rsiLevel)
      OpenBuyOrder();
}

//+------------------------------------------------------------------+
void OpenBuyOrder()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int    dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   // SL/TP por software — el broker rechaza stops dentro del spread (~1400 pts en C900)
   if(trade.Buy(gc_lot, _Symbol, ask, 0, 0, "C900BUY-COMPRA"))
   {
      Print("✅ COMPRA ABIERTA en ", DoubleToString(ask,dig));
      if(TG_Activo && StringLen(TG_Token) > 10)
      {
         double rsiVal = 0;
         if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) > 0) rsiVal = rsiBuffer[0];
         string msg = "🟢 <b>COMPRA — Crash 900 Index</b>\n"
                    + "💲 Ask: " + DoubleToString(ask,dig) + "\n"
                    + "📦 Lote: " + DoubleToString(gc_lot,2) + "\n"
                    + "🛑 SL: $" + DoubleToString(gc_sl,2)
                    + " | 🎯 TP: $" + DoubleToString(gc_tp,2) + "\n"
                    + "📊 RSI: " + DoubleToString(rsiVal,2);
         EnviarTelegram(msg);
      }
   }
   else
      Print("❌ Error al abrir: ", GetLastError());
}

//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);

      if(profit >= gc_tp)
      {
         if(trade.PositionClose(ticket))
         {
            dailyProfit += profit;
            ops_hoy++;
            dia_pnl     += profit;
            dia_wins++;
            semana_trades++;
            semana_wins++;
            semana_pnl  += profit;
            if(profit > semana_mejor) semana_mejor = profit;
            Print("💰 TP alcanzado: $", DoubleToString(profit,2));
            if(TG_Activo && StringLen(TG_Token) > 10)
               EnviarTelegram("✅ <b>GANANCIA — Crash 900 BUY</b>\n"
                             + "💵 +$" + DoubleToString(profit,2) + "\n"
                             + "Profit hoy: $" + DoubleToString(dailyProfit,2)
                             + " / Meta: $" + DoubleToString(DailyProfit_USD,2) + "\n"
                             + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
            CheckDailyLimits();
         }
      }
      else if(profit <= -gc_sl)
      {
         if(trade.PositionClose(ticket))
         {
            dailyProfit += profit;
            ops_hoy++;
            dia_pnl      += profit;
            dia_losses++;
            dailyLosses++;
            semana_trades++;
            semana_losses++;
            semana_pnl   += profit;
            if(profit < semana_peor) semana_peor = profit;
            Print("🛑 SL alcanzado: $", DoubleToString(profit,2));
            if(TG_Activo && StringLen(TG_Token) > 10)
               EnviarTelegram("🔴 <b>PÉRDIDA — Crash 900 BUY</b>\n"
                             + "💵 -$" + DoubleToString(MathAbs(profit),2) + "\n"
                             + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
            CheckDailyLimits();
         }
      }
   }
}

//+------------------------------------------------------------------+
void CheckDailyLimits()
{
   if(dailyProfit >= DailyProfit_USD)
   {
      tradingAllowed = false;
      Print("🎯 META DIARIA ALCANZADA: $", DoubleToString(dailyProfit,2));
      if(TG_Activo && StringLen(TG_Token) > 10)
         EnviarTelegram("🎯 <b>META DIARIA ALCANZADA</b>\n"
                       + "Profit: $" + DoubleToString(dailyProfit,2) + "\n"
                       + "Bot pausado hasta mañana.\n"
                       + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
   }

   if(dailyLosses >= gc_maxLossDay)
   {
      tradingAllowed = false;
      Print("⛔ LIMITE DE PERDIDAS ALCANZADO: ", dailyLosses);
      if(TG_Activo && StringLen(TG_Token) > 10)
         EnviarTelegram("⛔ <b>LÍMITE DE PÉRDIDAS</b>\n"
                       + IntegerToString(dailyLosses) + " pérdidas hoy.\n"
                       + "Bot pausado hasta mañana.\n"
                       + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
   }
}

//+------------------------------------------------------------------+
void ReadConfig()
{
   static datetime s_last = 0;
   if(TimeCurrent() - s_last < 1) return;
   s_last = TimeCurrent();
   string fname = "mbot_" + IntegerToString(MagicNumber) + ".cfg";
   int fh = FileOpen(fname, FILE_READ | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE) return;
   while(!FileIsEnding(fh))
   {
      string line = FileReadString(fh);
      StringTrimRight(line); StringTrimLeft(line);
      if(StringLen(line) == 0) continue;
      int sep = StringFind(line, "=");
      if(sep < 0) continue;
      string key = StringSubstr(line, 0, sep);
      string val = StringSubstr(line, sep + 1);
      if(key == "ENABLED")      { bool ns = StringToInteger(val) != 0; if(g_dashEnabled != ns) { g_dashEnabled = ns; Print("Dashboard: bot ", g_dashEnabled ? "ACTIVADO" : "DETENIDO"); } }
      if(key == "RSI_LEVEL")    gc_rsiLevel   = StringToDouble(val);
      if(key == "SL")           gc_sl         = StringToDouble(val);
      if(key == "TP")           gc_tp         = StringToDouble(val);
      if(key == "LOT")          gc_lot        = StringToDouble(val);
      if(key == "MAX_LOSS_DAY") gc_maxLossDay = (int)StringToInteger(val);
   }
   FileClose(fh);
}

//+------------------------------------------------------------------+
void CheckDailyReset()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   datetime today = StringToTime(
      IntegerToString(dt.year)+"."+
      IntegerToString(dt.mon)+"."+
      IntegerToString(dt.day)
   );

   if(today <= lastDayChecked) return;

   if(lastDayChecked > 0 && ops_hoy > 0 && TG_Activo && StringLen(TG_Token) > 10)
   {
      int tot = dia_wins + dia_losses;
      double wr = tot > 0 ? (double)dia_wins / tot * 100 : 0;
      EnviarTelegram("📅 <b>Resumen del día — C900 BUY</b>\n"
                   + "Ops: " + IntegerToString(ops_hoy)
                   + " | " + IntegerToString(dia_wins) + "W / " + IntegerToString(dia_losses) + "L"
                   + " | WR: " + DoubleToString(wr,1) + "%\n"
                   + "P&L: $" + DoubleToString(dia_pnl,2) + "\n"
                   + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
   }

   lastDayChecked = today;
   dailyProfit    = 0;
   dailyLosses    = 0;
   tradingAllowed = true;
   ops_hoy        = 0;
   dia_pnl        = 0;
   dia_wins       = 0;
   dia_losses     = 0;

   if(dt.day_of_week == 1)
   {
      semana_trades = 0; semana_wins = 0; semana_losses = 0;
      semana_pnl    = 0; semana_mejor = 0; semana_peor  = 0;
   }

   Print("📅 Nuevo día — reset stats");
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
// Helpers panel
void PRect(string n, int x, int y, int w, int h, color bg, color bd)
{
   ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);     ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);  ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,bd);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);  ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
}

void PSeccion(string pfx, int px, int py, int pw, color ac, string txt)
{
   PRect(pfx+"Bg", px+1, py, pw-2, 16, C'10,25,15', C'10,25,15');
   PRect(pfx+"Ac", px+1, py, 3,    16, ac, ac);
   CrearLabel(pfx+"Tx", txt, px+10, py+3, ac, 7, true);
}

void CrearLabel(string nombre, string texto, int x, int y, color col, int tam, bool negrita)
{
   ObjectCreate(0, nombre, OBJ_LABEL, 0, 0, 0);
   ObjectSetString(0,  nombre, OBJPROP_TEXT,      texto);
   ObjectSetInteger(0, nombre, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nombre, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, nombre, OBJPROP_COLOR,     col);
   ObjectSetInteger(0, nombre, OBJPROP_FONTSIZE,  tam);
   ObjectSetString(0,  nombre, OBJPROP_FONT,      negrita ? "Arial Bold" : "Arial");
   ObjectSetInteger(0, nombre, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
   ObjectSetInteger(0, nombre, OBJPROP_BACK,      false);
   ObjectSetInteger(0, nombre, OBJPROP_SELECTABLE,false);
}

void EliminarPanel() { ObjectsDeleteAll(0, panel_prefix); ChartRedraw(0); }

//+------------------------------------------------------------------+
void DibujarPanel()
{
   int px=12, py=12, pw=312, ph=390;
   int lx=26, rx=204;

   ObjectsDeleteAll(0, panel_prefix);

   PRect(panel_prefix+"Main", px,py,pw,ph, C'8,20,10', C'30,160,60');
   PRect(panel_prefix+"Top",  px,py,pw,18, C'20,120,40', C'20,120,40');
   CrearLabel(panel_prefix+"Title", "BOT C900 BUY  v1.0", px+10, py+3, C'200,255,210', 8, true);

   CrearLabel(panel_prefix+"EstL", "ESTADO",   lx, py+24, C'100,150,120', 7, false);
   CrearLabel(panel_prefix+"EstV", "ACTIVO ✓", rx, py+24, C'0,220,120',   8, true);
   CrearLabel(panel_prefix+"TgL",  "Telegram", lx, py+38, C'100,150,120', 7, false);
   CrearLabel(panel_prefix+"TgV",  "OFF",      rx, py+38, C'180,60,60',   7, false);

   // CUENTA
   PSeccion(panel_prefix+"SCta", px, py+54, pw, C'0,180,220', "CUENTA");
   CrearLabel(panel_prefix+"BalL", "Balance",      lx, py+74,  C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"BalV", "--",            rx, py+74,  C'200,230,255', 8, true);
   CrearLabel(panel_prefix+"EqL",  "Equity",       lx, py+88,  C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"EqV",  "--",            rx, py+88,  C'200,230,255', 8, true);
   CrearLabel(panel_prefix+"LotL", "Lote",         lx, py+102, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"LotV", "--",            rx, py+102, C'200,230,255', 8, true);
   CrearLabel(panel_prefix+"PlFL", "P&L flotante", lx, py+116, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"PlFV", "--",            rx, py+116, C'200,230,255', 8, true);

   // HOY
   PSeccion(panel_prefix+"SHoy", px, py+134, pw, C'255,160,0', "HOY");
   CrearLabel(panel_prefix+"OpsL", "Operaciones",  lx, py+154, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"OpsV", "--",            rx, py+154, C'200,230,255', 7, false);
   CrearLabel(panel_prefix+"PnlL", "P&L hoy",      lx, py+168, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"PnlV", "--",            rx, py+168, C'200,230,255', 8, true);
   CrearLabel(panel_prefix+"MetL", "Meta / Pérd",  lx, py+182, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"MetV", "--",            rx, py+182, C'200,230,255', 7, false);

   // SEMANA
   PSeccion(panel_prefix+"SSem", px, py+200, pw, C'0,200,120', "SEMANA");
   CrearLabel(panel_prefix+"SwL", "Trades / WR",   lx, py+220, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"SwV", "--",             rx, py+220, C'200,230,255', 7, false);
   CrearLabel(panel_prefix+"SpL", "P&L semanal",   lx, py+234, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"SpV", "--",             rx, py+234, C'200,230,255', 8, true);

   // SEÑAL & MERCADO
   PSeccion(panel_prefix+"SSig", px, py+252, pw, C'0,220,120', "SEÑAL  &  MERCADO");
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
void ActualizarPanel()
{
   if(ObjectFind(0, panel_prefix+"Main") < 0) DibujarPanel();

   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   string est_txt; color est_col;
   if(HasOpenPosition())
     { est_txt = "EN POSICION";  est_col = clrAqua; }
   else if(!g_dashEnabled)
     { est_txt = "PAUSADO ⏸";   est_col = C'255,140,0'; }
   else if(tradingAllowed)
     { est_txt = "ACTIVO  ✓";   est_col = C'0,220,120'; }
   else
     { est_txt = "PAUSADO  ✗";  est_col = C'255,60,60'; }
   ObjectSetString(0,  panel_prefix+"EstV", OBJPROP_TEXT,  est_txt);
   ObjectSetInteger(0, panel_prefix+"EstV", OBJPROP_COLOR, est_col);

   string tgs = (TG_Activo && StringLen(TG_Token)>10) ? "ON" : "OFF";
   color  tgc = (TG_Activo && StringLen(TG_Token)>10) ? C'0,200,100' : C'180,60,60';
   ObjectSetString(0,  panel_prefix+"TgV", OBJPROP_TEXT,  tgs);
   ObjectSetInteger(0, panel_prefix+"TgV", OBJPROP_COLOR, tgc);

   ObjectSetString(0, panel_prefix+"BalV", OBJPROP_TEXT, "$"+DoubleToString(balance,2));
   ObjectSetString(0, panel_prefix+"EqV",  OBJPROP_TEXT, "$"+DoubleToString(equity,2));
   ObjectSetString(0, panel_prefix+"LotV", OBJPROP_TEXT, DoubleToString(gc_lot,2)+" lotes");
   ObjectSetString(0, panel_prefix+"SlV",  OBJPROP_TEXT, "$"+DoubleToString(gc_sl,2)+" / $"+DoubleToString(gc_tp,2));

   double pnl_fl = 0;
   if(HasOpenPosition())
      for(int i=0; i<PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         pnl_fl = PositionGetDouble(POSITION_PROFIT);
         break;
        }
   ObjectSetString(0,  panel_prefix+"PlFV", OBJPROP_TEXT,  "$"+DoubleToString(pnl_fl,2));
   ObjectSetInteger(0, panel_prefix+"PlFV", OBJPROP_COLOR, pnl_fl>=0 ? C'0,220,120' : C'255,80,80');

   ObjectSetString(0, panel_prefix+"OpsV", OBJPROP_TEXT,
      IntegerToString(ops_hoy)+" ops | "+IntegerToString(dia_wins)+"W / "+IntegerToString(dia_losses)+"L");
   ObjectSetString(0,  panel_prefix+"PnlV", OBJPROP_TEXT,  "$"+DoubleToString(dia_pnl,2));
   ObjectSetInteger(0, panel_prefix+"PnlV", OBJPROP_COLOR, dia_pnl>=0 ? C'0,220,120' : C'255,80,80');
   ObjectSetString(0, panel_prefix+"MetV", OBJPROP_TEXT,
      "$"+DoubleToString(dailyProfit,2)+" / $"+DoubleToString(DailyProfit_USD,2)
      +"  |  Pérd: "+IntegerToString(dailyLosses)+"/"+IntegerToString(MaxDailyLosses));

   int sw_tot = semana_wins+semana_losses;
   double sw_wr = sw_tot>0 ? (double)semana_wins/sw_tot*100 : 0;
   ObjectSetString(0, panel_prefix+"SwV", OBJPROP_TEXT,
      IntegerToString(semana_trades)+" / "+DoubleToString(sw_wr,1)+"%");
   ObjectSetString(0,  panel_prefix+"SpV", OBJPROP_TEXT,  "$"+DoubleToString(semana_pnl,2));
   ObjectSetInteger(0, panel_prefix+"SpV", OBJPROP_COLOR, semana_pnl>=0 ? C'0,220,120' : C'255,80,80');

   double rsiVal = 0;
   if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) > 0) rsiVal = rsiBuffer[0];
   ObjectSetString(0,  panel_prefix+"RsiV", OBJPROP_TEXT,  DoubleToString(rsiVal,2)+" pts");
   ObjectSetInteger(0, panel_prefix+"RsiV", OBJPROP_COLOR,
      rsiVal <= gc_rsiLevel ? C'0,220,120' : C'255,160,0');

   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   ObjectSetString(0, panel_prefix+"SprdV", OBJPROP_TEXT, IntegerToString(spread)+" pts");

   ChartRedraw(0);
}

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

void EnviarTelegram(string mensaje)
{
   if(!TG_Activo || StringLen(TG_Token) < 10 || StringLen(TG_ChatID) < 5) return;
   string url  = "https://api.telegram.org/bot" + TG_Token + "/sendMessage";
   string body = "chat_id=" + TG_ChatID + "&parse_mode=HTML&text=" + UrlEncode(mensaje);
   char req[], res[];
   string hdrs = "Content-Type: application/x-www-form-urlencoded\r\n";
   StringToCharArray(body, req, 0, StringLen(body));
   int code = WebRequest("POST", url, hdrs, 5000, req, res, hdrs);
   if(code != 200) Print("⚠ Telegram error HTTP: ", code);
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
      if(uid <= GlobalVariableGet(GV_UID)) { desde = pos+1; continue; }
      GlobalVariableSet(GV_UID, uid);
      string txt = ExtraerStr(json, "text", pos);
      if(StringLen(txt) > 0) ProcesarComando(txt);
      desde = pos+1;
   }
}

//+------------------------------------------------------------------+
void ProcesarComando(string cmd)
{
   StringToLower(cmd);
   int sp = StringFind(cmd, " ");
   if(sp > 0) cmd = StringSubstr(cmd, 0, sp);

   if(cmd == "/estado" || cmd == "/status")
   {
      double rsiVal = 0;
      if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) > 0) rsiVal = rsiBuffer[0];
      int tot = semana_wins+semana_losses;
      double wr = tot>0 ? (double)semana_wins/tot*100 : 0;
      EnviarTelegram((tradingAllowed ? "🟢" : "🔴") + " <b>Crash 900 BUY</b>\n"
                   + "💰 $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2) + "\n"
                   + "📈 " + (HasOpenPosition() ? "En posición" : "Sin posición") + "\n"
                   + "Profit hoy: $" + DoubleToString(dailyProfit,2) + " / $" + DoubleToString(DailyProfit_USD,2) + "\n"
                   + "Pérd hoy: " + IntegerToString(dailyLosses) + "/" + IntegerToString(MaxDailyLosses) + "\n"
                   + "RSI: " + DoubleToString(rsiVal,2));
      return;
   }
   if(cmd == "/ayuda" || cmd == "/help")
   {
      EnviarTelegram("📋 <b>Crash 900 BUY:</b>\n"
                   + "/estado  /ayuda\n\n"
                   + "/comprar9b  /cerrar9b\n"
                   + "/detener9b  /activar9b\n"
                   + "/reporte9b");
      return;
   }

   if(cmd == "/detener9b")
   {
      if(!tradingAllowed) { EnviarTelegram("ℹ️ C900 BUY ya estaba detenido."); return; }
      tradingAllowed = false;
      EnviarTelegram("🛑 <b>C900 BUY DETENIDO</b>\nEnvía /activar9b para reanudar.");
   }
   else if(cmd == "/activar9b")
   {
      if(tradingAllowed) { EnviarTelegram("ℹ️ C900 BUY ya estaba activo."); return; }
      tradingAllowed = true;
      EnviarTelegram("✅ <b>C900 BUY REACTIVADO</b>");
   }
   else if(cmd == "/cerrar9b")
   {
      if(!HasOpenPosition()) { EnviarTelegram("ℹ️ C900 BUY: Sin posición abierta."); return; }
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         if(trade.PositionClose(t))
            EnviarTelegram("✅ C900 BUY: Posición cerrada.\n💰 $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
         else EnviarTelegram("❌ C900 BUY: Error al cerrar.");
         break;
      }
   }
   else if(cmd == "/comprar9b")
   {
      if(!tradingAllowed) { EnviarTelegram("C900 BUY detenido. Usa /activar9b."); return; }
      if(HasOpenPosition()) { EnviarTelegram("C900 BUY: Ya hay posición."); return; }
      EnviarTelegram("📲 C900 BUY: Abriendo compra...");
      OpenBuyOrder();
   }
   else if(cmd == "/reporte9b")
   {
      int tot = semana_wins+semana_losses;
      double wr = tot>0 ? (double)semana_wins/tot*100 : 0;
      EnviarTelegram("📊 <b>Semana — C900 BUY</b>\n"
                   + "Trades: "+IntegerToString(semana_trades)
                   + " | WR: "+DoubleToString(wr,1)+"%\n"
                   + "P&L: $"+DoubleToString(semana_pnl,2)+"\n"
                   + "Mejor: $"+DoubleToString(semana_mejor,2)
                   + " | Peor: $"+DoubleToString(semana_peor,2));
   }
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
      if(c==',' || c=='}' || c==']' || c==' ') break;
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
//+------------------------------------------------------------------+
