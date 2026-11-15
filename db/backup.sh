#!/usr/bin/env bash
# =====================================================================
# backup.sh :: Estrategia de respaldos (completo semanal + diario)
#
# NOTA: pg_dump NO hace respaldos diferenciales. Opciones:
#   (A) PostgreSQL 17+: respaldo físico incremental con pg_basebackup
#       (requiere  summarize_wal = on  en postgresql.conf). Es lo que
#       implementa este script.
#   (B) PostgreSQL < 17: archivado de WAL (archive_mode/archive_command)
#       + pg_basebackup semanal; el WAL archivado cumple la función del
#       diferencial diario y permite restaurar a un instante (PITR).
#
# Uso:   backup.sh completo | incremental
# Cron (ejemplo):
#   0 2 * * 0     /opt/sih/backup.sh completo       # domingo 02:00
#   0 2 * * 1-6   /opt/sih/backup.sh incremental    # lunes-sábado 02:00
#
# Credenciales: usar ~/.pgpass o PGPASSFILE (rol con atributo REPLICATION).
# Ajustar rutas y host. SCRIPT NO PROBADO en tu entorno: validar la
# restauración periódicamente (pg_combinebackup + arranque de prueba).
# =====================================================================
set -euo pipefail

BASE_DIR="${BASE_DIR:-/var/backups/sih_farmacia}"
MIRROR="${MIRROR:-respaldo@servidor-espejo:/var/backups/sih_farmacia/}"   # servidor espejo
PGHOST="${PGHOST:-localhost}"
PGUSER="${PGUSER:-backup_user}"
DB="${DB:-sih_farmacia}"
STAMP="$(date +%Y%m%d_%H%M%S)"

mkdir -p "$BASE_DIR"

case "${1:-}" in
  completo)
    # Copia física completa (base de los incrementales) ...
    DEST="$BASE_DIR/full_$STAMP"
    pg_basebackup -h "$PGHOST" -U "$PGUSER" -D "$DEST" -Fp -X stream -c fast
    ln -sfn "$DEST" "$BASE_DIR/ultimo"
    # ... y volcado lógico (útil para migrar o restaurar tablas sueltas)
    pg_dump -h "$PGHOST" -U "$PGUSER" -Fc -f "$BASE_DIR/dump_$STAMP.dump" "$DB"
    ;;
  incremental)
    PREV="$(readlink -f "$BASE_DIR/ultimo")"
    DEST="$BASE_DIR/incr_$STAMP"
    pg_basebackup -h "$PGHOST" -U "$PGUSER" -D "$DEST" -Fp -X stream \
                  --incremental="$PREV/backup_manifest"
    ln -sfn "$DEST" "$BASE_DIR/ultimo"
    ;;
  *)
    echo "Uso: $0 completo|incremental" >&2; exit 1 ;;
esac

# Copia al servidor espejo
rsync -a --delete-after "$BASE_DIR/" "$MIRROR"

# Retención: conservar 5 semanas
find "$BASE_DIR" -maxdepth 1 \( -name 'full_*' -o -name 'incr_*' -o -name 'dump_*' \) -mtime +35 -exec rm -rf {} +
