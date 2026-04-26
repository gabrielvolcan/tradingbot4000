from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Depends, Body
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel
from datetime import datetime, date, timedelta
from typing import Optional, Dict, Any
import MetaTrader5 as mt5
import uvicorn
import socket
import os
import time as _time

from auth import (
    verify_password, hash_password, create_token, decode_token,
    load_users, save_users,
)

BASE           = os.path.dirname(os.path.abspath(__file__))
security       = HTTPBearer(auto_error=False)
_MT5_FILES_DIR = None

# ── Bot registry ───────────────────────────────────────────────────────────────
# BOTS is populated automatically from mreg_*.cfg files each EA writes on init.
# No manual configuration needed — just run your EAs and they register themselves.
BOTS: dict = {}

_BOT_ICONS: dict = {
    "crash500":  ("💥", "#f59e0b"),
    "crash900":  ("🔥", "#ef4444"),
    "crash900v2":("🔻", "#dc2626"),
    "crash1000": ("⚡", "#7c3aed"),
    "boom500":   ("🚀", "#22c55e"),
    "boom900":   ("🚀", "#16a34a"),
    "boom1000":  ("🚀", "#15803d"),
    "gold":      ("🥇", "#eab308"),
    "silver":    ("🥈", "#94a3b8"),
    "step100":   ("📈", "#0ea5e9"),
    "step200":   ("📈", "#06b6d4"),
    "step500":   ("📈", "#0891b2"),
}

BOT_SCHEMA = {
    "crash500": {
        "defaults": {"ENABLED":1,"RSI_PERIOD":14,"RSI_LEVEL":30.0,"SL":2.00,"TP":3.50,"RISK_PCT":2.0,"MAX_OPS_DAY":4,"MAX_LOSS_DAY":6.0,"MAX_CONSEC":2},
        "fields": [
            {"key":"RSI_LEVEL","label":"Nivel RSI compra","type":"float","min":5,"max":50,"step":0.5},
            {"key":"SL","label":"Stop Loss ($)","type":"float","min":0.5,"max":500,"step":0.5},
            {"key":"TP","label":"Take Profit ($)","type":"float","min":0.5,"max":500,"step":0.5},
            {"key":"RISK_PCT","label":"Riesgo % balance","type":"float","min":0.1,"max":10,"step":0.1},
            {"key":"MAX_OPS_DAY","label":"Máx. ops por día","type":"int","min":1,"max":50,"step":1},
            {"key":"MAX_LOSS_DAY","label":"Pérd. máx. día (% balance)","type":"float","min":0.5,"max":50,"step":0.5},
            {"key":"MAX_CONSEC","label":"Parar tras N pérdidas seguidas","type":"int","min":1,"max":20,"step":1},
        ],
    },
    "crash900": {
        "defaults": {"ENABLED":1,"RSI_LEVEL":24.0,"SL":5.00,"TP":5.00,"LOT":0.50,"MAX_LOSS_DAY":3},
        "fields": [
            {"key":"RSI_LEVEL","label":"Nivel RSI compra","type":"float","min":5,"max":50,"step":0.5},
            {"key":"SL","label":"Stop Loss ($)","type":"float","min":0.5,"max":500,"step":0.5},
            {"key":"TP","label":"Take Profit ($)","type":"float","min":0.5,"max":500,"step":0.5},
            {"key":"LOT","label":"Tamaño de lote","type":"float","min":0.01,"max":100,"step":0.01},
            {"key":"MAX_LOSS_DAY","label":"Máx. pérdidas diarias","type":"int","min":1,"max":20,"step":1},
        ],
    },
    "crash1000": {
        "defaults": {"ENABLED":1,"RSI_LEVEL":27.0,"SL":3.00,"TP":1.00,"LOT":0.20,"MAX_CONSEC_LOSS":4,"MAX_CONSEC_WIN":10},
        "fields": [
            {"key":"RSI_LEVEL","label":"Nivel RSI compra","type":"float","min":5,"max":50,"step":0.5},
            {"key":"SL","label":"Stop Loss ($)","type":"float","min":0.5,"max":500,"step":0.5},
            {"key":"TP","label":"Take Profit ($)","type":"float","min":0.5,"max":500,"step":0.5},
            {"key":"LOT","label":"Tamaño de lote","type":"float","min":0.01,"max":100,"step":0.01},
            {"key":"MAX_CONSEC_LOSS","label":"Parar tras N pérdidas seguidas","type":"int","min":1,"max":20,"step":1},
            {"key":"MAX_CONSEC_WIN","label":"Parar tras N ganancias seguidas","type":"int","min":1,"max":50,"step":1},
        ],
    },
    "crash900v2": {
        "defaults": {"ENABLED":1,"SL":5.00,"TP":5.00,"LOT":0.50,"MAX_LOSS_DAY":3},
        "fields": [
            {"key":"SL","label":"Stop Loss ($)","type":"float","min":0.5,"max":500,"step":0.5},
            {"key":"TP","label":"Take Profit ($)","type":"float","min":0.5,"max":500,"step":0.5},
            {"key":"LOT","label":"Tamaño de lote","type":"float","min":0.01,"max":100,"step":0.01},
            {"key":"MAX_LOSS_DAY","label":"Máx. pérdidas diarias","type":"int","min":1,"max":20,"step":1},
        ],
    },
}


# ── MT5 helpers ────────────────────────────────────────────────────────────────

def get_files_dir() -> str | None:
    global _MT5_FILES_DIR
    if not _MT5_FILES_DIR:
        info = mt5.terminal_info()
        if info is None:
            return None
        _MT5_FILES_DIR = os.path.join(info.data_path, "MQL5", "Files")
        os.makedirs(_MT5_FILES_DIR, exist_ok=True)
    return _MT5_FILES_DIR


def cfg_path(magic: int) -> str | None:
    # Siempre escribir en el terminal MT5 conectado (donde el EA lo lee)
    d = get_files_dir()
    return os.path.join(d, f"mbot_{magic}.cfg") if d else None


def read_cfg_file(path: str) -> dict:
    result = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if "=" not in line:
                    continue
                k, v = line.split("=", 1)
                try:
                    result[k] = float(v) if "." in v else int(v)
                except Exception:
                    result[k] = v
    except Exception:
        pass
    return result


def read_cfg(magic: int) -> dict:
    p = cfg_path(magic)
    if not p or not os.path.exists(p):
        return {}
    return read_cfg_file(p)


def write_cfg(magic: int, data: dict):
    p = cfg_path(magic)
    if not p:
        return
    with open(p, "w") as f:
        for k, v in data.items():
            f.write(f"{k}={v:.4f}\n" if isinstance(v, float) else f"{k}={v}\n")


def read_ctrl(magic: int) -> bool:
    return int(read_cfg(magic).get("ENABLED", 1)) != 0


def write_ctrl(magic: int, enabled: bool):
    ea_key = next((b.get("ea","") for b in BOTS.values() if b["magic"] == magic), "")
    cfg = read_cfg(magic)
    if not cfg and ea_key in BOT_SCHEMA:
        cfg = dict(BOT_SCHEMA[ea_key]["defaults"])
    cfg["ENABLED"] = 1 if enabled else 0
    write_cfg(magic, cfg)


def _best_filling(symbol: str) -> int:
    sym = mt5.symbol_info(symbol)
    if sym is None:
        return mt5.ORDER_FILLING_IOC
    fm = sym.filling_mode
    if fm & 1:
        return mt5.ORDER_FILLING_FOK
    if fm & 2:
        return mt5.ORDER_FILLING_IOC
    return mt5.ORDER_FILLING_RETURN


# ── Bot auto-discovery ─────────────────────────────────────────────────────────
_last_discover = 0.0


def _all_mt5_files_dirs() -> list[str]:
    """Devuelve todas las carpetas donde buscar mreg_*.cfg."""
    dirs = []
    # 1. Carpeta bots/ local del dashboard (la mas simple y portable)
    local_bots = os.path.join(BASE, "bots")
    if os.path.isdir(local_bots):
        dirs.append(local_bots)
    # 2. Terminal MT5 que Python conectó
    primary = get_files_dir()
    if primary and primary not in dirs:
        dirs.append(primary)
    # 3. Todos los terminales MT5 instalados en AppData
    base = os.path.join(os.environ.get("APPDATA", ""), "MetaQuotes", "Terminal")
    if os.path.isdir(base):
        for entry in os.listdir(base):
            candidate = os.path.join(base, entry, "MQL5", "Files")
            if os.path.isdir(candidate) and candidate not in dirs:
                dirs.append(candidate)
    return dirs


def discover_bots():
    global BOTS, _last_discover
    now = _time.time()
    if now - _last_discover < 10:
        return
    _last_discover = now
    found = {}

    # ── 1. mreg_*.cfg files (fuente principal — nombre, ea, ícono, color) ──────
    for d in _all_mt5_files_dirs():
        try:
            files = os.listdir(d)
        except OSError:
            continue
        for fname in files:
            if not fname.startswith("mreg_") or not fname.endswith(".cfg"):
                continue
            data = read_cfg_file(os.path.join(d, fname))
            try:
                magic = int(data.get("MAGIC", 0))
            except Exception:
                continue
            if not magic:
                continue
            key = str(magic)
            ea_key = str(data.get("EA", f"bot_{key}")).lower().strip()
            icon, color = _BOT_ICONS.get(ea_key, ("🤖", "#7c3aed"))
            found[key] = {
                "name":      str(data.get("NAME", data.get("SYMBOL", f"Bot {key}"))),
                "magic":     magic,
                "symbol":    str(data.get("SYMBOL", "")),
                "icon":      icon,
                "color":     color,
                "ea":        ea_key,
                "files_dir": d,
            }

    # ── 2. Autodetección desde MT5 (fallback si no hay mreg files) ─────────────
    if mt5.terminal_info():
        files_dir = get_files_dir() or ""

        # Posiciones abiertas
        positions = mt5.positions_get()
        if positions:
            for p in positions:
                if p.magic and str(p.magic) not in found:
                    found[str(p.magic)] = {
                        "name": f"Bot {p.magic}", "magic": p.magic,
                        "symbol": p.symbol, "icon": "🤖", "color": "#7c3aed",
                        "ea": "", "files_dir": files_dir,
                    }

        # Historial de 30 días (detecta bots aunque no tengan posición abierta)
        from_dt = datetime.combine(date.today() - timedelta(days=30), datetime.min.time())
        deals = mt5.history_deals_get(from_dt, datetime.now())
        if deals:
            seen_magic = {deal.magic for deal in deals if deal.magic}
            for magic in seen_magic:
                if str(magic) not in found:
                    sym = next((deal.symbol for deal in deals if deal.magic == magic), "")
                    found[str(magic)] = {
                        "name": f"Bot {magic}", "magic": magic,
                        "symbol": sym, "icon": "🤖", "color": "#7c3aed",
                        "ea": "", "files_dir": files_dir,
                    }

    BOTS.clear()
    BOTS.update(found)


def auto_schema(magic: int) -> dict:
    skip = {"ENABLED", "NAME", "SYMBOL", "MAGIC", "EA", "RSI_PERIOD"}
    cfg = read_cfg(magic)
    fields = []
    for key, val in cfg.items():
        if key in skip:
            continue
        is_int = isinstance(val, int)
        fields.append({
            "key":   key,
            "label": key.replace("_", " ").title(),
            "type":  "int" if is_int else "float",
            "min":   0,
            "max":   100000 if is_int else 10000.0,
            "step":  1 if is_int else 0.1,
        })
    return {"fields": fields, "defaults": {f["key"]: cfg.get(f["key"]) for f in fields}}


def ensure_mt5():
    if not mt5.terminal_info():
        mt5.initialize()
    if not mt5.terminal_info():
        raise HTTPException(503, "MT5 no disponible — abre MetaTrader 5")


# ── Auth helpers ───────────────────────────────────────────────────────────────

def get_current_user(creds: HTTPAuthorizationCredentials = Depends(security)):
    if not creds:
        raise HTTPException(401, "Token requerido")
    username = decode_token(creds.credentials)
    if not username:
        raise HTTPException(401, "Token inválido o expirado")
    users = load_users()
    if username not in users:
        raise HTTPException(401, "Usuario no encontrado")
    return {"username": username, **users[username]}


def require_admin(user=Depends(get_current_user)):
    if user.get("role") != "admin":
        raise HTTPException(403, "Solo administradores")
    return user


# ── Lifespan ───────────────────────────────────────────────────────────────────

@asynccontextmanager
async def lifespan(app: FastAPI):
    if mt5.initialize():
        info = mt5.account_info()
        print("✅ MetaTrader 5 conectado")
        if info:
            print(f"   Cuenta: {info.login} | {info.server}")
            print(f"   Balance: ${info.balance:,.2f}")
        discover_bots()
        for bot_id, bot in BOTS.items():
            p = cfg_path(bot["magic"])
            if p and not os.path.exists(p):
                write_ctrl(bot["magic"], True)
        if BOTS:
            names = [f"{b['name']} (magic={b['magic']})" for b in BOTS.values()]
            print(f"   Bots detectados: {', '.join(names)}")
        else:
            print("   ⚠️  Sin bots registrados — inicia tus EAs en MT5")
    else:
        print("⚠️  MT5 no disponible — abre MetaTrader 5 primero")

    users = load_users()
    if "admin" in users:
        print("━" * 40)
        print("  👤 Usuario por defecto: admin")
        print("  🔑 Contraseña:          admin123")
        print("  ⚠️  Cámbiala desde el perfil!")
        print("━" * 40)
    yield
    mt5.shutdown()


app = FastAPI(title="TradingBot 4000", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.mount("/static", StaticFiles(directory=os.path.join(BASE, "static")), name="static")


# ── Auth endpoints ─────────────────────────────────────────────────────────────

class LoginReq(BaseModel):
    username: str
    password: str


@app.post("/api/login")
def login(data: LoginReq):
    users = load_users()
    uname = data.username.lower().strip()
    user  = users.get(uname)
    if not user or not verify_password(data.password, user["password_hash"]):
        raise HTTPException(401, "Credenciales incorrectas")
    token = create_token(uname)
    return {
        "token":        token,
        "username":     uname,
        "display_name": user["display_name"],
        "role":         user["role"],
        "theme":        user.get("theme", "#7c3aed"),
    }


@app.get("/api/me")
def get_me(user=Depends(get_current_user)):
    return {
        "username":     user["username"],
        "display_name": user["display_name"],
        "role":         user["role"],
        "theme":        user.get("theme", "#7c3aed"),
    }


class ProfileUpdate(BaseModel):
    display_name: Optional[str] = None
    theme:        Optional[str] = None
    old_password: Optional[str] = None
    new_password: Optional[str] = None


@app.put("/api/me")
def update_me(data: ProfileUpdate, user=Depends(get_current_user)):
    users = load_users()
    u = users[user["username"]]
    if data.display_name:
        u["display_name"] = data.display_name.strip()
    if data.theme:
        u["theme"] = data.theme
    if data.new_password:
        if not data.old_password or not verify_password(data.old_password, u["password_hash"]):
            raise HTTPException(400, "Contraseña actual incorrecta")
        if len(data.new_password) < 6:
            raise HTTPException(400, "La contraseña debe tener al menos 6 caracteres")
        u["password_hash"] = hash_password(data.new_password)
    save_users(users)
    return {"ok": True, "display_name": u["display_name"], "theme": u["theme"]}


# ── User management ────────────────────────────────────────────────────────────

@app.get("/api/users")
def list_users(admin=Depends(require_admin)):
    return [
        {"username": k, "display_name": v["display_name"], "role": v["role"], "theme": v.get("theme", "#7c3aed")}
        for k, v in load_users().items()
    ]


class CreateUserReq(BaseModel):
    username:     str
    password:     str
    display_name: str
    role:         str = "viewer"
    theme:        str = "#7c3aed"


@app.post("/api/users")
def create_user(data: CreateUserReq, admin=Depends(require_admin)):
    users = load_users()
    uname = data.username.lower().strip()
    if not uname:
        raise HTTPException(400, "Nombre de usuario inválido")
    if uname in users:
        raise HTTPException(400, "El usuario ya existe")
    if len(data.password) < 6:
        raise HTTPException(400, "La contraseña debe tener al menos 6 caracteres")
    users[uname] = {
        "password_hash": hash_password(data.password),
        "display_name":  data.display_name.strip(),
        "role":          data.role if data.role in ("admin", "viewer") else "viewer",
        "theme":         data.theme,
    }
    save_users(users)
    return {"ok": True, "username": uname}


@app.delete("/api/users/{username}")
def delete_user(username: str, admin=Depends(require_admin)):
    if username == admin["username"]:
        raise HTTPException(400, "No puedes eliminarte a ti mismo")
    users = load_users()
    if username not in users:
        raise HTTPException(404, "Usuario no encontrado")
    del users[username]
    save_users(users)
    return {"ok": True}


# ── Trading data ───────────────────────────────────────────────────────────────

@app.get("/api/account")
def get_account(user=Depends(get_current_user)):
    ensure_mt5()
    info = mt5.account_info()
    if not info:
        raise HTTPException(503, "Sin datos de cuenta")
    modes = {0: "DEMO", 1: "CONCURSO", 2: "REAL"}
    return {
        "login":       info.login,
        "server":      info.server,
        "currency":    info.currency,
        "balance":     round(info.balance, 2),
        "equity":      round(info.equity, 2),
        "margin_free": round(info.margin_free, 2),
        "profit":      round(info.profit, 2),
        "leverage":    info.leverage,
        "trade_mode":  modes.get(info.trade_mode, "DEMO"),
        "name":        info.name,
        "company":     info.company,
    }


@app.get("/api/positions")
def get_positions(user=Depends(get_current_user)):
    ensure_mt5()
    positions = mt5.positions_get()
    if not positions:
        return []
    return [
        {
            "ticket":        p.ticket,
            "symbol":        p.symbol,
            "type":          "BUY" if p.type == 0 else "SELL",
            "volume":        p.volume,
            "price_open":    p.price_open,
            "price_current": p.price_current,
            "profit":        round(p.profit, 2),
            "sl":            p.sl,
            "tp":            p.tp,
            "magic":         p.magic,
            "time":          datetime.fromtimestamp(p.time).strftime("%H:%M:%S"),
        }
        for p in positions
    ]


@app.get("/api/history")
def get_history(days: int = 1, user=Depends(get_current_user)):
    ensure_mt5()
    from_dt = datetime.combine(date.today() - timedelta(days=days - 1), datetime.min.time())
    deals   = mt5.history_deals_get(from_dt, datetime.now())
    if not deals:
        return []
    result = []
    for d in deals:
        if d.entry == mt5.DEAL_ENTRY_OUT:
            result.append({
                "ticket": d.ticket,
                "symbol": d.symbol,
                "profit": round(d.profit + d.commission + d.swap, 2),
                "volume": d.volume,
                "time":   datetime.fromtimestamp(d.time).strftime("%H:%M:%S"),
                "magic":  d.magic,
            })
    return sorted(result, key=lambda x: x["time"], reverse=True)


# ── State (aggregated) ────────────────────────────────────────────────────────

@app.get("/api/state")
def get_state(user=Depends(get_current_user)):
    """Single endpoint that returns everything the dashboard needs in one call."""
    connected = bool(mt5.terminal_info())
    if not connected:
        mt5.initialize()
        connected = bool(mt5.terminal_info())

    discover_bots()

    account   = None
    positions = []
    history   = []
    bots_data = {}

    if connected:
        info = mt5.account_info()
        if info:
            modes = {0: "DEMO", 1: "CONCURSO", 2: "REAL"}
            account = {
                "login":       info.login,
                "server":      info.server,
                "balance":     round(info.balance, 2),
                "equity":      round(info.equity, 2),
                "margin_free": round(info.margin_free, 2),
                "profit":      round(info.profit, 2),
                "leverage":    info.leverage,
                "trade_mode":  modes.get(info.trade_mode, "DEMO"),
                "name":        info.name,
                "company":     info.company,
            }

        raw_pos = mt5.positions_get()
        if raw_pos:
            positions = [
                {
                    "ticket":        p.ticket,
                    "symbol":        p.symbol,
                    "type":          "BUY" if p.type == 0 else "SELL",
                    "volume":        p.volume,
                    "price_open":    p.price_open,
                    "price_current": p.price_current,
                    "profit":        round(p.profit, 2),
                    "sl":            p.sl,
                    "tp":            p.tp,
                    "magic":         p.magic,
                    "time":          datetime.fromtimestamp(p.time).strftime("%H:%M:%S"),
                }
                for p in raw_pos
            ]

        from_dt = datetime.combine(date.today(), datetime.min.time())
        deals   = mt5.history_deals_get(from_dt, datetime.now())
        if deals:
            history = sorted(
                [
                    {
                        "ticket": d.ticket,
                        "symbol": d.symbol,
                        "type":   "BUY" if d.type == 0 else "SELL",
                        "profit": round(d.profit + d.commission + d.swap, 2),
                        "volume": d.volume,
                        "time":   datetime.fromtimestamp(d.time).strftime("%H:%M:%S"),
                        "magic":  d.magic,
                        "comment": d.comment,
                    }
                    for d in deals
                    if d.entry == mt5.DEAL_ENTRY_OUT
                ],
                key=lambda x: x["time"], reverse=True
            )

        all_deals = deals
        for bot_id, bot in BOTS.items():
            enabled  = read_ctrl(bot["magic"])
            open_pos = None
            if raw_pos:
                for p in raw_pos:
                    if p.magic == bot["magic"]:
                        open_pos = {
                            "ticket": p.ticket,
                            "profit": round(p.profit, 2),
                            "type":   "BUY" if p.type == 0 else "SELL",
                            "volume": p.volume,
                        }
                        break
            wins = losses = 0
            day_pnl = 0.0
            if all_deals:
                for d in all_deals:
                    if d.entry == mt5.DEAL_ENTRY_OUT and d.magic == bot["magic"]:
                        pnl = d.profit + d.commission + d.swap
                        day_pnl += pnl
                        wins += 1 if pnl >= 0 else 0
                        losses += 0 if pnl >= 0 else 1
            bots_data[bot_id] = {
                "name":     bot["name"],
                "icon":     bot["icon"],
                "color":    bot["color"],
                "symbol":   bot.get("symbol", ""),
                "ea":       bot.get("ea", ""),
                "magic":    bot["magic"],
                "enabled":  enabled,
                "position": open_pos,
                "today":    {"pnl": round(day_pnl, 2), "wins": wins, "losses": losses, "ops": wins + losses},
            }

    return {
        "connected": connected,
        "account":   account,
        "bots":      bots_data,
        "positions": positions,
        "history":   history,
    }


# ── Bot endpoints ──────────────────────────────────────────────────────────────

@app.get("/api/bots")
def get_bots(user=Depends(get_current_user)):
    ensure_mt5()
    discover_bots()
    from_dt   = datetime.combine(date.today(), datetime.min.time())
    deals     = mt5.history_deals_get(from_dt, datetime.now())
    positions = mt5.positions_get()
    result    = {}
    for bot_id, bot in BOTS.items():
        enabled  = read_ctrl(bot["magic"])
        open_pos = None
        if positions:
            for p in positions:
                if p.magic == bot["magic"]:
                    open_pos = {"ticket": p.ticket, "profit": round(p.profit, 2),
                                "type": "BUY" if p.type == 0 else "SELL", "volume": p.volume}
                    break
        wins = losses = 0
        day_pnl = 0.0
        if deals:
            for d in deals:
                if d.entry == mt5.DEAL_ENTRY_OUT and d.magic == bot["magic"]:
                    pnl = d.profit + d.commission + d.swap
                    day_pnl += pnl
                    wins += 1 if pnl >= 0 else 0
                    losses += 0 if pnl >= 0 else 1
        result[bot_id] = {
            "name":    bot["name"],   "icon":    bot["icon"],
            "color":   bot["color"],  "symbol":  bot.get("symbol", ""),
            "magic":   bot["magic"],  "enabled": enabled,
            "position": open_pos,
            "today":   {"pnl": round(day_pnl, 2), "wins": wins, "losses": losses, "ops": wins + losses},
        }
    return result


@app.post("/api/bots/{bot_id}/toggle")
def toggle_bot(bot_id: str, admin=Depends(require_admin)):
    if bot_id not in BOTS:
        raise HTTPException(404, "Bot no encontrado")
    ensure_mt5()
    bot       = BOTS[bot_id]
    new_state = not read_ctrl(bot["magic"])
    p = cfg_path(bot["magic"])
    if not p:
        raise HTTPException(503, "MT5 desconectado — no se pudo escribir el archivo de control")
    write_ctrl(bot["magic"], new_state)
    actual = read_ctrl(bot["magic"])
    if actual != new_state:
        raise HTTPException(500, "Error crítico: el archivo no se pudo escribir. Verifica permisos.")
    return {"ok": True, "enabled": new_state}


@app.get("/api/bots/{bot_id}/config")
def get_config(bot_id: str, user=Depends(get_current_user)):
    if bot_id not in BOTS:
        raise HTTPException(404, "Bot no encontrado")
    magic  = BOTS[bot_id]["magic"]
    ea_key = BOTS[bot_id].get("ea", "")
    if ea_key in BOT_SCHEMA:
        schema   = BOT_SCHEMA[ea_key]
        defaults = {k: v for k, v in schema["defaults"].items() if k != "ENABLED"}
        fields   = schema["fields"]
    else:
        s        = auto_schema(magic)
        defaults = s["defaults"]
        fields   = s["fields"]
    current = read_cfg(magic)
    merged  = {**defaults, **{k: v for k, v in current.items() if k != "ENABLED"}}
    return {"config": merged, "defaults": defaults, "fields": fields}


@app.put("/api/bots/{bot_id}/config")
def update_config(bot_id: str, config: Dict[str, Any] = Body(...), admin=Depends(require_admin)):
    if bot_id not in BOTS:
        raise HTTPException(404, "Bot no encontrado")
    magic  = BOTS[bot_id]["magic"]
    ea_key = BOTS[bot_id].get("ea", "")
    if ea_key in BOT_SCHEMA:
        allowed = {f["key"] for f in BOT_SCHEMA[ea_key]["fields"]}
    else:
        allowed = {f["key"] for f in auto_schema(magic)["fields"]}
    current = read_cfg(magic)
    if not current:
        current = dict(BOT_SCHEMA[ea_key]["defaults"]) if ea_key in BOT_SCHEMA else {"ENABLED": 1}
    for key, val in config.items():
        if key in allowed:
            current[key] = val
    write_cfg(magic, current)
    return {"ok": True}


# ── Chart & tick ───────────────────────────────────────────────────────────────

_TF_MAP = {
    "M1":  mt5.TIMEFRAME_M1,  "M5":  mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15, "M30": mt5.TIMEFRAME_M30,
    "H1":  mt5.TIMEFRAME_H1,  "H4":  mt5.TIMEFRAME_H4,
}


@app.get("/api/chart/{symbol}")
def get_chart(symbol: str, tf: str = "M1", bars: int = 300, user=Depends(get_current_user)):
    ensure_mt5()
    timeframe = _TF_MAP.get(tf, mt5.TIMEFRAME_M1)
    rates = mt5.copy_rates_from_pos(symbol, timeframe, 0, bars)
    if rates is None or len(rates) == 0:
        raise HTTPException(503, f"Sin datos de velas para {symbol}")
    return [
        {"time": int(r["time"]), "open": float(r["open"]), "high": float(r["high"]),
         "low": float(r["low"]), "close": float(r["close"])}
        for r in rates
    ]


@app.get("/api/tick/{symbol}")
def get_tick(symbol: str, user=Depends(get_current_user)):
    ensure_mt5()
    tick = mt5.symbol_info_tick(symbol)
    if tick is None:
        raise HTTPException(503, f"Sin precio para {symbol}")
    sym = mt5.symbol_info(symbol)
    digits = sym.digits if sym else 5
    return {"bid": round(tick.bid, digits), "ask": round(tick.ask, digits), "time": int(tick.time)}


# ── Manual trade ───────────────────────────────────────────────────────────────

class TradeReq(BaseModel):
    symbol:  str
    type:    str    # "BUY" or "SELL"
    volume:  float
    comment: str = "Manual"


@app.post("/api/trade")
def open_trade(data: TradeReq, admin=Depends(require_admin)):
    ensure_mt5()
    if data.type not in ("BUY", "SELL"):
        raise HTTPException(400, "type debe ser BUY o SELL")
    if data.volume <= 0:
        raise HTTPException(400, "El volumen debe ser mayor a 0")
    tick = mt5.symbol_info_tick(data.symbol)
    if tick is None:
        raise HTTPException(503, f"No se pudo obtener precio de {data.symbol}")
    order_type = mt5.ORDER_TYPE_BUY if data.type == "BUY" else mt5.ORDER_TYPE_SELL
    price      = tick.ask if data.type == "BUY" else tick.bid
    filling    = _best_filling(data.symbol)
    req = {
        "action":       mt5.TRADE_ACTION_DEAL,
        "symbol":       data.symbol,
        "volume":       round(data.volume, 2),
        "type":         order_type,
        "price":        price,
        "deviation":    50,
        "type_filling": filling,
        "comment":      data.comment[:31],
        "magic":        0,
    }
    res = mt5.order_send(req)
    if res is None:
        raise HTTPException(500, f"MT5 no respondió — {mt5.last_error()}")
    if res.retcode != 10009:
        raise HTTPException(500, f"Error MT5 {res.retcode}: {res.comment}")
    return {"ticket": res.order, "retcode": res.retcode, "price": price}


# ── Close position ─────────────────────────────────────────────────────────────

@app.post("/api/positions/{ticket}/close")
def close_position(ticket: int, admin=Depends(require_admin)):
    ensure_mt5()
    positions = mt5.positions_get(ticket=ticket)
    if not positions:
        raise HTTPException(404, "Posición no encontrada")
    p    = positions[0]
    tick = mt5.symbol_info_tick(p.symbol)
    if tick is None:
        raise HTTPException(503, f"No se pudo obtener precio de {p.symbol}")
    filling = _best_filling(p.symbol)
    req = {
        "action":       mt5.TRADE_ACTION_DEAL,
        "symbol":       p.symbol,
        "volume":       p.volume,
        "type":         mt5.ORDER_TYPE_SELL if p.type == 0 else mt5.ORDER_TYPE_BUY,
        "position":     ticket,
        "price":        tick.bid if p.type == 0 else tick.ask,
        "deviation":    50,
        "type_filling": filling,
        "magic":        p.magic,
        "comment":      "Dashboard",
    }
    res = mt5.order_send(req)
    if res is None:
        raise HTTPException(500, f"MT5 no respondió — {mt5.last_error()}")
    if res.retcode != 10009:
        raise HTTPException(500, f"Error MT5 {res.retcode}: {res.comment}")
    return {"retcode": res.retcode, "comment": res.comment, "success": True}


# ── Market Watch symbols ───────────────────────────────────────────────────────

@app.get("/api/watchlist")
def get_watchlist(user=Depends(get_current_user)):
    ensure_mt5()
    syms = mt5.symbols_get()
    if not syms:
        return []
    result = []
    for s in syms:
        if not s.visible:
            continue
        tick = mt5.symbol_info_tick(s.name)
        result.append({
            "symbol": s.name,
            "description": s.description,
            "bid": tick.bid if tick else 0,
            "ask": tick.ask if tick else 0,
            "digits": s.digits,
        })
    return sorted(result, key=lambda x: x["symbol"])


# ── Debug ──────────────────────────────────────────────────────────────────────

@app.get("/api/debug", include_in_schema=False)
def debug_info():
    dirs = _all_mt5_files_dirs()
    carpetas = {}
    for d in dirs:
        if not os.path.isdir(d):
            carpetas[d] = {"existe": False, "mreg_files": {}}
            continue
        try:
            all_files = os.listdir(d)
        except OSError as e:
            carpetas[d] = {"existe": True, "error": str(e), "mreg_files": {}}
            continue
        mreg_contents = {}
        for f in all_files:
            if f.startswith("mreg_") and f.endswith(".cfg"):
                mreg_contents[f] = read_cfg_file(os.path.join(d, f))
        carpetas[d] = {"existe": True, "mreg_files": mreg_contents}

    connected = bool(mt5.terminal_info())
    positions = []
    if connected:
        raw = mt5.positions_get()
        if raw:
            positions = [{"magic": p.magic, "symbol": p.symbol, "ticket": p.ticket} for p in raw]

    return {
        "mt5_conectado":    connected,
        "files_dir_primario": get_files_dir(),
        "bots_detectados":  {k: {"name": v["name"], "magic": v["magic"], "ea": v["ea"], "files_dir": v["files_dir"]} for k, v in BOTS.items()},
        "posiciones_abiertas": positions,
        "carpetas":         carpetas,
    }


# ── Static ─────────────────────────────────────────────────────────────────────

@app.get("/", include_in_schema=False)
def index():
    return FileResponse(os.path.join(BASE, "static", "index.html"))


if __name__ == "__main__":
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        local_ip = s.getsockname()[0]
        s.close()
    except Exception:
        local_ip = "localhost"

    print("\n" + "═" * 50)
    print("  🤖  MalditoBot Dashboard")
    print("═" * 50)
    print(f"  📱  Cel (WiFi):  http://{local_ip}:8000")
    print(f"  💻  PC local:   http://localhost:8000")
    print(f"  🌐  Externo:    usa start_ngrok.bat")
    print("═" * 50 + "\n")

    uvicorn.run(app, host="0.0.0.0", port=8000, reload=False)
