"""Endpoints REST. Cada ruta usa el rol del usuario en sesión: además del
filtro de la API (requiere_rol), PostgreSQL vuelve a validar los permisos."""
import time

from flask import Blueprint, jsonify, request
from psycopg import errors as pgerr

import db
from auth import hashear, requiere_rol

bp = Blueprint("api", __name__)

JEFE = "Jefe de Farmacia"
DISP = "Dispensador"
ADMIN = "Administrador"


# ---------------------------------------------------------------- utilidades
class ErrorValidacion(Exception):
    pass


def ip():
    return request.remote_addr


def cuerpo():
    d = request.get_json(silent=True)
    if not isinstance(d, dict):
        raise ErrorValidacion("Se esperaba un cuerpo JSON")
    return d


def entero(d, campo, requerido=True):
    v = d.get(campo)
    if v in (None, ""):
        if requerido:
            raise ErrorValidacion(f"Falta el campo '{campo}'")
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        raise ErrorValidacion(f"'{campo}' debe ser un número entero")


def texto(d, campo, requerido=True):
    v = d.get(campo)
    if v is None or str(v).strip() == "":
        if requerido:
            raise ErrorValidacion(f"Falta el campo '{campo}'")
        return None
    return str(v).strip()


# ------------------------------------------------------------------- monitor
@bp.get("/monitor")
@requiere_rol()
def monitor(u):
    with db.transaccion(u, ip()) as cur:
        cur.execute("SELECT * FROM v_kpi_monitor")
        kpi = cur.fetchone()
        cur.execute("SELECT * FROM v_insumos_reorden")
        reorden = cur.fetchall()
        cur.execute("SELECT * FROM v_lotes_por_caducar")
        por_caducar = cur.fetchall()
    return jsonify(kpi=kpi, reorden=reorden, por_caducar=por_caducar)


# --------------------------------------------------------------- catálogos
@bp.get("/catalogos")
@requiere_rol()
def catalogos(u):
    """Insumos (con stock vigente) y ubicaciones, para llenar los formularios."""
    with db.transaccion(u, ip()) as cur:
        cur.execute(
            """SELECT id_insumo, codigo_insumo, descripcion_farmaco, es_controlado, stock_vigente
                 FROM v_stock_insumo ORDER BY descripcion_farmaco""")
        insumos = cur.fetchall()
        cur.execute("SELECT id_ubicacion, nombre_area, anaquel_seccion FROM almacen_ubicacion ORDER BY nombre_area")
        ubicaciones = cur.fetchall()
    return jsonify(insumos=insumos, ubicaciones=ubicaciones)


@bp.get("/medicos")
@requiere_rol(DISP, JEFE)
def medicos(u):
    q = f"%{request.args.get('q', '').strip()}%"
    with db.transaccion(u, ip()) as cur:
        cur.execute(
            """SELECT id_medico, cedula_profesional, nombre, especialidad FROM medico
                WHERE nombre ILIKE %s OR cedula_profesional ILIKE %s
                ORDER BY nombre LIMIT 20""", (q, q))
        return jsonify(cur.fetchall())


@bp.get("/pacientes")
@requiere_rol(DISP, JEFE)
def pacientes(u):
    q = f"%{request.args.get('q', '').strip()}%"
    with db.transaccion(u, ip()) as cur:
        cur.execute(
            """SELECT id_paciente, expediente_folio, nombre, area_ingreso FROM paciente
                WHERE nombre ILIKE %s OR expediente_folio ILIKE %s
                ORDER BY nombre LIMIT 20""", (q, q))
        return jsonify(cur.fetchall())


@bp.post("/medicos")
@requiere_rol(DISP, JEFE)
def crear_medico(u):
    d = cuerpo()
    cedula = texto(d, "cedula_profesional")
    nombre = texto(d, "nombre")
    especialidad = texto(d, "especialidad", requerido=False)
    with db.transaccion(u, ip()) as cur:
        try:
            cur.execute(
                """INSERT INTO medico (cedula_profesional, nombre, especialidad)
                   VALUES (%s, %s, %s)
                   RETURNING id_medico, cedula_profesional, nombre, especialidad""",
                (cedula, nombre, especialidad))
            medico = cur.fetchone()
        except pgerr.UniqueViolation:
            raise ErrorValidacion("Ya existe un médico con esa cédula profesional")
    return jsonify(medico), 201


@bp.post("/pacientes")
@requiere_rol(DISP, JEFE)
def crear_paciente(u):
    d = cuerpo()
    expediente = texto(d, "expediente_folio")
    nombre = texto(d, "nombre")
    area = texto(d, "area_ingreso", requerido=False)
    with db.transaccion(u, ip()) as cur:
        try:
            cur.execute(
                """INSERT INTO paciente (expediente_folio, nombre, area_ingreso)
                   VALUES (%s, %s, %s)
                   RETURNING id_paciente, expediente_folio, nombre, area_ingreso""",
                (expediente, nombre, area))
            paciente = cur.fetchone()
        except pgerr.UniqueViolation:
            raise ErrorValidacion("Ya existe un paciente con ese expediente")
    return jsonify(paciente), 201


# ------------------------------------------------------------- dispensación
@bp.post("/dispensaciones")
@requiere_rol(DISP, JEFE)
def dispensar(u):
    d = cuerpo()
    args = (
        entero(d, "id_insumo"),
        entero(d, "cantidad"),
        entero(d, "id_ubicacion_origen"),
        entero(d, "id_ubicacion_destino", requerido=False),
        entero(d, "id_medico", requerido=False),
        entero(d, "id_paciente", requerido=False),
        u["id_usuario"],
    )
    with db.transaccion(u, ip()) as cur:
        cur.execute(
            "SELECT sp_dispensar_peps(%s::int,%s::int,%s::int,%s::int,%s::int,%s::int,%s::int) AS folio",
            args)
        folio = cur.fetchone()["folio"]
        cur.execute("SELECT * FROM fn_detalle_dispensacion(%s)", (folio,))
        lotes = cur.fetchall()
    return jsonify(folio=folio, lotes=lotes), 201


# ------------------------------------------- lotes, entradas y traslados
@bp.get("/lotes")
@requiere_rol(JEFE)
def lotes(u):
    with db.transaccion(u, ip()) as cur:
        cur.execute("SELECT * FROM v_stock_lote ORDER BY fecha_caducidad")
        return jsonify(cur.fetchall())


@bp.get("/proveedores")
@requiere_rol(JEFE)
def proveedores(u):
    with db.transaccion(u, ip()) as cur:
        cur.execute("SELECT id_proveedor, rfc, razon_social FROM proveedor ORDER BY razon_social")
        return jsonify(cur.fetchall())


@bp.post("/lotes")
@requiere_rol(JEFE)
def crear_lote(u):
    d = cuerpo()
    with db.transaccion(u, ip()) as cur:
        cur.execute(
            """INSERT INTO lote (id_insumo, id_proveedor, numero_lote,
                                 fecha_fabricacion, fecha_caducidad, precio_unitario)
               VALUES (%s::int, %s::int, %s, %s::date, %s::date, %s::numeric)
               RETURNING id_lote""",
            (entero(d, "id_insumo"), entero(d, "id_proveedor"), texto(d, "numero_lote"),
             texto(d, "fecha_fabricacion", False), texto(d, "fecha_caducidad"),
             texto(d, "precio_unitario", False)))
        return jsonify(cur.fetchone()), 201


@bp.post("/entradas")
@requiere_rol(JEFE)
def entrada(u):
    """Entrada de un lote que ya existe (id_lote) o de un lote nuevo (lote_nuevo).
    Todo ocurre en una sola transacción: si algo falla no queda un lote huérfano."""
    d = cuerpo()
    cantidad = entero(d, "cantidad")
    id_ubicacion = entero(d, "id_ubicacion")
    nuevo = d.get("lote_nuevo")
    if nuevo is not None and not isinstance(nuevo, dict):
        raise ErrorValidacion("Datos del lote nuevo inválidos")

    with db.transaccion(u, ip()) as cur:
        if nuevo:
            try:
                cur.execute(
                    """INSERT INTO lote (id_insumo, id_proveedor, numero_lote,
                                         fecha_fabricacion, fecha_caducidad, precio_unitario)
                       VALUES (%s::int, %s::int, %s, %s::date, %s::date, %s::numeric)
                       RETURNING id_lote""",
                    (entero(nuevo, "id_insumo"), entero(nuevo, "id_proveedor"),
                     texto(nuevo, "numero_lote"), texto(nuevo, "fecha_fabricacion", False),
                     texto(nuevo, "fecha_caducidad"), texto(nuevo, "precio_unitario", False)))
            except pgerr.UniqueViolation:
                raise ErrorValidacion(
                    "Ya existe un lote con ese número para ese insumo. "
                    "Usa la opción «Lote que ya existe».")
            id_lote = cur.fetchone()["id_lote"]
        else:
            id_lote = entero(d, "id_lote")

        cur.execute(
            "SELECT sp_registrar_entrada(%s::int,%s::int,%s::int,%s::int) AS id_entrada",
            (id_lote, id_ubicacion, cantidad, u["id_usuario"]))
        id_entrada = cur.fetchone()["id_entrada"]
    return jsonify(id_entrada=id_entrada, id_lote=id_lote), 201


@bp.get("/entradas")
@requiere_rol(JEFE)
def entradas(u):
    """Últimas 15 entradas registradas."""
    with db.transaccion(u, ip()) as cur:
        cur.execute(
            """SELECT e.id_entrada, e.fecha_hora, l.numero_lote, i.descripcion_farmaco,
                      a.nombre_area, e.cantidad
                 FROM entrada_inventario e
                 JOIN lote l              ON l.id_lote = e.id_lote
                 JOIN insumo i            ON i.id_insumo = l.id_insumo
                 JOIN almacen_ubicacion a ON a.id_ubicacion = e.id_ubicacion
                ORDER BY e.fecha_hora DESC, e.id_entrada DESC
                LIMIT 15""")
        return jsonify(cur.fetchall())


@bp.get("/existencias")
@requiere_rol(JEFE)
def existencias(u):
    """Existencias vigentes de un insumo, por ubicación (para los traslados)."""
    id_insumo = entero({"v": request.args.get("id_insumo")}, "v")
    with db.transaccion(u, ip()) as cur:
        cur.execute(
            """SELECT a.id_ubicacion, a.nombre_area, SUM(lu.cantidad)::int AS cantidad
                 FROM lote_ubicacion lu
                 JOIN lote l              ON l.id_lote = lu.id_lote
                 JOIN almacen_ubicacion a ON a.id_ubicacion = lu.id_ubicacion
                WHERE l.id_insumo = %s
                  AND l.fecha_caducidad >= CURRENT_DATE
                  AND lu.cantidad > 0
                GROUP BY a.id_ubicacion, a.nombre_area
                ORDER BY a.nombre_area""", (id_insumo,))
        return jsonify(cur.fetchall())


@bp.post("/traslados")
@requiere_rol(JEFE)
def traslado(u):
    d = cuerpo()
    with db.transaccion(u, ip()) as cur:
        cur.execute(
            "SELECT sp_trasladar_peps(%s::int,%s::int,%s::int,%s::int,%s::int)",
            (entero(d, "id_insumo"), entero(d, "cantidad"), entero(d, "id_ubicacion_origen"),
             entero(d, "id_ubicacion_destino"), u["id_usuario"]))
    return jsonify(ok=True), 201


# ------------------------------------------------------------ trazabilidad
@bp.get("/trazabilidad")
@requiere_rol()
def trazabilidad(u):
    """GET /api/trazabilidad?lote=LOT-2024-0081  (acepta con o sin '#')."""
    lote = request.args.get("lote", "").strip()
    if not lote:
        raise ErrorValidacion("Indica el número de lote (?lote=...)")
    inicio = time.perf_counter()
    with db.transaccion(u, ip()) as cur:
        cur.execute(
            """SELECT * FROM v_trazabilidad_lote
                WHERE numero_lote = %s OR numero_lote = '#' || %s
                ORDER BY fecha_evento NULLS FIRST""", (lote, lote))
        filas = cur.fetchall()
    ms = round((time.perf_counter() - inicio) * 1000, 1)
    return jsonify(lote=lote, resultados=filas, tiempo_ms=ms)


# ----------------------------------------------------------------- alertas
@bp.get("/alertas")
@requiere_rol()
def alertas(u):
    with db.transaccion(u, ip()) as cur:
        cur.execute("SELECT * FROM v_alertas_pendientes")
        return jsonify(cur.fetchall())


@bp.post("/alertas/generar")
@requiere_rol(JEFE)
def generar_alertas(u):
    with db.transaccion(u, ip()) as cur:
        cur.execute("SELECT fn_generar_alertas() AS nuevas")
        return jsonify(cur.fetchone())


@bp.post("/alertas/<int:id_alerta>/atender")
@requiere_rol(JEFE)
def atender_alerta(u, id_alerta):
    with db.transaccion(u, ip()) as cur:
        cur.execute(
            """UPDATE alerta SET atendida = TRUE, fecha_atencion = now()
                WHERE id_alerta = %s AND NOT atendida""", (id_alerta,))
        if cur.rowcount == 0:
            return jsonify(error="Alerta no encontrada o ya atendida"), 404
    return jsonify(ok=True)


# --------------------------------------------------------------- auditoría
POR_PAGINA = 25
LIMITE_EXPORTAR = 5000
COLUMNAS_AUDITORIA = """id_auditoria, timestamp_iso, id_usuario, usuario, nombre_usuario, rol,
       accion_sql, tabla_afectada, terminal_origen_ip, controlado,
       datos_anteriores, datos_nuevos"""


def _filtros_auditoria():
    """Arma el WHERE a partir de los parámetros de la URL (siempre con parámetros
    enlazados: nunca se pega texto del usuario dentro del SQL)."""
    a = request.args
    cond, params = [], []
    if a.get("desde"):
        cond.append("timestamp_iso >= %s::date")
        params.append(a["desde"])
    if a.get("hasta"):                                  # inclusive: hasta el final de ese día
        cond.append("timestamp_iso < (%s::date + 1)")
        params.append(a["hasta"])
    if a.get("tabla"):
        cond.append("tabla_afectada = %s")
        params.append(a["tabla"])
    if a.get("accion"):
        if a["accion"] not in ("INSERT", "UPDATE", "DELETE"):
            raise ErrorValidacion("Acción inválida")
        cond.append("accion_sql = %s")
        params.append(a["accion"])
    usuario = a.get("usuario")
    if usuario == "sistema":
        cond.append("id_usuario IS NULL")
    elif usuario:
        try:
            params.append(int(usuario))
        except ValueError:
            raise ErrorValidacion("Usuario inválido")
        cond.append("id_usuario = %s")
    if a.get("controlado") == "1":
        cond.append("controlado")
    return ("WHERE " + " AND ".join(cond)) if cond else "", params


@bp.get("/auditoria")
@requiere_rol(JEFE, ADMIN)
def auditoria(u):
    where, params = _filtros_auditoria()
    try:
        pagina = max(int(request.args.get("pagina", 1)), 1)
    except ValueError:
        raise ErrorValidacion("Página inválida")
    with db.transaccion(u, ip()) as cur:
        cur.execute(f"SELECT COUNT(*) AS n FROM v_bitacora {where}", params)
        total = cur.fetchone()["n"]
        cur.execute(
            f"""SELECT {COLUMNAS_AUDITORIA} FROM v_bitacora {where}
                 ORDER BY timestamp_iso DESC, id_auditoria DESC
                 LIMIT %s OFFSET %s""",
            params + [POR_PAGINA, (pagina - 1) * POR_PAGINA])
        filas = cur.fetchall()
    return jsonify(filas=filas, total=total, pagina=pagina, por_pagina=POR_PAGINA,
                   paginas=max(-(-total // POR_PAGINA), 1))


@bp.get("/auditoria/exportar")
@requiere_rol(JEFE, ADMIN)
def auditoria_exportar(u):
    where, params = _filtros_auditoria()
    with db.transaccion(u, ip()) as cur:
        cur.execute(
            f"""SELECT {COLUMNAS_AUDITORIA} FROM v_bitacora {where}
                 ORDER BY timestamp_iso DESC, id_auditoria DESC LIMIT %s""",
            params + [LIMITE_EXPORTAR])
        filas = cur.fetchall()
    return jsonify(filas=filas, limite=LIMITE_EXPORTAR, truncado=len(filas) == LIMITE_EXPORTAR)


@bp.get("/auditoria/filtros")
@requiere_rol(JEFE, ADMIN)
def auditoria_filtros(u):
    """Opciones para los desplegables de filtro."""
    with db.transaccion(u, ip()) as cur:
        cur.execute("SELECT DISTINCT tabla_afectada FROM v_bitacora ORDER BY tabla_afectada")
        tablas = [r["tabla_afectada"] for r in cur.fetchall()]
        cur.execute(
            """SELECT DISTINCT id_usuario, usuario, nombre_usuario, rol
                 FROM v_bitacora WHERE id_usuario IS NOT NULL ORDER BY id_usuario""")
        usuarios = cur.fetchall()
        cur.execute("SELECT EXISTS (SELECT 1 FROM v_bitacora WHERE id_usuario IS NULL) AS hay")
        hay_sistema = cur.fetchone()["hay"]
    return jsonify(tablas=tablas, usuarios=usuarios, hay_sistema=hay_sistema)


# ---------------------------------------------------- usuarios (Administrador)
def _validar_password(password):
    if len(password) < 8 or len(password.encode()) > 72:
        raise ErrorValidacion("La contraseña debe tener entre 8 y 72 caracteres")


def _validar_correo(correo):
    if "@" not in correo or " " in correo or len(correo) > 100:
        raise ErrorValidacion("Escribe un correo válido")


@bp.get("/roles")
@requiere_rol(ADMIN)
def roles(u):
    with db.transaccion(u, ip()) as cur:
        cur.execute("SELECT id_rol, nombre_rol, descripcion FROM rol ORDER BY id_rol")
        return jsonify(cur.fetchall())


@bp.get("/usuarios")
@requiere_rol(ADMIN)
def usuarios(u):
    with db.transaccion(u, ip()) as cur:   # nunca se devuelve hash_password
        cur.execute(
            """SELECT u.id_usuario, u.nombre, u.correo, u.activo, u.id_rol, r.nombre_rol
                 FROM usuario u JOIN rol r ON r.id_rol = u.id_rol
                ORDER BY u.id_usuario""")
        return jsonify(cur.fetchall())


@bp.post("/usuarios")
@requiere_rol(ADMIN)
def crear_usuario(u):
    d = cuerpo()
    password = texto(d, "password")
    _validar_password(password)
    correo = texto(d, "correo").lower()
    _validar_correo(correo)
    with db.transaccion(u, ip()) as cur:
        try:
            cur.execute(
                """INSERT INTO usuario (id_rol, nombre, correo, hash_password)
                   VALUES (%s::int, %s, %s, %s) RETURNING id_usuario""",
                (entero(d, "id_rol"), texto(d, "nombre"), correo, hashear(password)))
        except pgerr.UniqueViolation:
            raise ErrorValidacion("Ya existe un usuario con ese correo")
        return jsonify(cur.fetchone()), 201


@bp.patch("/usuarios/<int:id_usuario>")
@requiere_rol(ADMIN)
def actualizar_usuario(u, id_usuario):
    """Cambia nombre, correo, rol y/o estado. Para evitar quedarse sin acceso,
    el administrador no puede desactivarse ni cambiarse el rol a sí mismo."""
    d = cuerpo()
    propio = id_usuario == u["id_usuario"]
    sets, params = [], []

    if "activo" in d:
        if not isinstance(d["activo"], bool):
            raise ErrorValidacion("'activo' debe ser true o false")
        if propio and not d["activo"]:
            raise ErrorValidacion("No puedes desactivar tu propia cuenta")
        sets.append("activo = %s")
        params.append(d["activo"])
    if "id_rol" in d:
        if propio:
            raise ErrorValidacion("No puedes cambiar tu propio rol")
        sets.append("id_rol = %s::int")
        params.append(entero(d, "id_rol"))
    if "nombre" in d:
        sets.append("nombre = %s")
        params.append(texto(d, "nombre"))
    if "correo" in d:
        correo = texto(d, "correo").lower()
        _validar_correo(correo)
        sets.append("correo = %s")
        params.append(correo)
    if not sets:
        raise ErrorValidacion("No hay cambios que guardar")

    params.append(id_usuario)
    with db.transaccion(u, ip()) as cur:
        try:   # los fragmentos de SET son fijos: nunca se pega texto del usuario en el SQL
            cur.execute(f"UPDATE usuario SET {', '.join(sets)} WHERE id_usuario = %s", params)
        except pgerr.UniqueViolation:
            raise ErrorValidacion("Ya existe un usuario con ese correo")
        if cur.rowcount == 0:
            return jsonify(error="Usuario no encontrado"), 404
    return jsonify(ok=True)


@bp.post("/usuarios/<int:id_usuario>/password")
@requiere_rol(ADMIN)
def cambiar_password(u, id_usuario):
    d = cuerpo()
    password = texto(d, "password")
    _validar_password(password)
    with db.transaccion(u, ip()) as cur:
        cur.execute("UPDATE usuario SET hash_password = %s WHERE id_usuario = %s",
                    (hashear(password), id_usuario))
        if cur.rowcount == 0:
            return jsonify(error="Usuario no encontrado"), 404
    return jsonify(ok=True)
