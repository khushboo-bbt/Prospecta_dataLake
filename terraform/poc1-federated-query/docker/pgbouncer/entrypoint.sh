#!/bin/sh
# Renders pgbouncer.ini + userlist.txt from the environment variables the ECS
# task definition (pgbouncer.tf) injects, then runs pgbouncer in the
# foreground. Both read-only logins (mv_refresh, adhoc) share this one
# PgBouncer instance/pool against the same target database.
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

# Two separate TLS legs, both required, discovered as two separate failures:
# 1. Client-facing (Redshift -> PgBouncer): Redshift Federated Query always
#    requires SSL/TLS to the external Postgres data source ("ERROR: server
#    does not support SSL, but SSL was required") - not optional/configurable
#    on Redshift's side, so PgBouncer has to terminate TLS on its listening
#    side regardless. Self-signed and regenerated fresh on every container
#    start is fine: this only needs to satisfy "connection is encrypted",
#    nothing authenticates against this cert's identity (auth is via
#    userlist.txt/password, same as before) - a private key baked into the
#    image or persisted anywhere would be worse for secrets hygiene for no
#    real benefit.
# 2. Backend (PgBouncer -> the actual replica): the replica's pg_hba.conf
#    requires an encrypted connection too ("FATAL: no pg_hba.conf entry for
#    host ..., no encryption") - server_tls_sslmode below, separate from the
#    client_tls_* settings which only govern the first leg.
TLS_CERT="${CONFIG_DIR}/server.crt"
TLS_KEY="${CONFIG_DIR}/server.key"
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout "$TLS_KEY" -out "$TLS_CERT" \
  -days 365 -subj "/CN=pgbouncer"
chmod 600 "$TLS_KEY"
# client_tls_ca_file is also required even with sslmode=require and no
# client-cert verification - PgBouncer's TLS init otherwise fails with
# "TLS setup failed: failed to load CA: (null)" (confirmed via the actual
# CloudWatch logs on the first attempt without this line). The self-signed
# cert itself is a valid enough reference to satisfy the loader.

# Plaintext in userlist.txt, not a precomputed md5 hash: the replica (a
# fresh Postgres 16 instance) defaults to scram-sha-256 password storage,
# not md5 - a precomputed md5 hash here caused "FATAL: server login failed:
# wrong password type" once TLS on both legs was working (confirmed via
# testing). auth_type=plain below lets PgBouncer negotiate whichever method
# each side actually demands (client-facing to Redshift, backend to the
# replica) using this same plaintext value, rather than committing to one
# hash algorithm that may not match both. The file itself is still
# chmod 600, inside this container only, same as the env vars it's built
# from - no less secure than before.
{
  printf '"%s" "%s"\n' "$MV_REFRESH_DB_USERNAME" "$MV_REFRESH_DB_PASSWORD"
  printf '"%s" "%s"\n' "$ADHOC_DB_USERNAME" "$ADHOC_DB_PASSWORD"
} > "$CONFIG_DIR/userlist.txt"
chmod 600 "$CONFIG_DIR/userlist.txt"

cat > "$CONFIG_DIR/pgbouncer.ini" <<EOF
[databases]
${DB_NAME} = host=${DB_HOST} port=${DB_PORT} dbname=${DB_NAME}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = plain
auth_file = ${CONFIG_DIR}/userlist.txt
pool_mode = ${POOL_MODE}
default_pool_size = ${DEFAULT_POOL_SIZE}
max_client_conn = 200
client_tls_sslmode = require
client_tls_key_file = ${TLS_KEY}
client_tls_cert_file = ${TLS_CERT}
client_tls_ca_file = ${TLS_CERT}
server_tls_sslmode = require
EOF

exec pgbouncer "$CONFIG_DIR/pgbouncer.ini"
