#!/usr/bin/env python3
"""Offline deployment-control tests; never connect to a host or invoke Nix."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("deploy-hadal.sh")

# Each mocked executable records argv and SSH stdin. Remote scripts are checked
# for syntax separately, not executed against the workstation's /run or sudo.
MOCK = r'''
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
body = sys.stdin.read() if name == "ssh" and "-s" in args else ""
with open(os.environ["DEPLOY_TEST_LOG"], "a") as stream:
    stream.write(json.dumps({"name": name, "args": args, "body": body,
                             "ssh_options": os.environ.get("NIX_SSHOPTS")}) + "\n")
if name == "nix":
    if args[0] == "build":
        if os.environ.get("DEPLOY_TEST_FAILURE") == "build":
            sys.exit(1)
        Path(args[args.index("--out-link") + 1]).symlink_to(os.environ["DEPLOY_TEST_CANDIDATE"])
    elif os.environ.get("DEPLOY_TEST_FAILURE") == "copy":
        sys.exit(1)
elif name == "ssh":
    if "Wrong target hostname" in body:
        stage = "identity"
    elif "dry-activate" in body:
        stage = "preview"
    elif "systemd-run --unit" in body:
        stage = "activate"
    elif "HADAL_VERIFY" not in body and "Runtime does not match" in body:
        stage = "verify"
    else:
        stage = "poll"
    if os.environ.get("DEPLOY_TEST_FAILURE") == stage:
        sys.exit(1)
    if stage == "poll" and "show" in args:
        if os.environ.get("DEPLOY_TEST_FAILURE") == "unit":
            print("LoadState=loaded\nActiveState=failed\nSubState=failed\nResult=exit-code")
        else:
            print("LoadState=loaded\nActiveState=active\nSubState=exited\nResult=success")
'''


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hadal-deploy-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.script = self.root / "hosts/hadal-abyss-zone/scripts/deploy-hadal.sh"
        self.script.parent.mkdir(parents=True)
        # Only the copy under test uses a temporary store, so tests need neither
        # root nor any pre-existing Nix outputs. Production code is unchanged.
        self.store = self.root / "store"
        self.script.write_text(SCRIPT.read_text().replace("/nix/store/", f"{self.store}/"))
        self.candidate = self.store / (
            "0" * 32 + "-nixos-system-hadal-abyss-zone-storage-provisioning-test"
        )
        (self.candidate / "bin").mkdir(parents=True)
        switch = self.candidate / "bin/switch-to-configuration"
        switch.write_text("#!/bin/sh\nexit 0\n")
        switch.chmod(0o755)
        (self.candidate / "kernel").touch()
        self.key = self.root / "operator-key"
        self.key.touch()
        self.log = self.root / "commands.jsonl"
        mock_bin = self.root / "mock-bin"
        mock_bin.mkdir()
        for name in ("nix", "ssh"):
            executable = mock_bin / name
            executable.write_text(f"#!{sys.executable}\n{MOCK}")
            executable.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{mock_bin}:{os.environ['PATH']}",
                        DEPLOY_TEST_LOG=str(self.log),
                        DEPLOY_TEST_CANDIDATE=str(self.candidate))

    def run_script(self, *options, confirmation="", failure=None, build=False):
        env = dict(self.env)
        if failure:
            env["DEPLOY_TEST_FAILURE"] = failure
        args = ["bash", str(self.script), "--identity", str(self.key)]
        if not build:
            args += ["--candidate", str(self.candidate)]
        return subprocess.run(args + list(options), input=confirmation, text=True,
                              capture_output=True, env=env, timeout=10)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def activations(self):
        return [call for call in self.calls() if "systemd-run --unit" in call["body"]]

    def test_shell_syntax_including_remote_scripts(self):
        source = SCRIPT.read_text()
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)
        scripts = re.findall(r"<<'(HADAL_[A-Z]+)'\n(.*?)\n\1", source, re.S)
        self.assertEqual(len(scripts), 4)
        for name, body in scripts:
            with self.subTest(name=name):
                subprocess.run(["bash", "-n"], input=body, text=True, check=True)

    def test_preview_does_not_activate(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Preview only", result.stdout)
        self.assertFalse(self.activations())
        self.assertTrue(any("dry-activate" in call["body"] for call in self.calls()))

    def test_default_build_uses_specialisation_and_does_not_update_lock(self):
        result = self.run_script(build=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        build = next(call for call in self.calls() if call["name"] == "nix" and call["args"][0] == "build")
        self.assertIn("--no-update-lock-file", build["args"])
        self.assertIn(".specialisation.storage-provisioning.configuration.system.build.toplevel", build["args"][-1])
        self.assertFalse(self.activations())

    def test_declined_or_missing_confirmation_does_not_activate(self):
        for answer in ("no\n", ""):
            with self.subTest(answer=answer):
                result = self.run_script("--activate", confirmation=answer)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.activations())

    def test_successful_activation_is_test_only_and_detached(self):
        result = self.run_script("--activate", confirmation="DEPLOY\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        activation, = self.activations()
        self.assertIn('"$candidate/bin/switch-to-configuration" test', activation["body"])
        self.assertIn("RemainAfterExit=yes", activation["body"])
        self.assertIn("flock --nonblock", activation["body"])
        self.assertIn('cmp --silent /run/booted-system/kernel "$candidate/kernel"', activation["body"])
        self.assertNotIn("--wait", activation["body"])
        self.assertIn("Runtime activation completed", result.stdout)
        for call in self.calls():
            self.assertNotIn("nix-env", call["body"])
            self.assertNotIn("systemctl reboot", call["body"])

    def test_preflight_failures_never_activate(self):
        for failure in ("identity", "copy", "preview"):
            with self.subTest(failure=failure):
                result = self.run_script("--activate", confirmation="DEPLOY\n", failure=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.activations())

    def test_build_failure_stops_before_ssh(self):
        result = self.run_script(build=True, failure="build")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call["name"] == "ssh" for call in self.calls()))

    def test_activation_failure_is_reported(self):
        result = self.run_script("--activate", confirmation="DEPLOY\n", failure="unit")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Activation failed", result.stderr)

    def test_lost_ssh_acknowledgement_checks_unit_without_resubmitting(self):
        result = self.run_script("--activate", confirmation="DEPLOY\n", failure="activate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.activations()), 1)
        self.assertIn("SSH did not acknowledge", result.stderr)

    def test_failed_final_verification_is_not_reported_as_success(self):
        result = self.run_script("--activate", confirmation="DEPLOY\n", failure="verify")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("Runtime activation completed", result.stdout)

    def test_ipv6_target_is_bracketed_only_for_copy_uri(self):
        target = "workspace@fd00::2"
        result = self.run_script("--target", target)
        self.assertEqual(result.returncode, 0, result.stderr)
        copy = next(call for call in self.calls() if call["name"] == "nix")
        self.assertEqual(copy["args"][2], "ssh://workspace@[fd00::2]")
        ssh = next(call for call in self.calls() if call["name"] == "ssh")
        self.assertIn(target, ssh["args"])
        self.assertIn("-F /dev/null", copy["ssh_options"])

    def test_invalid_arguments_fail_before_contacting_host(self):
        for options in (("--target", "-oBadOption"), ("--candidate", "/tmp"), ("--unknown",), ("--target",)):
            with self.subTest(options=options):
                result = self.run_script(*options)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.calls())


if __name__ == "__main__":
    unittest.main()
