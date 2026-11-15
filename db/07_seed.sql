-- =====================================================================
-- 07_seed.sql :: Datos de prueba (basados en los wireframes)
-- Contraseña de TODOS los usuarios demo: Cambiar123!   (bcrypt vía pgcrypto)
-- Las fechas de caducidad son relativas a hoy para que la demo siempre
-- tenga lotes vigentes, próximos a caducar y alertas.
-- =====================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;

INSERT INTO rol (nombre_rol, descripcion) VALUES
 ('Jefe de Farmacia', 'Gestión completa de inventario, entradas, traslados y reportes'),
 ('Dispensador',      'Registra dispensaciones (salidas) bajo regla PEPS'),
 ('Administrador',    'Gestión de usuarios y consulta de bitácora de auditoría');

INSERT INTO usuario (id_rol, nombre, correo, hash_password)
SELECT r.id_rol, v.nombre, v.correo, crypt('Cambiar123!', gen_salt('bf'))
  FROM (VALUES
        ('Jefe de Farmacia', 'Laura Hernández', 'jefe.farmacia@hospital.mx'),
        ('Dispensador',      'Carlos Ruiz',     'dispensador@hospital.mx'),
        ('Administrador',    'Ana Torres',      'admin@hospital.mx')
       ) AS v(rol, nombre, correo)
  JOIN rol r ON r.nombre_rol = v.rol;

INSERT INTO almacen_ubicacion (nombre_area, anaquel_seccion) VALUES
 ('Almacén Central',  'Anaquel B-12'),
 ('Quirófano A3',     NULL),
 ('Bóveda Urgencias', NULL),
 ('Refrigerador 2',   NULL);

INSERT INTO proveedor (rfc, razon_social, contacto_telefono, contacto_email) VALUES
 ('PCO010101AB1', 'Pharma Corp', '33 1234 5678', 'ventas@pharmacorp.example');

INSERT INTO insumo (codigo_insumo, descripcion_farmaco, es_controlado, stock_minimo_seguridad, unidad_medida) VALUES
 ('INS-8840', 'Propofol 200mg / 20ml',        FALSE,  30, 'Ampolleta'),
 ('INS-1029', 'Fentanilo 0.5mg (Controlado)', TRUE,   15, 'Ampolleta'),
 ('INS-3321', 'Insulina Humana R 100UI/ml',   FALSE,  20, 'Frasco'),
 ('INS-5010', 'Paracetamol 500mg',            FALSE, 100, 'Caja');

INSERT INTO lote (id_insumo, id_proveedor, numero_lote, fecha_fabricacion, fecha_caducidad, precio_unitario)
SELECT i.id_insumo, p.id_proveedor, v.numero_lote,
       CURRENT_DATE - 700, CURRENT_DATE + v.dias, v.precio
  FROM (VALUES
        ('INS-8840', '#LOT-2024-0081',   2, 85.50),   -- próximo a caducar
        ('INS-8840', '#LOT-2025-0192',  58, 85.50),
        ('INS-1029', '#LOT-2026-0044', 230, 120.00),
        ('INS-3321', '#LOT-2026-0310', 110, 210.00),
        ('INS-5010', '#LOT-2026-0555', 400, 35.00)
       ) AS v(codigo, numero_lote, dias, precio)
  JOIN insumo i    ON i.codigo_insumo = v.codigo
  JOIN proveedor p ON p.rfc = 'PCO010101AB1';

INSERT INTO medico (cedula_profesional, nombre, especialidad) VALUES
 ('8839201', 'Dr. C. Mendoza', 'Anestesiología');

INSERT INTO paciente (expediente_folio, nombre, area_ingreso) VALUES
 ('EXP-000123', 'J. Martínez P.', 'Urgencias');

-- Entradas (pasan por sp_registrar_entrada: quedan auditadas y generan alertas)
SELECT sp_registrar_entrada(
         (SELECT id_lote FROM lote WHERE numero_lote = v.lote),
         (SELECT id_ubicacion FROM almacen_ubicacion WHERE nombre_area = v.ubic),
         v.cant,
         (SELECT id_usuario FROM usuario WHERE correo = 'jefe.farmacia@hospital.mx'))
  FROM (VALUES
        ('#LOT-2024-0081', 'Almacén Central',   4),
        ('#LOT-2025-0192', 'Almacén Central',  10),
        ('#LOT-2026-0044', 'Bóveda Urgencias',  4),
        ('#LOT-2026-0310', 'Refrigerador 2',   12),
        ('#LOT-2026-0555', 'Almacén Central', 500)
       ) AS v(lote, ubic, cant);

-- Alertas iniciales de caducidad y stock mínimo
SELECT fn_generar_alertas();
