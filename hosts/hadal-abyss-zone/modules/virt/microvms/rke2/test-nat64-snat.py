#!/usr/bin/env python3
"""Test an evaluated nftables table against iptables MASQUERADE in private netns.

Feed networking.nftables.tables.hadal_rke2_nat64 as JSON on stdin, or an object
with nat64, infrastructure, and routes keys to test both repairs. Pass
--iptables /path/to/ip6tables (legacy or nft). Requires Linux user namespaces, nft, ip,
nsenter, and unshare. No root, real interfaces, VMs, or Internet are used.
"""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile


def run(*args, input=None):
    return subprocess.run(args, input=input, text=True, capture_output=True,
                          check=True, timeout=15).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iptables", default=shutil.which("ip6tables") or shutil.which("ip6tables-legacy"))
    parser.add_argument("--isolated", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--original-netns", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--holder", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--server", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--port", type=int, default=18080, help=argparse.SUPPRESS)
    parser.add_argument("--probe", nargs=2, metavar=("DESTINATION", "SOURCE"), help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.holder:
        print("ready", flush=True)
        sys.stdin.read()
        return
    if args.server:
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as listener:
            listener.bind(("::", args.port))
            listener.listen()
            print("ready", flush=True)
            while True:
                conn, peer = listener.accept()
                with conn:
                    conn.sendall((peer[0] + "\n").encode())
    if args.probe:
        dest, source = args.probe
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as client:
            client.settimeout(5)
            if source != "auto":
                client.bind((source, 0))
            client.connect((dest, args.port))
            print(client.recv(256).decode().strip())
        return

    if not args.iptables:
        parser.error("pass an ip6tables binary with --iptables")
    raw = sys.stdin.read()
    if not args.isolated:
        subprocess.run(["unshare", "--user", "--map-root-user", "--net",
                        sys.executable, str(Path(__file__).resolve()),
                        "--isolated", "--original-netns",
                        str(Path("/proc/self/ns/net").stat().st_ino),
                        "--iptables", args.iptables],
                       input=raw, text=True, check=True, timeout=90)
        return

    # Never touch the host's actual network namespace, even if invoked by root
    # or if someone supplies the internal flag manually.
    uid_map = Path("/proc/self/uid_map").read_text().split()
    if os.geteuid() != 0 or len(uid_map) != 3 or uid_map[0] != "0" or uid_map[1] == "0" or uid_map[2] != "1":
        raise RuntimeError("Refusing to run without a single-user, root-mapped user namespace")
    if args.original_netns is None or Path("/proc/self/ns/net").stat().st_ino == args.original_netns:
        raise RuntimeError("Refusing to run without a new private network namespace")

    evaluated = json.loads(raw)
    table = evaluated.get("nat64", evaluated)
    infrastructure = evaluated.get("infrastructure")
    assert table["family"] == "ip6" and table["name"] == "hadal_rke2_nat64"
    content = table["content"]
    match = re.search(r'ip6 saddr (\S+) ip6 daddr (\S+) counter snat to (\S+)', content)
    assert match, "Expected the scoped source/destination/SNAT rule"
    pod_net, nat64_net, node = match.groups()
    assert 'oifname "ens5"' in content
    assert "priority srcnat - 1" in content
    pod_network = ipaddress.IPv6Network(pod_net)
    nat64_network = ipaddress.IPv6Network(nat64_net)
    node_network = ipaddress.IPv6Network(f"{node}/64", strict=False)
    pod = str(pod_network.network_address + 0x123)
    pod_router = str(pod_network.network_address + 1)
    upstream = str(node_network.network_address + 1)
    temporary_source = str(node_network.network_address + 0xfdfdaff721275d64)
    services = []
    if infrastructure:
        assert infrastructure["family"] == "ip6"
        assert infrastructure["name"] == "hadal_rke2_infrastructure"
        assert "priority srcnat - 1" in infrastructure["content"]
        services = re.findall(
            r'oifname "ens5" ip6 saddr (\S+) ip6 daddr (\S+) tcp dport (\d+) counter snat to (\S+)',
            infrastructure["content"])
        assert len(services) == 2 and {int(s[2]) for s in services} == {8200, 5432}
        assert all(s[0] == pod_net and s[3] == node for s in services)
        infra_route, = [r for r in evaluated["routes"] if all(
            ipaddress.IPv6Address(s[1]) in ipaddress.IPv6Network(r["Destination"])
            for s in services)]
        assert infra_route["Gateway"] == upstream and infra_route["PreferredSource"] == node
    nat64_dest = str(nat64_network.network_address + int(ipaddress.IPv4Address("192.0.2.10")))
    native_dest = "2001:db8:2::1"
    global_source = "2001:db8:1::20"
    outside_source = "fd00:dead:beef::123"
    script = str(Path(__file__).resolve())
    processes = []

    def start(*command):
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        processes.append(process)
        assert process.stdout.readline().strip() == "ready"
        return process

    def ns(process, *command):
        return ("nsenter", f"--net=/proc/{process.pid}/ns/net", "--", *command)

    def addr(process, device, address, prefix):
        command = ("ip", "-6", "addr", "add", f"{address}/{prefix}", "dev", device, "nodad")
        run(*(ns(process, *command) if process else command))

    def probe(process, destination, source="auto", port=18080):
        if process is not None and source == "auto":
            source = pod
        command = (sys.executable, script, "--probe", destination, source, "--port", str(port))
        return run(*(ns(process, *command) if process else command))

    def iptables(*command):
        return run(args.iptables, "-w", "5", "-t", "nat", *command)

    def generic_masquerade():
        iptables("-A", "CILIUM_POST_nat", "-s", pod_net, "-o", "ens5", "-j", "MASQUERADE")

    runtime_dir = tempfile.TemporaryDirectory(prefix="hadal-nat64-snat-test-")
    # xtables normally locks a root-owned host file even from a private netns.
    # Give these private rules their own lock without touching /run/xtables.lock.
    os.environ["XTABLES_LOCKFILE"] = str(Path(runtime_dir.name) / "xtables.lock")
    try:
        pod_ns = start("unshare", "--net", sys.executable, script, "--holder")
        server_ns = start("unshare", "--net", sys.executable, script, "--holder")
        for process in (None, pod_ns, server_ns):
            command = ("ip", "link", "set", "lo", "up")
            run(*(ns(process, *command) if process else command))
        for local, peer, process in (("lxc-test", "pod0", pod_ns), ("ens5", "server0", server_ns)):
            run("ip", "link", "add", local, "type", "veth", "peer", "name", peer)
            run("ip", "link", "set", peer, "netns", str(process.pid))
            run("ip", "link", "set", local, "up")
            run(*ns(process, "ip", "link", "set", peer, "up"))
        addr(None, "lxc-test", pod_router, 64)
        addr(pod_ns, "pod0", pod, 64)
        addr(pod_ns, "pod0", outside_source, 64)
        addr(None, "ens5", node, 64)
        addr(None, "ens5", global_source, 64)
        if infrastructure:
            addr(None, "ens5", temporary_source, 64)
        addr(server_ns, "server0", upstream, 64)
        addr(server_ns, "server0", "2001:db8:1::1", 64)
        addr(server_ns, "lo", nat64_dest, 128)
        addr(server_ns, "lo", native_dest, 128)
        for _, destination, _, _ in services:
            addr(server_ns, "lo", destination, 128)
        run("sysctl", "-qw", "net.ipv6.conf.all.forwarding=1")
        run(*ns(pod_ns, "ip", "-6", "route", "add", "default", "via", pod_router))
        run(*ns(server_ns, "ip", "-6", "route", "add", "default", "via", node))
        run("ip", "-6", "route", "add", nat64_net, "via", upstream, "dev", "ens5", "src", node)
        run("ip", "-6", "route", "add", "2001:db8:2::/64", "via", upstream)
        run("ip", "-6", "route", "add", "fd00:dead:beef::/64", "dev", "lxc-test")
        if infrastructure:
            run("ip", "-6", "route", "add", infra_route["Destination"], "via", upstream,
                "dev", "ens5", "src", node)
        start(*ns(server_ns, sys.executable, script, "--server"))
        for port in sorted({int(s[2]) for s in services}):
            start(*ns(server_ns, sys.executable, script, "--server", "--port", str(port)))

        iptables("-N", "CILIUM_POST_nat")
        iptables("-A", "POSTROUTING", "-j", "CILIUM_POST_nat")
        generic_masquerade()
        assert probe(None, nat64_dest) == node, "Node PreferredSource must work before the fix"
        baseline = probe(pod_ns, nat64_dest)
        assert baseline == global_source, f"Reproduce pod MASQUERADE ignoring PreferredSource, got {baseline}"
        print("PASS: reproduced node ULA success versus pod global-address masquerading", flush=True)
        for _, destination, port, _ in services:
            assert probe(None, destination, port=int(port)) == node
            baseline = probe(pod_ns, destination, port=int(port))
            assert baseline == temporary_source, f"Expected temporary pod MASQUERADE source, got {baseline}"
        if infrastructure:
            print("PASS: infrastructure route pins node source; generic pod MASQUERADE does not", flush=True)

        rules = f'table ip6 {table["name"]} {{\n{content}\n}}\n'
        run("nft", "-f", "-", input=rules)
        if infrastructure:
            infra_rules = f'table ip6 {infrastructure["name"]} {{\n{infrastructure["content"]}\n}}\n'
            run("nft", "-f", "-", input=infra_rules)
            for _, destination, port, _ in services:
                assert probe(pod_ns, destination, port=int(port)) == node
                assert probe(pod_ns, destination, outside_source, port=int(port)) == outside_source
                assert probe(pod_ns, destination) != node, "Unrelated ports must retain generic MASQUERADE"
            print("PASS: only pod OpenBao/PostgreSQL service flows use the fixed node ULA", flush=True)
        assert probe(pod_ns, nat64_dest) == node
        assert probe(pod_ns, native_dest) == global_source
        assert probe(pod_ns, nat64_dest, outside_source) == outside_source
        print("PASS: NAT64 uses node ULA; native IPv6 and non-pod sources are unchanged", flush=True)

        iptables("-F", "CILIUM_POST_nat")
        generic_masquerade()
        assert probe(pod_ns, nat64_dest) == node
        before = iptables("-S", "CILIUM_POST_nat")
        # The same create/delete/recreate transaction used by NixOS tables.
        run("nft", "-f", "-", input=f'table ip6 {table["name"]}\ndelete table ip6 {table["name"]}\n{rules}')
        assert iptables("-S", "CILIUM_POST_nat") == before
        assert probe(pod_ns, nat64_dest) == node
        if infrastructure:
            run("nft", "-f", "-", input=(
                f'table ip6 {infrastructure["name"]}\ndelete table ip6 {infrastructure["name"]}\n{infra_rules}'))
            for _, destination, port, _ in services:
                assert probe(pod_ns, destination, port=int(port)) == node
            assert iptables("-S", "CILIUM_POST_nat") == before
        print("PASS: survives Cilium-chain recreation and nftables reload without altering Cilium rules", flush=True)
    finally:
        for process in reversed(processes):
            process.terminate()
        for process in reversed(processes):
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        runtime_dir.cleanup()


if __name__ == "__main__":
    try:
        main()
    except subprocess.CalledProcessError as error:
        print(error.stdout or "", error.stderr or "", file=sys.stderr)
        raise
