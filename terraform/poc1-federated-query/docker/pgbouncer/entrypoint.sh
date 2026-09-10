#!/bin/sh
# Renders pgbouncer.ini + userlist.txt from the environment variables the ECS
# task definition (pgbouncer.tf) injects, then runs pgbouncer in the
# foreground. Both read-only logins (mv_refresh, adhoc) share this one
# PgBouncer instance/pool against the same target database, authenticated by
# password hashes computed here — the plaintext passwords never touch disk.
set -eu

: "${DB_HOST:?DB_HOST is required}"
: "${DB_PORT:=5432}"
: "${DB_NAME:?DB_NAME is required}"
: "${POOL_MODE:=transaction}"
: "${DEFAULT_POOL_SIZE:=20}"
: "${MV_REFRESH_DB_USERNAME:?MV_REFRESH_DB_USERNAME is required}"
: "${MV_REFRESH_DB_PASSWORD:?MV_REFRESH_DB_PASSWORD is required}"
: "${ADHOC_DB_USERNAME:?ADHOC_DB_USERNAME is required}"
: "${ADHOC_DB_PASSWORD:?ADHOC_DB_PASSWORD is required}"

CONFIG_DIR=/etc/pgbouncer
mkdir -p "$CONFIG_DIR"

md5_auth_entry() {
  # PgBouncer/Postgres md5 auth format: "md5" + md5(password || username)
  user="$1"
  pass="$2"
  hash=$(printf '%s' "${pass}${user}" | md5sum | awk '{print $1}')
  printf '"%s" "md5%s"\n' "$user" "$hash"
}

{
  md5_auth_entry "$MV_REFRESH_DB_USERNAME" "$MV_REFRESH_DB_PASSWORD"
  md5_auth_entry "$ADHOC_DB_USERNAME" "$ADHOC_DB_PASSWORD"
} > "$CONFIG_DIR/userlist.txt"
chmod 600 "$CONFIG_DIR/userlist.txt"

cat > "$CONFIG_DIR/pgbouncer.ini" <<EOF
[databases]
${DB_NAME} = host=${DB_HOST} port=${DB_PORT} dbname=${DB_NAME}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = md5
auth_file = ${CONFIG_DIR}/userlist.txt
pool_mode = ${POOL_MODE}
default_pool_size = ${DEFAULT_POOL_SIZE}
max_client_conn = 200
EOF

exec pgbouncer "$CONFIG_DIR/pgbouncer.ini"
