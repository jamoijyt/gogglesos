/* GogglesXR capture layer: screenshots and recordings of what a VR game shows in the headset.
 *
 * An OpenXR API layer: the OpenXR loader puts it between a game and the VR runtime. It does
 * nothing but pass calls on until GogglesXR asks for a capture (by creating a file, see
 * "Requests" below). Then, as the game hands each finished left-eye image back to the runtime,
 * it copies that image with the game's own Vulkan device:
 *
 *   screenshot  one full-size left-eye image, written as a PAM file for gogglesxr to turn
 *               into a PNG
 *   recording   a 16:9 crop of the left eye, centred on where the eye looks, scaled to the
 *               requested size, streamed as raw RGBA frames into a FIFO that ffmpeg reads
 *
 * Only Vulkan games are captured (that includes Proton games and SteamVR games through
 * xrizer). OpenGL games and the GogglesXR dashboard itself (an overlay session) are left alone.
 *
 * Requests, in ~/.cache/gogglesxr/capture/ (the home folder is shared with Steam's containers):
 *   screenshot.request   created by gogglesxr: capture the next frame into shot.pam. Empty: the
 *                        whole eye image; "W H ZOOM": a W:H crop around the point straight ahead
 *   record.on            "WIDTH HEIGHT FPS [ZOOM]": stream frames into record.fifo while it
 *                        exists. The crop has the WIDTH:HEIGHT shape (16:9, 9:16, 1:1...);
 *                        ZOOM 1 is the widest such crop, smaller values zoom in
 *   game.status          written here: the game that can be captured (refreshed every 2 s)
 *
 * Built with one gcc command (build.sh), with older glibc symbol versions so it also loads
 * inside Steam's game containers. Switch it off for one game with DISABLE_GOGGLESXR_CAPTURE=1.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <vulkan/vulkan.h>
#define XR_USE_GRAPHICS_API_VULKAN
#include "openxr/openxr.h"
#include "openxr/openxr_platform.h"
#include "openxr/openxr_loader_negotiation.h"

/* Bind to symbol versions that every glibc since 2.17 has, so the layer loads in Steam's
 * older game containers as well as on the desktop (glibc 2.34 gave these new versions). */
__asm__(".symver pthread_create,pthread_create@GLIBC_2.2.5");
__asm__(".symver pthread_join,pthread_join@GLIBC_2.2.5");
__asm__(".symver pthread_sigmask,pthread_sigmask@GLIBC_2.2.5");

#define EXPORT __attribute__((visibility("default")))
#define LAYER_NAME "XR_APILAYER_GOGGLES_capture"
#define MAX_SESSIONS 4
#define MAX_SWAPCHAINS 64
#define MAX_IMAGES 8
#define RECORD_SLOTS 3

static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
#include <stdarg.h>
static void say(const char *fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	fputs("GogglesXR capture: ", stderr);
	vfprintf(stderr, fmt, args);
	fputc('\n', stderr);
	va_end(args);
}

static double now_seconds(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ------------------------------------------------------------------ request files */
static char dir[512];

static void path_of(char *out, size_t size, const char *name)
{
	snprintf(out, size, "%s/%s", dir, name);
}

static bool file_exists(const char *name)
{
	char path[600];
	path_of(path, sizeof path, name);
	return access(path, F_OK) == 0;
}

static void make_dirs(void)
{
	const char *home = getenv("HOME");
	if (!home || !home[0])
		home = "/tmp";
	char path[512];
	snprintf(path, sizeof path, "%s/.cache", home);
	mkdir(path, 0700);
	snprintf(path, sizeof path, "%s/.cache/gogglesxr", home);
	mkdir(path, 0700);
	snprintf(dir, sizeof dir, "%s/.cache/gogglesxr/capture", home);
	mkdir(dir, 0700);
}

/* ------------------------------------------------------------------ state */
typedef struct vkfn {
	PFN_vkGetDeviceQueue GetDeviceQueue;
	PFN_vkCreateCommandPool CreateCommandPool;
	PFN_vkDestroyCommandPool DestroyCommandPool;
	PFN_vkAllocateCommandBuffers AllocateCommandBuffers;
	PFN_vkBeginCommandBuffer BeginCommandBuffer;
	PFN_vkEndCommandBuffer EndCommandBuffer;
	PFN_vkResetCommandBuffer ResetCommandBuffer;
	PFN_vkCmdPipelineBarrier CmdPipelineBarrier;
	PFN_vkCmdBlitImage CmdBlitImage;
	PFN_vkCmdCopyImageToBuffer CmdCopyImageToBuffer;
	PFN_vkQueueSubmit QueueSubmit;
	PFN_vkCreateFence CreateFence;
	PFN_vkDestroyFence DestroyFence;
	PFN_vkWaitForFences WaitForFences;
	PFN_vkGetFenceStatus GetFenceStatus;
	PFN_vkResetFences ResetFences;
	PFN_vkCreateImage CreateImage;
	PFN_vkDestroyImage DestroyImage;
	PFN_vkGetImageMemoryRequirements GetImageMemoryRequirements;
	PFN_vkBindImageMemory BindImageMemory;
	PFN_vkCreateBuffer CreateBuffer;
	PFN_vkDestroyBuffer DestroyBuffer;
	PFN_vkGetBufferMemoryRequirements GetBufferMemoryRequirements;
	PFN_vkBindBufferMemory BindBufferMemory;
	PFN_vkAllocateMemory AllocateMemory;
	PFN_vkFreeMemory FreeMemory;
	PFN_vkMapMemory MapMemory;
	PFN_vkInvalidateMappedMemoryRanges InvalidateMappedMemoryRanges;
	PFN_vkGetPhysicalDeviceMemoryProperties GetPhysicalDeviceMemoryProperties;
	PFN_vkGetPhysicalDeviceFormatProperties GetPhysicalDeviceFormatProperties;
} vkfn;

/* A copy target: an image to blit into, a host-visible buffer to read it from */
typedef struct target {
	uint32_t w, h;
	VkFormat format;
	VkImage image;
	VkDeviceMemory image_mem;
	VkBuffer buffer;
	VkDeviceMemory buffer_mem;
	VkDeviceSize size;
	void *map;
	bool coherent;
	VkCommandBuffer cmd;
	VkFence fence;
	int state; /* 0 free, 1 copying on the GPU, 2 being written out */
} target;

typedef struct session_rec {
	XrSession handle;
	bool capture; /* a Vulkan session that isn't an overlay */
	VkInstance vk_instance;
	VkPhysicalDevice physical;
	VkDevice device;
	uint32_t queue_family, queue_index;
	VkQueue queue;
	vkfn fn;
	bool vk_ready, vk_failed;
	VkCommandPool pool;
	/* The left eye, from the last frame the game submitted */
	XrSwapchain eye_swapchain;
	XrRect2Di eye_rect;
	uint32_t eye_layer;
	XrFovf eye_fov;
	/* Requests */
	bool shot_pending;
	double shot_aspect, shot_zoom; /* 0: the whole eye image */
	double rec_zoom;
	bool recording;
	uint32_t rec_w, rec_h;
	double rec_interval, rec_last;
	target shot;
	target slots[RECORD_SLOTS];
	double status_written;
	int writer_jobs; /* frames of this session still being written out */
} session_rec;

typedef struct swapchain_rec {
	XrSwapchain handle;
	session_rec *session;
	VkFormat format;
	uint32_t width, height, array_size;
	bool color;
	uint32_t image_count;
	VkImage images[MAX_IMAGES];
	uint32_t acquired[MAX_IMAGES];
	uint32_t acquired_head, acquired_count;
} swapchain_rec;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static session_rec sessions[MAX_SESSIONS];
static swapchain_rec swapchains[MAX_SWAPCHAINS];
static char app_name[XR_MAX_APPLICATION_NAME_SIZE];

static PFN_xrGetInstanceProcAddr next_gipa;
static PFN_xrCreateSession next_CreateSession;
static PFN_xrDestroySession next_DestroySession;
static PFN_xrCreateSwapchain next_CreateSwapchain;
static PFN_xrDestroySwapchain next_DestroySwapchain;
static PFN_xrEnumerateSwapchainImages next_EnumerateSwapchainImages;
static PFN_xrAcquireSwapchainImage next_AcquireSwapchainImage;
static PFN_xrReleaseSwapchainImage next_ReleaseSwapchainImage;
static PFN_xrEndFrame next_EndFrame;

static session_rec *find_session(XrSession handle)
{
	for (int i = 0; i < MAX_SESSIONS; i++)
		if (sessions[i].handle == handle && handle != XR_NULL_HANDLE)
			return &sessions[i];
	return NULL;
}

static swapchain_rec *find_swapchain(XrSwapchain handle)
{
	for (int i = 0; i < MAX_SWAPCHAINS; i++)
		if (swapchains[i].handle == handle && handle != XR_NULL_HANDLE)
			return &swapchains[i];
	return NULL;
}

/* ------------------------------------------------------------------ writer thread */
/* Files and FIFO writes happen here, never on the game's render thread. */
enum job_kind { JOB_FILE, JOB_FRAME, JOB_OPEN_FIFO, JOB_CLOSE_FIFO };
typedef struct job {
	enum job_kind kind;
	char path[600];
	void *data; /* JOB_FILE: malloc'd PAM file */
	size_t size;
	target *slot; /* JOB_FRAME */
	session_rec *session;
	struct job *next;
} job;

static pthread_cond_t jobs_cond = PTHREAD_COND_INITIALIZER;
static pthread_cond_t done_cond = PTHREAD_COND_INITIALIZER;
static job *jobs_head, *jobs_tail;
static bool writer_started;
static int fifo_fd = -1;

static void write_all(int fd, const void *data, size_t size, bool *ok)
{
	const char *p = data;
	while (size > 0 && *ok) {
		ssize_t n = write(fd, p, size);
		if (n < 0 && errno == EINTR)
			continue;
		if (n <= 0) {
			*ok = false;
			break;
		}
		p += n;
		size -= (size_t)n;
	}
}

static void *writer_main(void *unused)
{
	(void)unused;
	/* A FIFO whose reader has gone must give EPIPE here, not kill the game */
	sigset_t block;
	sigemptyset(&block);
	sigaddset(&block, SIGPIPE);
	pthread_sigmask(SIG_BLOCK, &block, NULL);

	pthread_mutex_lock(&lock);
	for (;;) {
		while (!jobs_head)
			pthread_cond_wait(&jobs_cond, &lock);
		job *j = jobs_head;
		jobs_head = j->next;
		if (!jobs_head)
			jobs_tail = NULL;
		pthread_mutex_unlock(&lock);

		bool ok = true;
		switch (j->kind) {
		case JOB_FILE: {
			char tmp[620];
			snprintf(tmp, sizeof tmp, "%s.part", j->path);
			int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0600);
			if (fd >= 0) {
				write_all(fd, j->data, j->size, &ok);
				close(fd);
				if (ok)
					rename(tmp, j->path);
				else
					unlink(tmp);
			}
			free(j->data);
			break;
		}
		case JOB_OPEN_FIFO:
			/* Wait (up to 10 s) for ffmpeg to open its end. Never block for good: if ffmpeg has
			 * gone, frames are dropped instead and the game carries on. */
			for (int tries = 0; fifo_fd < 0 && tries < 200; tries++) {
				fifo_fd = open(j->path, O_WRONLY | O_NONBLOCK);
				if (fifo_fd < 0) {
					if (errno != ENXIO && errno != EINTR)
						break;
					struct timespec pause = {0, 50 * 1000000};
					nanosleep(&pause, NULL);
				}
			}
			if (fifo_fd >= 0)
				fcntl(fifo_fd, F_SETFL, fcntl(fifo_fd, F_GETFL) & ~O_NONBLOCK);
			else
				say("nothing is reading %s, so the recording is dropped", j->path);
			break;
		case JOB_FRAME:
			if (fifo_fd >= 0) {
				write_all(fifo_fd, j->slot->map, (size_t)j->slot->w * j->slot->h * 4, &ok);
				if (!ok) {
					close(fifo_fd);
					fifo_fd = -1;
				}
			}
			break;
		case JOB_CLOSE_FIFO:
			if (fifo_fd >= 0)
				close(fifo_fd);
			fifo_fd = -1;
			break;
		}

		pthread_mutex_lock(&lock);
		if (j->kind == JOB_FRAME) {
			j->slot->state = 0;
			j->session->writer_jobs--;
			pthread_cond_broadcast(&done_cond);
		}
		free(j);
	}
	return NULL;
}

/* Called with the lock held */
static void push_job(job *j)
{
	if (!writer_started) {
		pthread_t thread;
		pthread_attr_t attr;
		pthread_attr_init(&attr);
		pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
		if (pthread_create(&thread, &attr, writer_main, NULL) == 0)
			writer_started = true;
		pthread_attr_destroy(&attr);
		if (!writer_started) {
			free(j->data);
			free(j);
			return;
		}
	}
	j->next = NULL;
	if (jobs_tail)
		jobs_tail->next = j;
	else
		jobs_head = j;
	jobs_tail = j;
	pthread_cond_signal(&jobs_cond);
}

static void push_simple(enum job_kind kind, const char *name)
{
	job *j = calloc(1, sizeof *j);
	if (!j)
		return;
	j->kind = kind;
	path_of(j->path, sizeof j->path, name);
	push_job(j);
}

/* ------------------------------------------------------------------ Vulkan */
static bool vk_setup(session_rec *s)
{
	if (s->vk_ready)
		return true;
	if (s->vk_failed)
		return false;
	s->vk_failed = true;
	PFN_vkGetDeviceProcAddr gdpa = (PFN_vkGetDeviceProcAddr)vkGetInstanceProcAddr(s->vk_instance, "vkGetDeviceProcAddr");
	if (!gdpa)
		return false;
	vkfn *f = &s->fn;
#define DEV(name) f->name = (PFN_vk##name)gdpa(s->device, "vk" #name); if (!f->name) return false
#define INST(name) f->name = (PFN_vk##name)vkGetInstanceProcAddr(s->vk_instance, "vk" #name); if (!f->name) return false
	DEV(GetDeviceQueue);
	DEV(CreateCommandPool);
	DEV(DestroyCommandPool);
	DEV(AllocateCommandBuffers);
	DEV(BeginCommandBuffer);
	DEV(EndCommandBuffer);
	DEV(ResetCommandBuffer);
	DEV(CmdPipelineBarrier);
	DEV(CmdBlitImage);
	DEV(CmdCopyImageToBuffer);
	DEV(QueueSubmit);
	DEV(CreateFence);
	DEV(DestroyFence);
	DEV(WaitForFences);
	DEV(GetFenceStatus);
	DEV(ResetFences);
	DEV(CreateImage);
	DEV(DestroyImage);
	DEV(GetImageMemoryRequirements);
	DEV(BindImageMemory);
	DEV(CreateBuffer);
	DEV(DestroyBuffer);
	DEV(GetBufferMemoryRequirements);
	DEV(BindBufferMemory);
	DEV(AllocateMemory);
	DEV(FreeMemory);
	DEV(MapMemory);
	DEV(InvalidateMappedMemoryRanges);
	INST(GetPhysicalDeviceMemoryProperties);
	INST(GetPhysicalDeviceFormatProperties);
#undef DEV
#undef INST
	f->GetDeviceQueue(s->device, s->queue_family, s->queue_index, &s->queue);
	VkCommandPoolCreateInfo pool = {
	    .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
	    .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
	    .queueFamilyIndex = s->queue_family,
	};
	if (f->CreateCommandPool(s->device, &pool, NULL, &s->pool) != VK_SUCCESS)
		return false;
	s->vk_failed = false;
	s->vk_ready = true;
	return true;
}

static int memory_type(session_rec *s, uint32_t bits, VkMemoryPropertyFlags want, bool *coherent)
{
	VkPhysicalDeviceMemoryProperties props;
	s->fn.GetPhysicalDeviceMemoryProperties(s->physical, &props);
	for (int pass = 0; pass < 2; pass++) {
		/* Prefer host-coherent memory for read-back, take any host-visible memory otherwise */
		VkMemoryPropertyFlags extra = (pass == 0 && (want & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) ? VK_MEMORY_PROPERTY_HOST_COHERENT_BIT : 0;
		for (uint32_t i = 0; i < props.memoryTypeCount; i++) {
			VkMemoryPropertyFlags has = props.memoryTypes[i].propertyFlags;
			if ((bits & (1u << i)) && (has & (want | extra)) == (want | extra)) {
				if (coherent)
					*coherent = (has & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
				return (int)i;
			}
		}
	}
	return -1;
}

static void target_free(session_rec *s, target *t)
{
	vkfn *f = &s->fn;
	if (t->fence)
		f->DestroyFence(s->device, t->fence, NULL);
	if (t->buffer)
		f->DestroyBuffer(s->device, t->buffer, NULL);
	if (t->buffer_mem)
		f->FreeMemory(s->device, t->buffer_mem, NULL);
	if (t->image)
		f->DestroyImage(s->device, t->image, NULL);
	if (t->image_mem)
		f->FreeMemory(s->device, t->image_mem, NULL);
	/* The command buffer goes with the pool */
	memset(t, 0, sizeof *t);
}

/* Make `t` a w x h copy target in `format` (re-created when the size changes) */
static bool target_make(session_rec *s, target *t, uint32_t w, uint32_t h, VkFormat format)
{
	if (t->image && t->w == w && t->h == h && t->format == format)
		return true;
	if (t->image)
		target_free(s, t);
	vkfn *f = &s->fn;
	t->w = w;
	t->h = h;
	t->format = format;
	VkImageCreateInfo ii = {
	    .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
	    .imageType = VK_IMAGE_TYPE_2D,
	    .format = format,
	    .extent = {w, h, 1},
	    .mipLevels = 1,
	    .arrayLayers = 1,
	    .samples = VK_SAMPLE_COUNT_1_BIT,
	    .tiling = VK_IMAGE_TILING_OPTIMAL,
	    .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
	    .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
	};
	VkMemoryRequirements req;
	if (f->CreateImage(s->device, &ii, NULL, &t->image) != VK_SUCCESS)
		goto fail;
	f->GetImageMemoryRequirements(s->device, t->image, &req);
	int type = memory_type(s, req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, NULL);
	if (type < 0)
		type = memory_type(s, req.memoryTypeBits, 0, NULL);
	VkMemoryAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = (uint32_t)type};
	if (type < 0 || f->AllocateMemory(s->device, &ai, NULL, &t->image_mem) != VK_SUCCESS ||
	    f->BindImageMemory(s->device, t->image, t->image_mem, 0) != VK_SUCCESS)
		goto fail;

	t->size = (VkDeviceSize)w * h * 4;
	VkBufferCreateInfo bi = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = t->size, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
	if (f->CreateBuffer(s->device, &bi, NULL, &t->buffer) != VK_SUCCESS)
		goto fail;
	f->GetBufferMemoryRequirements(s->device, t->buffer, &req);
	type = memory_type(s, req.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT, &t->coherent);
	ai.allocationSize = req.size;
	ai.memoryTypeIndex = (uint32_t)type;
	if (type < 0 || f->AllocateMemory(s->device, &ai, NULL, &t->buffer_mem) != VK_SUCCESS ||
	    f->BindBufferMemory(s->device, t->buffer, t->buffer_mem, 0) != VK_SUCCESS ||
	    f->MapMemory(s->device, t->buffer_mem, 0, VK_WHOLE_SIZE, 0, &t->map) != VK_SUCCESS)
		goto fail;

	if (!t->cmd) {
		VkCommandBufferAllocateInfo ci = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = s->pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
		if (f->AllocateCommandBuffers(s->device, &ci, &t->cmd) != VK_SUCCESS)
			goto fail;
	}
	VkFenceCreateInfo fi = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
	if (f->CreateFence(s->device, &fi, NULL, &t->fence) != VK_SUCCESS)
		goto fail;
	return true;
fail:
	say("couldn't set up a %ux%u capture image", w, h);
	{
		VkCommandBuffer keep = t->cmd;
		target_free(s, t);
		t->cmd = keep;
	}
	return false;
}

static bool is_srgb(VkFormat f)
{
	switch (f) {
	case VK_FORMAT_R8G8B8A8_UNORM:
	case VK_FORMAT_B8G8R8A8_UNORM:
	case VK_FORMAT_A8B8G8R8_UNORM_PACK32:
		return false; /* the game already wrote the bytes it wants shown */
	default:
		return true; /* sRGB formats and high-precision (linear) formats */
	}
}

/* Copy `src` (one layer of a game's swapchain image) into `t`, scaling `from` to fill it.
 * Recorded into t->cmd and submitted on the game's queue with t->fence. */
static bool copy_eye(session_rec *s, swapchain_rec *sc, VkImage src, XrRect2Di from, target *t)
{
	vkfn *f = &s->fn;
	VkFormatProperties fp;
	f->GetPhysicalDeviceFormatProperties(s->physical, sc->format, &fp);
	if (!(fp.optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_SRC_BIT))
		return false;
	bool same_size = (uint32_t)from.extent.width == t->w && (uint32_t)from.extent.height == t->h;
	VkFilter filter = (!same_size && (fp.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT)) ? VK_FILTER_LINEAR : VK_FILTER_NEAREST;

	f->ResetCommandBuffer(t->cmd, 0);
	VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};
	if (f->BeginCommandBuffer(t->cmd, &begin) != VK_SUCCESS)
		return false;

	VkImageSubresourceRange layer = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, s->eye_layer, 1};
	VkImageMemoryBarrier to_copy[2] = {
	    {
	        /* The game left its image ready to be shown (OpenXR requires this layout) */
	        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
	        .srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_MEMORY_WRITE_BIT,
	        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
	        .oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
	        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
	        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	        .image = src,
	        .subresourceRange = layer,
	    },
	    {
	        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
	        .srcAccessMask = 0,
	        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
	        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
	        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
	        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	        .image = t->image,
	        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
	    },
	};
	f->CmdPipelineBarrier(t->cmd, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 2, to_copy);

	VkImageBlit blit = {
	    .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, s->eye_layer, 1},
	    .srcOffsets = {{from.offset.x, from.offset.y, 0}, {from.offset.x + from.extent.width, from.offset.y + from.extent.height, 1}},
	    .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
	    .dstOffsets = {{0, 0, 0}, {(int32_t)t->w, (int32_t)t->h, 1}},
	};
	f->CmdBlitImage(t->cmd, src, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, t->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit, filter);

	VkImageMemoryBarrier after_blit[2] = {
	    {
	        /* Hand the game's image back exactly as it was */
	        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
	        .srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
	        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | VK_ACCESS_SHADER_READ_BIT,
	        .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
	        .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
	        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	        .image = src,
	        .subresourceRange = layer,
	    },
	    {
	        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
	        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
	        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
	        .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
	        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
	        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	        .image = t->image,
	        .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
	    },
	};
	f->CmdPipelineBarrier(t->cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT | VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 2, after_blit);

	VkBufferImageCopy copy = {
	    .imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
	    .imageExtent = {t->w, t->h, 1},
	};
	f->CmdCopyImageToBuffer(t->cmd, t->image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, t->buffer, 1, &copy);
	VkBufferMemoryBarrier to_host = {
	    .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
	    .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
	    .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
	    .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	    .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
	    .buffer = t->buffer,
	    .size = VK_WHOLE_SIZE,
	};
	f->CmdPipelineBarrier(t->cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL, 1, &to_host, 0, NULL);
	if (f->EndCommandBuffer(t->cmd) != VK_SUCCESS)
		return false;

	f->ResetFences(s->device, 1, &t->fence);
	VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &t->cmd};
	return f->QueueSubmit(s->queue, 1, &submit, t->fence) == VK_SUCCESS;
}

static void make_visible(session_rec *s, target *t)
{
	if (t->coherent)
		return;
	VkMappedMemoryRange range = {.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory = t->buffer_mem, .size = VK_WHOLE_SIZE};
	s->fn.InvalidateMappedMemoryRanges(s->device, 1, &range);
}

static VkFormat copy_format(VkFormat src)
{
	return is_srgb(src) ? VK_FORMAT_R8G8B8A8_SRGB : VK_FORMAT_R8G8B8A8_UNORM;
}

/* ------------------------------------------------------------------ captures */
static XrRect2Di crop_rect(session_rec *s, double aspect, double zoom);

static void take_screenshot(session_rec *s, swapchain_rec *sc, VkImage src)
{
	s->shot_pending = false;
	XrRect2Di area = s->shot_aspect > 0 ? crop_rect(s, s->shot_aspect, s->shot_zoom) : s->eye_rect;
	uint32_t w = (uint32_t)area.extent.width, h = (uint32_t)area.extent.height;
	if (w == 0 || h == 0 || !target_make(s, &s->shot, w, h, copy_format(sc->format)))
		return;
	if (!copy_eye(s, sc, src, area, &s->shot)) {
		say("this game's image format can't be copied");
		return;
	}
	/* One short wait for the GPU: a screenshot may cost one frame */
	if (s->fn.WaitForFences(s->device, 1, &s->shot.fence, VK_TRUE, 1000000000ull) != VK_SUCCESS)
		return;
	make_visible(s, &s->shot);
	char header[128];
	int header_len = snprintf(header, sizeof header, "P7\nWIDTH %u\nHEIGHT %u\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n", w, h);
	size_t pixels = (size_t)w * h * 4;
	job *j = calloc(1, sizeof *j);
	char *data = malloc((size_t)header_len + pixels);
	if (!j || !data) {
		free(j);
		free(data);
		return;
	}
	memcpy(data, header, (size_t)header_len);
	memcpy(data + header_len, s->shot.map, pixels);
	j->kind = JOB_FILE;
	j->data = data;
	j->size = (size_t)header_len + pixels;
	path_of(j->path, sizeof j->path, "shot.pam");
	push_job(j);
}

/* The part of the eye image around the point straight ahead with the shape `aspect` (width /
 * height), as large as fits, then made smaller by `zoom` (1 = as large as fits) */
static XrRect2Di crop_rect(session_rec *s, double aspect, double zoom)
{
	XrRect2Di eye = s->eye_rect;
	int32_t w = eye.extent.width, h = eye.extent.height;
	if (aspect <= 0.01)
		aspect = 16.0 / 9.0;
	if (zoom <= 0.05 || zoom > 1.0)
		zoom = 1.0;
	double cw = w, ch = w / aspect;
	if (ch > h) {
		ch = h;
		cw = h * aspect;
	}
	cw *= zoom;
	ch *= zoom;
	int32_t iw = (int32_t)cw < 2 ? 2 : (int32_t)cw, ih = (int32_t)ch < 2 ? 2 : (int32_t)ch;
	/* Where the forward direction falls in the image, from the eye's field of view */
	double l = tan(s->eye_fov.angleLeft), r = tan(s->eye_fov.angleRight);
	double u = tan(s->eye_fov.angleUp), d = tan(s->eye_fov.angleDown);
	double fx = (r - l) > 1e-6 ? -l / (r - l) : 0.5;
	double fy = (u - d) > 1e-6 ? u / (u - d) : 0.5;
	int32_t cx = (int32_t)(fx * w) - iw / 2, cy = (int32_t)(fy * h) - ih / 2;
	if (cx + iw > w)
		cx = w - iw;
	if (cy + ih > h)
		cy = h - ih;
	if (cx < 0)
		cx = 0;
	if (cy < 0)
		cy = 0;
	XrRect2Di out = {{eye.offset.x + cx, eye.offset.y + cy}, {iw, ih}};
	return out;
}

static void record_frame(session_rec *s, swapchain_rec *sc, VkImage src)
{
	double now = now_seconds();
	if (now - s->rec_last < s->rec_interval * 0.9)
		return;
	target *slot = NULL;
	for (int i = 0; i < RECORD_SLOTS; i++)
		if (s->slots[i].state == 0) {
			slot = &s->slots[i];
			break;
		}
	if (!slot)
		return; /* the writer is behind: skip this frame */
	if (!target_make(s, slot, s->rec_w, s->rec_h, copy_format(sc->format)))
		return;
	if (!copy_eye(s, sc, src, crop_rect(s, (double)s->rec_w / s->rec_h, s->rec_zoom), slot))
		return;
	s->rec_last = now;
	slot->state = 1;
}

/* Hand finished frames to the writer (called once per frame and when stopping) */
static void collect_frames(session_rec *s, bool wait)
{
	for (int i = 0; i < RECORD_SLOTS; i++) {
		target *t = &s->slots[i];
		if (t->state != 1)
			continue;
		if (wait)
			s->fn.WaitForFences(s->device, 1, &t->fence, VK_TRUE, 1000000000ull);
		if (s->fn.GetFenceStatus(s->device, t->fence) != VK_SUCCESS)
			continue;
		make_visible(s, t);
		job *j = calloc(1, sizeof *j);
		if (!j) {
			t->state = 0;
			continue;
		}
		t->state = 2;
		j->kind = JOB_FRAME;
		j->slot = t;
		j->session = s;
		s->writer_jobs++;
		push_job(j);
	}
}

static void stop_recording(session_rec *s)
{
	if (!s->recording)
		return;
	s->recording = false;
	if (s->vk_ready)
		collect_frames(s, true);
	push_simple(JOB_CLOSE_FIFO, "record.fifo");
	say("recording stopped");
}

static void write_status(session_rec *s, double now)
{
	if (now - s->status_written < 2.0)
		return;
	s->status_written = now;
	char path[600], text[400];
	path_of(path, sizeof path, "game.status");
	int n = snprintf(text, sizeof text, "%s\n%dx%d\n", app_name, s->eye_rect.extent.width, s->eye_rect.extent.height);
	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd >= 0) {
		bool ok = true;
		write_all(fd, text, (size_t)n, &ok);
		close(fd);
	}
}

/* Look at the request files (once per frame, a couple of cheap system calls) */
static void check_requests(session_rec *s)
{
	double now = now_seconds();
	write_status(s, now);
	if (file_exists("screenshot.request")) {
		char path[600];
		path_of(path, sizeof path, "screenshot.request");
		unsigned w = 0, h = 0;
		double zoom = 1.0;
		FILE *fp = fopen(path, "r");
		if (fp) {
			if (fscanf(fp, "%u %u %lf", &w, &h, &zoom) < 2)
				w = h = 0;
			fclose(fp);
		}
		unlink(path);
		s->shot_aspect = (w && h) ? (double)w / h : 0.0;
		s->shot_zoom = zoom;
		s->shot_pending = true;
	}
	bool want = file_exists("record.on");
	if (want && !s->recording) {
		char path[600];
		path_of(path, sizeof path, "record.on");
		unsigned w = 1920, h = 1080, fps = 30;
		double zoom = 1.0;
		FILE *fp = fopen(path, "r");
		if (fp) {
			if (fscanf(fp, "%u %u %u %lf", &w, &h, &fps, &zoom) < 3) {
				w = 1920;
				h = 1080;
				fps = 30;
			}
			fclose(fp);
		}
		if (fps > 120)
			fps = 120;
		s->rec_zoom = zoom;
		s->rec_w = (w & ~1u) ? (w & ~1u) : 1920;
		s->rec_h = (h & ~1u) ? (h & ~1u) : 1080;
		s->rec_interval = 1.0 / (fps ? fps : 30);
		s->rec_last = 0;
		s->recording = true;
		push_simple(JOB_OPEN_FIFO, "record.fifo");
		say("recording %ux%u at %u fps", s->rec_w, s->rec_h, fps);
	} else if (!want && s->recording) {
		stop_recording(s);
	}
}

static void session_free(session_rec *s)
{
	stop_recording(s);
	if (s->vk_ready) {
		/* Wait (up to 5 s) for the writer to finish with this session's memory. If it is stuck
		 * on a recording nobody reads, leave the memory alone rather than hold the game up. */
		struct timespec until;
		clock_gettime(CLOCK_REALTIME, &until);
		until.tv_sec += 5;
		while (s->writer_jobs > 0)
			if (pthread_cond_timedwait(&done_cond, &lock, &until) == ETIMEDOUT)
				break;
		if (s->writer_jobs > 0) {
			say("a recording is still being written; leaving its memory to the driver");
			memset(s, 0, sizeof *s);
			return;
		}
		if (s->shot.fence)
			s->fn.WaitForFences(s->device, 1, &s->shot.fence, VK_TRUE, 1000000000ull);
		target_free(s, &s->shot);
		for (int i = 0; i < RECORD_SLOTS; i++)
			target_free(s, &s->slots[i]);
		s->fn.DestroyCommandPool(s->device, s->pool, NULL);
	}
	if (s->capture) {
		char path[600];
		path_of(path, sizeof path, "game.status");
		unlink(path);
	}
	memset(s, 0, sizeof *s);
}

/* ------------------------------------------------------------------ OpenXR hooks */
static XRAPI_ATTR XrResult XRAPI_CALL hook_CreateSession(XrInstance instance, const XrSessionCreateInfo *info, XrSession *session)
{
	XrResult result = next_CreateSession(instance, info, session);
	if (XR_FAILED(result))
		return result;
	const XrGraphicsBindingVulkanKHR *vulkan = NULL;
	bool overlay = false;
	for (const XrBaseInStructure *p = info->next; p; p = p->next) {
		if (p->type == XR_TYPE_GRAPHICS_BINDING_VULKAN_KHR)
			vulkan = (const XrGraphicsBindingVulkanKHR *)p;
		if (p->type == XR_TYPE_SESSION_CREATE_INFO_OVERLAY_EXTX)
			overlay = true;
	}
	pthread_mutex_lock(&lock);
	for (int i = 0; i < MAX_SESSIONS; i++) {
		if (sessions[i].handle != XR_NULL_HANDLE)
			continue;
		session_rec *s = &sessions[i];
		s->handle = *session;
		s->capture = vulkan && !overlay;
		if (vulkan) {
			s->vk_instance = vulkan->instance;
			s->physical = vulkan->physicalDevice;
			s->device = vulkan->device;
			s->queue_family = vulkan->queueFamilyIndex;
			s->queue_index = vulkan->queueIndex;
		}
		if (s->capture)
			say("ready to capture %s", app_name[0] ? app_name : "this game");
		break;
	}
	pthread_mutex_unlock(&lock);
	return result;
}

static XRAPI_ATTR XrResult XRAPI_CALL hook_DestroySession(XrSession session)
{
	pthread_mutex_lock(&lock);
	session_rec *s = find_session(session);
	if (s) {
		for (int i = 0; i < MAX_SWAPCHAINS; i++)
			if (swapchains[i].session == s)
				memset(&swapchains[i], 0, sizeof swapchains[i]);
		session_free(s);
	}
	pthread_mutex_unlock(&lock);
	return next_DestroySession(session);
}

static XRAPI_ATTR XrResult XRAPI_CALL hook_CreateSwapchain(XrSession session, const XrSwapchainCreateInfo *info, XrSwapchain *swapchain)
{
	pthread_mutex_lock(&lock);
	session_rec *s = find_session(session);
	bool color = (info->usageFlags & XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT) && info->sampleCount <= 1;
	bool watch = s && s->capture && color;
	pthread_mutex_unlock(&lock);

	XrSwapchainCreateInfo copy = *info;
	if (watch)
		copy.usageFlags |= XR_SWAPCHAIN_USAGE_TRANSFER_SRC_BIT; /* so the image may be copied from */
	XrResult result = next_CreateSwapchain(session, &copy, swapchain);
	if (XR_FAILED(result) && watch) /* the runtime doesn't like the extra flag: carry on without */
		result = next_CreateSwapchain(session, info, swapchain);
	if (XR_FAILED(result) || !watch)
		return result;

	pthread_mutex_lock(&lock);
	for (int i = 0; i < MAX_SWAPCHAINS; i++) {
		if (swapchains[i].handle != XR_NULL_HANDLE)
			continue;
		swapchain_rec *sc = &swapchains[i];
		memset(sc, 0, sizeof *sc);
		sc->handle = *swapchain;
		sc->session = find_session(session);
		sc->format = (VkFormat)info->format;
		sc->width = info->width;
		sc->height = info->height;
		sc->array_size = info->arraySize;
		sc->color = true;
		break;
	}
	pthread_mutex_unlock(&lock);
	return result;
}

static XRAPI_ATTR XrResult XRAPI_CALL hook_DestroySwapchain(XrSwapchain swapchain)
{
	pthread_mutex_lock(&lock);
	swapchain_rec *sc = find_swapchain(swapchain);
	if (sc) {
		if (sc->session && sc->session->eye_swapchain == swapchain)
			sc->session->eye_swapchain = XR_NULL_HANDLE;
		memset(sc, 0, sizeof *sc);
	}
	pthread_mutex_unlock(&lock);
	return next_DestroySwapchain(swapchain);
}

static XRAPI_ATTR XrResult XRAPI_CALL hook_EnumerateSwapchainImages(XrSwapchain swapchain, uint32_t capacity, uint32_t *count, XrSwapchainImageBaseHeader *images)
{
	XrResult result = next_EnumerateSwapchainImages(swapchain, capacity, count, images);
	if (XR_FAILED(result) || capacity == 0 || !images || images->type != XR_TYPE_SWAPCHAIN_IMAGE_VULKAN_KHR)
		return result;
	pthread_mutex_lock(&lock);
	swapchain_rec *sc = find_swapchain(swapchain);
	if (sc) {
		const XrSwapchainImageVulkanKHR *vk = (const XrSwapchainImageVulkanKHR *)images;
		sc->image_count = *count < MAX_IMAGES ? *count : MAX_IMAGES;
		for (uint32_t i = 0; i < sc->image_count; i++)
			sc->images[i] = vk[i].image;
	}
	pthread_mutex_unlock(&lock);
	return result;
}

static XRAPI_ATTR XrResult XRAPI_CALL hook_AcquireSwapchainImage(XrSwapchain swapchain, const XrSwapchainImageAcquireInfo *info, uint32_t *index)
{
	XrResult result = next_AcquireSwapchainImage(swapchain, info, index);
	if (XR_FAILED(result))
		return result;
	pthread_mutex_lock(&lock);
	swapchain_rec *sc = find_swapchain(swapchain);
	if (sc && sc->acquired_count < MAX_IMAGES) {
		sc->acquired[(sc->acquired_head + sc->acquired_count) % MAX_IMAGES] = *index;
		sc->acquired_count++;
	}
	pthread_mutex_unlock(&lock);
	return result;
}

static XRAPI_ATTR XrResult XRAPI_CALL hook_ReleaseSwapchainImage(XrSwapchain swapchain, const XrSwapchainImageReleaseInfo *info)
{
	pthread_mutex_lock(&lock);
	swapchain_rec *sc = find_swapchain(swapchain);
	if (sc && sc->acquired_count > 0) {
		/* Images are released in the order they were acquired */
		uint32_t index = sc->acquired[sc->acquired_head];
		sc->acquired_head = (sc->acquired_head + 1) % MAX_IMAGES;
		sc->acquired_count--;
		session_rec *s = sc->session;
		if (s && s->eye_swapchain == swapchain && (s->shot_pending || s->recording) && index < sc->image_count && vk_setup(s)) {
			VkImage image = sc->images[index];
			if (s->shot_pending)
				take_screenshot(s, sc, image);
			if (s->recording)
				record_frame(s, sc, image);
		}
	}
	pthread_mutex_unlock(&lock);
	/* Our copy was queued first, so the runtime only touches the image after it */
	return next_ReleaseSwapchainImage(swapchain, info);
}

static XRAPI_ATTR XrResult XRAPI_CALL hook_EndFrame(XrSession session, const XrFrameEndInfo *info)
{
	pthread_mutex_lock(&lock);
	session_rec *s = find_session(session);
	if (s && s->capture) {
		/* Remember the left eye of the game's main view for the next frame's copy */
		for (uint32_t i = 0; i < info->layerCount; i++) {
			const XrCompositionLayerBaseHeader *layer = info->layers[i];
			if (!layer || layer->type != XR_TYPE_COMPOSITION_LAYER_PROJECTION)
				continue;
			const XrCompositionLayerProjection *projection = (const XrCompositionLayerProjection *)layer;
			if (projection->viewCount < 1)
				continue;
			const XrCompositionLayerProjectionView *left = &projection->views[0];
			swapchain_rec *sc = find_swapchain(left->subImage.swapchain);
			if (sc) {
				s->eye_swapchain = left->subImage.swapchain;
				s->eye_rect = left->subImage.imageRect;
				s->eye_layer = left->subImage.imageArrayIndex;
				s->eye_fov = left->fov;
			}
			break;
		}
		check_requests(s);
		if (s->recording && s->vk_ready)
			collect_frames(s, false);
	}
	pthread_mutex_unlock(&lock);
	return next_EndFrame(session, info);
}

/* ------------------------------------------------------------------ dispatch */
static XRAPI_ATTR XrResult XRAPI_CALL hook_GetInstanceProcAddr(XrInstance instance, const char *name, PFN_xrVoidFunction *function)
{
	XrResult result = next_gipa(instance, name, function);
	if (XR_FAILED(result))
		return result;
#define HOOK(fn)                                              \
	if (strcmp(name, "xr" #fn) == 0) {                        \
		next_##fn = (PFN_xr##fn) * function;                    \
		*function = (PFN_xrVoidFunction)hook_##fn;              \
		return result;                                         \
	}
	HOOK(CreateSession)
	HOOK(DestroySession)
	HOOK(CreateSwapchain)
	HOOK(DestroySwapchain)
	HOOK(EnumerateSwapchainImages)
	HOOK(AcquireSwapchainImage)
	HOOK(ReleaseSwapchainImage)
	HOOK(EndFrame)
#undef HOOK
	if (strcmp(name, "xrGetInstanceProcAddr") == 0)
		*function = (PFN_xrVoidFunction)hook_GetInstanceProcAddr;
	return result;
}

static XRAPI_ATTR XrResult XRAPI_CALL layer_CreateApiLayerInstance(const XrInstanceCreateInfo *info, const XrApiLayerCreateInfo *layer_info, XrInstance *instance)
{
	if (!layer_info || !layer_info->nextInfo)
		return XR_ERROR_INITIALIZATION_FAILED;
	XrApiLayerCreateInfo next = *layer_info;
	next.nextInfo = layer_info->nextInfo->next;
	XrResult result = layer_info->nextInfo->nextCreateApiLayerInstance(info, &next, instance);
	if (XR_FAILED(result))
		return result;
	next_gipa = layer_info->nextInfo->nextGetInstanceProcAddr;
	snprintf(app_name, sizeof app_name, "%s", info->applicationInfo.applicationName);
	make_dirs();
	/* Resolve the functions we pass on, so they work even if the app looks them up directly */
	PFN_xrVoidFunction unused;
	const char *names[] = {"xrCreateSession", "xrDestroySession", "xrCreateSwapchain", "xrDestroySwapchain",
	                       "xrEnumerateSwapchainImages", "xrAcquireSwapchainImage", "xrReleaseSwapchainImage", "xrEndFrame"};
	for (size_t i = 0; i < sizeof names / sizeof names[0]; i++)
		hook_GetInstanceProcAddr(*instance, names[i], &unused);
	return result;
}

EXPORT XRAPI_ATTR XrResult XRAPI_CALL xrNegotiateLoaderApiLayerInterface(const XrNegotiateLoaderInfo *loader_info, const char *layer_name, XrNegotiateApiLayerRequest *request)
{
	(void)layer_name;
	if (!loader_info || !request || loader_info->structType != XR_LOADER_INTERFACE_STRUCT_LOADER_INFO ||
	    request->structType != XR_LOADER_INTERFACE_STRUCT_API_LAYER_REQUEST ||
	    loader_info->minInterfaceVersion > XR_CURRENT_LOADER_API_LAYER_VERSION ||
	    loader_info->maxInterfaceVersion < XR_CURRENT_LOADER_API_LAYER_VERSION)
		return XR_ERROR_INITIALIZATION_FAILED;
	request->layerInterfaceVersion = XR_CURRENT_LOADER_API_LAYER_VERSION;
	request->layerApiVersion = XR_API_VERSION_1_0;
	request->getInstanceProcAddr = hook_GetInstanceProcAddr;
	request->createApiLayerInstance = layer_CreateApiLayerInstance;
	return XR_SUCCESS;
}
