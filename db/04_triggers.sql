-- =====================================================================
-- 04_triggers.sql :: Auditoría automática e inmutabilidad de la bitácora
-- =====================================================================

-- ---------------------------------------------------------------------
-- Trigger genérico de auditoría (INSERT / UPDATE / DELETE).
-- Usuario: viene de fn_set_contexto() / sp_* (app.user_id).
-- Terminal: app.client_ip (IP real del cliente enviada por el backend);
--           si no existe, IP de la conexión a la BD; si no, 'local'.
-- SECURITY DEFINER: escribe en la bitácora aunque el rol que ejecuta la
-- operación no tenga permiso directo sobre ella.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_auditar()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_viejo  JSONB;
    v_nuevo  JSONB;
    v_ip     TEXT;
    v_desc   TEXT;
BEGIN
    v_ip := COALESCE(NULLIF(current_setting('app.client_ip', true), ''),
                     host(inet_client_addr()),
                     'local');

    IF TG_OP IN ('UPDATE','DELETE') THEN
        v_viejo := to_jsonb(OLD) - 'hash_password';
    END IF;
    IF TG_OP IN ('INSERT','UPDATE') THEN
        v_nuevo := to_jsonb(NEW) - 'hash_password';
    END IF;

    v_desc := TG_TABLE_NAME || ' ' || COALESCE(
                  CASE WHEN TG_OP = 'DELETE' THEN v_viejo::TEXT ELSE v_nuevo::TEXT END, '');

    INSERT INTO bitacora_auditoria
        (id_usuario, accion_sql, tabla_afectada, descripcion_objeto,
         datos_anteriores, datos_nuevos, terminal_origen_ip)
    VALUES
        (fn_usuario_actual(), TG_OP, TG_TABLE_NAME, v_desc,
         v_viejo, v_nuevo, v_ip);

    RETURN NULL;   -- AFTER trigger: el valor de retorno se ignora
END;
$$;

-- Tablas auditadas (todas las que contienen datos operativos o de seguridad)
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'rol','usuario','proveedor','insumo','almacen_ubicacion',
        'medico','paciente','lote','lote_ubicacion',
        'entrada_inventario','dispensacion'
    ]
    LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_auditar ON %I', t);
        EXECUTE format(
            'CREATE TRIGGER trg_auditar
               AFTER INSERT OR UPDATE OR DELETE ON %I
               FOR EACH ROW EXECUTE FUNCTION fn_auditar()', t);
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- Inmutabilidad: la bitácora no admite UPDATE, DELETE ni TRUNCATE.
-- (Además se revocan esos permisos en 06_roles.sql.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_bitacora_inmutable()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'La bitácora de auditoría es inmutable (% no permitido)', TG_OP;
END;
$$;

DROP TRIGGER IF EXISTS trg_bitacora_inmutable ON bitacora_auditoria;
CREATE TRIGGER trg_bitacora_inmutable
    BEFORE UPDATE OR DELETE ON bitacora_auditoria
    FOR EACH ROW EXECUTE FUNCTION fn_bitacora_inmutable();

DROP TRIGGER IF EXISTS trg_bitacora_inmutable_truncate ON bitacora_auditoria;
CREATE TRIGGER trg_bitacora_inmutable_truncate
    BEFORE TRUNCATE ON bitacora_auditoria
    FOR EACH STATEMENT EXECUTE FUNCTION fn_bitacora_inmutable();
