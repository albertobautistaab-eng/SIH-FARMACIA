"""Punto de entrada. Ejecutar:  python app.py   (desde la carpeta backend)"""
import logging
import os
from datetime import date, datetime, timedelta
from decimal import Decimal
from pathlib import Path
from uuid import UUID

import psycopg
from dotenv import load_dotenv
from flask import Flask, abort, jsonify, send_from_directory

load_dotenv()

import api    # noqa: E402  (después de load_dotenv)
import auth   # noqa: E402
import db     # noqa: E402

RAIZ_WEB = Path(__file__).resolve().parent.parent
# Solo estos archivos se sirven al navegador (así no se expone .env, db/, etc.)
ARCHIVOS_WEB = {"index.html", "styles.css", "app.js"}


def _json_default(o):
    if isinstance(o, (datetime, date)):
        return o.isoformat()
    if isinstance(o, Decimal):
        return float(o)
    if isinstance(o, UUID):
        return str(o)
    raise TypeError(f"No serializable: {type(o)}")


def create_app():
    app = Flask(__name__)

    secret = os.environ.get("SECRET_KEY")
    if not secret:
        raise RuntimeError("Falta SECRET_KEY en el archivo .env")
    app.config.update(
        SECRET_KEY=secret,
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_SECURE=os.environ.get("COOKIE_SECURE") == "1",
        PERMANENT_SESSION_LIFETIME=timedelta(hours=8),
    )
    app.json.default = _json_default

    db.init_pool()
    app.register_blueprint(auth.bp, url_prefix="/api")
    app.register_blueprint(api.bp, url_prefix="/api")

    # ---------- frontend ----------
    @app.get("/")
    def index():
        return send_from_directory(RAIZ_WEB, "index.html")

    @app.get("/<path:nombre>")
    def estatico(nombre):
        if nombre in ARCHIVOS_WEB:
            return send_from_directory(RAIZ_WEB, nombre)
        abort(404)

    # ---------- errores: se traducen a JSON legible ----------
    def err(msg, code):
        return jsonify(error=msg), code

    @app.errorhandler(api.ErrorValidacion)
    def _(e):
        return err(str(e), 400)

    @app.errorhandler(psycopg.errors.RaiseException)       # RAISE EXCEPTION de nuestras funciones
    def _(e):
        return err(e.diag.message_primary, 400)

    @app.errorhandler(psycopg.errors.InsufficientPrivilege)
    def _(e):
        return err("No tienes permiso para esta acción", 403)

    @app.errorhandler(psycopg.errors.UniqueViolation)
    def _(e):
        return err("Ya existe un registro con esos datos", 409)

    @app.errorhandler(psycopg.errors.ForeignKeyViolation)
    def _(e):
        return err("Referencia inválida: el registro relacionado no existe", 400)

    @app.errorhandler(psycopg.errors.CheckViolation)
    @app.errorhandler(psycopg.errors.NotNullViolation)
    @app.errorhandler(psycopg.errors.DataError)
    def _(e):
        return err("Datos inválidos o incompletos", 400)

    @app.errorhandler(psycopg.OperationalError)
    def _(e):
        logging.exception("Base de datos no disponible")
        return err("Base de datos no disponible", 503)

    return app


app = create_app()

if __name__ == "__main__":
    app.run(debug=os.environ.get("FLASK_DEBUG") == "1", port=5000)