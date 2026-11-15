-- =====================================================================
-- 08_extras.sql :: Soporte para el backend Python
-- Detalle de una dispensación (lotes usados por PEPS) sin dar acceso
-- directo a las tablas lote/dispensacion al rol Dispensador.
-- Si ya instalaste 01-07, ejecuta SOLO este archivo.
-- =====================================================================
CREATE OR REPLACE FUNCTION fn_detalle_dispensacion(p_folio UUID)
RETURNS TABLE (numero_lote TEXT, fecha_caducidad DATE, cantidad INT, ubicacion_origen TEXT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
    SELECT l.numero_lote::TEXT, l.fecha_caducidad, d.cantidad_dispensada, a.nombre_area::TEXT
      FROM dispensacion d
      JOIN lote l              ON l.id_lote = d.id_lote
      JOIN almacen_ubicacion a ON a.id_ubicacion = d.id_ubicacion_origen
     WHERE d.folio_operacion = p_folio
     ORDER BY l.fecha_caducidad, l.id_lote;
$$;

REVOKE ALL ON FUNCTION fn_detalle_dispensacion(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION fn_detalle_dispensacion(UUID)
      TO rol_dispensador, rol_jefe_farmacia;
