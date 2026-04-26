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

files_dir = os.path.join(info.data_path, "MQL5", "Files")
os.makedirs(files_dir, exist_ok=True)
print(f"Carpeta MT5 Files: {files_dir}\n")

# Recopilar magic numbers desde posiciones abiertas e historial de 7 dias
seen = {}  # magic -> {symbol, name}

positions = mt5.positions_get()
if positions:
    for p in positions:
        if p.magic not in seen:
            seen[p.magic] = {"symbol": p.symbol, "source": "posicion activa"}

from_dt = datetime.combine(date.today() - timedelta(days=7), datetime.min.time())
deals = mt5.history_deals_get(from_dt, datetime.now())
if deals:
    for d in deals:
        if d.magic and d.magic not in seen:
            seen[d.magic] = {"symbol": d.symbol, "source": "historial"}

mt5.shutdown()

if not seen:
    print("No se encontraron bots activos ni en historial reciente.")
    print("Asegurate de que tus EAs tengan operaciones abiertas o recientes.")
    input("\nPresiona Enter para salir...")
    sys.exit(0)

print(f"Se encontraron {len(seen)} bot(s):\n")
created = 0
for magic, data in seen.items():
    symbol  = data["symbol"]
    source  = data["source"]
    name    = f"Bot {magic}"
    cfg_path = os.path.join(files_dir, f"mreg_{magic}.cfg")

    # Si ya existe, no sobreescribir
    if os.path.exists(cfg_path):
        print(f"  [ya existe] magic={magic} | {symbol} ({source})")
        continue

    with open(cfg_path, "w", encoding="utf-8") as f:
        f.write(f"MAGIC={magic}\n")
        f.write(f"NAME={name}\n")
        f.write(f"SYMBOL={symbol}\n")
        f.write(f"EA=mybot\n")
        f.write(f"ENABLED=1\n")

    print(f"  [creado] magic={magic} | {symbol} ({source})")
    created += 1

print(f"\n{created} archivo(s) nuevo(s) creado(s).")
print("\nReinicia start.bat para que el dashboard los detecte.")
input("\nPresiona Enter para salir...")
