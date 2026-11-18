--
-- PostgreSQL database dump
--

\restrict joWC0b4gw6OA78mirunNzb7f0HOz4dotDmMhOuSgDotZqT6uIr1DeSc6obBOta3

-- Dumped from database version 18.7
-- Dumped by pg_dump version 18.7

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: fn_auditar(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_auditar() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
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


ALTER FUNCTION public.fn_auditar() OWNER TO postgres;

--
-- Name: fn_bitacora_inmutable(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_bitacora_inmutable() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    RAISE EXCEPTION 'La bitácora de auditoría es inmutable (% no permitido)', TG_OP;
END;
$$;


ALTER FUNCTION public.fn_bitacora_inmutable() OWNER TO postgres;

--
-- Name: fn_detalle_dispensacion(uuid); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_detalle_dispensacion(p_folio uuid) RETURNS TABLE(numero_lote text, fecha_caducidad date, cantidad integer, ubicacion_origen text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
    SELECT l.numero_lote::TEXT, l.fecha_caducidad, d.cantidad_dispensada, a.nombre_area::TEXT
      FROM dispensacion d
      JOIN lote l              ON l.id_lote = d.id_lote
      JOIN almacen_ubicacion a ON a.id_ubicacion = d.id_ubicacion_origen
     WHERE d.folio_operacion = p_folio
     ORDER BY l.fecha_caducidad, l.id_lote;
$$;


ALTER FUNCTION public.fn_detalle_dispensacion(p_folio uuid) OWNER TO postgres;

--
-- Name: fn_enmascarar_datos(text, jsonb); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_enmascarar_datos(p_tabla text, p_datos jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE
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


ALTER FUNCTION public.fn_enmascarar_datos(p_tabla text, p_datos jsonb) OWNER TO postgres;

--
-- Name: fn_generar_alertas(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_generar_alertas() RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    r        RECORD;
    v_dias   INT;
    v_tipo   TEXT;
    v_filas  INT;
    v_nuevas INT := 0;
BEGIN
    -- 1) Cerrar alertas de caducidad de lotes que ya no tienen existencias
    UPDATE alerta a
       SET atendida = TRUE, fecha_atencion = now()
     WHERE a.tipo LIKE 'CADUC%'
       AND NOT a.atendida
       AND NOT EXISTS (SELECT 1 FROM lote_ubicacion lu
                        WHERE lu.id_lote = a.id_lote AND lu.cantidad > 0);

    -- 2) Lotes con existencias que caducan en <= 90 días (o ya caducados)
    FOR r IN
        SELECT l.id_lote, l.id_insumo, l.numero_lote, l.fecha_caducidad,
               i.descripcion_farmaco, SUM(lu.cantidad) AS stock
          FROM lote l
          JOIN insumo i ON i.id_insumo = l.id_insumo
          JOIN lote_ubicacion lu ON lu.id_lote = l.id_lote
         WHERE l.fecha_caducidad <= CURRENT_DATE + 90
         GROUP BY l.id_lote, i.id_insumo
        HAVING SUM(lu.cantidad) > 0
    LOOP
        v_dias := r.fecha_caducidad - CURRENT_DATE;
        v_tipo := CASE
                    WHEN v_dias < 0   THEN 'CADUCADO'
                    WHEN v_dias <= 30 THEN 'CADUCIDAD_30'
                    WHEN v_dias <= 60 THEN 'CADUCIDAD_60'
                    ELSE                   'CADUCIDAD_90'
                  END;

        -- Cerrar el nivel anterior del mismo lote (p. ej. 90 -> 60)
        UPDATE alerta
           SET atendida = TRUE, fecha_atencion = now()
         WHERE id_lote = r.id_lote
           AND tipo LIKE 'CADUC%'
           AND tipo <> v_tipo
           AND NOT atendida;

        INSERT INTO alerta (tipo, id_insumo, id_lote, mensaje)
        VALUES (v_tipo, r.id_insumo, r.id_lote,
                format('%s, lote %s: %s unidades, caducidad %s (%s días).',
                       r.descripcion_farmaco, r.numero_lote, r.stock,
                       r.fecha_caducidad, v_dias))
        ON CONFLICT DO NOTHING;
        GET DIAGNOSTICS v_filas = ROW_COUNT;
        v_nuevas := v_nuevas + v_filas;
    END LOOP;

    -- 3) Stock mínimo de todos los insumos activos
    FOR r IN SELECT id_insumo FROM insumo WHERE activo LOOP
        PERFORM fn_verificar_stock_insumo(r.id_insumo);
    END LOOP;

    RETURN v_nuevas;
END;
$$;


ALTER FUNCTION public.fn_generar_alertas() OWNER TO postgres;

--
-- Name: fn_set_contexto(integer, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_set_contexto(p_id_usuario integer, p_ip text DEFAULT NULL::text) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM set_config('app.user_id',   COALESCE(p_id_usuario::TEXT, ''), true);
    PERFORM set_config('app.client_ip', COALESCE(p_ip, ''), true);
END;
$$;


ALTER FUNCTION public.fn_set_contexto(p_id_usuario integer, p_ip text) OWNER TO postgres;

--
-- Name: fn_usuario_actual(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_usuario_actual() RETURNS integer
    LANGUAGE sql STABLE
    AS $$
    SELECT NULLIF(current_setting('app.user_id', true), '')::INT;
$$;


ALTER FUNCTION public.fn_usuario_actual() OWNER TO postgres;

--
-- Name: fn_verificar_stock_insumo(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_verificar_stock_insumo(p_id_insumo integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_min   INT;
    v_desc  TEXT;
    v_stock INT;
BEGIN
    SELECT i.stock_minimo_seguridad, i.descripcion_farmaco
      INTO v_min, v_desc
      FROM insumo i
     WHERE i.id_insumo = p_id_insumo;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    SELECT COALESCE(SUM(lu.cantidad), 0)
      INTO v_stock
      FROM lote l
      JOIN lote_ubicacion lu ON lu.id_lote = l.id_lote
     WHERE l.id_insumo = p_id_insumo
       AND l.fecha_caducidad >= CURRENT_DATE;

    IF v_stock < v_min THEN
        INSERT INTO alerta (tipo, id_insumo, mensaje)
        VALUES ('STOCK_MINIMO', p_id_insumo,
                format('%s: stock %s por debajo del mínimo %s. Notificar a Compras.',
                       v_desc, v_stock, v_min))
        ON CONFLICT DO NOTHING;   -- ya existe una alerta abierta
    ELSE
        UPDATE alerta
           SET atendida = TRUE, fecha_atencion = now()
         WHERE id_insumo = p_id_insumo
           AND tipo = 'STOCK_MINIMO'
           AND NOT atendida;
    END IF;
END;
$$;


ALTER FUNCTION public.fn_verificar_stock_insumo(p_id_insumo integer) OWNER TO postgres;

--
-- Name: sp_dispensar_peps(integer, integer, integer, integer, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sp_dispensar_peps(p_id_insumo integer, p_cantidad integer, p_id_ubicacion_origen integer, p_id_ubicacion_destino integer, p_id_medico integer, p_id_paciente integer, p_id_usuario integer) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_controlado BOOLEAN;
    v_activo     BOOLEAN;
    v_folio      UUID := gen_random_uuid();
    v_restante   INT  := p_cantidad;
    v_tomar      INT;
    r            RECORD;
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad debe ser mayor a cero';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE id_usuario = p_id_usuario AND activo) THEN
        RAISE EXCEPTION 'Usuario % inexistente o inactivo', p_id_usuario;
    END IF;

    SELECT es_controlado, activo INTO v_controlado, v_activo
      FROM insumo WHERE id_insumo = p_id_insumo;
    IF NOT FOUND OR NOT v_activo THEN
        RAISE EXCEPTION 'Insumo % inexistente o inactivo', p_id_insumo;
    END IF;

    IF v_controlado AND (p_id_medico IS NULL OR p_id_paciente IS NULL) THEN
        RAISE EXCEPTION 'Sustancia controlada: se requiere médico prescriptor y paciente';
    END IF;
    IF p_id_medico IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM medico WHERE id_medico = p_id_medico) THEN
        RAISE EXCEPTION 'Médico % no existe', p_id_medico;
    END IF;
    IF p_id_paciente IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM paciente WHERE id_paciente = p_id_paciente) THEN
        RAISE EXCEPTION 'Paciente % no existe', p_id_paciente;
    END IF;

    PERFORM set_config('app.user_id', p_id_usuario::TEXT, true);

    FOR r IN
        SELECT lu.id_lote, lu.cantidad
          FROM lote_ubicacion lu
          JOIN lote l ON l.id_lote = lu.id_lote
         WHERE l.id_insumo = p_id_insumo
           AND lu.id_ubicacion = p_id_ubicacion_origen
           AND lu.cantidad > 0
           AND l.fecha_caducidad >= CURRENT_DATE
         ORDER BY l.fecha_caducidad ASC, l.id_lote ASC      -- << PEPS
           FOR UPDATE OF lu
    LOOP
        v_tomar := LEAST(r.cantidad, v_restante);

        UPDATE lote_ubicacion
           SET cantidad = cantidad - v_tomar
         WHERE id_lote = r.id_lote AND id_ubicacion = p_id_ubicacion_origen;

        INSERT INTO dispensacion (folio_operacion, id_lote, id_ubicacion_origen,
                                  id_ubicacion_destino, id_medico, id_paciente,
                                  id_usuario, cantidad_dispensada)
        VALUES (v_folio, r.id_lote, p_id_ubicacion_origen, p_id_ubicacion_destino,
                p_id_medico, p_id_paciente, p_id_usuario, v_tomar);

        v_restante := v_restante - v_tomar;
        EXIT WHEN v_restante = 0;
    END LOOP;

    IF v_restante > 0 THEN
        RAISE EXCEPTION
            'Stock vigente insuficiente: faltan % de % solicitadas (los lotes caducados se excluyen)',
            v_restante, p_cantidad;
    END IF;

    PERFORM fn_verificar_stock_insumo(p_id_insumo);
    RETURN v_folio;
END;
$$;


ALTER FUNCTION public.sp_dispensar_peps(p_id_insumo integer, p_cantidad integer, p_id_ubicacion_origen integer, p_id_ubicacion_destino integer, p_id_medico integer, p_id_paciente integer, p_id_usuario integer) OWNER TO postgres;

--
-- Name: sp_registrar_entrada(integer, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sp_registrar_entrada(p_id_lote integer, p_id_ubicacion integer, p_cantidad integer, p_id_usuario integer) RETURNS bigint
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_insumo  INT;
    v_caduca  DATE;
    v_id      BIGINT;
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad debe ser mayor a cero';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE id_usuario = p_id_usuario AND activo) THEN
        RAISE EXCEPTION 'Usuario % inexistente o inactivo', p_id_usuario;
    END IF;

    SELECT id_insumo, fecha_caducidad INTO v_insumo, v_caduca
      FROM lote WHERE id_lote = p_id_lote;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Lote % no existe', p_id_lote;
    END IF;
    IF v_caduca < CURRENT_DATE THEN
        RAISE EXCEPTION 'No se puede dar entrada a un lote caducado (%).', v_caduca;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM almacen_ubicacion WHERE id_ubicacion = p_id_ubicacion) THEN
        RAISE EXCEPTION 'Ubicación % no existe', p_id_ubicacion;
    END IF;

    PERFORM set_config('app.user_id', p_id_usuario::TEXT, true);

    INSERT INTO entrada_inventario (id_lote, id_ubicacion, id_usuario, cantidad)
    VALUES (p_id_lote, p_id_ubicacion, p_id_usuario, p_cantidad)
    RETURNING id_entrada INTO v_id;

    INSERT INTO lote_ubicacion (id_lote, id_ubicacion, cantidad)
    VALUES (p_id_lote, p_id_ubicacion, p_cantidad)
    ON CONFLICT (id_lote, id_ubicacion)
    DO UPDATE SET cantidad = lote_ubicacion.cantidad + EXCLUDED.cantidad;

    PERFORM fn_verificar_stock_insumo(v_insumo);
    RETURN v_id;
END;
$$;


ALTER FUNCTION public.sp_registrar_entrada(p_id_lote integer, p_id_ubicacion integer, p_cantidad integer, p_id_usuario integer) OWNER TO postgres;

--
-- Name: sp_trasladar_peps(integer, integer, integer, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.sp_trasladar_peps(p_id_insumo integer, p_cantidad integer, p_id_ubicacion_origen integer, p_id_ubicacion_destino integer, p_id_usuario integer) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
    v_restante INT := p_cantidad;
    v_tomar    INT;
    r          RECORD;
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad debe ser mayor a cero';
    END IF;
    IF p_id_ubicacion_origen = p_id_ubicacion_destino THEN
        RAISE EXCEPTION 'Origen y destino no pueden ser la misma ubicación';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM usuario WHERE id_usuario = p_id_usuario AND activo) THEN
        RAISE EXCEPTION 'Usuario % inexistente o inactivo', p_id_usuario;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM almacen_ubicacion WHERE id_ubicacion = p_id_ubicacion_destino) THEN
        RAISE EXCEPTION 'Ubicación destino % no existe', p_id_ubicacion_destino;
    END IF;

    PERFORM set_config('app.user_id', p_id_usuario::TEXT, true);

    FOR r IN
        SELECT lu.id_lote, lu.cantidad
          FROM lote_ubicacion lu
          JOIN lote l ON l.id_lote = lu.id_lote
         WHERE l.id_insumo = p_id_insumo
           AND lu.id_ubicacion = p_id_ubicacion_origen
           AND lu.cantidad > 0
           AND l.fecha_caducidad >= CURRENT_DATE
         ORDER BY l.fecha_caducidad ASC, l.id_lote ASC
           FOR UPDATE OF lu
    LOOP
        v_tomar := LEAST(r.cantidad, v_restante);

        UPDATE lote_ubicacion
           SET cantidad = cantidad - v_tomar
         WHERE id_lote = r.id_lote AND id_ubicacion = p_id_ubicacion_origen;

        INSERT INTO lote_ubicacion (id_lote, id_ubicacion, cantidad)
        VALUES (r.id_lote, p_id_ubicacion_destino, v_tomar)
        ON CONFLICT (id_lote, id_ubicacion)
        DO UPDATE SET cantidad = lote_ubicacion.cantidad + EXCLUDED.cantidad;

        v_restante := v_restante - v_tomar;
        EXIT WHEN v_restante = 0;
    END LOOP;

    IF v_restante > 0 THEN
        RAISE EXCEPTION 'Stock vigente insuficiente en origen: faltan % de %',
                        v_restante, p_cantidad;
    END IF;
    -- El stock total no cambia en un traslado, no hace falta verificar alertas.
END;
$$;


ALTER FUNCTION public.sp_trasladar_peps(p_id_insumo integer, p_cantidad integer, p_id_ubicacion_origen integer, p_id_ubicacion_destino integer, p_id_usuario integer) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: alerta; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.alerta (
    id_alerta bigint NOT NULL,
    tipo character varying(20) NOT NULL,
    id_insumo integer NOT NULL,
    id_lote integer,
    mensaje text NOT NULL,
    fecha_generada timestamp with time zone DEFAULT now() NOT NULL,
    atendida boolean DEFAULT false NOT NULL,
    fecha_atencion timestamp with time zone,
    CONSTRAINT alerta_tipo_check CHECK (((tipo)::text = ANY ((ARRAY['STOCK_MINIMO'::character varying, 'CADUCIDAD_90'::character varying, 'CADUCIDAD_60'::character varying, 'CADUCIDAD_30'::character varying, 'CADUCADO'::character varying])::text[])))
);


ALTER TABLE public.alerta OWNER TO postgres;

--
-- Name: alerta_id_alerta_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.alerta ALTER COLUMN id_alerta ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.alerta_id_alerta_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: almacen_ubicacion; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.almacen_ubicacion (
    id_ubicacion integer NOT NULL,
    nombre_area character varying(100) NOT NULL,
    anaquel_seccion character varying(50)
);


ALTER TABLE public.almacen_ubicacion OWNER TO postgres;

--
-- Name: almacen_ubicacion_id_ubicacion_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.almacen_ubicacion ALTER COLUMN id_ubicacion ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.almacen_ubicacion_id_ubicacion_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: bitacora_auditoria; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.bitacora_auditoria (
    id_auditoria bigint NOT NULL,
    id_usuario integer,
    accion_sql character varying(10) NOT NULL,
    tabla_afectada character varying(50) NOT NULL,
    descripcion_objeto text,
    datos_anteriores jsonb,
    datos_nuevos jsonb,
    timestamp_iso timestamp with time zone DEFAULT now() NOT NULL,
    terminal_origen_ip character varying(45) NOT NULL,
    CONSTRAINT bitacora_auditoria_accion_sql_check CHECK (((accion_sql)::text = ANY ((ARRAY['INSERT'::character varying, 'UPDATE'::character varying, 'DELETE'::character varying])::text[])))
);


ALTER TABLE public.bitacora_auditoria OWNER TO postgres;

--
-- Name: bitacora_auditoria_id_auditoria_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.bitacora_auditoria ALTER COLUMN id_auditoria ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.bitacora_auditoria_id_auditoria_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: dispensacion; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.dispensacion (
    id_dispensacion bigint NOT NULL,
    folio_operacion uuid NOT NULL,
    id_lote integer NOT NULL,
    id_ubicacion_origen integer NOT NULL,
    id_ubicacion_destino integer,
    id_medico integer,
    id_paciente integer,
    id_usuario integer NOT NULL,
    cantidad_dispensada integer NOT NULL,
    fecha_hora_dispensacion timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT dispensacion_cantidad_dispensada_check CHECK ((cantidad_dispensada > 0))
);


ALTER TABLE public.dispensacion OWNER TO postgres;

--
-- Name: dispensacion_id_dispensacion_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.dispensacion ALTER COLUMN id_dispensacion ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.dispensacion_id_dispensacion_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: entrada_inventario; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.entrada_inventario (
    id_entrada bigint NOT NULL,
    id_lote integer NOT NULL,
    id_ubicacion integer NOT NULL,
    id_usuario integer NOT NULL,
    cantidad integer NOT NULL,
    fecha_hora timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT entrada_inventario_cantidad_check CHECK ((cantidad > 0))
);


ALTER TABLE public.entrada_inventario OWNER TO postgres;

--
-- Name: entrada_inventario_id_entrada_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.entrada_inventario ALTER COLUMN id_entrada ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.entrada_inventario_id_entrada_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: insumo; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.insumo (
    id_insumo integer NOT NULL,
    codigo_insumo character varying(20) NOT NULL,
    descripcion_farmaco character varying(200) NOT NULL,
    es_controlado boolean DEFAULT false NOT NULL,
    stock_minimo_seguridad integer NOT NULL,
    unidad_medida character varying(30),
    activo boolean DEFAULT true NOT NULL,
    CONSTRAINT insumo_stock_minimo_seguridad_check CHECK ((stock_minimo_seguridad >= 0))
);


ALTER TABLE public.insumo OWNER TO postgres;

--
-- Name: insumo_id_insumo_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.insumo ALTER COLUMN id_insumo ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.insumo_id_insumo_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lote; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.lote (
    id_lote integer NOT NULL,
    id_insumo integer NOT NULL,
    id_proveedor integer NOT NULL,
    numero_lote character varying(50) NOT NULL,
    fecha_fabricacion date,
    fecha_caducidad date NOT NULL,
    precio_unitario numeric(10,2),
    CONSTRAINT lote_check CHECK (((fecha_fabricacion IS NULL) OR (fecha_fabricacion < fecha_caducidad))),
    CONSTRAINT lote_precio_unitario_check CHECK ((precio_unitario >= (0)::numeric))
);


ALTER TABLE public.lote OWNER TO postgres;

--
-- Name: lote_id_lote_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.lote ALTER COLUMN id_lote ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.lote_id_lote_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: lote_ubicacion; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.lote_ubicacion (
    id_lote integer NOT NULL,
    id_ubicacion integer NOT NULL,
    cantidad integer DEFAULT 0 NOT NULL,
    CONSTRAINT lote_ubicacion_cantidad_check CHECK ((cantidad >= 0))
);


ALTER TABLE public.lote_ubicacion OWNER TO postgres;

--
-- Name: medico; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.medico (
    id_medico integer NOT NULL,
    cedula_profesional character varying(20) NOT NULL,
    nombre character varying(100) NOT NULL,
    especialidad character varying(100)
);


ALTER TABLE public.medico OWNER TO postgres;

--
-- Name: medico_id_medico_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.medico ALTER COLUMN id_medico ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.medico_id_medico_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: paciente; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.paciente (
    id_paciente integer NOT NULL,
    expediente_folio character varying(30) NOT NULL,
    nombre character varying(100) NOT NULL,
    area_ingreso character varying(100)
);


ALTER TABLE public.paciente OWNER TO postgres;

--
-- Name: paciente_id_paciente_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.paciente ALTER COLUMN id_paciente ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.paciente_id_paciente_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: proveedor; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.proveedor (
    id_proveedor integer NOT NULL,
    rfc character varying(13) NOT NULL,
    razon_social character varying(150) NOT NULL,
    contacto_telefono character varying(20),
    contacto_email character varying(100)
);


ALTER TABLE public.proveedor OWNER TO postgres;

--
-- Name: proveedor_id_proveedor_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.proveedor ALTER COLUMN id_proveedor ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.proveedor_id_proveedor_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: rol; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.rol (
    id_rol integer NOT NULL,
    nombre_rol character varying(50) NOT NULL,
    descripcion text
);


ALTER TABLE public.rol OWNER TO postgres;

--
-- Name: rol_id_rol_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.rol ALTER COLUMN id_rol ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.rol_id_rol_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: usuario; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.usuario (
    id_usuario integer NOT NULL,
    id_rol integer NOT NULL,
    nombre character varying(100) NOT NULL,
    correo character varying(100) NOT NULL,
    hash_password character varying(255) NOT NULL,
    activo boolean DEFAULT true NOT NULL
);


ALTER TABLE public.usuario OWNER TO postgres;

--
-- Name: usuario_id_usuario_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

ALTER TABLE public.usuario ALTER COLUMN id_usuario ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME public.usuario_id_usuario_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: v_alertas_pendientes; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_alertas_pendientes AS
 SELECT a.id_alerta,
    a.tipo,
    i.codigo_insumo,
    i.descripcion_farmaco,
    l.numero_lote,
    a.mensaje,
    a.fecha_generada
   FROM ((public.alerta a
     JOIN public.insumo i ON ((i.id_insumo = a.id_insumo)))
     LEFT JOIN public.lote l ON ((l.id_lote = a.id_lote)))
  WHERE (NOT a.atendida)
  ORDER BY a.fecha_generada DESC;


ALTER VIEW public.v_alertas_pendientes OWNER TO postgres;

--
-- Name: v_bitacora; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_bitacora AS
 SELECT b.id_auditoria,
    b.timestamp_iso,
    b.id_usuario,
    COALESCE(('USR-'::text || u.id_usuario), 'SISTEMA'::text) AS usuario,
    COALESCE(r.nombre_rol, 'Sistema'::character varying) AS rol,
    b.accion_sql,
    b.tabla_afectada,
        CASE
            WHEN ((CURRENT_USER = 'rol_administrador'::name) AND ((b.tabla_afectada)::text = ANY ((ARRAY['paciente'::character varying, 'medico'::character varying])::text[]))) THEN (b.tabla_afectada)::text
            ELSE b.descripcion_objeto
        END AS descripcion_objeto,
    b.terminal_origen_ip,
    u.nombre AS nombre_usuario,
        CASE
            WHEN (CURRENT_USER = 'rol_administrador'::name) THEN public.fn_enmascarar_datos((b.tabla_afectada)::text, b.datos_anteriores)
            ELSE b.datos_anteriores
        END AS datos_anteriores,
        CASE
            WHEN (CURRENT_USER = 'rol_administrador'::name) THEN public.fn_enmascarar_datos((b.tabla_afectada)::text, b.datos_nuevos)
            ELSE b.datos_nuevos
        END AS datos_nuevos,
    ((EXISTS ( SELECT 1
           FROM (public.lote l
             JOIN public.insumo i ON ((i.id_insumo = l.id_insumo)))
          WHERE (i.es_controlado AND (l.id_lote = ((COALESCE(b.datos_nuevos, b.datos_anteriores) ->> 'id_lote'::text))::integer)))) OR (((b.tabla_afectada)::text = 'insumo'::text) AND COALESCE(((COALESCE(b.datos_nuevos, b.datos_anteriores) ->> 'es_controlado'::text))::boolean, false))) AS controlado
   FROM ((public.bitacora_auditoria b
     LEFT JOIN public.usuario u ON ((u.id_usuario = b.id_usuario)))
     LEFT JOIN public.rol r ON ((r.id_rol = u.id_rol)))
  ORDER BY b.timestamp_iso DESC, b.id_auditoria DESC;


ALTER VIEW public.v_bitacora OWNER TO postgres;

--
-- Name: v_stock_insumo; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_stock_insumo AS
SELECT
    NULL::integer AS id_insumo,
    NULL::character varying(20) AS codigo_insumo,
    NULL::character varying(200) AS descripcion_farmaco,
    NULL::boolean AS es_controlado,
    NULL::integer AS stock_minimo_seguridad,
    NULL::integer AS stock_vigente,
    NULL::integer AS stock_caducado,
    NULL::boolean AS bajo_minimo;


ALTER VIEW public.v_stock_insumo OWNER TO postgres;

--
-- Name: v_insumos_reorden; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_insumos_reorden AS
 SELECT id_insumo,
    codigo_insumo,
    descripcion_farmaco,
    ( SELECT string_agg(DISTINCT (a.nombre_area)::text, ', '::text) AS string_agg
           FROM ((public.lote l
             JOIN public.lote_ubicacion lu ON (((lu.id_lote = l.id_lote) AND (lu.cantidad > 0))))
             JOIN public.almacen_ubicacion a ON ((a.id_ubicacion = lu.id_ubicacion)))
          WHERE ((l.id_insumo = s.id_insumo) AND (l.fecha_caducidad >= CURRENT_DATE))) AS ubicacion_actual,
    stock_vigente AS stock,
    stock_minimo_seguridad AS minimo,
        CASE
            WHEN ((stock_vigente * 2) < stock_minimo_seguridad) THEN 'ALERTA_COMPRAS'::text
            ELSE 'REORDEN_PENDIENTE'::text
        END AS estado
   FROM public.v_stock_insumo s
  WHERE bajo_minimo
  ORDER BY ((stock_vigente)::numeric / (NULLIF(stock_minimo_seguridad, 0))::numeric), codigo_insumo;


ALTER VIEW public.v_insumos_reorden OWNER TO postgres;

--
-- Name: v_stock_lote; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_stock_lote AS
SELECT
    NULL::integer AS id_lote,
    NULL::character varying(50) AS numero_lote,
    NULL::integer AS id_insumo,
    NULL::character varying(20) AS codigo_insumo,
    NULL::character varying(200) AS descripcion_farmaco,
    NULL::integer AS id_proveedor,
    NULL::date AS fecha_caducidad,
    NULL::integer AS dias_para_caducar,
    NULL::integer AS stock_total;


ALTER VIEW public.v_stock_lote OWNER TO postgres;

--
-- Name: v_lotes_por_caducar; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_lotes_por_caducar AS
 SELECT id_lote,
    numero_lote,
    codigo_insumo,
    descripcion_farmaco,
    fecha_caducidad,
    dias_para_caducar,
    stock_total,
        CASE
            WHEN (dias_para_caducar < 0) THEN 'CADUCADO'::text
            WHEN (dias_para_caducar <= 30) THEN 'CADUCIDAD_30'::text
            WHEN (dias_para_caducar <= 60) THEN 'CADUCIDAD_60'::text
            ELSE 'CADUCIDAD_90'::text
        END AS nivel
   FROM public.v_stock_lote
  WHERE ((stock_total > 0) AND (dias_para_caducar <= 90))
  ORDER BY fecha_caducidad;


ALTER VIEW public.v_lotes_por_caducar OWNER TO postgres;

--
-- Name: v_kpi_monitor; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_kpi_monitor AS
 SELECT (( SELECT count(*) AS count
           FROM public.insumo
          WHERE insumo.activo))::integer AS total_insumos,
    (( SELECT count(*) AS count
           FROM public.v_stock_insumo
          WHERE v_stock_insumo.bajo_minimo))::integer AS insumos_bajo_minimo,
    (( SELECT count(*) AS count
           FROM public.v_lotes_por_caducar
          WHERE ((v_lotes_por_caducar.dias_para_caducar >= 0) AND (v_lotes_por_caducar.dias_para_caducar <= 30))))::integer AS lotes_caducan_30d,
    (( SELECT count(*) AS count
           FROM public.v_lotes_por_caducar
          WHERE (v_lotes_por_caducar.dias_para_caducar < 0)))::integer AS lotes_caducados,
    round(((100.0 * (( SELECT count(*) AS count
           FROM public.v_stock_insumo
          WHERE (v_stock_insumo.stock_vigente > 0)))::numeric) / (NULLIF(( SELECT count(*) AS count
           FROM public.insumo
          WHERE insumo.activo), 0))::numeric), 1) AS disponibilidad_pct;


ALTER VIEW public.v_kpi_monitor OWNER TO postgres;

--
-- Name: v_trazabilidad_lote; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.v_trazabilidad_lote AS
 SELECT l.numero_lote,
    i.codigo_insumo,
    i.descripcion_farmaco,
    p.razon_social AS proveedor,
    p.rfc AS proveedor_rfc,
    l.fecha_caducidad,
    'EN_INVENTARIO'::text AS situacion,
    (a.nombre_area)::text AS ubicacion,
    (a.anaquel_seccion)::text AS anaquel,
    lu.cantidad,
    NULL::text AS medico,
    NULL::text AS cedula_profesional,
    NULL::text AS paciente,
    NULL::text AS expediente_folio,
    NULL::timestamp with time zone AS fecha_evento
   FROM ((((public.lote l
     JOIN public.insumo i ON ((i.id_insumo = l.id_insumo)))
     JOIN public.proveedor p ON ((p.id_proveedor = l.id_proveedor)))
     JOIN public.lote_ubicacion lu ON (((lu.id_lote = l.id_lote) AND (lu.cantidad > 0))))
     JOIN public.almacen_ubicacion a ON ((a.id_ubicacion = lu.id_ubicacion)))
UNION ALL
 SELECT l.numero_lote,
    i.codigo_insumo,
    i.descripcion_farmaco,
    p.razon_social AS proveedor,
    p.rfc AS proveedor_rfc,
    l.fecha_caducidad,
    'DISPENSADO'::text AS situacion,
    (a.nombre_area)::text AS ubicacion,
    (a.anaquel_seccion)::text AS anaquel,
    d.cantidad_dispensada AS cantidad,
        CASE
            WHEN ((CURRENT_USER = 'rol_administrador'::name) AND (d.id_medico IS NOT NULL)) THEN 'Restringido'::text
            ELSE (m.nombre)::text
        END AS medico,
        CASE
            WHEN ((CURRENT_USER = 'rol_administrador'::name) AND (d.id_medico IS NOT NULL)) THEN 'Restringido'::text
            ELSE (m.cedula_profesional)::text
        END AS cedula_profesional,
        CASE
            WHEN ((CURRENT_USER = 'rol_administrador'::name) AND (d.id_paciente IS NOT NULL)) THEN 'Restringido'::text
            ELSE (pa.nombre)::text
        END AS paciente,
        CASE
            WHEN ((CURRENT_USER = 'rol_administrador'::name) AND (d.id_paciente IS NOT NULL)) THEN 'Restringido'::text
            ELSE (pa.expediente_folio)::text
        END AS expediente_folio,
    d.fecha_hora_dispensacion AS fecha_evento
   FROM ((((((public.dispensacion d
     JOIN public.lote l ON ((l.id_lote = d.id_lote)))
     JOIN public.insumo i ON ((i.id_insumo = l.id_insumo)))
     JOIN public.proveedor p ON ((p.id_proveedor = l.id_proveedor)))
     LEFT JOIN public.almacen_ubicacion a ON ((a.id_ubicacion = d.id_ubicacion_destino)))
     LEFT JOIN public.medico m ON ((m.id_medico = d.id_medico)))
     LEFT JOIN public.paciente pa ON ((pa.id_paciente = d.id_paciente)));


ALTER VIEW public.v_trazabilidad_lote OWNER TO postgres;

--
-- Data for Name: alerta; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.alerta (id_alerta, tipo, id_insumo, id_lote, mensaje, fecha_generada, atendida, fecha_atencion) FROM stdin;
5	CADUCIDAD_60	1	1	Propofol 200mg / 20ml, lote #LOT-2025-0192: 10 unidades, caducidad 2027-01-10 (58 días).	2026-11-13 19:52:18.7644-06	t	2026-11-13 23:14:01.883207-06
6	CADUCIDAD_30	1	2	Propofol 200mg / 20ml, lote #LOT-2024-0081: 4 unidades, caducidad 2026-11-15 (2 días).	2026-11-13 19:52:18.7644-06	t	2026-11-13 23:14:04.546863-06
1	STOCK_MINIMO	1	\N	Propofol 200mg / 20ml: stock 4 por debajo del mínimo 30. Notificar a Compras.	2026-11-13 19:52:18.710701-06	t	2026-11-13 23:14:18.512051-06
3	STOCK_MINIMO	2	\N	Fentanilo 0.5mg (Controlado): stock 4 por debajo del mínimo 15. Notificar a Compras.	2026-11-13 19:52:18.710701-06	t	2026-11-13 23:18:27.293809-06
12	CADUCIDAD_60	1	1	Propofol 200mg / 20ml, lote #LOT-2025-0192: 10 unidades, caducidad 2027-01-10 (58 días).	2026-11-13 23:18:40.677377-06	t	2026-11-14 17:47:55.105516-06
13	CADUCIDAD_30	1	2	Propofol 200mg / 20ml, lote #LOT-2024-0081: 4 unidades, caducidad 2026-11-15 (2 días).	2026-11-13 23:18:40.677377-06	t	2026-11-14 17:48:00.371937-06
14	STOCK_MINIMO	1	\N	Propofol 200mg / 20ml: stock 14 por debajo del mínimo 30. Notificar a Compras.	2026-11-13 23:18:40.677377-06	t	2026-11-14 17:48:02.756696-06
15	STOCK_MINIMO	2	\N	Fentanilo 0.5mg (Controlado): stock 4 por debajo del mínimo 15. Notificar a Compras.	2026-11-13 23:18:40.677377-06	t	2026-11-14 17:48:04.738608-06
4	STOCK_MINIMO	3	\N	Insulina Humana R 100UI/ml: stock 12 por debajo del mínimo 20. Notificar a Compras.	2026-11-13 19:52:18.710701-06	t	2026-11-14 17:48:07.50372-06
22	STOCK_MINIMO	6	\N	Midazolam 5mg/5ml: stock 14 por debajo del mínimo 20. Notificar a Compras.	2026-11-17 18:05:30.454005-06	t	2026-11-17 18:05:30.454005-06
23	STOCK_MINIMO	8	\N	Diazepam 10mg/2ml: stock 12 por debajo del mínimo 15. Notificar a Compras.	2026-11-17 18:05:30.454005-06	t	2026-11-17 18:05:30.454005-06
24	STOCK_MINIMO	12	\N	Lidocaína 2% 100mg/5ml: stock 8 por debajo del mínimo 50. Notificar a Compras.	2026-11-17 18:05:30.454005-06	t	2026-11-17 18:05:30.454005-06
25	STOCK_MINIMO	15	\N	Dexametasona 8mg/2ml: stock 40 por debajo del mínimo 50. Notificar a Compras.	2026-11-17 18:05:30.454005-06	t	2026-11-17 18:05:30.454005-06
26	STOCK_MINIMO	17	\N	Cefazolina 1g: stock 15 por debajo del mínimo 60. Notificar a Compras.	2026-11-17 18:05:30.454005-06	t	2026-11-17 18:05:30.454005-06
27	STOCK_MINIMO	18	\N	Vancomicina 1g: stock 30 por debajo del mínimo 40. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
28	STOCK_MINIMO	19	\N	Meropenem 1g: stock 20 por debajo del mínimo 30. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
29	STOCK_MINIMO	22	\N	Adrenalina 1mg/ml: stock 40 por debajo del mínimo 60. Notificar a Compras.	2026-11-17 18:05:30.454005-06	t	2026-11-17 18:05:30.454005-06
30	STOCK_MINIMO	25	\N	Noradrenalina 4mg/4ml: stock 20 por debajo del mínimo 25. Notificar a Compras.	2026-11-17 18:05:30.454005-06	t	2026-11-17 18:05:30.454005-06
31	STOCK_MINIMO	38	\N	Naloxona 0.4mg/ml: stock 8 por debajo del mínimo 10. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
34	STOCK_MINIMO	13	\N	Ketorolaco 30mg/ml: stock 92 por debajo del mínimo 100. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
35	STOCK_MINIMO	27	\N	Heparina sódica 5000UI/5ml: stock 45 por debajo del mínimo 50. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
38	STOCK_MINIMO	25	\N	Noradrenalina 4mg/4ml: stock 23 por debajo del mínimo 25. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
39	STOCK_MINIMO	32	\N	Insulina NPH 100UI/ml: stock 11 por debajo del mínimo 15. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
41	STOCK_MINIMO	6	\N	Midazolam 5mg/5ml: stock 19 por debajo del mínimo 20. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
44	STOCK_MINIMO	17	\N	Cefazolina 1g: stock 58 por debajo del mínimo 60. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
48	STOCK_MINIMO	22	\N	Adrenalina 1mg/ml: stock 52 por debajo del mínimo 60. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
55	STOCK_MINIMO	16	\N	Ceftriaxona 1g: stock 109 por debajo del mínimo 120. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
76	CADUCIDAD_60	1	1	Propofol 200mg / 20ml, lote #LOT-2025-0192: 10 unidades, caducidad 2027-01-10 (54 días).	2026-11-17 18:05:30.454005-06	f	\N
77	CADUCIDAD_90	4	50	Paracetamol 500mg, lote #LOT-2026-0612: 110 unidades, caducidad 2027-01-31 (75 días).	2026-11-17 18:05:30.454005-06	f	\N
78	CADUCIDAD_60	26	34	Furosemida 20mg/2ml, lote #LOT-2026-1122: 58 unidades, caducidad 2027-01-11 (55 días).	2026-11-17 18:05:30.454005-06	f	\N
79	CADUCIDAD_30	14	19	Ondansetrón 8mg/4ml, lote #LOT-2026-1110: 15 unidades, caducidad 2026-11-29 (12 días).	2026-11-17 18:05:30.454005-06	f	\N
80	CADUCIDAD_60	31	40	Solución glucosada 5% 500ml, lote #LOT-2026-1127: 120 unidades, caducidad 2027-01-04 (48 días).	2026-11-17 18:05:30.454005-06	f	\N
81	CADUCIDAD_60	13	17	Ketorolaco 30mg/ml, lote #LOT-2026-1109: 10 unidades, caducidad 2026-12-28 (41 días).	2026-11-17 18:05:30.454005-06	f	\N
82	CADUCIDAD_30	36	45	Oxitocina 10UI/ml, lote #LOT-2026-1132: 28 unidades, caducidad 2026-11-26 (9 días).	2026-11-17 18:05:30.454005-06	f	\N
83	CADUCIDAD_30	30	38	Solución Hartmann 1000ml, lote #LOT-2026-1126: 40 unidades, caducidad 2026-12-15 (28 días).	2026-11-17 18:05:30.454005-06	f	\N
84	CADUCIDAD_90	24	32	Amiodarona 150mg/3ml, lote #LOT-2026-1120: 35 unidades, caducidad 2027-01-28 (72 días).	2026-11-17 18:05:30.454005-06	f	\N
85	CADUCIDAD_90	34	43	Omeprazol 40mg IV, lote #LOT-2026-1130: 50 unidades, caducidad 2027-02-10 (85 días).	2026-11-17 18:05:30.454005-06	f	\N
86	CADUCADO	12	15	Lidocaína 2% 100mg/5ml, lote #LOT-2025-1008: 8 unidades, caducidad 2026-11-11 (-6 días).	2026-11-17 18:05:30.454005-06	f	\N
87	CADUCIDAD_30	15	21	Dexametasona 8mg/2ml, lote #LOT-2026-1111: 52 unidades, caducidad 2026-12-12 (25 días).	2026-11-17 18:05:30.454005-06	f	\N
88	CADUCADO	17	24	Cefazolina 1g, lote #LOT-2025-1013: 15 unidades, caducidad 2026-10-29 (-19 días).	2026-11-17 18:05:30.454005-06	f	\N
89	CADUCADO	1	2	Propofol 200mg / 20ml, lote #LOT-2024-0081: 4 unidades, caducidad 2026-11-15 (-2 días).	2026-11-17 18:05:30.454005-06	f	\N
90	STOCK_MINIMO	1	\N	Propofol 200mg / 20ml: stock 10 por debajo del mínimo 30. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
91	STOCK_MINIMO	2	\N	Fentanilo 0.5mg (Controlado): stock 4 por debajo del mínimo 15. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
92	STOCK_MINIMO	3	\N	Insulina Humana R 100UI/ml: stock 12 por debajo del mínimo 20. Notificar a Compras.	2026-11-17 18:05:30.454005-06	f	\N
\.


--
-- Data for Name: almacen_ubicacion; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.almacen_ubicacion (id_ubicacion, nombre_area, anaquel_seccion) FROM stdin;
1	Almacén Central	Anaquel B-12
2	Quirófano A3	\N
3	Bóveda Urgencias	\N
4	Refrigerador 2	\N
5	Bóveda Central	Cuarto de controlados
6	Refrigerador 1	Cadena fría
7	Terapia Intensiva (UCI)	Carro de medicamentos
8	Farmacia Satélite Urgencias	Anaquel S-01
9	Farmacia Satélite Hospitalización	Anaquel H-04
10	Pediatría	Gabinete P-02
11	Quirófano B1	\N
12	Tococirugía	Gabinete T-01
\.


--
-- Data for Name: bitacora_auditoria; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.bitacora_auditoria (id_auditoria, id_usuario, accion_sql, tabla_afectada, descripcion_objeto, datos_anteriores, datos_nuevos, timestamp_iso, terminal_origen_ip) FROM stdin;
1	\N	INSERT	rol	rol {"id_rol": 1, "nombre_rol": "Jefe de Farmacia", "descripcion": "Gestión completa de inventario, entradas, traslados y reportes"}	\N	{"id_rol": 1, "nombre_rol": "Jefe de Farmacia", "descripcion": "Gestión completa de inventario, entradas, traslados y reportes"}	2026-11-13 19:52:18.656318-06	::1
2	\N	INSERT	rol	rol {"id_rol": 2, "nombre_rol": "Dispensador", "descripcion": "Registra dispensaciones (salidas) bajo regla PEPS"}	\N	{"id_rol": 2, "nombre_rol": "Dispensador", "descripcion": "Registra dispensaciones (salidas) bajo regla PEPS"}	2026-11-13 19:52:18.656318-06	::1
3	\N	INSERT	rol	rol {"id_rol": 3, "nombre_rol": "Administrador", "descripcion": "Gestión de usuarios y consulta de bitácora de auditoría"}	\N	{"id_rol": 3, "nombre_rol": "Administrador", "descripcion": "Gestión de usuarios y consulta de bitácora de auditoría"}	2026-11-13 19:52:18.656318-06	::1
4	\N	INSERT	usuario	usuario {"activo": true, "correo": "jefe.farmacia@hospital.mx", "id_rol": 1, "nombre": "Laura Hernández", "id_usuario": 1}	\N	{"activo": true, "correo": "jefe.farmacia@hospital.mx", "id_rol": 1, "nombre": "Laura Hernández", "id_usuario": 1}	2026-11-13 19:52:18.66511-06	::1
5	\N	INSERT	usuario	usuario {"activo": true, "correo": "dispensador@hospital.mx", "id_rol": 2, "nombre": "Carlos Ruiz", "id_usuario": 2}	\N	{"activo": true, "correo": "dispensador@hospital.mx", "id_rol": 2, "nombre": "Carlos Ruiz", "id_usuario": 2}	2026-11-13 19:52:18.66511-06	::1
6	\N	INSERT	usuario	usuario {"activo": true, "correo": "admin@hospital.mx", "id_rol": 3, "nombre": "Ana Torres", "id_usuario": 3}	\N	{"activo": true, "correo": "admin@hospital.mx", "id_rol": 3, "nombre": "Ana Torres", "id_usuario": 3}	2026-11-13 19:52:18.66511-06	::1
7	\N	INSERT	almacen_ubicacion	almacen_ubicacion {"nombre_area": "Almacén Central", "id_ubicacion": 1, "anaquel_seccion": "Anaquel B-12"}	\N	{"nombre_area": "Almacén Central", "id_ubicacion": 1, "anaquel_seccion": "Anaquel B-12"}	2026-11-13 19:52:18.691013-06	::1
8	\N	INSERT	almacen_ubicacion	almacen_ubicacion {"nombre_area": "Quirófano A3", "id_ubicacion": 2, "anaquel_seccion": null}	\N	{"nombre_area": "Quirófano A3", "id_ubicacion": 2, "anaquel_seccion": null}	2026-11-13 19:52:18.691013-06	::1
9	\N	INSERT	almacen_ubicacion	almacen_ubicacion {"nombre_area": "Bóveda Urgencias", "id_ubicacion": 3, "anaquel_seccion": null}	\N	{"nombre_area": "Bóveda Urgencias", "id_ubicacion": 3, "anaquel_seccion": null}	2026-11-13 19:52:18.691013-06	::1
10	\N	INSERT	almacen_ubicacion	almacen_ubicacion {"nombre_area": "Refrigerador 2", "id_ubicacion": 4, "anaquel_seccion": null}	\N	{"nombre_area": "Refrigerador 2", "id_ubicacion": 4, "anaquel_seccion": null}	2026-11-13 19:52:18.691013-06	::1
11	\N	INSERT	proveedor	proveedor {"rfc": "PCO010101AB1", "id_proveedor": 1, "razon_social": "Pharma Corp", "contacto_email": "ventas@pharmacorp.example", "contacto_telefono": "33 1234 5678"}	\N	{"rfc": "PCO010101AB1", "id_proveedor": 1, "razon_social": "Pharma Corp", "contacto_email": "ventas@pharmacorp.example", "contacto_telefono": "33 1234 5678"}	2026-11-13 19:52:18.695457-06	::1
12	\N	INSERT	insumo	insumo {"activo": true, "id_insumo": 1, "codigo_insumo": "INS-8840", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Propofol 200mg / 20ml", "stock_minimo_seguridad": 30}	\N	{"activo": true, "id_insumo": 1, "codigo_insumo": "INS-8840", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Propofol 200mg / 20ml", "stock_minimo_seguridad": 30}	2026-11-13 19:52:18.698271-06	::1
13	\N	INSERT	insumo	insumo {"activo": true, "id_insumo": 2, "codigo_insumo": "INS-1029", "es_controlado": true, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Fentanilo 0.5mg (Controlado)", "stock_minimo_seguridad": 15}	\N	{"activo": true, "id_insumo": 2, "codigo_insumo": "INS-1029", "es_controlado": true, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Fentanilo 0.5mg (Controlado)", "stock_minimo_seguridad": 15}	2026-11-13 19:52:18.698271-06	::1
14	\N	INSERT	insumo	insumo {"activo": true, "id_insumo": 3, "codigo_insumo": "INS-3321", "es_controlado": false, "unidad_medida": "Frasco", "descripcion_farmaco": "Insulina Humana R 100UI/ml", "stock_minimo_seguridad": 20}	\N	{"activo": true, "id_insumo": 3, "codigo_insumo": "INS-3321", "es_controlado": false, "unidad_medida": "Frasco", "descripcion_farmaco": "Insulina Humana R 100UI/ml", "stock_minimo_seguridad": 20}	2026-11-13 19:52:18.698271-06	::1
15	\N	INSERT	insumo	insumo {"activo": true, "id_insumo": 4, "codigo_insumo": "INS-5010", "es_controlado": false, "unidad_medida": "Caja", "descripcion_farmaco": "Paracetamol 500mg", "stock_minimo_seguridad": 100}	\N	{"activo": true, "id_insumo": 4, "codigo_insumo": "INS-5010", "es_controlado": false, "unidad_medida": "Caja", "descripcion_farmaco": "Paracetamol 500mg", "stock_minimo_seguridad": 100}	2026-11-13 19:52:18.698271-06	::1
16	\N	INSERT	lote	lote {"id_lote": 1, "id_insumo": 1, "numero_lote": "#LOT-2025-0192", "id_proveedor": 1, "fecha_caducidad": "2027-01-10", "precio_unitario": 85.50, "fecha_fabricacion": "2024-12-13"}	\N	{"id_lote": 1, "id_insumo": 1, "numero_lote": "#LOT-2025-0192", "id_proveedor": 1, "fecha_caducidad": "2027-01-10", "precio_unitario": 85.50, "fecha_fabricacion": "2024-12-13"}	2026-11-13 19:52:18.701007-06	::1
17	\N	INSERT	lote	lote {"id_lote": 2, "id_insumo": 1, "numero_lote": "#LOT-2024-0081", "id_proveedor": 1, "fecha_caducidad": "2026-11-15", "precio_unitario": 85.50, "fecha_fabricacion": "2024-12-13"}	\N	{"id_lote": 2, "id_insumo": 1, "numero_lote": "#LOT-2024-0081", "id_proveedor": 1, "fecha_caducidad": "2026-11-15", "precio_unitario": 85.50, "fecha_fabricacion": "2024-12-13"}	2026-11-13 19:52:18.701007-06	::1
18	\N	INSERT	lote	lote {"id_lote": 3, "id_insumo": 2, "numero_lote": "#LOT-2026-0044", "id_proveedor": 1, "fecha_caducidad": "2027-07-01", "precio_unitario": 120.00, "fecha_fabricacion": "2024-12-13"}	\N	{"id_lote": 3, "id_insumo": 2, "numero_lote": "#LOT-2026-0044", "id_proveedor": 1, "fecha_caducidad": "2027-07-01", "precio_unitario": 120.00, "fecha_fabricacion": "2024-12-13"}	2026-11-13 19:52:18.701007-06	::1
19	\N	INSERT	lote	lote {"id_lote": 4, "id_insumo": 3, "numero_lote": "#LOT-2026-0310", "id_proveedor": 1, "fecha_caducidad": "2027-03-03", "precio_unitario": 210.00, "fecha_fabricacion": "2024-12-13"}	\N	{"id_lote": 4, "id_insumo": 3, "numero_lote": "#LOT-2026-0310", "id_proveedor": 1, "fecha_caducidad": "2027-03-03", "precio_unitario": 210.00, "fecha_fabricacion": "2024-12-13"}	2026-11-13 19:52:18.701007-06	::1
20	\N	INSERT	lote	lote {"id_lote": 5, "id_insumo": 4, "numero_lote": "#LOT-2026-0555", "id_proveedor": 1, "fecha_caducidad": "2027-12-18", "precio_unitario": 35.00, "fecha_fabricacion": "2024-12-13"}	\N	{"id_lote": 5, "id_insumo": 4, "numero_lote": "#LOT-2026-0555", "id_proveedor": 1, "fecha_caducidad": "2027-12-18", "precio_unitario": 35.00, "fecha_fabricacion": "2024-12-13"}	2026-11-13 19:52:18.701007-06	::1
21	\N	INSERT	medico	medico {"nombre": "Dr. C. Mendoza", "id_medico": 1, "especialidad": "Anestesiología", "cedula_profesional": "8839201"}	\N	{"nombre": "Dr. C. Mendoza", "id_medico": 1, "especialidad": "Anestesiología", "cedula_profesional": "8839201"}	2026-11-13 19:52:18.705694-06	::1
22	\N	INSERT	paciente	paciente {"nombre": "J. Martínez P.", "id_paciente": 1, "area_ingreso": "Urgencias", "expediente_folio": "EXP-000123"}	\N	{"nombre": "J. Martínez P.", "id_paciente": 1, "area_ingreso": "Urgencias", "expediente_folio": "EXP-000123"}	2026-11-13 19:52:18.708308-06	::1
23	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 2, "cantidad": 4, "fecha_hora": "2026-11-13T19:52:18.710701-06:00", "id_entrada": 1, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 2, "cantidad": 4, "fecha_hora": "2026-11-13T19:52:18.710701-06:00", "id_entrada": 1, "id_usuario": 1, "id_ubicacion": 1}	2026-11-13 19:52:18.710701-06	::1
24	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 2, "cantidad": 4, "id_ubicacion": 1}	\N	{"id_lote": 2, "cantidad": 4, "id_ubicacion": 1}	2026-11-13 19:52:18.710701-06	::1
25	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 1, "cantidad": 10, "fecha_hora": "2026-11-13T19:52:18.710701-06:00", "id_entrada": 2, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 1, "cantidad": 10, "fecha_hora": "2026-11-13T19:52:18.710701-06:00", "id_entrada": 2, "id_usuario": 1, "id_ubicacion": 1}	2026-11-13 19:52:18.710701-06	::1
26	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 1, "cantidad": 10, "id_ubicacion": 1}	\N	{"id_lote": 1, "cantidad": 10, "id_ubicacion": 1}	2026-11-13 19:52:18.710701-06	::1
27	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 3, "cantidad": 4, "fecha_hora": "2026-11-13T19:52:18.710701-06:00", "id_entrada": 3, "id_usuario": 1, "id_ubicacion": 3}	\N	{"id_lote": 3, "cantidad": 4, "fecha_hora": "2026-11-13T19:52:18.710701-06:00", "id_entrada": 3, "id_usuario": 1, "id_ubicacion": 3}	2026-11-13 19:52:18.710701-06	::1
28	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 3, "cantidad": 4, "id_ubicacion": 3}	\N	{"id_lote": 3, "cantidad": 4, "id_ubicacion": 3}	2026-11-13 19:52:18.710701-06	::1
29	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 4, "cantidad": 12, "fecha_hora": "2026-11-13T19:52:18.710701-06:00", "id_entrada": 4, "id_usuario": 1, "id_ubicacion": 4}	\N	{"id_lote": 4, "cantidad": 12, "fecha_hora": "2026-11-13T19:52:18.710701-06:00", "id_entrada": 4, "id_usuario": 1, "id_ubicacion": 4}	2026-11-13 19:52:18.710701-06	::1
30	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 4, "cantidad": 12, "id_ubicacion": 4}	\N	{"id_lote": 4, "cantidad": 12, "id_ubicacion": 4}	2026-11-13 19:52:18.710701-06	::1
31	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 5, "cantidad": 500, "fecha_hora": "2026-11-13T19:52:18.710701-06:00", "id_entrada": 5, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 5, "cantidad": 500, "fecha_hora": "2026-11-13T19:52:18.710701-06:00", "id_entrada": 5, "id_usuario": 1, "id_ubicacion": 1}	2026-11-13 19:52:18.710701-06	::1
32	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 5, "cantidad": 500, "id_ubicacion": 1}	\N	{"id_lote": 5, "cantidad": 500, "id_ubicacion": 1}	2026-11-13 19:52:18.710701-06	::1
59	1	INSERT	almacen_ubicacion	almacen_ubicacion {"nombre_area": "Pediatría", "id_ubicacion": 10, "anaquel_seccion": "Gabinete P-02"}	\N	{"nombre_area": "Pediatría", "id_ubicacion": 10, "anaquel_seccion": "Gabinete P-02"}	2026-11-17 18:05:30.454005-06	192.168.1.101
60	1	INSERT	almacen_ubicacion	almacen_ubicacion {"nombre_area": "Quirófano B1", "id_ubicacion": 11, "anaquel_seccion": null}	\N	{"nombre_area": "Quirófano B1", "id_ubicacion": 11, "anaquel_seccion": null}	2026-11-17 18:05:30.454005-06	192.168.1.101
45	\N	UPDATE	usuario	usuario {"activo": true, "correo": "jefe.farmacia@hospital.mx", "id_rol": 1, "nombre": "Laura Hernández", "id_usuario": 1}	{"activo": true, "correo": "jefe.farmacia@hospital.mx", "id_rol": 1, "nombre": "Laura Hernández", "id_usuario": 1}	{"activo": true, "correo": "jefe.farmacia@hospital.mx", "id_rol": 1, "nombre": "Laura Hernández", "id_usuario": 1}	2026-11-14 16:17:17.394515-06	consola
46	\N	UPDATE	usuario	usuario {"activo": true, "correo": "dispensador@hospital.mx", "id_rol": 2, "nombre": "Carlos Ruiz", "id_usuario": 2}	{"activo": true, "correo": "dispensador@hospital.mx", "id_rol": 2, "nombre": "Carlos Ruiz", "id_usuario": 2}	{"activo": true, "correo": "dispensador@hospital.mx", "id_rol": 2, "nombre": "Carlos Ruiz", "id_usuario": 2}	2026-11-14 16:17:52.401178-06	consola
47	\N	UPDATE	usuario	usuario {"activo": true, "correo": "admin@hospital.mx", "id_rol": 3, "nombre": "Ana Torres", "id_usuario": 3}	{"activo": true, "correo": "admin@hospital.mx", "id_rol": 3, "nombre": "Ana Torres", "id_usuario": 3}	{"activo": true, "correo": "admin@hospital.mx", "id_rol": 3, "nombre": "Ana Torres", "id_usuario": 3}	2026-11-14 16:18:09.20372-06	consola
48	3	INSERT	usuario	usuario {"activo": true, "correo": "ricardo.medina@hospital.mx", "id_rol": 1, "nombre": "Ricardo Medina Salas", "id_usuario": 4}	\N	{"activo": true, "correo": "ricardo.medina@hospital.mx", "id_rol": 1, "nombre": "Ricardo Medina Salas", "id_usuario": 4}	2026-11-17 18:05:30.454005-06	192.168.1.103
49	3	INSERT	usuario	usuario {"activo": true, "correo": "pedro.gallegos@hospital.mx", "id_rol": 2, "nombre": "Pedro Gallegos", "id_usuario": 5}	\N	{"activo": true, "correo": "pedro.gallegos@hospital.mx", "id_rol": 2, "nombre": "Pedro Gallegos", "id_usuario": 5}	2026-11-17 18:05:30.454005-06	192.168.1.103
50	3	INSERT	usuario	usuario {"activo": true, "correo": "daniela.cardenas@hospital.mx", "id_rol": 2, "nombre": "Daniela Cárdenas", "id_usuario": 6}	\N	{"activo": true, "correo": "daniela.cardenas@hospital.mx", "id_rol": 2, "nombre": "Daniela Cárdenas", "id_usuario": 6}	2026-11-17 18:05:30.454005-06	192.168.1.103
51	3	INSERT	usuario	usuario {"activo": true, "correo": "jose.ramirez@hospital.mx", "id_rol": 2, "nombre": "José Luis Ramírez", "id_usuario": 7}	\N	{"activo": true, "correo": "jose.ramirez@hospital.mx", "id_rol": 2, "nombre": "José Luis Ramírez", "id_usuario": 7}	2026-11-17 18:05:30.454005-06	192.168.1.103
52	3	INSERT	usuario	usuario {"activo": true, "correo": "maria.ortiz@hospital.mx", "id_rol": 2, "nombre": "María Fernanda Ortiz", "id_usuario": 8}	\N	{"activo": true, "correo": "maria.ortiz@hospital.mx", "id_rol": 2, "nombre": "María Fernanda Ortiz", "id_usuario": 8}	2026-11-17 18:05:30.454005-06	192.168.1.103
53	3	INSERT	usuario	usuario {"activo": true, "correo": "jorge.salinas@hospital.mx", "id_rol": 3, "nombre": "Jorge Salinas", "id_usuario": 9}	\N	{"activo": true, "correo": "jorge.salinas@hospital.mx", "id_rol": 3, "nombre": "Jorge Salinas", "id_usuario": 9}	2026-11-17 18:05:30.454005-06	192.168.1.103
54	1	INSERT	almacen_ubicacion	almacen_ubicacion {"nombre_area": "Bóveda Central", "id_ubicacion": 5, "anaquel_seccion": "Cuarto de controlados"}	\N	{"nombre_area": "Bóveda Central", "id_ubicacion": 5, "anaquel_seccion": "Cuarto de controlados"}	2026-11-17 18:05:30.454005-06	192.168.1.101
55	1	INSERT	almacen_ubicacion	almacen_ubicacion {"nombre_area": "Refrigerador 1", "id_ubicacion": 6, "anaquel_seccion": "Cadena fría"}	\N	{"nombre_area": "Refrigerador 1", "id_ubicacion": 6, "anaquel_seccion": "Cadena fría"}	2026-11-17 18:05:30.454005-06	192.168.1.101
56	1	INSERT	almacen_ubicacion	almacen_ubicacion {"nombre_area": "Terapia Intensiva (UCI)", "id_ubicacion": 7, "anaquel_seccion": "Carro de medicamentos"}	\N	{"nombre_area": "Terapia Intensiva (UCI)", "id_ubicacion": 7, "anaquel_seccion": "Carro de medicamentos"}	2026-11-17 18:05:30.454005-06	192.168.1.101
57	1	INSERT	almacen_ubicacion	almacen_ubicacion {"nombre_area": "Farmacia Satélite Urgencias", "id_ubicacion": 8, "anaquel_seccion": "Anaquel S-01"}	\N	{"nombre_area": "Farmacia Satélite Urgencias", "id_ubicacion": 8, "anaquel_seccion": "Anaquel S-01"}	2026-11-17 18:05:30.454005-06	192.168.1.101
58	1	INSERT	almacen_ubicacion	almacen_ubicacion {"nombre_area": "Farmacia Satélite Hospitalización", "id_ubicacion": 9, "anaquel_seccion": "Anaquel H-04"}	\N	{"nombre_area": "Farmacia Satélite Hospitalización", "id_ubicacion": 9, "anaquel_seccion": "Anaquel H-04"}	2026-11-17 18:05:30.454005-06	192.168.1.101
61	1	INSERT	almacen_ubicacion	almacen_ubicacion {"nombre_area": "Tococirugía", "id_ubicacion": 12, "anaquel_seccion": "Gabinete T-01"}	\N	{"nombre_area": "Tococirugía", "id_ubicacion": 12, "anaquel_seccion": "Gabinete T-01"}	2026-11-17 18:05:30.454005-06	192.168.1.101
62	1	INSERT	proveedor	proveedor {"rfc": "DMP040312K45", "id_proveedor": 2, "razon_social": "Distribuidora Médica del Pacífico S.A. de C.V.", "contacto_email": "pedidos@dmpacifico.example", "contacto_telefono": "33 3615 2200"}	\N	{"rfc": "DMP040312K45", "id_proveedor": 2, "razon_social": "Distribuidora Médica del Pacífico S.A. de C.V.", "contacto_email": "pedidos@dmpacifico.example", "contacto_telefono": "33 3615 2200"}	2026-11-17 18:05:30.454005-06	192.168.1.101
63	1	INSERT	proveedor	proveedor {"rfc": "LBM980715QX2", "id_proveedor": 3, "razon_social": "Laboratorios Biofarma de México S.A.", "contacto_email": "ventas@biofarma.example", "contacto_telefono": "33 3810 4471"}	\N	{"rfc": "LBM980715QX2", "id_proveedor": 3, "razon_social": "Laboratorios Biofarma de México S.A.", "contacto_email": "ventas@biofarma.example", "contacto_telefono": "33 3810 4471"}	2026-11-17 18:05:30.454005-06	192.168.1.101
64	1	INSERT	proveedor	proveedor {"rfc": "IHO110228T91", "id_proveedor": 4, "razon_social": "Insumos Hospitalarios Occidente S.A. de C.V.", "contacto_email": "contacto@insumosocc.example", "contacto_telefono": "33 3121 9085"}	\N	{"rfc": "IHO110228T91", "id_proveedor": 4, "razon_social": "Insumos Hospitalarios Occidente S.A. de C.V.", "contacto_email": "contacto@insumosocc.example", "contacto_telefono": "33 3121 9085"}	2026-11-17 18:05:30.454005-06	192.168.1.101
65	1	INSERT	proveedor	proveedor {"rfc": "GFC070930L38", "id_proveedor": 5, "razon_social": "Grupo Farmacéutico Centauro S.A. de C.V.", "contacto_email": "licitaciones@centauro.example", "contacto_telefono": "33 3647 3310"}	\N	{"rfc": "GFC070930L38", "id_proveedor": 5, "razon_social": "Grupo Farmacéutico Centauro S.A. de C.V.", "contacto_email": "licitaciones@centauro.example", "contacto_telefono": "33 3647 3310"}	2026-11-17 18:05:30.454005-06	192.168.1.101
66	1	INSERT	proveedor	proveedor {"rfc": "MET150604H27", "id_proveedor": 6, "razon_social": "Medicamentos Especializados Tapatíos S.A.", "contacto_email": "ventas@metapatios.example", "contacto_telefono": "33 3825 7742"}	\N	{"rfc": "MET150604H27", "id_proveedor": 6, "razon_social": "Medicamentos Especializados Tapatíos S.A.", "contacto_email": "ventas@metapatios.example", "contacto_telefono": "33 3825 7742"}	2026-11-17 18:05:30.454005-06	192.168.1.101
67	1	INSERT	proveedor	proveedor {"rfc": "CFP190121AB7", "id_proveedor": 7, "razon_social": "Cadena Fría Pharma Logistics S.A. de C.V.", "contacto_email": "operaciones@cadenafria.example", "contacto_telefono": "33 3770 5518"}	\N	{"rfc": "CFP190121AB7", "id_proveedor": 7, "razon_social": "Cadena Fría Pharma Logistics S.A. de C.V.", "contacto_email": "operaciones@cadenafria.example", "contacto_telefono": "33 3770 5518"}	2026-11-17 18:05:30.454005-06	192.168.1.101
68	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 5, "codigo_insumo": "INS-2001", "es_controlado": true, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Morfina 10mg/ml", "stock_minimo_seguridad": 12}	\N	{"activo": true, "id_insumo": 5, "codigo_insumo": "INS-2001", "es_controlado": true, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Morfina 10mg/ml", "stock_minimo_seguridad": 12}	2026-11-17 18:05:30.454005-06	192.168.1.101
69	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 6, "codigo_insumo": "INS-2002", "es_controlado": true, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Midazolam 5mg/5ml", "stock_minimo_seguridad": 20}	\N	{"activo": true, "id_insumo": 6, "codigo_insumo": "INS-2002", "es_controlado": true, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Midazolam 5mg/5ml", "stock_minimo_seguridad": 20}	2026-11-17 18:05:30.454005-06	192.168.1.101
70	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 7, "codigo_insumo": "INS-2003", "es_controlado": true, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Ketamina 500mg/10ml", "stock_minimo_seguridad": 10}	\N	{"activo": true, "id_insumo": 7, "codigo_insumo": "INS-2003", "es_controlado": true, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Ketamina 500mg/10ml", "stock_minimo_seguridad": 10}	2026-11-17 18:05:30.454005-06	192.168.1.101
71	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 8, "codigo_insumo": "INS-2004", "es_controlado": true, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Diazepam 10mg/2ml", "stock_minimo_seguridad": 15}	\N	{"activo": true, "id_insumo": 8, "codigo_insumo": "INS-2004", "es_controlado": true, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Diazepam 10mg/2ml", "stock_minimo_seguridad": 15}	2026-11-17 18:05:30.454005-06	192.168.1.101
72	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 9, "codigo_insumo": "INS-2005", "es_controlado": true, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Buprenorfina 0.3mg/ml", "stock_minimo_seguridad": 8}	\N	{"activo": true, "id_insumo": 9, "codigo_insumo": "INS-2005", "es_controlado": true, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Buprenorfina 0.3mg/ml", "stock_minimo_seguridad": 8}	2026-11-17 18:05:30.454005-06	192.168.1.101
73	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 10, "codigo_insumo": "INS-2006", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Rocuronio 50mg/5ml", "stock_minimo_seguridad": 40}	\N	{"activo": true, "id_insumo": 10, "codigo_insumo": "INS-2006", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Rocuronio 50mg/5ml", "stock_minimo_seguridad": 40}	2026-11-17 18:05:30.454005-06	192.168.1.101
74	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 11, "codigo_insumo": "INS-2007", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Bupivacaína 0.5% 20ml", "stock_minimo_seguridad": 25}	\N	{"activo": true, "id_insumo": 11, "codigo_insumo": "INS-2007", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Bupivacaína 0.5% 20ml", "stock_minimo_seguridad": 25}	2026-11-17 18:05:30.454005-06	192.168.1.101
75	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 12, "codigo_insumo": "INS-2008", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Lidocaína 2% 100mg/5ml", "stock_minimo_seguridad": 50}	\N	{"activo": true, "id_insumo": 12, "codigo_insumo": "INS-2008", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Lidocaína 2% 100mg/5ml", "stock_minimo_seguridad": 50}	2026-11-17 18:05:30.454005-06	192.168.1.101
76	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 13, "codigo_insumo": "INS-2009", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Ketorolaco 30mg/ml", "stock_minimo_seguridad": 100}	\N	{"activo": true, "id_insumo": 13, "codigo_insumo": "INS-2009", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Ketorolaco 30mg/ml", "stock_minimo_seguridad": 100}	2026-11-17 18:05:30.454005-06	192.168.1.101
77	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 14, "codigo_insumo": "INS-2010", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Ondansetrón 8mg/4ml", "stock_minimo_seguridad": 60}	\N	{"activo": true, "id_insumo": 14, "codigo_insumo": "INS-2010", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Ondansetrón 8mg/4ml", "stock_minimo_seguridad": 60}	2026-11-17 18:05:30.454005-06	192.168.1.101
78	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 15, "codigo_insumo": "INS-2011", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Dexametasona 8mg/2ml", "stock_minimo_seguridad": 50}	\N	{"activo": true, "id_insumo": 15, "codigo_insumo": "INS-2011", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Dexametasona 8mg/2ml", "stock_minimo_seguridad": 50}	2026-11-17 18:05:30.454005-06	192.168.1.101
79	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 16, "codigo_insumo": "INS-2012", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Ceftriaxona 1g", "stock_minimo_seguridad": 120}	\N	{"activo": true, "id_insumo": 16, "codigo_insumo": "INS-2012", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Ceftriaxona 1g", "stock_minimo_seguridad": 120}	2026-11-17 18:05:30.454005-06	192.168.1.101
80	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 17, "codigo_insumo": "INS-2013", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Cefazolina 1g", "stock_minimo_seguridad": 60}	\N	{"activo": true, "id_insumo": 17, "codigo_insumo": "INS-2013", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Cefazolina 1g", "stock_minimo_seguridad": 60}	2026-11-17 18:05:30.454005-06	192.168.1.101
81	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 18, "codigo_insumo": "INS-2014", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Vancomicina 1g", "stock_minimo_seguridad": 40}	\N	{"activo": true, "id_insumo": 18, "codigo_insumo": "INS-2014", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Vancomicina 1g", "stock_minimo_seguridad": 40}	2026-11-17 18:05:30.454005-06	192.168.1.101
82	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 19, "codigo_insumo": "INS-2015", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Meropenem 1g", "stock_minimo_seguridad": 30}	\N	{"activo": true, "id_insumo": 19, "codigo_insumo": "INS-2015", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Meropenem 1g", "stock_minimo_seguridad": 30}	2026-11-17 18:05:30.454005-06	192.168.1.101
83	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 20, "codigo_insumo": "INS-2016", "es_controlado": false, "unidad_medida": "Bolsa", "descripcion_farmaco": "Ciprofloxacino 200mg/100ml", "stock_minimo_seguridad": 40}	\N	{"activo": true, "id_insumo": 20, "codigo_insumo": "INS-2016", "es_controlado": false, "unidad_medida": "Bolsa", "descripcion_farmaco": "Ciprofloxacino 200mg/100ml", "stock_minimo_seguridad": 40}	2026-11-17 18:05:30.454005-06	192.168.1.101
84	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 21, "codigo_insumo": "INS-2017", "es_controlado": false, "unidad_medida": "Bolsa", "descripcion_farmaco": "Metronidazol 500mg/100ml", "stock_minimo_seguridad": 50}	\N	{"activo": true, "id_insumo": 21, "codigo_insumo": "INS-2017", "es_controlado": false, "unidad_medida": "Bolsa", "descripcion_farmaco": "Metronidazol 500mg/100ml", "stock_minimo_seguridad": 50}	2026-11-17 18:05:30.454005-06	192.168.1.101
85	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 22, "codigo_insumo": "INS-2018", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Adrenalina 1mg/ml", "stock_minimo_seguridad": 60}	\N	{"activo": true, "id_insumo": 22, "codigo_insumo": "INS-2018", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Adrenalina 1mg/ml", "stock_minimo_seguridad": 60}	2026-11-17 18:05:30.454005-06	192.168.1.101
86	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 23, "codigo_insumo": "INS-2019", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Atropina 1mg/ml", "stock_minimo_seguridad": 30}	\N	{"activo": true, "id_insumo": 23, "codigo_insumo": "INS-2019", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Atropina 1mg/ml", "stock_minimo_seguridad": 30}	2026-11-17 18:05:30.454005-06	192.168.1.101
87	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 24, "codigo_insumo": "INS-2020", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Amiodarona 150mg/3ml", "stock_minimo_seguridad": 25}	\N	{"activo": true, "id_insumo": 24, "codigo_insumo": "INS-2020", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Amiodarona 150mg/3ml", "stock_minimo_seguridad": 25}	2026-11-17 18:05:30.454005-06	192.168.1.101
88	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 25, "codigo_insumo": "INS-2021", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Noradrenalina 4mg/4ml", "stock_minimo_seguridad": 25}	\N	{"activo": true, "id_insumo": 25, "codigo_insumo": "INS-2021", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Noradrenalina 4mg/4ml", "stock_minimo_seguridad": 25}	2026-11-17 18:05:30.454005-06	192.168.1.101
89	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 26, "codigo_insumo": "INS-2022", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Furosemida 20mg/2ml", "stock_minimo_seguridad": 50}	\N	{"activo": true, "id_insumo": 26, "codigo_insumo": "INS-2022", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Furosemida 20mg/2ml", "stock_minimo_seguridad": 50}	2026-11-17 18:05:30.454005-06	192.168.1.101
90	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 27, "codigo_insumo": "INS-2023", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Heparina sódica 5000UI/5ml", "stock_minimo_seguridad": 50}	\N	{"activo": true, "id_insumo": 27, "codigo_insumo": "INS-2023", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Heparina sódica 5000UI/5ml", "stock_minimo_seguridad": 50}	2026-11-17 18:05:30.454005-06	192.168.1.101
91	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 28, "codigo_insumo": "INS-2024", "es_controlado": false, "unidad_medida": "Jeringa prellenada", "descripcion_farmaco": "Enoxaparina 40mg/0.4ml", "stock_minimo_seguridad": 60}	\N	{"activo": true, "id_insumo": 28, "codigo_insumo": "INS-2024", "es_controlado": false, "unidad_medida": "Jeringa prellenada", "descripcion_farmaco": "Enoxaparina 40mg/0.4ml", "stock_minimo_seguridad": 60}	2026-11-17 18:05:30.454005-06	192.168.1.101
109	1	INSERT	medico	medico {"nombre": "Dra. Sofía Pedroza", "id_medico": 8, "especialidad": "Neonatología", "cedula_profesional": "10456982"}	\N	{"nombre": "Dra. Sofía Pedroza", "id_medico": 8, "especialidad": "Neonatología", "cedula_profesional": "10456982"}	2026-11-17 18:05:30.454005-06	192.168.1.101
92	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 29, "codigo_insumo": "INS-2025", "es_controlado": false, "unidad_medida": "Bolsa", "descripcion_farmaco": "Solución salina 0.9% 500ml", "stock_minimo_seguridad": 200}	\N	{"activo": true, "id_insumo": 29, "codigo_insumo": "INS-2025", "es_controlado": false, "unidad_medida": "Bolsa", "descripcion_farmaco": "Solución salina 0.9% 500ml", "stock_minimo_seguridad": 200}	2026-11-17 18:05:30.454005-06	192.168.1.101
93	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 30, "codigo_insumo": "INS-2026", "es_controlado": false, "unidad_medida": "Bolsa", "descripcion_farmaco": "Solución Hartmann 1000ml", "stock_minimo_seguridad": 150}	\N	{"activo": true, "id_insumo": 30, "codigo_insumo": "INS-2026", "es_controlado": false, "unidad_medida": "Bolsa", "descripcion_farmaco": "Solución Hartmann 1000ml", "stock_minimo_seguridad": 150}	2026-11-17 18:05:30.454005-06	192.168.1.101
94	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 31, "codigo_insumo": "INS-2027", "es_controlado": false, "unidad_medida": "Bolsa", "descripcion_farmaco": "Solución glucosada 5% 500ml", "stock_minimo_seguridad": 100}	\N	{"activo": true, "id_insumo": 31, "codigo_insumo": "INS-2027", "es_controlado": false, "unidad_medida": "Bolsa", "descripcion_farmaco": "Solución glucosada 5% 500ml", "stock_minimo_seguridad": 100}	2026-11-17 18:05:30.454005-06	192.168.1.101
95	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 32, "codigo_insumo": "INS-2028", "es_controlado": false, "unidad_medida": "Frasco", "descripcion_farmaco": "Insulina NPH 100UI/ml", "stock_minimo_seguridad": 15}	\N	{"activo": true, "id_insumo": 32, "codigo_insumo": "INS-2028", "es_controlado": false, "unidad_medida": "Frasco", "descripcion_farmaco": "Insulina NPH 100UI/ml", "stock_minimo_seguridad": 15}	2026-11-17 18:05:30.454005-06	192.168.1.101
96	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 33, "codigo_insumo": "INS-2029", "es_controlado": false, "unidad_medida": "Pluma", "descripcion_farmaco": "Insulina glargina 100UI/ml", "stock_minimo_seguridad": 10}	\N	{"activo": true, "id_insumo": 33, "codigo_insumo": "INS-2029", "es_controlado": false, "unidad_medida": "Pluma", "descripcion_farmaco": "Insulina glargina 100UI/ml", "stock_minimo_seguridad": 10}	2026-11-17 18:05:30.454005-06	192.168.1.101
97	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 34, "codigo_insumo": "INS-2030", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Omeprazol 40mg IV", "stock_minimo_seguridad": 40}	\N	{"activo": true, "id_insumo": 34, "codigo_insumo": "INS-2030", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Omeprazol 40mg IV", "stock_minimo_seguridad": 40}	2026-11-17 18:05:30.454005-06	192.168.1.101
98	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 35, "codigo_insumo": "INS-2031", "es_controlado": false, "unidad_medida": "Inhalador", "descripcion_farmaco": "Salbutamol 100mcg inhalador", "stock_minimo_seguridad": 30}	\N	{"activo": true, "id_insumo": 35, "codigo_insumo": "INS-2031", "es_controlado": false, "unidad_medida": "Inhalador", "descripcion_farmaco": "Salbutamol 100mcg inhalador", "stock_minimo_seguridad": 30}	2026-11-17 18:05:30.454005-06	192.168.1.101
99	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 36, "codigo_insumo": "INS-2032", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Oxitocina 10UI/ml", "stock_minimo_seguridad": 30}	\N	{"activo": true, "id_insumo": 36, "codigo_insumo": "INS-2032", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Oxitocina 10UI/ml", "stock_minimo_seguridad": 30}	2026-11-17 18:05:30.454005-06	192.168.1.101
100	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 37, "codigo_insumo": "INS-2033", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Hidrocortisona 100mg", "stock_minimo_seguridad": 25}	\N	{"activo": true, "id_insumo": 37, "codigo_insumo": "INS-2033", "es_controlado": false, "unidad_medida": "Frasco ámpula", "descripcion_farmaco": "Hidrocortisona 100mg", "stock_minimo_seguridad": 25}	2026-11-17 18:05:30.454005-06	192.168.1.101
101	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 38, "codigo_insumo": "INS-2034", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Naloxona 0.4mg/ml", "stock_minimo_seguridad": 10}	\N	{"activo": true, "id_insumo": 38, "codigo_insumo": "INS-2034", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Naloxona 0.4mg/ml", "stock_minimo_seguridad": 10}	2026-11-17 18:05:30.454005-06	192.168.1.101
102	1	INSERT	insumo	insumo {"activo": true, "id_insumo": 39, "codigo_insumo": "INS-2035", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Gluconato de calcio 10% 10ml", "stock_minimo_seguridad": 20}	\N	{"activo": true, "id_insumo": 39, "codigo_insumo": "INS-2035", "es_controlado": false, "unidad_medida": "Ampolleta", "descripcion_farmaco": "Gluconato de calcio 10% 10ml", "stock_minimo_seguridad": 20}	2026-11-17 18:05:30.454005-06	192.168.1.101
103	1	INSERT	medico	medico {"nombre": "Dra. Patricia Villalobos", "id_medico": 2, "especialidad": "Medicina de Urgencias", "cedula_profesional": "9120456"}	\N	{"nombre": "Dra. Patricia Villalobos", "id_medico": 2, "especialidad": "Medicina de Urgencias", "cedula_profesional": "9120456"}	2026-11-17 18:05:30.454005-06	192.168.1.101
104	1	INSERT	medico	medico {"nombre": "Dr. Héctor Ibarra", "id_medico": 3, "especialidad": "Cirugía General", "cedula_profesional": "8745123"}	\N	{"nombre": "Dr. Héctor Ibarra", "id_medico": 3, "especialidad": "Cirugía General", "cedula_profesional": "8745123"}	2026-11-17 18:05:30.454005-06	192.168.1.101
105	1	INSERT	medico	medico {"nombre": "Dra. Lucía Fernández", "id_medico": 4, "especialidad": "Pediatría", "cedula_profesional": "10234871"}	\N	{"nombre": "Dra. Lucía Fernández", "id_medico": 4, "especialidad": "Pediatría", "cedula_profesional": "10234871"}	2026-11-17 18:05:30.454005-06	192.168.1.101
106	1	INSERT	medico	medico {"nombre": "Dr. Alejandro Cortés", "id_medico": 5, "especialidad": "Medicina Interna", "cedula_profesional": "7561290"}	\N	{"nombre": "Dr. Alejandro Cortés", "id_medico": 5, "especialidad": "Medicina Interna", "cedula_profesional": "7561290"}	2026-11-17 18:05:30.454005-06	192.168.1.101
107	1	INSERT	medico	medico {"nombre": "Dra. Mariana Robles", "id_medico": 6, "especialidad": "Ginecología y Obstetricia", "cedula_profesional": "9987345"}	\N	{"nombre": "Dra. Mariana Robles", "id_medico": 6, "especialidad": "Ginecología y Obstetricia", "cedula_profesional": "9987345"}	2026-11-17 18:05:30.454005-06	192.168.1.101
108	1	INSERT	medico	medico {"nombre": "Dr. Gustavo Navarro", "id_medico": 7, "especialidad": "Cardiología", "cedula_profesional": "8123764"}	\N	{"nombre": "Dr. Gustavo Navarro", "id_medico": 7, "especialidad": "Cardiología", "cedula_profesional": "8123764"}	2026-11-17 18:05:30.454005-06	192.168.1.101
227	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 23, "cantidad": 60, "id_ubicacion": 9}	\N	{"id_lote": 23, "cantidad": 60, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.101
110	1	INSERT	medico	medico {"nombre": "Dr. Emilio Santoyo", "id_medico": 9, "especialidad": "Ortopedia y Traumatología", "cedula_profesional": "7890231"}	\N	{"nombre": "Dr. Emilio Santoyo", "id_medico": 9, "especialidad": "Ortopedia y Traumatología", "cedula_profesional": "7890231"}	2026-11-17 18:05:30.454005-06	192.168.1.101
111	1	INSERT	medico	medico {"nombre": "Dra. Valeria Ochoa", "id_medico": 10, "especialidad": "Medicina Crítica", "cedula_profesional": "9345617"}	\N	{"nombre": "Dra. Valeria Ochoa", "id_medico": 10, "especialidad": "Medicina Crítica", "cedula_profesional": "9345617"}	2026-11-17 18:05:30.454005-06	192.168.1.101
112	1	INSERT	medico	medico {"nombre": "Dr. Rodrigo Palacios", "id_medico": 11, "especialidad": "Anestesiología", "cedula_profesional": "8567094"}	\N	{"nombre": "Dr. Rodrigo Palacios", "id_medico": 11, "especialidad": "Anestesiología", "cedula_profesional": "8567094"}	2026-11-17 18:05:30.454005-06	192.168.1.101
113	1	INSERT	medico	medico {"nombre": "Dra. Teresa Quintero", "id_medico": 12, "especialidad": "Oncología Médica", "cedula_profesional": "9678312"}	\N	{"nombre": "Dra. Teresa Quintero", "id_medico": 12, "especialidad": "Oncología Médica", "cedula_profesional": "9678312"}	2026-11-17 18:05:30.454005-06	192.168.1.101
114	1	INSERT	paciente	paciente {"nombre": "Elena Ramírez Torres", "id_paciente": 2, "area_ingreso": "Urgencias", "expediente_folio": "EXP-000124"}	\N	{"nombre": "Elena Ramírez Torres", "id_paciente": 2, "area_ingreso": "Urgencias", "expediente_folio": "EXP-000124"}	2026-11-17 18:05:30.454005-06	192.168.1.101
115	1	INSERT	paciente	paciente {"nombre": "Miguel Ángel Soto Vega", "id_paciente": 3, "area_ingreso": "Hospitalización", "expediente_folio": "EXP-000125"}	\N	{"nombre": "Miguel Ángel Soto Vega", "id_paciente": 3, "area_ingreso": "Hospitalización", "expediente_folio": "EXP-000125"}	2026-11-17 18:05:30.454005-06	192.168.1.101
116	1	INSERT	paciente	paciente {"nombre": "Guadalupe Ríos Mendoza", "id_paciente": 4, "area_ingreso": "Tococirugía", "expediente_folio": "EXP-000126"}	\N	{"nombre": "Guadalupe Ríos Mendoza", "id_paciente": 4, "area_ingreso": "Tococirugía", "expediente_folio": "EXP-000126"}	2026-11-17 18:05:30.454005-06	192.168.1.101
117	1	INSERT	paciente	paciente {"nombre": "Fernando Castañeda Lara", "id_paciente": 5, "area_ingreso": "Terapia Intensiva", "expediente_folio": "EXP-000127"}	\N	{"nombre": "Fernando Castañeda Lara", "id_paciente": 5, "area_ingreso": "Terapia Intensiva", "expediente_folio": "EXP-000127"}	2026-11-17 18:05:30.454005-06	192.168.1.101
118	1	INSERT	paciente	paciente {"nombre": "Ana Sofía Domínguez Ruiz", "id_paciente": 6, "area_ingreso": "Pediatría", "expediente_folio": "EXP-000128"}	\N	{"nombre": "Ana Sofía Domínguez Ruiz", "id_paciente": 6, "area_ingreso": "Pediatría", "expediente_folio": "EXP-000128"}	2026-11-17 18:05:30.454005-06	192.168.1.101
119	1	INSERT	paciente	paciente {"nombre": "Luis Alberto Herrera Gil", "id_paciente": 7, "area_ingreso": "Quirófano", "expediente_folio": "EXP-000129"}	\N	{"nombre": "Luis Alberto Herrera Gil", "id_paciente": 7, "area_ingreso": "Quirófano", "expediente_folio": "EXP-000129"}	2026-11-17 18:05:30.454005-06	192.168.1.101
120	1	INSERT	paciente	paciente {"nombre": "Carmen Lizeth Aguirre Peña", "id_paciente": 8, "area_ingreso": "Hospitalización", "expediente_folio": "EXP-000130"}	\N	{"nombre": "Carmen Lizeth Aguirre Peña", "id_paciente": 8, "area_ingreso": "Hospitalización", "expediente_folio": "EXP-000130"}	2026-11-17 18:05:30.454005-06	192.168.1.101
121	1	INSERT	paciente	paciente {"nombre": "Javier Esparza Montes", "id_paciente": 9, "area_ingreso": "Urgencias", "expediente_folio": "EXP-000131"}	\N	{"nombre": "Javier Esparza Montes", "id_paciente": 9, "area_ingreso": "Urgencias", "expediente_folio": "EXP-000131"}	2026-11-17 18:05:30.454005-06	192.168.1.101
122	1	INSERT	paciente	paciente {"nombre": "Rosa María Valdez Ortega", "id_paciente": 10, "area_ingreso": "Oncología", "expediente_folio": "EXP-000132"}	\N	{"nombre": "Rosa María Valdez Ortega", "id_paciente": 10, "area_ingreso": "Oncología", "expediente_folio": "EXP-000132"}	2026-11-17 18:05:30.454005-06	192.168.1.101
123	1	INSERT	paciente	paciente {"nombre": "Diego Armando Cisneros", "id_paciente": 11, "area_ingreso": "Urgencias", "expediente_folio": "EXP-000133"}	\N	{"nombre": "Diego Armando Cisneros", "id_paciente": 11, "area_ingreso": "Urgencias", "expediente_folio": "EXP-000133"}	2026-11-17 18:05:30.454005-06	192.168.1.101
124	1	INSERT	paciente	paciente {"nombre": "Paola Andrea Beltrán Cruz", "id_paciente": 12, "area_ingreso": "Hospitalización", "expediente_folio": "EXP-000134"}	\N	{"nombre": "Paola Andrea Beltrán Cruz", "id_paciente": 12, "area_ingreso": "Hospitalización", "expediente_folio": "EXP-000134"}	2026-11-17 18:05:30.454005-06	192.168.1.101
125	1	INSERT	paciente	paciente {"nombre": "Ernesto Villaseñor Díaz", "id_paciente": 13, "area_ingreso": "Terapia Intensiva", "expediente_folio": "EXP-000135"}	\N	{"nombre": "Ernesto Villaseñor Díaz", "id_paciente": 13, "area_ingreso": "Terapia Intensiva", "expediente_folio": "EXP-000135"}	2026-11-17 18:05:30.454005-06	192.168.1.101
126	1	INSERT	paciente	paciente {"nombre": "Mariana Contreras Solís", "id_paciente": 14, "area_ingreso": "Tococirugía", "expediente_folio": "EXP-000136"}	\N	{"nombre": "Mariana Contreras Solís", "id_paciente": 14, "area_ingreso": "Tococirugía", "expediente_folio": "EXP-000136"}	2026-11-17 18:05:30.454005-06	192.168.1.101
127	1	INSERT	paciente	paciente {"nombre": "Raúl Ontiveros Pineda", "id_paciente": 15, "area_ingreso": "Quirófano", "expediente_folio": "EXP-000137"}	\N	{"nombre": "Raúl Ontiveros Pineda", "id_paciente": 15, "area_ingreso": "Quirófano", "expediente_folio": "EXP-000137"}	2026-11-17 18:05:30.454005-06	192.168.1.101
128	1	INSERT	paciente	paciente {"nombre": "Alejandra Nuño Barajas", "id_paciente": 16, "area_ingreso": "Pediatría", "expediente_folio": "EXP-000138"}	\N	{"nombre": "Alejandra Nuño Barajas", "id_paciente": 16, "area_ingreso": "Pediatría", "expediente_folio": "EXP-000138"}	2026-11-17 18:05:30.454005-06	192.168.1.101
129	1	INSERT	paciente	paciente {"nombre": "Jorge Luis Gaytán Reyes", "id_paciente": 17, "area_ingreso": "Hospitalización", "expediente_folio": "EXP-000139"}	\N	{"nombre": "Jorge Luis Gaytán Reyes", "id_paciente": 17, "area_ingreso": "Hospitalización", "expediente_folio": "EXP-000139"}	2026-11-17 18:05:30.454005-06	192.168.1.101
130	1	INSERT	paciente	paciente {"nombre": "Karla Vanessa Mora Cuevas", "id_paciente": 18, "area_ingreso": "Urgencias", "expediente_folio": "EXP-000140"}	\N	{"nombre": "Karla Vanessa Mora Cuevas", "id_paciente": 18, "area_ingreso": "Urgencias", "expediente_folio": "EXP-000140"}	2026-11-17 18:05:30.454005-06	192.168.1.101
131	1	INSERT	paciente	paciente {"nombre": "Salvador Padilla Franco", "id_paciente": 19, "area_ingreso": "Terapia Intensiva", "expediente_folio": "EXP-000141"}	\N	{"nombre": "Salvador Padilla Franco", "id_paciente": 19, "area_ingreso": "Terapia Intensiva", "expediente_folio": "EXP-000141"}	2026-11-17 18:05:30.454005-06	192.168.1.101
132	1	INSERT	paciente	paciente {"nombre": "Yolanda Preciado Ibarra", "id_paciente": 20, "area_ingreso": "Oncología", "expediente_folio": "EXP-000142"}	\N	{"nombre": "Yolanda Preciado Ibarra", "id_paciente": 20, "area_ingreso": "Oncología", "expediente_folio": "EXP-000142"}	2026-11-17 18:05:30.454005-06	192.168.1.101
133	1	INSERT	paciente	paciente {"nombre": "Cristian Orozco Zamora", "id_paciente": 21, "area_ingreso": "Quirófano", "expediente_folio": "EXP-000143"}	\N	{"nombre": "Cristian Orozco Zamora", "id_paciente": 21, "area_ingreso": "Quirófano", "expediente_folio": "EXP-000143"}	2026-11-17 18:05:30.454005-06	192.168.1.101
134	1	INSERT	paciente	paciente {"nombre": "Brenda Michelle Lugo Ávila", "id_paciente": 22, "area_ingreso": "Pediatría", "expediente_folio": "EXP-000144"}	\N	{"nombre": "Brenda Michelle Lugo Ávila", "id_paciente": 22, "area_ingreso": "Pediatría", "expediente_folio": "EXP-000144"}	2026-11-17 18:05:30.454005-06	192.168.1.101
135	1	INSERT	paciente	paciente {"nombre": "Armando Delgadillo Rubio", "id_paciente": 23, "area_ingreso": "Hospitalización", "expediente_folio": "EXP-000145"}	\N	{"nombre": "Armando Delgadillo Rubio", "id_paciente": 23, "area_ingreso": "Hospitalización", "expediente_folio": "EXP-000145"}	2026-11-17 18:05:30.454005-06	192.168.1.101
136	1	INSERT	paciente	paciente {"nombre": "Itzel Nayeli Corona Sáenz", "id_paciente": 24, "area_ingreso": "Tococirugía", "expediente_folio": "EXP-000146"}	\N	{"nombre": "Itzel Nayeli Corona Sáenz", "id_paciente": 24, "area_ingreso": "Tococirugía", "expediente_folio": "EXP-000146"}	2026-11-17 18:05:30.454005-06	192.168.1.101
137	1	INSERT	paciente	paciente {"nombre": "Óscar Rafael Meza Bustos", "id_paciente": 25, "area_ingreso": "Urgencias", "expediente_folio": "EXP-000147"}	\N	{"nombre": "Óscar Rafael Meza Bustos", "id_paciente": 25, "area_ingreso": "Urgencias", "expediente_folio": "EXP-000147"}	2026-11-17 18:05:30.454005-06	192.168.1.101
138	1	INSERT	paciente	paciente {"nombre": "Verónica Tapia Campos", "id_paciente": 26, "area_ingreso": "Hospitalización", "expediente_folio": "EXP-000148"}	\N	{"nombre": "Verónica Tapia Campos", "id_paciente": 26, "area_ingreso": "Hospitalización", "expediente_folio": "EXP-000148"}	2026-11-17 18:05:30.454005-06	192.168.1.101
139	1	INSERT	lote	lote {"id_lote": 6, "id_insumo": 5, "numero_lote": "#LOT-2026-1101", "id_proveedor": 3, "fecha_caducidad": "2027-08-24", "precio_unitario": 48.00, "fecha_fabricacion": "2025-03-07"}	\N	{"id_lote": 6, "id_insumo": 5, "numero_lote": "#LOT-2026-1101", "id_proveedor": 3, "fecha_caducidad": "2027-08-24", "precio_unitario": 48.00, "fecha_fabricacion": "2025-03-07"}	2026-11-17 18:05:30.454005-06	192.168.1.101
140	1	INSERT	lote	lote {"id_lote": 7, "id_insumo": 5, "numero_lote": "#LOT-2025-0944", "id_proveedor": 3, "fecha_caducidad": "2027-01-14", "precio_unitario": 48.00, "fecha_fabricacion": "2024-07-28"}	\N	{"id_lote": 7, "id_insumo": 5, "numero_lote": "#LOT-2025-0944", "id_proveedor": 3, "fecha_caducidad": "2027-01-14", "precio_unitario": 48.00, "fecha_fabricacion": "2024-07-28"}	2026-11-17 18:05:30.454005-06	192.168.1.101
141	1	INSERT	lote	lote {"id_lote": 8, "id_insumo": 6, "numero_lote": "#LOT-2026-1102", "id_proveedor": 3, "fecha_caducidad": "2027-09-13", "precio_unitario": 36.00, "fecha_fabricacion": "2025-03-27"}	\N	{"id_lote": 8, "id_insumo": 6, "numero_lote": "#LOT-2026-1102", "id_proveedor": 3, "fecha_caducidad": "2027-09-13", "precio_unitario": 36.00, "fecha_fabricacion": "2025-03-27"}	2026-11-17 18:05:30.454005-06	192.168.1.101
142	1	INSERT	lote	lote {"id_lote": 9, "id_insumo": 7, "numero_lote": "#LOT-2026-1103", "id_proveedor": 2, "fecha_caducidad": "2027-11-02", "precio_unitario": 190.00, "fecha_fabricacion": "2025-05-16"}	\N	{"id_lote": 9, "id_insumo": 7, "numero_lote": "#LOT-2026-1103", "id_proveedor": 2, "fecha_caducidad": "2027-11-02", "precio_unitario": 190.00, "fecha_fabricacion": "2025-05-16"}	2026-11-17 18:05:30.454005-06	192.168.1.101
143	1	INSERT	lote	lote {"id_lote": 10, "id_insumo": 8, "numero_lote": "#LOT-2025-1004", "id_proveedor": 3, "fecha_caducidad": "2026-12-11", "precio_unitario": 22.00, "fecha_fabricacion": "2024-06-24"}	\N	{"id_lote": 10, "id_insumo": 8, "numero_lote": "#LOT-2025-1004", "id_proveedor": 3, "fecha_caducidad": "2026-12-11", "precio_unitario": 22.00, "fecha_fabricacion": "2024-06-24"}	2026-11-17 18:05:30.454005-06	192.168.1.101
144	1	INSERT	lote	lote {"id_lote": 11, "id_insumo": 8, "numero_lote": "#LOT-2026-1104", "id_proveedor": 3, "fecha_caducidad": "2027-12-22", "precio_unitario": 22.00, "fecha_fabricacion": "2025-07-05"}	\N	{"id_lote": 11, "id_insumo": 8, "numero_lote": "#LOT-2026-1104", "id_proveedor": 3, "fecha_caducidad": "2027-12-22", "precio_unitario": 22.00, "fecha_fabricacion": "2025-07-05"}	2026-11-17 18:05:30.454005-06	192.168.1.101
145	1	INSERT	lote	lote {"id_lote": 12, "id_insumo": 9, "numero_lote": "#LOT-2026-1105", "id_proveedor": 3, "fecha_caducidad": "2027-08-04", "precio_unitario": 160.00, "fecha_fabricacion": "2025-02-15"}	\N	{"id_lote": 12, "id_insumo": 9, "numero_lote": "#LOT-2026-1105", "id_proveedor": 3, "fecha_caducidad": "2027-08-04", "precio_unitario": 160.00, "fecha_fabricacion": "2025-02-15"}	2026-11-17 18:05:30.454005-06	192.168.1.101
146	1	INSERT	lote	lote {"id_lote": 13, "id_insumo": 10, "numero_lote": "#LOT-2026-1106", "id_proveedor": 7, "fecha_caducidad": "2027-04-16", "precio_unitario": 64.00, "fecha_fabricacion": "2024-10-28"}	\N	{"id_lote": 13, "id_insumo": 10, "numero_lote": "#LOT-2026-1106", "id_proveedor": 7, "fecha_caducidad": "2027-04-16", "precio_unitario": 64.00, "fecha_fabricacion": "2024-10-28"}	2026-11-17 18:05:30.454005-06	192.168.1.101
147	1	INSERT	lote	lote {"id_lote": 14, "id_insumo": 11, "numero_lote": "#LOT-2026-1107", "id_proveedor": 2, "fecha_caducidad": "2027-10-03", "precio_unitario": 58.00, "fecha_fabricacion": "2025-04-16"}	\N	{"id_lote": 14, "id_insumo": 11, "numero_lote": "#LOT-2026-1107", "id_proveedor": 2, "fecha_caducidad": "2027-10-03", "precio_unitario": 58.00, "fecha_fabricacion": "2025-04-16"}	2026-11-17 18:05:30.454005-06	192.168.1.101
148	1	INSERT	lote	lote {"id_lote": 15, "id_insumo": 12, "numero_lote": "#LOT-2025-1008", "id_proveedor": 4, "fecha_caducidad": "2026-11-18", "precio_unitario": 12.00, "fecha_fabricacion": "2024-05-25"}	\N	{"id_lote": 15, "id_insumo": 12, "numero_lote": "#LOT-2025-1008", "id_proveedor": 4, "fecha_caducidad": "2026-11-18", "precio_unitario": 12.00, "fecha_fabricacion": "2024-05-25"}	2026-11-17 18:05:30.454005-06	192.168.1.101
149	1	INSERT	lote	lote {"id_lote": 16, "id_insumo": 12, "numero_lote": "#LOT-2026-1108", "id_proveedor": 4, "fecha_caducidad": "2027-06-15", "precio_unitario": 12.00, "fecha_fabricacion": "2024-12-27"}	\N	{"id_lote": 16, "id_insumo": 12, "numero_lote": "#LOT-2026-1108", "id_proveedor": 4, "fecha_caducidad": "2027-06-15", "precio_unitario": 12.00, "fecha_fabricacion": "2024-12-27"}	2026-11-17 18:05:30.454005-06	192.168.1.101
150	1	INSERT	lote	lote {"id_lote": 17, "id_insumo": 13, "numero_lote": "#LOT-2026-1109", "id_proveedor": 2, "fecha_caducidad": "2026-12-28", "precio_unitario": 9.80, "fecha_fabricacion": "2024-07-11"}	\N	{"id_lote": 17, "id_insumo": 13, "numero_lote": "#LOT-2026-1109", "id_proveedor": 2, "fecha_caducidad": "2026-12-28", "precio_unitario": 9.80, "fecha_fabricacion": "2024-07-11"}	2026-11-17 18:05:30.454005-06	192.168.1.101
151	1	INSERT	lote	lote {"id_lote": 18, "id_insumo": 13, "numero_lote": "#LOT-2026-1209", "id_proveedor": 2, "fecha_caducidad": "2027-11-17", "precio_unitario": 9.80, "fecha_fabricacion": "2025-05-31"}	\N	{"id_lote": 18, "id_insumo": 13, "numero_lote": "#LOT-2026-1209", "id_proveedor": 2, "fecha_caducidad": "2027-11-17", "precio_unitario": 9.80, "fecha_fabricacion": "2025-05-31"}	2026-11-17 18:05:30.454005-06	192.168.1.101
152	1	INSERT	lote	lote {"id_lote": 19, "id_insumo": 14, "numero_lote": "#LOT-2026-1110", "id_proveedor": 2, "fecha_caducidad": "2026-11-29", "precio_unitario": 14.00, "fecha_fabricacion": "2024-06-12"}	\N	{"id_lote": 19, "id_insumo": 14, "numero_lote": "#LOT-2026-1110", "id_proveedor": 2, "fecha_caducidad": "2026-11-29", "precio_unitario": 14.00, "fecha_fabricacion": "2024-06-12"}	2026-11-17 18:05:30.454005-06	192.168.1.101
153	1	INSERT	lote	lote {"id_lote": 20, "id_insumo": 14, "numero_lote": "#LOT-2026-1210", "id_proveedor": 2, "fecha_caducidad": "2027-09-13", "precio_unitario": 14.00, "fecha_fabricacion": "2025-03-27"}	\N	{"id_lote": 20, "id_insumo": 14, "numero_lote": "#LOT-2026-1210", "id_proveedor": 2, "fecha_caducidad": "2027-09-13", "precio_unitario": 14.00, "fecha_fabricacion": "2025-03-27"}	2026-11-17 18:05:30.454005-06	192.168.1.101
154	1	INSERT	lote	lote {"id_lote": 21, "id_insumo": 15, "numero_lote": "#LOT-2026-1111", "id_proveedor": 4, "fecha_caducidad": "2026-12-12", "precio_unitario": 8.00, "fecha_fabricacion": "2024-06-25"}	\N	{"id_lote": 21, "id_insumo": 15, "numero_lote": "#LOT-2026-1111", "id_proveedor": 4, "fecha_caducidad": "2026-12-12", "precio_unitario": 8.00, "fecha_fabricacion": "2024-06-25"}	2026-11-17 18:05:30.454005-06	192.168.1.101
155	1	INSERT	lote	lote {"id_lote": 22, "id_insumo": 15, "numero_lote": "#LOT-2026-1211", "id_proveedor": 4, "fecha_caducidad": "2027-08-24", "precio_unitario": 8.00, "fecha_fabricacion": "2025-03-07"}	\N	{"id_lote": 22, "id_insumo": 15, "numero_lote": "#LOT-2026-1211", "id_proveedor": 4, "fecha_caducidad": "2027-08-24", "precio_unitario": 8.00, "fecha_fabricacion": "2025-03-07"}	2026-11-17 18:05:30.454005-06	192.168.1.101
156	1	INSERT	lote	lote {"id_lote": 23, "id_insumo": 16, "numero_lote": "#LOT-2026-1112", "id_proveedor": 5, "fecha_caducidad": "2027-10-13", "precio_unitario": 21.00, "fecha_fabricacion": "2025-04-26"}	\N	{"id_lote": 23, "id_insumo": 16, "numero_lote": "#LOT-2026-1112", "id_proveedor": 5, "fecha_caducidad": "2027-10-13", "precio_unitario": 21.00, "fecha_fabricacion": "2025-04-26"}	2026-11-17 18:05:30.454005-06	192.168.1.101
157	1	INSERT	lote	lote {"id_lote": 24, "id_insumo": 17, "numero_lote": "#LOT-2025-1013", "id_proveedor": 5, "fecha_caducidad": "2026-11-18", "precio_unitario": 18.00, "fecha_fabricacion": "2024-05-12"}	\N	{"id_lote": 24, "id_insumo": 17, "numero_lote": "#LOT-2025-1013", "id_proveedor": 5, "fecha_caducidad": "2026-11-18", "precio_unitario": 18.00, "fecha_fabricacion": "2024-05-12"}	2026-11-17 18:05:30.454005-06	192.168.1.101
158	1	INSERT	lote	lote {"id_lote": 25, "id_insumo": 17, "numero_lote": "#LOT-2026-1113", "id_proveedor": 5, "fecha_caducidad": "2027-08-14", "precio_unitario": 18.00, "fecha_fabricacion": "2025-02-25"}	\N	{"id_lote": 25, "id_insumo": 17, "numero_lote": "#LOT-2026-1113", "id_proveedor": 5, "fecha_caducidad": "2027-08-14", "precio_unitario": 18.00, "fecha_fabricacion": "2025-02-25"}	2026-11-17 18:05:30.454005-06	192.168.1.101
159	1	INSERT	lote	lote {"id_lote": 26, "id_insumo": 18, "numero_lote": "#LOT-2026-1114", "id_proveedor": 5, "fecha_caducidad": "2027-07-15", "precio_unitario": 46.00, "fecha_fabricacion": "2025-01-26"}	\N	{"id_lote": 26, "id_insumo": 18, "numero_lote": "#LOT-2026-1114", "id_proveedor": 5, "fecha_caducidad": "2027-07-15", "precio_unitario": 46.00, "fecha_fabricacion": "2025-01-26"}	2026-11-17 18:05:30.454005-06	192.168.1.101
160	1	INSERT	lote	lote {"id_lote": 27, "id_insumo": 19, "numero_lote": "#LOT-2026-1115", "id_proveedor": 5, "fecha_caducidad": "2027-06-05", "precio_unitario": 95.00, "fecha_fabricacion": "2024-12-17"}	\N	{"id_lote": 27, "id_insumo": 19, "numero_lote": "#LOT-2026-1115", "id_proveedor": 5, "fecha_caducidad": "2027-06-05", "precio_unitario": 95.00, "fecha_fabricacion": "2024-12-17"}	2026-11-17 18:05:30.454005-06	192.168.1.101
161	1	INSERT	lote	lote {"id_lote": 28, "id_insumo": 20, "numero_lote": "#LOT-2026-1116", "id_proveedor": 2, "fecha_caducidad": "2027-05-26", "precio_unitario": 35.00, "fecha_fabricacion": "2024-12-07"}	\N	{"id_lote": 28, "id_insumo": 20, "numero_lote": "#LOT-2026-1116", "id_proveedor": 2, "fecha_caducidad": "2027-05-26", "precio_unitario": 35.00, "fecha_fabricacion": "2024-12-07"}	2026-11-17 18:05:30.454005-06	192.168.1.101
162	1	INSERT	lote	lote {"id_lote": 29, "id_insumo": 21, "numero_lote": "#LOT-2026-1117", "id_proveedor": 2, "fecha_caducidad": "2027-05-11", "precio_unitario": 28.00, "fecha_fabricacion": "2024-11-22"}	\N	{"id_lote": 29, "id_insumo": 21, "numero_lote": "#LOT-2026-1117", "id_proveedor": 2, "fecha_caducidad": "2027-05-11", "precio_unitario": 28.00, "fecha_fabricacion": "2024-11-22"}	2026-11-17 18:05:30.454005-06	192.168.1.101
163	1	INSERT	lote	lote {"id_lote": 30, "id_insumo": 22, "numero_lote": "#LOT-2026-1118", "id_proveedor": 4, "fecha_caducidad": "2027-06-25", "precio_unitario": 12.00, "fecha_fabricacion": "2025-01-06"}	\N	{"id_lote": 30, "id_insumo": 22, "numero_lote": "#LOT-2026-1118", "id_proveedor": 4, "fecha_caducidad": "2027-06-25", "precio_unitario": 12.00, "fecha_fabricacion": "2025-01-06"}	2026-11-17 18:05:30.454005-06	192.168.1.101
164	1	INSERT	lote	lote {"id_lote": 31, "id_insumo": 23, "numero_lote": "#LOT-2026-1119", "id_proveedor": 4, "fecha_caducidad": "2027-06-10", "precio_unitario": 15.00, "fecha_fabricacion": "2024-12-22"}	\N	{"id_lote": 31, "id_insumo": 23, "numero_lote": "#LOT-2026-1119", "id_proveedor": 4, "fecha_caducidad": "2027-06-10", "precio_unitario": 15.00, "fecha_fabricacion": "2024-12-22"}	2026-11-17 18:05:30.454005-06	192.168.1.101
165	1	INSERT	lote	lote {"id_lote": 32, "id_insumo": 24, "numero_lote": "#LOT-2026-1120", "id_proveedor": 6, "fecha_caducidad": "2027-01-28", "precio_unitario": 62.00, "fecha_fabricacion": "2024-08-11"}	\N	{"id_lote": 32, "id_insumo": 24, "numero_lote": "#LOT-2026-1120", "id_proveedor": 6, "fecha_caducidad": "2027-01-28", "precio_unitario": 62.00, "fecha_fabricacion": "2024-08-11"}	2026-11-17 18:05:30.454005-06	192.168.1.101
166	1	INSERT	lote	lote {"id_lote": 33, "id_insumo": 25, "numero_lote": "#LOT-2026-1121", "id_proveedor": 6, "fecha_caducidad": "2027-08-04", "precio_unitario": 54.00, "fecha_fabricacion": "2025-02-15"}	\N	{"id_lote": 33, "id_insumo": 25, "numero_lote": "#LOT-2026-1121", "id_proveedor": 6, "fecha_caducidad": "2027-08-04", "precio_unitario": 54.00, "fecha_fabricacion": "2025-02-15"}	2026-11-17 18:05:30.454005-06	192.168.1.101
167	1	INSERT	lote	lote {"id_lote": 34, "id_insumo": 26, "numero_lote": "#LOT-2026-1122", "id_proveedor": 2, "fecha_caducidad": "2027-01-11", "precio_unitario": 7.00, "fecha_fabricacion": "2024-07-25"}	\N	{"id_lote": 34, "id_insumo": 26, "numero_lote": "#LOT-2026-1122", "id_proveedor": 2, "fecha_caducidad": "2027-01-11", "precio_unitario": 7.00, "fecha_fabricacion": "2024-07-25"}	2026-11-17 18:05:30.454005-06	192.168.1.101
168	1	INSERT	lote	lote {"id_lote": 35, "id_insumo": 27, "numero_lote": "#LOT-2026-1123", "id_proveedor": 6, "fecha_caducidad": "2027-09-23", "precio_unitario": 38.00, "fecha_fabricacion": "2025-04-06"}	\N	{"id_lote": 35, "id_insumo": 27, "numero_lote": "#LOT-2026-1123", "id_proveedor": 6, "fecha_caducidad": "2027-09-23", "precio_unitario": 38.00, "fecha_fabricacion": "2025-04-06"}	2026-11-17 18:05:30.454005-06	192.168.1.101
169	1	INSERT	lote	lote {"id_lote": 36, "id_insumo": 28, "numero_lote": "#LOT-2026-1124", "id_proveedor": 6, "fecha_caducidad": "2027-11-12", "precio_unitario": 78.00, "fecha_fabricacion": "2025-05-26"}	\N	{"id_lote": 36, "id_insumo": 28, "numero_lote": "#LOT-2026-1124", "id_proveedor": 6, "fecha_caducidad": "2027-11-12", "precio_unitario": 78.00, "fecha_fabricacion": "2025-05-26"}	2026-11-17 18:05:30.454005-06	192.168.1.101
170	1	INSERT	lote	lote {"id_lote": 37, "id_insumo": 29, "numero_lote": "#LOT-2026-1125", "id_proveedor": 4, "fecha_caducidad": "2027-10-13", "precio_unitario": 17.00, "fecha_fabricacion": "2025-04-26"}	\N	{"id_lote": 37, "id_insumo": 29, "numero_lote": "#LOT-2026-1125", "id_proveedor": 4, "fecha_caducidad": "2027-10-13", "precio_unitario": 17.00, "fecha_fabricacion": "2025-04-26"}	2026-11-17 18:05:30.454005-06	192.168.1.101
171	1	INSERT	lote	lote {"id_lote": 38, "id_insumo": 30, "numero_lote": "#LOT-2026-1126", "id_proveedor": 4, "fecha_caducidad": "2026-12-15", "precio_unitario": 21.00, "fecha_fabricacion": "2024-06-28"}	\N	{"id_lote": 38, "id_insumo": 30, "numero_lote": "#LOT-2026-1126", "id_proveedor": 4, "fecha_caducidad": "2026-12-15", "precio_unitario": 21.00, "fecha_fabricacion": "2024-06-28"}	2026-11-17 18:05:30.454005-06	192.168.1.101
172	1	INSERT	lote	lote {"id_lote": 39, "id_insumo": 30, "numero_lote": "#LOT-2026-1226", "id_proveedor": 4, "fecha_caducidad": "2027-10-23", "precio_unitario": 21.00, "fecha_fabricacion": "2025-05-06"}	\N	{"id_lote": 39, "id_insumo": 30, "numero_lote": "#LOT-2026-1226", "id_proveedor": 4, "fecha_caducidad": "2027-10-23", "precio_unitario": 21.00, "fecha_fabricacion": "2025-05-06"}	2026-11-17 18:05:30.454005-06	192.168.1.101
173	1	INSERT	lote	lote {"id_lote": 40, "id_insumo": 31, "numero_lote": "#LOT-2026-1127", "id_proveedor": 4, "fecha_caducidad": "2027-01-04", "precio_unitario": 19.00, "fecha_fabricacion": "2024-07-18"}	\N	{"id_lote": 40, "id_insumo": 31, "numero_lote": "#LOT-2026-1127", "id_proveedor": 4, "fecha_caducidad": "2027-01-04", "precio_unitario": 19.00, "fecha_fabricacion": "2024-07-18"}	2026-11-17 18:05:30.454005-06	192.168.1.101
174	1	INSERT	lote	lote {"id_lote": 41, "id_insumo": 32, "numero_lote": "#LOT-2026-1128", "id_proveedor": 7, "fecha_caducidad": "2027-04-06", "precio_unitario": 190.00, "fecha_fabricacion": "2024-10-18"}	\N	{"id_lote": 41, "id_insumo": 32, "numero_lote": "#LOT-2026-1128", "id_proveedor": 7, "fecha_caducidad": "2027-04-06", "precio_unitario": 190.00, "fecha_fabricacion": "2024-10-18"}	2026-11-17 18:05:30.454005-06	192.168.1.101
175	1	INSERT	lote	lote {"id_lote": 42, "id_insumo": 33, "numero_lote": "#LOT-2026-1129", "id_proveedor": 7, "fecha_caducidad": "2027-06-15", "precio_unitario": 410.00, "fecha_fabricacion": "2024-12-27"}	\N	{"id_lote": 42, "id_insumo": 33, "numero_lote": "#LOT-2026-1129", "id_proveedor": 7, "fecha_caducidad": "2027-06-15", "precio_unitario": 410.00, "fecha_fabricacion": "2024-12-27"}	2026-11-17 18:05:30.454005-06	192.168.1.101
176	1	INSERT	lote	lote {"id_lote": 43, "id_insumo": 34, "numero_lote": "#LOT-2026-1130", "id_proveedor": 2, "fecha_caducidad": "2027-02-10", "precio_unitario": 29.00, "fecha_fabricacion": "2024-08-24"}	\N	{"id_lote": 43, "id_insumo": 34, "numero_lote": "#LOT-2026-1130", "id_proveedor": 2, "fecha_caducidad": "2027-02-10", "precio_unitario": 29.00, "fecha_fabricacion": "2024-08-24"}	2026-11-17 18:05:30.454005-06	192.168.1.101
177	1	INSERT	lote	lote {"id_lote": 44, "id_insumo": 35, "numero_lote": "#LOT-2026-1131", "id_proveedor": 5, "fecha_caducidad": "2027-12-22", "precio_unitario": 88.00, "fecha_fabricacion": "2025-07-05"}	\N	{"id_lote": 44, "id_insumo": 35, "numero_lote": "#LOT-2026-1131", "id_proveedor": 5, "fecha_caducidad": "2027-12-22", "precio_unitario": 88.00, "fecha_fabricacion": "2025-07-05"}	2026-11-17 18:05:30.454005-06	192.168.1.101
178	1	INSERT	lote	lote {"id_lote": 45, "id_insumo": 36, "numero_lote": "#LOT-2026-1132", "id_proveedor": 7, "fecha_caducidad": "2026-11-26", "precio_unitario": 16.00, "fecha_fabricacion": "2024-06-09"}	\N	{"id_lote": 45, "id_insumo": 36, "numero_lote": "#LOT-2026-1132", "id_proveedor": 7, "fecha_caducidad": "2026-11-26", "precio_unitario": 16.00, "fecha_fabricacion": "2024-06-09"}	2026-11-17 18:05:30.454005-06	192.168.1.101
179	1	INSERT	lote	lote {"id_lote": 46, "id_insumo": 36, "numero_lote": "#LOT-2026-1232", "id_proveedor": 7, "fecha_caducidad": "2027-03-17", "precio_unitario": 16.00, "fecha_fabricacion": "2024-09-28"}	\N	{"id_lote": 46, "id_insumo": 36, "numero_lote": "#LOT-2026-1232", "id_proveedor": 7, "fecha_caducidad": "2027-03-17", "precio_unitario": 16.00, "fecha_fabricacion": "2024-09-28"}	2026-11-17 18:05:30.454005-06	192.168.1.101
180	1	INSERT	lote	lote {"id_lote": 47, "id_insumo": 37, "numero_lote": "#LOT-2026-1133", "id_proveedor": 2, "fecha_caducidad": "2027-08-14", "precio_unitario": 33.00, "fecha_fabricacion": "2025-02-25"}	\N	{"id_lote": 47, "id_insumo": 37, "numero_lote": "#LOT-2026-1133", "id_proveedor": 2, "fecha_caducidad": "2027-08-14", "precio_unitario": 33.00, "fecha_fabricacion": "2025-02-25"}	2026-11-17 18:05:30.454005-06	192.168.1.101
181	1	INSERT	lote	lote {"id_lote": 48, "id_insumo": 38, "numero_lote": "#LOT-2026-1134", "id_proveedor": 3, "fecha_caducidad": "2027-07-05", "precio_unitario": 120.00, "fecha_fabricacion": "2025-01-16"}	\N	{"id_lote": 48, "id_insumo": 38, "numero_lote": "#LOT-2026-1134", "id_proveedor": 3, "fecha_caducidad": "2027-07-05", "precio_unitario": 120.00, "fecha_fabricacion": "2025-01-16"}	2026-11-17 18:05:30.454005-06	192.168.1.101
182	1	INSERT	lote	lote {"id_lote": 49, "id_insumo": 39, "numero_lote": "#LOT-2026-1135", "id_proveedor": 2, "fecha_caducidad": "2027-07-25", "precio_unitario": 22.00, "fecha_fabricacion": "2025-02-05"}	\N	{"id_lote": 49, "id_insumo": 39, "numero_lote": "#LOT-2026-1135", "id_proveedor": 2, "fecha_caducidad": "2027-07-25", "precio_unitario": 22.00, "fecha_fabricacion": "2025-02-05"}	2026-11-17 18:05:30.454005-06	192.168.1.101
183	1	INSERT	lote	lote {"id_lote": 50, "id_insumo": 4, "numero_lote": "#LOT-2026-0612", "id_proveedor": 1, "fecha_caducidad": "2027-01-31", "precio_unitario": 35.00, "fecha_fabricacion": "2024-08-14"}	\N	{"id_lote": 50, "id_insumo": 4, "numero_lote": "#LOT-2026-0612", "id_proveedor": 1, "fecha_caducidad": "2027-01-31", "precio_unitario": 35.00, "fecha_fabricacion": "2024-08-14"}	2026-11-17 18:05:30.454005-06	192.168.1.101
184	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 6, "cantidad": 20, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 6, "id_usuario": 4, "id_ubicacion": 5}	\N	{"id_lote": 6, "cantidad": 20, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 6, "id_usuario": 4, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.104
185	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 6, "cantidad": 20, "id_ubicacion": 5}	\N	{"id_lote": 6, "cantidad": 20, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.104
186	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 7, "cantidad": 10, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 7, "id_usuario": 1, "id_ubicacion": 5}	\N	{"id_lote": 7, "cantidad": 10, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 7, "id_usuario": 1, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.101
187	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 7, "cantidad": 10, "id_ubicacion": 5}	\N	{"id_lote": 7, "cantidad": 10, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.101
188	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 8, "cantidad": 14, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 8, "id_usuario": 4, "id_ubicacion": 5}	\N	{"id_lote": 8, "cantidad": 14, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 8, "id_usuario": 4, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.104
189	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 8, "cantidad": 14, "id_ubicacion": 5}	\N	{"id_lote": 8, "cantidad": 14, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.104
190	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 8, "cantidad": 10, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 9, "id_usuario": 1, "id_ubicacion": 3}	\N	{"id_lote": 8, "cantidad": 10, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 9, "id_usuario": 1, "id_ubicacion": 3}	2026-11-17 18:05:30.454005-06	192.168.1.101
191	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 8, "cantidad": 10, "id_ubicacion": 3}	\N	{"id_lote": 8, "cantidad": 10, "id_ubicacion": 3}	2026-11-17 18:05:30.454005-06	192.168.1.101
192	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 9, "cantidad": 18, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 10, "id_usuario": 4, "id_ubicacion": 5}	\N	{"id_lote": 9, "cantidad": 18, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 10, "id_usuario": 4, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.104
193	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 9, "cantidad": 18, "id_ubicacion": 5}	\N	{"id_lote": 9, "cantidad": 18, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.104
194	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 10, "cantidad": 12, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 11, "id_usuario": 1, "id_ubicacion": 3}	\N	{"id_lote": 10, "cantidad": 12, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 11, "id_usuario": 1, "id_ubicacion": 3}	2026-11-17 18:05:30.454005-06	192.168.1.101
195	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 10, "cantidad": 12, "id_ubicacion": 3}	\N	{"id_lote": 10, "cantidad": 12, "id_ubicacion": 3}	2026-11-17 18:05:30.454005-06	192.168.1.101
196	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 11, "cantidad": 20, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 12, "id_usuario": 4, "id_ubicacion": 3}	\N	{"id_lote": 11, "cantidad": 20, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 12, "id_usuario": 4, "id_ubicacion": 3}	2026-11-17 18:05:30.454005-06	192.168.1.104
197	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 11, "cantidad": 20, "id_ubicacion": 3}	\N	{"id_lote": 11, "cantidad": 20, "id_ubicacion": 3}	2026-11-17 18:05:30.454005-06	192.168.1.104
198	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 12, "cantidad": 12, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 13, "id_usuario": 1, "id_ubicacion": 5}	\N	{"id_lote": 12, "cantidad": 12, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 13, "id_usuario": 1, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.101
199	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 12, "cantidad": 12, "id_ubicacion": 5}	\N	{"id_lote": 12, "cantidad": 12, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.101
200	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 13, "cantidad": 60, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 14, "id_usuario": 4, "id_ubicacion": 6}	\N	{"id_lote": 13, "cantidad": 60, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 14, "id_usuario": 4, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.104
201	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 13, "cantidad": 60, "id_ubicacion": 6}	\N	{"id_lote": 13, "cantidad": 60, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.104
202	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 14, "cantidad": 40, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 15, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 14, "cantidad": 40, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 15, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
203	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 14, "cantidad": 40, "id_ubicacion": 1}	\N	{"id_lote": 14, "cantidad": 40, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
204	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 14, "cantidad": 12, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 16, "id_usuario": 4, "id_ubicacion": 2}	\N	{"id_lote": 14, "cantidad": 12, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 16, "id_usuario": 4, "id_ubicacion": 2}	2026-11-17 18:05:30.454005-06	192.168.1.104
205	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 14, "cantidad": 12, "id_ubicacion": 2}	\N	{"id_lote": 14, "cantidad": 12, "id_ubicacion": 2}	2026-11-17 18:05:30.454005-06	192.168.1.104
206	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 15, "cantidad": 8, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 17, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 15, "cantidad": 8, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 17, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
207	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 15, "cantidad": 8, "id_ubicacion": 1}	\N	{"id_lote": 15, "cantidad": 8, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
208	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 16, "cantidad": 90, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 18, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 16, "cantidad": 90, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 18, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
209	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 16, "cantidad": 90, "id_ubicacion": 1}	\N	{"id_lote": 16, "cantidad": 90, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
210	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 17, "cantidad": 120, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 19, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 17, "cantidad": 120, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 19, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
211	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 17, "cantidad": 120, "id_ubicacion": 1}	\N	{"id_lote": 17, "cantidad": 120, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
212	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 18, "cantidad": 60, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 20, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 18, "cantidad": 60, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 20, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
213	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 18, "cantidad": 60, "id_ubicacion": 1}	\N	{"id_lote": 18, "cantidad": 60, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
214	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 19, "cantidad": 70, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 21, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 19, "cantidad": 70, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 21, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
215	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 19, "cantidad": 70, "id_ubicacion": 1}	\N	{"id_lote": 19, "cantidad": 70, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
216	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 20, "cantidad": 80, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 22, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 20, "cantidad": 80, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 22, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
217	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 20, "cantidad": 80, "id_ubicacion": 1}	\N	{"id_lote": 20, "cantidad": 80, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
218	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 21, "cantidad": 40, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 23, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 21, "cantidad": 40, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 23, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
219	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 21, "cantidad": 40, "id_ubicacion": 1}	\N	{"id_lote": 21, "cantidad": 40, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
220	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 21, "cantidad": 30, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 24, "id_usuario": 4, "id_ubicacion": 8}	\N	{"id_lote": 21, "cantidad": 30, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 24, "id_usuario": 4, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.104
221	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 21, "cantidad": 30, "id_ubicacion": 8}	\N	{"id_lote": 21, "cantidad": 30, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.104
222	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 22, "cantidad": 60, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 25, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 22, "cantidad": 60, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 25, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
223	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 22, "cantidad": 60, "id_ubicacion": 1}	\N	{"id_lote": 22, "cantidad": 60, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
224	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 23, "cantidad": 150, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 26, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 23, "cantidad": 150, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 26, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
225	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 23, "cantidad": 150, "id_ubicacion": 1}	\N	{"id_lote": 23, "cantidad": 150, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
226	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 23, "cantidad": 60, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 27, "id_usuario": 1, "id_ubicacion": 9}	\N	{"id_lote": 23, "cantidad": 60, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 27, "id_usuario": 1, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.101
228	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 24, "cantidad": 15, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 28, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 24, "cantidad": 15, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 28, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
229	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 24, "cantidad": 15, "id_ubicacion": 1}	\N	{"id_lote": 24, "cantidad": 15, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
230	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 25, "cantidad": 85, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 29, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 25, "cantidad": 85, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 29, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
231	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 25, "cantidad": 85, "id_ubicacion": 1}	\N	{"id_lote": 25, "cantidad": 85, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
232	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 26, "cantidad": 30, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 30, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 26, "cantidad": 30, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 30, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
233	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 26, "cantidad": 30, "id_ubicacion": 1}	\N	{"id_lote": 26, "cantidad": 30, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
234	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 27, "cantidad": 20, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 31, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 27, "cantidad": 20, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 31, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
235	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 27, "cantidad": 20, "id_ubicacion": 1}	\N	{"id_lote": 27, "cantidad": 20, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
236	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 28, "cantidad": 90, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 32, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 28, "cantidad": 90, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 32, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
237	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 28, "cantidad": 90, "id_ubicacion": 1}	\N	{"id_lote": 28, "cantidad": 90, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
238	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 29, "cantidad": 100, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 33, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 29, "cantidad": 100, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 33, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
239	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 29, "cantidad": 100, "id_ubicacion": 1}	\N	{"id_lote": 29, "cantidad": 100, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
240	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 30, "cantidad": 40, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 34, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 30, "cantidad": 40, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 34, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
241	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 30, "cantidad": 40, "id_ubicacion": 1}	\N	{"id_lote": 30, "cantidad": 40, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
242	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 30, "cantidad": 20, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 35, "id_usuario": 1, "id_ubicacion": 8}	\N	{"id_lote": 30, "cantidad": 20, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 35, "id_usuario": 1, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.101
243	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 30, "cantidad": 20, "id_ubicacion": 8}	\N	{"id_lote": 30, "cantidad": 20, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.101
244	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 30, "cantidad": 8, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 36, "id_usuario": 4, "id_ubicacion": 2}	\N	{"id_lote": 30, "cantidad": 8, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 36, "id_usuario": 4, "id_ubicacion": 2}	2026-11-17 18:05:30.454005-06	192.168.1.104
245	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 30, "cantidad": 8, "id_ubicacion": 2}	\N	{"id_lote": 30, "cantidad": 8, "id_ubicacion": 2}	2026-11-17 18:05:30.454005-06	192.168.1.104
246	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 31, "cantidad": 50, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 37, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 31, "cantidad": 50, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 37, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
247	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 31, "cantidad": 50, "id_ubicacion": 1}	\N	{"id_lote": 31, "cantidad": 50, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
248	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 32, "cantidad": 45, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 38, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 32, "cantidad": 45, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 38, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
249	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 32, "cantidad": 45, "id_ubicacion": 1}	\N	{"id_lote": 32, "cantidad": 45, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
250	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 33, "cantidad": 20, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 39, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 33, "cantidad": 20, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 39, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
251	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 33, "cantidad": 20, "id_ubicacion": 1}	\N	{"id_lote": 33, "cantidad": 20, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
252	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 33, "cantidad": 10, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 40, "id_usuario": 4, "id_ubicacion": 7}	\N	{"id_lote": 33, "cantidad": 10, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 40, "id_usuario": 4, "id_ubicacion": 7}	2026-11-17 18:05:30.454005-06	192.168.1.104
253	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 33, "cantidad": 10, "id_ubicacion": 7}	\N	{"id_lote": 33, "cantidad": 10, "id_ubicacion": 7}	2026-11-17 18:05:30.454005-06	192.168.1.104
254	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 34, "cantidad": 70, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 41, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 34, "cantidad": 70, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 41, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
255	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 34, "cantidad": 70, "id_ubicacion": 1}	\N	{"id_lote": 34, "cantidad": 70, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
256	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 35, "cantidad": 64, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 42, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 35, "cantidad": 64, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 42, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
257	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 35, "cantidad": 64, "id_ubicacion": 1}	\N	{"id_lote": 35, "cantidad": 64, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
258	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 36, "cantidad": 150, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 43, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 36, "cantidad": 150, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 43, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
259	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 36, "cantidad": 150, "id_ubicacion": 1}	\N	{"id_lote": 36, "cantidad": 150, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
260	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 37, "cantidad": 600, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 44, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 37, "cantidad": 600, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 44, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
261	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 37, "cantidad": 600, "id_ubicacion": 1}	\N	{"id_lote": 37, "cantidad": 600, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
262	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 38, "cantidad": 180, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 45, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 38, "cantidad": 180, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 45, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
263	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 38, "cantidad": 180, "id_ubicacion": 1}	\N	{"id_lote": 38, "cantidad": 180, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
264	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 39, "cantidad": 220, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 46, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 39, "cantidad": 220, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 46, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
265	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 39, "cantidad": 220, "id_ubicacion": 1}	\N	{"id_lote": 39, "cantidad": 220, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
266	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 40, "cantidad": 160, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 47, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 40, "cantidad": 160, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 47, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
267	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 40, "cantidad": 160, "id_ubicacion": 1}	\N	{"id_lote": 40, "cantidad": 160, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
268	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 41, "cantidad": 24, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 48, "id_usuario": 4, "id_ubicacion": 4}	\N	{"id_lote": 41, "cantidad": 24, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 48, "id_usuario": 4, "id_ubicacion": 4}	2026-11-17 18:05:30.454005-06	192.168.1.104
269	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 41, "cantidad": 24, "id_ubicacion": 4}	\N	{"id_lote": 41, "cantidad": 24, "id_ubicacion": 4}	2026-11-17 18:05:30.454005-06	192.168.1.104
270	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 42, "cantidad": 16, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 49, "id_usuario": 1, "id_ubicacion": 6}	\N	{"id_lote": 42, "cantidad": 16, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 49, "id_usuario": 1, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.101
271	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 42, "cantidad": 16, "id_ubicacion": 6}	\N	{"id_lote": 42, "cantidad": 16, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.101
272	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 43, "cantidad": 70, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 50, "id_usuario": 4, "id_ubicacion": 1}	\N	{"id_lote": 43, "cantidad": 70, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 50, "id_usuario": 4, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
273	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 43, "cantidad": 70, "id_ubicacion": 1}	\N	{"id_lote": 43, "cantidad": 70, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
274	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 44, "cantidad": 60, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 51, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 44, "cantidad": 60, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 51, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
275	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 44, "cantidad": 60, "id_ubicacion": 1}	\N	{"id_lote": 44, "cantidad": 60, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
276	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 45, "cantidad": 36, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 52, "id_usuario": 4, "id_ubicacion": 6}	\N	{"id_lote": 45, "cantidad": 36, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 52, "id_usuario": 4, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.104
277	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 45, "cantidad": 36, "id_ubicacion": 6}	\N	{"id_lote": 45, "cantidad": 36, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.104
278	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 45, "cantidad": 12, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 53, "id_usuario": 1, "id_ubicacion": 12}	\N	{"id_lote": 45, "cantidad": 12, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 53, "id_usuario": 1, "id_ubicacion": 12}	2026-11-17 18:05:30.454005-06	192.168.1.101
279	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 45, "cantidad": 12, "id_ubicacion": 12}	\N	{"id_lote": 45, "cantidad": 12, "id_ubicacion": 12}	2026-11-17 18:05:30.454005-06	192.168.1.101
280	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 46, "cantidad": 40, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 54, "id_usuario": 4, "id_ubicacion": 6}	\N	{"id_lote": 46, "cantidad": 40, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 54, "id_usuario": 4, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.104
281	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 46, "cantidad": 40, "id_ubicacion": 6}	\N	{"id_lote": 46, "cantidad": 40, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.104
282	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 47, "cantidad": 40, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 55, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 47, "cantidad": 40, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 55, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
283	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 47, "cantidad": 40, "id_ubicacion": 1}	\N	{"id_lote": 47, "cantidad": 40, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
284	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 48, "cantidad": 8, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 56, "id_usuario": 4, "id_ubicacion": 8}	\N	{"id_lote": 48, "cantidad": 8, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 56, "id_usuario": 4, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.104
285	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 48, "cantidad": 8, "id_ubicacion": 8}	\N	{"id_lote": 48, "cantidad": 8, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.104
286	1	INSERT	entrada_inventario	entrada_inventario {"id_lote": 49, "cantidad": 45, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 57, "id_usuario": 1, "id_ubicacion": 1}	\N	{"id_lote": 49, "cantidad": 45, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 57, "id_usuario": 1, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
287	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 49, "cantidad": 45, "id_ubicacion": 1}	\N	{"id_lote": 49, "cantidad": 45, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
288	4	INSERT	entrada_inventario	entrada_inventario {"id_lote": 50, "cantidad": 150, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 58, "id_usuario": 4, "id_ubicacion": 9}	\N	{"id_lote": 50, "cantidad": 150, "fecha_hora": "2026-11-17T18:05:30.454005-06:00", "id_entrada": 58, "id_usuario": 4, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.104
289	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 50, "cantidad": 150, "id_ubicacion": 9}	\N	{"id_lote": 50, "cantidad": 150, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.104
290	4	UPDATE	lote	lote {"id_lote": 15, "id_insumo": 12, "numero_lote": "#LOT-2025-1008", "id_proveedor": 4, "fecha_caducidad": "2026-11-11", "precio_unitario": 12.00, "fecha_fabricacion": "2024-05-25"}	{"id_lote": 15, "id_insumo": 12, "numero_lote": "#LOT-2025-1008", "id_proveedor": 4, "fecha_caducidad": "2026-11-18", "precio_unitario": 12.00, "fecha_fabricacion": "2024-05-25"}	{"id_lote": 15, "id_insumo": 12, "numero_lote": "#LOT-2025-1008", "id_proveedor": 4, "fecha_caducidad": "2026-11-11", "precio_unitario": 12.00, "fecha_fabricacion": "2024-05-25"}	2026-11-17 18:05:30.454005-06	192.168.1.104
291	4	UPDATE	lote	lote {"id_lote": 24, "id_insumo": 17, "numero_lote": "#LOT-2025-1013", "id_proveedor": 5, "fecha_caducidad": "2026-10-29", "precio_unitario": 18.00, "fecha_fabricacion": "2024-05-12"}	{"id_lote": 24, "id_insumo": 17, "numero_lote": "#LOT-2025-1013", "id_proveedor": 5, "fecha_caducidad": "2026-11-18", "precio_unitario": 18.00, "fecha_fabricacion": "2024-05-12"}	{"id_lote": 24, "id_insumo": 17, "numero_lote": "#LOT-2025-1013", "id_proveedor": 5, "fecha_caducidad": "2026-10-29", "precio_unitario": 18.00, "fecha_fabricacion": "2024-05-12"}	2026-11-17 18:05:30.454005-06	192.168.1.104
292	1	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 37, "cantidad": 500, "id_ubicacion": 1}	{"id_lote": 37, "cantidad": 600, "id_ubicacion": 1}	{"id_lote": 37, "cantidad": 500, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
293	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 37, "cantidad": 100, "id_ubicacion": 2}	\N	{"id_lote": 37, "cantidad": 100, "id_ubicacion": 2}	2026-11-17 18:05:30.454005-06	192.168.1.101
294	4	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 37, "cantidad": 440, "id_ubicacion": 1}	{"id_lote": 37, "cantidad": 500, "id_ubicacion": 1}	{"id_lote": 37, "cantidad": 440, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
295	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 37, "cantidad": 60, "id_ubicacion": 11}	\N	{"id_lote": 37, "cantidad": 60, "id_ubicacion": 11}	2026-11-17 18:05:30.454005-06	192.168.1.104
296	1	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 38, "cantidad": 140, "id_ubicacion": 1}	{"id_lote": 38, "cantidad": 180, "id_ubicacion": 1}	{"id_lote": 38, "cantidad": 140, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
297	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 38, "cantidad": 40, "id_ubicacion": 7}	\N	{"id_lote": 38, "cantidad": 40, "id_ubicacion": 7}	2026-11-17 18:05:30.454005-06	192.168.1.101
298	4	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 28, "cantidad": 60, "id_ubicacion": 1}	{"id_lote": 28, "cantidad": 90, "id_ubicacion": 1}	{"id_lote": 28, "cantidad": 60, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
299	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 28, "cantidad": 30, "id_ubicacion": 9}	\N	{"id_lote": 28, "cantidad": 30, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.104
300	1	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 29, "cantidad": 75, "id_ubicacion": 1}	{"id_lote": 29, "cantidad": 100, "id_ubicacion": 1}	{"id_lote": 29, "cantidad": 75, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
301	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 29, "cantidad": 25, "id_ubicacion": 8}	\N	{"id_lote": 29, "cantidad": 25, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.101
302	4	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 31, "cantidad": 35, "id_ubicacion": 1}	{"id_lote": 31, "cantidad": 50, "id_ubicacion": 1}	{"id_lote": 31, "cantidad": 35, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
303	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 31, "cantidad": 15, "id_ubicacion": 2}	\N	{"id_lote": 31, "cantidad": 15, "id_ubicacion": 2}	2026-11-17 18:05:30.454005-06	192.168.1.104
304	1	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 34, "cantidad": 50, "id_ubicacion": 1}	{"id_lote": 34, "cantidad": 70, "id_ubicacion": 1}	{"id_lote": 34, "cantidad": 50, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
305	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 34, "cantidad": 20, "id_ubicacion": 9}	\N	{"id_lote": 34, "cantidad": 20, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.101
306	4	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 47, "cantidad": 30, "id_ubicacion": 1}	{"id_lote": 47, "cantidad": 40, "id_ubicacion": 1}	{"id_lote": 47, "cantidad": 30, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.104
307	4	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 47, "cantidad": 10, "id_ubicacion": 8}	\N	{"id_lote": 47, "cantidad": 10, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.104
308	1	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 43, "cantidad": 50, "id_ubicacion": 1}	{"id_lote": 43, "cantidad": 70, "id_ubicacion": 1}	{"id_lote": 43, "cantidad": 50, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
309	1	INSERT	lote_ubicacion	lote_ubicacion {"id_lote": 43, "cantidad": 20, "id_ubicacion": 9}	\N	{"id_lote": 43, "cantidad": 20, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.101
310	5	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 25, "cantidad": 76, "id_ubicacion": 1}	{"id_lote": 25, "cantidad": 85, "id_ubicacion": 1}	{"id_lote": 25, "cantidad": 76, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.105
311	5	INSERT	dispensacion	dispensacion {"id_lote": 25, "id_medico": 5, "id_usuario": 5, "id_paciente": 4, "folio_operacion": "bba8dbcc-bb2a-4da5-b1ae-9cde33ef4a8b", "id_dispensacion": 7, "cantidad_dispensada": 9, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 25, "id_medico": 5, "id_usuario": 5, "id_paciente": 4, "folio_operacion": "bba8dbcc-bb2a-4da5-b1ae-9cde33ef4a8b", "id_dispensacion": 7, "cantidad_dispensada": 9, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.105
312	5	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 36, "cantidad": 142, "id_ubicacion": 1}	{"id_lote": 36, "cantidad": 150, "id_ubicacion": 1}	{"id_lote": 36, "cantidad": 142, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.105
313	5	INSERT	dispensacion	dispensacion {"id_lote": 36, "id_medico": 6, "id_usuario": 5, "id_paciente": 2, "folio_operacion": "e03eb86f-a5d8-4157-baa7-42c077bb3128", "id_dispensacion": 8, "cantidad_dispensada": 8, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 36, "id_medico": 6, "id_usuario": 5, "id_paciente": 2, "folio_operacion": "e03eb86f-a5d8-4157-baa7-42c077bb3128", "id_dispensacion": 8, "cantidad_dispensada": 8, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.105
314	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 17, "cantidad": 101, "id_ubicacion": 1}	{"id_lote": 17, "cantidad": 120, "id_ubicacion": 1}	{"id_lote": 17, "cantidad": 101, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
315	6	INSERT	dispensacion	dispensacion {"id_lote": 17, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "b109beae-0c6e-46e9-854f-5f919a5956cc", "id_dispensacion": 9, "cantidad_dispensada": 19, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 17, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "b109beae-0c6e-46e9-854f-5f919a5956cc", "id_dispensacion": 9, "cantidad_dispensada": 19, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
316	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 43, "cantidad": 47, "id_ubicacion": 1}	{"id_lote": 43, "cantidad": 50, "id_ubicacion": 1}	{"id_lote": 43, "cantidad": 47, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
317	8	INSERT	dispensacion	dispensacion {"id_lote": 43, "id_medico": 6, "id_usuario": 8, "id_paciente": 12, "folio_operacion": "17772c1b-a7af-4cef-ae17-ce6c63e4f97f", "id_dispensacion": 10, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 43, "id_medico": 6, "id_usuario": 8, "id_paciente": 12, "folio_operacion": "17772c1b-a7af-4cef-ae17-ce6c63e4f97f", "id_dispensacion": 10, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
318	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 47, "cantidad": 28, "id_ubicacion": 1}	{"id_lote": 47, "cantidad": 30, "id_ubicacion": 1}	{"id_lote": 47, "cantidad": 28, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
319	7	INSERT	dispensacion	dispensacion {"id_lote": 47, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "4ee58a28-f22c-49d3-8d9b-901252103573", "id_dispensacion": 11, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 47, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "4ee58a28-f22c-49d3-8d9b-901252103573", "id_dispensacion": 11, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
320	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 26, "cantidad": 28, "id_ubicacion": 1}	{"id_lote": 26, "cantidad": 30, "id_ubicacion": 1}	{"id_lote": 26, "cantidad": 28, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
321	6	INSERT	dispensacion	dispensacion {"id_lote": 26, "id_medico": 6, "id_usuario": 6, "id_paciente": 2, "folio_operacion": "5566c53f-9a4a-4c9f-8f96-1303cffdb3ab", "id_dispensacion": 12, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 26, "id_medico": 6, "id_usuario": 6, "id_paciente": 2, "folio_operacion": "5566c53f-9a4a-4c9f-8f96-1303cffdb3ab", "id_dispensacion": 12, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
322	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 35, "cantidad": 51, "id_ubicacion": 1}	{"id_lote": 35, "cantidad": 64, "id_ubicacion": 1}	{"id_lote": 35, "cantidad": 51, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
323	8	INSERT	dispensacion	dispensacion {"id_lote": 35, "id_medico": 12, "id_usuario": 8, "id_paciente": 19, "folio_operacion": "00c4524c-c80f-401e-8a38-4565f123a220", "id_dispensacion": 13, "cantidad_dispensada": 13, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 35, "id_medico": 12, "id_usuario": 8, "id_paciente": 19, "folio_operacion": "00c4524c-c80f-401e-8a38-4565f123a220", "id_dispensacion": 13, "cantidad_dispensada": 13, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
324	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 33, "cantidad": 7, "id_ubicacion": 7}	{"id_lote": 33, "cantidad": 10, "id_ubicacion": 7}	{"id_lote": 33, "cantidad": 7, "id_ubicacion": 7}	2026-11-17 18:05:30.454005-06	192.168.1.106
325	6	INSERT	dispensacion	dispensacion {"id_lote": 33, "id_medico": 4, "id_usuario": 6, "id_paciente": 24, "folio_operacion": "260d6229-3901-49fe-9c6e-f4f923e4a775", "id_dispensacion": 14, "cantidad_dispensada": 3, "id_ubicacion_origen": 7, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 33, "id_medico": 4, "id_usuario": 6, "id_paciente": 24, "folio_operacion": "260d6229-3901-49fe-9c6e-f4f923e4a775", "id_dispensacion": 14, "cantidad_dispensada": 3, "id_ubicacion_origen": 7, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
326	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 25, "cantidad": 66, "id_ubicacion": 1}	{"id_lote": 25, "cantidad": 76, "id_ubicacion": 1}	{"id_lote": 25, "cantidad": 66, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
327	2	INSERT	dispensacion	dispensacion {"id_lote": 25, "id_medico": 6, "id_usuario": 2, "id_paciente": 24, "folio_operacion": "6e1e1dc3-8a18-4c69-ac0e-ab434e165b0c", "id_dispensacion": 15, "cantidad_dispensada": 10, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 25, "id_medico": 6, "id_usuario": 2, "id_paciente": 24, "folio_operacion": "6e1e1dc3-8a18-4c69-ac0e-ab434e165b0c", "id_dispensacion": 15, "cantidad_dispensada": 10, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
328	1	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 27, "cantidad": 10, "id_ubicacion": 1}	{"id_lote": 27, "cantidad": 20, "id_ubicacion": 1}	{"id_lote": 27, "cantidad": 10, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
329	1	INSERT	dispensacion	dispensacion {"id_lote": 27, "id_medico": 6, "id_usuario": 1, "id_paciente": 19, "folio_operacion": "f1b325aa-bba6-403d-9d24-53f1029288b7", "id_dispensacion": 16, "cantidad_dispensada": 10, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 27, "id_medico": 6, "id_usuario": 1, "id_paciente": 19, "folio_operacion": "f1b325aa-bba6-403d-9d24-53f1029288b7", "id_dispensacion": 16, "cantidad_dispensada": 10, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.101
330	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 21, "cantidad": 27, "id_ubicacion": 8}	{"id_lote": 21, "cantidad": 30, "id_ubicacion": 8}	{"id_lote": 21, "cantidad": 27, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.102
331	2	INSERT	dispensacion	dispensacion {"id_lote": 21, "id_medico": 3, "id_usuario": 2, "id_paciente": 2, "folio_operacion": "7c114907-5134-4f47-bdeb-2d34fef0ba48", "id_dispensacion": 17, "cantidad_dispensada": 3, "id_ubicacion_origen": 8, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 21, "id_medico": 3, "id_usuario": 2, "id_paciente": 2, "folio_operacion": "7c114907-5134-4f47-bdeb-2d34fef0ba48", "id_dispensacion": 17, "cantidad_dispensada": 3, "id_ubicacion_origen": 8, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
332	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 33, "cantidad": 19, "id_ubicacion": 1}	{"id_lote": 33, "cantidad": 20, "id_ubicacion": 1}	{"id_lote": 33, "cantidad": 19, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
333	6	INSERT	dispensacion	dispensacion {"id_lote": 33, "id_medico": 5, "id_usuario": 6, "id_paciente": 21, "folio_operacion": "7f9a3dfb-be8b-4780-9ffb-91ac50226e82", "id_dispensacion": 18, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 33, "id_medico": 5, "id_usuario": 6, "id_paciente": 21, "folio_operacion": "7f9a3dfb-be8b-4780-9ffb-91ac50226e82", "id_dispensacion": 18, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
334	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 34, "cantidad": 48, "id_ubicacion": 1}	{"id_lote": 34, "cantidad": 50, "id_ubicacion": 1}	{"id_lote": 34, "cantidad": 48, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
335	7	INSERT	dispensacion	dispensacion {"id_lote": 34, "id_medico": 4, "id_usuario": 7, "id_paciente": 6, "folio_operacion": "ab18675b-72b2-4de0-86af-b2ffc1f64c02", "id_dispensacion": 19, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 34, "id_medico": 4, "id_usuario": 7, "id_paciente": 6, "folio_operacion": "ab18675b-72b2-4de0-86af-b2ffc1f64c02", "id_dispensacion": 19, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
336	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 17, "cantidad": 32, "id_ubicacion": 1}	{"id_lote": 17, "cantidad": 101, "id_ubicacion": 1}	{"id_lote": 17, "cantidad": 32, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
337	7	INSERT	dispensacion	dispensacion {"id_lote": 17, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "5dfdba47-bd5f-4b83-bf14-9a4fe9bbae23", "id_dispensacion": 20, "cantidad_dispensada": 69, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 17, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "5dfdba47-bd5f-4b83-bf14-9a4fe9bbae23", "id_dispensacion": 20, "cantidad_dispensada": 69, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
338	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 35, "cantidad": 45, "id_ubicacion": 1}	{"id_lote": 35, "cantidad": 51, "id_ubicacion": 1}	{"id_lote": 35, "cantidad": 45, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
339	6	INSERT	dispensacion	dispensacion {"id_lote": 35, "id_medico": 2, "id_usuario": 6, "id_paciente": 11, "folio_operacion": "18fc9ebe-f640-458c-9eb0-4265b3d33720", "id_dispensacion": 21, "cantidad_dispensada": 6, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 35, "id_medico": 2, "id_usuario": 6, "id_paciente": 11, "folio_operacion": "18fc9ebe-f640-458c-9eb0-4265b3d33720", "id_dispensacion": 21, "cantidad_dispensada": 6, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
340	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 28, "cantidad": 58, "id_ubicacion": 1}	{"id_lote": 28, "cantidad": 60, "id_ubicacion": 1}	{"id_lote": 28, "cantidad": 58, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
341	2	INSERT	dispensacion	dispensacion {"id_lote": 28, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "576d8805-c437-4084-83f0-8f0df24ccc47", "id_dispensacion": 22, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 28, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "576d8805-c437-4084-83f0-8f0df24ccc47", "id_dispensacion": 22, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
342	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 40, "cantidad": 158, "id_ubicacion": 1}	{"id_lote": 40, "cantidad": 160, "id_ubicacion": 1}	{"id_lote": 40, "cantidad": 158, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
343	8	INSERT	dispensacion	dispensacion {"id_lote": 40, "id_medico": 11, "id_usuario": 8, "id_paciente": 12, "folio_operacion": "993820f1-f925-47c2-9450-e47d00e01607", "id_dispensacion": 23, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 40, "id_medico": 11, "id_usuario": 8, "id_paciente": 12, "folio_operacion": "993820f1-f925-47c2-9450-e47d00e01607", "id_dispensacion": 23, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
344	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 40, "cantidad": 142, "id_ubicacion": 1}	{"id_lote": 40, "cantidad": 158, "id_ubicacion": 1}	{"id_lote": 40, "cantidad": 142, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
345	8	INSERT	dispensacion	dispensacion {"id_lote": 40, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "0d9d4631-807a-452a-ae9a-c515932d1316", "id_dispensacion": 24, "cantidad_dispensada": 16, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 40, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "0d9d4631-807a-452a-ae9a-c515932d1316", "id_dispensacion": 24, "cantidad_dispensada": 16, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
346	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 40, "cantidad": 130, "id_ubicacion": 1}	{"id_lote": 40, "cantidad": 142, "id_ubicacion": 1}	{"id_lote": 40, "cantidad": 130, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
347	8	INSERT	dispensacion	dispensacion {"id_lote": 40, "id_medico": 2, "id_usuario": 8, "id_paciente": 5, "folio_operacion": "88cd113f-c1cb-4886-bffb-d78cb6eed255", "id_dispensacion": 25, "cantidad_dispensada": 12, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 40, "id_medico": 2, "id_usuario": 8, "id_paciente": 5, "folio_operacion": "88cd113f-c1cb-4886-bffb-d78cb6eed255", "id_dispensacion": 25, "cantidad_dispensada": 12, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
348	1	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 14, "cantidad": 11, "id_ubicacion": 2}	{"id_lote": 14, "cantidad": 12, "id_ubicacion": 2}	{"id_lote": 14, "cantidad": 11, "id_ubicacion": 2}	2026-11-17 18:05:30.454005-06	192.168.1.101
349	1	INSERT	dispensacion	dispensacion {"id_lote": 14, "id_medico": null, "id_usuario": 1, "id_paciente": null, "folio_operacion": "46fd4df4-b4a5-41c7-8220-5d645ba6cb2a", "id_dispensacion": 26, "cantidad_dispensada": 1, "id_ubicacion_origen": 2, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 14, "id_medico": null, "id_usuario": 1, "id_paciente": null, "folio_operacion": "46fd4df4-b4a5-41c7-8220-5d645ba6cb2a", "id_dispensacion": 26, "cantidad_dispensada": 1, "id_ubicacion_origen": 2, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.101
350	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 48, "cantidad": 6, "id_ubicacion": 8}	{"id_lote": 48, "cantidad": 8, "id_ubicacion": 8}	{"id_lote": 48, "cantidad": 6, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.102
351	2	INSERT	dispensacion	dispensacion {"id_lote": 48, "id_medico": 3, "id_usuario": 2, "id_paciente": 17, "folio_operacion": "e42ecc91-f827-4656-baf0-52f5dd5886c2", "id_dispensacion": 27, "cantidad_dispensada": 2, "id_ubicacion_origen": 8, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 48, "id_medico": 3, "id_usuario": 2, "id_paciente": 17, "folio_operacion": "e42ecc91-f827-4656-baf0-52f5dd5886c2", "id_dispensacion": 27, "cantidad_dispensada": 2, "id_ubicacion_origen": 8, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
352	5	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 31, "cantidad": 28, "id_ubicacion": 1}	{"id_lote": 31, "cantidad": 35, "id_ubicacion": 1}	{"id_lote": 31, "cantidad": 28, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.105
353	5	INSERT	dispensacion	dispensacion {"id_lote": 31, "id_medico": 7, "id_usuario": 5, "id_paciente": 18, "folio_operacion": "031f8361-cbf4-4994-9fd3-b4b2fa63c2ab", "id_dispensacion": 28, "cantidad_dispensada": 7, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 31, "id_medico": 7, "id_usuario": 5, "id_paciente": 18, "folio_operacion": "031f8361-cbf4-4994-9fd3-b4b2fa63c2ab", "id_dispensacion": 28, "cantidad_dispensada": 7, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.105
354	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 35, "cantidad": 42, "id_ubicacion": 1}	{"id_lote": 35, "cantidad": 45, "id_ubicacion": 1}	{"id_lote": 35, "cantidad": 42, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
355	7	INSERT	dispensacion	dispensacion {"id_lote": 35, "id_medico": 12, "id_usuario": 7, "id_paciente": 11, "folio_operacion": "d0d06c42-2c75-4bdb-864f-2896559b96d2", "id_dispensacion": 29, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 35, "id_medico": 12, "id_usuario": 7, "id_paciente": 11, "folio_operacion": "d0d06c42-2c75-4bdb-864f-2896559b96d2", "id_dispensacion": 29, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
356	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 8, "cantidad": 13, "id_ubicacion": 5}	{"id_lote": 8, "cantidad": 14, "id_ubicacion": 5}	{"id_lote": 8, "cantidad": 13, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.107
357	7	INSERT	dispensacion	dispensacion {"id_lote": 8, "id_medico": 8, "id_usuario": 7, "id_paciente": 5, "folio_operacion": "ee79ea92-2f36-4c02-8635-1088a36b8015", "id_dispensacion": 30, "cantidad_dispensada": 1, "id_ubicacion_origen": 5, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 8, "id_medico": 8, "id_usuario": 7, "id_paciente": 5, "folio_operacion": "ee79ea92-2f36-4c02-8635-1088a36b8015", "id_dispensacion": 30, "cantidad_dispensada": 1, "id_ubicacion_origen": 5, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
358	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 43, "cantidad": 45, "id_ubicacion": 1}	{"id_lote": 43, "cantidad": 47, "id_ubicacion": 1}	{"id_lote": 43, "cantidad": 45, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
359	6	INSERT	dispensacion	dispensacion {"id_lote": 43, "id_medico": 5, "id_usuario": 6, "id_paciente": 25, "folio_operacion": "db33ea61-6d01-47da-a98e-0665781365cb", "id_dispensacion": 31, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 43, "id_medico": 5, "id_usuario": 6, "id_paciente": 25, "folio_operacion": "db33ea61-6d01-47da-a98e-0665781365cb", "id_dispensacion": 31, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
360	5	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 7, "cantidad": 0, "id_ubicacion": 5}	{"id_lote": 7, "cantidad": 10, "id_ubicacion": 5}	{"id_lote": 7, "cantidad": 0, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.105
361	5	INSERT	dispensacion	dispensacion {"id_lote": 7, "id_medico": 6, "id_usuario": 5, "id_paciente": 17, "folio_operacion": "3e104fce-91af-4768-a80b-38885842c146", "id_dispensacion": 32, "cantidad_dispensada": 10, "id_ubicacion_origen": 5, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 7, "id_medico": 6, "id_usuario": 5, "id_paciente": 17, "folio_operacion": "3e104fce-91af-4768-a80b-38885842c146", "id_dispensacion": 32, "cantidad_dispensada": 10, "id_ubicacion_origen": 5, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.105
362	5	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 6, "cantidad": 18, "id_ubicacion": 5}	{"id_lote": 6, "cantidad": 20, "id_ubicacion": 5}	{"id_lote": 6, "cantidad": 18, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.105
363	5	INSERT	dispensacion	dispensacion {"id_lote": 6, "id_medico": 6, "id_usuario": 5, "id_paciente": 17, "folio_operacion": "3e104fce-91af-4768-a80b-38885842c146", "id_dispensacion": 33, "cantidad_dispensada": 2, "id_ubicacion_origen": 5, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 6, "id_medico": 6, "id_usuario": 5, "id_paciente": 17, "folio_operacion": "3e104fce-91af-4768-a80b-38885842c146", "id_dispensacion": 33, "cantidad_dispensada": 2, "id_ubicacion_origen": 5, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.105
364	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 12, "cantidad": 10, "id_ubicacion": 5}	{"id_lote": 12, "cantidad": 12, "id_ubicacion": 5}	{"id_lote": 12, "cantidad": 10, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.106
365	6	INSERT	dispensacion	dispensacion {"id_lote": 12, "id_medico": 10, "id_usuario": 6, "id_paciente": 14, "folio_operacion": "29f7e65e-e1a4-4843-9bcc-fbd765a0d253", "id_dispensacion": 34, "cantidad_dispensada": 2, "id_ubicacion_origen": 5, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 12, "id_medico": 10, "id_usuario": 6, "id_paciente": 14, "folio_operacion": "29f7e65e-e1a4-4843-9bcc-fbd765a0d253", "id_dispensacion": 34, "cantidad_dispensada": 2, "id_ubicacion_origen": 5, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
366	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 50, "cantidad": 140, "id_ubicacion": 9}	{"id_lote": 50, "cantidad": 150, "id_ubicacion": 9}	{"id_lote": 50, "cantidad": 140, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.102
367	2	INSERT	dispensacion	dispensacion {"id_lote": 50, "id_medico": 8, "id_usuario": 2, "id_paciente": 13, "folio_operacion": "23f3cd1c-c2d5-4bed-b7d8-654ea70fa36d", "id_dispensacion": 35, "cantidad_dispensada": 10, "id_ubicacion_origen": 9, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 50, "id_medico": 8, "id_usuario": 2, "id_paciente": 13, "folio_operacion": "23f3cd1c-c2d5-4bed-b7d8-654ea70fa36d", "id_dispensacion": 35, "cantidad_dispensada": 10, "id_ubicacion_origen": 9, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
368	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 33, "cantidad": 16, "id_ubicacion": 1}	{"id_lote": 33, "cantidad": 19, "id_ubicacion": 1}	{"id_lote": 33, "cantidad": 16, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
369	2	INSERT	dispensacion	dispensacion {"id_lote": 33, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "10c10bb5-7095-4e88-b977-68998a0190fa", "id_dispensacion": 36, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 33, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "10c10bb5-7095-4e88-b977-68998a0190fa", "id_dispensacion": 36, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
370	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 41, "cantidad": 11, "id_ubicacion": 4}	{"id_lote": 41, "cantidad": 24, "id_ubicacion": 4}	{"id_lote": 41, "cantidad": 11, "id_ubicacion": 4}	2026-11-17 18:05:30.454005-06	192.168.1.107
371	7	INSERT	dispensacion	dispensacion {"id_lote": 41, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "69701389-8995-4b13-b1e2-b42164f3e772", "id_dispensacion": 37, "cantidad_dispensada": 13, "id_ubicacion_origen": 4, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 41, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "69701389-8995-4b13-b1e2-b42164f3e772", "id_dispensacion": 37, "cantidad_dispensada": 13, "id_ubicacion_origen": 4, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
372	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 38, "cantidad": 0, "id_ubicacion": 1}	{"id_lote": 38, "cantidad": 140, "id_ubicacion": 1}	{"id_lote": 38, "cantidad": 0, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
373	7	INSERT	dispensacion	dispensacion {"id_lote": 38, "id_medico": 4, "id_usuario": 7, "id_paciente": 21, "folio_operacion": "8132c199-9598-40ce-9bcb-580edbc3a1d6", "id_dispensacion": 38, "cantidad_dispensada": 140, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 38, "id_medico": 4, "id_usuario": 7, "id_paciente": 21, "folio_operacion": "8132c199-9598-40ce-9bcb-580edbc3a1d6", "id_dispensacion": 38, "cantidad_dispensada": 140, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
374	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 39, "cantidad": 210, "id_ubicacion": 1}	{"id_lote": 39, "cantidad": 220, "id_ubicacion": 1}	{"id_lote": 39, "cantidad": 210, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
375	7	INSERT	dispensacion	dispensacion {"id_lote": 39, "id_medico": 4, "id_usuario": 7, "id_paciente": 21, "folio_operacion": "8132c199-9598-40ce-9bcb-580edbc3a1d6", "id_dispensacion": 39, "cantidad_dispensada": 10, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 39, "id_medico": 4, "id_usuario": 7, "id_paciente": 21, "folio_operacion": "8132c199-9598-40ce-9bcb-580edbc3a1d6", "id_dispensacion": 39, "cantidad_dispensada": 10, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
376	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 36, "cantidad": 110, "id_ubicacion": 1}	{"id_lote": 36, "cantidad": 142, "id_ubicacion": 1}	{"id_lote": 36, "cantidad": 110, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
377	8	INSERT	dispensacion	dispensacion {"id_lote": 36, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "3ab9907c-b9f0-43bb-ad49-64da3ac5cdc0", "id_dispensacion": 40, "cantidad_dispensada": 32, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 36, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "3ab9907c-b9f0-43bb-ad49-64da3ac5cdc0", "id_dispensacion": 40, "cantidad_dispensada": 32, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
378	1	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 5, "cantidad": 472, "id_ubicacion": 1}	{"id_lote": 5, "cantidad": 500, "id_ubicacion": 1}	{"id_lote": 5, "cantidad": 472, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
379	1	INSERT	dispensacion	dispensacion {"id_lote": 5, "id_medico": 1, "id_usuario": 1, "id_paciente": 18, "folio_operacion": "98ba2b0b-1d72-47d5-81d0-79541f704681", "id_dispensacion": 41, "cantidad_dispensada": 28, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 5, "id_medico": 1, "id_usuario": 1, "id_paciente": 18, "folio_operacion": "98ba2b0b-1d72-47d5-81d0-79541f704681", "id_dispensacion": 41, "cantidad_dispensada": 28, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.101
380	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 43, "cantidad": 44, "id_ubicacion": 1}	{"id_lote": 43, "cantidad": 45, "id_ubicacion": 1}	{"id_lote": 43, "cantidad": 44, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
381	8	INSERT	dispensacion	dispensacion {"id_lote": 43, "id_medico": 7, "id_usuario": 8, "id_paciente": 17, "folio_operacion": "9bada4f6-ec77-4f89-86dc-09d89cbfde8c", "id_dispensacion": 42, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 43, "id_medico": 7, "id_usuario": 8, "id_paciente": 17, "folio_operacion": "9bada4f6-ec77-4f89-86dc-09d89cbfde8c", "id_dispensacion": 42, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
382	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 5, "cantidad": 458, "id_ubicacion": 1}	{"id_lote": 5, "cantidad": 472, "id_ubicacion": 1}	{"id_lote": 5, "cantidad": 458, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
383	6	INSERT	dispensacion	dispensacion {"id_lote": 5, "id_medico": 7, "id_usuario": 6, "id_paciente": 1, "folio_operacion": "ba2c146c-6e6e-4b9a-b893-b675a823d572", "id_dispensacion": 43, "cantidad_dispensada": 14, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 5, "id_medico": 7, "id_usuario": 6, "id_paciente": 1, "folio_operacion": "ba2c146c-6e6e-4b9a-b893-b675a823d572", "id_dispensacion": 43, "cantidad_dispensada": 14, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
384	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 49, "cantidad": 41, "id_ubicacion": 1}	{"id_lote": 49, "cantidad": 45, "id_ubicacion": 1}	{"id_lote": 49, "cantidad": 41, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
385	2	INSERT	dispensacion	dispensacion {"id_lote": 49, "id_medico": 12, "id_usuario": 2, "id_paciente": 7, "folio_operacion": "6c838373-7e6c-4e5c-8dc9-31d8a3fc1c7b", "id_dispensacion": 44, "cantidad_dispensada": 4, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 49, "id_medico": 12, "id_usuario": 2, "id_paciente": 7, "folio_operacion": "6c838373-7e6c-4e5c-8dc9-31d8a3fc1c7b", "id_dispensacion": 44, "cantidad_dispensada": 4, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
386	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 49, "cantidad": 40, "id_ubicacion": 1}	{"id_lote": 49, "cantidad": 41, "id_ubicacion": 1}	{"id_lote": 49, "cantidad": 40, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
387	8	INSERT	dispensacion	dispensacion {"id_lote": 49, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "a5fb8848-f365-4424-8703-604fa673ff26", "id_dispensacion": 45, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 49, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "a5fb8848-f365-4424-8703-604fa673ff26", "id_dispensacion": 45, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
388	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 41, "cantidad": 10, "id_ubicacion": 4}	{"id_lote": 41, "cantidad": 11, "id_ubicacion": 4}	{"id_lote": 41, "cantidad": 10, "id_ubicacion": 4}	2026-11-17 18:05:30.454005-06	192.168.1.108
389	8	INSERT	dispensacion	dispensacion {"id_lote": 41, "id_medico": 1, "id_usuario": 8, "id_paciente": 6, "folio_operacion": "566133dc-0932-4b8c-9be3-02917095d8f3", "id_dispensacion": 46, "cantidad_dispensada": 1, "id_ubicacion_origen": 4, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 41, "id_medico": 1, "id_usuario": 8, "id_paciente": 6, "folio_operacion": "566133dc-0932-4b8c-9be3-02917095d8f3", "id_dispensacion": 46, "cantidad_dispensada": 1, "id_ubicacion_origen": 4, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
390	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 47, "cantidad": 27, "id_ubicacion": 1}	{"id_lote": 47, "cantidad": 28, "id_ubicacion": 1}	{"id_lote": 47, "cantidad": 27, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
391	6	INSERT	dispensacion	dispensacion {"id_lote": 47, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "e81350d4-e05c-49c1-bded-b180eb9813cf", "id_dispensacion": 47, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 47, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "e81350d4-e05c-49c1-bded-b180eb9813cf", "id_dispensacion": 47, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
392	5	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 21, "cantidad": 22, "id_ubicacion": 8}	{"id_lote": 21, "cantidad": 27, "id_ubicacion": 8}	{"id_lote": 21, "cantidad": 22, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.105
393	5	INSERT	dispensacion	dispensacion {"id_lote": 21, "id_medico": 4, "id_usuario": 5, "id_paciente": 26, "folio_operacion": "1a15fc8f-5164-48d3-856b-24a0d02b7d2a", "id_dispensacion": 48, "cantidad_dispensada": 5, "id_ubicacion_origen": 8, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 21, "id_medico": 4, "id_usuario": 5, "id_paciente": 26, "folio_operacion": "1a15fc8f-5164-48d3-856b-24a0d02b7d2a", "id_dispensacion": 48, "cantidad_dispensada": 5, "id_ubicacion_origen": 8, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.105
394	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 8, "cantidad": 9, "id_ubicacion": 5}	{"id_lote": 8, "cantidad": 13, "id_ubicacion": 5}	{"id_lote": 8, "cantidad": 9, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.106
395	6	INSERT	dispensacion	dispensacion {"id_lote": 8, "id_medico": 12, "id_usuario": 6, "id_paciente": 12, "folio_operacion": "1e0d2ae9-4103-4db8-a7f1-6fc104401787", "id_dispensacion": 49, "cantidad_dispensada": 4, "id_ubicacion_origen": 5, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 8, "id_medico": 12, "id_usuario": 6, "id_paciente": 12, "folio_operacion": "1e0d2ae9-4103-4db8-a7f1-6fc104401787", "id_dispensacion": 49, "cantidad_dispensada": 4, "id_ubicacion_origen": 5, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
396	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 23, "cantidad": 58, "id_ubicacion": 9}	{"id_lote": 23, "cantidad": 60, "id_ubicacion": 9}	{"id_lote": 23, "cantidad": 58, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.108
397	8	INSERT	dispensacion	dispensacion {"id_lote": 23, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "9ef05a57-0d75-4919-a8d9-d2bb4e0eba11", "id_dispensacion": 50, "cantidad_dispensada": 2, "id_ubicacion_origen": 9, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 23, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "9ef05a57-0d75-4919-a8d9-d2bb4e0eba11", "id_dispensacion": 50, "cantidad_dispensada": 2, "id_ubicacion_origen": 9, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
398	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 49, "cantidad": 37, "id_ubicacion": 1}	{"id_lote": 49, "cantidad": 40, "id_ubicacion": 1}	{"id_lote": 49, "cantidad": 37, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
399	6	INSERT	dispensacion	dispensacion {"id_lote": 49, "id_medico": 8, "id_usuario": 6, "id_paciente": 7, "folio_operacion": "465f4270-d018-4dfb-a6bc-bfb0f8d7122e", "id_dispensacion": 51, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 49, "id_medico": 8, "id_usuario": 6, "id_paciente": 7, "folio_operacion": "465f4270-d018-4dfb-a6bc-bfb0f8d7122e", "id_dispensacion": 51, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
400	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 33, "cantidad": 4, "id_ubicacion": 7}	{"id_lote": 33, "cantidad": 7, "id_ubicacion": 7}	{"id_lote": 33, "cantidad": 4, "id_ubicacion": 7}	2026-11-17 18:05:30.454005-06	192.168.1.108
401	8	INSERT	dispensacion	dispensacion {"id_lote": 33, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "28971bd3-543d-4409-884e-17c6c1823d0a", "id_dispensacion": 52, "cantidad_dispensada": 3, "id_ubicacion_origen": 7, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 33, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "28971bd3-543d-4409-884e-17c6c1823d0a", "id_dispensacion": 52, "cantidad_dispensada": 3, "id_ubicacion_origen": 7, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
402	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 23, "cantidad": 89, "id_ubicacion": 1}	{"id_lote": 23, "cantidad": 150, "id_ubicacion": 1}	{"id_lote": 23, "cantidad": 89, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
403	6	INSERT	dispensacion	dispensacion {"id_lote": 23, "id_medico": 3, "id_usuario": 6, "id_paciente": 9, "folio_operacion": "136a1b5a-6987-4d64-810e-53fe94ef3ede", "id_dispensacion": 53, "cantidad_dispensada": 61, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 23, "id_medico": 3, "id_usuario": 6, "id_paciente": 9, "folio_operacion": "136a1b5a-6987-4d64-810e-53fe94ef3ede", "id_dispensacion": 53, "cantidad_dispensada": 61, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
404	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 16, "cantidad": 84, "id_ubicacion": 1}	{"id_lote": 16, "cantidad": 90, "id_ubicacion": 1}	{"id_lote": 16, "cantidad": 84, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
405	2	INSERT	dispensacion	dispensacion {"id_lote": 16, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "530ba178-a91b-4aee-9020-9c32f4eea5ab", "id_dispensacion": 54, "cantidad_dispensada": 6, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 16, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "530ba178-a91b-4aee-9020-9c32f4eea5ab", "id_dispensacion": 54, "cantidad_dispensada": 6, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
406	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 8, "cantidad": 3, "id_ubicacion": 3}	{"id_lote": 8, "cantidad": 10, "id_ubicacion": 3}	{"id_lote": 8, "cantidad": 3, "id_ubicacion": 3}	2026-11-17 18:05:30.454005-06	192.168.1.106
407	6	INSERT	dispensacion	dispensacion {"id_lote": 8, "id_medico": 10, "id_usuario": 6, "id_paciente": 18, "folio_operacion": "f132bc9b-26ab-4e6d-81fd-6b0c7c7ff09c", "id_dispensacion": 55, "cantidad_dispensada": 7, "id_ubicacion_origen": 3, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 8, "id_medico": 10, "id_usuario": 6, "id_paciente": 18, "folio_operacion": "f132bc9b-26ab-4e6d-81fd-6b0c7c7ff09c", "id_dispensacion": 55, "cantidad_dispensada": 7, "id_ubicacion_origen": 3, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
408	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 49, "cantidad": 34, "id_ubicacion": 1}	{"id_lote": 49, "cantidad": 37, "id_ubicacion": 1}	{"id_lote": 49, "cantidad": 34, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
409	6	INSERT	dispensacion	dispensacion {"id_lote": 49, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "7a4f09bf-9f54-4b94-b0ae-2472005e6d3a", "id_dispensacion": 56, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 49, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "7a4f09bf-9f54-4b94-b0ae-2472005e6d3a", "id_dispensacion": 56, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
410	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 25, "cantidad": 58, "id_ubicacion": 1}	{"id_lote": 25, "cantidad": 66, "id_ubicacion": 1}	{"id_lote": 25, "cantidad": 58, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
411	7	INSERT	dispensacion	dispensacion {"id_lote": 25, "id_medico": 2, "id_usuario": 7, "id_paciente": 1, "folio_operacion": "decd57a7-64a4-4e9e-8e34-ff8dd37b0407", "id_dispensacion": 57, "cantidad_dispensada": 8, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 25, "id_medico": 2, "id_usuario": 7, "id_paciente": 1, "folio_operacion": "decd57a7-64a4-4e9e-8e34-ff8dd37b0407", "id_dispensacion": 57, "cantidad_dispensada": 8, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
412	5	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 30, "cantidad": 13, "id_ubicacion": 8}	{"id_lote": 30, "cantidad": 20, "id_ubicacion": 8}	{"id_lote": 30, "cantidad": 13, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.105
413	5	INSERT	dispensacion	dispensacion {"id_lote": 30, "id_medico": null, "id_usuario": 5, "id_paciente": null, "folio_operacion": "602265a0-c37c-4261-ba20-3535e75b2f3e", "id_dispensacion": 58, "cantidad_dispensada": 7, "id_ubicacion_origen": 8, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 30, "id_medico": null, "id_usuario": 5, "id_paciente": null, "folio_operacion": "602265a0-c37c-4261-ba20-3535e75b2f3e", "id_dispensacion": 58, "cantidad_dispensada": 7, "id_ubicacion_origen": 8, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.105
414	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 45, "cantidad": 27, "id_ubicacion": 6}	{"id_lote": 45, "cantidad": 36, "id_ubicacion": 6}	{"id_lote": 45, "cantidad": 27, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.107
415	7	INSERT	dispensacion	dispensacion {"id_lote": 45, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "22231585-2563-479a-880d-79997497069d", "id_dispensacion": 59, "cantidad_dispensada": 9, "id_ubicacion_origen": 6, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 45, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "22231585-2563-479a-880d-79997497069d", "id_dispensacion": 59, "cantidad_dispensada": 9, "id_ubicacion_origen": 6, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
416	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 44, "cantidad": 49, "id_ubicacion": 1}	{"id_lote": 44, "cantidad": 60, "id_ubicacion": 1}	{"id_lote": 44, "cantidad": 49, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
417	8	INSERT	dispensacion	dispensacion {"id_lote": 44, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "85037a69-b776-4e87-95b3-ff0da8ed123f", "id_dispensacion": 60, "cantidad_dispensada": 11, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 44, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "85037a69-b776-4e87-95b3-ff0da8ed123f", "id_dispensacion": 60, "cantidad_dispensada": 11, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
418	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 50, "cantidad": 110, "id_ubicacion": 9}	{"id_lote": 50, "cantidad": 140, "id_ubicacion": 9}	{"id_lote": 50, "cantidad": 110, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.107
419	7	INSERT	dispensacion	dispensacion {"id_lote": 50, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "c0758732-58de-423f-88b8-2a1bb05ebc79", "id_dispensacion": 61, "cantidad_dispensada": 30, "id_ubicacion_origen": 9, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 50, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "c0758732-58de-423f-88b8-2a1bb05ebc79", "id_dispensacion": 61, "cantidad_dispensada": 30, "id_ubicacion_origen": 9, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
420	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 44, "cantidad": 48, "id_ubicacion": 1}	{"id_lote": 44, "cantidad": 49, "id_ubicacion": 1}	{"id_lote": 44, "cantidad": 48, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
421	8	INSERT	dispensacion	dispensacion {"id_lote": 44, "id_medico": 12, "id_usuario": 8, "id_paciente": 5, "folio_operacion": "317dddaa-a8a7-4579-bfa5-baf31903afc2", "id_dispensacion": 62, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 44, "id_medico": 12, "id_usuario": 8, "id_paciente": 5, "folio_operacion": "317dddaa-a8a7-4579-bfa5-baf31903afc2", "id_dispensacion": 62, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
422	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 35, "cantidad": 41, "id_ubicacion": 1}	{"id_lote": 35, "cantidad": 42, "id_ubicacion": 1}	{"id_lote": 35, "cantidad": 41, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
423	6	INSERT	dispensacion	dispensacion {"id_lote": 35, "id_medico": 5, "id_usuario": 6, "id_paciente": 10, "folio_operacion": "d299376c-f20c-4c08-bbc0-37f19cfab338", "id_dispensacion": 63, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 35, "id_medico": 5, "id_usuario": 6, "id_paciente": 10, "folio_operacion": "d299376c-f20c-4c08-bbc0-37f19cfab338", "id_dispensacion": 63, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
424	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 14, "cantidad": 6, "id_ubicacion": 2}	{"id_lote": 14, "cantidad": 11, "id_ubicacion": 2}	{"id_lote": 14, "cantidad": 6, "id_ubicacion": 2}	2026-11-17 18:05:30.454005-06	192.168.1.102
425	2	INSERT	dispensacion	dispensacion {"id_lote": 14, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "b0cbfc0a-4a88-4d8c-ad5a-c90ce31b0e0f", "id_dispensacion": 64, "cantidad_dispensada": 5, "id_ubicacion_origen": 2, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 14, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "b0cbfc0a-4a88-4d8c-ad5a-c90ce31b0e0f", "id_dispensacion": 64, "cantidad_dispensada": 5, "id_ubicacion_origen": 2, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
426	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 5, "cantidad": 440, "id_ubicacion": 1}	{"id_lote": 5, "cantidad": 458, "id_ubicacion": 1}	{"id_lote": 5, "cantidad": 440, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
427	8	INSERT	dispensacion	dispensacion {"id_lote": 5, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "04520804-a598-47d4-9b80-b936ae766a15", "id_dispensacion": 65, "cantidad_dispensada": 18, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 5, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "04520804-a598-47d4-9b80-b936ae766a15", "id_dispensacion": 65, "cantidad_dispensada": 18, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
428	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 40, "cantidad": 120, "id_ubicacion": 1}	{"id_lote": 40, "cantidad": 130, "id_ubicacion": 1}	{"id_lote": 40, "cantidad": 120, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
429	8	INSERT	dispensacion	dispensacion {"id_lote": 40, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "6f2ce803-4f60-449f-9735-91de1b91748f", "id_dispensacion": 66, "cantidad_dispensada": 10, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 40, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "6f2ce803-4f60-449f-9735-91de1b91748f", "id_dispensacion": 66, "cantidad_dispensada": 10, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
430	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 19, "cantidad": 60, "id_ubicacion": 1}	{"id_lote": 19, "cantidad": 70, "id_ubicacion": 1}	{"id_lote": 19, "cantidad": 60, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
431	2	INSERT	dispensacion	dispensacion {"id_lote": 19, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "3e679bec-b152-4b73-bfa7-968e376c6a54", "id_dispensacion": 67, "cantidad_dispensada": 10, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 19, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "3e679bec-b152-4b73-bfa7-968e376c6a54", "id_dispensacion": 67, "cantidad_dispensada": 10, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
432	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 19, "cantidad": 57, "id_ubicacion": 1}	{"id_lote": 19, "cantidad": 60, "id_ubicacion": 1}	{"id_lote": 19, "cantidad": 57, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
433	6	INSERT	dispensacion	dispensacion {"id_lote": 19, "id_medico": 4, "id_usuario": 6, "id_paciente": 14, "folio_operacion": "b331910c-499a-4b36-9e6b-f8da42defad7", "id_dispensacion": 68, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 19, "id_medico": 4, "id_usuario": 6, "id_paciente": 14, "folio_operacion": "b331910c-499a-4b36-9e6b-f8da42defad7", "id_dispensacion": 68, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
434	5	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 43, "cantidad": 38, "id_ubicacion": 1}	{"id_lote": 43, "cantidad": 44, "id_ubicacion": 1}	{"id_lote": 43, "cantidad": 38, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.105
435	5	INSERT	dispensacion	dispensacion {"id_lote": 43, "id_medico": null, "id_usuario": 5, "id_paciente": null, "folio_operacion": "93543c6f-3459-430d-b2da-d029aad4d037", "id_dispensacion": 69, "cantidad_dispensada": 6, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 43, "id_medico": null, "id_usuario": 5, "id_paciente": null, "folio_operacion": "93543c6f-3459-430d-b2da-d029aad4d037", "id_dispensacion": 69, "cantidad_dispensada": 6, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.105
436	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 25, "cantidad": 55, "id_ubicacion": 1}	{"id_lote": 25, "cantidad": 58, "id_ubicacion": 1}	{"id_lote": 25, "cantidad": 55, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
437	7	INSERT	dispensacion	dispensacion {"id_lote": 25, "id_medico": 10, "id_usuario": 7, "id_paciente": 3, "folio_operacion": "cee23be9-4399-4c55-8e58-352a20ababed", "id_dispensacion": 70, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 25, "id_medico": 10, "id_usuario": 7, "id_paciente": 3, "folio_operacion": "cee23be9-4399-4c55-8e58-352a20ababed", "id_dispensacion": 70, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
438	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 31, "cantidad": 25, "id_ubicacion": 1}	{"id_lote": 31, "cantidad": 28, "id_ubicacion": 1}	{"id_lote": 31, "cantidad": 25, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
439	7	INSERT	dispensacion	dispensacion {"id_lote": 31, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "d3769149-aceb-4685-8f2c-7218bbd06844", "id_dispensacion": 71, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 31, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "d3769149-aceb-4685-8f2c-7218bbd06844", "id_dispensacion": 71, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
440	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 17, "cantidad": 11, "id_ubicacion": 1}	{"id_lote": 17, "cantidad": 32, "id_ubicacion": 1}	{"id_lote": 17, "cantidad": 11, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
441	6	INSERT	dispensacion	dispensacion {"id_lote": 17, "id_medico": 12, "id_usuario": 6, "id_paciente": 17, "folio_operacion": "637419b0-72f7-409f-b13f-0fc2ba873d2b", "id_dispensacion": 72, "cantidad_dispensada": 21, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 17, "id_medico": 12, "id_usuario": 6, "id_paciente": 17, "folio_operacion": "637419b0-72f7-409f-b13f-0fc2ba873d2b", "id_dispensacion": 72, "cantidad_dispensada": 21, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
442	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 30, "cantidad": 31, "id_ubicacion": 1}	{"id_lote": 30, "cantidad": 40, "id_ubicacion": 1}	{"id_lote": 30, "cantidad": 31, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
443	8	INSERT	dispensacion	dispensacion {"id_lote": 30, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "6ba36fb3-50dc-4522-b6bf-7c8a4ede7b8b", "id_dispensacion": 73, "cantidad_dispensada": 9, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 30, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "6ba36fb3-50dc-4522-b6bf-7c8a4ede7b8b", "id_dispensacion": 73, "cantidad_dispensada": 9, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
444	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 37, "cantidad": 369, "id_ubicacion": 1}	{"id_lote": 37, "cantidad": 440, "id_ubicacion": 1}	{"id_lote": 37, "cantidad": 369, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
445	6	INSERT	dispensacion	dispensacion {"id_lote": 37, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "0a30e4d5-036a-4af3-b72a-56fbc29f57a8", "id_dispensacion": 74, "cantidad_dispensada": 71, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 37, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "0a30e4d5-036a-4af3-b72a-56fbc29f57a8", "id_dispensacion": 74, "cantidad_dispensada": 71, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
446	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 43, "cantidad": 30, "id_ubicacion": 1}	{"id_lote": 43, "cantidad": 38, "id_ubicacion": 1}	{"id_lote": 43, "cantidad": 30, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
447	6	INSERT	dispensacion	dispensacion {"id_lote": 43, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "67d3d1a3-7a15-4580-895d-55a84742a0b2", "id_dispensacion": 75, "cantidad_dispensada": 8, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 43, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "67d3d1a3-7a15-4580-895d-55a84742a0b2", "id_dispensacion": 75, "cantidad_dispensada": 8, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
448	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 26, "cantidad": 27, "id_ubicacion": 1}	{"id_lote": 26, "cantidad": 28, "id_ubicacion": 1}	{"id_lote": 26, "cantidad": 27, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
449	7	INSERT	dispensacion	dispensacion {"id_lote": 26, "id_medico": 2, "id_usuario": 7, "id_paciente": 22, "folio_operacion": "de23fd24-bab2-4ab4-b459-f4d14483ea01", "id_dispensacion": 76, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 26, "id_medico": 2, "id_usuario": 7, "id_paciente": 22, "folio_operacion": "de23fd24-bab2-4ab4-b459-f4d14483ea01", "id_dispensacion": 76, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
450	1	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 34, "cantidad": 47, "id_ubicacion": 1}	{"id_lote": 34, "cantidad": 48, "id_ubicacion": 1}	{"id_lote": 34, "cantidad": 47, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.101
451	1	INSERT	dispensacion	dispensacion {"id_lote": 34, "id_medico": 4, "id_usuario": 1, "id_paciente": 23, "folio_operacion": "5ba0cc51-383e-4127-b48d-b7a1346fcc84", "id_dispensacion": 77, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 34, "id_medico": 4, "id_usuario": 1, "id_paciente": 23, "folio_operacion": "5ba0cc51-383e-4127-b48d-b7a1346fcc84", "id_dispensacion": 77, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.101
452	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 13, "cantidad": 51, "id_ubicacion": 6}	{"id_lote": 13, "cantidad": 60, "id_ubicacion": 6}	{"id_lote": 13, "cantidad": 51, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.106
453	6	INSERT	dispensacion	dispensacion {"id_lote": 13, "id_medico": 5, "id_usuario": 6, "id_paciente": 18, "folio_operacion": "5e68580e-eaa1-4d06-9e08-f63d0dbc75b6", "id_dispensacion": 78, "cantidad_dispensada": 9, "id_ubicacion_origen": 6, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 13, "id_medico": 5, "id_usuario": 6, "id_paciente": 18, "folio_operacion": "5e68580e-eaa1-4d06-9e08-f63d0dbc75b6", "id_dispensacion": 78, "cantidad_dispensada": 9, "id_ubicacion_origen": 6, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
454	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 16, "cantidad": 80, "id_ubicacion": 1}	{"id_lote": 16, "cantidad": 84, "id_ubicacion": 1}	{"id_lote": 16, "cantidad": 80, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
455	7	INSERT	dispensacion	dispensacion {"id_lote": 16, "id_medico": 4, "id_usuario": 7, "id_paciente": 4, "folio_operacion": "24a982c6-bb24-4cfa-bae2-ccb5d86e0148", "id_dispensacion": 79, "cantidad_dispensada": 4, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 16, "id_medico": 4, "id_usuario": 7, "id_paciente": 4, "folio_operacion": "24a982c6-bb24-4cfa-bae2-ccb5d86e0148", "id_dispensacion": 79, "cantidad_dispensada": 4, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
456	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 28, "cantidad": 42, "id_ubicacion": 1}	{"id_lote": 28, "cantidad": 58, "id_ubicacion": 1}	{"id_lote": 28, "cantidad": 42, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
457	7	INSERT	dispensacion	dispensacion {"id_lote": 28, "id_medico": 9, "id_usuario": 7, "id_paciente": 12, "folio_operacion": "03854ee7-44c7-46d1-8565-b6963f270bf9", "id_dispensacion": 80, "cantidad_dispensada": 16, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 28, "id_medico": 9, "id_usuario": 7, "id_paciente": 12, "folio_operacion": "03854ee7-44c7-46d1-8565-b6963f270bf9", "id_dispensacion": 80, "cantidad_dispensada": 16, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
458	5	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 16, "cantidad": 77, "id_ubicacion": 1}	{"id_lote": 16, "cantidad": 80, "id_ubicacion": 1}	{"id_lote": 16, "cantidad": 77, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.105
459	5	INSERT	dispensacion	dispensacion {"id_lote": 16, "id_medico": 10, "id_usuario": 5, "id_paciente": 18, "folio_operacion": "7e4c57e9-ac27-4232-8efa-6e9f827e5afc", "id_dispensacion": 81, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 16, "id_medico": 10, "id_usuario": 5, "id_paciente": 18, "folio_operacion": "7e4c57e9-ac27-4232-8efa-6e9f827e5afc", "id_dispensacion": 81, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.105
460	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 33, "cantidad": 10, "id_ubicacion": 1}	{"id_lote": 33, "cantidad": 16, "id_ubicacion": 1}	{"id_lote": 33, "cantidad": 10, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
461	8	INSERT	dispensacion	dispensacion {"id_lote": 33, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "d2a4dbf2-9a65-4a77-b186-7b80901b4f6e", "id_dispensacion": 82, "cantidad_dispensada": 6, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 33, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "d2a4dbf2-9a65-4a77-b186-7b80901b4f6e", "id_dispensacion": 82, "cantidad_dispensada": 6, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
462	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 30, "cantidad": 29, "id_ubicacion": 1}	{"id_lote": 30, "cantidad": 31, "id_ubicacion": 1}	{"id_lote": 30, "cantidad": 29, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
463	2	INSERT	dispensacion	dispensacion {"id_lote": 30, "id_medico": 12, "id_usuario": 2, "id_paciente": 11, "folio_operacion": "c4fa4960-4a68-4811-b7e4-4f1213225cb5", "id_dispensacion": 83, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 30, "id_medico": 12, "id_usuario": 2, "id_paciente": 11, "folio_operacion": "c4fa4960-4a68-4811-b7e4-4f1213225cb5", "id_dispensacion": 83, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
464	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 37, "cantidad": 300, "id_ubicacion": 1}	{"id_lote": 37, "cantidad": 369, "id_ubicacion": 1}	{"id_lote": 37, "cantidad": 300, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
465	6	INSERT	dispensacion	dispensacion {"id_lote": 37, "id_medico": 3, "id_usuario": 6, "id_paciente": 11, "folio_operacion": "202c5bb9-d07c-409c-b925-fae7a2b635cd", "id_dispensacion": 84, "cantidad_dispensada": 69, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 37, "id_medico": 3, "id_usuario": 6, "id_paciente": 11, "folio_operacion": "202c5bb9-d07c-409c-b925-fae7a2b635cd", "id_dispensacion": 84, "cantidad_dispensada": 69, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
466	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 27, "cantidad": 0, "id_ubicacion": 1}	{"id_lote": 27, "cantidad": 10, "id_ubicacion": 1}	{"id_lote": 27, "cantidad": 0, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
467	2	INSERT	dispensacion	dispensacion {"id_lote": 27, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "49f15bf7-7d1f-45a4-b901-b17cbdabe774", "id_dispensacion": 85, "cantidad_dispensada": 10, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 27, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "49f15bf7-7d1f-45a4-b901-b17cbdabe774", "id_dispensacion": 85, "cantidad_dispensada": 10, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
468	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 42, "cantidad": 15, "id_ubicacion": 6}	{"id_lote": 42, "cantidad": 16, "id_ubicacion": 6}	{"id_lote": 42, "cantidad": 15, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.106
469	6	INSERT	dispensacion	dispensacion {"id_lote": 42, "id_medico": 6, "id_usuario": 6, "id_paciente": 9, "folio_operacion": "4db621d2-f06c-4997-8939-173d441a541d", "id_dispensacion": 86, "cantidad_dispensada": 1, "id_ubicacion_origen": 6, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 42, "id_medico": 6, "id_usuario": 6, "id_paciente": 9, "folio_operacion": "4db621d2-f06c-4997-8939-173d441a541d", "id_dispensacion": 86, "cantidad_dispensada": 1, "id_ubicacion_origen": 6, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
470	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 30, "cantidad": 8, "id_ubicacion": 8}	{"id_lote": 30, "cantidad": 13, "id_ubicacion": 8}	{"id_lote": 30, "cantidad": 8, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.106
471	6	INSERT	dispensacion	dispensacion {"id_lote": 30, "id_medico": 6, "id_usuario": 6, "id_paciente": 7, "folio_operacion": "653c0af2-582f-47d1-a417-0ca217218713", "id_dispensacion": 87, "cantidad_dispensada": 5, "id_ubicacion_origen": 8, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 30, "id_medico": 6, "id_usuario": 6, "id_paciente": 7, "folio_operacion": "653c0af2-582f-47d1-a417-0ca217218713", "id_dispensacion": 87, "cantidad_dispensada": 5, "id_ubicacion_origen": 8, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
472	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 34, "cantidad": 44, "id_ubicacion": 1}	{"id_lote": 34, "cantidad": 47, "id_ubicacion": 1}	{"id_lote": 34, "cantidad": 44, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
473	8	INSERT	dispensacion	dispensacion {"id_lote": 34, "id_medico": 11, "id_usuario": 8, "id_paciente": 16, "folio_operacion": "42591227-e56a-4797-b0f3-ec74258e8b00", "id_dispensacion": 88, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 34, "id_medico": 11, "id_usuario": 8, "id_paciente": 16, "folio_operacion": "42591227-e56a-4797-b0f3-ec74258e8b00", "id_dispensacion": 88, "cantidad_dispensada": 3, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
474	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 26, "cantidad": 15, "id_ubicacion": 1}	{"id_lote": 26, "cantidad": 27, "id_ubicacion": 1}	{"id_lote": 26, "cantidad": 15, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
475	7	INSERT	dispensacion	dispensacion {"id_lote": 26, "id_medico": 2, "id_usuario": 7, "id_paciente": 22, "folio_operacion": "1fcec51f-0917-4f93-a5fe-609738213cdc", "id_dispensacion": 89, "cantidad_dispensada": 12, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 26, "id_medico": 2, "id_usuario": 7, "id_paciente": 22, "folio_operacion": "1fcec51f-0917-4f93-a5fe-609738213cdc", "id_dispensacion": 89, "cantidad_dispensada": 12, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
476	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 19, "cantidad": 48, "id_ubicacion": 1}	{"id_lote": 19, "cantidad": 57, "id_ubicacion": 1}	{"id_lote": 19, "cantidad": 48, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
477	7	INSERT	dispensacion	dispensacion {"id_lote": 19, "id_medico": 6, "id_usuario": 7, "id_paciente": 22, "folio_operacion": "d9dff936-a084-4347-8c3e-18118fa4f017", "id_dispensacion": 90, "cantidad_dispensada": 9, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 19, "id_medico": 6, "id_usuario": 7, "id_paciente": 22, "folio_operacion": "d9dff936-a084-4347-8c3e-18118fa4f017", "id_dispensacion": 90, "cantidad_dispensada": 9, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
478	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 29, "cantidad": 63, "id_ubicacion": 1}	{"id_lote": 29, "cantidad": 75, "id_ubicacion": 1}	{"id_lote": 29, "cantidad": 63, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
479	2	INSERT	dispensacion	dispensacion {"id_lote": 29, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "1484a7cb-ea2f-44f5-af28-caa6dedae3ed", "id_dispensacion": 91, "cantidad_dispensada": 12, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 29, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "1484a7cb-ea2f-44f5-af28-caa6dedae3ed", "id_dispensacion": 91, "cantidad_dispensada": 12, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
480	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 23, "cantidad": 35, "id_ubicacion": 9}	{"id_lote": 23, "cantidad": 58, "id_ubicacion": 9}	{"id_lote": 23, "cantidad": 35, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.108
481	8	INSERT	dispensacion	dispensacion {"id_lote": 23, "id_medico": 3, "id_usuario": 8, "id_paciente": 1, "folio_operacion": "a7109f81-6445-4d3a-8c28-8c39f6412472", "id_dispensacion": 92, "cantidad_dispensada": 23, "id_ubicacion_origen": 9, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 23, "id_medico": 3, "id_usuario": 8, "id_paciente": 1, "folio_operacion": "a7109f81-6445-4d3a-8c28-8c39f6412472", "id_dispensacion": 92, "cantidad_dispensada": 23, "id_ubicacion_origen": 9, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
482	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 19, "cantidad": 33, "id_ubicacion": 1}	{"id_lote": 19, "cantidad": 48, "id_ubicacion": 1}	{"id_lote": 19, "cantidad": 33, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
483	2	INSERT	dispensacion	dispensacion {"id_lote": 19, "id_medico": 1, "id_usuario": 2, "id_paciente": 12, "folio_operacion": "8b89035c-bbd0-4dbf-a0e8-ffc0df70dba9", "id_dispensacion": 93, "cantidad_dispensada": 15, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 19, "id_medico": 1, "id_usuario": 2, "id_paciente": 12, "folio_operacion": "8b89035c-bbd0-4dbf-a0e8-ffc0df70dba9", "id_dispensacion": 93, "cantidad_dispensada": 15, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
484	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 29, "cantidad": 50, "id_ubicacion": 1}	{"id_lote": 29, "cantidad": 63, "id_ubicacion": 1}	{"id_lote": 29, "cantidad": 50, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
485	7	INSERT	dispensacion	dispensacion {"id_lote": 29, "id_medico": 8, "id_usuario": 7, "id_paciente": 14, "folio_operacion": "077ec26a-9b91-49a6-a63a-0e10d5263a8c", "id_dispensacion": 94, "cantidad_dispensada": 13, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 29, "id_medico": 8, "id_usuario": 7, "id_paciente": 14, "folio_operacion": "077ec26a-9b91-49a6-a63a-0e10d5263a8c", "id_dispensacion": 94, "cantidad_dispensada": 13, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
486	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 23, "cantidad": 74, "id_ubicacion": 1}	{"id_lote": 23, "cantidad": 89, "id_ubicacion": 1}	{"id_lote": 23, "cantidad": 74, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
487	2	INSERT	dispensacion	dispensacion {"id_lote": 23, "id_medico": 6, "id_usuario": 2, "id_paciente": 17, "folio_operacion": "db37d522-799e-49b3-add9-32b57b0a7b43", "id_dispensacion": 95, "cantidad_dispensada": 15, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 23, "id_medico": 6, "id_usuario": 2, "id_paciente": 17, "folio_operacion": "db37d522-799e-49b3-add9-32b57b0a7b43", "id_dispensacion": 95, "cantidad_dispensada": 15, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
488	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 49, "cantidad": 33, "id_ubicacion": 1}	{"id_lote": 49, "cantidad": 34, "id_ubicacion": 1}	{"id_lote": 49, "cantidad": 33, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
489	8	INSERT	dispensacion	dispensacion {"id_lote": 49, "id_medico": 10, "id_usuario": 8, "id_paciente": 23, "folio_operacion": "8323fe9d-6492-498b-a94b-f0e9be6dc56e", "id_dispensacion": 96, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 49, "id_medico": 10, "id_usuario": 8, "id_paciente": 23, "folio_operacion": "8323fe9d-6492-498b-a94b-f0e9be6dc56e", "id_dispensacion": 96, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
490	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 23, "cantidad": 34, "id_ubicacion": 9}	{"id_lote": 23, "cantidad": 35, "id_ubicacion": 9}	{"id_lote": 23, "cantidad": 34, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.102
491	2	INSERT	dispensacion	dispensacion {"id_lote": 23, "id_medico": 10, "id_usuario": 2, "id_paciente": 26, "folio_operacion": "95b42093-d68f-4336-850c-beacbf2b57ba", "id_dispensacion": 97, "cantidad_dispensada": 1, "id_ubicacion_origen": 9, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 23, "id_medico": 10, "id_usuario": 2, "id_paciente": 26, "folio_operacion": "95b42093-d68f-4336-850c-beacbf2b57ba", "id_dispensacion": 97, "cantidad_dispensada": 1, "id_ubicacion_origen": 9, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
492	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 13, "cantidad": 48, "id_ubicacion": 6}	{"id_lote": 13, "cantidad": 51, "id_ubicacion": 6}	{"id_lote": 13, "cantidad": 48, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.107
493	7	INSERT	dispensacion	dispensacion {"id_lote": 13, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "448b94ee-03b5-46e5-885a-ca909265a34c", "id_dispensacion": 98, "cantidad_dispensada": 3, "id_ubicacion_origen": 6, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 13, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "448b94ee-03b5-46e5-885a-ca909265a34c", "id_dispensacion": 98, "cantidad_dispensada": 3, "id_ubicacion_origen": 6, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
494	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 30, "cantidad": 6, "id_ubicacion": 8}	{"id_lote": 30, "cantidad": 8, "id_ubicacion": 8}	{"id_lote": 30, "cantidad": 6, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.107
495	7	INSERT	dispensacion	dispensacion {"id_lote": 30, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "9b5ca1da-be86-4fd7-9ad0-1b4f0ece67a8", "id_dispensacion": 99, "cantidad_dispensada": 2, "id_ubicacion_origen": 8, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 30, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "9b5ca1da-be86-4fd7-9ad0-1b4f0ece67a8", "id_dispensacion": 99, "cantidad_dispensada": 2, "id_ubicacion_origen": 8, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
496	5	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 33, "cantidad": 3, "id_ubicacion": 7}	{"id_lote": 33, "cantidad": 4, "id_ubicacion": 7}	{"id_lote": 33, "cantidad": 3, "id_ubicacion": 7}	2026-11-17 18:05:30.454005-06	192.168.1.105
497	5	INSERT	dispensacion	dispensacion {"id_lote": 33, "id_medico": 9, "id_usuario": 5, "id_paciente": 22, "folio_operacion": "aa0e6020-5694-40ff-844d-13fbe1a46c8e", "id_dispensacion": 100, "cantidad_dispensada": 1, "id_ubicacion_origen": 7, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 33, "id_medico": 9, "id_usuario": 5, "id_paciente": 22, "folio_operacion": "aa0e6020-5694-40ff-844d-13fbe1a46c8e", "id_dispensacion": 100, "cantidad_dispensada": 1, "id_ubicacion_origen": 7, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.105
498	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 9, "cantidad": 16, "id_ubicacion": 5}	{"id_lote": 9, "cantidad": 18, "id_ubicacion": 5}	{"id_lote": 9, "cantidad": 16, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.107
499	7	INSERT	dispensacion	dispensacion {"id_lote": 9, "id_medico": 10, "id_usuario": 7, "id_paciente": 16, "folio_operacion": "6bf691c7-0e3e-43d4-a518-d5fa0b612cc0", "id_dispensacion": 101, "cantidad_dispensada": 2, "id_ubicacion_origen": 5, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 9, "id_medico": 10, "id_usuario": 7, "id_paciente": 16, "folio_operacion": "6bf691c7-0e3e-43d4-a518-d5fa0b612cc0", "id_dispensacion": 101, "cantidad_dispensada": 2, "id_ubicacion_origen": 5, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
500	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 48, "cantidad": 4, "id_ubicacion": 8}	{"id_lote": 48, "cantidad": 6, "id_ubicacion": 8}	{"id_lote": 48, "cantidad": 4, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.107
501	7	INSERT	dispensacion	dispensacion {"id_lote": 48, "id_medico": 12, "id_usuario": 7, "id_paciente": 23, "folio_operacion": "602e720f-7620-42be-97ce-cceb445e6679", "id_dispensacion": 102, "cantidad_dispensada": 2, "id_ubicacion_origen": 8, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 48, "id_medico": 12, "id_usuario": 7, "id_paciente": 23, "folio_operacion": "602e720f-7620-42be-97ce-cceb445e6679", "id_dispensacion": 102, "cantidad_dispensada": 2, "id_ubicacion_origen": 8, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
502	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 42, "cantidad": 14, "id_ubicacion": 6}	{"id_lote": 42, "cantidad": 15, "id_ubicacion": 6}	{"id_lote": 42, "cantidad": 14, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.107
503	7	INSERT	dispensacion	dispensacion {"id_lote": 42, "id_medico": 7, "id_usuario": 7, "id_paciente": 3, "folio_operacion": "81ff22c0-368b-4002-9254-b251fd630d0d", "id_dispensacion": 103, "cantidad_dispensada": 1, "id_ubicacion_origen": 6, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 42, "id_medico": 7, "id_usuario": 7, "id_paciente": 3, "folio_operacion": "81ff22c0-368b-4002-9254-b251fd630d0d", "id_dispensacion": 103, "cantidad_dispensada": 1, "id_ubicacion_origen": 6, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
504	5	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 19, "cantidad": 15, "id_ubicacion": 1}	{"id_lote": 19, "cantidad": 33, "id_ubicacion": 1}	{"id_lote": 19, "cantidad": 15, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.105
505	5	INSERT	dispensacion	dispensacion {"id_lote": 19, "id_medico": null, "id_usuario": 5, "id_paciente": null, "folio_operacion": "bedfde10-5731-4ea9-8858-2c42bde4be99", "id_dispensacion": 104, "cantidad_dispensada": 18, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 19, "id_medico": null, "id_usuario": 5, "id_paciente": null, "folio_operacion": "bedfde10-5731-4ea9-8858-2c42bde4be99", "id_dispensacion": 104, "cantidad_dispensada": 18, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.105
506	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 30, "cantidad": 7, "id_ubicacion": 2}	{"id_lote": 30, "cantidad": 8, "id_ubicacion": 2}	{"id_lote": 30, "cantidad": 7, "id_ubicacion": 2}	2026-11-17 18:05:30.454005-06	192.168.1.102
507	2	INSERT	dispensacion	dispensacion {"id_lote": 30, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "2173b69d-1399-4b94-b909-973d53a7208a", "id_dispensacion": 105, "cantidad_dispensada": 1, "id_ubicacion_origen": 2, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 30, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "2173b69d-1399-4b94-b909-973d53a7208a", "id_dispensacion": 105, "cantidad_dispensada": 1, "id_ubicacion_origen": 2, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
508	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 16, "cantidad": 69, "id_ubicacion": 1}	{"id_lote": 16, "cantidad": 77, "id_ubicacion": 1}	{"id_lote": 16, "cantidad": 69, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
509	8	INSERT	dispensacion	dispensacion {"id_lote": 16, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "be8d3b8c-0b47-4f69-aee9-6f2d93e34039", "id_dispensacion": 106, "cantidad_dispensada": 8, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 16, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "be8d3b8c-0b47-4f69-aee9-6f2d93e34039", "id_dispensacion": 106, "cantidad_dispensada": 8, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
510	5	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 12, "cantidad": 9, "id_ubicacion": 5}	{"id_lote": 12, "cantidad": 10, "id_ubicacion": 5}	{"id_lote": 12, "cantidad": 9, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.105
511	5	INSERT	dispensacion	dispensacion {"id_lote": 12, "id_medico": 3, "id_usuario": 5, "id_paciente": 2, "folio_operacion": "2020bca5-845b-4dce-af96-83a0f72a4a4e", "id_dispensacion": 107, "cantidad_dispensada": 1, "id_ubicacion_origen": 5, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 12, "id_medico": 3, "id_usuario": 5, "id_paciente": 2, "folio_operacion": "2020bca5-845b-4dce-af96-83a0f72a4a4e", "id_dispensacion": 107, "cantidad_dispensada": 1, "id_ubicacion_origen": 5, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.105
512	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 26, "cantidad": 13, "id_ubicacion": 1}	{"id_lote": 26, "cantidad": 15, "id_ubicacion": 1}	{"id_lote": 26, "cantidad": 13, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
513	6	INSERT	dispensacion	dispensacion {"id_lote": 26, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "a1919248-70df-4c72-80f9-484717f24099", "id_dispensacion": 108, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 26, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "a1919248-70df-4c72-80f9-484717f24099", "id_dispensacion": 108, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
514	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 45, "cantidad": 16, "id_ubicacion": 6}	{"id_lote": 45, "cantidad": 27, "id_ubicacion": 6}	{"id_lote": 45, "cantidad": 16, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.106
515	6	INSERT	dispensacion	dispensacion {"id_lote": 45, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "cad6dbf7-2110-4996-93c2-c4bef2a6cccb", "id_dispensacion": 109, "cantidad_dispensada": 11, "id_ubicacion_origen": 6, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 45, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "cad6dbf7-2110-4996-93c2-c4bef2a6cccb", "id_dispensacion": 109, "cantidad_dispensada": 11, "id_ubicacion_origen": 6, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
516	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 8, "cantidad": 2, "id_ubicacion": 3}	{"id_lote": 8, "cantidad": 3, "id_ubicacion": 3}	{"id_lote": 8, "cantidad": 2, "id_ubicacion": 3}	2026-11-17 18:05:30.454005-06	192.168.1.106
517	6	INSERT	dispensacion	dispensacion {"id_lote": 8, "id_medico": 5, "id_usuario": 6, "id_paciente": 4, "folio_operacion": "1fc62134-a93d-40bb-8876-2a2d9b4a137c", "id_dispensacion": 110, "cantidad_dispensada": 1, "id_ubicacion_origen": 3, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 8, "id_medico": 5, "id_usuario": 6, "id_paciente": 4, "folio_operacion": "1fc62134-a93d-40bb-8876-2a2d9b4a137c", "id_dispensacion": 110, "cantidad_dispensada": 1, "id_ubicacion_origen": 3, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
518	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 14, "cantidad": 5, "id_ubicacion": 2}	{"id_lote": 14, "cantidad": 6, "id_ubicacion": 2}	{"id_lote": 14, "cantidad": 5, "id_ubicacion": 2}	2026-11-17 18:05:30.454005-06	192.168.1.106
519	6	INSERT	dispensacion	dispensacion {"id_lote": 14, "id_medico": 5, "id_usuario": 6, "id_paciente": 23, "folio_operacion": "49151d6b-0b00-43c1-8e54-a7aa9557cd0c", "id_dispensacion": 111, "cantidad_dispensada": 1, "id_ubicacion_origen": 2, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 14, "id_medico": 5, "id_usuario": 6, "id_paciente": 23, "folio_operacion": "49151d6b-0b00-43c1-8e54-a7aa9557cd0c", "id_dispensacion": 111, "cantidad_dispensada": 1, "id_ubicacion_origen": 2, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
520	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 23, "cantidad": 30, "id_ubicacion": 9}	{"id_lote": 23, "cantidad": 34, "id_ubicacion": 9}	{"id_lote": 23, "cantidad": 30, "id_ubicacion": 9}	2026-11-17 18:05:30.454005-06	192.168.1.106
521	6	INSERT	dispensacion	dispensacion {"id_lote": 23, "id_medico": 2, "id_usuario": 6, "id_paciente": 15, "folio_operacion": "afbe8c46-116c-40b1-9cca-24138b3c0070", "id_dispensacion": 112, "cantidad_dispensada": 4, "id_ubicacion_origen": 9, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 23, "id_medico": 2, "id_usuario": 6, "id_paciente": 15, "folio_operacion": "afbe8c46-116c-40b1-9cca-24138b3c0070", "id_dispensacion": 112, "cantidad_dispensada": 4, "id_ubicacion_origen": 9, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
522	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 14, "cantidad": 4, "id_ubicacion": 2}	{"id_lote": 14, "cantidad": 5, "id_ubicacion": 2}	{"id_lote": 14, "cantidad": 4, "id_ubicacion": 2}	2026-11-17 18:05:30.454005-06	192.168.1.102
523	2	INSERT	dispensacion	dispensacion {"id_lote": 14, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "32ae2cc8-e006-4076-9d81-942c6b231bb5", "id_dispensacion": 113, "cantidad_dispensada": 1, "id_ubicacion_origen": 2, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 14, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "32ae2cc8-e006-4076-9d81-942c6b231bb5", "id_dispensacion": 113, "cantidad_dispensada": 1, "id_ubicacion_origen": 2, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
524	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 8, "cantidad": 0, "id_ubicacion": 3}	{"id_lote": 8, "cantidad": 2, "id_ubicacion": 3}	{"id_lote": 8, "cantidad": 0, "id_ubicacion": 3}	2026-11-17 18:05:30.454005-06	192.168.1.102
525	2	INSERT	dispensacion	dispensacion {"id_lote": 8, "id_medico": 10, "id_usuario": 2, "id_paciente": 15, "folio_operacion": "572842c7-4ace-46c4-ab56-dcf5a116a838", "id_dispensacion": 114, "cantidad_dispensada": 2, "id_ubicacion_origen": 3, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 8, "id_medico": 10, "id_usuario": 2, "id_paciente": 15, "folio_operacion": "572842c7-4ace-46c4-ab56-dcf5a116a838", "id_dispensacion": 114, "cantidad_dispensada": 2, "id_ubicacion_origen": 3, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
526	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 31, "cantidad": 23, "id_ubicacion": 1}	{"id_lote": 31, "cantidad": 25, "id_ubicacion": 1}	{"id_lote": 31, "cantidad": 23, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
527	2	INSERT	dispensacion	dispensacion {"id_lote": 31, "id_medico": 5, "id_usuario": 2, "id_paciente": 5, "folio_operacion": "7bdf8965-68bb-43b9-8003-b04d4e7f00f1", "id_dispensacion": 115, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 31, "id_medico": 5, "id_usuario": 2, "id_paciente": 5, "folio_operacion": "7bdf8965-68bb-43b9-8003-b04d4e7f00f1", "id_dispensacion": 115, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
528	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 30, "cantidad": 10, "id_ubicacion": 1}	{"id_lote": 30, "cantidad": 29, "id_ubicacion": 1}	{"id_lote": 30, "cantidad": 10, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
529	7	INSERT	dispensacion	dispensacion {"id_lote": 30, "id_medico": 9, "id_usuario": 7, "id_paciente": 2, "folio_operacion": "a60a20f9-3a1e-4259-a5b7-555ba6685d7f", "id_dispensacion": 116, "cantidad_dispensada": 19, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 30, "id_medico": 9, "id_usuario": 7, "id_paciente": 2, "folio_operacion": "a60a20f9-3a1e-4259-a5b7-555ba6685d7f", "id_dispensacion": 116, "cantidad_dispensada": 19, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
530	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 33, "cantidad": 8, "id_ubicacion": 1}	{"id_lote": 33, "cantidad": 10, "id_ubicacion": 1}	{"id_lote": 33, "cantidad": 8, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
531	2	INSERT	dispensacion	dispensacion {"id_lote": 33, "id_medico": 10, "id_usuario": 2, "id_paciente": 20, "folio_operacion": "de5e8e4f-897c-4d57-81f3-7c5c186849f0", "id_dispensacion": 117, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 33, "id_medico": 10, "id_usuario": 2, "id_paciente": 20, "folio_operacion": "de5e8e4f-897c-4d57-81f3-7c5c186849f0", "id_dispensacion": 117, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
532	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 29, "cantidad": 35, "id_ubicacion": 1}	{"id_lote": 29, "cantidad": 50, "id_ubicacion": 1}	{"id_lote": 29, "cantidad": 35, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
533	6	INSERT	dispensacion	dispensacion {"id_lote": 29, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "b53903f1-dd6c-4a78-859a-06d14d3ace64", "id_dispensacion": 118, "cantidad_dispensada": 15, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 29, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "b53903f1-dd6c-4a78-859a-06d14d3ace64", "id_dispensacion": 118, "cantidad_dispensada": 15, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
534	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 32, "cantidad": 37, "id_ubicacion": 1}	{"id_lote": 32, "cantidad": 45, "id_ubicacion": 1}	{"id_lote": 32, "cantidad": 37, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
535	8	INSERT	dispensacion	dispensacion {"id_lote": 32, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "04f76b3d-8749-4f84-b4fe-d043fee0a199", "id_dispensacion": 119, "cantidad_dispensada": 8, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 32, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "04f76b3d-8749-4f84-b4fe-d043fee0a199", "id_dispensacion": 119, "cantidad_dispensada": 8, "id_ubicacion_origen": 1, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
536	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 44, "cantidad": 42, "id_ubicacion": 1}	{"id_lote": 44, "cantidad": 48, "id_ubicacion": 1}	{"id_lote": 44, "cantidad": 42, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
537	2	INSERT	dispensacion	dispensacion {"id_lote": 44, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "6d6b18d5-86f6-47b5-9851-4e4ffe67b13e", "id_dispensacion": 120, "cantidad_dispensada": 6, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 44, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "6d6b18d5-86f6-47b5-9851-4e4ffe67b13e", "id_dispensacion": 120, "cantidad_dispensada": 6, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
538	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 34, "cantidad": 38, "id_ubicacion": 1}	{"id_lote": 34, "cantidad": 44, "id_ubicacion": 1}	{"id_lote": 34, "cantidad": 38, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.107
539	7	INSERT	dispensacion	dispensacion {"id_lote": 34, "id_medico": 2, "id_usuario": 7, "id_paciente": 26, "folio_operacion": "89024057-0da1-475b-96f7-7c862b01057f", "id_dispensacion": 121, "cantidad_dispensada": 6, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 34, "id_medico": 2, "id_usuario": 7, "id_paciente": 26, "folio_operacion": "89024057-0da1-475b-96f7-7c862b01057f", "id_dispensacion": 121, "cantidad_dispensada": 6, "id_ubicacion_origen": 1, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
540	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 42, "cantidad": 12, "id_ubicacion": 6}	{"id_lote": 42, "cantidad": 14, "id_ubicacion": 6}	{"id_lote": 42, "cantidad": 12, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.108
541	8	INSERT	dispensacion	dispensacion {"id_lote": 42, "id_medico": 5, "id_usuario": 8, "id_paciente": 2, "folio_operacion": "19d97125-e765-4a34-998e-e4b8490a1267", "id_dispensacion": 122, "cantidad_dispensada": 2, "id_ubicacion_origen": 6, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 42, "id_medico": 5, "id_usuario": 8, "id_paciente": 2, "folio_operacion": "19d97125-e765-4a34-998e-e4b8490a1267", "id_dispensacion": 122, "cantidad_dispensada": 2, "id_ubicacion_origen": 6, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
542	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 26, "cantidad": 12, "id_ubicacion": 1}	{"id_lote": 26, "cantidad": 13, "id_ubicacion": 1}	{"id_lote": 26, "cantidad": 12, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
543	2	INSERT	dispensacion	dispensacion {"id_lote": 26, "id_medico": 10, "id_usuario": 2, "id_paciente": 21, "folio_operacion": "9dc8d5be-fcf2-4048-acbe-e3c9bc551f27", "id_dispensacion": 123, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 26, "id_medico": 10, "id_usuario": 2, "id_paciente": 21, "folio_operacion": "9dc8d5be-fcf2-4048-acbe-e3c9bc551f27", "id_dispensacion": 123, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
544	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 13, "cantidad": 46, "id_ubicacion": 6}	{"id_lote": 13, "cantidad": 48, "id_ubicacion": 6}	{"id_lote": 13, "cantidad": 46, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.107
545	7	INSERT	dispensacion	dispensacion {"id_lote": 13, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "f39992a0-5a14-446b-aaba-64ed6c39d4ae", "id_dispensacion": 124, "cantidad_dispensada": 2, "id_ubicacion_origen": 6, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 13, "id_medico": null, "id_usuario": 7, "id_paciente": null, "folio_operacion": "f39992a0-5a14-446b-aaba-64ed6c39d4ae", "id_dispensacion": 124, "cantidad_dispensada": 2, "id_ubicacion_origen": 6, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
546	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 32, "cantidad": 35, "id_ubicacion": 1}	{"id_lote": 32, "cantidad": 37, "id_ubicacion": 1}	{"id_lote": 32, "cantidad": 35, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
547	2	INSERT	dispensacion	dispensacion {"id_lote": 32, "id_medico": 6, "id_usuario": 2, "id_paciente": 18, "folio_operacion": "5268176d-9e8b-4242-ada6-a9bc6d785318", "id_dispensacion": 125, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 32, "id_medico": 6, "id_usuario": 2, "id_paciente": 18, "folio_operacion": "5268176d-9e8b-4242-ada6-a9bc6d785318", "id_dispensacion": 125, "cantidad_dispensada": 2, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
548	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 28, "cantidad": 35, "id_ubicacion": 1}	{"id_lote": 28, "cantidad": 42, "id_ubicacion": 1}	{"id_lote": 28, "cantidad": 35, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
549	6	INSERT	dispensacion	dispensacion {"id_lote": 28, "id_medico": 3, "id_usuario": 6, "id_paciente": 12, "folio_operacion": "43cda981-d1e3-460d-a8c6-375fe92e5472", "id_dispensacion": 126, "cantidad_dispensada": 7, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 28, "id_medico": 3, "id_usuario": 6, "id_paciente": 12, "folio_operacion": "43cda981-d1e3-460d-a8c6-375fe92e5472", "id_dispensacion": 126, "cantidad_dispensada": 7, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
550	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 30, "cantidad": 6, "id_ubicacion": 2}	{"id_lote": 30, "cantidad": 7, "id_ubicacion": 2}	{"id_lote": 30, "cantidad": 6, "id_ubicacion": 2}	2026-11-17 18:05:30.454005-06	192.168.1.102
551	2	INSERT	dispensacion	dispensacion {"id_lote": 30, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "1a7ea1b8-4fef-4ef2-8629-d4915daed0d7", "id_dispensacion": 127, "cantidad_dispensada": 1, "id_ubicacion_origen": 2, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 30, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "1a7ea1b8-4fef-4ef2-8629-d4915daed0d7", "id_dispensacion": 127, "cantidad_dispensada": 1, "id_ubicacion_origen": 2, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
552	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 9, "cantidad": 12, "id_ubicacion": 5}	{"id_lote": 9, "cantidad": 16, "id_ubicacion": 5}	{"id_lote": 9, "cantidad": 12, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.106
553	6	INSERT	dispensacion	dispensacion {"id_lote": 9, "id_medico": 9, "id_usuario": 6, "id_paciente": 16, "folio_operacion": "5a994a89-ece0-462d-b62e-6e69be4f637c", "id_dispensacion": 128, "cantidad_dispensada": 4, "id_ubicacion_origen": 5, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 9, "id_medico": 9, "id_usuario": 6, "id_paciente": 16, "folio_operacion": "5a994a89-ece0-462d-b62e-6e69be4f637c", "id_dispensacion": 128, "cantidad_dispensada": 4, "id_ubicacion_origen": 5, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
554	7	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 8, "cantidad": 8, "id_ubicacion": 5}	{"id_lote": 8, "cantidad": 9, "id_ubicacion": 5}	{"id_lote": 8, "cantidad": 8, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.107
555	7	INSERT	dispensacion	dispensacion {"id_lote": 8, "id_medico": 6, "id_usuario": 7, "id_paciente": 3, "folio_operacion": "d4f66f0e-1d9a-45a5-8985-bb526d58d972", "id_dispensacion": 129, "cantidad_dispensada": 1, "id_ubicacion_origen": 5, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 8, "id_medico": 6, "id_usuario": 7, "id_paciente": 3, "folio_operacion": "d4f66f0e-1d9a-45a5-8985-bb526d58d972", "id_dispensacion": 129, "cantidad_dispensada": 1, "id_ubicacion_origen": 5, "id_ubicacion_destino": 10, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.107
556	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 33, "cantidad": 1, "id_ubicacion": 7}	{"id_lote": 33, "cantidad": 3, "id_ubicacion": 7}	{"id_lote": 33, "cantidad": 1, "id_ubicacion": 7}	2026-11-17 18:05:30.454005-06	192.168.1.108
557	8	INSERT	dispensacion	dispensacion {"id_lote": 33, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "58b1d581-0f8e-4e19-b150-3ac051e30855", "id_dispensacion": 130, "cantidad_dispensada": 2, "id_ubicacion_origen": 7, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 33, "id_medico": null, "id_usuario": 8, "id_paciente": null, "folio_operacion": "58b1d581-0f8e-4e19-b150-3ac051e30855", "id_dispensacion": 130, "cantidad_dispensada": 2, "id_ubicacion_origen": 7, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
558	1	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 10, "cantidad": 0, "id_ubicacion": 3}	{"id_lote": 10, "cantidad": 12, "id_ubicacion": 3}	{"id_lote": 10, "cantidad": 0, "id_ubicacion": 3}	2026-11-17 18:05:30.454005-06	192.168.1.101
559	1	INSERT	dispensacion	dispensacion {"id_lote": 10, "id_medico": 7, "id_usuario": 1, "id_paciente": 19, "folio_operacion": "9756b095-5feb-45a5-9971-7ee8bea1d5d8", "id_dispensacion": 131, "cantidad_dispensada": 12, "id_ubicacion_origen": 3, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 10, "id_medico": 7, "id_usuario": 1, "id_paciente": 19, "folio_operacion": "9756b095-5feb-45a5-9971-7ee8bea1d5d8", "id_dispensacion": 131, "cantidad_dispensada": 12, "id_ubicacion_origen": 3, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.101
560	1	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 11, "cantidad": 18, "id_ubicacion": 3}	{"id_lote": 11, "cantidad": 20, "id_ubicacion": 3}	{"id_lote": 11, "cantidad": 18, "id_ubicacion": 3}	2026-11-17 18:05:30.454005-06	192.168.1.101
561	1	INSERT	dispensacion	dispensacion {"id_lote": 11, "id_medico": 7, "id_usuario": 1, "id_paciente": 19, "folio_operacion": "9756b095-5feb-45a5-9971-7ee8bea1d5d8", "id_dispensacion": 132, "cantidad_dispensada": 2, "id_ubicacion_origen": 3, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 11, "id_medico": 7, "id_usuario": 1, "id_paciente": 19, "folio_operacion": "9756b095-5feb-45a5-9971-7ee8bea1d5d8", "id_dispensacion": 132, "cantidad_dispensada": 2, "id_ubicacion_origen": 3, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.101
562	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 8, "cantidad": 6, "id_ubicacion": 5}	{"id_lote": 8, "cantidad": 8, "id_ubicacion": 5}	{"id_lote": 8, "cantidad": 6, "id_ubicacion": 5}	2026-11-17 18:05:30.454005-06	192.168.1.102
563	2	INSERT	dispensacion	dispensacion {"id_lote": 8, "id_medico": 6, "id_usuario": 2, "id_paciente": 26, "folio_operacion": "4384b813-5191-4a7c-9315-fcdc27c33690", "id_dispensacion": 133, "cantidad_dispensada": 2, "id_ubicacion_origen": 5, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 8, "id_medico": 6, "id_usuario": 2, "id_paciente": 26, "folio_operacion": "4384b813-5191-4a7c-9315-fcdc27c33690", "id_dispensacion": 133, "cantidad_dispensada": 2, "id_ubicacion_origen": 5, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
564	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 23, "cantidad": 50, "id_ubicacion": 1}	{"id_lote": 23, "cantidad": 74, "id_ubicacion": 1}	{"id_lote": 23, "cantidad": 50, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
565	6	INSERT	dispensacion	dispensacion {"id_lote": 23, "id_medico": 9, "id_usuario": 6, "id_paciente": 14, "folio_operacion": "d1d15d51-148b-473d-ad5b-6a778c50d5c0", "id_dispensacion": 134, "cantidad_dispensada": 24, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 23, "id_medico": 9, "id_usuario": 6, "id_paciente": 14, "folio_operacion": "d1d15d51-148b-473d-ad5b-6a778c50d5c0", "id_dispensacion": 134, "cantidad_dispensada": 24, "id_ubicacion_origen": 1, "id_ubicacion_destino": 11, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
566	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 21, "cantidad": 12, "id_ubicacion": 8}	{"id_lote": 21, "cantidad": 22, "id_ubicacion": 8}	{"id_lote": 21, "cantidad": 12, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.102
567	2	INSERT	dispensacion	dispensacion {"id_lote": 21, "id_medico": 4, "id_usuario": 2, "id_paciente": 16, "folio_operacion": "87584ed2-d643-4ea7-a5ef-e88f7849ae02", "id_dispensacion": 135, "cantidad_dispensada": 10, "id_ubicacion_origen": 8, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 21, "id_medico": 4, "id_usuario": 2, "id_paciente": 16, "folio_operacion": "87584ed2-d643-4ea7-a5ef-e88f7849ae02", "id_dispensacion": 135, "cantidad_dispensada": 10, "id_ubicacion_origen": 8, "id_ubicacion_destino": 12, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
568	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 42, "cantidad": 11, "id_ubicacion": 6}	{"id_lote": 42, "cantidad": 12, "id_ubicacion": 6}	{"id_lote": 42, "cantidad": 11, "id_ubicacion": 6}	2026-11-17 18:05:30.454005-06	192.168.1.108
569	8	INSERT	dispensacion	dispensacion {"id_lote": 42, "id_medico": 9, "id_usuario": 8, "id_paciente": 24, "folio_operacion": "70665298-2c0a-4280-b1e6-47eab79a3953", "id_dispensacion": 136, "cantidad_dispensada": 1, "id_ubicacion_origen": 6, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 42, "id_medico": 9, "id_usuario": 8, "id_paciente": 24, "folio_operacion": "70665298-2c0a-4280-b1e6-47eab79a3953", "id_dispensacion": 136, "cantidad_dispensada": 1, "id_ubicacion_origen": 6, "id_ubicacion_destino": 2, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
570	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 17, "cantidad": 10, "id_ubicacion": 1}	{"id_lote": 17, "cantidad": 11, "id_ubicacion": 1}	{"id_lote": 17, "cantidad": 10, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
571	6	INSERT	dispensacion	dispensacion {"id_lote": 17, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "695c4465-75d2-4ff2-a7ae-abe5b067c484", "id_dispensacion": 137, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 17, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "695c4465-75d2-4ff2-a7ae-abe5b067c484", "id_dispensacion": 137, "cantidad_dispensada": 1, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
572	8	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 35, "cantidad": 34, "id_ubicacion": 1}	{"id_lote": 35, "cantidad": 41, "id_ubicacion": 1}	{"id_lote": 35, "cantidad": 34, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.108
573	8	INSERT	dispensacion	dispensacion {"id_lote": 35, "id_medico": 11, "id_usuario": 8, "id_paciente": 9, "folio_operacion": "84ebebea-d409-4acc-811f-19ca6115d7fa", "id_dispensacion": 138, "cantidad_dispensada": 7, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 35, "id_medico": 11, "id_usuario": 8, "id_paciente": 9, "folio_operacion": "84ebebea-d409-4acc-811f-19ca6115d7fa", "id_dispensacion": 138, "cantidad_dispensada": 7, "id_ubicacion_origen": 1, "id_ubicacion_destino": 7, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.108
574	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 48, "cantidad": 3, "id_ubicacion": 8}	{"id_lote": 48, "cantidad": 4, "id_ubicacion": 8}	{"id_lote": 48, "cantidad": 3, "id_ubicacion": 8}	2026-11-17 18:05:30.454005-06	192.168.1.102
575	2	INSERT	dispensacion	dispensacion {"id_lote": 48, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "3aaefb70-d9c9-4e04-b079-f0e37f289bb3", "id_dispensacion": 139, "cantidad_dispensada": 1, "id_ubicacion_origen": 8, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 48, "id_medico": null, "id_usuario": 2, "id_paciente": null, "folio_operacion": "3aaefb70-d9c9-4e04-b079-f0e37f289bb3", "id_dispensacion": 139, "cantidad_dispensada": 1, "id_ubicacion_origen": 8, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
576	6	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 47, "cantidad": 20, "id_ubicacion": 1}	{"id_lote": 47, "cantidad": 27, "id_ubicacion": 1}	{"id_lote": 47, "cantidad": 20, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.106
577	6	INSERT	dispensacion	dispensacion {"id_lote": 47, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "f10046a4-8b0f-4217-a1b5-7392fca03dc0", "id_dispensacion": 140, "cantidad_dispensada": 7, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 47, "id_medico": null, "id_usuario": 6, "id_paciente": null, "folio_operacion": "f10046a4-8b0f-4217-a1b5-7392fca03dc0", "id_dispensacion": 140, "cantidad_dispensada": 7, "id_ubicacion_origen": 1, "id_ubicacion_destino": 8, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.106
578	2	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 16, "cantidad": 60, "id_ubicacion": 1}	{"id_lote": 16, "cantidad": 69, "id_ubicacion": 1}	{"id_lote": 16, "cantidad": 60, "id_ubicacion": 1}	2026-11-17 18:05:30.454005-06	192.168.1.102
579	2	INSERT	dispensacion	dispensacion {"id_lote": 16, "id_medico": 7, "id_usuario": 2, "id_paciente": 24, "folio_operacion": "7362e29f-63ec-42aa-88d6-795dcc48cac7", "id_dispensacion": 141, "cantidad_dispensada": 9, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	\N	{"id_lote": 16, "id_medico": 7, "id_usuario": 2, "id_paciente": 24, "folio_operacion": "7362e29f-63ec-42aa-88d6-795dcc48cac7", "id_dispensacion": 141, "cantidad_dispensada": 9, "id_ubicacion_origen": 1, "id_ubicacion_destino": 9, "fecha_hora_dispensacion": "2026-11-17T18:05:30.454005-06:00"}	2026-11-17 18:05:30.454005-06	192.168.1.102
580	3	UPDATE	usuario	usuario {"activo": false, "correo": "pedro.gallegos@hospital.mx", "id_rol": 2, "nombre": "Pedro Gallegos", "id_usuario": 5}	{"activo": true, "correo": "pedro.gallegos@hospital.mx", "id_rol": 2, "nombre": "Pedro Gallegos", "id_usuario": 5}	{"activo": false, "correo": "pedro.gallegos@hospital.mx", "id_rol": 2, "nombre": "Pedro Gallegos", "id_usuario": 5}	2026-11-17 18:05:30.454005-06	192.168.1.103
581	1	UPDATE	lote_ubicacion	lote_ubicacion {"id_lote": 14, "cantidad": 31, "id_ubicacion": 1}	{"id_lote": 14, "cantidad": 40, "id_ubicacion": 1}	{"id_lote": 14, "cantidad": 31, "id_ubicacion": 1}	2026-11-17 19:23:58.582767-06	127.0.0.1
582	1	INSERT	dispensacion	dispensacion {"id_lote": 14, "id_medico": 3, "id_usuario": 1, "id_paciente": 16, "folio_operacion": "7d1659b4-d6f3-4605-acc7-984b5cb85b52", "id_dispensacion": 142, "cantidad_dispensada": 9, "id_ubicacion_origen": 1, "id_ubicacion_destino": 1, "fecha_hora_dispensacion": "2026-11-17T19:23:58.582767-06:00"}	\N	{"id_lote": 14, "id_medico": 3, "id_usuario": 1, "id_paciente": 16, "folio_operacion": "7d1659b4-d6f3-4605-acc7-984b5cb85b52", "id_dispensacion": 142, "cantidad_dispensada": 9, "id_ubicacion_origen": 1, "id_ubicacion_destino": 1, "fecha_hora_dispensacion": "2026-11-17T19:23:58.582767-06:00"}	2026-11-17 19:23:58.582767-06	127.0.0.1
\.


--
-- Data for Name: dispensacion; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.dispensacion (id_dispensacion, folio_operacion, id_lote, id_ubicacion_origen, id_ubicacion_destino, id_medico, id_paciente, id_usuario, cantidad_dispensada, fecha_hora_dispensacion) FROM stdin;
7	bba8dbcc-bb2a-4da5-b1ae-9cde33ef4a8b	25	1	8	5	4	5	9	2026-11-17 18:05:30.454005-06
8	e03eb86f-a5d8-4157-baa7-42c077bb3128	36	1	10	6	2	5	8	2026-11-17 18:05:30.454005-06
9	b109beae-0c6e-46e9-854f-5f919a5956cc	17	1	9	\N	\N	6	19	2026-11-17 18:05:30.454005-06
10	17772c1b-a7af-4cef-ae17-ce6c63e4f97f	43	1	10	6	12	8	3	2026-11-17 18:05:30.454005-06
11	4ee58a28-f22c-49d3-8d9b-901252103573	47	1	8	\N	\N	7	2	2026-11-17 18:05:30.454005-06
12	5566c53f-9a4a-4c9f-8f96-1303cffdb3ab	26	1	12	6	2	6	2	2026-11-17 18:05:30.454005-06
13	00c4524c-c80f-401e-8a38-4565f123a220	35	1	11	12	19	8	13	2026-11-17 18:05:30.454005-06
14	260d6229-3901-49fe-9c6e-f4f923e4a775	33	7	11	4	24	6	3	2026-11-17 18:05:30.454005-06
15	6e1e1dc3-8a18-4c69-ac0e-ab434e165b0c	25	1	8	6	24	2	10	2026-11-17 18:05:30.454005-06
16	f1b325aa-bba6-403d-9d24-53f1029288b7	27	1	11	6	19	1	10	2026-11-17 18:05:30.454005-06
17	7c114907-5134-4f47-bdeb-2d34fef0ba48	21	8	12	3	2	2	3	2026-11-17 18:05:30.454005-06
18	7f9a3dfb-be8b-4780-9ffb-91ac50226e82	33	1	7	5	21	6	1	2026-11-17 18:05:30.454005-06
19	ab18675b-72b2-4de0-86af-b2ffc1f64c02	34	1	10	4	6	7	2	2026-11-17 18:05:30.454005-06
20	5dfdba47-bd5f-4b83-bf14-9a4fe9bbae23	17	1	9	\N	\N	7	69	2026-11-17 18:05:30.454005-06
21	18fc9ebe-f640-458c-9eb0-4265b3d33720	35	1	2	2	11	6	6	2026-11-17 18:05:30.454005-06
22	576d8805-c437-4084-83f0-8f0df24ccc47	28	1	8	\N	\N	2	2	2026-11-17 18:05:30.454005-06
23	993820f1-f925-47c2-9450-e47d00e01607	40	1	7	11	12	8	2	2026-11-17 18:05:30.454005-06
24	0d9d4631-807a-452a-ae9a-c515932d1316	40	1	9	\N	\N	8	16	2026-11-17 18:05:30.454005-06
25	88cd113f-c1cb-4886-bffb-d78cb6eed255	40	1	8	2	5	8	12	2026-11-17 18:05:30.454005-06
26	46fd4df4-b4a5-41c7-8220-5d645ba6cb2a	14	2	10	\N	\N	1	1	2026-11-17 18:05:30.454005-06
27	e42ecc91-f827-4656-baf0-52f5dd5886c2	48	8	9	3	17	2	2	2026-11-17 18:05:30.454005-06
28	031f8361-cbf4-4994-9fd3-b4b2fa63c2ab	31	1	11	7	18	5	7	2026-11-17 18:05:30.454005-06
29	d0d06c42-2c75-4bdb-864f-2896559b96d2	35	1	7	12	11	7	3	2026-11-17 18:05:30.454005-06
30	ee79ea92-2f36-4c02-8635-1088a36b8015	8	5	2	8	5	7	1	2026-11-17 18:05:30.454005-06
31	db33ea61-6d01-47da-a98e-0665781365cb	43	1	12	5	25	6	2	2026-11-17 18:05:30.454005-06
32	3e104fce-91af-4768-a80b-38885842c146	7	5	8	6	17	5	10	2026-11-17 18:05:30.454005-06
33	3e104fce-91af-4768-a80b-38885842c146	6	5	8	6	17	5	2	2026-11-17 18:05:30.454005-06
34	29f7e65e-e1a4-4843-9bcc-fbd765a0d253	12	5	10	10	14	6	2	2026-11-17 18:05:30.454005-06
35	23f3cd1c-c2d5-4bed-b7d8-654ea70fa36d	50	9	11	8	13	2	10	2026-11-17 18:05:30.454005-06
36	10c10bb5-7095-4e88-b977-68998a0190fa	33	1	11	\N	\N	2	3	2026-11-17 18:05:30.454005-06
37	69701389-8995-4b13-b1e2-b42164f3e772	41	4	11	\N	\N	7	13	2026-11-17 18:05:30.454005-06
38	8132c199-9598-40ce-9bcb-580edbc3a1d6	38	1	8	4	21	7	140	2026-11-17 18:05:30.454005-06
39	8132c199-9598-40ce-9bcb-580edbc3a1d6	39	1	8	4	21	7	10	2026-11-17 18:05:30.454005-06
40	3ab9907c-b9f0-43bb-ad49-64da3ac5cdc0	36	1	12	\N	\N	8	32	2026-11-17 18:05:30.454005-06
41	98ba2b0b-1d72-47d5-81d0-79541f704681	5	1	11	1	18	1	28	2026-11-17 18:05:30.454005-06
42	9bada4f6-ec77-4f89-86dc-09d89cbfde8c	43	1	9	7	17	8	1	2026-11-17 18:05:30.454005-06
43	ba2c146c-6e6e-4b9a-b893-b675a823d572	5	1	2	7	1	6	14	2026-11-17 18:05:30.454005-06
44	6c838373-7e6c-4e5c-8dc9-31d8a3fc1c7b	49	1	9	12	7	2	4	2026-11-17 18:05:30.454005-06
45	a5fb8848-f365-4424-8703-604fa673ff26	49	1	11	\N	\N	8	1	2026-11-17 18:05:30.454005-06
46	566133dc-0932-4b8c-9be3-02917095d8f3	41	4	11	1	6	8	1	2026-11-17 18:05:30.454005-06
47	e81350d4-e05c-49c1-bded-b180eb9813cf	47	1	10	\N	\N	6	1	2026-11-17 18:05:30.454005-06
48	1a15fc8f-5164-48d3-856b-24a0d02b7d2a	21	8	10	4	26	5	5	2026-11-17 18:05:30.454005-06
49	1e0d2ae9-4103-4db8-a7f1-6fc104401787	8	5	8	12	12	6	4	2026-11-17 18:05:30.454005-06
50	9ef05a57-0d75-4919-a8d9-d2bb4e0eba11	23	9	11	\N	\N	8	2	2026-11-17 18:05:30.454005-06
51	465f4270-d018-4dfb-a6bc-bfb0f8d7122e	49	1	10	8	7	6	3	2026-11-17 18:05:30.454005-06
52	28971bd3-543d-4409-884e-17c6c1823d0a	33	7	8	\N	\N	8	3	2026-11-17 18:05:30.454005-06
53	136a1b5a-6987-4d64-810e-53fe94ef3ede	23	1	2	3	9	6	61	2026-11-17 18:05:30.454005-06
54	530ba178-a91b-4aee-9020-9c32f4eea5ab	16	1	11	\N	\N	2	6	2026-11-17 18:05:30.454005-06
55	f132bc9b-26ab-4e6d-81fd-6b0c7c7ff09c	8	3	12	10	18	6	7	2026-11-17 18:05:30.454005-06
56	7a4f09bf-9f54-4b94-b0ae-2472005e6d3a	49	1	10	\N	\N	6	3	2026-11-17 18:05:30.454005-06
57	decd57a7-64a4-4e9e-8e34-ff8dd37b0407	25	1	2	2	1	7	8	2026-11-17 18:05:30.454005-06
58	602265a0-c37c-4261-ba20-3535e75b2f3e	30	8	11	\N	\N	5	7	2026-11-17 18:05:30.454005-06
59	22231585-2563-479a-880d-79997497069d	45	6	12	\N	\N	7	9	2026-11-17 18:05:30.454005-06
60	85037a69-b776-4e87-95b3-ff0da8ed123f	44	1	11	\N	\N	8	11	2026-11-17 18:05:30.454005-06
61	c0758732-58de-423f-88b8-2a1bb05ebc79	50	9	12	\N	\N	7	30	2026-11-17 18:05:30.454005-06
62	317dddaa-a8a7-4579-bfa5-baf31903afc2	44	1	7	12	5	8	1	2026-11-17 18:05:30.454005-06
63	d299376c-f20c-4c08-bbc0-37f19cfab338	35	1	8	5	10	6	1	2026-11-17 18:05:30.454005-06
64	b0cbfc0a-4a88-4d8c-ad5a-c90ce31b0e0f	14	2	10	\N	\N	2	5	2026-11-17 18:05:30.454005-06
65	04520804-a598-47d4-9b80-b936ae766a15	5	1	12	\N	\N	8	18	2026-11-17 18:05:30.454005-06
66	6f2ce803-4f60-449f-9735-91de1b91748f	40	1	8	\N	\N	8	10	2026-11-17 18:05:30.454005-06
67	3e679bec-b152-4b73-bfa7-968e376c6a54	19	1	11	\N	\N	2	10	2026-11-17 18:05:30.454005-06
68	b331910c-499a-4b36-9e6b-f8da42defad7	19	1	7	4	14	6	3	2026-11-17 18:05:30.454005-06
69	93543c6f-3459-430d-b2da-d029aad4d037	43	1	7	\N	\N	5	6	2026-11-17 18:05:30.454005-06
70	cee23be9-4399-4c55-8e58-352a20ababed	25	1	2	10	3	7	3	2026-11-17 18:05:30.454005-06
71	d3769149-aceb-4685-8f2c-7218bbd06844	31	1	8	\N	\N	7	3	2026-11-17 18:05:30.454005-06
72	637419b0-72f7-409f-b13f-0fc2ba873d2b	17	1	7	12	17	6	21	2026-11-17 18:05:30.454005-06
73	6ba36fb3-50dc-4522-b6bf-7c8a4ede7b8b	30	1	9	\N	\N	8	9	2026-11-17 18:05:30.454005-06
74	0a30e4d5-036a-4af3-b72a-56fbc29f57a8	37	1	12	\N	\N	6	71	2026-11-17 18:05:30.454005-06
75	67d3d1a3-7a15-4580-895d-55a84742a0b2	43	1	12	\N	\N	6	8	2026-11-17 18:05:30.454005-06
76	de23fd24-bab2-4ab4-b459-f4d14483ea01	26	1	8	2	22	7	1	2026-11-17 18:05:30.454005-06
77	5ba0cc51-383e-4127-b48d-b7a1346fcc84	34	1	11	4	23	1	1	2026-11-17 18:05:30.454005-06
78	5e68580e-eaa1-4d06-9e08-f63d0dbc75b6	13	6	10	5	18	6	9	2026-11-17 18:05:30.454005-06
79	24a982c6-bb24-4cfa-bae2-ccb5d86e0148	16	1	9	4	4	7	4	2026-11-17 18:05:30.454005-06
80	03854ee7-44c7-46d1-8565-b6963f270bf9	28	1	9	9	12	7	16	2026-11-17 18:05:30.454005-06
81	7e4c57e9-ac27-4232-8efa-6e9f827e5afc	16	1	11	10	18	5	3	2026-11-17 18:05:30.454005-06
82	d2a4dbf2-9a65-4a77-b186-7b80901b4f6e	33	1	8	\N	\N	8	6	2026-11-17 18:05:30.454005-06
83	c4fa4960-4a68-4811-b7e4-4f1213225cb5	30	1	7	12	11	2	2	2026-11-17 18:05:30.454005-06
84	202c5bb9-d07c-409c-b925-fae7a2b635cd	37	1	2	3	11	6	69	2026-11-17 18:05:30.454005-06
85	49f15bf7-7d1f-45a4-b901-b17cbdabe774	27	1	2	\N	\N	2	10	2026-11-17 18:05:30.454005-06
86	4db621d2-f06c-4997-8939-173d441a541d	42	6	12	6	9	6	1	2026-11-17 18:05:30.454005-06
87	653c0af2-582f-47d1-a417-0ca217218713	30	8	11	6	7	6	5	2026-11-17 18:05:30.454005-06
88	42591227-e56a-4797-b0f3-ec74258e8b00	34	1	10	11	16	8	3	2026-11-17 18:05:30.454005-06
89	1fcec51f-0917-4f93-a5fe-609738213cdc	26	1	10	2	22	7	12	2026-11-17 18:05:30.454005-06
90	d9dff936-a084-4347-8c3e-18118fa4f017	19	1	11	6	22	7	9	2026-11-17 18:05:30.454005-06
91	1484a7cb-ea2f-44f5-af28-caa6dedae3ed	29	1	12	\N	\N	2	12	2026-11-17 18:05:30.454005-06
92	a7109f81-6445-4d3a-8c28-8c39f6412472	23	9	12	3	1	8	23	2026-11-17 18:05:30.454005-06
93	8b89035c-bbd0-4dbf-a0e8-ffc0df70dba9	19	1	8	1	12	2	15	2026-11-17 18:05:30.454005-06
94	077ec26a-9b91-49a6-a63a-0e10d5263a8c	29	1	7	8	14	7	13	2026-11-17 18:05:30.454005-06
95	db37d522-799e-49b3-add9-32b57b0a7b43	23	1	9	6	17	2	15	2026-11-17 18:05:30.454005-06
96	8323fe9d-6492-498b-a94b-f0e9be6dc56e	49	1	10	10	23	8	1	2026-11-17 18:05:30.454005-06
97	95b42093-d68f-4336-850c-beacbf2b57ba	23	9	12	10	26	2	1	2026-11-17 18:05:30.454005-06
98	448b94ee-03b5-46e5-885a-ca909265a34c	13	6	11	\N	\N	7	3	2026-11-17 18:05:30.454005-06
99	9b5ca1da-be86-4fd7-9ad0-1b4f0ece67a8	30	8	10	\N	\N	7	2	2026-11-17 18:05:30.454005-06
100	aa0e6020-5694-40ff-844d-13fbe1a46c8e	33	7	8	9	22	5	1	2026-11-17 18:05:30.454005-06
101	6bf691c7-0e3e-43d4-a518-d5fa0b612cc0	9	5	7	10	16	7	2	2026-11-17 18:05:30.454005-06
102	602e720f-7620-42be-97ce-cceb445e6679	48	8	10	12	23	7	2	2026-11-17 18:05:30.454005-06
103	81ff22c0-368b-4002-9254-b251fd630d0d	42	6	12	7	3	7	1	2026-11-17 18:05:30.454005-06
104	bedfde10-5731-4ea9-8858-2c42bde4be99	19	1	11	\N	\N	5	18	2026-11-17 18:05:30.454005-06
105	2173b69d-1399-4b94-b909-973d53a7208a	30	2	10	\N	\N	2	1	2026-11-17 18:05:30.454005-06
106	be8d3b8c-0b47-4f69-aee9-6f2d93e34039	16	1	11	\N	\N	8	8	2026-11-17 18:05:30.454005-06
107	2020bca5-845b-4dce-af96-83a0f72a4a4e	12	5	12	3	2	5	1	2026-11-17 18:05:30.454005-06
108	a1919248-70df-4c72-80f9-484717f24099	26	1	2	\N	\N	6	2	2026-11-17 18:05:30.454005-06
109	cad6dbf7-2110-4996-93c2-c4bef2a6cccb	45	6	10	\N	\N	6	11	2026-11-17 18:05:30.454005-06
110	1fc62134-a93d-40bb-8876-2a2d9b4a137c	8	3	8	5	4	6	1	2026-11-17 18:05:30.454005-06
111	49151d6b-0b00-43c1-8e54-a7aa9557cd0c	14	2	9	5	23	6	1	2026-11-17 18:05:30.454005-06
112	afbe8c46-116c-40b1-9cca-24138b3c0070	23	9	8	2	15	6	4	2026-11-17 18:05:30.454005-06
113	32ae2cc8-e006-4076-9d81-942c6b231bb5	14	2	11	\N	\N	2	1	2026-11-17 18:05:30.454005-06
114	572842c7-4ace-46c4-ab56-dcf5a116a838	8	3	12	10	15	2	2	2026-11-17 18:05:30.454005-06
115	7bdf8965-68bb-43b9-8003-b04d4e7f00f1	31	1	10	5	5	2	2	2026-11-17 18:05:30.454005-06
116	a60a20f9-3a1e-4259-a5b7-555ba6685d7f	30	1	9	9	2	7	19	2026-11-17 18:05:30.454005-06
117	de5e8e4f-897c-4d57-81f3-7c5c186849f0	33	1	9	10	20	2	2	2026-11-17 18:05:30.454005-06
118	b53903f1-dd6c-4a78-859a-06d14d3ace64	29	1	9	\N	\N	6	15	2026-11-17 18:05:30.454005-06
119	04f76b3d-8749-4f84-b4fe-d043fee0a199	32	1	10	\N	\N	8	8	2026-11-17 18:05:30.454005-06
120	6d6b18d5-86f6-47b5-9851-4e4ffe67b13e	44	1	12	\N	\N	2	6	2026-11-17 18:05:30.454005-06
121	89024057-0da1-475b-96f7-7c862b01057f	34	1	12	2	26	7	6	2026-11-17 18:05:30.454005-06
122	19d97125-e765-4a34-998e-e4b8490a1267	42	6	2	5	2	8	2	2026-11-17 18:05:30.454005-06
123	9dc8d5be-fcf2-4048-acbe-e3c9bc551f27	26	1	11	10	21	2	1	2026-11-17 18:05:30.454005-06
124	f39992a0-5a14-446b-aaba-64ed6c39d4ae	13	6	10	\N	\N	7	2	2026-11-17 18:05:30.454005-06
125	5268176d-9e8b-4242-ada6-a9bc6d785318	32	1	11	6	18	2	2	2026-11-17 18:05:30.454005-06
126	43cda981-d1e3-460d-a8c6-375fe92e5472	28	1	7	3	12	6	7	2026-11-17 18:05:30.454005-06
127	1a7ea1b8-4fef-4ef2-8629-d4915daed0d7	30	2	9	\N	\N	2	1	2026-11-17 18:05:30.454005-06
128	5a994a89-ece0-462d-b62e-6e69be4f637c	9	5	7	9	16	6	4	2026-11-17 18:05:30.454005-06
129	d4f66f0e-1d9a-45a5-8985-bb526d58d972	8	5	10	6	3	7	1	2026-11-17 18:05:30.454005-06
130	58b1d581-0f8e-4e19-b150-3ac051e30855	33	7	2	\N	\N	8	2	2026-11-17 18:05:30.454005-06
131	9756b095-5feb-45a5-9971-7ee8bea1d5d8	10	3	12	7	19	1	12	2026-11-17 18:05:30.454005-06
132	9756b095-5feb-45a5-9971-7ee8bea1d5d8	11	3	12	7	19	1	2	2026-11-17 18:05:30.454005-06
133	4384b813-5191-4a7c-9315-fcdc27c33690	8	5	2	6	26	2	2	2026-11-17 18:05:30.454005-06
134	d1d15d51-148b-473d-ad5b-6a778c50d5c0	23	1	11	9	14	6	24	2026-11-17 18:05:30.454005-06
135	87584ed2-d643-4ea7-a5ef-e88f7849ae02	21	8	12	4	16	2	10	2026-11-17 18:05:30.454005-06
136	70665298-2c0a-4280-b1e6-47eab79a3953	42	6	2	9	24	8	1	2026-11-17 18:05:30.454005-06
137	695c4465-75d2-4ff2-a7ae-abe5b067c484	17	1	7	\N	\N	6	1	2026-11-17 18:05:30.454005-06
138	84ebebea-d409-4acc-811f-19ca6115d7fa	35	1	7	11	9	8	7	2026-11-17 18:05:30.454005-06
139	3aaefb70-d9c9-4e04-b079-f0e37f289bb3	48	8	9	\N	\N	2	1	2026-11-17 18:05:30.454005-06
140	f10046a4-8b0f-4217-a1b5-7392fca03dc0	47	1	8	\N	\N	6	7	2026-11-17 18:05:30.454005-06
141	7362e29f-63ec-42aa-88d6-795dcc48cac7	16	1	9	7	24	2	9	2026-11-17 18:05:30.454005-06
142	7d1659b4-d6f3-4605-acc7-984b5cb85b52	14	1	1	3	16	1	9	2026-11-17 19:23:58.582767-06
\.


--
-- Data for Name: entrada_inventario; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.entrada_inventario (id_entrada, id_lote, id_ubicacion, id_usuario, cantidad, fecha_hora) FROM stdin;
1	2	1	1	4	2026-11-13 19:52:18.710701-06
2	1	1	1	10	2026-11-13 19:52:18.710701-06
3	3	3	1	4	2026-11-13 19:52:18.710701-06
4	4	4	1	12	2026-11-13 19:52:18.710701-06
5	5	1	1	500	2026-11-13 19:52:18.710701-06
6	6	5	4	20	2026-11-17 18:05:30.454005-06
7	7	5	1	10	2026-11-17 18:05:30.454005-06
8	8	5	4	14	2026-11-17 18:05:30.454005-06
9	8	3	1	10	2026-11-17 18:05:30.454005-06
10	9	5	4	18	2026-11-17 18:05:30.454005-06
11	10	3	1	12	2026-11-17 18:05:30.454005-06
12	11	3	4	20	2026-11-17 18:05:30.454005-06
13	12	5	1	12	2026-11-17 18:05:30.454005-06
14	13	6	4	60	2026-11-17 18:05:30.454005-06
15	14	1	1	40	2026-11-17 18:05:30.454005-06
16	14	2	4	12	2026-11-17 18:05:30.454005-06
17	15	1	1	8	2026-11-17 18:05:30.454005-06
18	16	1	4	90	2026-11-17 18:05:30.454005-06
19	17	1	1	120	2026-11-17 18:05:30.454005-06
20	18	1	4	60	2026-11-17 18:05:30.454005-06
21	19	1	1	70	2026-11-17 18:05:30.454005-06
22	20	1	4	80	2026-11-17 18:05:30.454005-06
23	21	1	1	40	2026-11-17 18:05:30.454005-06
24	21	8	4	30	2026-11-17 18:05:30.454005-06
25	22	1	1	60	2026-11-17 18:05:30.454005-06
26	23	1	4	150	2026-11-17 18:05:30.454005-06
27	23	9	1	60	2026-11-17 18:05:30.454005-06
28	24	1	4	15	2026-11-17 18:05:30.454005-06
29	25	1	1	85	2026-11-17 18:05:30.454005-06
30	26	1	4	30	2026-11-17 18:05:30.454005-06
31	27	1	1	20	2026-11-17 18:05:30.454005-06
32	28	1	4	90	2026-11-17 18:05:30.454005-06
33	29	1	1	100	2026-11-17 18:05:30.454005-06
34	30	1	4	40	2026-11-17 18:05:30.454005-06
35	30	8	1	20	2026-11-17 18:05:30.454005-06
36	30	2	4	8	2026-11-17 18:05:30.454005-06
37	31	1	1	50	2026-11-17 18:05:30.454005-06
38	32	1	4	45	2026-11-17 18:05:30.454005-06
39	33	1	1	20	2026-11-17 18:05:30.454005-06
40	33	7	4	10	2026-11-17 18:05:30.454005-06
41	34	1	1	70	2026-11-17 18:05:30.454005-06
42	35	1	4	64	2026-11-17 18:05:30.454005-06
43	36	1	1	150	2026-11-17 18:05:30.454005-06
44	37	1	4	600	2026-11-17 18:05:30.454005-06
45	38	1	1	180	2026-11-17 18:05:30.454005-06
46	39	1	4	220	2026-11-17 18:05:30.454005-06
47	40	1	1	160	2026-11-17 18:05:30.454005-06
48	41	4	4	24	2026-11-17 18:05:30.454005-06
49	42	6	1	16	2026-11-17 18:05:30.454005-06
50	43	1	4	70	2026-11-17 18:05:30.454005-06
51	44	1	1	60	2026-11-17 18:05:30.454005-06
52	45	6	4	36	2026-11-17 18:05:30.454005-06
53	45	12	1	12	2026-11-17 18:05:30.454005-06
54	46	6	4	40	2026-11-17 18:05:30.454005-06
55	47	1	1	40	2026-11-17 18:05:30.454005-06
56	48	8	4	8	2026-11-17 18:05:30.454005-06
57	49	1	1	45	2026-11-17 18:05:30.454005-06
58	50	9	4	150	2026-11-17 18:05:30.454005-06
\.


--
-- Data for Name: insumo; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.insumo (id_insumo, codigo_insumo, descripcion_farmaco, es_controlado, stock_minimo_seguridad, unidad_medida, activo) FROM stdin;
1	INS-8840	Propofol 200mg / 20ml	f	30	Ampolleta	t
2	INS-1029	Fentanilo 0.5mg (Controlado)	t	15	Ampolleta	t
3	INS-3321	Insulina Humana R 100UI/ml	f	20	Frasco	t
4	INS-5010	Paracetamol 500mg	f	100	Caja	t
5	INS-2001	Morfina 10mg/ml	t	12	Ampolleta	t
6	INS-2002	Midazolam 5mg/5ml	t	20	Ampolleta	t
7	INS-2003	Ketamina 500mg/10ml	t	10	Frasco ámpula	t
8	INS-2004	Diazepam 10mg/2ml	t	15	Ampolleta	t
9	INS-2005	Buprenorfina 0.3mg/ml	t	8	Ampolleta	t
10	INS-2006	Rocuronio 50mg/5ml	f	40	Frasco ámpula	t
11	INS-2007	Bupivacaína 0.5% 20ml	f	25	Frasco ámpula	t
12	INS-2008	Lidocaína 2% 100mg/5ml	f	50	Ampolleta	t
13	INS-2009	Ketorolaco 30mg/ml	f	100	Ampolleta	t
14	INS-2010	Ondansetrón 8mg/4ml	f	60	Ampolleta	t
15	INS-2011	Dexametasona 8mg/2ml	f	50	Ampolleta	t
16	INS-2012	Ceftriaxona 1g	f	120	Frasco ámpula	t
17	INS-2013	Cefazolina 1g	f	60	Frasco ámpula	t
18	INS-2014	Vancomicina 1g	f	40	Frasco ámpula	t
19	INS-2015	Meropenem 1g	f	30	Frasco ámpula	t
20	INS-2016	Ciprofloxacino 200mg/100ml	f	40	Bolsa	t
21	INS-2017	Metronidazol 500mg/100ml	f	50	Bolsa	t
22	INS-2018	Adrenalina 1mg/ml	f	60	Ampolleta	t
23	INS-2019	Atropina 1mg/ml	f	30	Ampolleta	t
24	INS-2020	Amiodarona 150mg/3ml	f	25	Ampolleta	t
25	INS-2021	Noradrenalina 4mg/4ml	f	25	Ampolleta	t
26	INS-2022	Furosemida 20mg/2ml	f	50	Ampolleta	t
27	INS-2023	Heparina sódica 5000UI/5ml	f	50	Frasco ámpula	t
28	INS-2024	Enoxaparina 40mg/0.4ml	f	60	Jeringa prellenada	t
29	INS-2025	Solución salina 0.9% 500ml	f	200	Bolsa	t
30	INS-2026	Solución Hartmann 1000ml	f	150	Bolsa	t
31	INS-2027	Solución glucosada 5% 500ml	f	100	Bolsa	t
32	INS-2028	Insulina NPH 100UI/ml	f	15	Frasco	t
33	INS-2029	Insulina glargina 100UI/ml	f	10	Pluma	t
34	INS-2030	Omeprazol 40mg IV	f	40	Frasco ámpula	t
35	INS-2031	Salbutamol 100mcg inhalador	f	30	Inhalador	t
36	INS-2032	Oxitocina 10UI/ml	f	30	Ampolleta	t
37	INS-2033	Hidrocortisona 100mg	f	25	Frasco ámpula	t
38	INS-2034	Naloxona 0.4mg/ml	f	10	Ampolleta	t
39	INS-2035	Gluconato de calcio 10% 10ml	f	20	Ampolleta	t
\.


--
-- Data for Name: lote; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.lote (id_lote, id_insumo, id_proveedor, numero_lote, fecha_fabricacion, fecha_caducidad, precio_unitario) FROM stdin;
1	1	1	#LOT-2025-0192	2024-12-13	2027-01-10	85.50
2	1	1	#LOT-2024-0081	2024-12-13	2026-11-15	85.50
3	2	1	#LOT-2026-0044	2024-12-13	2027-07-01	120.00
4	3	1	#LOT-2026-0310	2024-12-13	2027-03-03	210.00
5	4	1	#LOT-2026-0555	2024-12-13	2027-12-18	35.00
6	5	3	#LOT-2026-1101	2025-03-07	2027-08-24	48.00
7	5	3	#LOT-2025-0944	2024-07-28	2027-01-14	48.00
8	6	3	#LOT-2026-1102	2025-03-27	2027-09-13	36.00
9	7	2	#LOT-2026-1103	2025-05-16	2027-11-02	190.00
10	8	3	#LOT-2025-1004	2024-06-24	2026-12-11	22.00
11	8	3	#LOT-2026-1104	2025-07-05	2027-12-22	22.00
12	9	3	#LOT-2026-1105	2025-02-15	2027-08-04	160.00
13	10	7	#LOT-2026-1106	2024-10-28	2027-04-16	64.00
14	11	2	#LOT-2026-1107	2025-04-16	2027-10-03	58.00
16	12	4	#LOT-2026-1108	2024-12-27	2027-06-15	12.00
17	13	2	#LOT-2026-1109	2024-07-11	2026-12-28	9.80
18	13	2	#LOT-2026-1209	2025-05-31	2027-11-17	9.80
19	14	2	#LOT-2026-1110	2024-06-12	2026-11-29	14.00
20	14	2	#LOT-2026-1210	2025-03-27	2027-09-13	14.00
21	15	4	#LOT-2026-1111	2024-06-25	2026-12-12	8.00
22	15	4	#LOT-2026-1211	2025-03-07	2027-08-24	8.00
23	16	5	#LOT-2026-1112	2025-04-26	2027-10-13	21.00
25	17	5	#LOT-2026-1113	2025-02-25	2027-08-14	18.00
26	18	5	#LOT-2026-1114	2025-01-26	2027-07-15	46.00
27	19	5	#LOT-2026-1115	2024-12-17	2027-06-05	95.00
28	20	2	#LOT-2026-1116	2024-12-07	2027-05-26	35.00
29	21	2	#LOT-2026-1117	2024-11-22	2027-05-11	28.00
30	22	4	#LOT-2026-1118	2025-01-06	2027-06-25	12.00
31	23	4	#LOT-2026-1119	2024-12-22	2027-06-10	15.00
32	24	6	#LOT-2026-1120	2024-08-11	2027-01-28	62.00
33	25	6	#LOT-2026-1121	2025-02-15	2027-08-04	54.00
34	26	2	#LOT-2026-1122	2024-07-25	2027-01-11	7.00
35	27	6	#LOT-2026-1123	2025-04-06	2027-09-23	38.00
36	28	6	#LOT-2026-1124	2025-05-26	2027-11-12	78.00
37	29	4	#LOT-2026-1125	2025-04-26	2027-10-13	17.00
38	30	4	#LOT-2026-1126	2024-06-28	2026-12-15	21.00
39	30	4	#LOT-2026-1226	2025-05-06	2027-10-23	21.00
40	31	4	#LOT-2026-1127	2024-07-18	2027-01-04	19.00
41	32	7	#LOT-2026-1128	2024-10-18	2027-04-06	190.00
42	33	7	#LOT-2026-1129	2024-12-27	2027-06-15	410.00
43	34	2	#LOT-2026-1130	2024-08-24	2027-02-10	29.00
44	35	5	#LOT-2026-1131	2025-07-05	2027-12-22	88.00
45	36	7	#LOT-2026-1132	2024-06-09	2026-11-26	16.00
46	36	7	#LOT-2026-1232	2024-09-28	2027-03-17	16.00
47	37	2	#LOT-2026-1133	2025-02-25	2027-08-14	33.00
48	38	3	#LOT-2026-1134	2025-01-16	2027-07-05	120.00
49	39	2	#LOT-2026-1135	2025-02-05	2027-07-25	22.00
50	4	1	#LOT-2026-0612	2024-08-14	2027-01-31	35.00
15	12	4	#LOT-2025-1008	2024-05-25	2026-11-11	12.00
24	17	5	#LOT-2025-1013	2024-05-12	2026-10-29	18.00
\.


--
-- Data for Name: lote_ubicacion; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.lote_ubicacion (id_lote, id_ubicacion, cantidad) FROM stdin;
2	1	4
1	1	10
3	3	4
4	4	12
14	1	31
15	1	8
18	1	60
20	1	80
21	1	40
22	1	60
24	1	15
45	12	12
46	6	40
37	2	100
37	11	60
38	7	40
28	9	30
29	8	25
31	2	15
34	9	20
47	8	10
43	9	20
7	5	0
6	5	18
38	1	0
39	1	210
36	1	110
41	4	10
50	9	110
5	1	440
40	1	120
25	1	55
43	1	30
37	1	300
27	1	0
49	1	33
30	8	6
19	1	15
12	5	9
45	6	16
23	9	30
14	2	4
8	3	0
31	1	23
30	1	10
33	1	8
29	1	35
44	1	42
34	1	38
26	1	12
13	6	46
32	1	35
28	1	35
30	2	6
9	5	12
33	7	1
10	3	0
11	3	18
8	5	6
23	1	50
21	8	12
42	6	11
17	1	10
35	1	34
48	8	3
47	1	20
16	1	60
\.


--
-- Data for Name: medico; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.medico (id_medico, cedula_profesional, nombre, especialidad) FROM stdin;
1	8839201	Dr. C. Mendoza	Anestesiología
2	9120456	Dra. Patricia Villalobos	Medicina de Urgencias
3	8745123	Dr. Héctor Ibarra	Cirugía General
4	10234871	Dra. Lucía Fernández	Pediatría
5	7561290	Dr. Alejandro Cortés	Medicina Interna
6	9987345	Dra. Mariana Robles	Ginecología y Obstetricia
7	8123764	Dr. Gustavo Navarro	Cardiología
8	10456982	Dra. Sofía Pedroza	Neonatología
9	7890231	Dr. Emilio Santoyo	Ortopedia y Traumatología
10	9345617	Dra. Valeria Ochoa	Medicina Crítica
11	8567094	Dr. Rodrigo Palacios	Anestesiología
12	9678312	Dra. Teresa Quintero	Oncología Médica
\.


--
-- Data for Name: paciente; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.paciente (id_paciente, expediente_folio, nombre, area_ingreso) FROM stdin;
1	EXP-000123	J. Martínez P.	Urgencias
2	EXP-000124	Elena Ramírez Torres	Urgencias
3	EXP-000125	Miguel Ángel Soto Vega	Hospitalización
4	EXP-000126	Guadalupe Ríos Mendoza	Tococirugía
5	EXP-000127	Fernando Castañeda Lara	Terapia Intensiva
6	EXP-000128	Ana Sofía Domínguez Ruiz	Pediatría
7	EXP-000129	Luis Alberto Herrera Gil	Quirófano
8	EXP-000130	Carmen Lizeth Aguirre Peña	Hospitalización
9	EXP-000131	Javier Esparza Montes	Urgencias
10	EXP-000132	Rosa María Valdez Ortega	Oncología
11	EXP-000133	Diego Armando Cisneros	Urgencias
12	EXP-000134	Paola Andrea Beltrán Cruz	Hospitalización
13	EXP-000135	Ernesto Villaseñor Díaz	Terapia Intensiva
14	EXP-000136	Mariana Contreras Solís	Tococirugía
15	EXP-000137	Raúl Ontiveros Pineda	Quirófano
16	EXP-000138	Alejandra Nuño Barajas	Pediatría
17	EXP-000139	Jorge Luis Gaytán Reyes	Hospitalización
18	EXP-000140	Karla Vanessa Mora Cuevas	Urgencias
19	EXP-000141	Salvador Padilla Franco	Terapia Intensiva
20	EXP-000142	Yolanda Preciado Ibarra	Oncología
21	EXP-000143	Cristian Orozco Zamora	Quirófano
22	EXP-000144	Brenda Michelle Lugo Ávila	Pediatría
23	EXP-000145	Armando Delgadillo Rubio	Hospitalización
24	EXP-000146	Itzel Nayeli Corona Sáenz	Tococirugía
25	EXP-000147	Óscar Rafael Meza Bustos	Urgencias
26	EXP-000148	Verónica Tapia Campos	Hospitalización
\.


--
-- Data for Name: proveedor; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.proveedor (id_proveedor, rfc, razon_social, contacto_telefono, contacto_email) FROM stdin;
1	PCO010101AB1	Pharma Corp	33 1234 5678	ventas@pharmacorp.example
2	DMP040312K45	Distribuidora Médica del Pacífico S.A. de C.V.	33 3615 2200	pedidos@dmpacifico.example
3	LBM980715QX2	Laboratorios Biofarma de México S.A.	33 3810 4471	ventas@biofarma.example
4	IHO110228T91	Insumos Hospitalarios Occidente S.A. de C.V.	33 3121 9085	contacto@insumosocc.example
5	GFC070930L38	Grupo Farmacéutico Centauro S.A. de C.V.	33 3647 3310	licitaciones@centauro.example
6	MET150604H27	Medicamentos Especializados Tapatíos S.A.	33 3825 7742	ventas@metapatios.example
7	CFP190121AB7	Cadena Fría Pharma Logistics S.A. de C.V.	33 3770 5518	operaciones@cadenafria.example
\.


--
-- Data for Name: rol; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.rol (id_rol, nombre_rol, descripcion) FROM stdin;
1	Jefe de Farmacia	Gestión completa de inventario, entradas, traslados y reportes
2	Dispensador	Registra dispensaciones (salidas) bajo regla PEPS
3	Administrador	Gestión de usuarios y consulta de bitácora de auditoría
\.


--
-- Data for Name: usuario; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.usuario (id_usuario, id_rol, nombre, correo, hash_password, activo) FROM stdin;
1	1	Laura Hernández	jefe.farmacia@hospital.mx	$2b$12$NhFP1VIFHWmcuZd1TnJdNuyfGjZocz7kTm56Lhf5h0KFM6bVi5OSa	t
2	2	Carlos Ruiz	dispensador@hospital.mx	$2b$12$NxfEbjlCAa9No.2ISMSQw.AQaxnNcf4FxzgjAOih1yfo9mYYM./zi	t
3	3	Ana Torres	admin@hospital.mx	$2b$12$Old0XVVPdRLIMz52OU1Wq.WvxEz7QsypON/YPD/tMuycMzCukZFQq	t
4	1	Ricardo Medina Salas	ricardo.medina@hospital.mx	$2a$06$9ePYS3X/oHJyhWpZNiUP4ua9Ck9CBXUhAzW5fe8QwYkGe4tgKyuSC	t
6	2	Daniela Cárdenas	daniela.cardenas@hospital.mx	$2a$06$yj5gJ.f0onZ2CoyjjXgYYeRMz39/3bF1dui0sadkyx6BQT5HJ4bwi	t
7	2	José Luis Ramírez	jose.ramirez@hospital.mx	$2a$06$Tf29Sx71gHRePCdpzE5YVO8Ntbo37/vpfkZDAXiqegxSgp5EgaplS	t
8	2	María Fernanda Ortiz	maria.ortiz@hospital.mx	$2a$06$JFbT9IybUxLmJfiUOdY6FOpWZzEFvjo.n73TV3Z7aVujzehoo3ECy	t
9	3	Jorge Salinas	jorge.salinas@hospital.mx	$2a$06$TvKi56i9Aoh7j6QFWGUBjOOT2aac/9ohUDakYBKQmOPA7qH7z4Q3m	t
5	2	Pedro Gallegos	pedro.gallegos@hospital.mx	$2a$06$YayvmWpsramnhiEuiE074eHGkcnGXvo93coACk2hD58nAWrWCj6Uy	f
\.


--
-- Name: alerta_id_alerta_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.alerta_id_alerta_seq', 103, true);


--
-- Name: almacen_ubicacion_id_ubicacion_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.almacen_ubicacion_id_ubicacion_seq', 12, true);


--
-- Name: bitacora_auditoria_id_auditoria_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.bitacora_auditoria_id_auditoria_seq', 582, true);


--
-- Name: dispensacion_id_dispensacion_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.dispensacion_id_dispensacion_seq', 142, true);


--
-- Name: entrada_inventario_id_entrada_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.entrada_inventario_id_entrada_seq', 58, true);


--
-- Name: insumo_id_insumo_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.insumo_id_insumo_seq', 39, true);


--
-- Name: lote_id_lote_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.lote_id_lote_seq', 50, true);


--
-- Name: medico_id_medico_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.medico_id_medico_seq', 12, true);


--
-- Name: paciente_id_paciente_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.paciente_id_paciente_seq', 26, true);


--
-- Name: proveedor_id_proveedor_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.proveedor_id_proveedor_seq', 7, true);


--
-- Name: rol_id_rol_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.rol_id_rol_seq', 3, true);


--
-- Name: usuario_id_usuario_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.usuario_id_usuario_seq', 9, true);


--
-- Name: alerta alerta_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alerta
    ADD CONSTRAINT alerta_pkey PRIMARY KEY (id_alerta);


--
-- Name: almacen_ubicacion almacen_ubicacion_nombre_area_anaquel_seccion_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.almacen_ubicacion
    ADD CONSTRAINT almacen_ubicacion_nombre_area_anaquel_seccion_key UNIQUE (nombre_area, anaquel_seccion);


--
-- Name: almacen_ubicacion almacen_ubicacion_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.almacen_ubicacion
    ADD CONSTRAINT almacen_ubicacion_pkey PRIMARY KEY (id_ubicacion);


--
-- Name: bitacora_auditoria bitacora_auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bitacora_auditoria
    ADD CONSTRAINT bitacora_auditoria_pkey PRIMARY KEY (id_auditoria);


--
-- Name: dispensacion dispensacion_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dispensacion
    ADD CONSTRAINT dispensacion_pkey PRIMARY KEY (id_dispensacion);


--
-- Name: entrada_inventario entrada_inventario_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entrada_inventario
    ADD CONSTRAINT entrada_inventario_pkey PRIMARY KEY (id_entrada);


--
-- Name: insumo insumo_codigo_insumo_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.insumo
    ADD CONSTRAINT insumo_codigo_insumo_key UNIQUE (codigo_insumo);


--
-- Name: insumo insumo_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.insumo
    ADD CONSTRAINT insumo_pkey PRIMARY KEY (id_insumo);


--
-- Name: lote lote_id_insumo_numero_lote_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.lote
    ADD CONSTRAINT lote_id_insumo_numero_lote_key UNIQUE (id_insumo, numero_lote);


--
-- Name: lote lote_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.lote
    ADD CONSTRAINT lote_pkey PRIMARY KEY (id_lote);


--
-- Name: lote_ubicacion lote_ubicacion_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.lote_ubicacion
    ADD CONSTRAINT lote_ubicacion_pkey PRIMARY KEY (id_lote, id_ubicacion);


--
-- Name: medico medico_cedula_profesional_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.medico
    ADD CONSTRAINT medico_cedula_profesional_key UNIQUE (cedula_profesional);


--
-- Name: medico medico_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.medico
    ADD CONSTRAINT medico_pkey PRIMARY KEY (id_medico);


--
-- Name: paciente paciente_expediente_folio_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.paciente
    ADD CONSTRAINT paciente_expediente_folio_key UNIQUE (expediente_folio);


--
-- Name: paciente paciente_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.paciente
    ADD CONSTRAINT paciente_pkey PRIMARY KEY (id_paciente);


--
-- Name: proveedor proveedor_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.proveedor
    ADD CONSTRAINT proveedor_pkey PRIMARY KEY (id_proveedor);


--
-- Name: proveedor proveedor_rfc_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.proveedor
    ADD CONSTRAINT proveedor_rfc_key UNIQUE (rfc);


--
-- Name: rol rol_nombre_rol_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rol
    ADD CONSTRAINT rol_nombre_rol_key UNIQUE (nombre_rol);


--
-- Name: rol rol_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.rol
    ADD CONSTRAINT rol_pkey PRIMARY KEY (id_rol);


--
-- Name: usuario usuario_correo_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.usuario
    ADD CONSTRAINT usuario_correo_key UNIQUE (correo);


--
-- Name: usuario usuario_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.usuario
    ADD CONSTRAINT usuario_pkey PRIMARY KEY (id_usuario);


--
-- Name: idx_alerta_pendientes; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_alerta_pendientes ON public.alerta USING btree (fecha_generada DESC) WHERE (NOT atendida);


--
-- Name: idx_bitacora_fecha; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bitacora_fecha ON public.bitacora_auditoria USING btree (timestamp_iso DESC);


--
-- Name: idx_bitacora_tabla; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bitacora_tabla ON public.bitacora_auditoria USING btree (tabla_afectada);


--
-- Name: idx_bitacora_usuario; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_bitacora_usuario ON public.bitacora_auditoria USING btree (id_usuario, timestamp_iso DESC);


--
-- Name: idx_disp_fecha; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_disp_fecha ON public.dispensacion USING btree (fecha_hora_dispensacion DESC);


--
-- Name: idx_disp_folio; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_disp_folio ON public.dispensacion USING btree (folio_operacion);


--
-- Name: idx_disp_lote; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_disp_lote ON public.dispensacion USING btree (id_lote);


--
-- Name: idx_disp_medico; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_disp_medico ON public.dispensacion USING btree (id_medico);


--
-- Name: idx_disp_paciente; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_disp_paciente ON public.dispensacion USING btree (id_paciente);


--
-- Name: idx_entrada_fecha; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_entrada_fecha ON public.entrada_inventario USING btree (fecha_hora DESC);


--
-- Name: idx_entrada_lote; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_entrada_lote ON public.entrada_inventario USING btree (id_lote);


--
-- Name: idx_lote_caducidad; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_lote_caducidad ON public.lote USING btree (fecha_caducidad);


--
-- Name: idx_lote_insumo_caducidad; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_lote_insumo_caducidad ON public.lote USING btree (id_insumo, fecha_caducidad);


--
-- Name: idx_lote_numero; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_lote_numero ON public.lote USING btree (numero_lote);


--
-- Name: idx_lote_ubicacion_ubic; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_lote_ubicacion_ubic ON public.lote_ubicacion USING btree (id_ubicacion, id_lote) WHERE (cantidad > 0);


--
-- Name: uq_alerta_abierta; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX uq_alerta_abierta ON public.alerta USING btree (tipo, id_insumo, COALESCE(id_lote, 0)) WHERE (NOT atendida);


--
-- Name: v_stock_insumo _RETURN; Type: RULE; Schema: public; Owner: postgres
--

CREATE OR REPLACE VIEW public.v_stock_insumo AS
 SELECT id_insumo,
    codigo_insumo,
    descripcion_farmaco,
    es_controlado,
    stock_minimo_seguridad,
    stock_vigente,
    stock_caducado,
    (stock_vigente < stock_minimo_seguridad) AS bajo_minimo
   FROM ( SELECT i.id_insumo,
            i.codigo_insumo,
            i.descripcion_farmaco,
            i.es_controlado,
            i.stock_minimo_seguridad,
            (COALESCE(sum(lu.cantidad) FILTER (WHERE (l.fecha_caducidad >= CURRENT_DATE)), (0)::bigint))::integer AS stock_vigente,
            (COALESCE(sum(lu.cantidad) FILTER (WHERE (l.fecha_caducidad < CURRENT_DATE)), (0)::bigint))::integer AS stock_caducado
           FROM ((public.insumo i
             LEFT JOIN public.lote l ON ((l.id_insumo = i.id_insumo)))
             LEFT JOIN public.lote_ubicacion lu ON ((lu.id_lote = l.id_lote)))
          WHERE i.activo
          GROUP BY i.id_insumo) s;


--
-- Name: v_stock_lote _RETURN; Type: RULE; Schema: public; Owner: postgres
--

CREATE OR REPLACE VIEW public.v_stock_lote AS
 SELECT l.id_lote,
    l.numero_lote,
    l.id_insumo,
    i.codigo_insumo,
    i.descripcion_farmaco,
    l.id_proveedor,
    l.fecha_caducidad,
    (l.fecha_caducidad - CURRENT_DATE) AS dias_para_caducar,
    (COALESCE(sum(lu.cantidad), (0)::bigint))::integer AS stock_total
   FROM ((public.lote l
     JOIN public.insumo i ON ((i.id_insumo = l.id_insumo)))
     LEFT JOIN public.lote_ubicacion lu ON ((lu.id_lote = l.id_lote)))
  GROUP BY l.id_lote, i.id_insumo;


--
-- Name: almacen_ubicacion trg_auditar; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auditar AFTER INSERT OR DELETE OR UPDATE ON public.almacen_ubicacion FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


--
-- Name: dispensacion trg_auditar; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auditar AFTER INSERT OR DELETE OR UPDATE ON public.dispensacion FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


--
-- Name: entrada_inventario trg_auditar; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auditar AFTER INSERT OR DELETE OR UPDATE ON public.entrada_inventario FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


--
-- Name: insumo trg_auditar; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auditar AFTER INSERT OR DELETE OR UPDATE ON public.insumo FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


--
-- Name: lote trg_auditar; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auditar AFTER INSERT OR DELETE OR UPDATE ON public.lote FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


--
-- Name: lote_ubicacion trg_auditar; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auditar AFTER INSERT OR DELETE OR UPDATE ON public.lote_ubicacion FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


--
-- Name: medico trg_auditar; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auditar AFTER INSERT OR DELETE OR UPDATE ON public.medico FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


--
-- Name: paciente trg_auditar; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auditar AFTER INSERT OR DELETE OR UPDATE ON public.paciente FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


--
-- Name: proveedor trg_auditar; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auditar AFTER INSERT OR DELETE OR UPDATE ON public.proveedor FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


--
-- Name: rol trg_auditar; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auditar AFTER INSERT OR DELETE OR UPDATE ON public.rol FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


--
-- Name: usuario trg_auditar; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auditar AFTER INSERT OR DELETE OR UPDATE ON public.usuario FOR EACH ROW EXECUTE FUNCTION public.fn_auditar();


--
-- Name: bitacora_auditoria trg_bitacora_inmutable; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_bitacora_inmutable BEFORE DELETE OR UPDATE ON public.bitacora_auditoria FOR EACH ROW EXECUTE FUNCTION public.fn_bitacora_inmutable();


--
-- Name: bitacora_auditoria trg_bitacora_inmutable_truncate; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_bitacora_inmutable_truncate BEFORE TRUNCATE ON public.bitacora_auditoria FOR EACH STATEMENT EXECUTE FUNCTION public.fn_bitacora_inmutable();


--
-- Name: alerta alerta_id_insumo_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alerta
    ADD CONSTRAINT alerta_id_insumo_fkey FOREIGN KEY (id_insumo) REFERENCES public.insumo(id_insumo);


--
-- Name: alerta alerta_id_lote_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.alerta
    ADD CONSTRAINT alerta_id_lote_fkey FOREIGN KEY (id_lote) REFERENCES public.lote(id_lote);


--
-- Name: bitacora_auditoria bitacora_auditoria_id_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.bitacora_auditoria
    ADD CONSTRAINT bitacora_auditoria_id_usuario_fkey FOREIGN KEY (id_usuario) REFERENCES public.usuario(id_usuario);


--
-- Name: dispensacion dispensacion_id_lote_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dispensacion
    ADD CONSTRAINT dispensacion_id_lote_fkey FOREIGN KEY (id_lote) REFERENCES public.lote(id_lote);


--
-- Name: dispensacion dispensacion_id_medico_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dispensacion
    ADD CONSTRAINT dispensacion_id_medico_fkey FOREIGN KEY (id_medico) REFERENCES public.medico(id_medico);


--
-- Name: dispensacion dispensacion_id_paciente_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dispensacion
    ADD CONSTRAINT dispensacion_id_paciente_fkey FOREIGN KEY (id_paciente) REFERENCES public.paciente(id_paciente);


--
-- Name: dispensacion dispensacion_id_ubicacion_destino_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dispensacion
    ADD CONSTRAINT dispensacion_id_ubicacion_destino_fkey FOREIGN KEY (id_ubicacion_destino) REFERENCES public.almacen_ubicacion(id_ubicacion);


--
-- Name: dispensacion dispensacion_id_ubicacion_origen_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dispensacion
    ADD CONSTRAINT dispensacion_id_ubicacion_origen_fkey FOREIGN KEY (id_ubicacion_origen) REFERENCES public.almacen_ubicacion(id_ubicacion);


--
-- Name: dispensacion dispensacion_id_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dispensacion
    ADD CONSTRAINT dispensacion_id_usuario_fkey FOREIGN KEY (id_usuario) REFERENCES public.usuario(id_usuario);


--
-- Name: entrada_inventario entrada_inventario_id_lote_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entrada_inventario
    ADD CONSTRAINT entrada_inventario_id_lote_fkey FOREIGN KEY (id_lote) REFERENCES public.lote(id_lote);


--
-- Name: entrada_inventario entrada_inventario_id_ubicacion_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entrada_inventario
    ADD CONSTRAINT entrada_inventario_id_ubicacion_fkey FOREIGN KEY (id_ubicacion) REFERENCES public.almacen_ubicacion(id_ubicacion);


--
-- Name: entrada_inventario entrada_inventario_id_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.entrada_inventario
    ADD CONSTRAINT entrada_inventario_id_usuario_fkey FOREIGN KEY (id_usuario) REFERENCES public.usuario(id_usuario);


--
-- Name: lote lote_id_insumo_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.lote
    ADD CONSTRAINT lote_id_insumo_fkey FOREIGN KEY (id_insumo) REFERENCES public.insumo(id_insumo);


--
-- Name: lote lote_id_proveedor_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.lote
    ADD CONSTRAINT lote_id_proveedor_fkey FOREIGN KEY (id_proveedor) REFERENCES public.proveedor(id_proveedor);


--
-- Name: lote_ubicacion lote_ubicacion_id_lote_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.lote_ubicacion
    ADD CONSTRAINT lote_ubicacion_id_lote_fkey FOREIGN KEY (id_lote) REFERENCES public.lote(id_lote);


--
-- Name: lote_ubicacion lote_ubicacion_id_ubicacion_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.lote_ubicacion
    ADD CONSTRAINT lote_ubicacion_id_ubicacion_fkey FOREIGN KEY (id_ubicacion) REFERENCES public.almacen_ubicacion(id_ubicacion);


--
-- Name: usuario usuario_id_rol_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.usuario
    ADD CONSTRAINT usuario_id_rol_fkey FOREIGN KEY (id_rol) REFERENCES public.rol(id_rol);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO app_backend;
GRANT USAGE ON SCHEMA public TO rol_dispensador;
GRANT USAGE ON SCHEMA public TO rol_jefe_farmacia;
GRANT USAGE ON SCHEMA public TO rol_administrador;


--
-- Name: FUNCTION fn_auditar(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.fn_auditar() FROM PUBLIC;


--
-- Name: FUNCTION fn_bitacora_inmutable(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.fn_bitacora_inmutable() FROM PUBLIC;


--
-- Name: FUNCTION fn_detalle_dispensacion(p_folio uuid); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.fn_detalle_dispensacion(p_folio uuid) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_detalle_dispensacion(p_folio uuid) TO rol_dispensador;
GRANT ALL ON FUNCTION public.fn_detalle_dispensacion(p_folio uuid) TO rol_jefe_farmacia;


--
-- Name: FUNCTION fn_generar_alertas(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.fn_generar_alertas() FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_generar_alertas() TO rol_jefe_farmacia;


--
-- Name: FUNCTION fn_set_contexto(p_id_usuario integer, p_ip text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.fn_set_contexto(p_id_usuario integer, p_ip text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.fn_set_contexto(p_id_usuario integer, p_ip text) TO app_backend;
GRANT ALL ON FUNCTION public.fn_set_contexto(p_id_usuario integer, p_ip text) TO rol_dispensador;
GRANT ALL ON FUNCTION public.fn_set_contexto(p_id_usuario integer, p_ip text) TO rol_jefe_farmacia;
GRANT ALL ON FUNCTION public.fn_set_contexto(p_id_usuario integer, p_ip text) TO rol_administrador;


--
-- Name: FUNCTION fn_usuario_actual(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.fn_usuario_actual() FROM PUBLIC;


--
-- Name: FUNCTION fn_verificar_stock_insumo(p_id_insumo integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.fn_verificar_stock_insumo(p_id_insumo integer) FROM PUBLIC;


--
-- Name: FUNCTION sp_dispensar_peps(p_id_insumo integer, p_cantidad integer, p_id_ubicacion_origen integer, p_id_ubicacion_destino integer, p_id_medico integer, p_id_paciente integer, p_id_usuario integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.sp_dispensar_peps(p_id_insumo integer, p_cantidad integer, p_id_ubicacion_origen integer, p_id_ubicacion_destino integer, p_id_medico integer, p_id_paciente integer, p_id_usuario integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_dispensar_peps(p_id_insumo integer, p_cantidad integer, p_id_ubicacion_origen integer, p_id_ubicacion_destino integer, p_id_medico integer, p_id_paciente integer, p_id_usuario integer) TO rol_dispensador;
GRANT ALL ON FUNCTION public.sp_dispensar_peps(p_id_insumo integer, p_cantidad integer, p_id_ubicacion_origen integer, p_id_ubicacion_destino integer, p_id_medico integer, p_id_paciente integer, p_id_usuario integer) TO rol_jefe_farmacia;


--
-- Name: FUNCTION sp_registrar_entrada(p_id_lote integer, p_id_ubicacion integer, p_cantidad integer, p_id_usuario integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.sp_registrar_entrada(p_id_lote integer, p_id_ubicacion integer, p_cantidad integer, p_id_usuario integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_registrar_entrada(p_id_lote integer, p_id_ubicacion integer, p_cantidad integer, p_id_usuario integer) TO rol_jefe_farmacia;


--
-- Name: FUNCTION sp_trasladar_peps(p_id_insumo integer, p_cantidad integer, p_id_ubicacion_origen integer, p_id_ubicacion_destino integer, p_id_usuario integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.sp_trasladar_peps(p_id_insumo integer, p_cantidad integer, p_id_ubicacion_origen integer, p_id_ubicacion_destino integer, p_id_usuario integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.sp_trasladar_peps(p_id_insumo integer, p_cantidad integer, p_id_ubicacion_origen integer, p_id_ubicacion_destino integer, p_id_usuario integer) TO rol_jefe_farmacia;


--
-- Name: TABLE alerta; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.alerta TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.alerta TO rol_administrador;


--
-- Name: COLUMN alerta.atendida; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(atendida) ON TABLE public.alerta TO rol_jefe_farmacia;


--
-- Name: COLUMN alerta.fecha_atencion; Type: ACL; Schema: public; Owner: postgres
--

GRANT UPDATE(fecha_atencion) ON TABLE public.alerta TO rol_jefe_farmacia;


--
-- Name: TABLE almacen_ubicacion; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.almacen_ubicacion TO rol_dispensador;
GRANT SELECT,INSERT,UPDATE ON TABLE public.almacen_ubicacion TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.almacen_ubicacion TO rol_administrador;


--
-- Name: TABLE dispensacion; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.dispensacion TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.dispensacion TO rol_administrador;


--
-- Name: TABLE entrada_inventario; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.entrada_inventario TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.entrada_inventario TO rol_administrador;


--
-- Name: TABLE insumo; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.insumo TO rol_dispensador;
GRANT SELECT,INSERT,UPDATE ON TABLE public.insumo TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.insumo TO rol_administrador;


--
-- Name: TABLE lote; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.lote TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.lote TO rol_administrador;


--
-- Name: TABLE lote_ubicacion; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.lote_ubicacion TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.lote_ubicacion TO rol_administrador;


--
-- Name: TABLE medico; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE public.medico TO rol_dispensador;
GRANT SELECT,INSERT,UPDATE ON TABLE public.medico TO rol_jefe_farmacia;


--
-- Name: TABLE paciente; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE public.paciente TO rol_dispensador;
GRANT SELECT,INSERT,UPDATE ON TABLE public.paciente TO rol_jefe_farmacia;


--
-- Name: TABLE proveedor; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.proveedor TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.proveedor TO rol_administrador;


--
-- Name: TABLE rol; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.rol TO app_backend;
GRANT SELECT,INSERT,UPDATE ON TABLE public.rol TO rol_administrador;
GRANT SELECT ON TABLE public.rol TO rol_jefe_farmacia;


--
-- Name: TABLE usuario; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.usuario TO rol_administrador;


--
-- Name: COLUMN usuario.id_usuario; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(id_usuario) ON TABLE public.usuario TO app_backend;
GRANT SELECT(id_usuario) ON TABLE public.usuario TO rol_jefe_farmacia;


--
-- Name: COLUMN usuario.id_rol; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(id_rol) ON TABLE public.usuario TO app_backend;
GRANT SELECT(id_rol) ON TABLE public.usuario TO rol_jefe_farmacia;


--
-- Name: COLUMN usuario.nombre; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(nombre) ON TABLE public.usuario TO app_backend;
GRANT SELECT(nombre) ON TABLE public.usuario TO rol_jefe_farmacia;


--
-- Name: COLUMN usuario.correo; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(correo) ON TABLE public.usuario TO app_backend;
GRANT SELECT(correo) ON TABLE public.usuario TO rol_jefe_farmacia;


--
-- Name: COLUMN usuario.hash_password; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(hash_password) ON TABLE public.usuario TO app_backend;


--
-- Name: COLUMN usuario.activo; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(activo) ON TABLE public.usuario TO app_backend;
GRANT SELECT(activo) ON TABLE public.usuario TO rol_jefe_farmacia;


--
-- Name: TABLE v_alertas_pendientes; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.v_alertas_pendientes TO rol_dispensador;
GRANT SELECT ON TABLE public.v_alertas_pendientes TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.v_alertas_pendientes TO rol_administrador;


--
-- Name: TABLE v_bitacora; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.v_bitacora TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.v_bitacora TO rol_administrador;


--
-- Name: TABLE v_stock_insumo; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.v_stock_insumo TO rol_dispensador;
GRANT SELECT ON TABLE public.v_stock_insumo TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.v_stock_insumo TO rol_administrador;


--
-- Name: TABLE v_insumos_reorden; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.v_insumos_reorden TO rol_dispensador;
GRANT SELECT ON TABLE public.v_insumos_reorden TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.v_insumos_reorden TO rol_administrador;


--
-- Name: TABLE v_stock_lote; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.v_stock_lote TO rol_dispensador;
GRANT SELECT ON TABLE public.v_stock_lote TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.v_stock_lote TO rol_administrador;


--
-- Name: TABLE v_lotes_por_caducar; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.v_lotes_por_caducar TO rol_dispensador;
GRANT SELECT ON TABLE public.v_lotes_por_caducar TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.v_lotes_por_caducar TO rol_administrador;


--
-- Name: TABLE v_kpi_monitor; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.v_kpi_monitor TO rol_dispensador;
GRANT SELECT ON TABLE public.v_kpi_monitor TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.v_kpi_monitor TO rol_administrador;


--
-- Name: TABLE v_trazabilidad_lote; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.v_trazabilidad_lote TO rol_dispensador;
GRANT SELECT ON TABLE public.v_trazabilidad_lote TO rol_jefe_farmacia;
GRANT SELECT ON TABLE public.v_trazabilidad_lote TO rol_administrador;


--
-- PostgreSQL database dump complete
--

\unrestrict joWC0b4gw6OA78mirunNzb7f0HOz4dotDmMhOuSgDotZqT6uIr1DeSc6obBOta3

