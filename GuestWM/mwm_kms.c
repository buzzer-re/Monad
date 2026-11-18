/*
 * mwm_kms.c — the VM's display for Monad's window manager: Linux's
 * kernel mode setting, asked directly (ioctls on /dev/dri/card0, no
 * library). One framebuffer in the VM's memory of the size asked for,
 * which need not be a size the display lists: Apple's virtio-gpu device
 * takes any up to 8192 × 8192 and the Mac's side follows. What the window
 * manager draws there reaches the Mac when a rectangle is presented.
 *
 * Linux only; mwm_kms.h says what the rest sees.
 */
#include "mwm_kms.h"

#include <drm/drm.h>
#include <drm/drm_mode.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

struct mwm_kms {
    int fd;
    uint32_t fb, handle;
    uint32_t *pixels;
    size_t bytes;
    int width, height, stride;
};

static int xioctl(int fd, unsigned long request, void *arg) {
    int r;
    do {
        r = ioctl(fd, request, arg);
    } while (r < 0 && (errno == EINTR || errno == EAGAIN));
    return r;
}

static mwm_kms *failed(mwm_kms *k, char *err, size_t errlen, const char *what) {
    snprintf(err, errlen, "%s: %s", what, strerror(errno));
    mwm_kms_close(k);
    return NULL;
}

mwm_kms *mwm_kms_open(const char *card, int width, int height, char *err, size_t errlen) {
    mwm_kms *k = calloc(1, sizeof *k);
    if (!k) {
        snprintf(err, errlen, "out of memory");
        return NULL;
    }
    k->fd = open(card, O_RDWR | O_CLOEXEC);
    if (k->fd < 0) return failed(k, err, errlen, card);
    /* The first to open the card is its master already; said again for a card another program left. */
    (void)xioctl(k->fd, DRM_IOCTL_SET_MASTER, 0);

    uint32_t crtcs[8], connectors[8], encoders[8];
    struct drm_mode_card_res res = {0};
    if (xioctl(k->fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) return failed(k, err, errlen, "reading the display's resources");
    if (res.count_crtcs == 0 || res.count_connectors == 0 || res.count_crtcs > 8 || res.count_connectors > 8 || res.count_encoders > 8) {
        errno = ENODEV;
        return failed(k, err, errlen, "the card has no display Monad can use");
    }
    res.count_fbs = 0;
    res.crtc_id_ptr = (uintptr_t)crtcs;
    res.connector_id_ptr = (uintptr_t)connectors;
    res.encoder_id_ptr = (uintptr_t)encoders;
    if (xioctl(k->fd, DRM_IOCTL_MODE_GETRESOURCES, &res) < 0) return failed(k, err, errlen, "reading the display's resources");
    if (width < (int)res.min_width || height < (int)res.min_height || width > (int)res.max_width || height > (int)res.max_height) {
        errno = EINVAL;
        return failed(k, err, errlen, "the display cannot be that size");
    }

    struct drm_mode_create_dumb dumb = {.width = (uint32_t)width, .height = (uint32_t)height, .bpp = 32};
    if (xioctl(k->fd, DRM_IOCTL_MODE_CREATE_DUMB, &dumb) < 0) return failed(k, err, errlen, "making the framebuffer");
    k->handle = dumb.handle;
    struct drm_mode_fb_cmd fb = {.width = (uint32_t)width, .height = (uint32_t)height, .pitch = dumb.pitch, .bpp = 32, .depth = 24,
                                 .handle = dumb.handle};
    if (xioctl(k->fd, DRM_IOCTL_MODE_ADDFB, &fb) < 0) return failed(k, err, errlen, "adding the framebuffer");
    k->fb = fb.fb_id;
    struct drm_mode_map_dumb map = {.handle = dumb.handle};
    if (xioctl(k->fd, DRM_IOCTL_MODE_MAP_DUMB, &map) < 0) return failed(k, err, errlen, "mapping the framebuffer");
    void *pixels = mmap(NULL, dumb.size, PROT_READ | PROT_WRITE, MAP_SHARED, k->fd, (off_t)map.offset);
    if (pixels == MAP_FAILED) return failed(k, err, errlen, "mapping the framebuffer");
    k->pixels = pixels;
    k->bytes = dumb.size;
    k->width = width;
    k->height = height;
    k->stride = (int)(dumb.pitch / 4);
    memset(k->pixels, 0, k->bytes);

    /* A mode of exactly this size, with the blanking any 60 Hz mode has: only the size matters to the device. */
    struct drm_mode_modeinfo mode = {0};
    mode.hdisplay = (uint16_t)width;
    mode.hsync_start = (uint16_t)(width + 48);
    mode.hsync_end = (uint16_t)(width + 80);
    mode.htotal = (uint16_t)(width + 160);
    mode.vdisplay = (uint16_t)height;
    mode.vsync_start = (uint16_t)(height + 3);
    mode.vsync_end = (uint16_t)(height + 8);
    mode.vtotal = (uint16_t)(height + 40);
    mode.vrefresh = 60;
    mode.clock = (uint32_t)((uint64_t)mode.htotal * mode.vtotal * 60 / 1000);
    mode.type = DRM_MODE_TYPE_USERDEF;
    snprintf(mode.name, sizeof mode.name, "%dx%d", width, height);
    struct drm_mode_crtc crtc = {.crtc_id = crtcs[0], .fb_id = k->fb, .set_connectors_ptr = (uintptr_t)&connectors[0],
                                 .count_connectors = 1, .mode = mode, .mode_valid = 1};
    if (xioctl(k->fd, DRM_IOCTL_MODE_SETCRTC, &crtc) < 0) return failed(k, err, errlen, "setting the display's size");
    mwm_kms_present(k, 0, 0, width, height);
    return k;
}

void mwm_kms_close(mwm_kms *k) {
    if (!k) return;
    if (k->pixels) munmap(k->pixels, k->bytes);
    if (k->fd >= 0) {
        if (k->fb) (void)xioctl(k->fd, DRM_IOCTL_MODE_RMFB, &k->fb);
        if (k->handle) {
            struct drm_mode_destroy_dumb destroy = {.handle = k->handle};
            (void)xioctl(k->fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
        }
        close(k->fd);
    }
    free(k);
}

uint32_t *mwm_kms_pixels(const mwm_kms *k) { return k->pixels; }
int mwm_kms_stride(const mwm_kms *k) { return k->stride; }

void mwm_kms_present(mwm_kms *k, int x, int y, int width, int height) {
    if (width <= 0 || height <= 0) return;
    struct drm_clip_rect clip = {.x1 = (unsigned short)x, .y1 = (unsigned short)y, .x2 = (unsigned short)(x + width),
                                 .y2 = (unsigned short)(y + height)};
    struct drm_mode_fb_dirty_cmd dirty = {.fb_id = k->fb, .num_clips = 1, .clips_ptr = (uintptr_t)&clip};
    (void)xioctl(k->fd, DRM_IOCTL_MODE_DIRTYFB, &dirty);
}
