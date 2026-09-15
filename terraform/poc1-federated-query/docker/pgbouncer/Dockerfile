FROM debian:bookworm-slim

# PgBouncer refuses to run as root ("FATAL PgBouncer should not run as
# root") - create/ensure a dedicated non-root user and own its config dir
# outright, rather than relying on whatever the Debian package's postinst
# happens to set up.
RUN apt-get update \
    && apt-get install -y --no-install-recommends pgbouncer openssl \
    && rm -rf /var/lib/apt/lists/* \
    && id -u pgbouncer >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin pgbouncer \
    && mkdir -p /etc/pgbouncer \
    && chown -R pgbouncer:pgbouncer /etc/pgbouncer

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER pgbouncer

EXPOSE 6432

ENTRYPOINT ["/entrypoint.sh"]
