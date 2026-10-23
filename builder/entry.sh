# The builder's entry, run in its container by scripts/builder.res, root reached by the keys in
# KEYS, a store building for both architectures, and sshd's host key kept in the store's volume.
set -eu
export PATH=/root/.nix-profile/bin
key=/nix/var/machine-builder/ssh_host_ed25519_key
mkdir -p /nix/var/machine-builder /root/.ssh /var/empty /etc/ssh /etc/nix
[ -f $key ] || ssh-keygen -q -t ed25519 -N '' -f $key
printf '%s\n' "$KEYS" > /root/.ssh/authorized_keys
chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys

# sshd refuses a locked root and needs a user of its own.
{ echo 'root:*:1::::::' && grep -v '^root:' /etc/shadow; } > /etc/shadow.new && mv /etc/shadow.new /etc/shadow
grep -q '^sshd:' /etc/passwd || echo 'sshd:x:74:74::/var/empty:/bin/false' >> /etc/passwd
grep -q '^sshd:' /etc/group || echo 'sshd:x:74:' >> /etc/group
cat > /etc/ssh/sshd_config <<EOF
HostKey $key
PidFile none
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
SetEnv PATH=$PATH
EOF

# Docker Desktop runs x86_64 on Arm by Rosetta, which builds the same paths a native machine does.
other=
[ "$(uname -m)" != aarch64 ] || other="extra-platforms = x86_64-linux"
cat > /etc/nix/nix.conf <<EOF
build-users-group = nixbld
experimental-features = nix-command flakes
substituters = https://cache.nixos.org/
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
trusted-users = root
sandbox = true
filter-syscalls = true
max-jobs = auto
cores = 0
$other
EOF
exec "$(readlink -f /root/.nix-profile/bin/sshd)" -D -e -f /etc/ssh/sshd_config
