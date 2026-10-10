#!/bin/bash
#
# First-run datadir initialization wrapper for the official MariaDB
# entrypoint: the stock entrypoint would let its temporary server join a
# running cluster (wsrep is enabled from the baked-in config) and crash
# during SST. Initialize once with wsrep switched off, then hand over:
# the real server startup then joins the cluster through a clean SST.
#
set -e

admin_bin=$(command -v mariadb-admin || command -v mysqladmin)
admin_ping=("$admin_bin" --user=root --password="$MARIADB_ROOT_PASSWORD")

# mariadb_upgrade_info is not replicated by mariabackup SST, so the
# presence of the mysql system directory is the "already usable datadir"
# marker (delete the volumes after a crash mid-initialization).
if [ ! -d /var/lib/mysql/mysql ]; then
  echo "[clusterchk-demo] First run: initializing datadir without wsrep"
  docker-entrypoint.sh mariadbd --wsrep-on=OFF >/tmp/galera-init.log 2>&1 &
  init_pid=$!
  until grep -q "init process done" /tmp/galera-init.log 2>/dev/null \
        && "${admin_ping[@]}" --connect-timeout=2 ping >/dev/null 2>&1; do
    if ! kill -0 "$init_pid" 2>/dev/null; then
      echo "[clusterchk-demo] Initialization failed:" >&2
      cat /tmp/galera-init.log >&2
      exit 1
    fi
    sleep 2
  done
  "${admin_ping[@]}" shutdown >/dev/null 2>&1 || true
  wait "$init_pid" 2>/dev/null || true
  echo "[clusterchk-demo] Datadir initialized, proceeding with wsrep enabled"
fi

exec docker-entrypoint.sh "$@"
