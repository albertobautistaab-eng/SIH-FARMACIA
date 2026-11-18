"""Genera las alertas de caducidad y stock mínimo. Programar 1 vez al día.
  Linux/Mac (cron):   0 6 * * *  cd /ruta/backend && python generar_alertas.py
  Windows: Programador de tareas -> ejecutar  python generar_alertas.py
"""
from dotenv import load_dotenv

load_dotenv()
import backend.db as db  # noqa: E402

db.init_pool()
# id_usuario None => la bitácora lo registra como SISTEMA
with db.transaccion({"id_usuario": None, "rol": "Jefe de Farmacia"}, "sistema") as cur:
    cur.execute("SELECT fn_generar_alertas() AS nuevas")
    print("Alertas nuevas:", cur.fetchone()["nuevas"])
