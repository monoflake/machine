update_driver() {
	local reason at run version last_at last_run current previous url sha directory candidate status
	driver_root=/var/lib/driver
	if [ "$dry" = false ]; then
		exec 9>"$driver_root/.update-lock"
		flock 9
	fi
	say 'fetching driver pointer'
	get "pointer/driver/$machine" "$work/pointer" || {
		status=$?
		if [ "$status" = 2 ]; then say 'no driver pointer, nothing to do'; return 0; fi
		refuse 'pointer fetch failed'
	}
	say 'fetching pointer signature'
	get "pointer/driver/$machine.sig" "$work/pointer.sig" || {
		status=$?
		if [ "$status" = 2 ]; then say 'no driver pointer, nothing to do'; return 0; fi
		refuse 'signature fetch failed'
	}
	say 'verifying driver pointer signature'
	verify_pointer "$(field .driverSigners)" driver-pointer || refuse 'invalid driver-pointer signature'
	say 'validating driver pointer'
	reason=$(update_driver_pointer "$work/pointer" "$machine" "$(date -u +%s)" "$(field .driverBuilds)") || refuse "$reason"
	at=$(jq -r .at "$work/pointer")
	run=$(jq -r .run "$work/pointer")
	version=$(jq -r .version "$work/pointer")
	if [ -f "$state" ]; then
		update_driver_pointer "$state" "$machine" "$(date -u +%s)" true >/dev/null || refuse 'recorded state malformed'
		last_at=$(jq -r .at "$state")
		last_run=$(jq -r .run "$state")
		[[ ! $at < $last_at ]] || refuse 'older at than accepted pointer'
		if [ "$at" = "$last_at" ]; then
			[ "$run" = "$last_run" ] || refuse 'equal at from another run'
			jq -S . "$state" >"$work/accepted"
			jq -S . "$work/pointer" >"$work/incoming"
			cmp -s "$work/accepted" "$work/incoming" || refuse 'accepted run changed pointer'
			say 'pointer already taken'
			return
		fi
	fi
	say 'reading the running driver'
	current=$(readlink "$driver_root/current") || current=
	if [ "${current##*/}" = "$version" ]; then
		say 'pointer is the running driver'
		if [ "$dry" = false ]; then record; fi
		return
	fi
	if [ "$dry" = true ]; then
		say 'dry run would install pointer driver'
		return
	fi
	url=$(jq -r --arg arch "$(field .architecture)" '.archives[$arch].url' "$work/pointer")
	sha=$(jq -r --arg arch "$(field .architecture)" '.archives[$arch].sha256 | ascii_downcase' "$work/pointer")
	say 'downloading driver archive'
	if [[ $url == build/driver/* ]]; then
		get "$url" "$work/archive" || refuse 'archive download failed'
	else
		curl --silent --show-error --fail --location --proto '=https' --proto-redir '=https' \
			--output "$work/archive" "$url" >"$work/download-log" 2>&1 || refuse 'archive download failed'
	fi
	say 'checking driver archive SHA-256'
	[ "$(sha256sum "$work/archive" | cut -d ' ' -f 1)" = "$sha" ] || refuse 'archive SHA-256 differs'
	say 'unpacking driver archive'
	# Only regular release files may enter the executable directory.
	tar -tzf "$work/archive" >"$work/members" 2>/dev/null || refuse 'invalid archive'
	while IFS= read -r candidate; do
		case $candidate in driver-machine | LICENSE-MIT | LICENSE-APACHE | ./driver-machine | ./LICENSE-MIT | ./LICENSE-APACHE | ./) ;;
		*) refuse 'unexpected archive member' ;; esac
	done <"$work/members"
	tar -tvzf "$work/archive" >"$work/types" 2>/dev/null || refuse 'invalid archive'
	awk 'substr($0,1,1) != "-" && !(substr($0,1,1) == "d" && $NF == "./") {exit 1}' \
		"$work/types" || refuse 'archive contains links or special files'
	directory=$(mktemp -d "$driver_root/.install.XXXXXX")
	if ! tar -xzf "$work/archive" --no-same-owner --no-same-permissions -C "$directory" 2>/dev/null ||
		[ ! -f "$directory/driver-machine" ] || [ ! -x "$directory/driver-machine" ]; then
		rm -rf "$directory"
		refuse 'archive lacks executable driver-machine'
	fi
	chmod 0755 "$directory" "$directory/driver-machine"
	previous=$(readlink "$driver_root/previous") || previous=
	# A retained version can be selected again by a newer pointer.
	if [ -d "$driver_root/$version" ]; then rm -rf "${driver_root:?}/${version:?}"; fi
	mv "$directory" "$driver_root/$version"
	say 'switching driver links'
	driver_link "$version" current
	if [ -n "$current" ]; then driver_link "$current" previous; fi
	say 'restarting driver services'
	if ! driver_restart >"$work/restart-log" 2>&1; then
		masked "$work/restart-log"
		say 'restart failed, restoring previous driver'
		if [ -n "$current" ]; then
			driver_link "$current" current
			if [ -n "$previous" ]; then driver_link "$previous" previous; else rm -f "$driver_root/previous"; fi
			driver_restart >"$work/restore-log" 2>&1 || refuse 'restart failed and driver restoration failed'
		else
			rm -f "$driver_root/current" "$driver_root/previous"
			timeout 40 systemctl stop driver-machine.service driver-machine-entry.service >"$work/restore-log" 2>&1 || true
		fi
		refuse 'driver restart failed'
	fi
	record
	say 'removing older driver versions'
	shopt -s dotglob nullglob
	for directory in "$driver_root/"*; do
		[ -d "$directory" ] && [ ! -L "$directory" ] || continue
		[ "${directory##*/}" != "$version" ] && [ "${directory##*/}" != "${current##*/}" ] || continue
		rm -rf "$directory"
	done
	say 'driver install succeeded'
}
