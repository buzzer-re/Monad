/*
 * mnd_diskcheck.c — see mnd_diskcheck.h. Plain C11, no platform calls: the
 * disk is read through the caller's callback, a sector or a superblock at a
 * time, never scanned.
 */
#include "mnd_diskcheck.h"

#include <string.h>
#include <zlib.h>

#define SECTOR 512u
#define MAX_GPT_ENTRIES 1024u
#define MAX_GPT_ENTRY_SIZE 1024u

typedef struct {
    mnd_disk_read_fn read;
    void *ctx;
    uint64_t size;
} disk;

/* Bytes [off, off + len) of the disk, or -1 when any of them is outside it. */
static int rd(const disk *d, uint64_t off, void *buf, size_t len) {
    if (off > d->size || len > d->size - off) return -1;
    return d->read(d->ctx, off, buf, len) == 0 ? 0 : -1;
}

/* The same within a partition of `len` bytes starting at `start`. */
static int prd(const disk *d, uint64_t start, uint64_t len, uint64_t off, void *buf, size_t n) {
    if (off > len || n > len - off) return -1;
    return rd(d, start + off, buf, n);
}

static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint64_t le64(const uint8_t *p) { return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32; }

uint32_t mnd_crc32c(uint32_t crc, const void *data, size_t len) {
    const uint8_t *p = data;
    while (len--) {
        crc ^= *p++;
        for (int k = 0; k < 8; k++) crc = (crc >> 1) ^ (0x82F63B78u & (0u - (crc & 1u)));
    }
    return crc;
}

/* Printable ASCII up to the first NUL, trailing spaces dropped (FAT pads). */
static void text(char *dst, size_t cap, const uint8_t *src, size_t n) {
    size_t j = 0;
    for (size_t i = 0; i < n && j + 1 < cap && src[i]; i++)
        dst[j++] = src[i] >= 0x20 && src[i] < 0x7f ? (char)src[i] : '?';
    while (j > 0 && dst[j - 1] == ' ') j--;
    dst[j] = 0;
}

/* ---- GPT ------------------------------------------------------------------------ */

/* A GUID as GPT stores it (the first three fields little-endian). */
static void guid(const char *s, uint8_t out[16]) {
    static const int order[16] = {3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15};
    uint8_t b[16] = {0};
    int n = 0;
    for (; *s && n < 32; s++) {
        int v = *s >= '0' && *s <= '9' ? *s - '0' : *s >= 'A' && *s <= 'F' ? *s - 'A' + 10 : -1;
        if (v < 0) continue;
        if (n % 2) b[n / 2] = (uint8_t)(b[n / 2] << 4 | v);
        else b[n / 2] = (uint8_t)v;
        n++;
    }
    for (int i = 0; i < 16; i++) out[i] = b[order[i]];
}

static mnd_part_kind kind_of(const uint8_t type[16]) {
    static const struct {
        const char *guid;
        mnd_part_kind kind;
    } known[] = {
        {"C12A7328-F81F-11D2-BA4B-00A0C93EC93B", MND_PART_EFI},
        {"B921B045-1DF0-41C3-AF44-4C6F280D3FAE", MND_PART_LINUX_ROOT}, /* arm64 */
        {"4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709", MND_PART_LINUX_ROOT}, /* x86-64 */
        {"BC13C2FF-59E6-4262-A352-B275FD6F7172", MND_PART_LINUX_BOOT},
        {"0FC63DAF-8483-4772-8E79-3D69D8477DE4", MND_PART_LINUX_DATA},
        {"0657FD6D-A4AB-43C4-84E5-0933C84B4F4F", MND_PART_LINUX_SWAP},
        {"E6D6D379-F507-44C2-A23C-238F2A3DF928", MND_PART_LINUX_LVM},
    };
    for (size_t i = 0; i < sizeof known / sizeof known[0]; i++) {
        uint8_t g[16];
        guid(known[i].guid, g);
        if (!memcmp(g, type, 16)) return known[i].kind;
    }
    return MND_PART_OTHER;
}

typedef struct {
    uint64_t entries_lba;
    uint32_t count, size;
} gpt_table;

/* The header at `lba` and the CRC of its table, both checked. */
static int gpt_header(const disk *d, uint64_t lba, gpt_table *t) {
    uint8_t h[SECTOR];
    if (rd(d, lba * SECTOR, h, SECTOR) || memcmp(h, "EFI PART", 8)) return -1;
    uint32_t hsize = le32(h + 12);
    if (hsize < 92 || hsize > SECTOR) return -1;
    uint32_t want = le32(h + 16);
    memset(h + 16, 0, 4);
    if ((uint32_t)crc32(0L, h, hsize) != want || le64(h + 24) != lba) return -1;
    t->entries_lba = le64(h + 72);
    t->count = le32(h + 80);
    t->size = le32(h + 84);
    if (!t->count || t->count > MAX_GPT_ENTRIES || t->size < 128 || t->size > MAX_GPT_ENTRY_SIZE || t->size % 8)
        return -1;
    uint64_t sectors = ((uint64_t)t->count * t->size + SECTOR - 1) / SECTOR;
    if (t->entries_lba < 1 || t->entries_lba > d->size / SECTOR || sectors > d->size / SECTOR - t->entries_lba)
        return -1;
    uint8_t buf[4096];
    uint32_t per = (uint32_t)(sizeof buf / t->size), crc = (uint32_t)crc32(0L, Z_NULL, 0);
    for (uint32_t i = 0; i < t->count; i += per) {
        uint32_t n = t->count - i < per ? t->count - i : per;
        if (rd(d, t->entries_lba * SECTOR + (uint64_t)i * t->size, buf, (size_t)n * t->size)) return -1;
        crc = (uint32_t)crc32(crc, buf, n * t->size);
    }
    return crc == le32(h + 88) ? 0 : -1;
}

static void probe(const disk *d, uint64_t start, uint64_t len, mnd_disk_part *p);

static void gpt_entries(const disk *d, const gpt_table *t, mnd_disk_report *out) {
    uint64_t sectors = d->size / SECTOR;
    uint8_t buf[4096];
    uint32_t per = (uint32_t)(sizeof buf / t->size);
    for (uint32_t i = 0; i < t->count; i += per) {
        uint32_t n = t->count - i < per ? t->count - i : per;
        if (rd(d, t->entries_lba * SECTOR + (uint64_t)i * t->size, buf, (size_t)n * t->size)) return;
        for (uint32_t k = 0; k < n; k++) {
            const uint8_t *e = buf + (size_t)k * t->size;
            static const uint8_t unused[16];
            if (!memcmp(e, unused, 16)) continue;
            uint64_t first = le64(e + 32), last = le64(e + 40);
            if (first < 1 || first > last || last >= sectors || out->count == MND_DISK_MAX_PARTS) {
                out->skipped++;
                continue;
            }
            mnd_disk_part *p = &out->parts[out->count++];
            p->number = i + k + 1;
            p->kind = kind_of(e);
            p->first_lba = first;
            p->last_lba = last;
            size_t j = 0;
            for (size_t c = 0; c < 36 && j + 1 < sizeof p->name; c++) {
                uint16_t u = le16(e + 56 + 2 * c);
                if (!u) break;
                p->name[j++] = u >= 0x20 && u < 0x7f ? (char)u : '?';
            }
            p->name[j] = 0;
            probe(d, first * SECTOR, (last - first + 1) * SECTOR, p);
        }
    }
}

/* ---- ext2, ext3, ext4 ------------------------------------------------------------ */

/* An intact superblock of the copy in group `group`: sane, and its checksum
 * holds where the filesystem keeps one. Its block size, or 0. */
static uint32_t ext_ok(const uint8_t sb[1024], uint16_t group) {
    if (le16(sb + 56) != 0xEF53 || le32(sb + 24) > 6) return 0;
    uint32_t bs = 1024u << le32(sb + 24), per_group = le32(sb + 32);
    if (!per_group || per_group > 8 * bs || le16(sb + 90) != group) return 0;
    if ((le32(sb + 100) & 0x400) && (sb[0x175] != 1 || mnd_crc32c(0xFFFFFFFFu, sb, 1020) != le32(sb + 1020)))
        return 0;
    return bs;
}

static int ext_primary(const disk *d, uint64_t start, uint64_t len, mnd_disk_part *p) {
    uint8_t sb[1024];
    if (prd(d, start, len, 1024, sb, sizeof sb)) return 0;
    uint32_t bs = ext_ok(sb, 0);
    if (!bs) return 0;
    p->fs = MND_FS_EXT;
    p->primary_ok = 1;
    p->block_size = bs;
    text(p->label, sizeof p->label, sb + 0x78, 16);
    p->error_count = le32(sb + 0x194);
    p->has_errors = (le16(sb + 58) & 2) || p->error_count;
    p->needs_recovery = (le32(sb + 96) & 0x4) != 0;
    p->first_error_time = le32(sb + 0x198);
    text(p->first_error_func, sizeof p->first_error_func, sb + 0x1A8, 32);
    p->last_error_time = le32(sb + 0x1CC);
    text(p->last_error_func, sizeof p->last_error_func, sb + 0x1E0, 32);
    return 1;
}

/* Backup copies sit at the start of groups 1 and the powers of 3, 5 and 7
 * (sparse_super); the block size is not known without the main copy. */
static int ext_backup(const disk *d, uint64_t start, uint64_t len, mnd_disk_part *p) {
    static const uint32_t sizes[] = {4096, 1024, 2048};
    static const uint16_t groups[] = {1, 3, 5, 7, 9, 25, 27, 49};
    uint8_t sb[1024];
    for (size_t s = 0; s < sizeof sizes / sizeof sizes[0]; s++) {
        uint32_t bs = sizes[s];
        for (size_t g = 0; g < sizeof groups / sizeof groups[0]; g++) {
            uint64_t block = (uint64_t)groups[g] * 8 * bs + (bs == 1024);
            if (block * bs + sizeof sb > len) break;
            if (prd(d, start, len, block * bs, sb, sizeof sb) || ext_ok(sb, groups[g]) != bs) continue;
            p->fs = MND_FS_EXT;
            p->backup_ok = 1;
            p->backup_block = block;
            p->block_size = bs;
            text(p->label, sizeof p->label, sb + 0x78, 16);
            return 1;
        }
    }
    return 0;
}

/* ---- the others ------------------------------------------------------------------ */

/* btrfs: the main copy at 64 KiB, a mirror at 64 MiB; 1 intact, 0 damaged,
 * -1 not btrfs. */
static int btrfs_copy(const disk *d, uint64_t start, uint64_t len, uint64_t off, char *label, size_t cap) {
    uint8_t sb[4096];
    if (prd(d, start, len, off, sb, sizeof sb) || memcmp(sb + 0x40, "_BHRfS_M", 8)) return -1;
    if (le16(sb + 0xC4) == 0 && (mnd_crc32c(0xFFFFFFFFu, sb + 0x20, sizeof sb - 0x20) ^ 0xFFFFFFFFu) != le32(sb))
        return 0;
    text(label, cap, sb + 0x12B, 256);
    return 1;
}

static int fat_boot_sector(const uint8_t b[SECTOR], char *label, size_t cap) {
    uint16_t bps = le16(b + 11);
    uint8_t spc = b[13], fats = b[16];
    if (b[510] != 0x55 || b[511] != 0xAA || (bps != 512 && bps != 1024 && bps != 2048 && bps != 4096)) return 0;
    if (!spc || (spc & (spc - 1)) || !le16(b + 14) || fats < 1 || fats > 2) return 0;
    if (le16(b + 22) == 0 && !memcmp(b + 82, "FAT32", 5)) text(label, cap, b + 71, 11);
    else if (b[38] == 0x29) text(label, cap, b + 43, 11);
    return 1;
}

static int swap_signature(const disk *d, uint64_t start, uint64_t len) {
    static const uint64_t pages[] = {4096, 16384, 65536};
    char sig[10];
    for (size_t i = 0; i < 3; i++)
        if (!prd(d, start, len, pages[i] - 10, sig, sizeof sig) && !memcmp(sig, "SWAPSPACE2", 10)) return 1;
    return 0;
}

static void probe(const disk *d, uint64_t start, uint64_t len, mnd_disk_part *p) {
    uint8_t s[SECTOR];
    char label[sizeof p->label] = "";
    if (ext_primary(d, start, len, p)) return;
    if (!prd(d, start, len, 0, s, SECTOR) && !memcmp(s, "XFSB", 4)) {
        p->fs = MND_FS_XFS;
        p->primary_ok = 1;
        text(p->label, sizeof p->label, s + 108, 12);
        return;
    }
    int copy = btrfs_copy(d, start, len, 0x10000, p->label, sizeof p->label);
    int mirror = btrfs_copy(d, start, len, 0x4000000, label, sizeof label);
    if (copy >= 0 || mirror == 1) {
        p->fs = MND_FS_BTRFS;
        p->primary_ok = copy == 1;
        p->backup_ok = mirror == 1;
        if (copy != 1) memcpy(p->label, label, sizeof label);
        return;
    }
    if (!prd(d, start, len, 0, s, SECTOR) && fat_boot_sector(s, p->label, sizeof p->label)) {
        p->fs = MND_FS_FAT;
        p->primary_ok = 1;
        uint16_t backup = le16(s + 50);
        if (le16(s + 22) == 0 && backup >= 1 && backup <= 32 && !prd(d, start, len, (uint64_t)backup * SECTOR, s, SECTOR))
            p->backup_ok = fat_boot_sector(s, label, sizeof label);
        return;
    }
    if (!prd(d, start, len, 0, s, SECTOR) && !memcmp(s, "LUKS\xba\xbe", 6)) {
        p->fs = MND_FS_LUKS;
        p->primary_ok = 1;
        return;
    }
    for (uint64_t i = 0; i < 4; i++) {
        if (!prd(d, start, len, i * SECTOR, s, SECTOR) && !memcmp(s, "LABELONE", 8)) {
            p->fs = MND_FS_LVM;
            p->primary_ok = 1;
            return;
        }
    }
    if (swap_signature(d, start, len)) {
        p->fs = MND_FS_SWAP;
        p->primary_ok = 1;
        return;
    }
    if (ext_backup(d, start, len, p)) return;
    /* A FAT32 whose boot sector is gone keeps a copy at sector 6. */
    if (!prd(d, start, len, 6 * SECTOR, s, SECTOR) && fat_boot_sector(s, p->label, sizeof p->label) &&
        le16(s + 22) == 0) {
        p->fs = MND_FS_FAT;
        p->backup_ok = 1;
    }
}

int mnd_disk_check(mnd_disk_read_fn read, void *ctx, uint64_t size, mnd_disk_report *out) {
    memset(out, 0, sizeof *out);
    disk d = {read, ctx, size};
    uint8_t first[SECTOR];
    if (!read || rd(&d, 0, first, SECTOR)) return -1;
    gpt_table t;
    uint64_t last = size / SECTOR - 1;
    if (size / SECTOR > 2 && gpt_header(&d, 1, &t) == 0) {
        out->gpt = MND_GPT_OK;
    } else if (size / SECTOR > 2 && gpt_header(&d, last, &t) == 0) {
        out->gpt = MND_GPT_BACKUP;
    } else {
        mnd_disk_part *p = &out->parts[out->count++];
        p->kind = MND_PART_OTHER;
        p->last_lba = last;
        probe(&d, 0, size, p);
        return 0;
    }
    gpt_entries(&d, &t, out);
    return 0;
}
