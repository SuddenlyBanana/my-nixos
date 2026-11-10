#!/usr/bin/env python3
"""Synthetic local files only; no SSH/network, real vault data or guest PV writes."""

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('copy_files', HERE / 'copy-vaultwarden-files.py')
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)
CIPHER = '00000000-0000-0000-0000-000000000001'
ATTACHMENT = f'attachments/{CIPHER}/a1234'


class Files(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vw-files-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.files = {ATTACHMENT: b'synthetic attachment\0\xff\n', 'rsa_key.pem': b'synthetic private key fixture'}
        self.dirs = {'attachments', 'attachments/' + CIPHER}

    def archive(self, members=None):
        path = self.root / ('source-' + str(len(list(self.root.iterdir()))) + '.tar')
        with tarfile.open(path, 'w', format=tarfile.USTAR_FORMAT) as tar:
            if members is None:
                members = []
                for name in sorted(self.dirs):
                    entry = tarfile.TarInfo(name)
                    entry.type = tarfile.DIRTYPE
                    members.append((entry, None))
                for name, data in self.files.items():
                    entry = tarfile.TarInfo(name)
                    entry.size = len(data)
                    members.append((entry, io.BytesIO(data)))
            for entry, stream in members:
                tar.addfile(entry, stream)
        return path

    def test_inventory_and_sanitization(self):
        data, dirs = c.inventory(self.archive(), {ATTACHMENT})
        self.assertEqual(data, self.files)
        self.assertEqual(dirs, self.dirs)
        destination = self.root / 'payload.tar'
        digest = c.sanitize(destination, data, dirs)
        self.assertEqual(digest, hashlib.sha256(destination.read_bytes()).hexdigest())
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        with tarfile.open(destination) as tar:
            self.assertEqual(set(tar.getnames()), self.dirs | set(self.files) | {'.hadal-checksums'})
            for member in tar:
                self.assertEqual((member.uid, member.gid), (1000, 1000))
                self.assertEqual(member.mode, 0o700 if member.isdir() else 0o600)
            with tar.extractfile('.hadal-checksums') as stream:
                checksums = stream.read().decode()
            self.assertIn(hashlib.sha256(self.files[ATTACHMENT]).hexdigest(), checksums)

    def test_reject_traversal_links_and_special_members(self):
        for name, kind in (('/absolute', tarfile.REGTYPE), ('../parent', tarfile.REGTYPE),
                           ('attachments/../rsa_key.pem', tarfile.REGTYPE), ('attachments//double', tarfile.REGTYPE),
                           ('rsa_key.pem', tarfile.SYMTYPE), ('rsa_key.pem', tarfile.LNKTYPE),
                           ('rsa_key.pem', tarfile.FIFOTYPE), ('admin.env', tarfile.REGTYPE)):
            member = tarfile.TarInfo(name)
            member.type = kind
            with self.subTest(name=name, kind=kind), self.assertRaises(c.Failure):
                c.inventory(self.archive([(member, None)]), {ATTACHMENT})

    def test_missing_or_unreferenced_attachment_fails(self):
        path = self.archive()
        with self.assertRaises(c.Failure):
            c.inventory(path, set())
        with self.assertRaises(c.Failure):
            c.inventory(path, {ATTACHMENT, f'attachments/{CIPHER}/missing'})

    def test_duplicate_members_fail(self):
        entry = tarfile.TarInfo('rsa_key.pem')
        with self.assertRaises(c.Failure):
            c.inventory(self.archive([(entry, None), (entry, None)]), set())

    def test_completed_database_receipt_and_source(self):
        source = self.root / 'source.sqlite3'
        with contextlib.closing(sqlite3.connect(source)) as db, db:
            db.execute('CREATE TABLE __diesel_schema_migrations(version text)')
            db.executemany('INSERT INTO __diesel_schema_migrations VALUES (?)', [(v,) for v in c.m.REFERENCE['sqlite']])
            db.execute('CREATE TABLE attachments(cipher_uuid text,id text)')
            db.execute('INSERT INTO attachments VALUES (?,?)', (CIPHER, 'a1234'))
            db.execute('CREATE TABLE sends(uuid text)')
        source.chmod(0o600)
        manifest = {'format': 1, 'status': 'ready', 'release': c.m.RELEASE, 'run_id': 'a' * 32,
                    'source_sha256': c.m.digest(source)}
        receipt = {'run_id': 'a' * 32, 'state': 'verified', 'credentials_revoked': True,
                   'database': 'vaultwarden', 'server': c.m.DB_ADDRESS}
        c.m.save_json(self.root / 'manifest.json', manifest)
        c.m.save_json(self.root / 'live-attempt.json', receipt)
        self.assertEqual(c.completed_import(self.root)[3], {ATTACHMENT})
        receipt['state'] = 'transaction-starting'
        c.m.save_json(self.root / 'live-attempt.json', receipt)
        with self.assertRaises(c.Failure):
            c.completed_import(self.root)
        receipt['state'] = 'verified'
        c.m.save_json(self.root / 'live-attempt.json', receipt)
        c.m.write_private(self.root / 'files-attempt.json', '{}')
        with self.assertRaises(c.Failure):
            c.completed_import(self.root)

    def test_ssh_no_token_in_environment_and_no_raw_error(self):
        with patch.dict(os.environ, {'BAO_TOKEN': 'operator-secret', 'VAULT_TOKEN': 'operator-secret',
                                     'SSH_AUTH_SOCK': '/synthetic/local-agent'}):
            env = c.ssh_environment(self.root)
            self.assertNotIn('SSH_AUTH_SOCK', c.m.clean_env(self.root))
        self.assertEqual(env['SSH_AUTH_SOCK'], '/synthetic/local-agent')
        with patch.object(c.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, b'', b'private details')) as run:
            with self.assertRaises(c.Failure) as caught:
                c.ssh_run(['ssh', 'synthetic'], env, self.root)
        self.assertNotIn('private details', str(caught.exception))
        self.assertNotIn('BAO_TOKEN', run.call_args.kwargs['env'])
        self.assertNotIn('VAULT_TOKEN', run.call_args.kwargs['env'])

    def test_agent_socket_is_optional(self):
        with patch.dict(os.environ, {}, clear=True):
            self.assertNotIn('SSH_AUTH_SOCK', c.ssh_environment(self.root))

    def test_work_survives_nix_shell_tmpdir_cleanup(self):
        with patch.dict(os.environ, {'TMPDIR': str(self.root / 'ephemeral-nix-shell')}):
            directory = c.private_work_directory(self.root)
        self.assertEqual(directory.parent, self.root)
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)

    def test_forwarding_is_explicitly_disabled(self):
        # Both new SSH subprocess paths use the local-only agent environment;
        # do not regress to the clean non-SSH environment or add ssh -A.
        code = (HERE / 'copy-vaultwarden-files.py').read_text()
        self.assertIn("remote.command[1:1] = ['-o', 'ForwardAgent=no']", code)
        self.assertIn("'-o', 'ForwardAgent=no', '-o', 'BatchMode=yes'", code)
        self.assertIn('ssh_run(host_command, ssh_env, work, output_file=backup)', code)
        self.assertIn('ssh_run(command, ssh_env, work, input_file=payload)', code)


class RemoteShell(unittest.TestCase):
    def setUp(self):
        Files.setUp(self)
        self.pv, self.backup, self.bin = self.root / 'pv', self.root / 'backup', self.root / 'bin'
        for path in (self.pv, self.backup, self.bin):
            path.mkdir(mode=0o700)
        self.script = c.SCRIPT.replace('pv=/var/lib/hadal-pv/vaultwarden', 'pv=' + str(self.pv))
        self.script = self.script.replace('backup=/srv/mediabackup/vaultwarden', 'backup=' + str(self.backup))
        self.script = self.script.replace('/run/lock/hadal-vaultwarden-files.lock', str(self.root / 'lock'))
        self.script = self.script.replace('! -uid 1000', '! -uid ' + str(os.getuid()))
        self.script = self.script.replace('! -gid 1000', '! -gid ' + str(os.getgid()))
        wrappers = {
            'hostname': '#!/bin/sh\nprintf "%s\\n" "${VW_HOST:-rke2-server}"\n',
            'findmnt': '#!/bin/sh\ncase "$5" in TARGET) printf "%s\\n" "$VW_PV";; FSTYPE) echo xfs;; LABEL) echo "${VW_LABEL:-vault-data}";; OPTIONS) echo rw,relatime;; *) exit 1;; esac\n',
            'chown': '#!/bin/sh\nexit 0\n',
            'mv': '#!/bin/sh\nfor item do last=$item; done\n'
                  'if [ "${VW_FAIL_MOVE:-}" = 1 ] && [ "$last" = "$VW_PV/rsa_key.pem" ]; then exit 27; fi\n'
                  'exec ' + str(shutil.which('mv')) + ' "$@"\n',
        }
        for name, text in wrappers.items():
            (self.bin / name).write_text(text)
            (self.bin / name).chmod(0o700)
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'], VW_PV=str(self.pv))

    def execute(self, mode, archive=None, *, digest=None, env=None):
        command = ['bash', '-c', self.script, 'vw-files', mode]
        if mode == 'copy':
            command += ['a' * 32, digest or c.m.digest(archive), str(len(self.files))]
        return subprocess.run(command, input=archive.read_bytes() if archive else b'',
                              capture_output=True, env=env or self.env, timeout=20)

    def payload(self):
        path = self.root / 'payload.tar'
        c.sanitize(path, self.files, self.dirs)
        return path

    def test_preview_is_readonly(self):
        result = self.execute('preview')
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, b'PV_EMPTY vault-data xfs\n')
        self.assertEqual(list(self.pv.iterdir()), [])

    def test_success_hashes_permissions_and_stage_cleanup(self):
        result = self.execute('copy', self.payload())
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertTrue(result.stdout.startswith(b'PASS_FILES '))
        self.assertEqual(set(p.name for p in self.pv.iterdir()), {'attachments', 'rsa_key.pem'})
        for name, data in self.files.items():
            self.assertEqual((self.pv / name).read_bytes(), data)
            self.assertEqual((self.pv / name).stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.pv.stat().st_mode & 0o777, 0o700)

    def test_nonempty_and_wrong_label_refused(self):
        (self.pv / 'existing').touch()
        self.assertNotEqual(self.execute('preview').returncode, 0)
        (self.pv / 'existing').unlink()
        env = dict(self.env, VW_LABEL='wrong-volume')
        self.assertNotEqual(self.execute('preview', env=env).returncode, 0)
        self.assertEqual(list(self.pv.iterdir()), [])

    def test_bad_hash_retains_stage_never_publishes(self):
        result = self.execute('copy', self.payload(), digest='0' * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.pv / 'rsa_key.pem').exists())
        self.assertFalse((self.pv / 'attachments').exists())
        self.assertTrue((self.pv / ('.vw-migration-' + 'a' * 32)).is_dir())

    def test_partial_publication_is_retained_and_blind_retry_refused(self):
        archive = self.payload()
        result = self.execute('copy', archive, env=dict(self.env, VW_FAIL_MOVE='1'))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.pv / 'attachments').is_dir())
        self.assertFalse((self.pv / 'rsa_key.pem').exists())
        stage = self.pv / ('.vw-migration-' + 'a' * 32)
        self.assertEqual((stage / 'payload/rsa_key.pem').read_bytes(), self.files['rsa_key.pem'])
        retry = self.execute('copy', archive)
        self.assertNotEqual(retry.returncode, 0)
        self.assertEqual((self.pv / ATTACHMENT).read_bytes(), self.files[ATTACHMENT])

    def test_backup_export_allowlist_deterministic_and_unchanged(self):
        for name, data in self.files.items():
            path = self.backup / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (self.backup / 'db.sqlite3-wal').write_bytes(b'untouched wal fixture')
        (self.backup / 'admin.env').write_bytes(b'not copied')
        env = dict(self.env, VW_HOST='hadal-abyss-zone')
        a, b = self.execute('source', env=env), self.execute('source', env=env)
        self.assertEqual(a.returncode, 0, a.stderr.decode())
        self.assertEqual(a.stdout, b.stdout)
        archive = self.root / 'export.tar'
        archive.write_bytes(a.stdout)
        self.assertEqual(c.inventory(archive, {ATTACHMENT})[0], self.files)
        self.assertEqual((self.backup / 'db.sqlite3-wal').read_bytes(), b'untouched wal fixture')


if __name__ == '__main__':
    unittest.main()
