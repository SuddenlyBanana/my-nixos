# Hadal application-platform architecture update

This document records the target architecture and the decisions already made.
The executable configuration has not yet been updated to match it. Nothing on
`dev-appdeployment` has been deployed, so migration compatibility is required
only for services present on `main`.

## Target

- Run RKE2, PostgreSQL, and OpenBao in separate NixOS MicroVMs
  using microvm.nix and Cloud Hypervisor.
- Keep the physical host out of Kubernetes. Keep libvirt/Terranix for OpnSense
  and other appliance or legacy VMs.
- Run `www-domain1`, WAPmail, and Vaultwarden in RKE2.
- Replace rootless Podman on hadal after the Kubernetes cutovers have passed
  their rollback windows.
- Keep OpenBao outside Kubernetes so cluster loss does not remove the runtime
  secrets control plane.
- Manage cluster workloads from a separate private GitOps repository.

## Confirmed decisions

| Area | Decision |
| --- | --- |
| Availability | Accept a single-host, non-HA platform initially. |
| VM manager | microvm.nix with Cloud Hypervisor for RKE2, PostgreSQL, and OpenBao. |
| Container runtime | RKE2's bundled containerd. |
| CNI | RKE2-bundled Cilium, IPv6-only native routing, retaining kube-proxy initially. |
| Ingress | Traefik with a fixed NodePort behind `float-play`; public TLS stays on `float-play` initially. |
| Storage | LVM RAID1 and LVM-thin for VM volumes; prototype the exact layering on loop devices first. |
| VM cache | dm-cache in writeback mode. The increased data-loss risk is accepted. |
| Media cache | bcache in writeback mode in front of the Btrfs RAID1 members. The increased data-loss risk is accepted. |
| VM volumes | Separate `rke2-state`, `postgresql-data`, `openbao-data`, and `vaultwarden-data` thin LVs. |
| Guest filesystems | XFS directly on raw LVs; no qcow2 or raw image files inside the LVs. |
| Vaultwarden data | A static local PersistentVolume backed by the dedicated `vaultwarden-data` LV attached to the RKE2 VM. |
| OpenBao | One external OpenBao server using integrated Raft storage. |
| Unsealing | Manual Shamir unseal initially; shares are held offline and never stored on the host, in Git, or in Kubernetes. |
| Secret boundary | agenix handles machine/bootstrap secrets; OpenBao handles runtime workload secrets. |
| Kubernetes secrets | OpenBao CSI Provider and Secrets Store CSI Driver, authenticated by projected Kubernetes service-account tokens. |
| Non-Kubernetes authentication | Use narrowly scoped OpenBao AppRoles whose bootstrap material is delivered with agenix. |
| Database credentials | OpenBao database secrets engine issues dynamic PostgreSQL credentials. |
| PKI | Offline root CA with an OpenBao-managed intermediate for conventional internal TLS certificates. |
| Backup destination | Prepare NFS NAS placeholders; do not commit a real NAS address, export, credential, or encryption material here. |

## Identity and secret boundary

Kubernetes and non-Kubernetes workloads use different OpenBao authentication
paths:

- In RKE2, the OpenBao CSI Provider authenticates each pod with a projected
  service-account JWT. Give every workload a dedicated service account,
  OpenBao auth role, and least-privilege policy.
- Outside RKE2, use a distinct OpenBao AppRole per service. Deliver the initial
  RoleID and SecretID through agenix and keep policies narrowly scoped.
- OpenBao's database secrets engine creates, leases, and revokes PostgreSQL
  roles independently of either authentication path.

## Physical storage intent

Available devices are one 1 TB HDD, one 2 TB HDD divided into two 1 TB
partitions, another 1 TB HDD, and one 256 GB NVMe cache device.

- Pair one 1 TB HDD with one 1 TB partition from the 2 TB HDD for the LVM RAID1
  backing the VM thin pool.
- Pair the other 1 TB HDD with the other 1 TB partition for Btrfs RAID1 media.
- Partition the NVMe between the LVM dm-cache and the Btrfs backing-device
  bcache caches.
- Treat the NVMe as a common failure domain. In writeback mode, losing it can
  corrupt more than one cached filesystem and can defeat the apparent safety
  of the HDD mirrors.
- Keep thin-pool metadata mirrored, monitor both data and metadata usage, and
  retain unallocated VG space for repair and snapshot operations.

The exact LVM RAID, thin-pool, metadata, and cache target ordering is not yet a
production decision. It must be built, failed, recovered, and benchmarked with
loop devices before any real disk is repartitioned.

## Migration scope

The deployed source state is `main`:

- `www-domain1`: rootless Podman on hadal;
- WAPmail: Firecracker MicroVM;
- Vaultwarden: host service using SQLite under `/srv/media/vaultwarden`;
- PostgreSQL, OpenBao, and the current `dev-appdeployment` MicroVM
  storage/snapshot design: not deployed.

Vaultwarden therefore needs a real SQLite-to-PostgreSQL migration plus a copy
of its complete data directory into the new local PV. Pin the application
version during migration and do not combine the database migration with a
Vaultwarden upgrade.

## Backup placeholders

Use placeholders until the NAS design is finalized:

```text
<NAS_IPV6>
<NFS_RKE2_EXPORT>
<NFS_POSTGRESQL_EXPORT>
<NFS_OPENBAO_EXPORT>
<NFS_VAULTWARDEN_EXPORT>
<BACKUP_ENCRYPTION_KEY_REFERENCE>
<BACKUP_RETENTION_POLICY>
```

NFS is only the destination transport. RKE2 etcd snapshots, PostgreSQL
pgBackRest/WAL backups, OpenBao Raft snapshots, and
filesystem-aware Vaultwarden backups remain separate artifacts. Encrypt backup
contents before or while writing them to the NAS, and test restoration on
another machine.

## Decisions still to close

1. The exact private IPv6 node, pod, service, OpenBao, and PostgreSQL
   address allocations.
2. Results of the loop-device LVM/thin/dm-cache and Btrfs/bcache failure tests.
3. Sizes for the thin pool, its metadata, NVMe cache partitions, and all four
   LVs; preserve operational headroom rather than allocating the VG fully.
4. CPU and memory allocations for the three VMs after measurement on hadal.
5. AppRole provisioning, SecretID rotation, and revocation procedures for
   non-Kubernetes OpenBao agents.
6. The dynamic-database-credential reload strategy for each Kubernetes
   application. Vaultwarden does not gain live environment-variable updates
   from a rotated Kubernetes Secret, so lease renewal plus a controlled restart
   before maximum TTL must be proven or a local database proxy introduced.
7. Offline root operating procedure, OpenBao intermediate lifetime, certificate
   profiles, revocation publication, and OpenBao server bootstrap certificate.
8. Concrete NAS exports, authentication, client isolation, encrypted backup
   format, retention, capacity alerts, and restore host.
9. Monitoring and alert delivery for storage caches, thin-pool usage, XFS,
   RKE2/etcd, PostgreSQL, OpenBao, Cilium, Flux, and backup freshness.
10. Maintenance and disaster procedures for manually unsealing OpenBao after a
    host restart and for operating Kubernetes while OpenBao is down.
