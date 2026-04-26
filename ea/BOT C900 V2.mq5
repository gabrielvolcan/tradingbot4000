//+------------------------------------------------------------------+
//|                        BOT C900 PRO  v2.1                        |
//|          Estrategia RSI — Crash 900 Index — M1 Ventas            |
//+------------------------------------------------------------------+
#property copyright "BOT C900 PRO v2.1"
#property version   "2.10"
#property strict
#include <Trade\Trade.mqh>

//--- CONFIG
input group "=== SEÑAL RSI ==="
input int      RSI_Period      = 14;
input double   RSI_LevelSell   = 97.0;

input group "=== GESTIÓN DE RIESGO ==="
input double   LotSize         = 0.50;
input double   TakeProfit_USD  = 5.0;
input double   StopLoss_USD    = 5.0;

input group "=== LÍMITES DIARIOS ==="
input double   DailyProfit_USD = 25.0;
input int      MaxDailyLosses  = 3;

input group "=== CONFIGURACIÓN ==="
input int                     MagicNumber  = 900200;   // Magic único — no compartir con otro EA
input ENUM_ORDER_TYPE_FILLING InpFilling   = ORDER_FILLING_IOC;
input int                     InpSlippage  = 15;

input group "=== TELEGRAM ==="
input string   TG_Token        = "";
input string   TG_ChatID       = "";
input bool     TG_Activo       = true;
input int      TG_PollSegundos = 5;

//--- VARIABLES ORIGINALES
CTrade   trade;
int      rsiHandle;
double   rsiBuffer[];
double   dailyProfit   = 0;
int      dailyLosses   = 0;
bool     tradingAllowed = true;
datetime lastDayChecked = 0;

bool     g_dashEnabled = true;   // Controlado desde el Dashboard web

// Parámetros dinámicos — actualizados desde el Dashboard
double   gc_sl         = 5.00;
double   gc_tp         = 5.00;
double   gc_lot        = 0.50;
int      gc_maxLossDay = 3;

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
string   panel_prefix  = "C900_BOT_";
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

   gc_sl         = StopLoss_USD;
   gc_tp         = TakeProfit_USD;
   gc_lot        = LotSize;
   gc_maxLossDay = MaxDailyLosses;

   GV_UID = "C900BOT_UID_" + IntegerToString(MagicNumber);

   DibujarPanel();
   RegisterWithDashboard();

   Print("🤖 BOT C900 PRO v2.1 ACTIVO");

   if(TG_Activo && StringLen(TG_Token) > 10)
   {
      string msg = "🤖 <b>BOT C900 PRO v2.1</b> INICIADO\n"
                 + "📊 Símbolo: <b>" + _Symbol + "</b>\n"
                 + "⚙️ SL: $" + DoubleToString(StopLoss_USD,2)
                 + " | TP: $" + DoubleToString(TakeProfit_USD,2)
                 + " | Lote: " + DoubleToString(LotSize,2) + "\n"
                 + "🎯 Meta diaria: $" + DoubleToString(DailyProfit_USD,2)
                 + " | Máx pérd: " + IntegerToString(MaxDailyLosses) + "\n"
                 + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2) + "\n"
                 + "📲 Comandos: /estado /vender /cerrar /detener /activar /reporte /ayuda";
      EnviarTelegram(msg);
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   EliminarPanel();
   Print("Bot C900 detenido. Razón: ", reason);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ReadConfig();
   CheckDailyReset();

   if(TG_Activo && StringLen(TG_Token) > 10)
      if(TimeCurrent() - tg_last_poll >= TG_PollSegundos)
        {
         ProcesarComandosTelegram();
         tg_last_poll = TimeCurrent();
        }

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

   if(rsiPrevious < RSI_LevelSell && rsiCurrent >= RSI_LevelSell)
      OpenSellOrder();
}

//+------------------------------------------------------------------+
void OpenSellOrder()
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(trade.Sell(gc_lot, _Symbol, bid, 0, 0, "C900V2-VENTA"))
   {
      Print("✅ VENTA ABIERTA en ", DoubleToString(bid,dig));
      if(TG_Activo && StringLen(TG_Token) > 10)
      {
         double rsiVal = 0;
         if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) > 0) rsiVal = rsiBuffer[0];
         string msg = "🔴 <b>VENTA — Crash 900 Index</b>\n"
                    + "💲 Bid: " + DoubleToString(bid,dig) + "\n"
                    + "📦 Lote: " + DoubleToString(LotSize,2) + "\n"
                    + "🛑 SL: $" + DoubleToString(StopLoss_USD,2)
                    + " | 🎯 TP: $" + DoubleToString(TakeProfit_USD,2) + "\n"
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
   double buffer = 0.3;

   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double profit = PositionGetDouble(POSITION_PROFIT);

      if(profit >= (gc_tp - buffer))
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
               EnviarTelegram("✅ <b>GANANCIA — Crash 900 Index</b>\n"
                             + "💵 +$" + DoubleToString(profit,2) + "\n"
                             + "Profit hoy: $" + DoubleToString(dailyProfit,2)
                             + " / Meta: $" + DoubleToString(DailyProfit_USD,2) + "\n"
                             + "💰 Balance: $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
            CheckDailyLimits();
         }
      }
      else if(profit <= -(gc_sl - buffer))
      {
         if(trade.PositionClose(ticket))
         {
            dailyProfit += profit;
            dailyLosses++;
            ops_hoy++;
            dia_pnl     += profit;
            dia_losses++;
            semana_trades++;
            semana_losses++;
            semana_pnl  += profit;
            if(profit < semana_peor) semana_peor = profit;
            Print("🔴 SL alcanzado: $", DoubleToString(profit,2));
            if(TG_Activo && StringLen(TG_Token) > 10)
               EnviarTelegram("❌ <b>PÉRDIDA — Crash 900 Index</b>\n"
                             + "💵 -$" + DoubleToString(MathAbs(profit),2) + "\n"
                             + "Pérdidas hoy: " + IntegerToString(dailyLosses)
                             + "/" + IntegerToString(MaxDailyLosses) + "\n"
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

   if(dailyLosses >= MaxDailyLosses)
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
      EnviarTelegram("📅 <b>Resumen del día — C900</b>\n"
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
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
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
   PRect(pfx+"Bg", px+1, py, pw-2, 16, C'15,20,40', C'15,20,40');
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

   PRect(panel_prefix+"Main", px,py,pw,ph, C'8,8,20', C'220,60,60');
   PRect(panel_prefix+"Top",  px,py,pw,18, C'180,30,30', C'180,30,30');
   CrearLabel(panel_prefix+"Title", "BOT C900 PRO  v2.1", px+10, py+3, C'255,210,210', 8, true);

   CrearLabel(panel_prefix+"EstL", "ESTADO",   lx, py+24, C'100,120,150', 7, false);
   CrearLabel(panel_prefix+"EstV", "ACTIVO ✓", rx, py+24, C'0,220,120',   8, true);
   CrearLabel(panel_prefix+"TgL",  "Telegram", lx, py+38, C'100,120,150', 7, false);
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
   PSeccion(panel_prefix+"SSig", px, py+252, pw, C'180,100,255', "SEÑAL  &  MERCADO");
   CrearLabel(panel_prefix+"RsiL",  "RSI actual",  lx, py+272, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"RsiV",  "--",           rx, py+272, C'200,230,255', 7, false);
   CrearLabel(panel_prefix+"SprdL", "Spread",      lx, py+286, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"SprdV", "--",           rx, py+286, C'200,230,255', 7, false);
   CrearLabel(panel_prefix+"SlL",   "SL / TP",     lx, py+300, C'130,160,190', 7, false);
   CrearLabel(panel_prefix+"SlV",   "$"+DoubleToString(StopLoss_USD,2)+" / $"+DoubleToString(TakeProfit_USD,2),
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
   ObjectSetString(0, panel_prefix+"LotV", OBJPROP_TEXT, DoubleToString(LotSize,2)+" lotes (fijo)");

   double pnl_fl = 0;
   if(HasOpenPosition())
      for(int i=0; i<PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
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
      rsiVal >= RSI_LevelSell ? C'255,80,80' : C'255,160,0');

   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   ObjectSetString(0, panel_prefix+"SprdV", OBJPROP_TEXT, IntegerToString(spread)+" pts");

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//|  REGISTRO EN DASHBOARD                                           |
//+------------------------------------------------------------------+
void RegisterWithDashboard()
{
   string fname = "mreg_" + IntegerToString(MagicNumber) + ".cfg";
   int fh = FileOpen(fname, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE) { Print("WARN: no se pudo crear ", fname); return; }
   FileWriteString(fh, "NAME=Crash 900 SELL\n");
   FileWriteString(fh, "SYMBOL=" + _Symbol + "\n");
   FileWriteString(fh, "MAGIC=" + IntegerToString(MagicNumber) + "\n");
   FileWriteString(fh, "EA=crash900v2\n");
   FileClose(fh);
   Print("Dashboard: registrado como crash900v2 en ", fname);
}

//+------------------------------------------------------------------+
//|  LECTURA DE CONFIGURACION DESDE DASHBOARD                        |
//+------------------------------------------------------------------+
void ReadConfig()
{
   static datetime s_last = 0, s_diag = 0;
   if(TimeCurrent() - s_last < 1) return;
   s_last = TimeCurrent();
   string fname = "mbot_" + IntegerToString(MagicNumber) + ".cfg";
   int fh = FileOpen(fname, FILE_READ | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE) return;
   int en_val = 1;
   while(!FileIsEnding(fh))
   {
      string line = FileReadString(fh);
      int sep = StringFind(line, "=");
      if(sep < 0) continue;
      string key = StringSubstr(line, 0, sep);
      string val = StringSubstr(line, sep + 1);
      if(key == "ENABLED")          en_val        = (int)StringToInteger(val);
      else if(key == "SL")          gc_sl          = StringToDouble(val);
      else if(key == "TP")          gc_tp          = StringToDouble(val);
      else if(key == "LOT")         gc_lot         = StringToDouble(val);
      else if(key == "MAX_LOSS_DAY") gc_maxLossDay = (int)StringToInteger(val);
   }
   FileClose(fh);
   bool new_en = (en_val != 0);
   if(new_en != g_dashEnabled)
   {
      g_dashEnabled = new_en;
      Print("Dashboard: bot ", g_dashEnabled ? "ACTIVADO" : "DETENIDO");
   }
   if(TimeCurrent()-s_diag >= 30)
   { s_diag=TimeCurrent(); Print("DIAG C900V2: ENABLED=",en_val," g_dashEnabled=",g_dashEnabled); }
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

   // Comandos globales — ambos bots responden
   if(cmd == "/estado" || cmd == "/status")
   {
      double rsiVal = 0;
      if(CopyBuffer(rsiHandle, 0, 0, 1, rsiBuffer) > 0) rsiVal = rsiBuffer[0];
      int tot = semana_wins+semana_losses;
      double wr = tot>0 ? (double)semana_wins/tot*100 : 0;
      EnviarTelegram((tradingAllowed ? "🟢" : "🔴") + " <b>Crash 900</b>\n"
                   + "💰 $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2) + "\n"
                   + "📈 " + (HasOpenPosition() ? "En posición" : "Sin posición") + "\n"
                   + "Profit hoy: $" + DoubleToString(dailyProfit,2) + " / $" + DoubleToString(DailyProfit_USD,2) + "\n"
                   + "Pérd hoy: " + IntegerToString(dailyLosses) + "/" + IntegerToString(MaxDailyLosses) + "\n"
                   + "RSI: " + DoubleToString(rsiVal,2));
      return;
   }
   if(cmd == "/ayuda" || cmd == "/help")
   {
      EnviarTelegram("📋 <b>Crash 900:</b>\n"
                   + "/estado  /ayuda\n\n"
                   + "/vender9  /cerrar9\n"
                   + "/detener9  /activar9\n"
                   + "/reporte9");
      return;
   }

   // Comandos exclusivos Crash 900 — sufijo 9
   if(cmd == "/detener9")
   {
      if(!tradingAllowed) { EnviarTelegram("ℹ️ Crash 900 ya estaba detenido."); return; }
      tradingAllowed = false;
      EnviarTelegram("🛑 <b>Crash 900 DETENIDO</b>\nEnvía /activar9 para reanudar.");
   }
   else if(cmd == "/activar9")
   {
      if(tradingAllowed) { EnviarTelegram("ℹ️ Crash 900 ya estaba activo."); return; }
      tradingAllowed = true;
      EnviarTelegram("✅ <b>Crash 900 REACTIVADO</b>");
   }
   else if(cmd == "/cerrar9")
   {
      if(!HasOpenPosition()) { EnviarTelegram("ℹ️ Crash 900: Sin posición abierta."); return; }
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         if(trade.PositionClose(t))
            EnviarTelegram("✅ Crash 900: Posición cerrada.\n💰 $" + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE),2));
         else EnviarTelegram("❌ Crash 900: Error al cerrar.");
         break;
      }
   }
   else if(cmd == "/vender9")
   {
      if(!tradingAllowed) { EnviarTelegram("Crash 900 detenido. Usa /activar9."); return; }
      if(HasOpenPosition()) { EnviarTelegram("Crash 900: Ya hay posición."); return; }
      EnviarTelegram("📲 Crash 900: Abriendo venta...");
      OpenSellOrder();
   }
   else if(cmd == "/reporte9")
   {
      int tot = semana_wins+semana_losses;
      double wr = tot>0 ? (double)semana_wins/tot*100 : 0;
      EnviarTelegram("📊 <b>Semana — Crash 900</b>\n"
                   + "Trades: "+IntegerToString(semana_trades)
                   + " | WR: "+DoubleToString(wr,1)+"%\n"
                   + "P&L: $"+DoubleToString(semana_pnl,2)+"\n"
                   + "Mejor: $"+DoubleToString(semana_mejor,2)
                   + " | Peor: $"+DoubleToString(semana_peor,2));
   }
   // Ignorar comandos del C1000
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
