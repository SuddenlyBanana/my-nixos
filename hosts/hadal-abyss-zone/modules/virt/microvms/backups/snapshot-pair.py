"""Stream a matched online PostgreSQL/files snapshot set to encrypted Restic.

Only this run's verified LVM snapshots are removed. Never mounts guest volumes
on the host, stops Vaultwarden, or changes Flux replica counts.
"""

import datetime
import fcntl
import json
import os
from pathlib import Path
import socket
import subprocess
import uuid


def command(*arguments, **kwargs):
    return subprocess.run(arguments, check=True, text=True, capture_output=True, **kwargs).stdout


def rpc(vm, operation, run):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(150)
        client.connect(f"/var/lib/microvms/{vm}/notify.vsock")
        client.sendall(b"CONNECT 9100\n")
        with client.makefile("rb") as stream:
            if not stream.readline(256).startswith(b"OK "):
                raise RuntimeError(f"VSOCK connection to {vm} rejected")
            client.sendall(json.dumps({"command": operation, "run": run}).encode() + b"\n")
            response = json.loads(stream.readline(65536))
    if not response.get("ok"):
        raise RuntimeError(f"{vm} snapshot operation {operation} failed")
    return response["data"]


def lv_info(path):
    report = json.loads(command("lvs", "--reportformat", "json", "-o", "lv_uuid,origin", path))
    return report["report"][0]["lv"][0]


def restic_snapshot(run, *arguments):
    output = command("restic", "backup", "--json", "--tag", run, *arguments)
    summaries = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
    return next(item["snapshot_id"] for item in summaries if item.get("message_type") == "summary")


def backup():
    command(os.environ["CHECK_BACKUP_MOUNT"])
    os.environ["RESTIC_PASSWORD_FILE"] = str(Path(os.environ["CREDENTIALS_DIRECTORY"]) / "restic-password")
    run = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M%S") + "-" + uuid.uuid4().hex[:8]
    directory = Path(os.environ["RUNTIME_DIRECTORY"]) / run
    directory.mkdir(mode=0o700)
    snapshots = []
    active = []
    try:
        for vm in ("postgresql", "rke2"):
            rpc(vm, "begin", run)
            active.append(vm)
        # Freeze file storage before database storage, then hold both frozen
        # during both lvcreate calls. This is NOT a distributed transaction.
        for vm in ("rke2", "postgresql"):
            rpc(vm, "freeze", run)
        for origin, short in (("postgresql-data", "pg"), ("vaultwarden-data", "files")):
            name = f"backup-{short}-{run}"
            path = f"/dev/hadal-vm/{name}"
            command("lvcreate", "--snapshot", "--permission", "r", "--name", name, f"hadal-vm/{origin}")
            info = lv_info(path)
            if info["origin"].strip() != origin:
                raise RuntimeError("Unexpected snapshot origin")
            snapshots.append((path, info["lv_uuid"].strip(), origin, short))
        for vm in ("postgresql", "rke2"):
            if not rpc(vm, "status", run)["frozen"]:
                raise RuntimeError("Snapshot watchdog thawed before capture completed")
        for vm in ("postgresql", "rke2"):
            rpc(vm, "thaw", run)
        pg_metadata = rpc("postgresql", "finish", run)
        active.remove("postgresql")
        rpc("rke2", "finish", run)
        active.remove("rke2")
        manifest = {
            "id": run, "consistency": "coordinated-filesystem-snapshots",
            "application_consistency": "requires Vaultwarden recovery validation; not a cross-store transaction",
            "postgresql": pg_metadata, "images": {},
        }
        for path, _, _, short in snapshots:
            manifest["images"][short] = restic_snapshot(
                run, f"--stdin-filename={short}.partclone", "--stdin-from-command", "--",
                "partclone.xfs", "--clone", "--source", path, "--output", "-"
            )
        # A set is restorable only when this final completion manifest exists;
        # interrupted streams have no completed matched-set marker.
        (directory / "complete.json").write_text(json.dumps(manifest, indent=2) + "\n")
        restic_snapshot(run, str(directory))
    finally:
        for vm in reversed(active):
            try:
                rpc(vm, "abort", run)
            except Exception:
                print(f"WARNING: {vm} cleanup failed; the guest watchdog must thaw it", flush=True)
        for path, expected_uuid, origin, _ in snapshots:
            info = lv_info(path)
            if info["lv_uuid"].strip() != expected_uuid or info["origin"].strip() != origin:
                raise RuntimeError(f"Refusing to remove an unrecognized snapshot: {path}")
            command("lvremove", "--yes", path)


if __name__ == "__main__":
    os.umask(0o077)
    with open("/run/lock/hadal-online-backup.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        backup()
