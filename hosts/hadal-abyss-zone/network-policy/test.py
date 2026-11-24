#!/usr/bin/env python3
"""Check evaluated host policy; optionally test packets in private namespaces.

Static check (also the flake check): --config policy.json
Packet checks: --config policy.json --run-network
The packet test needs nft, ip, sysctl, unshare, nsenter, and user namespaces.
It never changes the host network or connects to real hosts.
"""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import selectors
import socket
import struct
import subprocess
import sys


def run(*args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, timeout=20, **kwargs)
    if result.returncode:
        raise RuntimeError(f"Test command {args!r} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def check_config(c):
    assert c["wireguardInterfaces"] == ["wg0"], "No Hadal remote-access tunnel"
    assert not c["backupsEnabled"] and not c["snapshotsEnabled"], "No NAS push backups"
    zones = c["zones"]
    assert zones["internal"]["prefix"] == "fd00:23ff:8e75::/48"
    assert zones["internal"]["nasAddress"] == "fd00:23ff:8e75:7::10"
    assert zones["internal"]["backupHost"] == "fd00:23ff:8e75:7::11"
    assert zones["remoteAccess"]["prefix"] == "fd2d:b57c:c77b:ffff::/64"
    for prefix in (zones["internal"]["prefix"], zones["remoteAccess"]["prefix"]):
        route, = [r for r in c["routes"] if r.get("Destination") == prefix]
        assert route["Gateway"] == c["gateway"]
        assert route["PreferredSource"] == c["hostAddress"]
    guard = c["tables"]["hadal-zone-boundary"]
    assert guard["family"] == "inet"
    assert "hook output priority filter - 5" in guard["content"]
    assert "hook forward priority filter - 5" in guard["content"]
    assert "ct state { established, related } return" in guard["content"]
    assert "packet-too-big" in guard["content"] and "counter drop" in guard["content"]
    assert zones["internal"]["prefix"] in guard["content"]
    assert zones["remoteAccess"]["prefix"] in guard["content"]
    assert "internal routed networks" not in c["forwardRules"]
    assert 'oifname "wg0"' in c["forwardRules"] and c["nat64"]["prefix"] in c["forwardRules"]
    assert 'oifname "br-lan" ip6 daddr 2000::/3' in c["forwardRules"]
    assert zones["internal"]["backupHost"] + "/128" in c["inputRules"]
    assert zones["internal"]["prefix"] not in c["inputRules"]
    assert zones["remoteAccess"]["prefix"] not in c["inputRules"]
    assert c["floatAddress"] + "/128" in c["inputRules"]
    print("PASS: evaluated zones, return routes, scoped permissions, and disabled push backups", flush=True)


def require_private_network(original_netns):
    # Also used by every socket/namespace worker, not just the orchestrator.
    uid_map = Path("/proc/self/uid_map").read_text().split()
    assert os.geteuid() == 0 and len(uid_map) == 3
    assert uid_map[0] == "0" and uid_map[1] != "0" and uid_map[2] == "1"
    assert original_netns is not None
    assert Path("/proc/self/ns/net").stat().st_ino != original_netns


def server():
    selector = selectors.DefaultSelector()
    listeners = []
    for port in (22, 25, 53, 2525, 5432, 6443, 8200, 18080,
                 30025, 30080, 30443, 30465, 30808, 30993):
        listener = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("::", port))
        listener.listen()
        selector.register(listener, selectors.EVENT_READ, "tcp")
        listeners.append(listener)
    for port in (53, 18080):
        listener = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        listener.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_RECVPKTINFO, 1)
        listener.bind(("::", port))
        selector.register(listener, selectors.EVENT_READ, "udp")
        listeners.append(listener)
    print("ready", flush=True)
    while True:
        for key, _ in selector.select():
            if key.data == "udp":
                _, ancillary, _, peer = key.fileobj.recvmsg(256, 256)
                # Reply from the destination alias, not the namespace's primary
                # address: connected UDP clients reject another source address.
                pktinfo = [item for item in ancillary
                           if item[:2] == (socket.IPPROTO_IPV6, socket.IPV6_PKTINFO)]
                key.fileobj.sendmsg([b"ok\n"], pktinfo, 0, peer)
            else:
                conn, _ = key.fileobj.accept()
                with conn:
                    conn.sendall(b"ok\n")


def probe(destination, port, source, udp=False):
    with socket.socket(socket.AF_INET6, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM) as client:
        client.settimeout(0.7)
        if source != "auto":
            client.bind((source, 0))
        client.connect((destination, int(port)))
        if udp:
            client.send(b"probe")
        assert client.recv(3) == b"ok\n"


def icmp_error(destination):
    with socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6) as client:
        # Synthetic Packet Too Big, intentionally not an established TCP reply.
        client.sendto(struct.pack("!BBHI", 2, 0, 0, 1280) + bytes(40), (destination, 0))


def receive_icmp_error():
    with socket.socket(socket.AF_INET6, socket.SOCK_RAW, socket.IPPROTO_ICMPV6) as listener:
        listener.settimeout(5)
        print("ready", flush=True)
        while True:
            data, _ = listener.recvfrom(4096)
            if data and data[0] == 2:
                print("received", flush=True)
                return


def packet_tests(c, original_netns):
    # Must be the owner of a fresh, single-user namespace, never host root.
    require_private_network(original_netns)
    os.environ["HADAL_TEST_ORIGINAL_NETNS"] = str(original_netns)
    script = str(Path(__file__).resolve())
    processes = []

    def start(*command):
        p = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             text=True)
        processes.append(p)
        assert p.stdout.readline().strip() == "ready", "Test process failed to start"
        return p

    def ns(process, *command):
        if process is None:
            return command
        return ("nsenter", f"--net=/proc/{process.pid}/ns/net", "--", *command)

    def address(process, device, ip, prefix=128):
        run(*ns(process, "ip", "-6", "addr", "add", f"{ip}/{prefix}",
                "dev", device, "nodad"))

    def connect(process, destination, port=18080, source="auto", *, allowed=True, udp=False):
        result = subprocess.run(ns(process, sys.executable, script, "--probe",
                                   destination, str(port), source, *(["--udp"] if udp else [])),
                                capture_output=True, text=True, timeout=5)
        assert (result.returncode == 0) == allowed, (
            f"Unexpected {'allow' if result.returncode == 0 else 'deny'}: "
            f"{source} -> {destination}:{port}; {result.stderr[-300:]}"
        )

    def apply_policy():
        chunks = []
        for name, table in c["tables"].items():
            family = table["family"]
            chunks.append(f"table {family} {name}\n"
                          f"delete table {family} {name}\n"
                          f"table {family} {name} {{\n{table['content']}\n}}\n")
        rules = "\n".join(chunks)
        run("nft", "--check", "-f", "-", input=rules)
        run("nft", "-f", "-", input=rules)

    t = c["topology"]
    host = c["hostAddress"]
    gateway = c["gateway"]
    node = t["service"]["rke2Address"]
    web_host = t["service"]["hostAddress"]
    db_host = t["infrastructure"]["hostAddress"]
    pg = t["infrastructure"]["postgresqlAddress"]
    bao = t["infrastructure"]["openbaoAddress"]
    pod = str(ipaddress.IPv6Network(t["cluster"]["podCidr"]).network_address + 0x123)
    internal = c["zones"]["internal"]
    nas = internal["nasAddress"]
    ipace = internal["backupHost"]
    other = str(ipaddress.IPv6Address(ipace) + 1)
    vpn = str(ipaddress.IPv6Network(c["zones"]["remoteAccess"]["prefix"]).network_address + 0x10)
    public = "2001:db8:80::1"
    web_gua = "2001:db8:9::20"
    nat64 = str(ipaddress.IPv6Network(c["nat64"]["prefix"]).network_address + 0xc6336401)
    lan_client = str(ipaddress.IPv6Network(c["lanPrefix"]).network_address + 0x50)

    try:
        peers = {}
        for name in ("br-lan", "br-web", "br-db", "wg0"):
            p = start("unshare", "--net", sys.executable, script, "--holder")
            peers[name] = p
            run("ip", "link", "add", name, "type", "veth", "peer", "name", "peer0")
            run("ip", "link", "set", "peer0", "netns", str(p.pid))
            run("ip", "link", "set", name, "up")
            run(*ns(p, "ip", "link", "set", "peer0", "up"))
            run(*ns(p, "ip", "link", "set", "lo", "up"))
            # Avoid unrelated router-advertisement behavior in this test fabric.
            run(*ns(p, "sysctl", "-qw", "net.ipv6.conf.all.accept_ra=0"))
        lan, web, db, wg = (peers[n] for n in ("br-lan", "br-web", "br-db", "wg0"))
        run("ip", "link", "set", "lo", "up")
        run("sysctl", "-qw", "net.ipv6.conf.all.forwarding=1")
        address(None, "br-lan", host, 64)
        address(None, "br-lan", "2001:db8:8::2", 64)
        address(lan, "peer0", gateway, 64)
        address(lan, "peer0", lan_client, 64)
        for ip in (nas, ipace, other, vpn, public):
            address(lan, "lo", ip)
        address(None, "br-web", web_host, 64)
        address(None, "br-web", "2001:db8:9::1", 64)
        address(web, "peer0", node, 64)
        address(web, "peer0", web_gua, 64)
        address(web, "lo", pod)
        address(None, "br-db", db_host, 64)
        address(db, "peer0", pg, 64)
        address(db, "peer0", bao, 64)
        address(None, "wg0", c["tunnelAddress"], 64)
        address(wg, "peer0", c["floatAddress"], 64)
        address(wg, "lo", nat64)
        for process, gateway_ip in ((lan, host), (web, web_host), (db, db_host), (wg, c["tunnelAddress"])):
            run(*ns(process, "ip", "-6", "route", "add", "default", "via", gateway_ip))
        run("ip", "-6", "route", "add", "default", "via", gateway)
        run("ip", "-6", "route", "add", t["cluster"]["podCidr"], "via", node)
        run("ip", "-6", "route", "add", c["nat64"]["prefix"], "via", c["floatAddress"])
        for prefix in (internal["prefix"], c["zones"]["remoteAccess"]["prefix"]):
            run("ip", "-6", "route", "add", prefix, "via", gateway, "src", host)
        for process in (None, lan, web, db, wg):
            start(*ns(process, sys.executable, script, "--server"))

        # Positive controls: all target listeners work before filtering.
        for destination in (nas, other, vpn, public, pg, bao, node, nat64):
            connect(None, destination)
        connect(None, nas, udp=True)
        apply_policy()

        for source in (node, pod, web_gua):
            for destination in (nas, other, vpn):
                connect(web, destination, source=source, allowed=False)
        for process, source in ((None, host), (None, "2001:db8:8::2"),
                                (db, pg), (wg, c["floatAddress"])):
            for destination in (nas, vpn):
                connect(process, destination, source=source, allowed=False)
        connect(None, nas, allowed=False, udp=True)
        connect(web, nas, source=node, allowed=False, udp=True)
        run(*ns(web, "ping", "-6", "-c1", "-W1", public))
        result = subprocess.run(ns(web, "ping", "-6", "-c1", "-W1", nas),
                                capture_output=True, timeout=4)
        assert result.returncode != 0, "NixOS's generic ICMP allow must not bypass the boundary"
        receiver = start(*ns(lan, sys.executable, script, "--icmp-listen"))
        run(sys.executable, script, "--icmp-error", nas)
        output, _ = receiver.communicate(timeout=7)
        assert receiver.returncode == 0 and output.strip() == "received", "PMTU errors must pass"
        print("PASS: host, node ULA/GUA, pods, DB and WG cannot initiate into protected zones", flush=True)

        # Simulate a later accidental DNAT port-forward. The earlier guard must
        # still win over NixOS's generic 'ct status dnat accept'.
        run("nft", "-f", "-", input=f'''table ip6 test_dnat {{
          chain pre {{ type nat hook prerouting priority dstnat;
            iifname "br-web" ip6 daddr {web_host} tcp dport 20000 dnat to [{nas}]:18080
          }}
        }}''')
        connect(web, web_host, 20000, node, allowed=False)
        print("PASS: DNAT and generic ICMP forwarding cannot bypass the internal deny", flush=True)

        connect(lan, host, 22, ipace)
        connect(lan, host, 22, other, allowed=False)
        connect(lan, host, 22, vpn, allowed=False)
        connect(lan, host, 22, lan_client)
        connect(wg, host, 22, c["floatAddress"])
        connect(wg, host, 53, c["floatAddress"])
        connect(wg, host, 53, c["floatAddress"], udp=True)
        connect(wg, node, 30080, c["floatAddress"])
        for port in (30025, 30465, 30993, 30443, 30808):
            connect(wg, node, port, c["floatAddress"])
        connect(wg, node, 6443, c["floatAddress"], allowed=False)
        connect(wg, pg, 5432, c["floatAddress"], allowed=False)
        print("PASS: ipace SSH/replies and existing management/float ingress remain scoped", flush=True)

        connect(web, c["floatAddress"], 2525, node)
        for source in (pod, web_gua):
            connect(web, c["floatAddress"], 2525, source, allowed=False)
        connect(lan, c["floatAddress"], 2525, lan_client, allowed=False)
        connect(web, c["floatAddress"], 25, node, allowed=False)
        print("PASS: mail ingress and the tunnel SMTP relay are source- and port-scoped", flush=True)

        for source in (node, pod, web_gua):
            connect(web, public, source=source)
        connect(web, public, source=web_gua, udp=True)
        for source in (node, pod):
            connect(web, nat64, source=source)
            connect(web, pg, 5432, source)
            connect(web, bao, 8200, source)
        connect(db, node, 6443, bao)
        connect(lan, pg, 5432, lan_client)
        connect(lan, pg, 5432, ipace, allowed=False)
        connect(web, pg, 22, node, allowed=False)
        print("PASS: native IPv6, NAT64, PostgreSQL, OpenBao, and API authentication flows", flush=True)

        # A local temporary rule must not be able to override the separate
        # boundary. Ruleset reloads must preserve the same positive/negative behavior.
        run("nft", "add", "rule", "inet", "nixos-fw", "forward-allow", "accept")
        connect(web, nas, source=node, allowed=False)
        apply_policy()
        connect(lan, host, 22, ipace)
        connect(web, public, source=web_gua)
        connect(web, nat64, source=node)
        connect(wg, node, 30080, c["floatAddress"])
        connect(None, nas, source=host, allowed=False)
        print("PASS: boundary survives a broad later allow and atomic firewall reload", flush=True)
    finally:
        for p in reversed(processes):
            p.terminate()
        for p in processes:
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config")
    parser.add_argument("--run-network", action="store_true")
    parser.add_argument("--isolated", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--original-netns", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--holder", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--server", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--probe", nargs=3, help=argparse.SUPPRESS)
    parser.add_argument("--udp", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--icmp-error", help=argparse.SUPPRESS)
    parser.add_argument("--icmp-listen", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.holder or args.server or args.probe or args.icmp_error or args.icmp_listen:
        original = os.environ.get("HADAL_TEST_ORIGINAL_NETNS")
        require_private_network(int(original) if original is not None else None)
    if args.holder:
        print("ready", flush=True)
        sys.stdin.read()
        return
    if args.server:
        server()
        return
    if args.probe:
        probe(*args.probe, udp=args.udp)
        return
    if args.icmp_error:
        icmp_error(args.icmp_error)
        return
    if args.icmp_listen:
        receive_icmp_error()
        return
    if not args.config:
        parser.error("--config is required")
    c = json.loads(Path(args.config).read_text())
    check_config(c)
    if args.run_network:
        if args.isolated:
            packet_tests(c, args.original_netns)
        else:
            subprocess.run([
                "unshare", "--user", "--map-root-user", "--net", sys.executable,
                str(Path(__file__).resolve()), "--config", str(Path(args.config).resolve()),
                "--run-network", "--isolated", "--original-netns",
                str(Path("/proc/self/ns/net").stat().st_ino),
            ], check=True, timeout=150)


if __name__ == "__main__":
    main()
