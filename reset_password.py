import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from auth import hash_password, load_users, save_users

users = load_users()
nueva = input("Nueva contraseña para 'admin': ").strip()
if not nueva:
    print("Contraseña vacía, cancelado.")
    sys.exit(1)
users["admin"]["password_hash"] = hash_password(nueva)
save_users(users)
print(f"✓ Contraseña actualizada. Ya puedes entrar con admin / {nueva}")
