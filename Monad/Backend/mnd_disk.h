/*
 * mnd_disk.h — raw disk image helpers.
 */
#ifndef MND_DISK_H
#define MND_DISK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Copy src to dst (which must not exist). Uses an APFS copy-on-write clone
 * when possible, otherwise a sparse copy. Returns 0 or errno. */
int mnd_disk_clone(const char *src, const char *dst);

/* Grow a raw image to size bytes (sparse). Never shrinks. Returns 0 or errno. */
int mnd_disk_grow(const char *path, uint64_t size);

/* Free bytes available to the caller on the volume holding path. */
int mnd_disk_free_bytes(const char *path, uint64_t *out);

/* Bytes actually allocated on disk for path. */
int mnd_disk_allocated_bytes(const char *path, uint64_t *out);

#ifdef __cplusplus
}
#endif

#endif
