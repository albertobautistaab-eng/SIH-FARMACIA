-- =====================================================================
-- 09_bitacora.sql :: Amplía v_bitacora para la pestaña de auditoría
--   + nombre_usuario      (nombre de quien hizo la acción)
--   + datos_anteriores / datos_nuevos (para ver qué cambió exactamente)
--   + controlado          (TRUE si el movimiento toca una sustancia controlada)
-- Las 9 columnas originales se conservan en el mismo orden; los permisos
-- (GRANT) se mantienen. Ejecutar solo este archivo si ya instalaste 01-08.
-- =====================================================================
CREATE OR REPLACE VIEW v_bitacora AS
SELECT b.id_auditoria,
       b.timestamp_iso,
       b.id_usuario,
       COALESCE('USR-' || u.id_usuario, 'SISTEMA') AS usuario,
       COALESCE(r.nombre_rol, 'Sistema')           AS rol,
       b.accion_sql,
       b.tabla_afectada,
       b.descripcion_objeto,
       b.terminal_origen_ip,
       -- columnas nuevas (siempre al final)
       u.nombre                                    AS nombre_usuario,
       b.datos_anteriores,
       b.datos_nuevos,
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
