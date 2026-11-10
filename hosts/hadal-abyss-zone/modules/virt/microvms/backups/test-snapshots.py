"""Unit checks only: no real LVM, filesystem freeze, VM, database or NAS access."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


agent_module = load("agent", "snapshot-agent.py")
pair = load("pair", "snapshot-pair.py")
RUN = "20261031020000-aabbccdd"


class AgentTests(unittest.TestCase):
    def request(self, agent, operation, run=RUN):
        return agent.dispatch({"command": operation, "run": run})

    def test_foreign_or_invalid_run_is_rejected(self):
        agent = agent_module.Agent("/snapshot")
        with self.assertRaises(ValueError):
            self.request(agent, "freeze", "../bad")
        self.request(agent, "begin")
        with self.assertRaises(ValueError):
            self.request(agent, "freeze", "20261031020000-deadbeef")

    @patch.object(agent_module.subprocess, "run")
    def test_watchdog_thaws_on_host_disconnect(self, execute):
        agent = agent_module.Agent("/snapshot")
        self.request(agent, "begin")
        self.request(agent, "freeze")
        agent.deadline = 0
        agent.expire()
        self.assertIsNone(agent.run)
        self.assertFalse(agent.frozen)
        self.assertEqual(execute.call_args.args[0], ["fsfreeze", "--unfreeze", "/snapshot"])

    @patch.object(agent_module.subprocess, "run")
    def test_failed_freeze_still_attempts_thaw(self, execute):
        execute.side_effect = [subprocess.TimeoutExpired("fsfreeze", 15), MagicMock()]
        agent = agent_module.Agent("/snapshot")
        self.request(agent, "begin")
        with self.assertRaises(subprocess.TimeoutExpired):
            self.request(agent, "freeze")
        agent.abort()
        self.assertFalse(agent.frozen)
        self.assertEqual(execute.call_count, 2)

    @patch.object(agent_module.os, "seteuid")
    @patch.object(agent_module.pwd, "getpwnam")
    @patch.object(agent_module.psycopg, "connect")
    def test_same_database_session_is_kept_until_stop(self, connect, user, seteuid):
        user.return_value.pw_uid = 71
        connection = connect.return_value
        connection.execute.return_value.fetchone.side_effect = [("0/1",), ("0/2", "label", "map")]
        agent = agent_module.Agent("/postgresql", postgres=True)
        self.request(agent, "begin")
        self.assertFalse(connection.close.called)
        result = self.request(agent, "finish")
        self.assertEqual(result["backup_label"], "label")
        self.assertEqual(connect.call_count, 1)
        connection.close.assert_called_once()


class PairTests(unittest.TestCase):
    @patch.object(pair, "command")
    @patch.object(pair, "rpc")
    @patch.object(pair, "lv_info")
    @patch.object(pair, "restic_snapshot")
    def test_stream_failure_has_no_completion_marker_and_cleans_owned_snapshots(self, restic, info, rpc, command):
        rpc.return_value = {"frozen": True}
        info.side_effect = [
            {"origin": "postgresql-data", "lv_uuid": "pg-owned"},
            {"origin": "vaultwarden-data", "lv_uuid": "files-owned"},
            {"origin": "postgresql-data", "lv_uuid": "pg-owned"},
            {"origin": "vaultwarden-data", "lv_uuid": "files-owned"},
        ]
        restic.side_effect = RuntimeError("simulated stream failure")
        with tempfile.TemporaryDirectory() as directory, patch.dict(pair.os.environ, {
            "CHECK_BACKUP_MOUNT": "/mock/check", "CREDENTIALS_DIRECTORY": directory,
            "RUNTIME_DIRECTORY": directory,
        }):
            with self.assertRaises(RuntimeError):
                pair.backup()
            self.assertEqual(list(Path(directory).glob("*/complete.json")), [])
        removed = [call.args for call in command.call_args_list if call.args[0] == "lvremove"]
        self.assertEqual(len(removed), 2)
        self.assertTrue(all(call[2].startswith("/dev/hadal-vm/backup-") for call in removed))

    @patch.object(pair, "command")
    @patch.object(pair, "rpc")
    @patch.object(pair, "lv_info")
    @patch.object(pair, "restic_snapshot")
    def test_changed_snapshot_identity_is_never_removed(self, restic, info, rpc, command):
        rpc.return_value = {"frozen": True}
        info.side_effect = [
            {"origin": "postgresql-data", "lv_uuid": "pg-owned"},
            {"origin": "vaultwarden-data", "lv_uuid": "files-owned"},
            {"origin": "postgresql-data", "lv_uuid": "someone-elses-volume"},
        ]
        restic.side_effect = RuntimeError("simulated stream failure")
        with tempfile.TemporaryDirectory() as directory, patch.dict(pair.os.environ, {
            "CHECK_BACKUP_MOUNT": "/mock/check", "CREDENTIALS_DIRECTORY": directory,
            "RUNTIME_DIRECTORY": directory,
        }):
            with self.assertRaisesRegex(RuntimeError, "Refusing to remove"):
                pair.backup()
        self.assertFalse(any(call.args[0] == "lvremove" for call in command.call_args_list))


if __name__ == "__main__":
    unittest.main()
