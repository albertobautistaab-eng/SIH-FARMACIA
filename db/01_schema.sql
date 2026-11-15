-- =====================================================================
-- 01_schema.sql :: Tablas, llaves y restricciones
-- Cambios respecto al modelo del PDF (ver notas al final del archivo):
--   * LOTE ya no guarda stock; el stock vive en LOTE_UBICACION
--   * Nueva tabla ENTRADA_INVENTARIO (registro de entradas)
--   * Nueva tabla ALERTA (caducidad y stock mínimo)
--   * DISPENSACION sin id_insumo redundante; una fila por lote consumido
-- =====================================================================

-- ---------- Catálogos de seguridad (RBAC) ----------
CREATE TABLE rol (
    id_rol      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre_rol  VARCHAR(50) NOT NULL UNIQUE,
    descripcion TEXT
);

CREATE TABLE usuario (
    id_usuario    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_rol        INT NOT NULL REFERENCES rol(id_rol),
    nombre        VARCHAR(100) NOT NULL,
    correo        VARCHAR(100) NOT NULL UNIQUE,
    hash_password VARCHAR(255) NOT NULL,
    activo        BOOLEAN NOT NULL DEFAULT TRUE
);

-- ---------- Catálogos operativos ----------
CREATE TABLE proveedor (
    id_proveedor      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rfc               VARCHAR(13) NOT NULL UNIQUE,
    razon_social      VARCHAR(150) NOT NULL,
    contacto_telefono VARCHAR(20),
    contacto_email    VARCHAR(100)
);

CREATE TABLE insumo (
    id_insumo             INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    codigo_insumo         VARCHAR(20) NOT NULL UNIQUE,
    descripcion_farmaco   VARCHAR(200) NOT NULL,
    es_controlado         BOOLEAN NOT NULL DEFAULT FALSE,
    stock_minimo_seguridad INT NOT NULL CHECK (stock_minimo_seguridad >= 0),
    unidad_medida         VARCHAR(30),
    activo                BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE almacen_ubicacion (
    id_ubicacion    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre_area     VARCHAR(100) NOT NULL,
    anaquel_seccion VARCHAR(50),
    UNIQUE (nombre_area, anaquel_seccion)
);

CREATE TABLE medico (
    id_medico          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    cedula_profesional VARCHAR(20) NOT NULL UNIQUE,
    nombre             VARCHAR(100) NOT NULL,
    especialidad       VARCHAR(100)
);

CREATE TABLE paciente (
    id_paciente      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    expediente_folio VARCHAR(30) NOT NULL UNIQUE,
    nombre           VARCHAR(100) NOT NULL,
    area_ingreso     VARCHAR(100)
);

-- ---------- Lotes y existencias ----------
CREATE TABLE lote (
    id_lote           INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_insumo         INT NOT NULL REFERENCES insumo(id_insumo),
    id_proveedor      INT NOT NULL REFERENCES proveedor(id_proveedor),
    numero_lote       VARCHAR(50) NOT NULL,
    fecha_fabricacion DATE,
    fecha_caducidad   DATE NOT NULL,
    precio_unitario   NUMERIC(10,2) CHECK (precio_unitario >= 0),
    UNIQUE (id_insumo, numero_lote),
    CHECK (fecha_fabricacion IS NULL OR fecha_fabricacion < fecha_caducidad)
);

-- Existencia de cada lote en cada ubicación física
CREATE TABLE lote_ubicacion (
    id_lote      INT NOT NULL REFERENCES lote(id_lote),
    id_ubicacion INT NOT NULL REFERENCES almacen_ubicacion(id_ubicacion),
    cantidad     INT NOT NULL DEFAULT 0 CHECK (cantidad >= 0),
    PRIMARY KEY (id_lote, id_ubicacion)
);

-- ---------- Movimientos ----------
CREATE TABLE entrada_inventario (
    id_entrada     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_lote        INT NOT NULL REFERENCES lote(id_lote),
    id_ubicacion   INT NOT NULL REFERENCES almacen_ubicacion(id_ubicacion),
    id_usuario     INT NOT NULL REFERENCES usuario(id_usuario),
    cantidad       INT NOT NULL CHECK (cantidad > 0),
    fecha_hora     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Una fila por cada lote del que se descontó (una salida puede abarcar
-- varios lotes). Las filas de una misma salida comparten folio_operacion.
CREATE TABLE dispensacion (
    id_dispensacion        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    folio_operacion        UUID NOT NULL,
    id_lote                INT NOT NULL REFERENCES lote(id_lote),
    id_ubicacion_origen    INT NOT NULL REFERENCES almacen_ubicacion(id_ubicacion),
    id_ubicacion_destino   INT REFERENCES almacen_ubicacion(id_ubicacion),
    id_medico              INT REFERENCES medico(id_medico),
    id_paciente            INT REFERENCES paciente(id_paciente),
    id_usuario             INT NOT NULL REFERENCES usuario(id_usuario),
    cantidad_dispensada    INT NOT NULL CHECK (cantidad_dispensada > 0),
    fecha_hora_dispensacion TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- Alertas ----------
CREATE TABLE alerta (
    id_alerta       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo            VARCHAR(20) NOT NULL
                    CHECK (tipo IN ('STOCK_MINIMO','CADUCIDAD_90','CADUCIDAD_60',
                                    'CADUCIDAD_30','CADUCADO')),
    id_insumo       INT NOT NULL REFERENCES insumo(id_insumo),
    id_lote         INT REFERENCES lote(id_lote),
    mensaje         TEXT NOT NULL,
    fecha_generada  TIMESTAMPTZ NOT NULL DEFAULT now(),
    atendida        BOOLEAN NOT NULL DEFAULT FALSE,
    fecha_atencion  TIMESTAMPTZ
);

-- ---------- Bitácora (se llena solo por triggers) ----------
CREATE TABLE bitacora_auditoria (
    id_auditoria       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_usuario         INT REFERENCES usuario(id_usuario),  -- NULL = proceso del sistema
    accion_sql         VARCHAR(10) NOT NULL CHECK (accion_sql IN ('INSERT','UPDATE','DELETE')),
    tabla_afectada     VARCHAR(50) NOT NULL,
    descripcion_objeto TEXT,
    datos_anteriores   JSONB,
    datos_nuevos       JSONB,
    timestamp_iso      TIMESTAMPTZ NOT NULL DEFAULT now(),
    terminal_origen_ip VARCHAR(45) NOT NULL
);

-- =====================================================================
-- Notas de diseño
--  * Stock total de un lote = SUM(lote_ubicacion.cantidad). Así se puede
--    saber cuánto hay en bóveda, quirófano, etc. (trazabilidad "en
--    inventario o paciente").
--  * El insumo de una dispensación se obtiene vía lote -> insumo, por eso
--    se eliminó id_insumo de DISPENSACION (evita inconsistencias).
--  * medico y paciente son opcionales en DISPENSACION (salida a un área),
--    pero sp_dispensar_peps los exige para sustancias controladas.
-- =====================================================================
