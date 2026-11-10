#!/usr/bin/env python3
"""Preview by default; --run explicitly confirms copying attachments and RSA key.

Run on the workstation after a verified database import. Never resets a DB,
resumes apps, edits the backup, copies SQLite/config/admin.env, or overwrites a PV.
No OpenBao token or tunnels needed. Private archives contain the RSA private key.
"""

import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import signal
import subprocess
import sys
import tarfile
import tempfile
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('vw_migration', HERE / 'migrate-vaultwarden.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
Failure, require = m.Failure, m.require
MAX_ARCHIVE = 64 * 1024 * 1024
SCRIPT = (HERE / 'vaultwarden-files-remote.sh').read_text()


def ssh_environment(directory):
    env = m.clean_env(directory)
    # BatchMode cannot unlock an encrypted private key interactively. Match
    # the existing connection checks by allowing the workstation's agent to
    # authenticate the explicitly selected identity. This does NOT forward the
    # agent: SSH uses ForwardAgent=no and never exposes its socket to a guest.
    if os.environ.get('SSH_AUTH_SOCK'):
        env['SSH_AUTH_SOCK'] = os.environ['SSH_AUTH_SOCK']
    return env


def private_work_directory(artifact):
    # nix develop can point TMPDIR at a directory removed when its shell exits.
    # Keep recovery archives/logs alongside the verified, owner-only artifact.
    return Path(tempfile.mkdtemp(prefix='files-work-', dir=artifact))


def completed_import(directory):
    directory = m.private(directory, directory=True)
    manifest = json.loads(m.private(directory / 'manifest.json').read_text())
    receipt = json.loads(m.private(directory / 'live-attempt.json').read_text())
    require(manifest['format'] == 1 and manifest['status'] == 'ready' and manifest['release'] == m.RELEASE,
            'Unexpected rehearsal manifest')
    require(re.fullmatch(r'[a-f0-9]{32}', manifest['run_id']), 'Invalid rehearsal identity')
    require(receipt['run_id'] == manifest['run_id'] and receipt['state'] == 'verified'
            and receipt['credentials_revoked'] is True and receipt['database'] == 'vaultwarden'
            and receipt['server'] == m.DB_ADDRESS, 'Database import must be verified with credentials revoked')
    require(not os.path.lexists(directory / 'files-attempt.json'),
            'A filesystem copy attempt already exists; inspect its receipt and PV before doing anything else')
    source = m.Source(directory / 'source.sqlite3')
    require(source.sha == manifest['source_sha256'], 'Rehearsal SQLite copy changed')
    with source.connect() as db:
        require(db.execute('SELECT count(*) FROM sends').fetchone()[0] == 0,
                'Existing Sends need a separate filesystem migration review')
        records = db.execute('SELECT cipher_uuid,id FROM attachments').fetchall()
    expected = set()
    for cipher, attachment in records:
        require(re.fullmatch(r'[a-fA-F0-9-]{36}', cipher)
                and re.fullmatch(r'[A-Za-z0-9_-]+', attachment), 'Unexpected attachment path format')
        path = f'attachments/{cipher}/{attachment}'
        require(path not in expected, 'Duplicate attachment path')
        expected.add(path)
    return directory, manifest['run_id'], source, expected


def inventory(path, expected):
    require(path.stat().st_size <= MAX_ARCHIVE, 'Backup archive exceeds 64 MiB safety limit')
    files, directories, seen, total = {}, set(), set(), 0
    with tarfile.open(path, 'r:') as archive:
        for member in archive:
            name = member.name.rstrip('/') if member.isdir() else member.name
            pure = PurePosixPath(name)
            require(name and not pure.is_absolute() and '..' not in pure.parts and str(pure) == name,
                    'Unsafe archive member path; values suppressed')
            require(name not in seen, 'Duplicate archive member')
            seen.add(name)
            require(len(seen) <= 10_000, 'Archive has too many members')
            require(member.isfile() or member.isdir(), 'Links or special archive members are forbidden')
            require(member.sparse is None, 'Sparse archive members are forbidden')
            if member.isdir():
                require(name == 'attachments' or (len(pure.parts) == 2 and pure.parts[0] == 'attachments'
                        and re.fullmatch(r'[a-fA-F0-9-]{36}', pure.parts[1])), 'Unexpected attachment directory')
                directories.add(name)
            else:
                require(name == 'rsa_key.pem' or name in expected, 'Unexpected/unreferenced backup file; values suppressed')
                require(0 <= member.size <= MAX_ARCHIVE, 'Invalid archive member size')
                total += member.size
                require(total <= MAX_ARCHIVE, 'Unpacked files exceed safety limit')
                stream = archive.extractfile(member)
                require(stream is not None, 'Unreadable archive member')
                with stream:
                    files[name] = stream.read()
    require(set(files) == expected | {'rsa_key.pem'} and 'attachments' in directories,
            'Backup file set does not match the imported attachment records')
    require(sum(map(len, files.values())) <= MAX_ARCHIVE, 'Unpacked files exceed safety limit')
    return files, directories


def sanitize(path, files, directories):
    hashes = {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
    checksums = ''.join(f'{hashes[name]}  {name}\n' for name in sorted(hashes)).encode()
    # Do not extract an untrusted tar. Rebuild every allowed member with fixed
    # type, permissions, UID/GID and no links, xattrs, absolute paths or devices.
    with path.open('xb') as stream:
        os.chmod(path, 0o600)
        with tarfile.open(fileobj=stream, mode='w', format=tarfile.USTAR_FORMAT) as archive:
            for name in sorted(directories):
                entry = tarfile.TarInfo(name)
                entry.type, entry.mode = tarfile.DIRTYPE, 0o700
                entry.uid = entry.gid = 1000
                archive.addfile(entry)
            for name, data in sorted(dict(files, **{'.hadal-checksums': checksums}).items()):
                entry = tarfile.TarInfo(name)
                entry.size, entry.mode, entry.uid, entry.gid = len(data), 0o600, 1000, 1000
                archive.addfile(entry, io.BytesIO(data))
        stream.flush()
        os.fsync(stream.fileno())
    require(path.stat().st_size <= MAX_ARCHIVE, 'Sanitized archive exceeds safety limit')
    return m.digest(path)


def ssh_run(command, env, directory, *, input_file=None, output_file=None):
    try:
        with (open(input_file, 'rb') if input_file else open(os.devnull, 'rb')) as incoming:
            if output_file:
                outgoing = os.fdopen(os.open(output_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb')
            else:
                outgoing = subprocess.PIPE
            try:
                result = subprocess.run(command, env=env, stdin=incoming, stdout=outgoing,
                                        stderr=subprocess.PIPE, timeout=180, umask=0o077)
            finally:
                if output_file:
                    outgoing.close()
    except subprocess.TimeoutExpired:
        raise Failure('SSH copy timed out; inspect any files-attempt receipt/stage before retrying') from None
    if result.stderr:
        name = directory / ('ssh-' + uuid.uuid4().hex + '.log')
        m.write_private(name, result.stderr)
    require(result.returncode == 0, 'SSH operation failed; private diagnostic logs retained; raw output suppressed')
    if output_file:
        require(Path(output_file).stat().st_size <= MAX_ARCHIVE, 'Source archive exceeds safety limit')
    return result.stdout.decode() if not output_file else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact-dir', required=True)
    parser.add_argument('--run', action='store_true', help='Explicitly confirmed live filesystem copy; no app start')
    parser.add_argument('--host', default='workspace@172.16.0.241')
    parser.add_argument('--identity', default='~/.ssh/id_ed25519_personal')
    parser.add_argument('--rke2-address', default='fd2d:b57c:c77b:9::20')
    args = parser.parse_args()
    require(os.getuid() != 0, 'Run as your normal workstation user, not root')
    os.umask(0o077)
    directory, run_id, source, expected = completed_import(args.artifact_dir)
    work = private_work_directory(directory)
    print('Private filesystem-copy directory: ' + str(work), flush=True)
    env = m.clean_env(work)
    ssh_env = ssh_environment(work)
    remote = m.support.Remote(args)
    remote.command[1:1] = ['-o', 'ForwardAgent=no']
    m.check_cluster(remote)
    require(remote.execute(['sudo', '-n', 'bash', '-c', SCRIPT, 'vw-files', 'preview']).strip()
            == 'PV_EMPTY vault-data xfs', 'PV preflight failed')
    identity = str(Path(args.identity).expanduser().resolve())
    host_command = ['ssh', '-F', '/dev/null', '-i', identity, '-o', 'IdentitiesOnly=yes',
                    '-o', 'ForwardAgent=no', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=10',
                    '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=2', args.host,
                    shlex.join(['sudo', '-n', 'bash', '-c', SCRIPT, 'vw-files', 'source'])]
    backup = work / 'backup.tar'
    ssh_run(host_command, ssh_env, work, output_file=backup)
    files, directories = inventory(backup, expected)
    # Validate without printing/storing a second plaintext private key.
    runner = m.Runner(work)
    result = subprocess.run([runner.tool('openssl'), 'rsa', '-check', '-noout', '-passin', 'pass:'],
                            input=files['rsa_key.pem'], env=env, capture_output=True, timeout=10)
    require(result.returncode == 0, 'RSA private-key validation failed; output suppressed')
    payload = work / 'payload.tar'
    payload_sha = sanitize(payload, files, directories)
    files = None
    print(f'PASS: {len(expected)} attachment files match imported records; private key validates', flush=True)
    print('PASS: destination is empty, mounted XFS label vault-data; apps suspended', flush=True)
    print('Copy scope: attachments/ and rsa_key.pem; destination UID:GID 1000:1000', flush=True)
    if not args.run:
        print('PREVIEW ONLY: no guest files written. Add --run to request the guarded copy.')
        return
    nonce = uuid.uuid4().hex
    phrase = 'COPY vaultwarden files ' + nonce
    print('Type exactly: ' + phrase, flush=True)
    with open('/dev/tty') as terminal:
        require(terminal.readline().strip() == phrase, 'Filesystem copy cancelled; no guest files written')
    m.check_cluster(remote)
    require(remote.execute(['sudo', '-n', 'bash', '-c', SCRIPT, 'vw-files', 'preview']).strip()
            == 'PV_EMPTY vault-data xfs', 'Destination changed before copy')
    source.unchanged()
    again = work / 'backup-recheck.tar'
    ssh_run(host_command, ssh_env, work, output_file=again)
    require(m.digest(again) == m.digest(backup), 'Backup changed between reads; no copy attempted')
    require(m.digest(payload) == payload_sha, 'Sanitized archive changed before transfer')
    receipt = {'database_run_id': run_id, 'attempt_id': nonce, 'state': 'copy-starting',
               'archive_sha256': payload_sha, 'attachments': len(expected),
               'target': '/var/lib/hadal-pv/vaultwarden', 'private_work_dir': str(work)}
    receipt_path = directory / 'files-attempt.json'
    m.write_private(receipt_path, json.dumps(receipt, indent=2) + '\n')
    command = remote.command + [shlex.join(['sudo', '-n', 'bash', '-c', SCRIPT, 'vw-files',
                                           'copy', nonce, payload_sha, str(len(expected) + 1)])]
    output = ssh_run(command, ssh_env, work, input_file=payload)
    require(output.strip() == 'PASS_FILES ' + payload_sha, 'Copy acknowledgment missing; inspect receipt, do not retry')
    receipt['state'] = 'copy-acknowledged'
    m.save_json(receipt_path, receipt)
    m.check_cluster(remote)
    receipt['state'] = 'verified'
    m.save_json(receipt_path, receipt)
    print('PASS: attachment/key checksums verified after publication; ownership 1000:1000', flush=True)
    print('PASS: SQLite, admin.env, config, caches and tmp not copied; original backup not changed')
    print('PASS: owned guest staging copies removed after verification; source and final files retained')
    print('PASS: filesystem migration complete; apps remain suspended')
    print('Filesystem receipt: ' + str(receipt_path))
    print('Private local archives retained at: ' + str(work))


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        main()
    except Failure as error:
        print('STOP: ' + str(error), file=sys.stderr)
        print('Keep apps suspended. Inspect any files-attempt.json and retained stage/logs; no automatic rollback, reset or retry.', file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, TypeError, KeyError, tarfile.TarError, subprocess.SubprocessError):
        # Do not stringify archive exceptions: they can contain sensitive names.
        print('STOP: filesystem preflight/copy failed; raw details suppressed. Keep apps suspended.', file=sys.stderr)
        print('Inspect any files-attempt.json and retained stage/logs; no automatic rollback, reset or retry.', file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print('STOP: interrupted; keep apps suspended and inspect any filesystem attempt receipt before retrying.', file=sys.stderr)
        sys.exit(130)
