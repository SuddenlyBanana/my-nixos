start_all()
router.wait_for_unit("jool-nat64-hadal.service")
router.wait_for_unit("firewall.service")
client.wait_for_unit("network.target")
server.wait_for_unit("nginx.service")

# The test's trusted LAN stands in for the decrypted WireGuard interface.
router.succeed("ip link set eth1 down")
router.succeed("ip link set eth1 name wg0")
router.succeed("ip link set wg0 up")
client.wait_until_succeeds("ping -6 -c1 fd00:1234:9::1")

with subtest("Trusted IPv6 client reaches an IPv4-only web endpoint"):
    client.succeed("curl --fail --max-time 10 'http://[64:ff9b::cb00:7110]/' | grep 'NAT64 test passed'")

with subtest("NAT64 blocks private IPv4 destinations"):
    client.fail("curl --fail --max-time 3 'http://[64:ff9b::7f00:1]/'")

with subtest("Public-side clients cannot use the translator"):
    server.fail("curl --fail --max-time 3 'http://[64:ff9b::cb00:7110]/'")

with subtest("Firewall restart preserves scoped translation"):
    router.succeed("systemctl restart firewall.service")
    client.succeed("curl --fail --max-time 10 'http://[64:ff9b::cb00:7110]/' | grep 'NAT64 test passed'")
