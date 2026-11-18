/*
 * mwm_data.c — the clipboard (wl_data_device_manager, wl_data_source,
 * wl_data_device, wl_data_offer).
 *
 * Programs copy and paste among themselves: what one copied is offered to
 * the one in front, and a paste has the copier write its data into the
 * paster's own pipe. Only the program in front sets the clipboard, and only
 * it is told what is on it.
 *
 * The Mac's clipboard and the VM's meet when the user says so on the Mac's
 * keyboard, and not otherwise: ⌘V makes the Mac's text what a paste gives
 * (mwm_server_paste); after ⌘C, what the program in front copies next is
 * read out for the Mac, once (mwm_server_copy). A program never reads the
 * Mac's clipboard by itself and never sets it by itself. Nothing is
 * dragged.
 */
#include "mwm_internal.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

enum { DEVICE_DATA_OFFER = 0, DEVICE_SELECTION = 5 };
enum { SOURCE_SEND = 1, SOURCE_CANCELLED = 2 };

/* The names text goes by, the first a program should be asked for. */
static const char *const text_kinds[] = {"text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT"};
enum { TEXT_KINDS = sizeof text_kinds / sizeof text_kinds[0] };

static bool is_text_kind(const char *mime) {
    for (int i = 0; i < TEXT_KINDS; i++)
        if (strcmp(mime, text_kinds[i]) == 0) return true;
    return false;
}

static bool offers(const source *src, const char *mime) {
    for (int i = 0; i < src->mime_count; i++)
        if (strcmp(src->mimes[i], mime) == 0) return true;
    return false;
}

/* Whether the bytes are UTF-8 text with no NUL in it. */
static bool is_text(const char *text, size_t len) {
    const unsigned char *p = (const unsigned char *)text, *end = p + len;
    while (p < end) {
        unsigned char c = *p++;
        int more = c < 0x80 ? 0 : (c & 0xe0) == 0xc0 ? 1 : (c & 0xf0) == 0xe0 ? 2 : (c & 0xf8) == 0xf0 ? 3 : -1;
        if (c == 0 || more < 0 || end - p < more) return false;
        uint32_t scalar = more == 0 ? c : c & (0x3f >> more);
        for (int i = 0; i < more; i++, p++) {
            if ((*p & 0xc0) != 0x80) return false;
            scalar = scalar << 6 | (*p & 0x3f);
        }
        static const uint32_t least[] = {0, 0x80, 0x800, 0x10000};
        if (scalar < least[more] || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) return false;
    }
    return true;
}

/* The program that has the keys; NULL when none does. */
static client *in_front(const mwm_server *s) {
    const window *w = s->seat.keyboard;
    return w && w->used && w->surface && !w->surface->owner->dead ? w->surface->owner : NULL;
}

/* ------------------------------------------------------------------------ */
/* Text on its way through a pipe                                            */

static void transfer_end(transfer *t) {
    if (t->fd >= 0) close(t->fd);
    free(t->data);
    *t = (transfer){.fd = -1};
}

/* Takes the descriptor; NULL (and it is closed) when it cannot be had. When
 * as many texts are under way as may be, the paste that waited longest is
 * given up on: a program that asks for the clipboard and never reads it
 * keeps no other from pasting. */
static transfer *transfer_begin(mwm_server *s, int fd, bool out) {
    transfer *slot = NULL, *oldest = NULL;
    for (int i = 0; i < MWM_MAX_TRANSFERS && !slot; i++) {
        transfer *t = &s->clipboard.transfers[i];
        if (t->fd < 0) slot = t;
        else if (t->out && (!oldest || (int32_t)(t->started - oldest->started) < 0)) oldest = t;
    }
    if (!slot && oldest) transfer_end(slot = oldest);
    int flags = fcntl(fd, F_GETFL);
    if (!slot || flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 || fcntl(fd, F_SETFD, FD_CLOEXEC) < 0) {
        close(fd);
        return NULL;
    }
    *slot = (transfer){.fd = fd, .out = out, .started = s->frame_time};
    return slot;
}

/* Writes what the pipe takes of the Mac's text now; the rest when it has room. */
static void transfer_write(transfer *t) {
    while (t->done < t->len) {
        ssize_t n = write(t->fd, t->data + t->done, t->len - t->done);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (n <= 0) break; /* the program closed its end */
        t->done += (size_t)n;
    }
    transfer_end(t);
}

/* What the user asked for with ⌘C: the copy's text, or nothing when the Mac
 * cannot have it (it is no text, or too much, or never came). The Mac is
 * told either way: its own clipboard is the older of the two from now on. */
static void hand_over(mwm_server *s, const char *text, size_t len) {
    if (s->clipboard.copied) s->clipboard.copied(s->clipboard.copied_ctx, text, len);
}

/* Reads what a program wrote of its copy; at its end, the Mac has it. */
static void transfer_read(mwm_server *s, transfer *t) {
    bool whole = false;
    for (;;) {
        if (!t->data && !(t->data = malloc(MWM_MAX_COPY + 1))) break;
        ssize_t n = read(t->fd, t->data + t->len, MWM_MAX_COPY + 1 - t->len);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (n < 0) break;
        if (n == 0) {
            whole = true;
            break;
        }
        t->len += (size_t)n;
        if (t->len > MWM_MAX_COPY) break; /* more than the Mac takes: none of it */
    }
    bool text = whole && t->len > 0 && is_text(t->data, t->len);
    hand_over(s, text ? t->data : "", text ? t->len : 0);
    transfer_end(t);
}

int mwm_data_sockets(const mwm_server *s, int *fds, bool *wants_write, int max) {
    int n = 0;
    for (int i = 0; i < MWM_MAX_TRANSFERS && n < max; i++) {
        const transfer *t = &s->clipboard.transfers[i];
        if (t->fd < 0) continue;
        fds[n] = t->fd;
        wants_write[n] = t->out;
        n++;
    }
    return n;
}

bool mwm_data_service(mwm_server *s, int fd) {
    for (int i = 0; i < MWM_MAX_TRANSFERS; i++) {
        transfer *t = &s->clipboard.transfers[i];
        if (t->fd != fd || fd < 0) continue;
        if (t->out) transfer_write(t);
        else transfer_read(s, t);
        return true;
    }
    return false;
}

bool mwm_data_waits(const mwm_server *s) {
    if (s->clipboard.armed) return true;
    for (int i = 0; i < MWM_MAX_TRANSFERS; i++)
        if (s->clipboard.transfers[i].fd >= 0 && !s->clipboard.transfers[i].out) return true;
    return false;
}

void mwm_data_frame(mwm_server *s, uint32_t time_ms) {
    if (s->clipboard.armed && (int32_t)(time_ms - s->clipboard.armed_at) > MWM_COPY_MS) s->clipboard.armed = false;
    for (int i = 0; i < MWM_MAX_TRANSFERS; i++) {
        transfer *t = &s->clipboard.transfers[i];
        /* A program asked for its copy that never writes it is not waited for. */
        if (t->fd >= 0 && !t->out && (int32_t)(time_ms - t->started) > MWM_COPY_MS) {
            hand_over(s, "", 0);
            transfer_end(t);
        }
    }
}

/* ------------------------------------------------------------------------ */
/* What is on the clipboard                                                  */

/* Tells the program what a paste would give it now: an offer for each of its devices, or none. */
static void announce(mwm_server *s, client *c) {
    const source *src = s->clipboard.source;
    bool something = src || s->clipboard.mac;
    for (uint32_t id = 0; id < c->object_cap; id++) {
        if (c->objects[id].type != T_DATA_DEVICE) continue;
        uint32_t offer = something ? mwm_add_server(c, T_DATA_OFFER, (void *)(uintptr_t)s->clipboard.generation) : 0;
        if (offer != 0) {
            mwm_event_uint(c, id, DEVICE_DATA_OFFER, offer);
            for (int i = 0; i < (src ? src->mime_count : TEXT_KINDS); i++) {
                mwm_put_begin(c->conn, offer, 0);
                mwm_put_string(c->conn, src ? src->mimes[i] : text_kinds[i]);
                mwm_put_end(c->conn);
            }
        }
        mwm_event_uint(c, id, DEVICE_SELECTION, offer); /* 0: nothing to paste (or more offers than it may keep) */
    }
    s->clipboard.told = c;
    s->clipboard.told_generation = s->clipboard.generation;
}

void mwm_data_focus(mwm_server *s, client *c) {
    if (c->dead || (s->clipboard.told == c && s->clipboard.told_generation == s->clipboard.generation)) return;
    announce(s, c);
}

/* Something else is on the clipboard, or nothing: the program whose copy it was is told, and the one in front. */
static void replace(mwm_server *s, source *src, char *mac, size_t mac_len) {
    source *old = s->clipboard.source;
    if (old && old != src && !old->owner->dead) {
        mwm_put_begin(old->owner->conn, old->id, SOURCE_CANCELLED);
        mwm_put_end(old->owner->conn);
    }
    free(s->clipboard.mac);
    s->clipboard.source = src;
    s->clipboard.mac = mac;
    s->clipboard.mac_len = mac_len;
    s->clipboard.generation++;
    client *front = in_front(s);
    if (front) announce(s, front);
}

bool mwm_server_paste(mwm_server *s, const char *text, size_t len) {
    if (len > MWM_MAX_CLIPBOARD || (len > 0 && (!text || !is_text(text, len)))) return false;
    char *copy = NULL;
    if (len > 0) {
        if (!(copy = malloc(len))) return false;
        memcpy(copy, text, len);
    } else if (!s->clipboard.mac) {
        return true; /* nothing of the Mac's was there */
    }
    replace(s, NULL, copy, len);
    mwm_flush(s);
    return true;
}

void mwm_server_copy(mwm_server *s, uint32_t time_ms) {
    s->clipboard.armed = true;
    s->clipboard.armed_at = time_ms;
}

void mwm_server_on_copied(mwm_server *s, mwm_copied copied, void *ctx) {
    s->clipboard.copied = copied;
    s->clipboard.copied_ctx = ctx;
}

/* The user asked for this copy on the Mac: the program is asked to write its text into a pipe of ours. */
static void read_out(mwm_server *s, const source *src) {
    const char *kind = NULL;
    for (int i = 0; i < TEXT_KINDS && !kind; i++)
        if (offers(src, text_kinds[i])) kind = text_kinds[i];
    int fds[2] = {-1, -1};
    transfer *t = kind && pipe(fds) == 0 ? transfer_begin(s, fds[0], false) : NULL;
    if (t) {
        t->started = s->clipboard.armed_at;
        mwm_put_begin(src->owner->conn, src->id, SOURCE_SEND);
        mwm_put_string(src->owner->conn, kind);
        mwm_put_fd(src->owner->conn, fds[1]);
        mwm_put_end(src->owner->conn);
    } else {
        hand_over(s, "", 0); /* a picture, say; or no pipe to be had */
    }
    if (fds[1] >= 0) close(fds[1]);
}

static void set_selection(mwm_server *s, client *c, mwm_msg *m) {
    uint32_t id = mwm_get_uint(m);
    (void)mwm_get_uint(m);
    if (m->bad) return;
    source *src = id != 0 ? mwm_find_as(c, id, T_DATA_SOURCE) : NULL;
    if (id != 0 && !src) {
        mwm_fail(c, m->object, E_INVALID_OBJECT, "not a data source");
        return;
    }
    if (in_front(s) != c) { /* not the program in front: its copy is not the clipboard */
        if (src) {
            mwm_put_begin(c->conn, src->id, SOURCE_CANCELLED);
            mwm_put_end(c->conn);
        }
        return;
    }
    if (!src && (!s->clipboard.source || s->clipboard.source->owner != c)) return; /* taking back what is not its own */
    replace(s, src, NULL, 0);
    if (src && s->clipboard.armed && (int32_t)(s->frame_time - s->clipboard.armed_at) <= MWM_COPY_MS) read_out(s, src);
    if (src) s->clipboard.armed = false; /* that key press has its answer, or was too long ago */
}

/* A paste: the data goes into the program's own pipe, from whoever has it. */
static void receive(mwm_server *s, client *c, uint32_t generation, mwm_msg *m) {
    uint32_t len;
    const char *mime = mwm_get_string(m, &len);
    int fd = mwm_get_fd(m);
    if (m->bad || !mime) {
        if (fd >= 0) close(fd);
        if (!m->bad) mwm_fail(c, m->object, E_INVALID_OBJECT, "no kind of data named");
        return;
    }
    const source *src = s->clipboard.source;
    if (generation != s->clipboard.generation) {
        close(fd); /* an offer of what is no longer on the clipboard */
    } else if (src && offers(src, mime) && !src->owner->dead) {
        mwm_put_begin(src->owner->conn, src->id, SOURCE_SEND);
        mwm_put_string(src->owner->conn, mime);
        mwm_put_fd(src->owner->conn, fd);
        mwm_put_end(src->owner->conn);
        close(fd);
    } else if (s->clipboard.mac && is_text_kind(mime)) {
        transfer *t = transfer_begin(s, fd, true);
        if (t && (t->data = malloc(s->clipboard.mac_len))) {
            memcpy(t->data, s->clipboard.mac, s->clipboard.mac_len);
            t->len = s->clipboard.mac_len;
            transfer_write(t);
        } else if (t) {
            transfer_end(t);
        }
    } else {
        close(fd); /* a kind nobody offered */
    }
}

/* ------------------------------------------------------------------------ */
/* Requests, and programs that go                                            */

void mwm_data_request(mwm_server *s, client *c, object *o, mwm_msg *m) {
    switch ((obj_type)o->type) {
    case T_DATA_MANAGER:
        if (m->opcode == 0) { /* create_data_source */
            uint32_t id = mwm_get_uint(m);
            if (m->bad) return;
            source *src = calloc(1, sizeof *src);
            if (!src) {
                mwm_fail(c, m->object, E_NO_MEMORY, "out of memory");
                return;
            }
            src->owner = c;
            src->id = id;
            if (!mwm_add(c, id, T_DATA_SOURCE, src)) free(src);
        } else if (m->opcode == 1) { /* get_data_device, for a seat */
            uint32_t id = mwm_get_uint(m), seat = mwm_get_uint(m);
            if (m->bad) return;
            if (!mwm_is(c, seat, T_SEAT)) {
                mwm_fail(c, m->object, E_INVALID_OBJECT, "not a seat");
                return;
            }
            if (mwm_add(c, id, T_DATA_DEVICE, NULL) && in_front(s) == c) announce(s, c); /* asked for late: told now */
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "wl_data_device_manager has no such request");
        }
        break;
    case T_DATA_SOURCE: {
        source *src = o->data;
        if (m->opcode == 0) { /* offer: one more kind its copy can be had as */
            uint32_t len;
            const char *mime = mwm_get_string(m, &len);
            if (m->bad) return;
            /* Kinds beyond what a copy may offer, or with names too long to be one, are not offered. */
            if (mime && len > 0 && len < MIME && src->mime_count < MAX_MIMES && !offers(src, mime)) {
                memcpy(src->mimes[src->mime_count++], mime, len + 1);
            }
        } else if (m->opcode == 1) { /* destroy: its copy is nobody's to paste */
            if (s->clipboard.source == src) replace(s, NULL, NULL, 0);
            mwm_del(c, m->object);
            free(src);
        } else if (m->opcode == 2) { /* set_actions: for dragging, which there is none of */
            mwm_skip_arguments(m);
        } else {
            mwm_fail(c, m->object, E_INVALID_METHOD, "wl_data_source has no such request");
        }
        break;
    }
    case T_DATA_DEVICE:
        if (m->opcode == 0) mwm_skip_arguments(m); /* start_drag: nothing is dragged */
        else if (m->opcode == 1) set_selection(s, c, m);
        else if (m->opcode == 2) mwm_del(c, m->object); /* release */
        else mwm_fail(c, m->object, E_INVALID_METHOD, "wl_data_device has no such request");
        break;
    case T_DATA_OFFER:
        if (m->opcode == 1) receive(s, c, (uint32_t)(uintptr_t)o->data, m);
        else if (m->opcode == 2) mwm_del(c, m->object); /* destroy */
        else if (m->opcode == 0 || m->opcode == 3 || m->opcode == 4) mwm_skip_arguments(m); /* accept, finish, set_actions: of drags */
        else mwm_fail(c, m->object, E_INVALID_METHOD, "wl_data_offer has no such request");
        break;
    default:
        break;
    }
}

void mwm_data_client_gone(mwm_server *s, client *c) {
    if (s->clipboard.told == c) s->clipboard.told = NULL;
    if (s->clipboard.source && s->clipboard.source->owner == c) replace(s, NULL, NULL, 0);
}

void mwm_data_init(mwm_server *s) {
    for (int i = 0; i < MWM_MAX_TRANSFERS; i++) s->clipboard.transfers[i].fd = -1;
}

void mwm_data_free(mwm_server *s) {
    for (int i = 0; i < MWM_MAX_TRANSFERS; i++) transfer_end(&s->clipboard.transfers[i]);
    free(s->clipboard.mac);
    s->clipboard.mac = NULL;
}
