case ${SSH_ORIGINAL_COMMAND-} in
system | driver) unit="update-now@$SSH_ORIGINAL_COMMAND.service" ;;
*)
	printf 'nudge: refused %q\n' "${SSH_ORIGINAL_COMMAND-}" >&2
	exit 1
	;;
esac
status=0
systemctl start "$unit" >/dev/null 2>&1 || status=$?
systemctl show -p Result --value "$unit" || true
if [ "$SSH_ORIGINAL_COMMAND" = system ]; then
	readlink /run/current-system || true
fi
exit "$status"
