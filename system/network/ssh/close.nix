''
  # A present table stays through four failures and has no boot grace or login exemption.
  state=''${MACHINE_SSH_STATE:-/run/machine-ssh}
  mkdir -p "$state"
  closed=0
  if nft list table inet machine-ssh >/dev/null 2>&1; then
  	closed=1
  fi
  backend=Unknown
  reason="tailscale status unavailable"
  if status=$(tailscale status --json 2>/dev/null); then
  	backend=$(jq -er '.BackendState | select(type == "string")' <<<"$status") || backend=Unknown
  	reason="BackendState $backend"
  	if [ "$backend" = Running ]; then
  		if jq -e '.Self.Online == true' <<<"$status" >/dev/null 2>&1; then
  			if [ "$closed" = 0 ]; then
  				nft -f "$1"
  			fi
  			printf '0\n' >"$state/failures"
  			exit 0
  		fi
  		reason="Online false"
  	fi
  fi

  if [ "$closed" = 0 ]; then
  	if [ "$backend" = NeedsLogin ]; then
  		printf '0\n' >"$state/failures"
  		exit 0
  	fi
  	uptime=''${MACHINE_SSH_UPTIME:-}
  	if [ -z "$uptime" ]; then
  		read -r uptime _ </proc/uptime
  	fi
  	if ! jq -en --arg uptime "$uptime" '$uptime | tonumber > 600' >/dev/null; then
  		printf '0\n' >"$state/failures"
  		exit 0
  	fi
  fi
  failures=0
  if [ -f "$state/failures" ]; then
  	read -r failures <"$state/failures"
  fi
  case "$failures" in
  	0|1|2|3|4) failures=$((failures + 1)) ;;
  	*) failures=5 ;;
  esac
  printf '%s\n' "$failures" >"$state/failures"
  if [ "$failures" -ge 5 ]; then
  	if [ "$closed" = 1 ]; then
  		nft delete table inet machine-ssh
  	fi
  	echo "machine-ssh-close: $reason after $failures consecutive unhealthy checks, public SSH open" >&2
  	exit 1
  fi
''
