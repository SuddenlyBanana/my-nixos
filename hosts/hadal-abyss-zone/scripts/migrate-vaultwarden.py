#!/usr/bin/env python3
"""Rehearse Vaultwarden 1.37.3 SQLite conversion; live import is a separate command.

No production connections in inspect/rehearse. No app activation, file-volume
copy, credential reset, live schema changes, or automatic retry after a live attempt.
Sensitive values stay in memory or owner-only local files, never terminal output.
"""

import argparse
from collections import Counter
from contextlib import closing
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import getpass
import hashlib
import http.client
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlencode
import uuid


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("hadal_csi_support", HERE / "smoke-test-openbao-csi.py")
support = importlib.util.module_from_spec(spec)
spec.loader.exec_module(support)
Failure, require = support.Failure, support.require
REFERENCE = json.loads((HERE / "vaultwarden-1.37.3-migrations.json").read_text())
RELEASE = "1.37.3"
CLUSTER = "170f7f7c-389b-5d34-e434-252e5fabfda5"
DB_ADDRESS = "fd2d:b57c:c77b:200::10"
MIGRATION_TABLE = "__diesel_schema_migrations"
PG_SETTINGS = """SET search_path TO pg_catalog;
SET timezone TO 'UTC'; SET datestyle TO 'ISO, YMD';
SET bytea_output TO 'hex'; SET extra_float_digits TO 3;
"""
# inet::text always includes the netmask (/128 for an IPv6 host). Compare the
# actual host address, not that display format. The transaction guard below
# separately compares inet values directly, preserving the exact target check.
IDENTITY_SQL = ("SELECT json_build_object('role',current_user,'database',current_database(),"
                "'address',host(inet_server_addr()),'port',inet_server_port(),"
                "'version',current_setting('server_version_num')::integer)")


def identifier(name):
    require(isinstance(name, str) and re.fullmatch(r"[a-z_][a-z0-9_]*", name), "Unexpected SQL identifier")
    return '"' + name + '"'


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def private(path, directory=False):
    path = Path(path).expanduser().absolute()
    require(not path.is_symlink(), "Refusing a symlink for a private migration file/directory")
    info = path.stat()
    require((stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))
            and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0,
            "Migration paths must be owned by you and inaccessible to group/other users")
    return path.resolve()


def write_private(path, data):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    with os.fdopen(os.open(path, flags, 0o600), "wb") as stream:
        stream.write(data.encode() if isinstance(data, str) else data)
        stream.flush()
        os.fsync(stream.fileno())
    sync_directory(Path(path).parent)


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def save_json(path, data):
    path = Path(path)
    if path.exists() or path.is_symlink():
        private(path)
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    write_private(temporary, json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.replace(temporary, path)
    sync_directory(path.parent)


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def clean_env(home):
    # In particular: no BAO_TOKEN, VAULT_TOKEN, PG*, DATABASE_URL, ENV_FILE,
    # inherited loader/debug options, or administrator credential in children.
    return {"PATH": os.environ.get("PATH", os.defpath), "HOME": str(home),
            "LC_ALL": "C", "LANG": "C", "TZ": "UTC"}


class Source:
    def __init__(self, path):
        self.path = private(path)
        private(self.path.parent, directory=True)
        with self.path.open("rb") as stream:
            header = stream.read(100)
        require(header.startswith(b"SQLite format 3\0") and header[18:20] == b"\x01\x01",
                "Use a standalone recovered SQLite database in DELETE journal mode, not a raw WAL backup")
        require(not any(Path(str(self.path) + suffix).exists() for suffix in ("-wal", "-journal")),
                "SQLite sidecar found; recover a standalone copy first")
        self.sha = digest(self.path)
        try:
            with self.connect() as db:
                require(db.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "SQLite integrity check failed")
                require(not db.execute("PRAGMA foreign_key_check").fetchall(), "SQLite has foreign-key violations")
                migrations = sorted(str(r[0]) for r in db.execute(f"SELECT version FROM {identifier(MIGRATION_TABLE)}"))
                require(migrations == REFERENCE["sqlite"], "SQLite migration IDs do not exactly match release 1.37.3")
                self.tables = [r[0] for r in db.execute(
                    "SELECT name FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' "
                    "AND name <> ? ORDER BY name", (MIGRATION_TABLE,))]
                require(self.tables, "SQLite has no application tables")
                self.columns = {}
                self.counts = {}
                for table in self.tables:
                    self.columns[table] = [r[1] for r in db.execute(f"PRAGMA table_info({identifier(table)})")]
                    self.counts[table] = db.execute(f"SELECT count(*) FROM {identifier(table)}").fetchone()[0]
        except sqlite3.Error:
            raise Failure("SQLite inspection failed; details suppressed") from None

    def connect(self):
        return closing(sqlite3.connect(self.path.as_uri() + "?mode=ro&immutable=1", uri=True))

    def unchanged(self):
        require(digest(self.path) == self.sha, "SQLite source changed; refusing to continue")


class Runner:
    def __init__(self, directory):
        self.directory = directory
        self.env = clean_env(directory)
        self.log = directory / "commands.log"
        write_private(self.log, "")

    def tool(self, name):
        path = shutil.which(name, path=self.env["PATH"])
        require(path, f"Missing {name}; enter nix develop .#devops --command bash")
        return path

    def run(self, command, *, env=None, timeout=60, output=None):
        try:
            with self.log.open("ab") as errors:
                if output is None:
                    result = subprocess.run(command, env=env or self.env, cwd=self.directory,
                                            stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout,
                                            umask=0o077)
                    if result.stderr:
                        errors.write(result.stderr)
                    value = result.stdout
                else:
                    with os.fdopen(os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
                        result = subprocess.run(command, env=env or self.env, cwd=self.directory,
                                                stdin=subprocess.DEVNULL, stdout=stream, stderr=errors,
                                                timeout=timeout, umask=0o077)
                    value = b""
        except subprocess.TimeoutExpired:
            raise Failure(f"{Path(command[0]).name} timed out; private logs retained") from None
        require(result.returncode == 0, f"{Path(command[0]).name} failed; private logs retained, raw output suppressed")
        return value.decode("utf-8")

    def spawn(self, command, log_name, env=None):
        path = self.directory / log_name
        with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as log:
            return subprocess.Popen(command, env=env or self.env, cwd=self.directory,
                                    stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                    umask=0o077)

    def versions(self, binary=None):
        result = {}
        for tool in ("initdb", "postgres", "psql", "pg_dump", "pg_restore"):
            version = self.run([self.tool(tool), "--version"]).strip()
            require(re.search(r"\(PostgreSQL\) 17\.", version), "All PostgreSQL tools must be version 17")
            result[tool] = version
        version = self.run([self.tool("pgloader"), "--version"]).strip()
        require(re.search(r'pgloader version "?3\.6\.9(?:"|\s|$)', version, re.I), "This helper is tested with pgloader 3.6.9")
        result["pgloader"] = version
        if binary:
            version = self.run([str(binary), "--version"]).splitlines()[0]
            require(version == "Vaultwarden " + RELEASE, "Vaultwarden must be exactly 1.37.3")
            result["vaultwarden"] = version
        return result


def conn_quote(value):
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


class Pg:
    def __init__(self, runner, connection, env=None):
        self.runner, self.connection = runner, connection
        self.env = env or runner.env

    def text(self, sql):
        return self.runner.run([self.runner.tool("psql"), "-X", "-w", "-qAt", "--set=ON_ERROR_STOP=1",
                                "--dbname", self.connection, "--command", PG_SETTINGS,
                                "--command", sql], env=self.env).strip()

    def json(self, sql):
        try:
            return json.loads(self.text(sql), parse_float=Decimal)
        except ValueError:
            raise Failure("Invalid PostgreSQL metadata response; values suppressed") from None

    def migrations(self):
        return self.json(f"SELECT coalesce(json_agg(version ORDER BY version), '[]'::json) "
                         f"FROM public.{identifier(MIGRATION_TABLE)}")

    def tables(self):
        return self.json("SELECT coalesce(json_agg(tablename ORDER BY tablename), '[]'::json) "
                         "FROM pg_tables WHERE schemaname='public' AND tablename <> " + literal(MIGRATION_TABLE))

    def columns(self, table):
        return self.json("SELECT coalesce(json_agg(json_build_object('name',column_name,'type',data_type) "
                         "ORDER BY ordinal_position),'[]'::json) FROM information_schema.columns "
                         "WHERE table_schema='public' AND table_name=" + literal(table))

    def snapshot(self, table, columns):
        return self.json(snapshot_sql(table, columns))

    def schema(self):
        return self.json(SCHEMA_SQL)


SCHEMA_SQL = """SELECT json_build_object(
'relations', (SELECT coalesce(json_agg(json_build_array(c.relname,c.relkind,c.relrowsecurity,c.relforcerowsecurity)
    ORDER BY c.relname),'[]'::json) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public'),
'columns', (SELECT coalesce(json_agg(json_build_array(c.relname,a.attname,format_type(a.atttypid,a.atttypmod),
    a.attnotnull,pg_get_expr(d.adbin,d.adrelid),a.attidentity,a.attgenerated) ORDER BY c.relname,a.attnum),'[]'::json)
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid
    LEFT JOIN pg_attrdef d ON d.adrelid=c.oid AND d.adnum=a.attnum
    WHERE n.nspname='public' AND a.attnum>0 AND NOT a.attisdropped AND c.relkind IN ('r','p')),
'constraints', (SELECT coalesce(json_agg(json_build_array(c.relname,k.conname,k.contype,k.convalidated,
    pg_get_constraintdef(k.oid,true)) ORDER BY c.relname,k.conname),'[]'::json)
    FROM pg_constraint k JOIN pg_class c ON c.oid=k.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public'),
'indexes', (SELECT coalesce(json_agg(json_build_array(c.relname,i.indisvalid,i.indisready,
    pg_get_indexdef(i.indexrelid)) ORDER BY c.relname),'[]'::json)
    FROM pg_index i JOIN pg_class c ON c.oid=i.indexrelid JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='public'),
'triggers', (SELECT coalesce(json_agg(json_build_array(c.relname,t.tgname,pg_get_triggerdef(t.oid,true))
    ORDER BY c.relname,t.tgname),'[]'::json) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
    JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='public' AND NOT t.tgisinternal),
'functions', (SELECT coalesce(json_agg(json_build_array(p.proname,pg_get_function_identity_arguments(p.oid))
    ORDER BY p.proname,pg_get_function_identity_arguments(p.oid)),'[]'::json) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public')
);"""


def snapshot_sql(table, columns):
    selected = ",".join(identifier(c) for c in sorted(columns))
    return ("SELECT json_build_object('count',count(*),'sha256',encode(sha256(convert_to("
            "coalesce(string_agg(row_to_json(t)::text,E'\\n' ORDER BY row_to_json(t)::text COLLATE \"C\"),''),"
            "'UTF8')),'hex')) FROM (SELECT " + selected + " FROM public." + identifier(table) + ") t;")


def normalize(value, kind):
    if value is None:
        return None
    try:
        if kind in ("text", "character varying", "character", "name"):
            require(isinstance(value, str), "Non-text value in a text column")
            return value
        if kind == "boolean":
            require(value in (0, 1, False, True), "Invalid boolean value")
            return bool(value)
        if kind in ("smallint", "integer", "bigint"):
            number = Decimal(str(value))
            require(number == number.to_integral_value(), "Non-integral value in an integer column")
            return str(int(number))
        if kind in ("numeric", "decimal", "real", "double precision"):
            number = Decimal(str(value))
            require(number.is_finite(), "Non-finite numeric value")
            return str(number.normalize())
        if kind in ("timestamp without time zone", "timestamp with time zone"):
            # SQLite/Chrono can store nanoseconds; PostgreSQL 17 stores integer
            # microseconds. datetime.fromisoformat silently TRUNCATES beyond
            # six digits, whereas PG's ParseFractionalSecond uses
            # rint(strtod(fraction) * 1000000). Mirror that exact conversion,
            # including ties-to-even and a carry into the next second/day.
            # Do not permit a tolerance: a genuine 1-us discrepancy must fail.
            match = re.fullmatch(r"(\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d)"
                                 r"(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)?", str(value))
            require(match, "Unsupported timestamp representation; values suppressed")
            whole, fraction, offset = match.groups()
            timestamp = datetime.fromisoformat(whole + ("+00:00" if offset == "Z" else offset or ""))
            timestamp += timedelta(microseconds=round(float("0." + fraction) * 1_000_000) if fraction else 0)
            if kind == "timestamp without time zone":
                require(timestamp.tzinfo is None, "Unexpected timezone on a naive timestamp")
            else:
                require(timestamp.tzinfo is not None, "Missing timezone on an aware timestamp")
                timestamp = timestamp.astimezone(timezone.utc)
            return timestamp.isoformat(timespec="microseconds")
        if kind == "bytea":
            if isinstance(value, bytes):
                return value.hex()
            require(isinstance(value, str) and value.startswith("\\x"), "Unexpected bytea representation")
            return bytes.fromhex(value[2:]).hex()
        if kind == "uuid":
            return uuid.UUID(str(value)).hex
        raise Failure("Unsupported nonempty column type; manual conversion review required")
    except (ValueError, ArithmeticError, TypeError):
        raise Failure("Value normalization failed; values suppressed") from None


def compare_values(source, pg):
    require(pg.tables() == source.tables, "Application table sets differ")
    snapshots, column_map = {}, {}
    with source.connect() as db:
        for table in source.tables:
            columns = pg.columns(table)
            names = sorted(c["name"] for c in columns)
            require(names == sorted(source.columns[table]), f"Column names differ for {table}")
            types = {c["name"]: c["type"] for c in columns}
            selected = ",".join(identifier(c) for c in names)
            sqlite_rows = db.execute(f"SELECT {selected} FROM {identifier(table)}").fetchall()
            postgres_rows = pg.json("SELECT coalesce(json_agg(t),'[]'::json) FROM (SELECT "
                                    + selected + " FROM public." + identifier(table) + ") t")
            def key(row):
                normalized = [normalize(value, types[name]) for name, value in zip(names, row)]
                return json.dumps(normalized, ensure_ascii=False, separators=(",", ":"))
            expected = Counter(key(row) for row in sqlite_rows)
            actual = Counter(key([row[name] for name in names]) for row in postgres_rows)
            require(expected == actual, f"Row/value comparison failed for {table}; values suppressed")
            snapshots[table] = pg.snapshot(table, names)
            column_map[table] = columns
            require(snapshots[table]["count"] == source.counts[table], f"Row count differs for {table}")
    source.unchanged()
    return snapshots, column_map


def stop(process, postgres=False):
    if process is None or process.poll() is not None:
        return
    process.send_signal(signal.SIGINT if postgres else signal.SIGTERM)
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        process.send_signal(signal.SIGQUIT if postgres else signal.SIGKILL)
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            raise Failure("Owned local process did not stop; inspect the private process receipt") from None
        raise Failure("Owned local process required forced shutdown; inspect before continuing") from None


class LocalCluster:
    def __init__(self, runner, binary):
        self.runner, self.binary = runner, binary
        self.process = self.app = None
        self.socket = runner.directory / "socket"
        self.pgdata = runner.directory / "pgdata"

    def pg(self, database="postgres"):
        return Pg(self.runner, f"host={conn_quote(self.socket)} port=55432 dbname={conn_quote(database)} user=stageadmin")

    def __enter__(self):
        self.socket.mkdir(mode=0o700)
        require(len(os.fsencode(self.socket / ".s.PGSQL.55432")) < 104, "Staging Unix socket path is too long")
        self.runner.run([self.runner.tool("initdb"), "-D", str(self.pgdata), "-U", "stageadmin",
                         "--auth=trust", "--encoding=UTF8", "--locale=C"], timeout=60)
        try:
            self.process = self.runner.spawn([self.runner.tool("postgres"), "-D", str(self.pgdata),
                "-k", str(self.socket), "-p", "55432", "-c", "listen_addresses=", "-c", "unix_socket_permissions=0700"],
                "postgres.log")
            save_json(self.runner.directory / "processes.json", {"postgres": self.process.pid})
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                require(self.process.poll() is None, "Local PostgreSQL exited; inspect private postgres.log")
                if (self.socket / ".s.PGSQL.55432").exists():
                    try:
                        self.pg().text("SELECT 1")
                        return self
                    except Failure:
                        pass  # The socket can appear before recovery/readiness completes.
                time.sleep(0.1)
            raise Failure("Local PostgreSQL readiness timed out")
        except BaseException:
            stop(self.process, postgres=True)
            raise

    def initialize(self, database):
        self.pg().text("CREATE DATABASE " + identifier(database))
        data = self.runner.directory / ("data-" + database)
        data.mkdir(mode=0o700)
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as listener:
            listener.bind(("::1", 0))
            port = listener.getsockname()[1]
        env = dict(self.runner.env, DATABASE_URL="postgresql:///" + database + "?" + urlencode({
            "host": str(self.socket), "port": "55432", "user": "stageadmin"}),
            DATA_FOLDER=str(data), CONFIG_FILE=str(data / "config.json"), ENV_FILE="/dev/null",
            WEB_VAULT_ENABLED="false", ROCKET_ADDRESS="::1", ROCKET_PORT=str(port), DOMAIN=f"http://[::1]:{port}",
            SIGNUPS_ALLOWED="false", INVITATIONS_ALLOWED="false", JOB_POLL_INTERVAL_MS="0", PUSH_ENABLED="false",
            DISABLE_ICON_DOWNLOAD="true", DB_CONNECTION_RETRIES="3", DATABASE_MAX_CONNS="2", DATABASE_MIN_CONNS="1")
        self.app = self.runner.spawn([str(self.binary)], "vaultwarden-" + database + ".log", env)
        save_json(self.runner.directory / "processes.json", {"postgres": self.process.pid, "vaultwarden": self.app.pid})
        try:
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                require(self.app.poll() is None, "Local Vaultwarden exited; inspect its private log")
                client = http.client.HTTPConnection("::1", port, timeout=1)
                try:
                    client.request("GET", "/alive")
                    response = client.getresponse()
                    response.read()
                    if response.status == 200:
                        break
                except (OSError, http.client.HTTPException):
                    pass
                finally:
                    client.close()
                time.sleep(0.2)
            else:
                raise Failure("Local Vaultwarden readiness timed out")
        finally:
            stop(self.app)
        require(self.app.returncode == 0, "Local Vaultwarden did not stop cleanly")
        pg = self.pg(database)
        require(pg.migrations() == REFERENCE["postgresql"], "Local PostgreSQL migration IDs differ from release 1.37.3")
        for table in pg.tables():
            require(pg.text("SELECT count(*) FROM public." + identifier(table)) == "0", "New staging database has application data")
        return pg

    def __exit__(self, *error):
        try:
            stop(self.app)
        finally:
            stop(self.process, postgres=True)


def archive_entries(runner, archive, tables, sequences):
    listing = runner.run([runner.tool("pg_restore"), "--list", str(archive)])
    seen, seq_seen = [], []
    for line in listing.splitlines():
        if not line.strip() or line.startswith(";"):
            continue
        match = re.fullmatch(r"\d+;\s+\d+\s+\d+\s+(TABLE DATA|SEQUENCE SET) public ([a-z_][a-z0-9_]*) ([a-z_][a-z0-9_]*)", line)
        require(match, "Archive contains an unexpected object; only public table data/sequence values are allowed")
        kind, name, _ = match.groups()
        require(name != MIGRATION_TABLE, "Archive must not overwrite Diesel migration history")
        (seen if kind == "TABLE DATA" else seq_seen).append(name)
    require(sorted(seen) == sorted(tables) and sorted(seq_seen) == sorted(sequences), "Archive object set differs from the rehearsal")


def validate_loader_logs(paths, schema, column_map):
    # pgloader 3.6.9 compares its inferred SQLite types with the existing PG
    # schema and rebuilds local constraints/indexes. Only these exact metadata
    # warnings are expected. Full values, schema and validated FKs are checked
    # independently afterwards; no live pgloader connection is ever made.
    constraints = {(c[0], c[1]) for c in schema["constraints"]}
    types = {(t, c["name"]): c["type"] for t, cols in column_map.items() for c in cols}
    pairs = {("text", "character"), ("text", "character varying"),
             ("bigint", "integer"), ("timestamptz", "timestamp without time zone")}
    for path in paths:
        require(path.is_file(), "Missing pgloader log")
        for line in path.read_text(errors="replace").splitlines():
            entry = re.match(r"^\d{4}-\d\d-\d\dT\S+\s+(ERROR|FATAL|WARN(?:ING)?)\s+(.*)$", line)
            if not entry:
                continue
            level, message = entry.groups()
            require(level not in ("ERROR", "FATAL"), "pgloader reported an error; inspect private logs")
            cast = re.fullmatch(r'Source column "public"\."([a-z_]+)"\."([a-z_]+)" is casted to type '
                r'"([a-z ]+)" which is not the same as "([a-z ]+)", the type of current target database '
                r'column "public"\."([a-z_]+)"\."([a-z_]+)"\.', message)
            if cast:
                table, column, before, after, target_table, target_column = cast.groups()
                require((table, column) == (target_table, target_column)
                        and types.get((table, column)) == after and (before, after) in pairs,
                        "Unexpected pgloader type warning; inspect private logs")
                continue
            missing = re.fullmatch(r'PostgreSQL warning: constraint "([a-z_]+)" of relation "([a-z_]+)" '
                                   r'does not exist, skipping', message)
            require(missing and (missing[2], missing[1]) in constraints,
                    "Unexpected pgloader warning; inspect private logs")


def rehearse(args):
    source = Source(args.sqlite)
    binary = Path(args.vaultwarden_bin).expanduser().resolve()
    require(binary.is_file(), "Missing Vaultwarden binary")
    parent = private(args.work_parent or source.path.parent, directory=True)
    directory = Path(tempfile.mkdtemp(prefix="vw-stage-", dir=parent))
    require(re.fullmatch(r"[-A-Za-z0-9_./]+", str(directory)), "Staging path must not contain whitespace or URI metacharacters")
    print("Private rehearsal directory: " + str(directory), flush=True)
    runner = Runner(directory)
    versions = runner.versions(binary)
    copied = directory / "source.sqlite3"
    with source.path.open("rb") as incoming, os.fdopen(os.open(copied, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as outgoing:
        shutil.copyfileobj(incoming, outgoing)
    source.unchanged()
    require(digest(copied) == source.sha, "Source copy differs")
    copied_source = Source(copied)
    archive = directory / "data.dump"
    with LocalCluster(runner, binary) as local:
        pg = local.initialize("vaultwarden")
        schema_before = pg.schema()
        require(not any(r[1] == "S" for r in schema_before["relations"]),
                "Unexpected sequence; sequence updates are not transactional")
        load = directory / "migration.load"
        write_private(load, "LOAD DATABASE\n FROM " + copied.as_uri().replace("file:", "sqlite:", 1)
            + "\n INTO postgresql://stageadmin@unix:" + str(local.socket) + ":55432/vaultwarden\n"
            + " WITH data only, include no drop, reset sequences, workers = 2, concurrency = 1\n"
            + " EXCLUDING TABLE NAMES LIKE '__diesel_schema_migrations'\n;\n")
        loader_root = directory / "loader"
        loader_root.mkdir(mode=0o700)
        runner.run([runner.tool("pgloader"), "--on-error-stop", "--root-dir", str(loader_root),
            "--logfile", str(loader_root / "pgloader.log"), str(load)], timeout=300,
            output=directory / "pgloader-console.log")
        validate_loader_logs((loader_root / "pgloader.log", directory / "pgloader-console.log"),
                             schema_before, {table: pg.columns(table) for table in source.tables})
        require(pg.schema() == schema_before and pg.migrations() == REFERENCE["postgresql"],
                "pgloader changed the initialized schema or migration history")
        snapshots, columns = compare_values(copied_source, pg)
        print(f"PASS: pgloader conversion and normalized values match all {len(source.tables)} application tables", flush=True)
        runner.run([runner.tool("pg_dump"), "--dbname", pg.connection, "--format=custom", "--data-only",
                    "--no-owner", "--no-privileges", "--exclude-table=public." + MIGRATION_TABLE,
                    "--file", str(archive)], timeout=120)
        os.chmod(archive, 0o600)
        sequences = sorted(r[0] for r in schema_before["relations"] if r[1] == "S")
        archive_entries(runner, archive, source.tables, sequences)
        restored = local.initialize("restorecheck")
        require(restored.schema() == schema_before, "Fresh restore-check schema differs")
        runner.run([runner.tool("pg_restore"), "--dbname", restored.connection, "--single-transaction",
                    "--exit-on-error", "--no-owner", "--no-privileges", str(archive)], timeout=120)
        again, _ = compare_values(copied_source, restored)
        require(again == snapshots and restored.schema() == schema_before
                and restored.migrations() == REFERENCE["postgresql"], "Archive restore verification failed")
        print("PASS: data-only archive restored and verified in a second fresh local database", flush=True)
    source.unchanged()
    manifest = {"format": 1, "status": "ready", "run_id": uuid.uuid4().hex, "release": RELEASE,
                "reference_sha256": digest(HERE / "vaultwarden-1.37.3-migrations.json"),
                "source_sha256": source.sha, "archive_sha256": digest(archive),
                "original_source": str(source.path), "versions": versions, "schema": schema_before,
                "columns": columns, "snapshots": snapshots, "sequences": sequences}
    save_json(directory / "manifest.json", manifest)
    print("PASS: local rehearsal complete; no production connection was made", flush=True)
    print("Artifact directory: " + str(directory))


def read_artifact(path):
    directory = private(path, directory=True)
    manifest_path = private(directory / "manifest.json")
    require(manifest_path.stat().st_size < 2_000_000, "Manifest is unexpectedly large")
    try:
        manifest = json.loads(manifest_path.read_text())
    except ValueError:
        raise Failure("Invalid manifest") from None
    require(manifest.get("format") == 1 and manifest.get("status") == "ready" and manifest.get("release") == RELEASE,
            "Artifact is not a completed 1.37.3 rehearsal")
    require(re.fullmatch(r"[a-f0-9]{32}", manifest.get("run_id", "")), "Invalid rehearsal identity")
    require(manifest.get("reference_sha256") == digest(HERE / "vaultwarden-1.37.3-migrations.json"), "Migration reference changed")
    require(not os.path.lexists(directory / "live-attempt.json"), "A live attempt already exists; inspect its receipt, do not retry blindly")
    require(digest(private(directory / "data.dump")) == manifest.get("archive_sha256"), "Archive changed after rehearsal")
    source = Source(directory / "source.sqlite3")
    require(source.sha == manifest.get("source_sha256") and source.tables == sorted(manifest.get("snapshots", {})), "Rehearsal source changed")
    for table in source.tables:
        snapshot = manifest["snapshots"][table]
        require(snapshot.get("count") == source.counts[table] and re.fullmatch(r"[0-9a-f]{64}", snapshot.get("sha256", "")), "Invalid table snapshot")
        require(sorted(c["name"] for c in manifest["columns"][table]) == sorted(source.columns[table]), "Invalid column metadata")
    require(manifest.get("sequences") == [], "Unexpected sequence metadata")
    return directory, manifest, source


def check_cluster(remote):
    require(remote.api == "https://[fd2d:b57c:c77b:9::20]:6443", "Unexpected RKE2 target")
    require(remote.execute(["hostname"]).strip() == "rke2-server", "Unexpected SSH guest")
    require(remote.get("kustomization.kustomize.toolkit.fluxcd.io", "apps", "flux-system")["spec"].get("suspend") is True,
            "Flux apps must remain suspended")
    pods = json.loads(remote.kube("get", "pods", "-A", "-o", "json"))["items"]
    for pod in pods:
        if pod.get("status", {}).get("phase") in ("Succeeded", "Failed"):
            continue
        labels = pod.get("metadata", {}).get("labels", {})
        containers = sum((pod.get("spec", {}).get(k, []) for k in
                          ("containers", "initContainers", "ephemeralContainers")), [])
        require(labels.get("app.kubernetes.io/name") != "vaultwarden"
                and not any(re.search(r"(?:^|/)vaultwarden(?::|@|$)", c.get("image", "")) for c in containers),
                "A Vaultwarden pod may be active; stop it before importing")


def assertion(condition, message):
    return "IF (" + condition + ") IS NOT TRUE THEN RAISE EXCEPTION " + literal(message) + "; END IF;\n"


def verification_sql(manifest, empty=False):
    statements = PG_SETTINGS + "DO $hadal_verify$ BEGIN\n"
    for table, snapshot in sorted(manifest["snapshots"].items()):
        columns = [c["name"] for c in manifest["columns"][table]]
        query = snapshot_sql(table, columns).removesuffix(";")
        if empty:
            condition = f"(SELECT count(*) FROM public.{identifier(table)}) = 0"
        else:
            condition = "(" + query + ")::jsonb = " + literal(json.dumps(snapshot, sort_keys=True)) + "::jsonb"
        statements += assertion(condition, "Data check failed for " + table)
    expected_migrations = literal(json.dumps(REFERENCE["postgresql"])) + "::jsonb"
    statements += assertion("(SELECT jsonb_agg(version ORDER BY version) FROM public." + identifier(MIGRATION_TABLE)
                            + ") = " + expected_migrations, "Diesel migration history differs")
    statements += assertion("(" + SCHEMA_SQL.removesuffix(";") + ")::jsonb = "
                            + literal(json.dumps(manifest["schema"], sort_keys=True)) + "::jsonb", "Schema changed")
    return statements + "END $hadal_verify$;\n"


def guard_sql(manifest):
    tables = sorted(list(manifest["snapshots"]) + [MIGRATION_TABLE])
    sql = PG_SETTINGS + "SET lock_timeout TO '5s'; SET statement_timeout TO '120s';\n"
    sql += "SELECT pg_advisory_xact_lock(1751213141, 1448552265);\n"
    sql += "LOCK TABLE " + ",".join("public." + identifier(t) for t in tables) + " IN ACCESS EXCLUSIVE MODE;\n"
    sql += "DO $hadal_identity$ BEGIN\n"
    sql += assertion("current_user = 'vaultwarden' AND current_database() = 'vaultwarden' "
                     "AND inet_server_addr() = " + literal(DB_ADDRESS) + "::inet AND inet_server_port() = 5432",
                     "Unexpected database identity")
    sql += assertion("NOT EXISTS (SELECT FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace "
                     "WHERE n.nspname='public' AND pg_get_userbyid(c.relowner) <> 'vaultwarden')", "Unexpected object ownership")
    return sql + "END $hadal_identity$;\n" + verification_sql(manifest, empty=True)


def validate_identity(identity):
    checks = {"role": identity.get("role") == "vaultwarden",
              "database": identity.get("database") == "vaultwarden",
              "address": identity.get("address") == DB_ADDRESS,
              "port": type(identity.get("port")) is int and identity["port"] == 5432,
              "version": type(identity.get("version")) is int and 170000 <= identity["version"] < 180000}
    failed = [name for name, passed in checks.items() if not passed]
    require(not failed, "Unexpected PostgreSQL target/version; failed checks: " + ", ".join(failed))


def import_live(args):
    directory, manifest, source = read_artifact(args.artifact_dir)
    require(1 <= args.pg_port <= 65535, "Invalid tunnel port")
    receipt_path = directory / "live-attempt.json"
    receipt = {"run_id": manifest["run_id"], "attempt_id": uuid.uuid4().hex,
               "database": "vaultwarden", "server": DB_ADDRESS, "state": "preparing",
               "credentials_revoked": False}
    receipt_owned = False
    # Credentials are never kept in the persistent artifact directory.
    with tempfile.TemporaryDirectory(prefix="hadal-vw-live-") as temporary:
        work = Path(temporary)
        runner = Runner(work)
        runner.versions()
        archive_entries(runner, directory / "data.dump", source.tables, manifest["sequences"])
        remote = support.Remote(args)
        check_cluster(remote)
        ca = remote.execute(["sudo", "-n", "cat", "/run/hadal-bootstrap/ca.crt"])
        bao = support.Bao(args.bao_addr, ca, "openbao.infra.windows.moe", "")
        health = bao.request("GET", "sys/health")
        require(health.get("cluster_id") == CLUSTER and health.get("sealed") is False, "Unexpected OpenBao cluster/state")
        bao.token = getpass.getpass("OpenBao administrator/operator token: ")
        require(bao.token, "Empty operator token")
        accessor = None
        try:
            child = bao.request("POST", "auth/token/create", {"policies": ["vaultwarden"], "no_default_policy": True,
                "ttl": "15m", "explicit_max_ttl": "15m", "renewable": False, "type": "service",
                "display_name": "hadal-vw-import-" + manifest["run_id"][:12]})["auth"]
            accessor = child["accessor"]
            require(accessor and child["client_token"] and 0 < child["lease_duration"] <= 900, "Unexpected migration token")
            credential = bao.request("GET", "database/creds/vaultwarden", token=child["client_token"])["data"]
            username, password = credential["username"], credential["password"]
            require(re.fullmatch(r"[A-Za-z0-9_-]+", username) and re.fullmatch(r"[A-Za-z0-9]{48}", password), "Unexpected migration credential format")
            ca_path, pass_path = work / "ca.crt", work / "pgpass"
            write_private(ca_path, ca)
            write_private(pass_path, f"postgres.infra.windows.moe:{args.pg_port}:vaultwarden:{username}:{password}\n")
            credential = password = None
            pg = Pg(runner, "host=postgres.infra.windows.moe hostaddr=::1 " + f"port={args.pg_port} dbname=vaultwarden user={username} "
                    + "sslmode=verify-full connect_timeout=5 sslrootcert=" + conn_quote(ca_path) + " passfile=" + conn_quote(pass_path))
            identity = pg.json(IDENTITY_SQL)
            validate_identity(identity)
            require(pg.migrations() == REFERENCE["postgresql"] and pg.schema() == manifest["schema"], "Live schema differs from rehearsal")
            require(pg.tables() == source.tables, "Live application table set differs")
            for table in source.tables:
                require(pg.text("SELECT count(*) FROM public." + identifier(table)) == "0", "Live destination already contains application data")
            print("Target: PostgreSQL " + DB_ADDRESS + ":5432/vaultwarden; Flux apps suspended", flush=True)
            print(f"Rehearsed import: {len(source.tables)} tables, {sum(source.counts.values())} rows", flush=True)
            phrase = "IMPORT vaultwarden " + manifest["run_id"]
            print("Type exactly: " + phrase, flush=True)
            with open("/dev/tty", "r") as terminal:
                require(terminal.readline().strip() == phrase, "Import cancelled; no data restored")
            check_cluster(remote)
            source.unchanged()
            require(digest(directory / "data.dump") == manifest["archive_sha256"], "Archive changed before import")
            archive_copy = work / "data.dump"
            with (directory / "data.dump").open("rb") as incoming:
                with os.fdopen(os.open(archive_copy, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as outgoing:
                    shutil.copyfileobj(incoming, outgoing)
            require(digest(archive_copy) == manifest["archive_sha256"], "Archive copy changed before import")
            restore_sql = work / "restore.sql"
            runner.run([runner.tool("pg_restore"), "--no-owner", "--no-privileges", "--file", str(restore_sql),
                        str(archive_copy)], timeout=60)
            os.chmod(restore_sql, 0o600)
            before, after = work / "before.sql", work / "after.sql"
            write_private(before, guard_sql(manifest))
            write_private(after, verification_sql(manifest))
            # Exclusive creation prevents two invocations from restoring the same artifact.
            write_private(receipt_path, json.dumps(receipt) + "\n")
            receipt_owned = True
            receipt["state"] = "transaction-starting"
            save_json(receipt_path, receipt)
            runner.run([runner.tool("psql"), "-X", "-w", "-q", "--single-transaction", "--set=ON_ERROR_STOP=1",
                        "--dbname", pg.connection, "--file", str(before), "--file", str(restore_sql), "--file", str(after)],
                       timeout=240, output=work / "restore-console.log")
            receipt["state"] = "commit-acknowledged"
            save_json(receipt_path, receipt)
            print("PASS: data restored and verified inside one transaction; commit acknowledged", flush=True)
            require(pg.schema() == manifest["schema"] and pg.migrations() == REFERENCE["postgresql"], "Post-commit schema verification failed")
            for table in source.tables:
                require(pg.snapshot(table, [c["name"] for c in manifest["columns"][table]]) == manifest["snapshots"][table], "Post-commit data verification failed")
            receipt["state"] = "verified"
            save_json(receipt_path, receipt)
            print("PASS: all table fingerprints verified after commit", flush=True)
        finally:
            try:
                if accessor:
                    bao.request("POST", "auth/token/revoke-accessor", {"accessor": accessor})
                    print("PASS: only the migration token and its leases revoked", flush=True)
                    if receipt_owned:
                        receipt["credentials_revoked"] = True
                        save_json(receipt_path, receipt)
            finally:
                bao.token = ""
                # Retain diagnostics, never passfiles, tokens, CA copies or restore SQL.
                # Database errors may contain vault values: keep these logs private.
                logs = directory / ("live-logs-" + receipt["attempt_id"])
                logs.mkdir(mode=0o700)
                for name in ("commands.log", "restore-console.log"):
                    path = work / name
                    if path.exists():
                        write_private(logs / name, path.read_bytes())
    print("PASS: database import complete; apps remain suspended; filesystem data not copied")
    print("Live receipt: " + str(receipt_path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inspect = commands.add_parser("inspect", help="Read-only inspection of a recovered standalone SQLite file")
    inspect.add_argument("--sqlite", required=True)
    rehearsal = commands.add_parser("rehearse", help="Convert only in private local PostgreSQL databases; no production connections")
    rehearsal.add_argument("--sqlite", required=True)
    rehearsal.add_argument("--vaultwarden-bin", default="result-vaultwarden-pg-migration/bin/vaultwarden")
    rehearsal.add_argument("--work-parent")
    live = commands.add_parser("import-live", help="Explicitly confirmed, guarded live data-only restore; never resume apps")
    live.add_argument("--artifact-dir", required=True)
    live.add_argument("--host", default="workspace@172.16.0.241")
    live.add_argument("--identity", default="~/.ssh/id_ed25519_personal")
    live.add_argument("--rke2-address", default="fd2d:b57c:c77b:9::20")
    live.add_argument("--bao-addr", default="https://[::1]:18200")
    live.add_argument("--pg-port", type=int, default=15432)
    args = parser.parse_args()
    require(os.getuid() != 0, "Run on the workstation as your normal user, not root")
    os.umask(0o077)
    if args.command == "inspect":
        source = Source(args.sqlite)
        print(f"PASS: standalone source; {len(source.tables)} tables, {sum(source.counts.values())} rows; release migration IDs match")
        print("Source SHA256: " + source.sha)
    elif args.command == "rehearse":
        rehearse(args)
    else:
        import_live(args)


if __name__ == "__main__":
    def terminated(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, terminated)
    try:
        main()
    except (Failure, OSError, sqlite3.Error) as error:
        print(f"STOP: {error}", file=sys.stderr)
        if len(sys.argv) > 1 and sys.argv[1] in ("inspect", "rehearse"):
            print("Local-only command; no production connection was made. Keep apps suspended. Failed rehearsals cannot be imported.", file=sys.stderr)
        else:
            print("Keep apps suspended. Do not retry a live attempt blindly; inspect its receipt. No automatic database reset.", file=sys.stderr)
        sys.exit(1)
    except (ValueError, TypeError, KeyError):
        print("STOP: invalid metadata or artifact; raw values suppressed. Keep apps suspended.", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("STOP: interrupted; check local process receipts and any live-attempt receipt before retrying", file=sys.stderr)
        sys.exit(130)
