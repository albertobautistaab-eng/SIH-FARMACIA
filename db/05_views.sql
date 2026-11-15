-- =====================================================================
-- 05_views.sql :: Vistas para tableros (monitor, trazabilidad, bitácora)
-- Las vistas corren con los permisos de su dueño: los roles solo
-- necesitan SELECT sobre la vista, no sobre las tablas base.
-- =====================================================================

-- Existencia total por lote (suma de todas sus ubicaciones)
CREATE OR REPLACE VIEW v_stock_lote AS
SELECT l.id_lote,
       l.numero_lote,
       l.id_insumo,
       i.codigo_insumo,
       i.descripcion_farmaco,
       l.id_proveedor,
       l.fecha_caducidad,
       (l.fecha_caducidad - CURRENT_DATE)         AS dias_para_caducar,
       COALESCE(SUM(lu.cantidad), 0)::INT         AS stock_total
  FROM lote l
  JOIN insumo i ON i.id_insumo = l.id_insumo
  LEFT JOIN lote_ubicacion lu ON lu.id_lote = l.id_lote
 GROUP BY l.id_lote, i.id_insumo;

-- Existencia por insumo (vigente = no caducada) y comparación con el mínimo
CREATE OR REPLACE VIEW v_stock_insumo AS
SELECT s.*,
       (s.stock_vigente < s.stock_minimo_seguridad) AS bajo_minimo
  FROM (
        SELECT i.id_insumo,
               i.codigo_insumo,
               i.descripcion_farmaco,
               i.es_controlado,
               i.stock_minimo_seguridad,
               COALESCE(SUM(lu.cantidad) FILTER (WHERE l.fecha_caducidad >= CURRENT_DATE), 0)::INT AS stock_vigente,
               COALESCE(SUM(lu.cantidad) FILTER (WHERE l.fecha_caducidad <  CURRENT_DATE), 0)::INT AS stock_caducado
          FROM insumo i
          LEFT JOIN lote l            ON l.id_insumo = i.id_insumo
          LEFT JOIN lote_ubicacion lu ON lu.id_lote  = l.id_lote
         WHERE i.activo
         GROUP BY i.id_insumo
       ) s;

-- Tabla "Insumos con requerimiento de reorden" del monitor
CREATE OR REPLACE VIEW v_insumos_reorden AS
SELECT s.id_insumo,
       s.codigo_insumo,
       s.descripcion_farmaco,
       (SELECT string_agg(DISTINCT a.nombre_area, ', ')
          FROM lote l
          JOIN lote_ubicacion lu     ON lu.id_lote = l.id_lote AND lu.cantidad > 0
          JOIN almacen_ubicacion a   ON a.id_ubicacion = lu.id_ubicacion
         WHERE l.id_insumo = s.id_insumo
           AND l.fecha_caducidad >= CURRENT_DATE)          AS ubicacion_actual,
       s.stock_vigente                                     AS stock,
       s.stock_minimo_seguridad                            AS minimo,
       CASE WHEN s.stock_vigente * 2 < s.stock_minimo_seguridad
            THEN 'ALERTA_COMPRAS' ELSE 'REORDEN_PENDIENTE' END AS estado
  FROM v_stock_insumo s
 WHERE s.bajo_minimo
 ORDER BY (s.stock_vigente::NUMERIC / NULLIF(s.stock_minimo_seguridad, 0)), s.codigo_insumo;

-- Lotes con existencias que caducan en <= 90 días o ya caducados
CREATE OR REPLACE VIEW v_lotes_por_caducar AS
SELECT id_lote, numero_lote, codigo_insumo, descripcion_farmaco,
       fecha_caducidad, dias_para_caducar, stock_total,
       CASE WHEN dias_para_caducar < 0   THEN 'CADUCADO'
            WHEN dias_para_caducar <= 30 THEN 'CADUCIDAD_30'
            WHEN dias_para_caducar <= 60 THEN 'CADUCIDAD_60'
            ELSE 'CADUCIDAD_90' END AS nivel
  FROM v_stock_lote
 WHERE stock_total > 0
   AND dias_para_caducar <= 90
 ORDER BY fecha_caducidad;

-- KPIs de las tarjetas del monitor (una sola fila)
-- disponibilidad_pct = % de insumos activos con stock vigente > 0
CREATE OR REPLACE VIEW v_kpi_monitor AS
SELECT (SELECT COUNT(*) FROM insumo WHERE activo)::INT                          AS total_insumos,
       (SELECT COUNT(*) FROM v_stock_insumo WHERE bajo_minimo)::INT             AS insumos_bajo_minimo,
       (SELECT COUNT(*) FROM v_lotes_por_caducar
         WHERE dias_para_caducar BETWEEN 0 AND 30)::INT                         AS lotes_caducan_30d,
       (SELECT COUNT(*) FROM v_lotes_por_caducar
         WHERE dias_para_caducar < 0)::INT                                      AS lotes_caducados,
       ROUND(100.0 * (SELECT COUNT(*) FROM v_stock_insumo WHERE stock_vigente > 0)
             / NULLIF((SELECT COUNT(*) FROM insumo WHERE activo), 0), 1)        AS disponibilidad_pct;

-- Trazabilidad por número de lote: dónde está (inventario) y a quién se
-- entregó (paciente). Uso:
--   SELECT * FROM v_trazabilidad_lote WHERE numero_lote = 'LOT-2024-0081';
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
       m.nombre::TEXT,
       m.cedula_profesional::TEXT,
       pa.nombre::TEXT,
       pa.expediente_folio::TEXT,
       d.fecha_hora_dispensacion
  FROM dispensacion d
  JOIN lote l               ON l.id_lote = d.id_lote
  JOIN insumo i             ON i.id_insumo = l.id_insumo
  JOIN proveedor p          ON p.id_proveedor = l.id_proveedor
  LEFT JOIN almacen_ubicacion a ON a.id_ubicacion = d.id_ubicacion_destino
  LEFT JOIN medico m        ON m.id_medico = d.id_medico
  LEFT JOIN paciente pa     ON pa.id_paciente = d.id_paciente;

-- Alertas abiertas
CREATE OR REPLACE VIEW v_alertas_pendientes AS
SELECT a.id_alerta, a.tipo, i.codigo_insumo, i.descripcion_farmaco,
       l.numero_lote, a.mensaje, a.fecha_generada
  FROM alerta a
  JOIN insumo i     ON i.id_insumo = a.id_insumo
  LEFT JOIN lote l  ON l.id_lote = a.id_lote
 WHERE NOT a.atendida
 ORDER BY a.fecha_generada DESC;

-- Bitácora legible (pantalla "Bitácora de auditoría")
CREATE OR REPLACE VIEW v_bitacora AS
SELECT b.id_auditoria,
       b.timestamp_iso,
       b.id_usuario,
       COALESCE('USR-' || u.id_usuario, 'SISTEMA') AS usuario,
       COALESCE(r.nombre_rol, 'Sistema')           AS rol,
       b.accion_sql,
       b.tabla_afectada,
       b.descripcion_objeto,
       b.terminal_origen_ip
  FROM bitacora_auditoria b
  LEFT JOIN usuario u ON u.id_usuario = b.id_usuario
  LEFT JOIN rol r     ON r.id_rol = u.id_rol
 ORDER BY b.timestamp_iso DESC, b.id_auditoria DESC;
