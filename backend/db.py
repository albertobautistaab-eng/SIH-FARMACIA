"""Conexión a PostgreSQL y manejo de transacciones con contexto de usuario."""
import os
import threading
from contextlib import contextmanager

from psycopg import sql
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

# Rol de la aplicación (usuario.rol.nombre_rol) -> rol de PostgreSQL.
# Lista blanca fija: nunca se arma el nombre del rol con texto del usuario.
ROLES_BD = {
    "Jefe de Farmacia": "rol_jefe_farmacia",
    "Dispensador": "rol_dispensador",
    "Administrador": "rol_administrador",
}

_pool = None
_candado = threading.Lock()


def init_pool():
    """Abre el pool de conexiones. Se puede llamar varias veces sin problema."""
    global _pool
    if _pool is not None:
        return
    _pool = ConnectionPool(
        os.environ["DATABASE_URL"],
        min_size=1,
        max_size=10,
        kwargs={"row_factory": dict_row},   # las filas llegan como diccionarios
        open=True,
    )


def _obtener_pool():
    """Si por cualquier motivo el pool aún no existe, se abre en este momento."""
    if _pool is None:
        with _candado:
            init_pool()
    return _pool


@contextmanager
def transaccion(usuario=None, ip=None):
    """Abre una transacción y entrega un cursor.

    usuario = {'id_usuario': int | None, 'rol': 'Dispensador' | ...}
      - Con usuario: SET LOCAL ROLE (PostgreSQL aplica los permisos de su rol)
        y fn_set_contexto (la bitácora sabrá quién y desde dónde).
      - Sin usuario: se usa app_backend tal cual (solo sirve para el login).

    Hace COMMIT al salir bien y ROLLBACK si hay cualquier excepción.
    """
    with _obtener_pool().connection() as conn:
        with conn.cursor() as cur:
            if usuario:
                rol_bd = ROLES_BD.get(usuario["rol"])
                if rol_bd is None:
                    raise PermissionError(f"Rol desconocido: {usuario['rol']}")
                cur.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(rol_bd)))
                cur.execute(
                    "SELECT fn_set_contexto(%s::int, %s::text)",
                    (usuario["id_usuario"], ip),
                )
            yield cur