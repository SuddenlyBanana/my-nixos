#!/usr/bin/env python3
"""Workstation-only OpenBao/CSI smoke test; preview by default, --run to execute.

Uses an existing verified OpenBao HTTPS tunnel (default https://[::1]:18200).
Fetches only the public CA over verified SSH, never a Kubernetes admin kubeconfig.
Requires Python 3 and ssh. No administrator credential is sent to SSH or a pod.
"""

import argparse
import base64
import getpass
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import ssl
import subprocess
import sys
from urllib.parse import urlsplit
import uuid


PREFIX = "hadal-csi-smoke-"
OWNER_KEY = "hadal.home.arpa/smoke-owner"
AUTH_PATH = "auth/kubernetes"


class Failure(Exception):
    """Safe-to-print error: never include raw subprocess or API responses."""


def require(condition, message):
    if not condition:
        raise Failure(message)


class Bao:
    def __init__(self, address, ca, server_name, token):
        url = urlsplit(address)
        require(url.scheme == "https" and url.hostname and not url.username
                and not url.password and url.path in ("", "/")
                and not url.query and not url.fragment, "OpenBao address must be a plain HTTPS origin")
        self.host, self.port = url.hostname, url.port or 443
        self.server_name, self.token = server_name, token
        self.context = ssl.create_default_context(cadata=ca)

    def request(self, method, path, data=None, *, token=None, expected=(200, 204)):
        # Connect to the tunnel but verify the actual OpenBao certificate name.
        # Verification stays enabled; the workstation CA is never replaced by
        # a pod-provided certificate or an insecure TLS context.
        connection = http.client.HTTPSConnection(self.host, self.port, timeout=20)
        try:
            raw_socket = socket.create_connection((self.host, self.port), timeout=20)
            try:
                connection.sock = self.context.wrap_socket(raw_socket, server_hostname=self.server_name)
            except BaseException:
                raw_socket.close()
                raise
            headers = {"Content-Type": "application/json"}
            credential = self.token if token is None else token
            if credential:
                headers["X-Vault-Token"] = credential
            connection.request(method, "/v1/" + path,
                               body=None if data is None else json.dumps(data), headers=headers)
            response = connection.getresponse()
            body = response.read()
            require(response.status in expected,
                    f"OpenBao {method} {path} failed (HTTP {response.status}); response suppressed")
            if response.status in (403, 404) or not body:
                return None
            return json.loads(body)
        except (OSError, http.client.HTTPException, ValueError) as error:
            raise Failure(f"OpenBao request failed ({type(error).__name__}); check the HTTPS tunnel/CA") from None
        finally:
            connection.close()


class Remote:
    def __init__(self, args):
        identity = str(Path(args.identity).expanduser().resolve())
        require(Path(identity).is_file() and "%" not in identity and "\n" not in identity,
                "SSH identity must be an existing file without percent signs/newlines")
        require(re.fullmatch(r"[\w.-]+@[\w.:-]+", args.host), "Use USER@HOST for --host")
        ipaddress.IPv6Address(args.rke2_address)
        common = ["ssh", "-F", "/dev/null", "-i", identity,
                  "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                  "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
                  "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2"]
        proxy = shlex.join(common + ["-W", "[%h]:%p", args.host])
        self.command = common + ["-o", f"ProxyCommand={proxy}", f"workspace@{args.rke2_address}"]
        self.api = f"https://[{args.rke2_address}]:6443"
        # Never inherit an OpenBao/Vault administrator token into SSH children.
        self.env = {key: value for key, value in os.environ.items()
                    if key not in ("BAO_TOKEN", "VAULT_TOKEN")}

    def execute(self, command, *, data=None, timeout=40):
        try:
            result = subprocess.run(self.command + [shlex.join(command)],
                                    input=data, text=True, capture_output=True,
                                    env=self.env, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise Failure("SSH/kubectl timed out; response suppressed") from None
        require(result.returncode == 0,
                "SSH/kubectl failed; verify host keys, connectivity and passwordless sudo (response suppressed)")
        return result.stdout

    def kube(self, *args, obj=None, timeout=40):
        request_timeout = "0" if "wait" in args else "25s"
        return self.execute(["sudo", "-n", "kubectl",
                             "--kubeconfig=/etc/rancher/rke2/rke2.yaml",
                             f"--server={self.api}", f"--request-timeout={request_timeout}", *args],
                            data=None if obj is None else json.dumps(obj), timeout=timeout)

    def get(self, kind, name, namespace=None, optional=False):
        args = ([] if namespace is None else ["-n", namespace]) + ["get", kind, name, "-o", "json"]
        if optional:
            args.append("--ignore-not-found")
        raw = self.kube(*args)
        return json.loads(raw) if raw.strip() else None


class SmokeTest:
    def __init__(self, remote, bao, run_id=None, owner=None):
        self.remote, self.bao = remote, bao
        self.run_id = run_id or PREFIX + uuid.uuid4().hex[:16]
        self.owner = owner or uuid.uuid4().hex
        require(re.fullmatch(PREFIX + r"[0-9a-f]{16}", self.run_id), "Invalid smoke-test identifier")
        self.marker = "non-sensitive-csi-probe-" + self.owner
        self.description = "Temporary Hadal CSI smoke test; owner=" + self.owner
        self.policy = f'# owner={self.owner}\npath "{self.run_id}/data/probe" {{ capabilities = ["read"] }}\n'
        self.attempted = set()
        self.namespace_uid = None
        self.mount_accessor = None
        self.login_accessor = None

    def metadata(self, name):
        return {"name": name, "namespace": self.run_id,
                "labels": {OWNER_KEY: self.owner, "app.kubernetes.io/managed-by": "hadal-csi-smoke"}}

    def mounts(self):
        result = self.bao.request("GET", "sys/mounts")
        return result.get("data", result)

    def preflight(self):
        require(self.remote.execute(["hostname"]).strip() == "rke2-server", "Wrong SSH guest hostname")
        node = self.remote.get("node", "hadal-rke2-1")
        require(any(c["type"] == "Ready" and c["status"] == "True"
                    for c in node["status"]["conditions"]), "RKE2 node is not Ready")
        require(self.remote.get("kustomization.kustomize.toolkit.fluxcd.io", "apps", "flux-system")
                ["spec"].get("suspend") is True, "Apps must remain suspended; refusing this rollout test")
        driver = self.remote.get("csidriver", "secrets-store.csi.k8s.io")
        require(any(t.get("audience") == "openbao" for t in driver["spec"].get("tokenRequests", [])),
                "CSI driver does not request the openbao audience")
        for namespace, name in (("kube-system", "secrets-store-csi-driver"),
                                ("openbao-system", "openbao-csi-provider")):
            release = self.remote.get("helmrelease.helm.toolkit.fluxcd.io", name, namespace)
            require(any(c["type"] == "Ready" and c["status"] == "True"
                        for c in release.get("status", {}).get("conditions", [])), f"HelmRelease {name} is not Ready")
        pods = json.loads(self.remote.kube("-n", "flux-system", "get", "pods", "-l", "app=source-controller", "-o", "json"))
        candidates = [pod for pod in pods["items"] if pod["spec"].get("nodeName") == "hadal-rke2-1"
                      and any(c["name"] == "manager" and c.get("ready")
                              for c in pod.get("status", {}).get("containerStatuses", []))]
        require(candidates, "Need a ready source-controller image cached on hadal-rke2-1")
        self.image = next(c["image"] for c in candidates[0]["spec"]["containers"] if c["name"] == "manager")
        require(self.remote.get("namespace", self.run_id, optional=True) is None,
                "Smoke-test namespace already exists; refusing adoption")
        require(self.run_id + "/" not in self.mounts(), "Smoke-test mount already exists; refusing overwrite")
        for path in (f"sys/policies/acl/{self.run_id}", f"{AUTH_PATH}/role/{self.run_id}"):
            require(self.bao.request("GET", path, expected=(200, 404)) is None,
                    "Smoke-test policy/role already exists; refusing overwrite")

    def create(self, obj):
        return json.loads(self.remote.kube("create", "-f", "-", "-o", "json", obj=obj))

    def provision(self):
        namespace = {"apiVersion": "v1", "kind": "Namespace", "metadata": self.metadata(self.run_id)}
        namespace["metadata"].pop("namespace")
        namespace["metadata"]["labels"]["pod-security.kubernetes.io/enforce"] = "restricted"
        self.attempted.add("namespace")
        self.namespace_uid = self.create(namespace)["metadata"]["uid"]
        for name in ("probe", "unbound"):
            self.create({"apiVersion": "v1", "kind": "ServiceAccount", "metadata": self.metadata(name),
                         "automountServiceAccountToken": False})
        self.create({"apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
                     "metadata": self.metadata("isolate"), "spec": {"podSelector": {},
                     "policyTypes": ["Ingress", "Egress"], "ingress": [], "egress": []}})
        self.attempted.add("mount")
        self.bao.request("POST", f"sys/mounts/{self.run_id}",
                         {"type": "kv", "options": {"version": "2"}, "description": self.description})
        self.mount_accessor = self.mounts()[self.run_id + "/"]["accessor"]
        for name in ("probe", "denied"):
            self.bao.request("POST", f"{self.run_id}/data/{name}", {"data": {"value": self.marker}})
        self.attempted.add("policy")
        self.bao.request("PUT", f"sys/policies/acl/{self.run_id}", {"policy": self.policy})
        self.attempted.add("role")
        self.bao.request("POST", f"{AUTH_PATH}/role/{self.run_id}", {
            "bound_service_account_names": ["probe"], "bound_service_account_namespaces": [self.run_id],
            "audience": "openbao", "token_policies": [self.run_id], "token_no_default_policy": True,
            "token_ttl": "10m", "token_max_ttl": "10m"})

    def login(self, account):
        jwt = self.remote.kube("-n", self.run_id, "create", "token", account,
                               "--audience=openbao", "--duration=10m").strip()
        require(jwt, "Kubernetes returned an empty projected token")
        return self.bao.request("POST", AUTH_PATH + "/login", {"role": self.run_id, "jwt": jwt}, token="",
                                expected=(200,) if account == "probe" else (403,))

    def test_login(self):
        auth = self.login("probe")["auth"]
        self.login_accessor = auth["accessor"]
        require(auth["metadata"]["service_account_name"] == "probe"
                and auth["metadata"]["service_account_namespace"] == self.run_id
                and auth["policies"] == [self.run_id], "Unexpected login identity or policies")
        token = auth["client_token"]
        result = self.bao.request("GET", f"{self.run_id}/data/probe", token=token)
        require(result["data"]["data"]["value"] == self.marker, "Authenticated read returned the wrong marker")
        self.bao.request("GET", f"{self.run_id}/data/denied", token=token, expected=(403,))
        self.login("unbound")
        print("PASS: Kubernetes login, allowed read, forbidden read, and unbound identity rejection", flush=True)

    def test_mount(self):
        self.create({"apiVersion": "secrets-store.csi.x-k8s.io/v1", "kind": "SecretProviderClass",
                     "metadata": self.metadata("probe"), "spec": {"provider": "openbao", "parameters": {
                         "roleName": self.run_id, "audience": "openbao", "baoAuthMountPath": "kubernetes",
                         "objects": json.dumps([{"objectName": "value", "secretPath": f"{self.run_id}/data/probe",
                                                 "secretKey": "value", "filePermission": 292}])},
                         "secretObjects": [{"secretName": "probe-sync", "type": "Opaque",
                                            "data": [{"objectName": "value", "key": "value"}]}]}})
        # Reuse a running controller's cached shell image; never pull a new image.
        # The pod has neither an API token mount nor any network egress.
        self.create({"apiVersion": "v1", "kind": "Pod", "metadata": self.metadata("probe"), "spec": {
            "serviceAccountName": "probe", "automountServiceAccountToken": False,
            "nodeSelector": {"kubernetes.io/hostname": "hadal-rke2-1"}, "restartPolicy": "Never",
            "activeDeadlineSeconds": 300,
            "securityContext": {"runAsNonRoot": True, "runAsUser": 1000, "runAsGroup": 1000,
                                "fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [{"name": "probe", "image": self.image, "imagePullPolicy": "Never",
                            "command": ["/bin/sh", "-ec", "while :; do sleep 30; done"],
                            "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                                                "capabilities": {"drop": ["ALL"]}},
                            "resources": {"requests": {"cpu": "10m", "memory": "16Mi"},
                                          "limits": {"cpu": "100m", "memory": "64Mi"}},
                            "volumeMounts": [{"name": "probe", "mountPath": "/probe", "readOnly": True}]}],
            "volumes": [{"name": "probe", "csi": {"driver": "secrets-store.csi.k8s.io", "readOnly": True,
                                                   "volumeAttributes": {"secretProviderClass": "probe"}}}]}})
        self.remote.kube("-n", self.run_id, "wait", "--for=condition=Ready", "pod/probe", "--timeout=180s", timeout=200)
        # Capture and compare; do not print even the harmless mounted value.
        value = self.remote.kube("-n", self.run_id, "exec", "probe", "--", "/bin/cat", "/probe/value")
        require(value == self.marker, "CSI-mounted file did not match the test marker")
        self.remote.kube("-n", self.run_id, "wait", "--for=create", "secret/probe-sync", "--timeout=30s", timeout=45)
        synced = self.remote.get("secret", "probe-sync", self.run_id)
        require(base64.b64decode(synced["data"]["value"], validate=True).decode() == self.marker,
                "CSI-synchronized Kubernetes Secret did not match")
        print("PASS: CSI-mounted file and synchronized Kubernetes Secret", flush=True)

    def cleanup(self):
        errors = []

        def attempt(name, action):
            try:
                action()
            except Exception:
                errors.append(name)

        def namespace():
            current = self.remote.get("namespace", self.run_id, optional=True)
            if current is None:
                return
            require(current["metadata"].get("labels", {}).get(OWNER_KEY) == self.owner,
                    "Namespace ownership changed")
            require(self.namespace_uid is None or current["metadata"]["uid"] == self.namespace_uid,
                    "Namespace UID changed")
            self.remote.kube("delete", "namespace", self.run_id, "--wait=true", "--timeout=60s", timeout=80)

        def role():
            path = f"{AUTH_PATH}/role/{self.run_id}"
            current = self.bao.request("GET", path, expected=(200, 404))
            if current is None:
                return
            data = current["data"]
            require(data.get("bound_service_account_names") == ["probe"]
                    and data.get("bound_service_account_namespaces") == [self.run_id]
                    and data.get("token_policies") == [self.run_id], "Role ownership changed")
            self.bao.request("DELETE", path)

        def policy():
            path = f"sys/policies/acl/{self.run_id}"
            current = self.bao.request("GET", path, expected=(200, 404))
            if current is not None:
                require(current["data"]["policy"] == self.policy, "Policy ownership changed")
                self.bao.request("DELETE", path)

        def mount():
            current = self.mounts().get(self.run_id + "/")
            if current is not None:
                require(current.get("description") == self.description
                        and (self.mount_accessor is None or current.get("accessor") == self.mount_accessor),
                        "Mount ownership changed")
                self.bao.request("DELETE", f"sys/mounts/{self.run_id}")

        # Independent guarded cleanup: one failure never skips the other stores.
        if "namespace" in self.attempted:
            attempt("Kubernetes namespace", namespace)
        if self.login_accessor:
            attempt("probe login token", lambda: self.bao.request(
                "POST", "auth/token/revoke-accessor", {"accessor": self.login_accessor}))
        for name, action in (("role", role), ("policy", policy), ("mount", mount)):
            if name in self.attempted:
                attempt("OpenBao " + name, action)
        return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Create test-only resources, test them, then clean up")
    parser.add_argument("--host", default="workspace@172.16.0.241")
    parser.add_argument("--rke2-address", default="fd2d:b57c:c77b:9::20")
    parser.add_argument("--identity", default="~/.ssh/id_ed25519_personal")
    parser.add_argument("--bao-addr", default="https://[::1]:18200")
    parser.add_argument("--tls-server-name", default="openbao.home.arpa")
    args = parser.parse_args()
    require(shutil.which("ssh"), "ssh is required")
    remote = Remote(args)
    require(remote.execute(["hostname"]).strip() == "rke2-server", "Wrong SSH guest hostname")
    ca = remote.execute(["sudo", "-n", "cat", "/run/hadal-bootstrap/ca.crt"])
    # No token files, command-line credentials, inherited insecure TLS flags,
    # or administrator token in child-process environments.
    client = Bao(args.bao_addr, ca, args.tls_server_name, "")
    status = client.request("GET", "sys/health", token="")
    require(status.get("initialized") is True and status.get("sealed") is False,
            "OpenBao is not initialized and unsealed")
    print("Target: RKE2 hadal-rke2-1; OpenBao " + status.get("cluster_id", "unknown"), flush=True)
    if not args.run:
        print("Preview only: --run creates an isolated namespace, KV mount, policy, role and harmless probe pod.")
        print("It tests login/denial and CSI file/Secret sync, then removes only its owned resources.")
        print("Keep apps suspended. No database, GitOps, deployment or server-auth configuration changes.")
        return 0
    client.token = os.environ.get("BAO_TOKEN", "")
    if not client.token:
        require(sys.stdin.isatty(), "Use an interactive terminal for the hidden operator-token prompt")
        client.token = getpass.getpass("OpenBao administrator/operator token: ")
    require(client.token, "An administrator/operator token is required")
    auth_config = client.request("GET", AUTH_PATH + "/config")["data"]
    require(auth_config.get("kubernetes_host") == remote.api
            and auth_config.get("token_reviewer_jwt_set") is True
            and auth_config.get("disable_local_ca_jwt") is True, "Unexpected Kubernetes auth configuration")
    test = SmokeTest(remote, client)
    print(f"Test resources: {test.run_id}; owner: {test.owner}", flush=True)
    try:
        test.preflight()
        test.provision()
        test.test_login()
        test.test_mount()
    finally:
        errors = test.cleanup()
        client.token = ""
        if errors:
            print(f"CLEANUP INCOMPLETE for {test.run_id}: {', '.join(errors)}. Inspect ownership before removal.", file=sys.stderr)
        elif test.attempted:
            print("PASS: owned temporary resources cleaned up", flush=True)
    require(not errors, "Cleanup was incomplete")
    print("PASS: OpenBao Kubernetes authentication and CSI smoke test; apps remain suspended", flush=True)
    return 0


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda signum, frame: sys.exit(143))
    try:
        sys.exit(main())
    except (Failure, KeyError, ValueError, OSError, EOFError) as error:
        # KeyError/ValueError can contain response data; print only their type.
        print("ERROR: " + (str(error) if isinstance(error, Failure) else type(error).__name__), file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("Interrupted; guarded cleanup was attempted.", file=sys.stderr)
        sys.exit(130)
