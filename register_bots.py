"""
Registra automaticamente los bots activos en MT5 para el dashboard.
Ejecutar una vez (o cada vez que agregues un EA nuevo).
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import MetaTrader5 as mt5
except ImportError:
    print("ERROR: MetaTrader5 no instalado. Ejecuta primero start.bat")
    input("Presiona Enter para salir...")
    sys.exit(1)

from datetime import datetime, date, timedelta

print("\n" + "="*50)
print("  TradingBot 4000 - Registro de Bots")
print("="*50 + "\n")

if not mt5.initialize():
    print("ERROR: No se pudo conectar a MetaTrader 5.")
    print("Asegurate de que MT5 este abierto.")
    input("\nPresiona Enter para salir...")
    sys.exit(1)

info = mt5.terminal_info()
if not info:
    print("ERROR: No se pudo obtener info del terminal.")
    input("\nPresiona Enter para salir...")
    sys.exit(1)

# Carpeta local bots/ del dashboard (portable, funciona siempre)
local_bots = os.path.join(os.path.dirname(os.path.abspath(__file__)), "bots")
os.makedirs(local_bots, exist_ok=True)
print(f"Guardando en: {local_bots}\n")

# Recopilar magic numbers desde posiciones abiertas e historial de 30 dias
# La clave es magic si es != 0, o "sym_SYMBOL" si magic es 0
seen = {}

positions = mt5.positions_get()
if positions:
    for p in positions:
        if p.magic and p.magic not in seen:
            seen[p.magic] = {"magic": p.magic, "symbol": p.symbol, "source": "posicion activa"}

from_dt = datetime.combine(date.today() - timedelta(days=30), datetime.min.time())
deals = mt5.history_deals_get(from_dt, datetime.now())
if deals:
    for d in deals:
        if d.magic and d.magic not in seen:
            seen[d.magic] = {"magic": d.magic, "symbol": d.symbol, "source": "historial"}

mt5.shutdown()

# Limpiar archivos sym_* viejos (magic=0) que ya no sirven
for fname in os.listdir(local_bots):
    if fname.startswith("mreg_sym_") and fname.endswith(".cfg"):
        os.remove(os.path.join(local_bots, fname))
        print(f"  [eliminado] {fname} (magic=0, no controlable)")

if not seen:
    print("No se encontraron bots en posiciones abiertas ni en historial de 30 dias.")
    print("Asegurate de que tus EAs hayan tenido actividad reciente.")
    input("\nPresiona Enter para salir...")
    sys.exit(0)

print(f"Se encontraron {len(seen)} bot(s):\n")
created = 0
reset = 0
for key, data in seen.items():
    magic    = data["magic"]
    symbol   = data["symbol"]
    source   = data["source"]
    name     = symbol if not magic else f"Bot {magic}"
    mreg     = os.path.join(local_bots, f"mreg_{key}.cfg")
    mbot     = os.path.join(local_bots, f"mbot_{key}.cfg")

    # Crear o actualizar mreg_*.cfg
    if not os.path.exists(mreg):
        with open(mreg, "w", encoding="utf-8") as f:
            f.write(f"MAGIC={magic}\n")
            f.write(f"NAME={name}\n")
            f.write(f"SYMBOL={symbol}\n")
            f.write("EA=mybot\n")
            f.write("ENABLED=1\n")
        print(f"  [creado]    magic={magic} | {symbol} ({source})")
        created += 1
    else:
        print(f"  [ya existe] magic={magic} | {symbol} ({source})")

    # Resetear mbot_*.cfg si tiene ENABLED=0 (estado pausado viejo)
    if os.path.exists(mbot):
        with open(mbot, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        if "ENABLED=0" in content:
            new_content = content.replace("ENABLED=0", "ENABLED=1")
            with open(mbot, "w", encoding="utf-8") as f:
                f.write(new_content)
            print(f"  [activado]  magic={magic} | estado reseteado a ACTIVO")
            reset += 1

print(f"\n{created} bot(s) nuevo(s) registrado(s), {reset} estado(s) reseteado(s).")
print("\nReinicia start.bat para que el dashboard los detecte.")
input("\nPresiona Enter para salir...")
