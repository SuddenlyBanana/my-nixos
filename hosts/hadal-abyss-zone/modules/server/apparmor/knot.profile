profile hadal-knot /nix/store/*-knot-dns-*/bin/knotd {
  capability net_bind_service,
  network,
  signal,

  /nix/store/** mr,
  /etc/{hosts,passwd,group,nsswitch.conf,resolv.conf,localtime} r,
  /proc/** r,
  /sys/** r,
  /dev/null rw,
  /dev/{zero,random,urandom} r,
  /dev/log w,
  /run/systemd/notify w,

  /var/lib/knot/ r,
  /var/lib/knot/** rwk,
  /run/knot/ r,
  /run/knot/** rwk,
}
