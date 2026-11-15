-- =====================================================================
-- 02_indexes.sql :: Índices para tablas de alta transaccionalidad
-- (Las PK y UNIQUE ya crean su propio índice.)
-- =====================================================================

-- Regla PEPS: lotes de un insumo ordenados por caducidad
CREATE INDEX idx_lote_insumo_caducidad ON lote (id_insumo, fecha_caducidad);
CREATE INDEX idx_lote_caducidad        ON lote (fecha_caducidad);
CREATE INDEX idx_lote_numero           ON lote (numero_lote);

-- Existencias por ubicación (solo filas con stock)
CREATE INDEX idx_lote_ubicacion_ubic   ON lote_ubicacion (id_ubicacion, id_lote)
    WHERE cantidad > 0;

-- Trazabilidad y reportes
CREATE INDEX idx_disp_lote      ON dispensacion (id_lote);
CREATE INDEX idx_disp_paciente  ON dispensacion (id_paciente);
CREATE INDEX idx_disp_medico    ON dispensacion (id_medico);
CREATE INDEX idx_disp_fecha     ON dispensacion (fecha_hora_dispensacion DESC);
CREATE INDEX idx_disp_folio     ON dispensacion (folio_operacion);
CREATE INDEX idx_entrada_lote   ON entrada_inventario (id_lote);
CREATE INDEX idx_entrada_fecha  ON entrada_inventario (fecha_hora DESC);

-- Auditoría
CREATE INDEX idx_bitacora_fecha   ON bitacora_auditoria (timestamp_iso DESC);
CREATE INDEX idx_bitacora_usuario ON bitacora_auditoria (id_usuario, timestamp_iso DESC);
CREATE INDEX idx_bitacora_tabla   ON bitacora_auditoria (tabla_afectada);

-- Alertas: una sola alerta abierta por (tipo, insumo, lote)
CREATE UNIQUE INDEX uq_alerta_abierta
    ON alerta (tipo, id_insumo, (COALESCE(id_lote, 0)))
    WHERE NOT atendida;
CREATE INDEX idx_alerta_pendientes ON alerta (fecha_generada DESC) WHERE NOT atendida;
