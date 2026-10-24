/*
 * mnd_unpack.h — a compressed disk image (.xz with Monad's own decoder, .gz
 * with zlib) into a file, as distros and mirrors publish them
 * (name.qcow2.xz, name.raw.gz). Runs of zeros are not written, so the output
 * keeps holes where the file system supports them.
 */
#ifndef MND_UNPACK_H
#define MND_UNPACK_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { MND_UNPACK_XZ = 1, MND_UNPACK_GZIP = 2 };

/* Progress over the compressed input; return false to cancel. */
typedef bool (*mnd_unpack_progress)(void *ctx, uint64_t done, uint64_t total);

/* Decompress `src` (`kind`: MND_UNPACK_*) into `dst`, created with mode 0600
 * (an existing file is replaced). xz dictionaries may use up to `memlimit`
 * bytes. Returns 0, or an errno code: EINVAL (unknown kind, not that format,
 * corrupt or truncated input, trailing data), EFBIG (more than 1 TiB out),
 * ENOMEM, ECANCELED, or a file system error. On failure dst does not exist. */
int mnd_unpack(const char *src, const char *dst, int kind, uint64_t memlimit,
               mnd_unpack_progress progress, void *ctx);

/* Description of the last error on this thread. */
const char *mnd_unpack_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
