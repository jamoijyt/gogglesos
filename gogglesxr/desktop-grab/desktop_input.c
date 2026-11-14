/* gogglesxr-desktop-input: lets the GogglesXR dashboard use the PC's mouse and keyboard.
 *
 * Creates two virtual input devices through the kernel's uinput interface, the same way a
 * drawing tablet or a remote-desktop program would, and moves them as the dashboard asks:
 *
 *   "GogglesXR pointer"   a pointer that jumps to a position on the desktop (like a tablet),
 *                         with three buttons and a wheel
 *   "GogglesXR keyboard"  a keyboard
 *
 * The desktop (KWin) spreads the pointer's range over all screens together, so a position is
 * given as two numbers from 0 to 65535 across the whole desktop.
 *
 * Commands, one per line on standard input:
 *   m X Y      move the pointer to X, Y (each 0..65535)
 *   b N D      button N (0 left, 1 right, 2 middle) down (D = 1) or up (D = 0)
 *   w DY [DX]  turn the wheel by DY clicks (positive = up) and DX clicks sideways
 *   k CODE D   key CODE (a Linux key code, see linux/input-event-codes.h) down or up
 *
 * Needs write access to /dev/uinput, which Goggles OS gives the logged-in user (udev rule
 * 60-gogglesxr-uinput.rules; Steam's own rules do the same for its controller support).
 * Prints "ready" when the devices exist, or "error: ..." and stops. Releases everything it
 * holds and removes the devices when its input closes or the dashboard goes away.
 *
 *   gogglesxr-desktop-input [--print]
 *
 * --print writes the events to standard output instead of creating devices (for testing).
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/uinput.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <unistd.h>

#define RANGE 65535

static int print_only;
static int pointer_fd = -1, keyboard_fd = -1;
static unsigned char key_down[KEY_MAX + 1];
static int button_down[3];
static const int buttons[3] = {BTN_LEFT, BTN_RIGHT, BTN_MIDDLE};

static void emit(int fd, int type, int code, int value)
{
	if (print_only) {
		if (type != EV_SYN)
			printf("%s type=%d code=%d value=%d\n", fd == keyboard_fd ? "keyboard" : "pointer", type, code, value);
		return;
	}
	struct input_event ev = {0};
	ev.type = (unsigned short)type;
	ev.code = (unsigned short)code;
	ev.value = value;
	if (write(fd, &ev, sizeof ev) != (ssize_t)sizeof ev) {
		/* the device is gone: nothing useful left to do */
	}
}

static void sync_device(int fd)
{
	emit(fd, EV_SYN, SYN_REPORT, 0);
}

static int make_device(const char *name, int pointer)
{
	int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
	if (fd < 0)
		return -1;
	struct uinput_setup setup = {0};
	snprintf(setup.name, sizeof setup.name, "%s", name);
	setup.id.bustype = BUS_VIRTUAL;
	setup.id.vendor = 0x6767; /* "gg" */
	setup.id.product = pointer ? 0x0001 : 0x0002;
	setup.id.version = 1;
	int ok = 1;
	if (pointer) {
		ok = ok && ioctl(fd, UI_SET_EVBIT, EV_KEY) == 0;
		for (int i = 0; i < 3; i++)
			ok = ok && ioctl(fd, UI_SET_KEYBIT, buttons[i]) == 0;
		ok = ok && ioctl(fd, UI_SET_EVBIT, EV_REL) == 0;
		ok = ok && ioctl(fd, UI_SET_RELBIT, REL_WHEEL) == 0;
		ok = ok && ioctl(fd, UI_SET_RELBIT, REL_HWHEEL) == 0;
		ok = ok && ioctl(fd, UI_SET_EVBIT, EV_ABS) == 0;
		for (int axis = ABS_X; axis <= ABS_Y; axis++) {
			struct uinput_abs_setup abs = {0};
			abs.code = (unsigned short)axis;
			abs.absinfo.minimum = 0;
			abs.absinfo.maximum = RANGE;
			ok = ok && ioctl(fd, UI_ABS_SETUP, &abs) == 0;
		}
	} else {
		ok = ok && ioctl(fd, UI_SET_EVBIT, EV_KEY) == 0;
		for (int key = KEY_ESC; key <= KEY_MICMUTE; key++)
			ok = ok && ioctl(fd, UI_SET_KEYBIT, key) == 0;
	}
	ok = ok && ioctl(fd, UI_DEV_SETUP, &setup) == 0;
	ok = ok && ioctl(fd, UI_DEV_CREATE) == 0;
	if (!ok) {
		close(fd);
		return -1;
	}
	return fd;
}

/* Let go of everything held, so a key or button can't stay stuck down on the PC */
static void release_all(void)
{
	for (int i = 0; i < 3; i++)
		if (button_down[i]) {
			emit(pointer_fd, EV_KEY, buttons[i], 0);
			button_down[i] = 0;
		}
	sync_device(pointer_fd);
	for (int key = 0; key <= KEY_MAX; key++)
		if (key_down[key]) {
			emit(keyboard_fd, EV_KEY, key, 0);
			key_down[key] = 0;
		}
	sync_device(keyboard_fd);
}

static int clamp(long v, long lo, long hi)
{
	return (int)(v < lo ? lo : v > hi ? hi : v);
}

int main(int argc, char **argv)
{
	for (int i = 1; i < argc; i++)
		if (strcmp(argv[i], "--print") == 0)
			print_only = 1;
	prctl(PR_SET_PDEATHSIG, SIGTERM); /* stop with the dashboard */
	signal(SIGPIPE, SIG_IGN);
	setvbuf(stdout, NULL, _IOLBF, 0);

	if (print_only) {
		pointer_fd = 100;
		keyboard_fd = 101;
	} else {
		pointer_fd = make_device("GogglesXR pointer", 1);
		keyboard_fd = pointer_fd >= 0 ? make_device("GogglesXR keyboard", 0) : -1;
		if (pointer_fd < 0 || keyboard_fd < 0) {
			printf("error: %s\n", errno == EACCES || errno == EPERM
			                          ? "no-permission: this user may not use /dev/uinput. Log out and back in once after updating Goggles OS."
			                          : errno == ENOENT ? "no-uinput: this PC's kernel has no uinput device"
			                                            : strerror(errno));
			return 1;
		}
	}
	printf("ready\n");

	char line[128];
	while (fgets(line, sizeof line, stdin)) {
		long a = 0, b = 0;
		char command = line[0];
		int count = sscanf(line + 1, "%ld %ld", &a, &b);
		switch (command) {
		case 'm':
			if (count == 2) {
				emit(pointer_fd, EV_ABS, ABS_X, clamp(a, 0, RANGE));
				emit(pointer_fd, EV_ABS, ABS_Y, clamp(b, 0, RANGE));
				sync_device(pointer_fd);
			}
			break;
		case 'b':
			if (count == 2 && a >= 0 && a < 3) {
				button_down[a] = b != 0;
				emit(pointer_fd, EV_KEY, buttons[a], b != 0);
				sync_device(pointer_fd);
			}
			break;
		case 'w':
			if (count >= 1) {
				if (a)
					emit(pointer_fd, EV_REL, REL_WHEEL, clamp(a, -10, 10));
				if (count == 2 && b)
					emit(pointer_fd, EV_REL, REL_HWHEEL, clamp(b, -10, 10));
				sync_device(pointer_fd);
			}
			break;
		case 'k':
			if (count == 2 && a > 0 && a <= KEY_MICMUTE) {
				key_down[a] = b != 0;
				emit(keyboard_fd, EV_KEY, (int)a, b != 0);
				sync_device(keyboard_fd);
			}
			break;
		default:
			break;
		}
	}
	release_all();
	if (!print_only) {
		ioctl(pointer_fd, UI_DEV_DESTROY);
		ioctl(keyboard_fd, UI_DEV_DESTROY);
	}
	return 0;
}
