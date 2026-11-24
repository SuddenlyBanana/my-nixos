#!/usr/bin/env python3
"""Offline guards; RUN_MIGRATION_INTEGRATION=1 adds isolated, synthetic DB tests.

Never connects to Hadal, OpenBao or a production database. The optional test
needs PostgreSQL 17, pgloader 3.6.9 and the built Vaultwarden PostgreSQL binary.
"""

import contextlib
from decimal import Decimal
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("migration", HERE / "migrate-vaultwarden.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def fixture(path, definitions=None, records=None):
    definitions = definitions or {"items": '"name" TEXT, "enabled" BOOLEAN'}
    with contextlib.closing(sqlite3.connect(path)) as db, db:
        db.execute('CREATE TABLE __diesel_schema_migrations(version TEXT PRIMARY KEY)')
        db.executemany('INSERT INTO __diesel_schema_migrations VALUES (?)',
                       [(v,) for v in m.REFERENCE["sqlite"]])
        for table, columns in definitions.items():
            db.execute(f'CREATE TABLE {m.identifier(table)} ({columns})')
        for table, rows in (records or {}).items():
            for row in rows:
                db.execute(f'INSERT INTO {m.identifier(table)} VALUES ({",".join("?" for _ in row)})', row)
    path.chmod(0o600)
    return path


class Guards(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vw-unit-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.path = fixture(self.directory / "source.sqlite3")

    def test_reference_counts(self):
        self.assertEqual((len(m.REFERENCE["sqlite"]), len(m.REFERENCE["postgresql"])), (56, 46))
        for backend in ("sqlite", "postgresql"):
            self.assertEqual(m.REFERENCE[backend], sorted(set(m.REFERENCE[backend])))

    def test_source_readonly_and_unchanged(self):
        before = m.digest(self.path)
        source = m.Source(self.path)
        self.assertEqual(source.counts, {"items": 0})
        self.assertEqual(source.columns, {"items": ["name", "enabled"]})
        self.assertEqual(before, m.digest(self.path))
        with source.connect() as db, self.assertRaises(sqlite3.OperationalError):
            db.execute('INSERT INTO items VALUES ("no",1)')
        with contextlib.closing(sqlite3.connect(self.path)) as db, db:
            db.execute('INSERT INTO items VALUES ("changed",1)')
        with self.assertRaises(m.Failure):
            source.unchanged()

    def test_reject_sidecars(self):
        for suffix in ("-wal", "-journal"):
            path = Path(str(self.path) + suffix)
            path.touch()
            with self.assertRaises(m.Failure):
                m.Source(self.path)
            path.unlink()

    def test_reject_wal_header(self):
        with contextlib.closing(sqlite3.connect(self.path)) as db, db:
            db.execute("PRAGMA journal_mode=WAL")
        with self.assertRaises(m.Failure):
            m.Source(self.path)

    def test_reject_wrong_migrations(self):
        with contextlib.closing(sqlite3.connect(self.path)) as db, db:
            db.execute('DELETE FROM __diesel_schema_migrations WHERE version=?', (m.REFERENCE["sqlite"][0],))
        with self.assertRaises(m.Failure):
            m.Source(self.path)

    def test_private_modes_and_symlink(self):
        self.path.chmod(0o644)
        with self.assertRaises(m.Failure):
            m.Source(self.path)
        self.path.chmod(0o600)
        link = self.directory / "symlink"
        link.symlink_to(self.path)
        with self.assertRaises(m.Failure):
            m.Source(link)
        self.directory.chmod(0o755)
        with self.assertRaises(m.Failure):
            m.Source(self.path)
        self.directory.chmod(0o700)

    def test_exclusive_private_writes(self):
        path = self.directory / "receipt"
        m.write_private(path, "first")
        with self.assertRaises(FileExistsError):
            m.write_private(path, "second")
        self.assertEqual(path.read_text(), "first")
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_identifier_and_literals(self):
        for value in ('x";DROP TABLE users;--', "Users", "public.users", "x y"):
            with self.assertRaises(m.Failure):
                m.identifier(value)
        self.assertEqual(m.literal("a'b"), "'a''b'")
        self.assertEqual(m.conn_quote("a'b\\c"), "'a\\'b\\\\c'")

    def test_normalization(self):
        self.assertEqual(m.normalize("2026-01-02 03:04:05.12", "timestamp without time zone"),
                         m.normalize("2026-01-02T03:04:05.120000", "timestamp without time zone"))
        self.assertEqual(m.normalize("2026-01-02T04:04:05+01:00", "timestamp with time zone"),
                         "2026-01-02T03:04:05.000000+00:00")
        self.assertEqual(m.normalize(b"\0\xff", "bytea"), m.normalize("\\x00ff", "bytea"))
        self.assertEqual(m.normalize(1, "boolean"), True)
        self.assertEqual(m.normalize("01", "integer"), "1")
        self.assertEqual(m.normalize(Decimal("123.4500"), "numeric"), "123.45")
        self.assertIsNone(m.normalize(None, "unknown"))
        self.assertEqual(m.normalize("\n'\\ż", "text"), "\n'\\ż")
        for kind, value in (("boolean", 3), ("integer", "private-value"), ("numeric", "NaN"),
                            ("text", 5), ("jsonb", {}), ("timestamp without time zone", "bad-secret")):
            with self.assertRaises(m.Failure) as caught:
                m.normalize(value, kind)
            self.assertNotIn("private-value", str(caught.exception))
            self.assertNotIn("bad-secret", str(caught.exception))

    def test_clean_environment(self):
        with patch.dict(os.environ, {"BAO_TOKEN": "secret", "PGPASSWORD": "secret", "DATABASE_URL": "secret"}):
            env = m.clean_env(self.directory)
        self.assertEqual(set(env), {"PATH", "HOME", "LC_ALL", "LANG", "TZ"})

    def test_nanosecond_timestamp_rounding(self):
        kind = 'timestamp without time zone'
        for fraction, expected in (
            ('000000499', '2026-01-02T03:04:05.000000'),
            ('000000500', '2026-01-02T03:04:05.000000'),
            ('000001500', '2026-01-02T03:04:05.000002'),
            ('123456499', '2026-01-02T03:04:05.123456'),
            ('123456500', '2026-01-02T03:04:05.123456'),
            ('123456501', '2026-01-02T03:04:05.123457'),
            ('123456789', '2026-01-02T03:04:05.123457'),
            ('999999499', '2026-01-02T03:04:05.999999'),
            ('999999500', '2026-01-02T03:04:06.000000'),
            ('999999999', '2026-01-02T03:04:06.000000'),
        ):
            with self.subTest(fraction=fraction):
                self.assertEqual(m.normalize('2026-01-02 03:04:05.' + fraction, kind), expected)
        self.assertEqual(m.normalize('2026-12-31 23:59:59.999999999', kind),
                         '2027-01-01T00:00:00.000000')
        self.assertEqual(m.normalize('2026-01-02T00:59:59.999999999+01:00', 'timestamp with time zone'),
                         '2026-01-02T00:00:00.000000+00:00')
        self.assertNotEqual(m.normalize('2026-01-02 03:04:05.123456789', kind),
                            m.normalize('2026-01-02 03:04:05.123456', kind))

    def test_comparison_still_rejects_wrong_microsecond(self):
        source_path = fixture(self.directory / 'timestamps.sqlite3', {'items': '"time" DATETIME'},
                              {'items': [('2026-12-31 23:59:59.999999999',)]})
        source = m.Source(source_path)
        columns = [{'name': 'time', 'type': 'timestamp without time zone'}]
        rows = [{'time': '2027-01-01T00:00:00'}]
        pg = SimpleNamespace(tables=lambda: ['items'], columns=lambda _: columns,
                             json=lambda _: rows, snapshot=lambda *_: {'count': 1, 'sha256': 'a' * 64})
        m.compare_values(source, pg)
        rows[0]['time'] = '2026-12-31T23:59:59.999999'
        with self.assertRaises(m.Failure):
            m.compare_values(source, pg)

    def test_row_comparison_counts_duplicates(self):
        with contextlib.closing(sqlite3.connect(self.path)) as db, db:
            db.executemany('INSERT INTO items VALUES (?,?)', [("ż\n'", 1), ("ż\n'", 1), (None, 0)])
        source = m.Source(self.path)
        columns = [{"name": "name", "type": "text"}, {"name": "enabled", "type": "boolean"}]
        rows = [{"name": "ż\n'", "enabled": True}] * 2 + [{"name": None, "enabled": False}]
        pg = SimpleNamespace(tables=lambda: ["items"], columns=lambda _: columns,
                             json=lambda _: rows, snapshot=lambda *_: {"count": 3, "sha256": "a" * 64})
        m.compare_values(source, pg)
        rows.pop()
        with self.assertRaises(m.Failure):
            m.compare_values(source, pg)

    def test_archive_allowlist(self):
        runner = SimpleNamespace(tool=lambda name: name,
                                 run=lambda _: '; header\n1; 0 42 TABLE DATA public items stageadmin\n')
        m.archive_entries(runner, "dummy", ["items"], [])
        for line in ('1; 0 42 TABLE public items stageadmin',
                     '1; 0 42 TABLE DATA public __diesel_schema_migrations stageadmin',
                     '1; 0 42 TABLE DATA other items stageadmin',
                     '1; 0 42 SEQUENCE SET public unexpected stageadmin'):
            runner.run = lambda _, line=line: line
            with self.assertRaises(m.Failure):
                m.archive_entries(runner, "dummy", ["items"], [])

    def manifest(self):
        return {"format": 1, "status": "ready", "release": m.RELEASE, "run_id": "a" * 32,
                "reference_sha256": m.digest(HERE / "vaultwarden-1.37.3-migrations.json"),
                "source_sha256": m.digest(self.path), "archive_sha256": m.digest(self.directory / "data.dump"),
                "columns": {"items": [{"name": "name", "type": "text"}, {"name": "enabled", "type": "boolean"}]},
                "snapshots": {"items": {"count": 0, "sha256": "a" * 64}}, "sequences": [], "schema": {}}

    def test_artifact_tamper_and_retry_guards(self):
        self.path.rename(self.directory / "source.sqlite3")
        m.write_private(self.directory / "data.dump", "synthetic")
        manifest = self.manifest()
        m.save_json(self.directory / "manifest.json", manifest)
        m.read_artifact(self.directory)
        m.write_private(self.directory / "live-attempt.json", '{}')
        with self.assertRaises(m.Failure):
            m.read_artifact(self.directory)
        (self.directory / "live-attempt.json").unlink()
        manifest["archive_sha256"] = "0" * 64
        m.save_json(self.directory / "manifest.json", manifest)
        with self.assertRaises(m.Failure):
            m.read_artifact(self.directory)

    def test_cluster_guard(self):
        pods = []
        suspended = True
        remote = SimpleNamespace(api="https://[fd2d:b57c:c77b:9::20]:6443", execute=lambda _: "rke2-server",
                                 get=lambda *_: {"spec": {"suspend": suspended}},
                                 kube=lambda *_: json.dumps({"items": pods}))
        m.check_cluster(remote)
        suspended = False
        with self.assertRaises(m.Failure):
            m.check_cluster(remote)
        suspended = True
        pods.append({"spec": {"ephemeralContainers": [{"image": "ghcr.io/dani-garcia/vaultwarden:1.37.3"}]}})
        with self.assertRaises(m.Failure):
            m.check_cluster(remote)

    def test_transaction_guards(self):
        m.write_private(self.directory / "data.dump", "synthetic")
        manifest = self.manifest()
        sql = m.guard_sql(manifest)
        self.assertIn('IN ACCESS EXCLUSIVE MODE', sql)
        self.assertIn('pg_advisory_xact_lock', sql)
        self.assertIn('current_database()', sql)
        self.assertIn('inet_server_addr()', sql)
        self.assertIn('count(*) FROM public."items") = 0', sql)
        self.assertIn('Diesel migration history differs', sql)
        self.assertIn('Schema changed', sql)
        self.assertNotIn('DROP ', sql)
        self.assertNotIn('TRUNCATE ', sql)
        self.assertIn('sha256', m.verification_sql(manifest))
        self.assertIn('IS NOT TRUE', sql)  # NULL must fail closed, too.

    def test_identity_is_exact_and_failures_are_nonsecret(self):
        identity = {'role': 'vaultwarden', 'database': 'vaultwarden',
                    'address': m.DB_ADDRESS, 'port': 5432, 'version': 170011}
        m.validate_identity(identity)
        self.assertIn('host(inet_server_addr())', m.IDENTITY_SQL)
        self.assertNotIn('inet_server_addr()::text', m.IDENTITY_SQL)
        for field, wrong in (('role', 'private-login'), ('database', 'other'),
                             ('address', 'fd2d:b57c:c77b:200::11'), ('address', None),
                             ('port', 15432), ('version', 160011), ('version', 180000),
                             ('port', True), ('version', None)):
            with self.subTest(field=field, wrong=wrong), self.assertRaises(m.Failure) as caught:
                m.validate_identity(dict(identity, **{field: wrong}))
            self.assertIn('failed checks: ' + field, str(caught.exception))
            self.assertNotIn('private-login', str(caught.exception))

    def test_expected_loader_warnings_only(self):
        log = self.directory / 'loader.log'
        schema = {"constraints": [["items", "items_fkey"]]}
        columns = {"items": [{"name": "name", "type": "character varying"}]}
        log.write_text('2026-01-01T00:00:00Z WARNING Source column "public"."items"."name" is casted to type '
                       '"text" which is not the same as "character varying", the type of current target database '
                       'column "public"."items"."name".\n'
                       '2026-01-01T00:00:00Z WARNING PostgreSQL warning: constraint "items_fkey" of relation "items" '
                       'does not exist, skipping\n')
        m.validate_loader_logs([log], schema, columns)
        for message in ('WARNING unknown warning', 'ERROR copy failed',
                        'WARNING PostgreSQL warning: constraint "unknown" of relation "items" does not exist, skipping'):
            log.write_text('2026-01-01T00:00:00Z ' + message)
            with self.assertRaises(m.Failure):
                m.validate_loader_logs([log], schema, columns)


class LiveMocks(unittest.TestCase):
    """Mock every remote operation; exercise credential and receipt ownership."""

    setUp = Guards.setUp
    manifest = Guards.manifest
    def run_live(self, *, cancel=False, nonempty=False, collision=False, transaction_fail=False, revoke_fail=False,
                 identity_override=None):
        m.write_private(self.directory / 'data.dump', 'synthetic')
        manifest = self.manifest()
        source = SimpleNamespace(tables=['items'], counts={'items': 0}, unchanged=lambda: None)
        args = SimpleNamespace(artifact_dir=str(self.directory), pg_port=15432,
                               bao_addr='https://[::1]:18200')
        calls, commands, connections = [], [], []
        receipt_path = self.directory / 'live-attempt.json'
        test = self

        class FakeRunner:
            def __init__(self, directory):
                self.directory, self.env = directory, m.clean_env(directory)
                m.write_private(directory / 'commands.log', '')

            def versions(self):
                return {}

            def tool(self, name):
                return name

            def run(self, command, **kwargs):
                commands.append(command)
                test.assertNotIn('operator-secret', repr(command))
                test.assertNotIn('A' * 48, repr(command))
                if command[0] == 'pg_restore':
                    m.write_private(Path(command[command.index('--file') + 1]), '-- synthetic restore\n')
                    if collision:
                        m.write_private(receipt_path, '{"state":"other-invocation"}')
                if command[0] == 'psql' and transaction_fail:
                    raise m.Failure('synthetic connection lost')
                return ''

        class FakePg:
            def __init__(self, runner, connection):
                self.connection = connection
                connections.append(connection)
                test.assertIn('sslmode=verify-full', connection)
                test.assertIn('host=postgres.infra.windows.moe hostaddr=::1', connection)
                passfile = runner.directory / 'pgpass'
                test.assertEqual(passfile.stat().st_mode & 0o777, 0o600)
                test.assertNotIn('operator-secret', passfile.read_text())
                test.assertNotIn('BAO_TOKEN', runner.env)

            def json(self, query):
                test.assertEqual(query, m.IDENTITY_SQL)
                test.assertIn('host(inet_server_addr())', query)
                return dict({'role': 'vaultwarden', 'database': 'vaultwarden', 'address': m.DB_ADDRESS,
                             'port': 5432, 'version': 170011}, **(identity_override or {}))

            def migrations(self):
                return m.REFERENCE['postgresql']

            def schema(self):
                return manifest['schema']

            def tables(self):
                return ['items']

            def text(self, query):
                return '1' if nonempty else '0'

            def snapshot(self, *_):
                return manifest['snapshots']['items']

        class FakeBao:
            def __init__(self, *args):
                self.token = ''

            def request(self, method, path, data=None, **kwargs):
                calls.append((method, path, data, kwargs))
                if path == 'sys/health':
                    return {'cluster_id': m.CLUSTER, 'sealed': False}
                if path == 'auth/token/create':
                    return {'auth': {'accessor': 'owned-accessor', 'client_token': 'owned-child', 'lease_duration': 900}}
                if path == 'database/creds/vaultwarden':
                    return {'data': {'username': 'v-test', 'password': 'A' * 48}}
                if path == 'auth/token/revoke-accessor':
                    if revoke_fail:
                        raise m.Failure('synthetic revoke failure')
                    return {}
                test.fail('Unexpected API path')

        original_open = open
        def terminal_open(path, *a, **kw):
            if path == '/dev/tty':
                return io.StringIO('cancel\n' if cancel else 'IMPORT vaultwarden ' + manifest['run_id'] + '\n')
            return original_open(path, *a, **kw)

        remote = SimpleNamespace(execute=lambda *_: 'synthetic-public-ca')
        output, error = io.StringIO(), None
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(m, 'read_artifact', return_value=(self.directory, manifest, source)))
            stack.enter_context(patch.object(m, 'archive_entries'))
            stack.enter_context(patch.object(m, 'check_cluster'))
            stack.enter_context(patch.object(m.support, 'Remote', return_value=remote))
            stack.enter_context(patch.object(m.support, 'Bao', FakeBao))
            stack.enter_context(patch.object(m, 'Runner', FakeRunner))
            stack.enter_context(patch.object(m, 'Pg', FakePg))
            stack.enter_context(patch.object(m.getpass, 'getpass', return_value='operator-secret'))
            stack.enter_context(patch.object(m, 'open', terminal_open, create=True))
            stack.enter_context(contextlib.redirect_stdout(output))
            try:
                m.import_live(args)
            except (m.Failure, FileExistsError) as caught:
                error = caught
        self.assertNotIn('operator-secret', output.getvalue())
        self.assertNotIn('A' * 48, output.getvalue())
        child = next(c for c in calls if c[1] == 'auth/token/create')
        self.assertEqual(child[2]['policies'], ['vaultwarden'])
        self.assertTrue(child[2]['no_default_policy'])
        self.assertEqual(child[2]['explicit_max_ttl'], '15m')
        revoke = [c for c in calls if c[1] == 'auth/token/revoke-accessor']
        self.assertEqual(len(revoke), 1)
        self.assertEqual(revoke[0][2], {'accessor': 'owned-accessor'})
        receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else None
        return error, commands, receipt

    def test_live_success(self):
        error, commands, receipt = self.run_live()
        self.assertIsNone(error)
        self.assertEqual(receipt['state'], 'verified')
        self.assertTrue(receipt['credentials_revoked'])
        self.assertTrue(any('--single-transaction' in c for c in commands))

    def test_cancel_never_restores(self):
        error, commands, receipt = self.run_live(cancel=True)
        self.assertIsNotNone(error)
        self.assertIsNone(receipt)
        self.assertFalse(commands)

    def test_nonempty_never_restores(self):
        error, commands, receipt = self.run_live(nonempty=True)
        self.assertIsNotNone(error)
        self.assertIsNone(receipt)
        self.assertFalse(commands)

    def test_identity_failure_never_confirms_or_restores(self):
        error, commands, receipt = self.run_live(identity_override={'address': None})
        self.assertIsNotNone(error)
        self.assertIn('failed checks: address', str(error))
        self.assertIsNone(receipt)
        self.assertFalse(commands)

    def test_collision_never_overwrites_others_receipt(self):
        error, commands, receipt = self.run_live(collision=True)
        self.assertIsNotNone(error)
        self.assertEqual(receipt, {'state': 'other-invocation'})
        self.assertFalse(any(c[0] == 'psql' for c in commands))

    def test_connection_failure_has_uncertain_receipt(self):
        error, commands, receipt = self.run_live(transaction_fail=True)
        self.assertIsNotNone(error)
        self.assertEqual(receipt['state'], 'transaction-starting')
        self.assertTrue(receipt['credentials_revoked'])

    def test_revoke_failure_is_failure_not_success(self):
        error, commands, receipt = self.run_live(revoke_fail=True)
        self.assertIsNotNone(error)
        self.assertEqual(receipt['state'], 'verified')
        self.assertFalse(receipt['credentials_revoked'])


@unittest.skipUnless(os.environ.get("RUN_MIGRATION_INTEGRATION") == "1", "optional local synthetic integration test")
class Integration(unittest.TestCase):
    def test_full_rehearsal_and_transaction_rollback(self):
        os.umask(0o077)
        parent = Path(tempfile.mkdtemp(prefix="vw-synthetic-"))
        print("\nSynthetic test directory: " + str(parent), flush=True)
        binary = Path("result-vaultwarden-pg-migration/bin/vaultwarden").resolve()
        seed_dir = parent / "seed"
        seed_dir.mkdir(mode=0o700)
        runner = m.Runner(seed_dir)
        with m.LocalCluster(runner, binary) as local:
            pg = local.initialize("seed")
            identity = pg.json(m.IDENTITY_SQL)
            self.assertIsNone(identity['address'])  # Private Unix socket, not a live TCP target.
            with self.assertRaises(m.Failure):
                m.validate_identity(identity)
            # Exercise the exact identity query with a synthetic inet value;
            # the old ::text cast returned /128 and rejected the intended host.
            address_sql = m.literal(m.DB_ADDRESS) + '::inet'
            result = pg.json(m.IDENTITY_SQL.replace('inet_server_addr()', address_sql))
            self.assertEqual(result['address'], m.DB_ADDRESS)
            old_format = pg.json('SELECT to_json((' + address_sql + ')::text)')
            self.assertEqual(old_format, m.DB_ADDRESS + '/128')
            definitions, values = {}, {}
            for table in pg.tables():
                columns = pg.columns(table)
                # Synthetic source has the same column names/types, not real vault data.
                affinity = {"boolean": "BOOLEAN", "integer": "INTEGER", "bigint": "BIGINT",
                            "timestamp without time zone": "DATETIME", "bytea": "BLOB"}
                definitions[table] = ','.join(m.identifier(c["name"]) + ' ' + affinity.get(c["type"], "TEXT") for c in columns)
                if table not in {"users", "ciphers", "attachments", "folders", "folders_ciphers",
                                 "archives", "twofactor", "devices"}:
                    continue
                nullable = pg.json("SELECT json_object_agg(column_name,is_nullable='YES') FROM information_schema.columns "
                                   "WHERE table_schema='public' AND table_name=" + m.literal(table))
                rows = []
                for number in range(2):
                    row = []
                    for c in columns:
                        name, kind = c["name"], c["type"]
                        if name in ("uuid", "user_uuid", "cipher_uuid", "folder_uuid"):
                            value = str(uuid.UUID(int=number + 1))
                        elif nullable[name]:
                            value = None
                        elif kind == "boolean":
                            value = number
                        elif kind in ("integer", "bigint", "smallint"):
                            value = 0
                        elif kind == "timestamp without time zone":
                            value = ("2026-01-02 03:04:05.123456789" if number == 0 else
                                     "2026-12-31 23:59:59.999999999")
                        elif kind == "bytea":
                            value = b"synthetic\x00\xff" + bytes([number])
                        elif kind in ("text", "character varying", "character"):
                            value = (f"fixture-{number}@example.invalid" if name == "email" else
                                     f"synthetic {number} ż\n'\\value")
                        else:
                            self.fail("Unsupported synthetic fixture type: " + kind)
                        row.append(value)
                    rows.append(row)
                values[table] = rows
            source = fixture(parent / "recovered.sqlite3", definitions, values)
        args = SimpleNamespace(sqlite=str(source), vaultwarden_bin=str(binary), work_parent=str(parent))
        m.rehearse(args)
        artifacts = list(parent.glob("vw-stage-*"))
        self.assertEqual(len(artifacts), 1)
        artifact, manifest, source = m.read_artifact(artifacts[0])
        self.assertEqual(sum(s["count"] for s in manifest["snapshots"].values()), 16)
        check_dir = parent / "transaction"
        check_dir.mkdir(mode=0o700)
        runner = m.Runner(check_dir)
        with m.LocalCluster(runner, binary) as local:
            pg = local.initialize("rollbackcheck")
            before = check_dir / "before.sql"
            after = check_dir / "after.sql"
            restore = check_dir / "restore.sql"
            m.write_private(before, m.verification_sql(manifest, empty=True))
            m.write_private(after, m.verification_sql(manifest) + "DO $$ BEGIN RAISE EXCEPTION 'synthetic failure'; END $$;")
            runner.run([runner.tool("pg_restore"), "--no-owner", "--no-privileges", "--file", str(restore), str(artifact / "data.dump")])
            command = [runner.tool("psql"), "-X", "-w", "-q", "--single-transaction", "--set=ON_ERROR_STOP=1",
                       "--dbname", pg.connection, "--file", str(before), "--file", str(restore), "--file", str(after)]
            with self.assertRaises(m.Failure):
                runner.run(command)
            self.assertEqual(pg.text('SELECT count(*) FROM public.users'), '0')
            self.assertEqual(pg.migrations(), m.REFERENCE["postgresql"])
            after.unlink()
            m.write_private(after, m.verification_sql(manifest))
            runner.run(command)
            self.assertEqual(pg.text('SELECT count(*) FROM public.users'), '2')
            with self.assertRaises(m.Failure):
                pg.text(m.verification_sql(manifest, empty=True))
            pg.text('DELETE FROM public.__diesel_schema_migrations')
            with self.assertRaises(m.Failure):
                pg.text(m.verification_sql(manifest))
            for version in m.REFERENCE['postgresql']:
                pg.text('INSERT INTO public.__diesel_schema_migrations(version) VALUES (' + m.literal(version) + ')')
            pg.text("ALTER TABLE public.users ADD COLUMN unexpected text")
            with self.assertRaises(m.Failure):
                pg.text(m.verification_sql(manifest))
        print("PASS: synthetic conversion, archive round trip, rollback, existing-data and schema guards", flush=True)


if __name__ == "__main__":
    unittest.main()
