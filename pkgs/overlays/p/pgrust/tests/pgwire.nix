# The server leg: pgrust listens on a TCP port and gives each pgwire connection
# its own backend thread inside one WASIX instance. A native psql drives it over
# the loopback bridge, so the concurrency check reads the backend ids the guest
# actually assigned.
{
  entry,
  harnesses,
  pkgs,
  ...
}: let
  native = pkgs.postgresql_18;
  psql = pkgs.lib.getExe' native "psql";
  port = 55440;
  clients = 8;
in {
  pgwire = harnesses.hostShell {
    name = "pgrust-pgwire";
    wasixCommands = builtins.attrValues entry.commands;
    hostPackages = [native pkgs.coreutils];
    wasmerArgs = ["--net"];
    timeout = 1800;
    script = ''
      ${pkgs.lib.getExe' native "initdb"} -D db -U postgres --no-locale --encoding=UTF8 >/dev/null

      # max_stack_depth sizes each backend's stack reservation, and the shipped
      # default reserves more than the 4 GiB address space serves out.
      postgres -D "$PWD/db" \
        -c listen_addresses=127.0.0.1 -c port=${toString port} -c unix_socket_directories= \
        -c log_min_messages=log -c max_stack_depth=2048 -c io_method=sync \
        -c autovacuum=off -c wal_sync_method=fdatasync >postgres.log 2>&1 &
      pid=$!
      trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT INT TERM

      up=""
      for _ in $(seq 1 120); do
        grep -qa "ready to accept connections" postgres.log && { up=1; break; }
        kill -0 "$pid" 2>/dev/null || { echo "FAIL: server exited during startup"; tail -40 postgres.log; exit 1; }
        sleep 1
      done
      [ -n "$up" ] || { echo "FAIL: no listener after 120s"; tail -40 postgres.log; exit 1; }

      test "$(${psql} -h 127.0.0.1 -p ${toString port} -U postgres -d postgres -Atc 'select 40 + 2')" = 42

      # An error must not cost the session: psql reads these as two simple queries
      # on one connection, so the 42 below is the backend recovering in place. The
      # --single leg cannot show this, and ON_ERROR_STOP stays unset so psql walks
      # past the failed statement instead of exiting.
      test "$(${psql} -h 127.0.0.1 -p ${toString port} -U postgres -d postgres -Atq <<'SQL'
      SELECT no_such_column FROM pg_class;
      SELECT 40 + 2;
      SQL
      )" = 42

      # One distinct backend id per connection is the threaded-backend claim; a
      # constant query would make the count vacuous.
      #
      # The clients are waited on by pid, never with a bare `wait`: the postmaster
      # job is still running at this point, and a bare `wait` blocks on it too, so
      # a healthy server would turn this leg into a harness timeout. Only an
      # unhealthy one returns early, which is how this stayed hidden.
      : >pids.txt
      clients_pids=""
      for _ in $(seq 1 ${toString clients}); do
        ${psql} -h 127.0.0.1 -p ${toString port} -U postgres -d postgres \
          -Atc 'select pg_backend_pid()' >>pids.txt &
        clients_pids="$clients_pids $!"
      done
      wait $clients_pids
      # Count numeric ids, not lines: a client that printed its error to stdout
      # would otherwise add to the distinct count instead of subtracting.
      test "$(sort -n -u pids.txt | grep -c '^[0-9]')" -eq ${toString clients}
    '';
  };
}
