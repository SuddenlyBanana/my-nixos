"""Host-only VSOCK control for bounded online filesystem snapshots.

This provides filesystem/crash consistency, not a cross-store application
transaction. A PostgreSQL backup session is held until the host finishes.
"""

import json
import os
import pwd
import re
import socket
import subprocess
import time

import psycopg


class Agent:
    def __init__(self, mount, postgres=False):
        self.mount = mount
        self.postgres = postgres
        self.run = None
        self.frozen = False
        self.deadline = 0
        self.connection = None

    def thaw(self):
        if self.frozen:
            subprocess.run(["fsfreeze", "--unfreeze", self.mount], check=True, timeout=15)
            self.frozen = False

    def abort(self):
        # Leave the watchdog armed if thaw fails; the caller retries, and
        # systemd's ExecStopPost also thaws after unexpected process exit.
        self.thaw()
        if self.connection:
            self.connection.close()
            self.connection = None
        self.run = None

    def expire(self):
        if self.run and time.monotonic() >= self.deadline:
            self.abort()

    def dispatch(self, request):
        self.expire()
        run = request.get("run", "")
        if not re.fullmatch(r"[0-9]{14}-[0-9a-f]{8}", run):
            raise ValueError("Invalid backup identifier")
        command = request.get("command")
        if command == "begin":
            if self.run:
                raise ValueError("A backup is already in progress")
            if self.postgres:
                # Unix peer authentication, no database password or network
                # management role. Only the connection is opened as postgres.
                original_uid = os.geteuid()
                try:
                    os.seteuid(pwd.getpwnam("postgres").pw_uid)
                    self.connection = psycopg.connect(
                        "dbname=postgres user=postgres host=/run/postgresql "
                        "options='-c statement_timeout=120000'", autocommit=True
                    )
                finally:
                    os.seteuid(original_uid)
                try:
                    self.connection.execute("SELECT pg_backup_start(%s, true)", (run,)).fetchone()
                except Exception:
                    self.connection.close()
                    self.connection = None
                    raise
            self.run = run
            self.deadline = time.monotonic() + 60
        elif run != self.run:
            raise ValueError("No matching active backup")
        elif command == "freeze":
            # Mark first: even a timed-out freeze must be followed by thaw.
            self.frozen = True
            subprocess.run(["fsfreeze", "--freeze", self.mount], check=True, timeout=15)
            self.deadline = min(self.deadline, time.monotonic() + 30)
        elif command == "thaw":
            self.thaw()
        elif command == "status":
            pass
        elif command == "finish":
            self.thaw()
            metadata = {}
            if self.connection:
                lsn, label, tablespaces = self.connection.execute(
                    "SELECT lsn::text, labelfile, spcmapfile FROM pg_backup_stop(true)"
                ).fetchone()
                metadata = {"stop_lsn": lsn, "backup_label": label, "tablespace_map": tablespaces}
            self.abort()
            return metadata
        elif command == "abort":
            self.abort()
        else:
            raise ValueError("Unknown command")
        return {"run": self.run, "frozen": self.frozen}


def serve():
    if int(os.environ.get("LISTEN_FDS", "0")) != 1:
        raise RuntimeError("Start through the systemd VSOCK socket")
    agent = Agent(os.environ["SNAPSHOT_MOUNT"], os.environ.get("SNAPSHOT_POSTGRES") == "1")
    listener = socket.socket(fileno=3)
    listener.settimeout(1)
    try:
        while True:
            try:
                agent.expire()
                client, _ = listener.accept()
            except socket.timeout:
                continue
            with client:
                client.settimeout(5)
                try:
                    with client.makefile("rb") as stream:
                        request = json.loads(stream.readline(4096))
                    result = {"ok": True, "data": agent.dispatch(request)}
                except Exception as error:
                    # No token, SQL dump, or raw database contents in errors.
                    result = {"ok": False, "error": type(error).__name__}
                client.sendall(json.dumps(result).encode() + b"\n")
    finally:
        agent.abort()


if __name__ == "__main__":
    serve()
