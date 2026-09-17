profile hadal-unbound /nix/store/*-unbound-*/bin/unbound {
  capability net_bind_service,
  capability net_raw,
  network,
  signal,

  /nix/store/** mr,
  /etc/unbound/unbound.conf r,
  /etc/{hosts,passwd,group,nsswitch.conf,resolv.conf,localtime} r,
  /proc/** r,
  /sys/** r,
  /dev/null rw,
  /dev/{zero,random,urandom} r,
  /run/systemd/notify w,

  /var/lib/unbound/ r,
  /var/lib/unbound/** rwk,
  /run/unbound/ r,
  /run/unbound/** rwk,
}
