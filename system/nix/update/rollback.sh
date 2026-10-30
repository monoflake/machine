[ "$(id -u)" = 0 ] || { echo 'update: rollback requires root' >&2; exit 1; }
driver_root=/var/lib/driver
exec 9>"$driver_root/.update-lock"
flock 9
current=$(readlink "$driver_root/current") || { echo 'update: current driver unavailable' >&2; exit 1; }
previous=$(readlink "$driver_root/previous") || { echo 'update: previous driver unavailable' >&2; exit 1; }
[ -x "$driver_root/$previous/driver-machine" ] || { echo 'update: previous binary unavailable' >&2; exit 1; }
driver_link "$previous" current
driver_link "$current" previous
if ! driver_restart; then
	driver_link "$current" current
	driver_link "$previous" previous
	driver_restart || true
	echo 'update: rollback restart failed, restored current link' >&2
	exit 1
fi
echo "update: rolled driver back to $previous"
