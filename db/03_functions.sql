-- =====================================================================
-- 03_functions.sql :: Lógica de negocio dentro del motor
--   fn_set_contexto          -> identifica al usuario/terminal (para auditoría)
--   fn_verificar_stock_insumo-> alerta de stock mínimo (abre/cierra sola)
--   fn_generar_alertas       -> alertas de caducidad 90/60/30 días + stock
--   sp_registrar_entrada     -> entrada de un lote a una ubicación
--   sp_dispensar_peps        -> salida con regla PEPS (multi-lote)
--   sp_trasladar_peps        -> traslado entre ubicaciones con PEPS
-- Todas son SECURITY DEFINER: los permisos se controlan con EXECUTE
-- (ver 06_roles.sql), no con acceso directo a las tablas.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Contexto de sesión. El backend (Python) lo llama al INICIO de cada
-- transacción, porque la BD solo ve al usuario del pool de conexiones.
--   SELECT fn_set_contexto(42, '192.168.1.104');
-- Los valores duran solo la transacción actual (is_local = true).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_set_contexto(p_id_usuario INT, p_ip TEXT DEFAULT NULL)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM set_config('app.user_id',   COALESCE(p_id_usuario::TEXT, ''), true);
    PERFORM set_config('app.client_ip', COALESCE(p_ip, ''), true);
END;
$$;

CREATE OR REPLACE FUNCTION fn_usuario_actual()
RETURNS INT
LANGUAGE sql STABLE
AS $$
    SELECT NULLIF(current_setting('app.user_id', true), '')::INT;
$$;

-- ---------------------------------------------------------------------
-- Stock mínimo: abre una alerta si el stock vigente (no caducado) cae
-- bajo el umbral y la cierra automáticamente cuando se repone.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_verificar_stock_insumo(p_id_insumo INT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_min   INT;
    v_desc  TEXT;
    v_stock INT;
BEGIN
    SELECT i.stock_minimo_seguridad, i.descripcion_farmaco
      INTO v_min, v_desc
      FROM insumo i
     WHERE i.id_insumo = p_id_insumo;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT COALESCE(SUM(lu.cantidad), 0)
      INTO v_stock
      FROM lote l
      JOIN lote_ubicacion lu ON lu.id_lote = l.id_lote
     WHERE l.id_insumo = p_id_insumo
       AND l.fecha_caducidad >= CURRENT_DATE;

    IF v_stock < v_min THEN
        INSERT INTO alerta (tipo, id_insumo, mensaje)
        VALUES ('STOCK_MINIMO', p_id_insumo,
                format('%s: stock %s por debajo del mínimo %s. Notificar a Compras.',
                       v_desc, v_stock, v_min))
        ON CONFLICT DO NOTHING;   -- ya existe una alerta abierta
    ELSE
        UPDATE alerta
           SET atendida = TRUE, fecha_atencion = now()
         WHERE id_insumo = p_id_insumo
           AND tipo = 'STOCK_MINIMO'
           AND NOT atendida;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------
-- Generador periódico de alertas (ejecutar 1 vez al día, ver README/cron).
-- Devuelve cuántas alertas nuevas se crearon.
--   SELECT fn_generar_alertas();
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_generar_alertas()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    r        RECORD;
    v_dias   INT;
    v_tipo   TEXT;
    v_filas  INT;
    v_nuevas INT := 0;
BEGIN
    -- 1) Cerrar alertas de caducidad de lotes que ya no tienen existencias
    UPDATE alerta a
       SET atendida = TRUE, fecha_atencion = now()
     WHERE a.tipo LIKE 'CADUC%'
       AND NOT a.atendida
       AND NOT EXISTS (SELECT 1 FROM lote_ubicacion lu
                        WHERE lu.id_lote = a.id_lote AND lu.cantidad > 0);

    -- 2) Lotes con existencias que caducan en <= 90 días (o ya caducados)
    FOR r IN
        SELECT l.id_lote, l.id_insumo, l.numero_lote, l.fecha_caducidad,
               i.descripcion_farmaco, SUM(lu.cantidad) AS stock
          FROM lote l
          JOIN insumo i ON i.id_insumo = l.id_insumo
          JOIN lote_ubicacion lu ON lu.id_lote = l.id_lote
         WHERE l.fecha_caducidad <= CURRENT_DATE + 90
         GROUP BY l.id_lote, i.id_insumo
        HAVING SUM(lu.cantidad) > 0
    LOOP
        v_dias := r.fecha_caducidad - CURRENT_DATE;
        v_tipo := CASE
                    WHEN v_dias < 0   THEN 'CADUCADO'
                    WHEN v_dias <= 30 THEN 'CADUCIDAD_30'
                    WHEN v_dias <= 60 THEN 'CADUCIDAD_60'
                    ELSE                   'CADUCIDAD_90'
                  END;

        -- Cerrar el nivel anterior del mismo lote (p. ej. 90 -> 60)
        UPDATE alerta
           SET atendida = TRUE, fecha_atencion = now()
         WHERE id_lote = r.id_lote
           AND tipo LIKE 'CADUC%'
           AND tipo <> v_tipo
           AND NOT atendida;

        INSERT INTO alerta (tipo, id_insumo, id_lote, mensaje)
        VALUES (v_tipo, r.id_insumo, r.id_lote,
                format('%s, lote %s: %s unidades, caducidad %s (%s días).',
                       r.descripcion_farmaco, r.numero_lote, r.stock,
                       r.fecha_caducidad, v_dias))
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_filas = ROW_COUNT;
        v_nuevas := v_nuevas + v_filas;
    END LOOP;

    -- 3) Stock mínimo de todos los insumos activos
    FOR r IN SELECT id_insumo FROM insumo WHERE activo LOOP
        PERFORM fn_verificar_stock_insumo(r.id_insumo);
    END LOOP;

    RETURN v_nuevas;
END;
$$;

-- ---------------------------------------------------------------------
-- Entrada de inventario: suma existencias de un lote en una ubicación.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_registrar_entrada(
    p_id_lote      INT,
    p_id_ubicacion INT,
    p_cantidad     INT,
    p_id_usuario   INT
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_insumo  INT;
    v_caduca  DATE;
    v_id      BIGINT;
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad debe ser mayor a cero';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE id_usuario = p_id_usuario AND activo) THEN
        RAISE EXCEPTION 'Usuario % inexistente o inactivo', p_id_usuario;
    END IF;

    SELECT id_insumo, fecha_caducidad INTO v_insumo, v_caduca
      FROM lote WHERE id_lote = p_id_lote;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Lote % no existe', p_id_lote;
    END IF;
    IF v_caduca < CURRENT_DATE THEN
        RAISE EXCEPTION 'No se puede dar entrada a un lote caducado (%).', v_caduca;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM almacen_ubicacion WHERE id_ubicacion = p_id_ubicacion) THEN
        RAISE EXCEPTION 'Ubicación % no existe', p_id_ubicacion;
    END IF;

    PERFORM set_config('app.user_id', p_id_usuario::TEXT, true);

    INSERT INTO entrada_inventario (id_lote, id_ubicacion, id_usuario, cantidad)
    VALUES (p_id_lote, p_id_ubicacion, p_id_usuario, p_cantidad)
    RETURNING id_entrada INTO v_id;

    INSERT INTO lote_ubicacion (id_lote, id_ubicacion, cantidad)
    VALUES (p_id_lote, p_id_ubicacion, p_cantidad)
    ON CONFLICT (id_lote, id_ubicacion)
    DO UPDATE SET cantidad = lote_ubicacion.cantidad + EXCLUDED.cantidad;

    PERFORM fn_verificar_stock_insumo(v_insumo);
    RETURN v_id;
END;
$$;

-- ---------------------------------------------------------------------
-- DISPENSACIÓN CON REGLA PEPS
--   * Descuenta SIEMPRE del lote con caducidad más próxima.
--   * Si un lote no alcanza, continúa con el siguiente (varias filas en
--     DISPENSACION con el mismo folio_operacion).
--   * Nunca toma lotes caducados.
--   * Bloquea filas (FOR UPDATE) en orden de caducidad: sin condiciones
--     de carrera ni deadlocks entre dispensaciones simultáneas.
--   * Sustancias controladas exigen médico y paciente.
--   * Todo o nada: si no hay stock suficiente se revierte la operación.
-- Devuelve el folio_operacion (UUID).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_dispensar_peps(
    p_id_insumo            INT,
    p_cantidad             INT,
    p_id_ubicacion_origen  INT,
    p_id_ubicacion_destino INT,
    p_id_medico            INT,
    p_id_paciente          INT,
    p_id_usuario           INT
) RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_controlado BOOLEAN;
    v_activo     BOOLEAN;
    v_folio      UUID := gen_random_uuid();
    v_restante   INT  := p_cantidad;
    v_tomar      INT;
    r            RECORD;
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad debe ser mayor a cero';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE id_usuario = p_id_usuario AND activo) THEN
        RAISE EXCEPTION 'Usuario % inexistente o inactivo', p_id_usuario;
    END IF;

    SELECT es_controlado, activo INTO v_controlado, v_activo
      FROM insumo WHERE id_insumo = p_id_insumo;
    IF NOT FOUND OR NOT v_activo THEN
        RAISE EXCEPTION 'Insumo % inexistente o inactivo', p_id_insumo;
    END IF;

    IF v_controlado AND (p_id_medico IS NULL OR p_id_paciente IS NULL) THEN
        RAISE EXCEPTION 'Sustancia controlada: se requiere médico prescriptor y paciente';
    END IF;
    IF p_id_medico IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM medico WHERE id_medico = p_id_medico) THEN
        RAISE EXCEPTION 'Médico % no existe', p_id_medico;
    END IF;
    IF p_id_paciente IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM paciente WHERE id_paciente = p_id_paciente) THEN
        RAISE EXCEPTION 'Paciente % no existe', p_id_paciente;
    END IF;

    PERFORM set_config('app.user_id', p_id_usuario::TEXT, true);

    FOR r IN
        SELECT lu.id_lote, lu.cantidad
          FROM lote_ubicacion lu
          JOIN lote l ON l.id_lote = lu.id_lote
         WHERE l.id_insumo = p_id_insumo
           AND lu.id_ubicacion = p_id_ubicacion_origen
           AND lu.cantidad > 0
           AND l.fecha_caducidad >= CURRENT_DATE
         ORDER BY l.fecha_caducidad ASC, l.id_lote ASC      -- << PEPS
           FOR UPDATE OF lu
    LOOP
        v_tomar := LEAST(r.cantidad, v_restante);

        UPDATE lote_ubicacion
           SET cantidad = cantidad - v_tomar
         WHERE id_lote = r.id_lote AND id_ubicacion = p_id_ubicacion_origen;

        INSERT INTO dispensacion (folio_operacion, id_lote, id_ubicacion_origen,
                                  id_ubicacion_destino, id_medico, id_paciente,
                                  id_usuario, cantidad_dispensada)
        VALUES (v_folio, r.id_lote, p_id_ubicacion_origen, p_id_ubicacion_destino,
                p_id_medico, p_id_paciente, p_id_usuario, v_tomar);

        v_restante := v_restante - v_tomar;
        EXIT WHEN v_restante = 0;
    END LOOP;

    IF v_restante > 0 THEN
        RAISE EXCEPTION
            'Stock vigente insuficiente: faltan % de % solicitadas (los lotes caducados se excluyen)',
            v_restante, p_cantidad;
    END IF;

    PERFORM fn_verificar_stock_insumo(p_id_insumo);
    RETURN v_folio;
END;
$$;

-- ---------------------------------------------------------------------
-- Traslado entre ubicaciones (ej. Almacén Central -> Quirófano A3),
-- también por PEPS. Queda registrado en la bitácora vía triggers.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sp_trasladar_peps(
    p_id_insumo            INT,
    p_cantidad             INT,
    p_id_ubicacion_origen  INT,
    p_id_ubicacion_destino INT,
    p_id_usuario           INT
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_restante INT := p_cantidad;
    v_tomar    INT;
    r          RECORD;
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad debe ser mayor a cero';
    END IF;
    IF p_id_ubicacion_origen = p_id_ubicacion_destino THEN
        RAISE EXCEPTION 'Origen y destino no pueden ser la misma ubicación';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE id_usuario = p_id_usuario AND activo) THEN
        RAISE EXCEPTION 'Usuario % inexistente o inactivo', p_id_usuario;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM almacen_ubicacion WHERE id_ubicacion = p_id_ubicacion_destino) THEN
        RAISE EXCEPTION 'Ubicación destino % no existe', p_id_ubicacion_destino;
    END IF;

    PERFORM set_config('app.user_id', p_id_usuario::TEXT, true);

    FOR r IN
        SELECT lu.id_lote, lu.cantidad
          FROM lote_ubicacion lu
          JOIN lote l ON l.id_lote = lu.id_lote
         WHERE l.id_insumo = p_id_insumo
           AND lu.id_ubicacion = p_id_ubicacion_origen
           AND lu.cantidad > 0
           AND l.fecha_caducidad >= CURRENT_DATE
         ORDER BY l.fecha_caducidad ASC, l.id_lote ASC
           FOR UPDATE OF lu
    LOOP
        v_tomar := LEAST(r.cantidad, v_restante);

        UPDATE lote_ubicacion
           SET cantidad = cantidad - v_tomar
         WHERE id_lote = r.id_lote AND id_ubicacion = p_id_ubicacion_origen;

        INSERT INTO lote_ubicacion (id_lote, id_ubicacion, cantidad)
        VALUES (r.id_lote, p_id_ubicacion_destino, v_tomar)
        ON CONFLICT (id_lote, id_ubicacion)
        DO UPDATE SET cantidad = lote_ubicacion.cantidad + EXCLUDED.cantidad;

        v_restante := v_restante - v_tomar;
        EXIT WHEN v_restante = 0;
    END LOOP;

    IF v_restante > 0 THEN
        RAISE EXCEPTION 'Stock vigente insuficiente en origen: faltan % de %',
                        v_restante, p_cantidad;
    END IF;
    -- El stock total no cambia en un traslado, no hace falta verificar alertas.
END;
$$;
