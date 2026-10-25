/* Tests for mnd_diskcheck against disks from gen_disk_fixtures.py, kept as
 * regions: everything outside them reads as zeros. */
#include "../Monad/Backend/mnd_diskcheck.h"
#include "test_util.h"

#include <stdint.h>

static const char *g_dir = ".";

typedef struct {
    uint64_t off;
    uint32_t len;
    const uint8_t *data;
} region;

typedef struct {
    uint64_t size;
    unsigned count;
    region r[64];
    uint8_t *blob;
    unsigned reads;
} vdisk;

static uint64_t le64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = v << 8 | p[i];
    return v;
}
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

static int load(const char *name, vdisk *d) {
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", g_dir, name);
    memset(d, 0, sizeof *d);
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    d->blob = malloc((size_t)n);
    if (!d->blob || fread(d->blob, 1, (size_t)n, f) != (size_t)n || n < 20 || memcmp(d->blob, "MNDDISK1", 8)) {
        fclose(f);
        return -1;
    }
    fclose(f);
    d->size = le64(d->blob + 8);
    unsigned count = le32(d->blob + 16);
    size_t pos = 20;
    for (unsigned i = 0; i < count && i < 64 && pos + 12 <= (size_t)n; i++) {
        region *r = &d->r[d->count++];
        r->off = le64(d->blob + pos);
        r->len = le32(d->blob + pos + 8);
        r->data = d->blob + pos + 12;
        pos += 12 + r->len;
    }
    return 0;
}

static int vread(void *ctx, uint64_t off, void *buf, size_t len) {
    vdisk *d = ctx;
    d->reads++;
    if (off > d->size || len > d->size - off) return -1;
    memset(buf, 0, len);
    for (unsigned i = 0; i < d->count; i++) {
        const region *r = &d->r[i];
        uint64_t a = off > r->off ? off : r->off;
        uint64_t b = off + len < r->off + r->len ? off + len : r->off + r->len;
        if (a < b) memcpy((uint8_t *)buf + (a - off), r->data + (a - r->off), (size_t)(b - a));
    }
    return 0;
}

static mnd_disk_report check(const char *name, vdisk *d) {
    mnd_disk_report rep;
    memset(&rep, 0xA5, sizeof rep); /* nothing may be left as it was */
    CHECK(load(name, d) == 0);
    CHECK(mnd_disk_check(vread, d, d->size, &rep) == 0);
    return rep;
}

static const mnd_disk_part *part(const mnd_disk_report *r, unsigned number) {
    for (unsigned i = 0; i < r->count; i++)
        if (r->parts[i].number == number) return &r->parts[i];
    return NULL;
}

/* Shaped like Ubuntu's cloud image: everything intact. Only a few small
 * reads, never a scan. */
static void test_cloud(void) {
    vdisk d;
    mnd_disk_report r = check("disk_cloud.regions", &d);
    CHECK(r.gpt == MND_GPT_OK);
    CHECK(r.count == 3);
    CHECK(r.skipped == 0);
    const mnd_disk_part *root = part(&r, 1), *boot = part(&r, 13), *efi = part(&r, 15);
    CHECK(root && boot && efi);
    if (!root || !boot || !efi) return;
    CHECK(root->kind == MND_PART_LINUX_ROOT);
    CHECK(root->first_lba == 2099200);
    CHECK(root->fs == MND_FS_EXT);
    CHECK(root->primary_ok == 1);
    CHECK_STR(root->label, "cloudimg-rootfs");
    CHECK(root->block_size == 4096);
    CHECK(root->has_errors == 0 && root->needs_recovery == 0 && root->error_count == 0);
    CHECK(boot->kind == MND_PART_LINUX_BOOT);
    CHECK(boot->fs == MND_FS_EXT && boot->primary_ok == 1);
    CHECK_STR(boot->label, "BOOT");
    CHECK(boot->block_size == 1024);
    CHECK(efi->kind == MND_PART_EFI);
    CHECK(efi->fs == MND_FS_FAT && efi->primary_ok == 1);
    CHECK_STR(efi->label, "UEFI");
    CHECK(d.reads < 100);
    free(d.blob);
}

/* The incident: the root's main superblock zeroed but for the counters and
 * the error being recorded. Its backup at block 32768 says what it was. */
static void test_zeroed_root(void) {
    vdisk d;
    mnd_disk_report r = check("disk_zeroed_root.regions", &d);
    const mnd_disk_part *root = part(&r, 1);
    CHECK(root != NULL);
    if (!root) return;
    CHECK(root->fs == MND_FS_EXT);
    CHECK(root->primary_ok == 0);
    CHECK(root->backup_ok == 1);
    CHECK(root->backup_block == 32768);
    CHECK(root->block_size == 4096);
    CHECK_STR(root->label, "cloudimg-rootfs");
    CHECK(root->has_errors == 0); /* a damaged superblock says nothing to trust */
    CHECK_STR(root->first_error_func, "");
    const mnd_disk_part *boot = part(&r, 13);
    CHECK(boot && boot->primary_ok == 1);
    free(d.blob);
}

/* An intact superblock that recorded errors, its journal not replayed. */
static void test_root_errors(void) {
    vdisk d;
    mnd_disk_report r = check("disk_root_errors.regions", &d);
    const mnd_disk_part *root = part(&r, 1);
    CHECK(root != NULL);
    if (!root) return;
    CHECK(root->fs == MND_FS_EXT && root->primary_ok == 1);
    CHECK(root->has_errors == 1);
    CHECK(root->needs_recovery == 1);
    CHECK(root->error_count == 1);
    CHECK_STR(root->first_error_func, "ext4_reserve_inode_write");
    CHECK(root->first_error_time == 0x6ADE1042);
    CHECK_STR(root->last_error_func, "ext4_reserve_inode_write");
    CHECK(root->last_error_time == 0x6ADE1042);
    free(d.blob);
}

/* A superblock whose checksum does not hold is one the kernel will not
 * mount: damaged, with its backup intact. */
static void test_bad_checksum(void) {
    vdisk d;
    mnd_disk_report r = check("disk_bad_csum.regions", &d);
    const mnd_disk_part *root = part(&r, 1);
    CHECK(root && root->fs == MND_FS_EXT && root->primary_ok == 0 && root->backup_ok == 1);
    free(d.blob);
}

static void test_gpt_backup_only(void) {
    vdisk d;
    mnd_disk_report r = check("disk_gpt_backup.regions", &d);
    CHECK(r.gpt == MND_GPT_BACKUP);
    CHECK(r.count == 3);
    const mnd_disk_part *root = part(&r, 1);
    CHECK(root && root->primary_ok == 1);
    free(d.blob);
}

static void test_other_filesystems(void) {
    vdisk d;
    mnd_disk_report r = check("disk_others.regions", &d);
    CHECK(r.gpt == MND_GPT_OK);
    CHECK(r.count == 7);
    const mnd_disk_part *p;
    p = part(&r, 1);
    CHECK(p && p->fs == MND_FS_XFS && p->primary_ok == 1);
    if (p) CHECK_STR(p->label, "xfsroot");
    if (p) CHECK_STR(p->name, "xfsroot");
    p = part(&r, 2);
    CHECK(p && p->fs == MND_FS_BTRFS && p->primary_ok == 1 && p->backup_ok == 1);
    if (p) CHECK_STR(p->label, "data");
    p = part(&r, 3);
    CHECK(p && p->kind == MND_PART_LINUX_SWAP && p->fs == MND_FS_SWAP && p->primary_ok == 1);
    p = part(&r, 4);
    CHECK(p && p->fs == MND_FS_LUKS);
    p = part(&r, 5);
    CHECK(p && p->kind == MND_PART_LINUX_LVM && p->fs == MND_FS_LVM);
    p = part(&r, 6);
    CHECK(p && p->fs == MND_FS_UNKNOWN && p->primary_ok == 0 && p->backup_ok == 0);
    p = part(&r, 7);
    CHECK(p && p->fs == MND_FS_BTRFS && p->primary_ok == 0 && p->backup_ok == 1);
    if (p) CHECK_STR(p->label, "data2");
    free(d.blob);
}

/* No partition table: the whole disk is one filesystem. */
static void test_bare_filesystem(void) {
    vdisk d;
    mnd_disk_report r = check("disk_bare_ext4.regions", &d);
    CHECK(r.gpt == MND_GPT_NONE);
    CHECK(r.count == 1);
    CHECK(r.parts[0].number == 0);
    CHECK(r.parts[0].fs == MND_FS_EXT && r.parts[0].primary_ok == 1);
    CHECK_STR(r.parts[0].label, "bare");
    free(d.blob);
}

/* Entries outside the disk or backwards are skipped, and no more than
 * MND_DISK_MAX_PARTS are reported. */
static void test_many_entries(void) {
    vdisk d;
    mnd_disk_report r = check("disk_many.regions", &d);
    CHECK(r.gpt == MND_GPT_OK);
    CHECK(r.count == MND_DISK_MAX_PARTS);
    CHECK(r.skipped == 4);
    CHECK(part(&r, 3) == NULL && part(&r, 4) == NULL);
    CHECK(part(&r, 5) != NULL);
    free(d.blob);
}

/* An empty disk: no table, nothing known on it. A disk that cannot be read
 * at all is an error. */
static void test_empty_and_unreadable(void) {
    vdisk d;
    memset(&d, 0, sizeof d);
    d.size = 64u << 20;
    mnd_disk_report r;
    CHECK(mnd_disk_check(vread, &d, d.size, &r) == 0);
    CHECK(r.gpt == MND_GPT_NONE && r.count == 1);
    CHECK(r.parts[0].fs == MND_FS_UNKNOWN && r.parts[0].primary_ok == 0 && r.parts[0].backup_ok == 0);
    d.size = 100; /* not even a sector */
    CHECK(mnd_disk_check(vread, &d, 1u << 20, &r) == -1);
}

/* ext4's CRC32C: the standard one ("123456789" → 0xE3069283) without its
 * final inversion. */
static void test_crc32c(void) {
    CHECK(mnd_crc32c(0xFFFFFFFFu, "123456789", 9) == (0xE3069283u ^ 0xFFFFFFFFu));
    CHECK(mnd_crc32c(0xFFFFFFFFu, "", 0) == 0xFFFFFFFFu);
}

int main(int argc, char **argv) {
    if (argc > 1) g_dir = argv[1];
    fprintf(stderr, "mnd_diskcheck tests\n");
    test_crc32c();
    test_cloud();
    test_zeroed_root();
    test_root_errors();
    test_bad_checksum();
    test_gpt_backup_only();
    test_other_filesystems();
    test_bare_filesystem();
    test_many_entries();
    test_empty_and_unreadable();
    fprintf(stderr, "%d checks, %d failures\n", g_checks, g_failures);
    return g_failures ? 1 : 0;
}
