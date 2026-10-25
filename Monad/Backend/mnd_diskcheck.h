/*
 * mnd_diskcheck — what a stopped Linux VM's disk looks like from outside:
 * its GPT partition table and, in each partition, which filesystem is there
 * and whether its superblock is intact (or only a backup copy is). Used
 * after a boot that never reached sshd, to say whether the disk is why.
 *
 * Read only, through a callback, so it runs on a disk file (MonadHost) and
 * on memory (tests, the fuzzer). The disk is the guest's to write: every
 * offset, count and length read from it is bounded before it is used, and
 * every string it reports is printable ASCII.
 */
#ifndef MND_DISKCHECK_H
#define MND_DISKCHECK_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MND_DISK_MAX_PARTS 16

/* Reads `len` bytes at `offset`; 0, or -1 when it cannot (past the end, an
 * I/O error). */
typedef int (*mnd_disk_read_fn)(void *ctx, uint64_t offset, void *buf, size_t len);

typedef enum {
    MND_GPT_NONE = 0,   /* no GPT: the whole disk is checked as one filesystem (number 0) */
    MND_GPT_OK,         /* the main GPT header and its table are intact */
    MND_GPT_BACKUP,     /* only the backup header (at the disk's end) is */
} mnd_gpt_state;

typedef enum {
    MND_PART_OTHER = 0,
    MND_PART_EFI,        /* EFI system partition */
    MND_PART_LINUX_ROOT, /* a Linux root (arm64, x86-64) */
    MND_PART_LINUX_BOOT, /* extended boot loader partition (/boot) */
    MND_PART_LINUX_DATA, /* Linux filesystem data */
    MND_PART_LINUX_SWAP,
    MND_PART_LINUX_LVM,
} mnd_part_kind;

typedef enum {
    MND_FS_UNKNOWN = 0,  /* nothing this knows */
    MND_FS_EXT,          /* ext2, ext3, ext4 */
    MND_FS_XFS,
    MND_FS_BTRFS,
    MND_FS_FAT,
    MND_FS_SWAP,
    MND_FS_LVM,
    MND_FS_LUKS,
} mnd_fs_kind;

typedef struct {
    unsigned number;          /* the GPT entry's number, from 1 (0: the whole disk) */
    mnd_part_kind kind;
    uint64_t first_lba, last_lba; /* 512-byte sectors */
    char name[37];            /* the GPT entry's name */
    mnd_fs_kind fs;           /* found by its main superblock, else by a backup copy */
    int primary_ok;           /* the main superblock is there, sane, its checksum holds */
    int backup_ok;            /* ext, btrfs, FAT32: an intact backup copy was found */
    uint64_t backup_block;    /* ext: the backup's block (e2fsck -b), with block_size (-B) */
    uint32_t block_size;
    char label[33];
    /* ext, from the main superblock: what the filesystem recorded itself */
    int has_errors;           /* marked as having errors, or an error count */
    int needs_recovery;       /* its journal was not replayed (not cleanly unmounted) */
    uint32_t error_count;
    char first_error_func[33];
    uint32_t first_error_time; /* seconds since 1970; 0: none */
    char last_error_func[33];
    uint32_t last_error_time;
} mnd_disk_part;

typedef struct {
    mnd_gpt_state gpt;
    unsigned count;           /* entries in parts */
    unsigned skipped;         /* used GPT entries past MND_DISK_MAX_PARTS, or out of the disk */
    mnd_disk_part parts[MND_DISK_MAX_PARTS];
} mnd_disk_report;

/* Checks a disk of `size` bytes. 0, or -1 when not even its first sector
 * could be read. */
int mnd_disk_check(mnd_disk_read_fn read, void *ctx, uint64_t size, mnd_disk_report *out);

/* CRC32C as ext4 keeps it (no final inversion): seed ~0 for a superblock. */
uint32_t mnd_crc32c(uint32_t crc, const void *data, size_t len);

#ifdef __cplusplus
}
#endif

#endif
