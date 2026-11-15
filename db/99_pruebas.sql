-- =====================================================================
-- 99_pruebas.sql :: Pruebas manuales (NO se instala automáticamente)
--   psql -d sih_farmacia -f 99_pruebas.sql
-- Todo corre dentro de una transacción que termina en ROLLBACK.
-- =====================================================================
\set ON_ERROR_STOP off
BEGIN;

\echo '--- 1) PEPS: salida de 6 Propofol; debe tomar 4 del lote 0081 y 2 del 0192'
SELECT sp_dispensar_peps(
    (SELECT id_insumo    FROM insumo            WHERE codigo_insumo = 'INS-8840'),
    6,
    (SELECT id_ubicacion FROM almacen_ubicacion WHERE nombre_area = 'Almacén Central'),
    (SELECT id_ubicacion FROM almacen_ubicacion WHERE nombre_area = 'Quirófano A3'),
    (SELECT id_medico    FROM medico            WHERE cedula_profesional = '8839201'),
    (SELECT id_paciente  FROM paciente          WHERE expediente_folio = 'EXP-000123'),
    (SELECT id_usuario   FROM usuario           WHERE correo = 'dispensador@hospital.mx'));

SELECT l.numero_lote, d.cantidad_dispensada
  FROM dispensacion d JOIN lote l USING (id_lote)
 ORDER BY l.fecha_caducidad;

\echo '--- 2) Trazabilidad del lote 0081'
SELECT situacion, ubicacion, cantidad, medico, paciente
  FROM v_trazabilidad_lote WHERE numero_lote = '#LOT-2024-0081';

\echo '--- 3) Debe FALLAR: stock insuficiente'
SAVEPOINT s1;
SELECT sp_dispensar_peps(
    (SELECT id_insumo FROM insumo WHERE codigo_insumo = 'INS-8840'), 9999,
    (SELECT id_ubicacion FROM almacen_ubicacion WHERE nombre_area = 'Almacén Central'),
    NULL, NULL, NULL,
    (SELECT id_usuario FROM usuario WHERE correo = 'dispensador@hospital.mx'));
ROLLBACK TO s1;

\echo '--- 4) Debe FALLAR: sustancia controlada sin médico/paciente'
SAVEPOINT s2;
SELECT sp_dispensar_peps(
    (SELECT id_insumo FROM insumo WHERE codigo_insumo = 'INS-1029'), 1,
    (SELECT id_ubicacion FROM almacen_ubicacion WHERE nombre_area = 'Bóveda Urgencias'),
    NULL, NULL, NULL,
    (SELECT id_usuario FROM usuario WHERE correo = 'dispensador@hospital.mx'));
ROLLBACK TO s2;

\echo '--- 5) Debe FALLAR: bitácora inmutable'
SAVEPOINT s3;
DELETE FROM bitacora_auditoria;
ROLLBACK TO s3;
SAVEPOINT s4;
UPDATE bitacora_auditoria SET accion_sql = 'INSERT';
ROLLBACK TO s4;

\echo '--- 6) Monitor'
SELECT * FROM v_kpi_monitor;
SELECT * FROM v_insumos_reorden;
SELECT * FROM v_alertas_pendientes;

\echo '--- 7) Últimos movimientos auditados'
SELECT timestamp_iso, usuario, rol, accion_sql, tabla_afectada FROM v_bitacora LIMIT 8;

ROLLBACK;
