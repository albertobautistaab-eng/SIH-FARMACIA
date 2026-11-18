"""Login / logout y control de acceso por rol (RBAC) a nivel de API."""
from functools import wraps

import bcrypt
from flask import Blueprint, jsonify, request, session

import db

bp = Blueprint("auth", __name__)


def usuario_actual():
    if "id_usuario" not in session:
        return None
    return {
        "id_usuario": session["id_usuario"],
        "nombre": session["nombre"],
        "rol": session["rol"],
    }


def _validar_sesion(u):
    """Comprueba en la base que el usuario siga activo y toma su rol actual.
    Así, si el Administrador desactiva a alguien o le cambia el rol, el efecto es
    inmediato y no hay que esperar a que expire su sesión."""
    with db.transaccion() as cur:
        cur.execute(
            """SELECT u.activo, u.nombre, r.nombre_rol
                 FROM usuario u JOIN rol r ON r.id_rol = u.id_rol
                WHERE u.id_usuario = %s""",
            (u["id_usuario"],),
        )
        fila = cur.fetchone()
    if not fila or not fila["activo"]:
        return None
    session["nombre"] = fila["nombre"]
    session["rol"] = fila["nombre_rol"]
    return {"id_usuario": u["id_usuario"], "nombre": fila["nombre"], "rol": fila["nombre_rol"]}


def requiere_rol(*roles):
    """Protege una ruta. Sin argumentos = cualquier usuario autenticado.
    La función decorada recibe el usuario como primer parámetro."""
    def decorador(fn):
        @wraps(fn)
        def envoltura(*args, **kwargs):
            u = usuario_actual()
            if u is None:
                return jsonify(error="No autenticado"), 401
            u = _validar_sesion(u)
            if u is None:
                session.clear()
                return jsonify(error="Tu sesión ya no es válida. Inicia sesión de nuevo."), 401
            if roles and u["rol"] not in roles:
                return jsonify(error="No tienes permiso para esta acción"), 403
            return fn(u, *args, **kwargs)
        return envoltura
    return decorador


def hashear(password: str) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()


@bp.post("/login")
def login():
    d = request.get_json(silent=True) or {}
    correo = (d.get("correo") or "").strip().lower()
    password = d.get("password") or ""
    if not correo or not password or len(password.encode()) > 72:
        return jsonify(error="Credenciales inválidas"), 401

    with db.transaccion() as cur:
        cur.execute(
            """SELECT u.id_usuario, u.nombre, u.hash_password, u.activo, r.nombre_rol
                 FROM usuario u JOIN rol r ON r.id_rol = u.id_rol
                WHERE lower(u.correo) = %s""",
            (correo,),
        )
        u = cur.fetchone()

    # Mismo mensaje si el usuario no existe, está inactivo o la clave falla
    if not u or not u["activo"] or not bcrypt.checkpw(password.encode(), u["hash_password"].encode()):
        return jsonify(error="Credenciales inválidas"), 401

    session.clear()
    session.permanent = True
    session.update(id_usuario=u["id_usuario"], nombre=u["nombre"], rol=u["nombre_rol"])
    return jsonify(id_usuario=u["id_usuario"], nombre=u["nombre"], rol=u["nombre_rol"])


@bp.post("/logout")
def logout():
    session.clear()
    return jsonify(ok=True)


@bp.get("/me")
@requiere_rol()
def me(u):
    return jsonify(u)
