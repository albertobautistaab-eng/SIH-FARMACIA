-- =====================================================================
-- SIH-FARMACIA :: Instalación completa
-- Uso (desde esta carpeta):
--   createdb sih_farmacia
--   psql -d sih_farmacia -v ON_ERROR_STOP=1 -f 00_install.sql
-- Requiere PostgreSQL 14+ y permisos de superusuario (extensión pgcrypto
-- y creación de roles).
-- =====================================================================
\ir 01_schema.sql
\ir 02_indexes.sql
\ir 03_functions.sql
\ir 04_triggers.sql
\ir 05_views.sql
\ir 06_roles.sql
\ir 07_seed.sql
