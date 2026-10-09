#!/usr/bin/env bash
#
# Installer for battctl - MacBook battery charge limit manager.
#
# Usage:
#   sudo ./install.sh [--limit N]   install (limit defaults to 80 if no config exists)
#   sudo ./install.sh uninstall     remove battctl and reset the limit to 100%
#   ./install.sh status             show current state
#
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN=/usr/local/bin/battctl
CONF=/etc/battctl.conf
UNIT=/etc/systemd/system/battctl.service
UDEV_RULE=/etc/udev/rules.d/99-battctl-power.rules
SLEEP_HOOK=/usr/lib/systemd/system-sleep/99-battctl
POLKIT_RULE=/etc/polkit-1/rules.d/49-battctl.rules

ACTION=install
LIMIT=""

die() { echo "install.sh: $*" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "this needs root - run: sudo $0 ${ACTION}"; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		install|uninstall|status) ACTION="$1" ;;
		--limit) LIMIT="${2:?--limit needs a value}"; shift ;;
		--limit=*) LIMIT="${1#--limit=}" ;;
		-h|--help) sed -n '3,9p' "$0"; exit 0 ;;
		*) die "unknown argument: $1" ;;
	esac
	shift
done

if [[ -n $LIMIT ]]; then
	[[ $LIMIT =~ ^[0-9]+$ ]] || die "--limit must be a number"
	(( LIMIT >= 10 && LIMIT <= 100 )) || die "--limit must be between 10 and 100"
fi

case "$ACTION" in
status)
	[[ -x $BIN ]] && "$BIN" status || echo "battctl is not installed"
	echo
	systemctl --no-pager --full status battctl.service 2>/dev/null | head -n 12 || true
	;;

uninstall)
	need_root
	if [[ -x $BIN ]]; then
		echo "==> Resetting the charge limit to 100%"
		"$BIN" set 100 || true
	fi
	echo "==> Disabling and removing units"
	systemctl disable --now battctl.service 2>/dev/null || true
	rm -f "$UNIT" "$UDEV_RULE" "$SLEEP_HOOK" "$BIN" "$POLKIT_RULE"
	systemctl daemon-reload
	udevadm control --reload-rules
	echo "Removed battctl. $CONF was kept (delete it manually if you want)."
	;;

install)
	need_root
	[[ -f $DIR/battctl.c ]] || die "battctl.c not found next to this script"

	if [[ ! -x $DIR/battctl ]]; then
		echo "==> Building battctl"
		if [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then
			sudo -u "$SUDO_USER" make -C "$DIR"
		else
			make -C "$DIR"
		fi
	fi

	echo "==> Installing $BIN"
	install -Dm755 "$DIR/battctl" "$BIN"
	install -Dm644 "$DIR/battctl.service" "$UNIT"
	install -Dm644 "$DIR/99-battctl-power.rules" "$UDEV_RULE"
	install -Dm755 "$DIR/99-battctl" "$SLEEP_HOOK"
	if [[ -f $DIR/49-battctl.rules ]]; then
		install -Dm644 "$DIR/49-battctl.rules" "$POLKIT_RULE"
	fi

	if [[ ! -f $CONF ]]; then
		echo "==> Creating $CONF (limit ${LIMIT:-80}%)"
		printf '# battctl configuration\n# charge_limit is the requested level in %% (100 = no limit).\ncharge_limit=%s\n' "${LIMIT:-80}" > "$CONF"
		chmod 644 "$CONF"
	fi

	systemctl daemon-reload
	udevadm control --reload-rules

	echo "==> Probing firmware and applying the limit"
	"$BIN" detect
	if [[ -n $LIMIT ]]; then
		"$BIN" set "$LIMIT"
	else
		"$BIN" apply
	fi

	echo "==> Enabling boot service"
	systemctl enable battctl.service >/dev/null
	echo "    boot service enabled; sleep hook and AC udev rule installed"

	echo
	"$BIN" status
	;;
esac
