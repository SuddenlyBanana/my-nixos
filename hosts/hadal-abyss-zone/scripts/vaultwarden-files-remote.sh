#!/usr/bin/env bash
# Invoked over verified SSH by copy-vaultwarden-files.py. Never installed as a service.
set -euo pipefail
umask 077

fail() { printf 'STOP: %s\n' "$1" >&2; exit 1; }
mode=${1:?Missing operation}
pv=/var/lib/hadal-pv/vaultwarden
backup=/srv/mediabackup/vaultwarden

if [[ $mode == source ]]; then
  [[ $(hostname) == hadal-abyss-zone ]] || fail 'Wrong backup host'
  [[ $(readlink -e "$backup") == "$backup" ]] || fail 'Backup path is missing or uses a symlink'
  [[ -d $backup/attachments && ! -L $backup/attachments ]] || fail 'Missing regular attachments directory'
  [[ -f $backup/rsa_key.pem && ! -L $backup/rsa_key.pem ]] || fail 'Missing regular RSA key file'
  [[ ! -e $backup/sends && ! -L $backup/sends ]] || fail 'Sends directory needs a separate migration review'
  [[ ! -e $backup/config.json && ! -L $backup/config.json ]] || fail 'Configuration overrides need review before copying'
  unsafe=$(find "$backup/attachments" "$backup/rsa_key.pem" -xdev ! -type d ! -type f -print -quit)
  [[ -z $unsafe ]] || fail 'Source contains a symlink or special file'
  # Deterministic metadata permits a second read to detect source changes.
  # Only these two names are read. Never open/checkpoint the SQLite/WAL backup.
  tar --sort=name --format=ustar --numeric-owner --owner=1000 --group=1000 \
    '--mode=u=rwX,go=' --mtime=@0 --atime-preserve=system \
    -C "$backup" -cf - attachments rsa_key.pem | head -c 67108865
  exit 0
fi

[[ $mode == preview || $mode == copy ]] || fail 'Unknown operation'
[[ $(hostname) == rke2-server ]] || fail 'Wrong guest'
[[ $(readlink -e "$pv") == "$pv" ]] || fail 'PV path is missing or uses a symlink'
[[ $(findmnt -rn -M "$pv" -o TARGET) == "$pv" ]] || fail 'Destination is not an exact mountpoint'
[[ $(findmnt -rn -M "$pv" -o FSTYPE) == xfs ]] || fail 'Unexpected PV filesystem'
[[ $(findmnt -rn -M "$pv" -o LABEL) == vault-data ]] || fail 'Unexpected PV label'
options=$(findmnt -rn -M "$pv" -o OPTIONS)
[[ ,$options, == *,rw,* ]] || fail 'PV is not writable'

empty_pv() {
  [[ -z $(find "$pv" -mindepth 1 -maxdepth 1 -print -quit) ]] || fail 'Destination is not empty; no overwrite/retry'
}
if [[ $mode == preview ]]; then
  empty_pv
  printf 'PV_EMPTY vault-data xfs\n'
  exit 0
fi

nonce=${2:?Missing attempt identity}
expected=${3:?Missing archive hash}
count=${4:?Missing file count}
[[ $nonce =~ ^[a-f0-9]{32}$ && $expected =~ ^[a-f0-9]{64}$ && $count =~ ^[1-9][0-9]*$ ]] || fail 'Invalid copy arguments'
exec 9>/run/lock/hadal-vaultwarden-files.lock
flock -n 9 || fail 'Another filesystem copy holds the lock'
empty_pv
stage=$pv/.vw-migration-$nonce
mkdir -m 0700 -- "$stage"
trap 'printf "STOP: Copy interrupted; inspect the workstation receipt and retained stage %s. Do not retry or delete blindly.\n" "$stage" >&2' ERR

# This is a local, sanitized, size-limited archive made by the workstation,
# not a direct extraction of the backup host's tar stream.
head -c 67108865 > "$stage/payload.tar"
[[ $(stat -c %s "$stage/payload.tar") -le 67108864 ]] || fail 'Archive exceeds the 64 MiB safety limit'
actual=$(sha256sum "$stage/payload.tar")
[[ ${actual%% *} == "$expected" ]] || fail 'Transferred archive hash differs'
mkdir -m 0700 -- "$stage/payload"
tar --extract --file "$stage/payload.tar" --directory "$stage/payload" \
  --no-same-owner --no-same-permissions --keep-old-files
(
  cd "$stage/payload"
  sha256sum --check --strict --status .hadal-checksums
)
[[ $(find "$stage/payload" -type f ! -name .hadal-checksums -printf 'x\n' | wc -l) -eq $count ]] || fail 'Extracted file count differs'
chown -R -- 1000:1000 "$stage/payload/attachments" "$stage/payload/rsa_key.pem"
find "$stage/payload/attachments" -type d -exec chmod 0700 -- {} +
find "$stage/payload/attachments" -type f -exec chmod 0600 -- {} +
chmod 0600 -- "$stage/payload/rsa_key.pem"

[[ ! -e $pv/attachments && ! -L $pv/attachments && ! -e $pv/rsa_key.pem && ! -L $pv/rsa_key.pem ]] || fail 'Destination changed during copy'
# Two renames are not an atomic pair. The persistent workstation attempt
# receipt blocks a blind retry if a connection is lost between them.
mv -T --no-clobber -- "$stage/payload/attachments" "$pv/attachments"
mv -T --no-clobber -- "$stage/payload/rsa_key.pem" "$pv/rsa_key.pem"
(
  cd "$pv"
  sha256sum --check --strict --status "$stage/payload/.hadal-checksums"
)
[[ -z $(find "$pv" -mindepth 1 -maxdepth 1 ! -name attachments ! -name rsa_key.pem ! -name ".vw-migration-$nonce" -print -quit) ]] || fail 'Unexpected extra entry appeared in PV'
[[ $(find "$pv/attachments" "$pv/rsa_key.pem" \( ! -uid 1000 -o ! -gid 1000 \) -print -quit) == '' ]] || fail 'Unexpected published ownership'
chown -- 1000:1000 "$pv"
chmod 0700 -- "$pv"
sync -f "$pv"

# Remove only our now-redundant archive/checksum copies after verification.
# Never remove source data, destination files, or a stage on failure.
rm -- "$stage/payload/.hadal-checksums" "$stage/payload.tar"
rmdir -- "$stage/payload" "$stage"
sync -f "$pv"
trap - ERR
printf 'PASS_FILES %s\n' "$expected"
