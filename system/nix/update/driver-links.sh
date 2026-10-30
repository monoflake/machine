driver_link() {
	local target=$1 name=$2 staging
	staging=$(mktemp -d "$driver_root/.link.XXXXXX")
	ln -s "$target" "$staging/link"
	mv -Tf "$staging/link" "$driver_root/$name"
	rmdir "$staging"
}
driver_restart() {
	local attempt
	timeout 40 systemctl restart driver-machine.service driver-machine-entry.service || return 1
	for ((attempt=0; attempt<20; attempt++)); do
		if systemctl is-active --quiet driver-machine.service &&
			systemctl is-active --quiet driver-machine-entry.service; then return 0; fi
		sleep 1
	done
	return 1
}
