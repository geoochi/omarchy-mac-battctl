// SPDX-License-Identifier: MIT
/*
 * battctl - battery charge limit manager for Apple Silicon MacBooks running
 *           Linux with the macsmc power_supply driver.
 *
 * The macsmc driver exposes charge_control_end_threshold as a writeable
 * sysfs attribute. The value is programmed into the SMC firmware, which then
 * enforces the limit by itself - including while Linux is suspended (lid
 * closed / s2idle), because the OS is not part of the control loop.
 *
 * Two firmware generations are supported by the driver:
 *   CHWA (modern): fixed 80% limit flag. Values <= 95 -> 80%, 96..100 -> 100%.
 *   CHLS (older) : end threshold configurable 10-99%; the recharge point is
 *                  fixed at end - 5. The driver also forces discharge to the
 *                  limit, so the battery comes down to it even while on AC.
 *
 * The firmware mode is probed with a single write (90) + read-back, then the
 * configured limit is restored.
 */

#define _GNU_SOURCE

#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define VERSION "1.0"

#define PS_DIR         "/sys/class/power_supply"
#define BAT_DIR        PS_DIR "/macsmc-battery"
#define END_PATH       BAT_DIR "/charge_control_end_threshold"
#define START_PATH     BAT_DIR "/charge_control_start_threshold"
#define CAP_PATH       BAT_DIR "/capacity"
#define STATUS_PATH    BAT_DIR "/status"
#define AC_ONLINE_PATH PS_DIR "/macsmc-ac/online"

#define CONFIG_PATH    "/etc/battctl.conf"

#define CHWA_FIXED_END 80
#define CHWA_WRITE_MAX 95
#define CHLS_MIN_END   10
#define HYSTERESIS     5

enum fw_mode { FW_UNKNOWN = 0, FW_CHWA, FW_CHLS };

struct config {
	bool have_limit;
	int charge_limit;
	enum fw_mode mode;
};

static const char *mode_name(enum fw_mode mode)
{
	switch (mode) {
	case FW_CHWA: return "chwa";
	case FW_CHLS: return "chls";
	default:      return "unknown";
	}
}

static const char *mode_desc(enum fw_mode mode)
{
	switch (mode) {
	case FW_CHWA: return "fixed 80% limit";
	case FW_CHLS: return "variable 10-99% limit";
	default:      return "not detected";
	}
}

static int read_int(const char *path, int *out)
{
	char buf[64];
	ssize_t n;
	int fd, saved;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	n = read(fd, buf, sizeof(buf) - 1);
	saved = errno;
	close(fd);
	if (n <= 0) {
		errno = saved;
		return -1;
	}
	buf[n] = '\0';

	char *end;
	errno = 0;
	long v = strtol(buf, &end, 10);
	if (errno != 0 || end == buf)
		return -1;
	*out = (int)v;
	return 0;
}

static int read_str(const char *path, char *buf, size_t len)
{
	ssize_t n;
	int fd, saved;

	fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	n = read(fd, buf, len - 1);
	saved = errno;
	close(fd);
	if (n <= 0) {
		errno = saved;
		return -1;
	}
	buf[n] = '\0';
	while (n > 0 && isspace((unsigned char)buf[n - 1]))
		buf[--n] = '\0';
	return 0;
}

static int write_int(const char *path, int value)
{
	char buf[32];
	ssize_t n;
	int fd, saved, len;

	len = snprintf(buf, sizeof(buf), "%d\n", value);
	fd = open(path, O_WRONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	n = write(fd, buf, (size_t)len);
	saved = errno;
	close(fd);
	if (n != len) {
		errno = saved != 0 ? saved : EIO;
		return -1;
	}
	return 0;
}

static int config_load(struct config *cfg)
{
	char line[256];
	FILE *f;

	cfg->have_limit = false;
	cfg->charge_limit = 0;
	cfg->mode = FW_UNKNOWN;

	f = fopen(CONFIG_PATH, "r");
	if (!f)
		return errno == ENOENT ? 0 : -1;

	while (fgets(line, sizeof(line), f)) {
		char *s = line;
		char word[32];
		int v;

		while (isspace((unsigned char)*s))
			s++;
		if (*s == '#' || *s == '\0')
			continue;
		if (sscanf(s, "charge_limit=%d", &v) == 1) {
			cfg->charge_limit = v;
			cfg->have_limit = true;
		} else if (sscanf(s, "firmware_mode=%31s", word) == 1) {
			if (strcmp(word, "chwa") == 0)
				cfg->mode = FW_CHWA;
			else if (strcmp(word, "chls") == 0)
				cfg->mode = FW_CHLS;
		}
	}
	fclose(f);
	return 0;
}

static int config_save(const struct config *cfg)
{
	FILE *f = fopen(CONFIG_PATH, "w");

	if (!f)
		return -1;
	fprintf(f, "# battctl configuration - MacBook battery charge limit\n");
	fprintf(f, "# charge_limit is the requested level in %% (100 = no limit).\n");
	if (cfg->have_limit)
		fprintf(f, "charge_limit=%d\n", cfg->charge_limit);
	else
		fprintf(f, "#charge_limit=80\n");
	fprintf(f, "firmware_mode=%s\n", mode_name(cfg->mode));
	if (ferror(f) || fclose(f) != 0) {
		if (!ferror(f))
			errno = EIO;
		return -1;
	}
	return 0;
}

/* Effective value to write for a requested limit on the given firmware. */
static int effective_limit(enum fw_mode mode, int requested)
{
	if (requested >= 100)
		return 100;
	if (mode == FW_CHWA)
		return requested <= CHWA_WRITE_MAX ? CHWA_FIXED_END : 100;
	if (mode == FW_CHLS)
		return requested < CHLS_MIN_END ? CHLS_MIN_END : requested;
	return -1;
}

/* Probe the firmware mode with a throwaway write; the caller restores the
 * configured limit afterwards. */
static int resolve_mode(struct config *cfg, bool force, bool verbose)
{
	enum fw_mode detected;
	int back;

	if (cfg->mode != FW_UNKNOWN && !force)
		return 0;

	if (write_int(END_PATH, 90) != 0) {
		fprintf(stderr, "battctl: cannot write to %s: %s\n", END_PATH, strerror(errno));
		if (errno == EACCES)
			fprintf(stderr, "battctl: permission denied - run with sudo.\n");
		return -1;
	}
	if (read_int(END_PATH, &back) != 0) {
		fprintf(stderr, "battctl: cannot read %s: %s\n", END_PATH, strerror(errno));
		return -1;
	}

	if (back == 90)
		detected = FW_CHLS;	/* value is stored verbatim */
	else if (back == 80)
		detected = FW_CHWA;	/* clamped to the fixed limit */
	else {
		fprintf(stderr, "battctl: firmware probe: unexpected value %d (expected 80 or 90)\n", back);
		return -1;
	}

	cfg->mode = detected;
	if (verbose)
		printf("Detected firmware charge-limit mode: %s (%s)\n",
		       mode_name(detected), mode_desc(detected));
	if (config_save(cfg) != 0)
		fprintf(stderr, "battctl: warning: could not save %s: %s\n", CONFIG_PATH, strerror(errno));
	return 0;
}

/* Write a value and return what the firmware actually reports. */
static int write_and_verify(int value)
{
	int actual;

	if (write_int(END_PATH, value) != 0) {
		fprintf(stderr, "battctl: cannot write '%d' to %s: %s\n", value, END_PATH, strerror(errno));
		if (errno == EACCES)
			fprintf(stderr, "battctl: permission denied - run with sudo.\n");
		return -1;
	}
	if (read_int(END_PATH, &actual) != 0) {
		fprintf(stderr, "battctl: cannot read back %s: %s\n", END_PATH, strerror(errno));
		return -1;
	}
	return actual;
}

static int require_firmware(void)
{
	int end;

	if (read_int(END_PATH, &end) == 0)
		return 0;
	fprintf(stderr, "battctl: %s not found or unreadable\n", END_PATH);
	fprintf(stderr, "battctl: is this an Apple Silicon Mac running Linux with the macsmc driver?\n");
	return -1;
}

static int cmd_status(void)
{
	struct config cfg;
	char status[64] = "unknown";
	int ac = -1, cap = -1, end = -1, start = -1;

	if (config_load(&cfg) != 0) {
		fprintf(stderr, "battctl: cannot read %s: %s\n", CONFIG_PATH, strerror(errno));
		return 1;
	}
	if (require_firmware() != 0)
		return 1;

	(void)read_int(CAP_PATH, &cap);
	(void)read_int(START_PATH, &start);
	(void)read_int(AC_ONLINE_PATH, &ac);
	(void)read_str(STATUS_PATH, status, sizeof(status));
	(void)read_int(END_PATH, &end);

	printf("MacBook battery charge limit (battctl %s)\n\n", VERSION);
	if (cap >= 0)
		printf("  Battery          : %d%% (%s)\n", cap, status);
	else
		printf("  Battery          : %s\n", status);
	if (ac >= 0)
		printf("  AC adapter       : %s\n", ac ? "online" : "offline");
	printf("  Firmware mode    : %s - %s\n", mode_name(cfg.mode), mode_desc(cfg.mode));
	if (end < 100 && start >= 0)
		printf("  Sysfs thresholds : end %d%%, start %d%% (recharge point)\n", end, start);
	else
		printf("  Sysfs thresholds : end %d%%, start %d%%\n", end, start);
	printf("\n");

	if (cfg.have_limit) {
		printf("  Configured limit : %d%%\n", cfg.charge_limit);
		if (cfg.mode == FW_UNKNOWN) {
			printf("  Effective limit  : unknown - run 'sudo battctl detect'\n");
		} else {
			int eff = effective_limit(cfg.mode, cfg.charge_limit);

			if (eff == 100) {
				printf("  Effective limit  : 100%% (limit off)\n");
			} else if (cfg.mode == FW_CHLS) {
				printf("  Effective limit  : %d%% (recharges below %d%%)\n",
				       eff, eff - HYSTERESIS);
			} else {
				printf("  Effective limit  : %d%%%s\n", eff,
				       cfg.charge_limit != eff ? " (firmware fixed limit)" : "");
			}
		}
	} else {
		printf("  Configured limit : none (run 'sudo battctl set 80')\n");
	}

	if (cfg.mode == FW_CHWA && cfg.have_limit &&
	    cfg.charge_limit != 100 && cfg.charge_limit != CHWA_FIXED_END) {
		printf("\n  note: this firmware only supports the fixed 80%% limit (the same as\n");
		printf("        macOS \"80%% limit\"), so %d%% is mapped to 80%%.\n", cfg.charge_limit);
	}
	if (cfg.mode == FW_UNKNOWN)
		printf("\n  note: run 'sudo battctl detect' once to probe the firmware.\n");
	if (geteuid() != 0)
		printf("\n  note: 'set', 'off', 'apply' and 'detect' need root - use sudo.\n");
	return 0;
}

static int cmd_set(int requested)
{
	struct config cfg;
	int actual, cap = -1, eff;

	if (requested < CHLS_MIN_END || requested > 100) {
		fprintf(stderr, "battctl: charge limit must be between %d and 100 (100 disables the limit)\n",
			CHLS_MIN_END);
		return 2;
	}
	if (geteuid() != 0) {
		fprintf(stderr, "battctl: this needs root - run: sudo battctl set %d\n", requested);
		return 1;
	}
	if (require_firmware() != 0)
		return 1;
	if (config_load(&cfg) != 0) {
		fprintf(stderr, "battctl: cannot read %s: %s\n", CONFIG_PATH, strerror(errno));
		return 1;
	}
	if (resolve_mode(&cfg, false, true) != 0)
		return 1;

	eff = effective_limit(cfg.mode, requested);
	actual = write_and_verify(eff);
	if (actual < 0)
		return 1;

	cfg.charge_limit = requested;
	cfg.have_limit = true;
	if (config_save(&cfg) != 0)
		fprintf(stderr, "battctl: warning: could not save %s: %s\n", CONFIG_PATH, strerror(errno));

	if (actual == 100) {
		if (requested == 100)
			printf("Charge limit disabled - the battery will charge to 100%%.\n");
		else
			printf("Charge limit set: requested %d%%, effective 100%% (limit off).\n", requested);
	} else if (cfg.mode == FW_CHWA && requested != actual) {
		printf("Charge limit set: requested %d%%, effective %d%%.\n", requested, actual);
		fprintf(stderr,
			"battctl: warning: this machine's firmware only supports the fixed 80%%\n"
			"battctl:          limit (the same as macOS \"80%% limit\"). %d%% is not\n"
			"battctl:          possible; 80%% is used instead. 'battctl off' removes it.\n",
			requested);
	} else {
		printf("Charge limit set: %d%%", actual);
		if (cfg.mode == FW_CHLS)
			printf(" (firmware will recharge below %d%%)", actual - HYSTERESIS);
		printf(".\n");
	}

	if (actual < 100 && read_int(CAP_PATH, &cap) == 0 && cap > actual)
		printf("note: battery is at %d%%, above the limit - charging is capped and it will\n"
		       "      come down to %d%%.\n", cap, actual);
	return 0;
}

static int cmd_apply(void)
{
	struct config cfg;
	int actual, cur, eff;

	if (geteuid() != 0) {
		fprintf(stderr, "battctl: 'apply' needs root - run: sudo battctl apply\n");
		return 1;
	}
	if (require_firmware() != 0)
		return 1;
	if (config_load(&cfg) != 0) {
		fprintf(stderr, "battctl: cannot read %s: %s\n", CONFIG_PATH, strerror(errno));
		return 1;
	}
	if (!cfg.have_limit) {
		printf("battctl: no charge_limit configured in %s - nothing to do.\n", CONFIG_PATH);
		return 0;
	}
	if (resolve_mode(&cfg, false, false) != 0)
		return 1;

	eff = effective_limit(cfg.mode, cfg.charge_limit);
	if (read_int(END_PATH, &cur) == 0 && cur == eff) {
		printf("battctl: charge limit already active (%d%%).\n", eff);
		return 0;
	}

	actual = write_and_verify(eff);
	if (actual < 0)
		return 1;
	printf("battctl: charge limit applied: %d%%", actual);
	if (actual != eff)
		printf(" (requested %d%%)", eff);
	printf(".\n");
	return 0;
}

static int cmd_detect(void)
{
	struct config cfg;
	int actual, target;

	if (geteuid() != 0) {
		fprintf(stderr, "battctl: 'detect' needs root - run: sudo battctl detect\n");
		return 1;
	}
	if (require_firmware() != 0)
		return 1;
	if (config_load(&cfg) != 0) {
		fprintf(stderr, "battctl: cannot read %s: %s\n", CONFIG_PATH, strerror(errno));
		return 1;
	}
	if (resolve_mode(&cfg, true, true) != 0)
		return 1;

	/* The probe wrote 90; restore the configured limit (or disable). */
	target = cfg.have_limit ? effective_limit(cfg.mode, cfg.charge_limit) : 100;
	actual = write_and_verify(target);
	if (actual < 0)
		return 1;
	if (cfg.have_limit)
		printf("Restored configured limit: %d%% -> effective %d%%.\n", cfg.charge_limit, actual);
	if (config_save(&cfg) != 0)
		fprintf(stderr, "battctl: warning: could not save %s: %s\n", CONFIG_PATH, strerror(errno));

	if (cfg.mode == FW_CHWA)
		printf("This firmware supports two states only: 80%% (limit on) or 100%% (limit off).\n");
	else
		printf("This firmware supports any charge limit from %d%% to 99%%; the recharge\n"
		       "point is fixed at limit - 5.\n", CHLS_MIN_END);
	return 0;
}

static void usage(FILE *out)
{
	fprintf(out,
		"battctl %s - MacBook battery charge limit (macsmc / Apple Silicon)\n"
		"\n"
		"Usage:\n"
		"  battctl [status]        show battery, limits and firmware mode\n"
		"  sudo battctl set N      set the charge limit to N%% (10-100, 100 = off)\n"
		"  sudo battctl off        remove the limit (same as: set 100)\n"
		"  sudo battctl apply      (re)apply the limit from %s\n"
		"  sudo battctl detect     probe which charge-limit mode the firmware supports\n"
		"  battctl help | version\n"
		"\n"
		"The limit is enforced by the SMC firmware itself, so it stays active\n"
		"while the lid is closed and the machine is suspended.\n",
		VERSION, CONFIG_PATH);
}

int main(int argc, char **argv)
{
	const char *cmd = argc > 1 ? argv[1] : "status";

	if (strcmp(cmd, "status") == 0 || strcmp(cmd, "show") == 0)
		return cmd_status();

	if (strcmp(cmd, "set") == 0) {
		char *end;
		long v;

		if (argc < 3) {
			fprintf(stderr, "battctl: 'set' needs a percentage, e.g. sudo battctl set 80\n");
			return 2;
		}
		v = strtol(argv[2], &end, 10);
		if (*end != '\0' || end == argv[2]) {
			fprintf(stderr, "battctl: invalid percentage '%s'\n", argv[2]);
			return 2;
		}
		return cmd_set((int)v);
	}
	if (strcmp(cmd, "off") == 0)
		return cmd_set(100);
	if (strcmp(cmd, "apply") == 0)
		return cmd_apply();
	if (strcmp(cmd, "detect") == 0)
		return cmd_detect();

	if (strcmp(cmd, "help") == 0 || strcmp(cmd, "-h") == 0 || strcmp(cmd, "--help") == 0) {
		usage(stdout);
		return 0;
	}
	if (strcmp(cmd, "version") == 0 || strcmp(cmd, "-V") == 0 || strcmp(cmd, "--version") == 0) {
		printf("battctl %s\n", VERSION);
		return 0;
	}

	fprintf(stderr, "battctl: unknown command '%s'\n\n", cmd);
	usage(stderr);
	return 2;
}
