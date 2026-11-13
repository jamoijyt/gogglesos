/* gogglesxr-desktop-grab: pictures of the KDE Plasma desktop for the GogglesXR dashboard.
 *
 * Asks KWin (the Plasma compositor) for a picture of the desktop through its screenshot
 * interface (org.kde.KWin.ScreenShot2) several times a second, shrinks it to fit the headset's
 * panel and writes it to a file the dashboard reads:
 *
 *   OUT        "GXDF", width, height, frame number (4 x 32-bit, little-endian), then
 *              width x height RGBA pixels. Replaced in one step (rename), never half-written.
 *   OUT.error  one line saying why there is no picture (deleted again once pictures arrive).
 *
 * KWin only answers programs that a desktop file lists for that interface: see
 * org.gogglesos.gogglesxr-desktop-grab.desktop (X-KDE-DBUS-Restricted-Interfaces). It needs
 * no prompt on the desktop, so it also works while you are in the headset.
 *
 *   gogglesxr-desktop-grab --out FILE [--fps N] [--max-width W] [--screen all|active|NAME]
 *                          [--test-pattern] [--once]
 *
 * --test-pattern draws moving stripes instead of asking KWin (for testing without Plasma).
 * Stops when its parent (the dashboard) goes away.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <gio/gunixfdlist.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <time.h>
#include <unistd.h>

typedef struct {
	int fd;
	uint8_t *data;
	size_t size, cap;
	volatile size_t expected; /* set once KWin has said how big the picture is */
} reader;

static const char *out_path;
static unsigned frame_number;

static void *read_all(void *arg)
{
	reader *r = arg;
	for (;;) {
		if (r->cap - r->size < 1 << 20) {
			size_t cap = r->cap ? r->cap * 2 : 16 << 20;
			uint8_t *data = realloc(r->data, cap);
			if (!data)
				break;
			r->data = data;
			r->cap = cap;
		}
		ssize_t n = read(r->fd, r->data + r->size, r->cap - r->size);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			break;
		r->size += (size_t)n;
		if (r->expected && r->size >= r->expected)
			break; /* the whole picture is here */
	}
	return NULL;
}

static void put_u32(uint8_t *p, uint32_t v)
{
	p[0] = v & 0xff;
	p[1] = (v >> 8) & 0xff;
	p[2] = (v >> 16) & 0xff;
	p[3] = (v >> 24) & 0xff;
}

static void report(const char *fmt, ...)
{
	char path[4096], text[512];
	va_list args;
	va_start(args, fmt);
	vsnprintf(text, sizeof text, fmt, args);
	va_end(args);
	fprintf(stderr, "gogglesxr-desktop-grab: %s\n", text);
	snprintf(path, sizeof path, "%s.error", out_path);
	FILE *f = fopen(path, "w");
	if (f) {
		fprintf(f, "%s\n", text);
		fclose(f);
	}
}

static void clear_report(void)
{
	char path[4096];
	snprintf(path, sizeof path, "%s.error", out_path);
	unlink(path);
}

/* Write a frame: `pixel(x, y, rgb)` gives the colour of source pixel x, y */
typedef void (*pixel_fn)(const void *ctx, uint32_t x, uint32_t y, uint8_t *rgb);

static int write_frame(uint32_t src_w, uint32_t src_h, uint32_t max_w, pixel_fn pixel, const void *ctx)
{
	uint32_t w = src_w, h = src_h;
	if (w > max_w) {
		h = (uint32_t)((uint64_t)h * max_w / w);
		w = max_w;
	}
	if (w == 0 || h == 0)
		return -1;
	size_t size = 16 + (size_t)w * h * 4;
	uint8_t *buf = malloc(size);
	if (!buf)
		return -1;
	memcpy(buf, "GXDF", 4);
	put_u32(buf + 4, w);
	put_u32(buf + 8, h);
	put_u32(buf + 12, ++frame_number);
	uint8_t *px = buf + 16;
	for (uint32_t y = 0; y < h; y++) {
		/* Average a 2x2 block around each sample point, so small text stays readable */
		uint32_t sy = (uint32_t)(((uint64_t)y * src_h) / h);
		uint32_t sy2 = sy + 1 < src_h && src_h > h ? sy + 1 : sy;
		for (uint32_t x = 0; x < w; x++) {
			uint32_t sx = (uint32_t)(((uint64_t)x * src_w) / w);
			uint32_t sx2 = sx + 1 < src_w && src_w > w ? sx + 1 : sx;
			uint8_t a[3], b[3], c[3], d[3];
			pixel(ctx, sx, sy, a);
			pixel(ctx, sx2, sy, b);
			pixel(ctx, sx, sy2, c);
			pixel(ctx, sx2, sy2, d);
			for (int i = 0; i < 3; i++)
				px[i] = (uint8_t)((a[i] + b[i] + c[i] + d[i] + 2) / 4);
			px[3] = 255;
			px += 4;
		}
	}
	char tmp[4096];
	snprintf(tmp, sizeof tmp, "%s.part", out_path);
	int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
	if (fd < 0) {
		free(buf);
		return -1;
	}
	size_t done = 0;
	while (done < size) {
		ssize_t n = write(fd, buf + done, size - done);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0)
			break;
		done += (size_t)n;
	}
	close(fd);
	free(buf);
	if (done != size || rename(tmp, out_path) != 0) {
		unlink(tmp);
		return -1;
	}
	return 0;
}

/* ------------------------------------------------------------------ KWin's picture */
typedef struct {
	const uint8_t *data;
	uint32_t stride, format;
} image;

static void image_pixel(const void *ctx, uint32_t x, uint32_t y, uint8_t *rgb)
{
	const image *im = ctx;
	const uint8_t *row = im->data + (size_t)y * im->stride;
	switch (im->format) {
	case 4: /* QImage::Format_RGB32, ARGB32 and ARGB32_Premultiplied: B G R A in memory */
	case 5:
	case 6: {
		const uint8_t *p = row + (size_t)x * 4;
		rgb[0] = p[2], rgb[1] = p[1], rgb[2] = p[0];
		break;
	}
	case 16: /* RGBX8888, RGBA8888, RGBA8888_Premultiplied: R G B A */
	case 17:
	case 18: {
		const uint8_t *p = row + (size_t)x * 4;
		rgb[0] = p[0], rgb[1] = p[1], rgb[2] = p[2];
		break;
	}
	case 13: { /* RGB888 */
		const uint8_t *p = row + (size_t)x * 3;
		rgb[0] = p[0], rgb[1] = p[1], rgb[2] = p[2];
		break;
	}
	case 29: { /* BGR888 */
		const uint8_t *p = row + (size_t)x * 3;
		rgb[0] = p[2], rgb[1] = p[1], rgb[2] = p[0];
		break;
	}
	default:
		rgb[0] = rgb[1] = rgb[2] = 0;
	}
}

static int format_supported(uint32_t f)
{
	return f == 4 || f == 5 || f == 6 || f == 13 || f == 16 || f == 17 || f == 18 || f == 29;
}

static uint32_t bytes_per_pixel(uint32_t f)
{
	return (f == 13 || f == 29) ? 3 : 4;
}

static uint32_t lookup_u32(GVariant *dict, const char *key)
{
	guint32 value = 0;
	if (!g_variant_lookup(dict, key, "u", &value)) {
		gint32 signed_value = 0;
		if (g_variant_lookup(dict, key, "i", &signed_value))
			value = (guint32)signed_value;
	}
	return value;
}

/* 0 = picture written, 1 = try again, 2 = give up */
static int grab(GDBusConnection *bus, const char *screen, uint32_t max_w)
{
	int fds[2];
	if (pipe2(fds, O_CLOEXEC) != 0)
		return 1;
	GError *error = NULL;
	GUnixFDList *fd_list = g_unix_fd_list_new();
	g_unix_fd_list_append(fd_list, fds[1], &error);
	close(fds[1]);
	if (error) {
		g_error_free(error);
		g_object_unref(fd_list);
		close(fds[0]);
		return 1;
	}
	reader r = {.fd = fds[0]};
	pthread_t thread;
	pthread_create(&thread, NULL, read_all, &r);

	GVariantBuilder options;
	g_variant_builder_init(&options, G_VARIANT_TYPE("a{sv}"));
	g_variant_builder_add(&options, "{sv}", "include-cursor", g_variant_new_boolean(TRUE));
	g_variant_builder_add(&options, "{sv}", "native-resolution", g_variant_new_boolean(FALSE));
	const char *method;
	GVariant *params;
	if (strcmp(screen, "all") == 0) {
		method = "CaptureWorkspace";
		params = g_variant_new("(a{sv}h)", &options, 0);
	} else if (strcmp(screen, "active") == 0) {
		method = "CaptureActiveScreen";
		params = g_variant_new("(a{sv}h)", &options, 0);
	} else {
		method = "CaptureScreen";
		params = g_variant_new("(sa{sv}h)", screen, &options, 0);
	}
	GVariant *reply = g_dbus_connection_call_with_unix_fd_list_sync(
	    bus, "org.kde.KWin", "/org/kde/KWin/ScreenShot2", "org.kde.KWin.ScreenShot2", method, params,
	    G_VARIANT_TYPE("(a{sv})"), G_DBUS_CALL_FLAGS_NONE, 5000, fd_list, NULL, NULL, &error);
	g_object_unref(fd_list);
	if (!reply) {
		/* Nothing will be written: end the reader */
		pthread_cancel(thread);
		pthread_join(thread, NULL);
		close(fds[0]);
		free(r.data);
		int fatal = 0;
		const char *msg = error ? error->message : "no answer";
		if (error && (strstr(msg, "NoAuthorized") || strstr(msg, "not authorized") || strstr(msg, "AccessDenied"))) {
			report("not-authorized: KWin didn't allow the desktop picture. Log out and back in once after updating Goggles OS.");
			fatal = 1;
		} else if (error && (strstr(msg, "ServiceUnknown") || strstr(msg, "UnknownObject") || strstr(msg, "UnknownMethod"))) {
			report("no-kwin: The desktop view needs KDE Plasma (KWin) on Wayland.");
			fatal = 1;
		} else {
			report("failed: %s", msg);
		}
		if (error)
			g_error_free(error);
		return fatal ? 2 : 1;
	}
	GVariant *results = g_variant_get_child_value(reply, 0);
	uint32_t w = lookup_u32(results, "width"), h = lookup_u32(results, "height");
	uint32_t stride = lookup_u32(results, "stride"), format = lookup_u32(results, "format");
	g_variant_unref(results);
	g_variant_unref(reply);
	if (format_supported(format) && h > 0)
		r.expected = (size_t)(stride ? stride : w * bytes_per_pixel(format)) * h;
	/* Wait for the picture, but never for ever */
	struct timespec until;
	clock_gettime(CLOCK_REALTIME, &until);
	until.tv_sec += 3;
	if (pthread_timedjoin_np(thread, NULL, &until) != 0) {
		pthread_cancel(thread);
		pthread_join(thread, NULL);
	}
	close(fds[0]);
	int status = 1;
	if (w == 0 || h == 0 || !format_supported(format)) {
		report("format: KWin sent a picture this version can't read (format %u, %ux%u)", format, w, h);
	} else {
		if (stride == 0)
			stride = w * bytes_per_pixel(format);
		if (r.size < (size_t)stride * (h - 1) + (size_t)w * bytes_per_pixel(format)) {
			report("failed: the picture from KWin was cut short");
		} else {
			image im = {.data = r.data, .stride = stride, .format = format};
			if (write_frame(w, h, max_w, image_pixel, &im) == 0) {
				status = 0;
				if (frame_number == 1)
					clear_report();
			}
		}
	}
	free(r.data);
	return status;
}

/* ------------------------------------------------------------------ test pattern */
static void test_pixel(const void *ctx, uint32_t x, uint32_t y, uint8_t *rgb)
{
	unsigned t = *(const unsigned *)ctx;
	int stripe = ((x + t * 24) / 80) % 2;
	rgb[0] = (uint8_t)(stripe ? 61 : 12);
	rgb[1] = (uint8_t)(stripe ? 220 : 38 + y % 64);
	rgb[2] = (uint8_t)(stripe ? 132 : 33);
}

static void sleep_seconds(double s)
{
	struct timespec ts = {(time_t)s, (long)((s - (time_t)s) * 1e9)};
	while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
	}
}

int main(int argc, char **argv)
{
	double fps = 15;
	uint32_t max_w = 1920;
	const char *screen = "all";
	int test = 0, once = 0;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--out") == 0 && i + 1 < argc)
			out_path = argv[++i];
		else if (strcmp(argv[i], "--fps") == 0 && i + 1 < argc)
			fps = atof(argv[++i]);
		else if (strcmp(argv[i], "--max-width") == 0 && i + 1 < argc)
			max_w = (uint32_t)atoi(argv[++i]);
		else if (strcmp(argv[i], "--screen") == 0 && i + 1 < argc)
			screen = argv[++i];
		else if (strcmp(argv[i], "--test-pattern") == 0)
			test = 1;
		else if (strcmp(argv[i], "--once") == 0)
			once = 1;
	}
	if (!out_path) {
		fprintf(stderr, "usage: %s --out FILE [--fps N] [--max-width W] [--screen all|active|NAME] [--test-pattern] [--once]\n", argv[0]);
		return 2;
	}
	if (fps < 1)
		fps = 1;
	if (fps > 60)
		fps = 60;
	if (max_w < 64)
		max_w = 64;
	prctl(PR_SET_PDEATHSIG, SIGTERM); /* stop with the dashboard */
	pid_t parent = getppid();

	GDBusConnection *bus = NULL;
	if (!test) {
		GError *error = NULL;
		bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &error);
		if (!bus) {
			report("no-session: %s", error ? error->message : "no session bus");
			return 1;
		}
	}
	int failures = 0;
	while (getppid() == parent) {
		struct timespec start, end;
		clock_gettime(CLOCK_MONOTONIC, &start);
		int status;
		if (test) {
			unsigned t = frame_number;
			status = write_frame(1280, 800, max_w, test_pixel, &t) == 0 ? 0 : 1;
		} else {
			status = grab(bus, screen, max_w);
		}
		if (status == 2)
			return 1;
		failures = status == 0 ? 0 : failures + 1;
		if (once)
			return status;
		if (failures > 50) /* about ten seconds of nothing: something is wrong */
			return 1;
		clock_gettime(CLOCK_MONOTONIC, &end);
		double spent = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
		double wait = (status == 0 ? 1.0 / fps : 0.2) - spent;
		if (wait > 0)
			sleep_seconds(wait);
	}
	return 0;
}
