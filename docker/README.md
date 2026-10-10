# Clusterchk Demo

A Docker Compose playground that reproduces the production scenario: a three-node
MariaDB Galera cluster behind HAProxy, with one *clusterchk* health-check endpoint
per node answering on port 9999, exactly like the SystemD socket-activated units do.

## Layout

* `galera1..3` - MariaDB 11.4 with the Galera provider and mariabackup SST
* `clusterchk1..3` - sidecars sharing the network namespace of their node, running
  `scripts/clusterchk.sh` through socat (one process per connection, like
  `clusterchk.socket` + `clusterchk@.service` do on a real host)
* `haproxy` - TCP load balancer on `127.0.0.1:3306`, with `option httpchk` so the
  HTTP status produced by clusterchk (200 or 503) drives the server state

## Quick start

1. `docker compose up -d` and wait until every node reports healthy
   (first boot initializes three datadirs and performs two SSTs; allow ~4 minutes)
2. Write through the entry point:

   ```sh
   docker run --rm --network host --entrypoint bash mariadb:11.4 -c \
     'mariadb -h 127.0.0.1 -P3306 -uroot -prootpw -e "CREATE DATABASE IF NOT EXISTS demo; CREATE TABLE demo.t(x int primary key auto_increment, note varchar(50)); INSERT INTO demo.t(note) VALUES (""hello galera"");"'
   ```

3. Verify replication on every node:

   ```sh
   for n in galera1 galera2 galera3; do
     docker compose exec -T $n mariadb -uroot -prootpw -N demo -e "SELECT * FROM t"
   done
   ```

4. Observe the health checks:

   ```sh
   for n in galera1 galera2 galera3; do
     docker compose exec -T $n bash -c \
       'printf "GET / HTTP/1.0\r\n\r\n" | timeout 3 socat - TCP:127.0.0.1:9999 | head -1'
   done
   ```

5. Simulate a failure and watch HAProxy drain the node (`fall 2` times
   `inter 3s`) while writes keep working:

   ```sh
   docker compose stop galera2
   docker compose logs -f haproxy        # galera2 goes DOWN, writes still succeed
   docker compose start galera2          # node rejoins via IST/SST, comes back UP
   ```

6. Tear everything down, volumes included: `docker compose down -v`

## Operational notes

* **Bootstrap sequence**: the whole stack recreates itself correctly on
  `docker compose up` thanks to health-gated startup order. A cold restart of a
  stopped-but-existing deployment must start `galera1` first (it owns the empty
  `gcomm://` bootstrap address), then the other services.
* **First-run initialization**: joining nodes cannot let the stock image entrypoint
  initialize the datadir while wsrep is enabled (its temporary server would try to
  join the live cluster and crash during SST). `entrypoint-node.sh` initializes the
  datadir once with wsrep switched off; the real startup then performs a clean SST.
* **Healthcheck credentials**: the image-provided `healthcheck.sh` stores its
  option file inside the datadir, which a full SST wipes, so the compose file uses
  a root/TCP probe on `127.0.0.1` instead.
* **HAProxy and DNS**: HAProxy resolves server names at load time; after recreating
  node containers, `docker compose restart haproxy` to refresh the addresses.
* **Donor behaviour**: after a *short* outage a node rejoins through IST and the
  donor stays `Synced`; the `Donor/Desynced`-with-mariabackup branch (HTTP 200)
  kicks in on full mariabackup SSTs, e.g. after purging the joiner's datadir.
