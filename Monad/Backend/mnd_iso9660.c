/*
 * mnd_iso9660.c — minimal ECMA-119 (ISO 9660) + Joliet writer.
 *
 * Layout (2048-byte sectors):
 *   0-15  system area            19-22 path tables (L/M primary, L/M Joliet)
 *   16    primary descriptor     23..  primary root directory
 *   17    Joliet descriptor      ..    Joliet root directory
 *   18    terminator             ..    file data
 */
#include "mnd_iso9660.h"

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define SECTOR 2048u
#define MAX_FILES 256

typedef struct {
    const mnd_iso_file *f;
    char pname[40]; /* primary identifier, e.g. USER_DATA.;1 */
    uint8_t jname[128];
    size_t jlen;
    uint32_t lba;
} entry;

static void le16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}
static void be16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)v;
}
static void le32(uint8_t *p, uint32_t v) {
    for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}
static void be32(uint8_t *p, uint32_t v) {
    for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * (3 - i)));
}
static void both16(uint8_t *p, uint16_t v) {
    le16(p, v);
    be16(p + 2, v);
}
static void both32(uint8_t *p, uint32_t v) {
    le32(p, v);
    be32(p + 4, v);
}

static uint32_t sectors_for(size_t n) { return (uint32_t)((n + SECTOR - 1) / SECTOR); }

static void fill_ascii(uint8_t *p, size_t n, const char *s) {
    memset(p, ' ', n);
    size_t l = strlen(s);
    memcpy(p, s, l < n ? l : n);
}

static void fill_ucs2(uint8_t *p, size_t n, const char *s) {
    for (size_t i = 0; i + 1 < n; i += 2) {
        p[i] = 0;
        p[i + 1] = ' ';
    }
    size_t l = strlen(s);
    for (size_t i = 0; i < l && 2 * i + 1 < n; i++) {
        p[2 * i] = 0;
        p[2 * i + 1] = (uint8_t)s[i];
    }
}

static void date7(uint8_t *d, const struct tm *t) {
    d[0] = (uint8_t)t->tm_year;
    d[1] = (uint8_t)(t->tm_mon + 1);
    d[2] = (uint8_t)t->tm_mday;
    d[3] = (uint8_t)t->tm_hour;
    d[4] = (uint8_t)t->tm_min;
    d[5] = (uint8_t)t->tm_sec;
    d[6] = 0; /* UTC */
}

static void date17(uint8_t *d, const struct tm *t) {
    char buf[20];
    snprintf(buf, sizeof buf, "%04d%02d%02d%02d%02d%02d00", t->tm_year + 1900, t->tm_mon + 1, t->tm_mday,
             t->tm_hour, t->tm_min, t->tm_sec);
    memcpy(d, buf, 16);
    d[16] = 0;
}

static void date17_empty(uint8_t *d) {
    memset(d, '0', 16);
    d[16] = 0;
}

/* Directory record; returns its length (always even). */
static size_t dirrec(uint8_t *p, uint32_t lba, uint32_t size, uint8_t flags, const uint8_t *id, size_t idlen,
                     const uint8_t d[7]) {
    size_t len = 33 + idlen;
    if (len & 1) len++;
    memset(p, 0, len);
    p[0] = (uint8_t)len;
    both32(p + 2, lba);
    both32(p + 10, size);
    memcpy(p + 18, d, 7);
    p[25] = flags;
    both16(p + 28, 1);
    p[32] = (uint8_t)idlen;
    memcpy(p + 33, id, idlen);
    return len;
}

static size_t dirrec_len(size_t idlen) { return (33 + idlen + 1) & ~(size_t)1; }

/* Size of a directory's extent, keeping records inside sector boundaries. */
static size_t dir_size(const entry *e, size_t n, bool joliet) {
    size_t off = 34 * 2; /* "." and ".." */
    for (size_t i = 0; i < n; i++) {
        size_t l = dirrec_len(joliet ? e[i].jlen : strlen(e[i].pname));
        if (off % SECTOR + l > SECTOR) off = (off / SECTOR + 1) * SECTOR;
        off += l;
    }
    return sectors_for(off) * SECTOR;
}

static void build_dir(uint8_t *buf, uint32_t self_lba, uint32_t self_size, const entry *e, size_t n, bool joliet,
                      const uint8_t d[7]) {
    size_t off = 0;
    const uint8_t dot = 0, dotdot = 1;
    off += dirrec(buf + off, self_lba, self_size, 2, &dot, 1, d);
    off += dirrec(buf + off, self_lba, self_size, 2, &dotdot, 1, d);
    for (size_t i = 0; i < n; i++) {
        const uint8_t *id = joliet ? e[i].jname : (const uint8_t *)e[i].pname;
        size_t idlen = joliet ? e[i].jlen : strlen(e[i].pname);
        size_t l = dirrec_len(idlen);
        if (off % SECTOR + l > SECTOR) off = (off / SECTOR + 1) * SECTOR;
        off += dirrec(buf + off, e[i].lba, (uint32_t)e[i].f->len, 0, id, idlen, d);
    }
}

static void build_vd(uint8_t *p, bool joliet, const char *vol, uint32_t total, uint32_t ptl, uint32_t ptm,
                     uint32_t root_lba, uint32_t root_size, const struct tm *t) {
    uint8_t d7[7];
    date7(d7, t);
    memset(p, 0, SECTOR);
    p[0] = joliet ? 2 : 1;
    memcpy(p + 1, "CD001", 5);
    p[6] = 1;
    if (joliet) {
        fill_ucs2(p + 8, 32, "");
        fill_ucs2(p + 40, 32, vol);
        p[88] = 0x25;
        p[89] = 0x2F;
        p[90] = 0x45; /* UCS-2 level 3 */
    } else {
        fill_ascii(p + 8, 32, "");
        fill_ascii(p + 40, 32, vol);
    }
    both32(p + 80, total);
    both16(p + 120, 1);
    both16(p + 124, 1);
    both16(p + 128, SECTOR);
    both32(p + 132, 10);
    le32(p + 140, ptl);
    be32(p + 148, ptm);
    const uint8_t root_id = 0;
    dirrec(p + 156, root_lba, root_size, 2, &root_id, 1, d7);
    if (joliet) {
        fill_ucs2(p + 190, 128, "");
        fill_ucs2(p + 318, 128, "");
        fill_ucs2(p + 446, 128, "");
        fill_ucs2(p + 574, 128, "MONAD");
        fill_ucs2(p + 702, 37, "");
        fill_ucs2(p + 739, 37, "");
        fill_ucs2(p + 776, 37, "");
    } else {
        fill_ascii(p + 190, 128, "");
        fill_ascii(p + 318, 128, "");
        fill_ascii(p + 446, 128, "");
        fill_ascii(p + 574, 128, "MONAD");
        fill_ascii(p + 702, 37, "");
        fill_ascii(p + 739, 37, "");
        fill_ascii(p + 776, 37, "");
    }
    date17(p + 813, t);
    date17(p + 830, t);
    date17_empty(p + 847);
    date17_empty(p + 864);
    p[881] = 1;
}

static void build_path_table(uint8_t *p, uint32_t root_lba, bool big_endian) {
    memset(p, 0, SECTOR);
    p[0] = 1;
    p[1] = 0;
    if (big_endian) {
        be32(p + 2, root_lba);
        be16(p + 6, 1);
    } else {
        le32(p + 2, root_lba);
        le16(p + 6, 1);
    }
    p[8] = 0;
}

static bool valid_name(const char *s) {
    size_t n = strlen(s);
    if (n == 0 || n > 64) return false;
    for (size_t i = 0; i < n; i++) {
        char c = s[i];
        bool ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' ||
                  c == '_' || c == '-';
        if (!ok) return false;
    }
    return true;
}

static int cmp_entry(const void *a, const void *b) {
    return strcmp(((const entry *)a)->pname, ((const entry *)b)->pname);
}

static int write_all(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w < 0) {
            if (errno == EINTR) continue;
            return errno;
        }
        p += w;
        n -= (size_t)w;
    }
    return 0;
}

int mnd_iso9660_write(const char *path, const char *volume_id, const mnd_iso_file *files, size_t nfiles) {
    if (!path || !volume_id || (!files && nfiles) || nfiles > MAX_FILES) return EINVAL;
    size_t vl = strlen(volume_id);
    if (vl == 0 || vl > 16) return EINVAL;
    for (size_t i = 0; i < vl; i++) {
        char c = volume_id[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) return EINVAL;
    }
    char vol_upper[17];
    for (size_t i = 0; i <= vl; i++)
        vol_upper[i] = (char)((volume_id[i] >= 'a' && volume_id[i] <= 'z') ? volume_id[i] - 32 : volume_id[i]);

    entry *e = calloc(nfiles ? nfiles : 1, sizeof *e);
    if (!e) return ENOMEM;
    for (size_t i = 0; i < nfiles; i++) {
        if (!files[i].name || !valid_name(files[i].name) || files[i].len > 0xFFFFFFFFu) {
            free(e);
            return EINVAL;
        }
        e[i].f = &files[i];
        /* Primary name: uppercase d-characters, "NAME.EXT;1" (max 30 chars). */
        const char *s = files[i].name;
        const char *dot = strrchr(s, '.');
        char base[25] = {0}, ext[6] = {0}; /* 24 + 1 + 5 + ";1" fits pname */
        size_t bl = 0, el = 0;
        for (const char *c = s; *c && (dot == NULL || c < dot) && bl < 24; c++) {
            char u = (*c >= 'a' && *c <= 'z') ? (char)(*c - 32) : *c;
            base[bl++] = ((u >= 'A' && u <= 'Z') || (u >= '0' && u <= '9')) ? u : '_';
        }
        if (dot)
            for (const char *c = dot + 1; *c && el < 5; c++) {
                char u = (*c >= 'a' && *c <= 'z') ? (char)(*c - 32) : *c;
                ext[el++] = ((u >= 'A' && u <= 'Z') || (u >= '0' && u <= '9')) ? u : '_';
            }
        snprintf(e[i].pname, sizeof e[i].pname, "%s.%s;1", base, ext);
        size_t nl = strlen(s);
        for (size_t k = 0; k < nl; k++) {
            e[i].jname[2 * k] = 0;
            e[i].jname[2 * k + 1] = (uint8_t)s[k];
        }
        e[i].jlen = 2 * nl;
    }
    qsort(e, nfiles, sizeof *e, cmp_entry);
    for (size_t i = 1; i < nfiles; i++) {
        if (strcmp(e[i].pname, e[i - 1].pname) == 0) {
            free(e);
            return EINVAL; /* names collide after mapping */
        }
    }

    const uint32_t lba_ptl = 19, lba_ptm = 20, lba_jptl = 21, lba_jptm = 22;
    const uint32_t lba_proot = 23;
    size_t psize = dir_size(e, nfiles, false), jsize = dir_size(e, nfiles, true);
    uint32_t lba_jroot = lba_proot + sectors_for(psize);
    uint32_t next = lba_jroot + sectors_for(jsize);
    for (size_t i = 0; i < nfiles; i++) {
        e[i].lba = next;
        next += sectors_for(e[i].f->len);
    }
    uint32_t total = next;

    time_t now = time(NULL);
    struct tm t;
    gmtime_r(&now, &t);
    uint8_t d7[7];
    date7(d7, &t);

    uint8_t *meta = calloc((size_t)lba_jroot + sectors_for(jsize), SECTOR);
    if (!meta) {
        free(e);
        return ENOMEM;
    }
    build_vd(meta + 16 * SECTOR, false, vol_upper, total, lba_ptl, lba_ptm, lba_proot, (uint32_t)psize, &t);
    build_vd(meta + 17 * SECTOR, true, volume_id, total, lba_jptl, lba_jptm, lba_jroot, (uint32_t)jsize, &t);
    uint8_t *term = meta + 18 * SECTOR;
    term[0] = 255;
    memcpy(term + 1, "CD001", 5);
    term[6] = 1;
    build_path_table(meta + lba_ptl * SECTOR, lba_proot, false);
    build_path_table(meta + lba_ptm * SECTOR, lba_proot, true);
    build_path_table(meta + lba_jptl * SECTOR, lba_jroot, false);
    build_path_table(meta + lba_jptm * SECTOR, lba_jroot, true);
    build_dir(meta + lba_proot * SECTOR, lba_proot, (uint32_t)psize, e, nfiles, false, d7);
    build_dir(meta + lba_jroot * SECTOR, lba_jroot, (uint32_t)jsize, e, nfiles, true, d7);

    size_t plen = strlen(path);
    char *tmp = malloc(plen + 16);
    if (!tmp) {
        free(meta);
        free(e);
        return ENOMEM;
    }
    snprintf(tmp, plen + 16, "%s.tmp%d", path, (int)getpid());
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    int err = fd < 0 ? errno : 0;
    if (!err) err = write_all(fd, meta, ((size_t)lba_jroot + sectors_for(jsize)) * SECTOR);
    static const uint8_t zeros[SECTOR];
    for (size_t i = 0; i < nfiles && !err; i++) {
        err = write_all(fd, e[i].f->data, e[i].f->len);
        size_t pad = (SECTOR - e[i].f->len % SECTOR) % SECTOR;
        if (!err && pad) err = write_all(fd, zeros, pad);
    }
    if (!err && fsync(fd) != 0) err = errno;
    if (fd >= 0 && close(fd) != 0 && !err) err = errno;
    if (!err && rename(tmp, path) != 0) err = errno;
    if (err) unlink(tmp);
    free(tmp);
    free(meta);
    free(e);
    return err;
}
