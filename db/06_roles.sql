-- =====================================================================
-- 06_roles.sql :: Control de acceso (RBAC) a nivel de base de datos
--
-- Modelo:
--   * El backend Python se conecta como "app_backend" (NOINHERIT: por sí
--     mismo casi no puede hacer nada).
--   * Tras autenticar al usuario, el backend ejecuta en CADA transacción:
--         SET LOCAL ROLE rol_dispensador;   -- según usuario.id_rol
--         SELECT fn_set_contexto(<id_usuario>, '<ip_cliente>');
--     y así PostgreSQL aplica los permisos del rol del usuario.
--   * Separación de funciones: el Administrador gestiona usuarios y
--     consulta la bitácora, pero NO dispensa medicamentos.
-- =====================================================================

DO $$
DECLARE r TEXT;
BEGIN
    FOREACH r IN ARRAY ARRAY['rol_dispensador','rol_jefe_farmacia','rol_administrador']
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_backend') THEN
        -- !! CAMBIAR la contraseña antes de producción !!
        CREATE ROLE app_backend LOGIN NOINHERIT PASSWORD 'farmacia';
    END IF;
END;
$$;

GRANT rol_dispensador, rol_jefe_farmacia, rol_administrador TO app_backend;

-- ---------- Cerrar todo por defecto ----------
REVOKE ALL ON ALL TABLES    IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT  USAGE ON SCHEMA public TO app_backend, rol_dispensador, rol_jefe_farmacia, rol_administrador;

-- ---------- app_backend: solo lo necesario para autenticar ----------
GRANT SELECT (id_usuario, id_rol, nombre, correo, hash_password, activo) ON usuario TO app_backend;
GRANT SELECT ON rol TO app_backend;
GRANT EXECUTE ON FUNCTION fn_set_contexto(INT, TEXT) TO app_backend;

-- ---------- Común a los tres roles ----------
GRANT EXECUTE ON FUNCTION fn_set_contexto(INT, TEXT) TO rol_dispensador, rol_jefe_farmacia, rol_administrador;
GRANT SELECT ON v_kpi_monitor, v_stock_insumo, v_stock_lote, v_insumos_reorden,
                v_lotes_por_caducar, v_alertas_pendientes, v_trazabilidad_lote
      TO rol_dispensador, rol_jefe_farmacia, rol_administrador;

-- ---------- Dispensador ----------
GRANT SELECT ON insumo, almacen_ubicacion, medico, paciente TO rol_dispensador;
GRANT EXECUTE ON FUNCTION sp_dispensar_peps(INT, INT, INT, INT, INT, INT, INT) TO rol_dispensador;

-- ---------- Jefe de Farmacia (hereda al dispensador) ----------
GRANT rol_dispensador TO rol_jefe_farmacia;
GRANT SELECT, INSERT, UPDATE ON insumo, proveedor, lote, almacen_ubicacion, medico, paciente
      TO rol_jefe_farmacia;
GRANT SELECT ON lote_ubicacion, entrada_inventario, dispensacion TO rol_jefe_farmacia;
GRANT SELECT, UPDATE (atendida, fecha_atencion) ON alerta TO rol_jefe_farmacia;
GRANT SELECT ON v_bitacora TO rol_jefe_farmacia;
GRANT EXECUTE ON FUNCTION sp_registrar_entrada(INT, INT, INT, INT)    TO rol_jefe_farmacia;
GRANT EXECUTE ON FUNCTION sp_trasladar_peps(INT, INT, INT, INT, INT)  TO rol_jefe_farmacia;
GRANT EXECUTE ON FUNCTION fn_generar_alertas()                        TO rol_jefe_farmacia;

-- ---------- Administrador ----------
GRANT SELECT, INSERT, UPDATE ON usuario, rol TO rol_administrador;   -- sin DELETE: se desactiva (activo=false)
GRANT SELECT ON bitacora_auditoria, v_bitacora TO rol_administrador;
GRANT SELECT ON insumo, proveedor, lote, lote_ubicacion, almacen_ubicacion,
                medico, paciente, dispensacion, entrada_inventario, alerta
      TO rol_administrador;

-- ---------- Bitácora: nadie modifica ni borra ----------
REVOKE UPDATE, DELETE, TRUNCATE ON bitacora_auditoria FROM PUBLIC, app_backend,
       rol_dispensador, rol_jefe_farmacia, rol_administrador;
