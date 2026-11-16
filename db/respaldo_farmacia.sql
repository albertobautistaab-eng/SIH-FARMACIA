--
-- PostgreSQL database dump
--

\restrict rnhvNwdBnv1DpALREshmNgbysSoqfZojigRVa3bnmRKF4OulJwLn9GH6oqy2hO0

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
\.


--
-- Data for Name: almacen_ubicacion; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.almacen_ubicacion (id_ubicacion, nombre_area, anaquel_seccion) FROM stdin;
1	Almacén Central	Anaquel B-12
2	Quirófano A3	\N
3	Bóveda Urgencias	\N
4	Refrigerador 2	\N
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
45	\N	UPDATE	usuario	usuario {"activo": true, "correo": "jefe.farmacia@hospital.mx", "id_rol": 1, "nombre": "Laura Hernández", "id_usuario": 1}	{"activo": true, "correo": "jefe.farmacia@hospital.mx", "id_rol": 1, "nombre": "Laura Hernández", "id_usuario": 1}	{"activo": true, "correo": "jefe.farmacia@hospital.mx", "id_rol": 1, "nombre": "Laura Hernández", "id_usuario": 1}	2026-11-14 16:17:17.394515-06	consola
46	\N	UPDATE	usuario	usuario {"activo": true, "correo": "dispensador@hospital.mx", "id_rol": 2, "nombre": "Carlos Ruiz", "id_usuario": 2}	{"activo": true, "correo": "dispensador@hospital.mx", "id_rol": 2, "nombre": "Carlos Ruiz", "id_usuario": 2}	{"activo": true, "correo": "dispensador@hospital.mx", "id_rol": 2, "nombre": "Carlos Ruiz", "id_usuario": 2}	2026-11-14 16:17:52.401178-06	consola
47	\N	UPDATE	usuario	usuario {"activo": true, "correo": "admin@hospital.mx", "id_rol": 3, "nombre": "Ana Torres", "id_usuario": 3}	{"activo": true, "correo": "admin@hospital.mx", "id_rol": 3, "nombre": "Ana Torres", "id_usuario": 3}	{"activo": true, "correo": "admin@hospital.mx", "id_rol": 3, "nombre": "Ana Torres", "id_usuario": 3}	2026-11-14 16:18:09.20372-06	consola
\.


--
-- Data for Name: dispensacion; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.dispensacion (id_dispensacion, folio_operacion, id_lote, id_ubicacion_origen, id_ubicacion_destino, id_medico, id_paciente, id_usuario, cantidad_dispensada, fecha_hora_dispensacion) FROM stdin;
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
\.


--
-- Data for Name: insumo; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.insumo (id_insumo, codigo_insumo, descripcion_farmaco, es_controlado, stock_minimo_seguridad, unidad_medida, activo) FROM stdin;
1	INS-8840	Propofol 200mg / 20ml	f	30	Ampolleta	t
2	INS-1029	Fentanilo 0.5mg (Controlado)	t	15	Ampolleta	t
3	INS-3321	Insulina Humana R 100UI/ml	f	20	Frasco	t
4	INS-5010	Paracetamol 500mg	f	100	Caja	t
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
\.


--
-- Data for Name: lote_ubicacion; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.lote_ubicacion (id_lote, id_ubicacion, cantidad) FROM stdin;
2	1	4
1	1	10
3	3	4
4	4	12
5	1	500
\.


--
-- Data for Name: medico; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.medico (id_medico, cedula_profesional, nombre, especialidad) FROM stdin;
1	8839201	Dr. C. Mendoza	Anestesiología
\.


--
-- Data for Name: paciente; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.paciente (id_paciente, expediente_folio, nombre, area_ingreso) FROM stdin;
1	EXP-000123	J. Martínez P.	Urgencias
\.


--
-- Data for Name: proveedor; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.proveedor (id_proveedor, rfc, razon_social, contacto_telefono, contacto_email) FROM stdin;
1	PCO010101AB1	Pharma Corp	33 1234 5678	ventas@pharmacorp.example
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
\.


--
-- Name: alerta_id_alerta_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.alerta_id_alerta_seq', 21, true);


--
-- Name: almacen_ubicacion_id_ubicacion_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.almacen_ubicacion_id_ubicacion_seq', 4, true);


--
-- Name: bitacora_auditoria_id_auditoria_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.bitacora_auditoria_id_auditoria_seq', 47, true);


--
-- Name: dispensacion_id_dispensacion_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.dispensacion_id_dispensacion_seq', 6, true);


--
-- Name: entrada_inventario_id_entrada_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.entrada_inventario_id_entrada_seq', 5, true);


--
-- Name: insumo_id_insumo_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.insumo_id_insumo_seq', 4, true);


--
-- Name: lote_id_lote_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.lote_id_lote_seq', 5, true);


--
-- Name: medico_id_medico_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.medico_id_medico_seq', 1, true);


--
-- Name: paciente_id_paciente_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.paciente_id_paciente_seq', 1, true);


--
-- Name: proveedor_id_proveedor_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.proveedor_id_proveedor_seq', 1, true);


--
-- Name: rol_id_rol_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.rol_id_rol_seq', 3, true);


--
-- Name: usuario_id_usuario_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.usuario_id_usuario_seq', 3, true);


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

GRANT SELECT ON TABLE public.medico TO rol_dispensador;
GRANT SELECT,INSERT,UPDATE ON TABLE public.medico TO rol_jefe_farmacia;


--
-- Name: TABLE paciente; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.paciente TO rol_dispensador;
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


--
-- Name: TABLE usuario; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,UPDATE ON TABLE public.usuario TO rol_administrador;


--
-- Name: COLUMN usuario.id_usuario; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(id_usuario) ON TABLE public.usuario TO app_backend;


--
-- Name: COLUMN usuario.id_rol; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(id_rol) ON TABLE public.usuario TO app_backend;


--
-- Name: COLUMN usuario.nombre; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(nombre) ON TABLE public.usuario TO app_backend;


--
-- Name: COLUMN usuario.correo; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(correo) ON TABLE public.usuario TO app_backend;


--
-- Name: COLUMN usuario.hash_password; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(hash_password) ON TABLE public.usuario TO app_backend;


--
-- Name: COLUMN usuario.activo; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT(activo) ON TABLE public.usuario TO app_backend;


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

\unrestrict rnhvNwdBnv1DpALREshmNgbysSoqfZojigRVa3bnmRKF4OulJwLn9GH6oqy2hO0

