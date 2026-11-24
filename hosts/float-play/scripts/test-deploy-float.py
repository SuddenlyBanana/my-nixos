#!/usr/bin/env python3
"""Offline deployment tests: fake Nix/SSH and execute boot guards in a temp tree."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("deploy-float.sh")
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
failure = os.environ.get("DEPLOY_TEST_FAILURE")
if name == "nix":
    if args[0] == "build":
        if failure == "build":
            sys.exit(1)
        Path(args[args.index("--out-link") + 1]).symlink_to(os.environ["DEPLOY_TEST_CANDIDATE"])
    elif failure == "copy":
        sys.exit(1)
elif name == "ssh":
    if "Wrong target hostname" in body:
        stage = "identity"
    elif "dry-activate" in body:
        stage = "preview"
    elif "systemd-run --unit" in body:
        stage = "activate"
    elif "Runtime does not match" in body:
        stage = "verify"
    else:
        stage = "poll"
    if failure == stage:
        sys.exit(1)
    if stage == "poll" and "show" in args:
        if failure == "unit":
            print("LoadState=loaded\nActiveState=failed\nSubState=failed\nResult=exit-code")
        else:
            print("LoadState=loaded\nActiveState=active\nSubState=exited\nResult=success")
elif name == "hostname":
    print("another-host" if failure == "hostname" else "float-play")
elif name == "systemctl":
    if failure == "health":
        sys.exit(1)
elif name == "sudo":
    sys.exit(__import__("subprocess").run(args[1:], env=os.environ).returncode)
elif name == "systemd-run":
    # Model the manager boundary: shell text is otherwise expanded by systemd,
    # and a transient service does not inherit the SSH login's executable PATH.
    command_index = next(i for i, arg in enumerate(args) if not arg.startswith("-"))
    command = args[command_index:]
    if "--expand-environment=no" not in args:
        print("Invalid environment variable name: services[@]", file=sys.stderr)
        sys.exit(1)
    env = dict(os.environ, PATH="/no-login-path")
    for arg in args[:command_index]:
        if arg.startswith("--setenv="):
            key, value = arg.removeprefix("--setenv=").split("=", 1)
            env[key] = value
    sys.exit(__import__("subprocess").run(command, env=env).returncode)
elif name == "nix-env":
    if failure == "profile":
        sys.exit(1)
    profile = Path(args[args.index("--profile") + 1])
    profile.unlink()
    profile.symlink_to(args[-1])
elif name == "switch-to-configuration":
    if failure == "boot":
        sys.exit(1)
'''


def remote_scripts():
    return dict(re.findall(r"<<'(FLOAT_[A-Z]+)'\n(.*?)\n\1", SCRIPT.read_text(), re.S))


class DeploymentTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="float-deploy-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.store = self.root / "store"
        self.candidate = self.store / ("0" * 32 + "-nixos-system-float-play-test")
        self.key = self.root / "operator-key"
        self.key.touch()
        self.log = self.root / "commands.jsonl"
        self.bin = self.root / "mock-bin"
        self.bin.mkdir()
        for command in ("nix", "ssh", "hostname", "systemctl", "sudo", "systemd-run"):
            self.mock(self.bin / command)
        self.mock(self.candidate / "bin/switch-to-configuration")
        (self.candidate / "kernel").write_text("test kernel")
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        DEPLOY_TEST_LOG=str(self.log),
                        DEPLOY_TEST_CANDIDATE=str(self.candidate))
        self.script = self.root / "hosts/float-play/scripts/deploy-float.sh"
        self.script.parent.mkdir(parents=True)
        self.script.write_text(SCRIPT.read_text().replace("/nix/store/", f"{self.store}/"))

    def mock(self, executable):
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text(f"#!{sys.executable}\n{MOCK}")
        executable.chmod(0o755)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def activations(self):
        return [call for call in self.calls() if "systemd-run --unit" in call["body"]]

    def run_script(self, *options, confirmation="", failure=None, build=False):
        env = dict(self.env)
        if failure:
            env["DEPLOY_TEST_FAILURE"] = failure
        args = ["bash", str(self.script), "--identity", str(self.key)]
        if not build:
            args += ["--candidate", str(self.candidate)]
        return subprocess.run(args + list(options), input=confirmation, text=True,
                              capture_output=True, env=env, timeout=10)

    def test_shell_syntax_including_remote_scripts(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)
        scripts = remote_scripts()
        self.assertEqual(len(scripts), 4)
        for name, body in scripts.items():
            with self.subTest(name=name):
                subprocess.run(["bash", "-n"], input=body, text=True, check=True)

    def test_preview_never_activates(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Preview only", result.stdout)
        self.assertFalse(self.activations())
        self.assertTrue(any("dry-activate" in call["body"] for call in self.calls()))

    def test_build_is_local_and_keeps_the_lock(self):
        result = self.run_script(build=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        build = next(c for c in self.calls() if c["name"] == "nix" and c["args"][0] == "build")
        self.assertIn("--no-update-lock-file", build["args"])
        self.assertTrue(build["args"][-1].endswith("#nixosConfigurations.float-play.config.system.build.toplevel"))
        self.assertFalse(any("nix build" in c["body"] for c in self.calls()))

    def test_copy_accepts_local_unsigned_closure_with_pinned_identity(self):
        self.assertEqual(self.run_script().returncode, 0)
        copy = next(c for c in self.calls() if c["name"] == "nix")
        self.assertEqual(copy["args"], ["copy", "--no-check-sigs", "--to",
                                         "ssh-ng://workspace@64.176.71.121", str(self.candidate)])
        self.assertIn(f"-i {self.key}", copy["ssh_options"])
        self.assertIn("-F /dev/null", copy["ssh_options"])

    def test_missing_or_wrong_confirmation_never_activates(self):
        for mode, answer in (("--activate", ""), ("--activate", "no\n"),
                             ("--persist", ""), ("--persist", "DEPLOY\n")):
            with self.subTest(mode=mode, answer=answer):
                self.assertNotEqual(self.run_script(mode, confirmation=answer).returncode, 0)
                self.assertFalse(self.activations())

    def test_runtime_activation_is_detached_and_has_no_profile_update(self):
        result = self.run_script("--activate", confirmation="DEPLOY\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        activation, = self.activations()
        self.assertEqual(activation["args"][-1], "test")
        self.assertIn("RemainAfterExit=yes", activation["body"])
        self.assertIn("flock --nonblock", activation["body"])
        self.assertNotIn("--wait", activation["body"])
        self.assertIn("Runtime activation completed", result.stdout)
        self.assertIn("--persist", result.stdout)

    def test_persistence_is_an_explicit_separate_operation(self):
        result = self.run_script("--persist", confirmation="PERSIST\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.activations()[0]["args"][-1], "persist")
        self.assertIn("Tested runtime persisted", result.stdout)

    def test_preflight_failures_never_activate(self):
        for failure in ("identity", "copy", "preview"):
            with self.subTest(failure=failure):
                self.assertNotEqual(self.run_script("--activate", confirmation="DEPLOY\n", failure=failure).returncode, 0)
                self.assertFalse(self.activations())

    def test_build_failure_never_contacts_host(self):
        self.assertNotEqual(self.run_script(build=True, failure="build").returncode, 0)
        self.assertFalse(any(c["name"] == "ssh" for c in self.calls()))

    def test_ssh_acknowledgement_loss_does_not_resubmit(self):
        result = self.run_script("--activate", confirmation="DEPLOY\n", failure="activate")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(self.activations()), 1)
        self.assertIn("SSH did not acknowledge", result.stderr)

    def test_failed_unit_or_verification_cannot_report_success(self):
        for failure in ("unit", "verify"):
            with self.subTest(failure=failure):
                result = self.run_script("--persist", confirmation="PERSIST\n", failure=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("Tested runtime persisted", result.stdout)

    def test_ipv6_target_brackets_only_the_copy_uri(self):
        result = self.run_script("--target", "workspace@fd00::1")
        self.assertEqual(result.returncode, 0, result.stderr)
        copy = next(c for c in self.calls() if c["name"] == "nix")
        self.assertIn("ssh-ng://workspace@[fd00::1]", copy["args"])
        self.assertIn("workspace@fd00::1", next(c for c in self.calls() if c["name"] == "ssh")["args"])

    def test_invalid_arguments_never_contact_host(self):
        for options in (("--activate", "--persist"), ("--target", "-oProxyCommand=bad"),
                        ("--candidate", "/tmp"), ("--target",), ("--unknown",)):
            with self.subTest(options=options):
                self.assertNotEqual(self.run_script(*options).returncode, 0)
                self.assertFalse(self.calls())
        self.assertNotEqual(self.run_script("--persist", build=True).returncode, 0)
        self.assertFalse(self.calls())

    def run_payload(self, mode="persist", failure=None, different_runtime=False,
                    launch=False, omit_path=False, omit_expansion_flag=False):
        """Execute the actual under-lock shell payload against temporary state."""
        current = self.root / "current-system"
        profile = self.root / "system-profile"
        booted = self.root / "booted-kernel"
        booted.write_text("different kernel" if failure == "kernel" else "test kernel")
        old = self.root / "old-system"
        old.mkdir(exist_ok=True)
        current.symlink_to(old if different_runtime else self.candidate)
        profile.symlink_to(old)
        self.mock(self.candidate / "sw/bin/nix-env")
        for command in ("hostname", "systemctl"):
            (self.candidate / f"sw/bin/{command}").symlink_to(self.bin / command)
        for command in ("bash", "flock", "cmp", "readlink"):
            (self.candidate / f"sw/bin/{command}").symlink_to(shutil.which(command))
        units = self.candidate / "etc/systemd/system"
        units.mkdir(parents=True)
        for name in ("systemd-networkd", "sshd", "firewall", "nginx", "knot", "postfix"):
            (units / f"{name}.service").touch()
        if launch:
            payload = remote_scripts()["FLOAT_ACTIVATE"]
            if omit_path:
                payload = re.sub(r"  --setenv=PATH=\S+ \\\n", "", payload)
            if omit_expansion_flag:
                payload = payload.replace("--expand-environment=no", "")
            args = [str(self.candidate), "offline-float-unit", mode]
        else:
            payload = re.search(r"/run/current-system/sw/bin/bash -c '\n(.*?)\n' --", remote_scripts()["FLOAT_ACTIVATE"], re.S).group(1)
            args = [str(self.candidate), mode]
        payload = payload.replace("/run/booted-system/kernel", str(booted))
        payload = payload.replace("/run/current-system", str(current))
        payload = payload.replace("/nix/var/nix/profiles/system", str(profile))
        payload = payload.replace("/run/lock/float-deploy.lock", str(self.root / "deploy.lock"))
        env = dict(self.env)
        if failure:
            env["DEPLOY_TEST_FAILURE"] = failure
        result = subprocess.run([shutil.which("bash"), "-c", payload, "--", *args],
                                env=env, text=True, capture_output=True, timeout=10)
        return result, profile, old

    def test_persist_payload_checks_kernel_runtime_hostname_and_services(self):
        # A new test fixture per scenario is needed because it owns symlinks.
        for failure, mismatch in (("kernel", False), ("hostname", False),
                                  ("health", False), (None, True)):
            with self.subTest(failure=failure, mismatch=mismatch):
                fixture = DeploymentTests()
                fixture.setUp()
                try:
                    result, profile, old = fixture.run_payload(failure=failure, different_runtime=mismatch)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(profile.resolve(), old)
                    self.assertFalse(any(c["name"] in ("nix-env", "switch-to-configuration") for c in fixture.calls()))
                finally:
                    fixture.doCleanups()

    def test_persist_payload_registers_profile_before_boot_update(self):
        result, profile, _ = self.run_payload()
        self.assertEqual(result.returncode, 0, result.stderr)
        mutations = [c for c in self.calls() if c["name"] in ("nix-env", "switch-to-configuration")]
        self.assertEqual([c["name"] for c in mutations], ["nix-env", "switch-to-configuration"])
        self.assertEqual(mutations[1]["args"], ["boot"])
        self.assertEqual(profile.resolve(), self.candidate)

    def test_failed_profile_registration_never_updates_boot(self):
        result, profile, old = self.run_payload(failure="profile")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(profile.resolve(), old)
        self.assertFalse(any(c["name"] == "switch-to-configuration" for c in self.calls()))

    def test_failed_boot_update_is_reported_without_automatic_rollback(self):
        result, profile, _ = self.run_payload(failure="boot")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(profile.resolve(), self.candidate)

    def test_runtime_payload_never_changes_system_profile(self):
        result, profile, old = self.run_payload(mode="test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(profile.resolve(), old)
        self.assertFalse(any(c["name"] == "nix-env" for c in self.calls()))
        self.assertEqual(next(c for c in self.calls() if c["name"] == "switch-to-configuration")["args"], ["test"])

    def test_systemd_launch_runs_runtime_payload_with_clean_service_environment(self):
        result, profile, old = self.run_payload(mode="test", launch=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(profile.resolve(), old)
        self.assertEqual(next(c for c in self.calls() if c["name"] == "switch-to-configuration")["args"], ["test"])

    def test_systemd_launch_preserves_array_variables_for_persistence(self):
        result, profile, _ = self.run_payload(launch=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(profile.resolve(), self.candidate)
        checks = [c for c in self.calls() if c["name"] == "systemctl"]
        self.assertTrue(any("postfix.service" in c["args"] for c in checks))

    def test_launch_regression_missing_service_path_fails_before_mutation(self):
        result, profile, old = self.run_payload(mode="test", launch=True, omit_path=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("hostname: command not found", result.stderr)
        self.assertEqual(profile.resolve(), old)
        self.assertFalse(any(c["name"] == "switch-to-configuration" for c in self.calls()))

    def test_launch_regression_systemd_expansion_fails_before_mutation(self):
        result, profile, old = self.run_payload(launch=True, omit_expansion_flag=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("services[@]", result.stderr)
        self.assertEqual(profile.resolve(), old)
        self.assertFalse(any(c["name"] == "switch-to-configuration" for c in self.calls()))


if __name__ == "__main__":
    unittest.main()
