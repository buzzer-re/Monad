/*
 * mnd_xz.h — streaming decoder for the .xz container with LZMA2 (as used by
 * distro cloud images shipped as tar.xz). Written from the .xz file format
 * specification 1.2.1; no liblzma.
 *
 * Supported: concatenated streams and stream padding, any number of blocks,
 * the LZMA2 filter only, check types None, CRC32, CRC64 and SHA-256. The
 * index is verified against the decoded blocks. Memory use is bounded by the
 * LZMA2 dictionary size, which must not exceed the caller's limit.
 */
#ifndef MND_XZ_H
#define MND_XZ_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    MND_XZ_OK = 0,           /* made progress or needs more input/output space */
    MND_XZ_END = 1,          /* all streams decoded (only with finish) */
    MND_XZ_EFORMAT = -1,     /* not .xz, or a malformed header/index/footer */
    MND_XZ_ECORRUPT = -2,    /* compressed data or check value is wrong */
    MND_XZ_EUNSUPPORTED = -3,/* filter or check type not supported */
    MND_XZ_EMEMLIMIT = -4,   /* dictionary larger than the memory limit */
    MND_XZ_ETRUNCATED = -5,  /* input ended inside a stream */
    MND_XZ_ENOMEM = -6,
    MND_XZ_EIO = -7,         /* read error (file reader only) */
};

typedef struct mnd_xz mnd_xz;

/* A decoder allowing dictionaries up to `memlimit` bytes. NULL on ENOMEM. */
mnd_xz *mnd_xz_new(uint64_t memlimit);
void mnd_xz_free(mnd_xz *d);

/* Decode from in[0..in_len) into out[0..out_len). *in_used and *out_written
 * report what was consumed and produced. `finish` says no input follows
 * in[]: once it is all consumed at a stream boundary the call returns
 * MND_XZ_END, inside a stream MND_XZ_ETRUNCATED. Errors are sticky. */
int mnd_xz_run(mnd_xz *d, const uint8_t *in, size_t in_len, size_t *in_used,
               uint8_t *out, size_t out_len, size_t *out_written, bool finish);

/* Details of the last error, e.g. "block 3: CRC64 mismatch". */
const char *mnd_xz_error(const mnd_xz *d);

/* Pull interface over a file descriptor (not closed by the reader). */
typedef struct mnd_xz_file mnd_xz_file;
mnd_xz_file *mnd_xz_file_open(int fd, uint64_t memlimit);
/* Up to n decompressed bytes: > 0 bytes read, 0 at the end, < 0 an MND_XZ_E* code. */
ssize_t mnd_xz_file_read(mnd_xz_file *f, void *buf, size_t n);
const char *mnd_xz_file_error(const mnd_xz_file *f);
/* Compressed bytes consumed so far (for progress). */
uint64_t mnd_xz_file_position(const mnd_xz_file *f);
void mnd_xz_file_close(mnd_xz_file *f);

#ifdef __cplusplus
}
#endif

#endif
