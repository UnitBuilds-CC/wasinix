# The --single leg: one session boots an externally initialized cluster, runs DDL
# and DML, raises an error, and still reaches a clean shutdown checkpoint. A
# statement queued behind that error in the same input never runs, because the
# single-user read loop takes all of stdin as one query; an answer after an error
# is therefore asserted in ./pgwire.nix, where each query is its own message.
{
  commands,
  entry,
  harnesses,
  pkgs,
  ...
}: let
  postgres = builtins.attrValues entry.commands;
  # pgrust ships no initdb, so the cluster comes from a C PostgreSQL 18.
  native = pkgs.postgresql_18;
in {
  single-user = harnesses.wasixShell {
    name = "pgrust-single-user";
    shell = commands.bash;
    commands = postgres ++ [commands.coreutils commands.grep];
    timeout = 1800;
    host = {
      packages = [native];
      setup = ''
        ${pkgs.lib.getExe' native "initdb"} -D db -U postgres --no-locale --encoding=UTF8 >/dev/null
      '';
    };
    script = ''
      # The boot GUC below reserves a 64 MiB stack, and RUST_MIN_STACK is what std
      # sizes a spawned thread's stack with.
      export RUST_MIN_STACK=67108864

      postgres --single -j -D "$PWD/db" \
        -c max_stack_depth=60000 -c io_method=sync -c autovacuum=off \
        -c wal_sync_method=fdatasync postgres >out.txt 2>&1 <<'SQL'
      CREATE TABLE wb_tenk (unique1 int4 NOT NULL, unique2 int4, stringu1 name, even int4);
      INSERT INTO wb_tenk SELECT i, 9 - i, 'row' || i, (i % 2) * 2 FROM generate_series(0, 9) AS g(i);
      CREATE UNIQUE INDEX wb_tenk_unique1 ON wb_tenk (unique1);
      SELECT count(*) AS cnt FROM wb_tenk;
      SELECT no_such_column FROM wb_tenk;
      SQL

      cat out.txt
      # The guest runs this script with plain bash, so errexit is not in play and
      # only the last command's status would reach the harness: each expectation
      # carries its own verdict here, and a missed one names itself.
      fail=0
      for want in 'PostgreSQL stand-alone backend 18.6' 'cnt = "10"' \
        'ERROR:  column "no_such_column" does not exist' 'checkpoint complete'; do
        grep -F "$want" out.txt || { echo "MISSING: $want"; fail=1; }
      done
      exit $fail
    '';
  };
}
