#!/usr/bin/env python3
"""Offline tests only: mock every SSH, Kubernetes, TLS and OpenBao operation."""

import argparse
import base64
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest import mock


spec = importlib.util.spec_from_file_location("csi_smoke", Path(__file__).with_name("smoke-test-openbao-csi.py"))
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
RUN = smoke.PREFIX + "0123456789abcdef"
OWNER = "fedcba98765432100123456789abcdef"
ADMIN = "FAKE-ADMIN-NEVER-LOG"
PROBE = "FAKE-PROBE-NEVER-LOG"


class Remote:
    api = "https://[fd2d:b57c:c77b:9::20]:6443"

    def __init__(self):
        self.namespace = None
        self.objects = []
        self.apps_suspended = True
        self.fail_namespace_delete = False
        self.lost_namespace_ack = False

    def execute(self, command):
        return "rke2-server\n" if command == ["hostname"] else "PUBLIC-CA"

    def get(self, kind, name, namespace=None, optional=False):
        ready = {"status": {"conditions": [{"type": "Ready", "status": "True"}]}}
        if kind in ("node", "helmrelease.helm.toolkit.fluxcd.io"):
            return ready
        if kind == "kustomization.kustomize.toolkit.fluxcd.io":
            return {"spec": {"suspend": self.apps_suspended}}
        if kind == "csidriver":
            return {"spec": {"tokenRequests": [{"audience": "openbao"}]}}
        if kind == "namespace":
            return self.namespace
        if kind == "secret":
            owner = self.namespace["metadata"]["labels"][smoke.OWNER_KEY]
            marker = "non-sensitive-csi-probe-" + owner
            return {"data": {"value": base64.b64encode(marker.encode()).decode()}}
        raise AssertionError((kind, name))

    def kube(self, *args, obj=None, timeout=40):
        if args[:3] == ("create", "-f", "-"):
            obj = copy.deepcopy(obj)
            self.objects.append(obj)
            if obj["kind"] == "Namespace":
                obj["metadata"]["uid"] = "created-uid"
                self.namespace = obj
                if self.lost_namespace_ack:
                    raise smoke.Failure("Simulated lost SSH acknowledgement")
            return json.dumps(obj)
        if "pods" in args:
            return json.dumps({"items": [{"spec": {"nodeName": "hadal-rke2-1",
                "containers": [{"name": "manager", "image": "ghcr.io/fluxcd/source-controller:v1.9.5"}]},
                "status": {"containerStatuses": [{"name": "manager", "ready": True}]}}]})
        if "token" in args:
            return "JWT-" + args[4]
        if args[:2] == ("delete", "namespace"):
            if self.fail_namespace_delete:
                raise smoke.Failure("Simulated namespace cleanup failure")
            self.namespace = None
            return "deleted"
        if "exec" in args:
            return "non-sensitive-csi-probe-" + self.namespace["metadata"]["labels"][smoke.OWNER_KEY]
        if "wait" in args:
            return "ready"
        raise AssertionError(args)


class Bao:
    def __init__(self):
        self.token = ADMIN
        self.calls = []
        self.mounts, self.policies, self.roles = {}, {}, {}
        self.allow_forbidden = False
        self.allow_unbound = False
        self.lost_mount_ack = False
        self.revoked = []

    def request(self, method, path, data=None, *, token=None, expected=(200, 204)):
        credential = self.token if token is None else token
        self.calls.append((method, path, data, credential))
        status, result = 200, None
        if path == "sys/health":
            result = {"initialized": True, "sealed": False, "cluster_id": "test-cluster"}
        elif path == "auth/kubernetes/config":
            result = {"data": {"kubernetes_host": Remote.api, "token_reviewer_jwt_set": True,
                               "disable_local_ca_jwt": True}}
        elif path == "sys/mounts":
            result = {"data": self.mounts}
        elif path.startswith("sys/mounts/"):
            name = path.split("/")[-1] + "/"
            if method == "POST":
                self.mounts[name] = dict(data, accessor="created-mount")
                if self.lost_mount_ack:
                    raise smoke.Failure("Simulated lost mount acknowledgement")
            elif method == "DELETE":
                del self.mounts[name]
        elif path.startswith("sys/policies/acl/"):
            name = path.split("/")[-1]
            if method == "PUT":
                self.policies[name] = data["policy"]
            elif method == "DELETE":
                del self.policies[name]
            elif name in self.policies:
                result = {"data": {"policy": self.policies[name]}}
            else:
                status = 404
        elif path.startswith("auth/kubernetes/role/"):
            name = path.split("/")[-1]
            if method == "POST":
                self.roles[name] = data
            elif method == "DELETE":
                del self.roles[name]
            elif name in self.roles:
                result = {"data": self.roles[name]}
            else:
                status = 404
        elif path == "auth/kubernetes/login":
            role = self.roles[data["role"]]
            if data["jwt"] != "JWT-probe" and not self.allow_unbound:
                status = 403
            else:
                result = {"auth": {"accessor": "probe-accessor", "client_token": PROBE,
                    "policies": role["token_policies"], "metadata": {"service_account_name": "probe",
                    "service_account_namespace": role["bound_service_account_namespaces"][0]}}}
        elif path == "auth/token/revoke-accessor":
            self.revoked.append(data["accessor"])
        elif "/data/" in path:
            if method == "GET":
                if path.endswith("/denied") and credential == PROBE and not self.allow_forbidden:
                    status = 403
                else:
                    owner = next(iter(self.mounts.values()))["description"].split("owner=")[1]
                    result = {"data": {"data": {"value": "non-sensitive-csi-probe-" + owner}}}
        else:
            raise AssertionError((method, path))
        smoke.require(status in expected, f"Unexpected mock HTTP status {status}")
        return result


class SmokeTests(unittest.TestCase):
    def setUp(self):
        self.remote, self.bao = Remote(), Bao()
        self.test = smoke.SmokeTest(self.remote, self.bao, RUN, OWNER)

    def provision(self):
        self.test.preflight()
        self.test.provision()

    def test_full_flow_and_cleanup(self):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.provision()
            self.test.test_login()
            self.test.test_mount()
            self.assertEqual(self.test.cleanup(), [])
        self.assertIsNone(self.remote.namespace)
        self.assertFalse(self.bao.mounts or self.bao.roles or self.bao.policies)
        self.assertEqual(self.bao.revoked, ["probe-accessor"])
        for value in (ADMIN, PROBE, "JWT-probe", "JWT-unbound"):
            self.assertNotIn(value, output.getvalue())

    def test_pod_has_no_admin_or_api_token_and_no_image_pull(self):
        self.provision()
        self.test.test_mount()
        pod = next(o for o in self.remote.objects if o["kind"] == "Pod")
        self.assertFalse(pod["spec"]["automountServiceAccountToken"])
        container, = pod["spec"]["containers"]
        self.assertEqual(container["imagePullPolicy"], "Never")
        self.assertTrue(container["securityContext"]["readOnlyRootFilesystem"])
        self.assertNotIn("env", container)
        manifests = json.dumps(self.remote.objects)
        for value in (ADMIN, PROBE, "JWT-probe"):
            self.assertNotIn(value, manifests)
        policy = next(o for o in self.remote.objects if o["kind"] == "NetworkPolicy")
        self.assertEqual(policy["spec"]["egress"], [])
        self.assertEqual(policy["spec"]["ingress"], [])
        role = self.bao.roles[RUN]
        self.assertEqual(role["bound_service_account_names"], ["probe"])
        self.assertEqual(role["bound_service_account_namespaces"], [RUN])
        self.assertEqual(role["audience"], "openbao")
        self.assertTrue(role["token_no_default_policy"])
        self.assertNotIn("*", self.test.policy)

    def test_refuses_unsuspended_apps_without_writes(self):
        self.remote.apps_suspended = False
        with self.assertRaises(smoke.Failure):
            self.test.preflight()
        self.assertFalse(self.test.attempted)
        self.assertFalse(self.remote.objects)

    def test_never_adopts_existing_namespace_mount_policy_or_role(self):
        for kind in ("namespace", "mount", "policy", "role"):
            with self.subTest(kind=kind):
                remote, bao = Remote(), Bao()
                test = smoke.SmokeTest(remote, bao, RUN, OWNER)
                if kind == "namespace":
                    remote.namespace = {"metadata": {"labels": {smoke.OWNER_KEY: "someone-else"}}}
                elif kind == "mount":
                    bao.mounts[RUN + "/"] = {"description": "pre-existing"}
                elif kind == "policy":
                    bao.policies[RUN] = "pre-existing"
                else:
                    bao.roles[RUN] = {"pre-existing": True}
                before = copy.deepcopy((remote.namespace, bao.mounts, bao.policies, bao.roles))
                with self.assertRaises(smoke.Failure):
                    test.preflight()
                self.assertEqual(test.cleanup(), [])
                self.assertEqual((remote.namespace, bao.mounts, bao.policies, bao.roles), before)

    def test_forbidden_read_must_actually_be_rejected(self):
        self.provision()
        self.bao.allow_forbidden = True
        with self.assertRaises(smoke.Failure):
            self.test.test_login()
        self.assertEqual(self.test.cleanup(), [])

    def test_unbound_identity_must_actually_be_rejected(self):
        self.provision()
        self.bao.allow_unbound = True
        with self.assertRaises(smoke.Failure):
            self.test.test_login()
        self.assertEqual(self.test.cleanup(), [])

    def test_cleanup_refuses_changed_ownership(self):
        self.provision()
        self.remote.namespace["metadata"]["uid"] = "replacement-uid"
        self.bao.mounts[RUN + "/"]["accessor"] = "replacement-mount"
        self.bao.policies[RUN] = "replacement-policy"
        self.bao.roles[RUN]["bound_service_account_namespaces"] = ["production"]
        self.assertEqual(len(self.test.cleanup()), 4)
        self.assertIsNotNone(self.remote.namespace)
        self.assertTrue(self.bao.mounts and self.bao.policies and self.bao.roles)

    def test_cleanup_continues_after_namespace_failure(self):
        self.provision()
        self.remote.fail_namespace_delete = True
        self.assertEqual(self.test.cleanup(), ["Kubernetes namespace"])
        self.assertFalse(self.bao.mounts or self.bao.roles or self.bao.policies)

    def test_lost_namespace_acknowledgement_is_cleaned_by_owner(self):
        self.remote.lost_namespace_ack = True
        self.test.preflight()
        with self.assertRaises(smoke.Failure):
            self.test.provision()
        self.assertEqual(self.test.cleanup(), [])
        self.assertIsNone(self.remote.namespace)

    def test_lost_mount_acknowledgement_is_cleaned_by_description(self):
        self.bao.lost_mount_ack = True
        self.test.preflight()
        with self.assertRaises(smoke.Failure):
            self.test.provision()
        self.assertEqual(self.test.cleanup(), [])
        self.assertFalse(self.bao.mounts)

    def test_invalid_cleanup_identifier_is_rejected(self):
        for name in ("database", "sys", "../production", smoke.PREFIX + "*"):
            with self.assertRaises(smoke.Failure):
                smoke.SmokeTest(self.remote, self.bao, name, OWNER)

    def main(self, *args):
        with mock.patch.object(sys, "argv", ["smoke-test", *args]), \
             mock.patch.object(smoke, "Remote", return_value=self.remote), \
             mock.patch.object(smoke, "Bao", return_value=self.bao), \
             mock.patch.object(smoke.shutil, "which", return_value="/mock/ssh"), \
             mock.patch.object(smoke.getpass, "getpass", return_value=ADMIN), \
             mock.patch.object(sys.stdin, "isatty", return_value=True), \
             contextlib.redirect_stdout(io.StringIO()) as output:
            result = smoke.main()
        return result, output.getvalue()

    def test_preview_never_creates_resources_or_uses_admin_token(self):
        result, output = self.main()
        self.assertEqual(result, 0)
        self.assertIn("Preview only", output)
        self.assertFalse(self.remote.objects)
        self.assertEqual(len(self.bao.calls), 1)
        self.assertEqual(self.bao.calls[0][3], "")

    def test_main_success_and_no_secret_output(self):
        result, output = self.main("--run")
        self.assertEqual(result, 0)
        self.assertIn("apps remain suspended", output)
        self.assertNotIn(ADMIN, output)
        self.assertNotIn(PROBE, output)

    def test_main_cleanup_failure_cannot_report_success(self):
        self.remote.fail_namespace_delete = True
        with contextlib.redirect_stderr(io.StringIO()) as errors:
            with self.assertRaises(smoke.Failure):
                self.main("--run")
        self.assertIn("CLEANUP INCOMPLETE", errors.getvalue())

    def test_interruption_still_cleans_up_without_touching_admin_token(self):
        with mock.patch.object(smoke.SmokeTest, "test_mount", side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                self.main("--run")
        self.assertIsNone(self.remote.namespace)
        self.assertFalse(self.bao.mounts or self.bao.roles or self.bao.policies)
        self.assertEqual(self.bao.revoked, ["probe-accessor"])
        self.assertEqual(self.bao.token, "")

    def test_ssh_drops_credentials_and_keeps_host_verification(self):
        args = argparse.Namespace(identity="/tmp/fake-key", host="workspace@172.16.0.241",
                                  rke2_address="fd2d:b57c:c77b:9::20")
        with mock.patch.object(Path, "is_file", return_value=True), \
             mock.patch.dict(os.environ, {"BAO_TOKEN": ADMIN, "VAULT_TOKEN": ADMIN}), \
             mock.patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "ok", "")) as runner:
            remote = smoke.Remote(args)
            remote.execute(["hostname"])
        command = runner.call_args.args[0]
        self.assertIn("StrictHostKeyChecking=yes", command)
        self.assertNotIn("BAO_TOKEN", runner.call_args.kwargs["env"])
        self.assertNotIn("VAULT_TOKEN", runner.call_args.kwargs["env"])
        self.assertNotIn(ADMIN, str(runner.call_args))
        self.assertNotIn("-A", command)

    def test_long_kubectl_wait_is_not_cut_short_by_rest_request_timeout(self):
        args = argparse.Namespace(identity="/tmp/fake-key", host="workspace@172.16.0.241",
                                  rke2_address="fd2d:b57c:c77b:9::20")
        with mock.patch.object(Path, "is_file", return_value=True):
            remote = smoke.Remote(args)
        with mock.patch.object(remote, "execute", return_value="ready") as execute:
            remote.kube("-n", RUN, "wait", "--for=condition=Ready", "pod/probe", "--timeout=180s", timeout=200)
        self.assertIn("--request-timeout=0", execute.call_args.args[0])
        self.assertEqual(execute.call_args.kwargs["timeout"], 200)

    def test_tls_checks_real_name_and_api_errors_never_leak_response(self):
        with mock.patch.object(smoke.ssl, "create_default_context") as context, \
             mock.patch.object(smoke.socket, "create_connection"), \
             mock.patch.object(smoke.http.client, "HTTPSConnection") as connection:
            response = connection.return_value.getresponse.return_value
            response.status = 403
            response.read.return_value = ("sensitive-response-" + ADMIN).encode()
            bao = smoke.Bao("https://[::1]:18200", "PUBLIC-CA", "openbao.home.arpa", ADMIN)
            with self.assertRaises(smoke.Failure) as raised:
                bao.request("GET", "sys/mounts")
            self.assertNotIn(ADMIN, str(raised.exception))
            context.assert_called_once_with(cadata="PUBLIC-CA")
            self.assertEqual(context.return_value.wrap_socket.call_args.kwargs["server_hostname"], "openbao.home.arpa")


if __name__ == "__main__":
    unittest.main()
