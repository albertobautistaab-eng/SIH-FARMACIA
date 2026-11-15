-- =====================================================================
-- 10_privacidad_admin.sql :: El Administrador no ve datos personales de
-- médicos ni pacientes.
--
-- Se aplica EN LA BASE DE DATOS (no solo en la página):
--   1) Se le quita el acceso directo a las tablas medico, paciente y
--      bitacora_auditoria (solo consulta las vistas).
--   2) v_trazabilidad_lote y v_bitacora enmascaran esos datos cuando la
--      consulta la hace el rol_administrador (current_user).
-- Los demás roles ven todo igual que antes.
-- Requiere haber ejecutado 01-09. Se puede ejecutar solo este archivo.
-- =====================================================================

REVOKE SELECT ON medico, paciente, bitacora_auditoria FROM rol_administrador;

-- ---------- Trazabilidad ----------
CREATE OR REPLACE VIEW v_trazabilidad_lote AS
SELECT l.numero_lote,
       i.codigo_insumo,
       i.descripcion_farmaco,
       p.razon_social                    AS proveedor,
       p.rfc                             AS proveedor_rfc,
       l.fecha_caducidad,
       'EN_INVENTARIO'::TEXT             AS situacion,
       a.nombre_area::TEXT               AS ubicacion,
       a.anaquel_seccion::TEXT           AS anaquel,
       lu.cantidad                       AS cantidad,
       NULL::TEXT                        AS medico,
       NULL::TEXT                        AS cedula_profesional,
       NULL::TEXT                        AS paciente,
       NULL::TEXT                        AS expediente_folio,
       NULL::TIMESTAMPTZ                 AS fecha_evento
  FROM lote l
  JOIN insumo i             ON i.id_insumo = l.id_insumo
  JOIN proveedor p          ON p.id_proveedor = l.id_proveedor
  JOIN lote_ubicacion lu    ON lu.id_lote = l.id_lote AND lu.cantidad > 0
  JOIN almacen_ubicacion a  ON a.id_ubicacion = lu.id_ubicacion
UNION ALL
SELECT l.numero_lote,
       i.codigo_insumo,
       i.descripcion_farmaco,
       p.razon_social,
       p.rfc,
       l.fecha_caducidad,
       'DISPENSADO'::TEXT,
       a.nombre_area::TEXT,
       a.anaquel_seccion::TEXT,
       d.cantidad_dispensada,
       CASE WHEN current_user = 'rol_administrador' AND d.id_medico IS NOT NULL
            THEN 'Restringido' ELSE m.nombre::TEXT END,
       CASE WHEN current_user = 'rol_administrador' AND d.id_medico IS NOT NULL
            THEN 'Restringido' ELSE m.cedula_profesional::TEXT END,
       CASE WHEN current_user = 'rol_administrador' AND d.id_paciente IS NOT NULL
            THEN 'Restringido' ELSE pa.nombre::TEXT END,
       CASE WHEN current_user = 'rol_administrador' AND d.id_paciente IS NOT NULL
            THEN 'Restringido' ELSE pa.expediente_folio::TEXT END,
       d.fecha_hora_dispensacion
  FROM dispensacion d
  JOIN lote l               ON l.id_lote = d.id_lote
  JOIN insumo i             ON i.id_insumo = l.id_insumo
  JOIN proveedor p          ON p.id_proveedor = l.id_proveedor
  LEFT JOIN almacen_ubicacion a ON a.id_ubicacion = d.id_ubicacion_destino
  LEFT JOIN medico m        ON m.id_medico = d.id_medico
  LEFT JOIN paciente pa     ON pa.id_paciente = d.id_paciente;

-- ---------- Bitácora ----------
-- Quita los datos personales dentro del JSON guardado de medico y paciente
CREATE OR REPLACE FUNCTION fn_enmascarar_datos(p_tabla TEXT, p_datos JSONB)
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE
        WHEN p_datos IS NULL THEN NULL
        WHEN p_tabla = 'paciente' THEN p_datos || jsonb_build_object(
            'nombre', '[restringido]', 'expediente_folio', '[restringido]', 'area_ingreso', '[restringido]')
        WHEN p_tabla = 'medico' THEN p_datos || jsonb_build_object(
            'nombre', '[restringido]', 'cedula_profesional', '[restringido]', 'especialidad', '[restringido]')
        ELSE p_datos
    END;
$$;

CREATE OR REPLACE VIEW v_bitacora AS
SELECT b.id_auditoria,
       b.timestamp_iso,
       b.id_usuario,
       COALESCE('USR-' || u.id_usuario, 'SISTEMA') AS usuario,
       COALESCE(r.nombre_rol, 'Sistema')           AS rol,
       b.accion_sql,
       b.tabla_afectada,
       CASE WHEN current_user = 'rol_administrador' AND b.tabla_afectada IN ('paciente', 'medico')
            THEN b.tabla_afectada ELSE b.descripcion_objeto END AS descripcion_objeto,
       b.terminal_origen_ip,
       u.nombre                                    AS nombre_usuario,
       CASE WHEN current_user = 'rol_administrador'
            THEN fn_enmascarar_datos(b.tabla_afectada, b.datos_anteriores)
            ELSE b.datos_anteriores END            AS datos_anteriores,
       CASE WHEN current_user = 'rol_administrador'
            THEN fn_enmascarar_datos(b.tabla_afectada, b.datos_nuevos)
            ELSE b.datos_nuevos END                AS datos_nuevos,
       (
         EXISTS (SELECT 1
                   FROM lote l
                   JOIN insumo i ON i.id_insumo = l.id_insumo
                  WHERE i.es_controlado
                    AND l.id_lote = (COALESCE(b.datos_nuevos, b.datos_anteriores) ->> 'id_lote')::INT)
         OR (b.tabla_afectada = 'insumo'
             AND COALESCE((COALESCE(b.datos_nuevos, b.datos_anteriores) ->> 'es_controlado')::BOOLEAN, FALSE))
       )                                           AS controlado
  FROM bitacora_auditoria b
  LEFT JOIN usuario u ON u.id_usuario = b.id_usuario
  LEFT JOIN rol r     ON r.id_rol = u.id_rol
 ORDER BY b.timestamp_iso DESC, b.id_auditoria DESC;
