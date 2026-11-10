{ pkgs }:

pkgs.runCommand "hadal-snapshot-safety-checks"
  {
    nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.psycopg ])) ];
  }
  ''
    cp ${./snapshot-agent.py} snapshot-agent.py
    cp ${./snapshot-pair.py} snapshot-pair.py
    cp ${./test-snapshots.py} test-snapshots.py
    python3 -B test-snapshots.py
    touch "$out"
  ''
