/*
 * mnd_qcow2.h — convert a qcow2 image (as shipped by Ubuntu cloud images) to
 * a sparse raw disk image suitable for Virtualization.framework.
 */
#ifndef MND_QCOW2_H
#define MND_QCOW2_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Progress callback: return false to cancel. */
typedef bool (*mnd_qcow2_progress)(void *ctx, uint64_t done, uint64_t total);

typedef struct {
    uint64_t virtual_size;
    uint32_t cluster_size;
    uint32_t version;
} mnd_qcow2_info;

/* Parse and validate the header. Returns 0 or an errno-style code
 * (EINVAL: not qcow2, ENOTSUP: unsupported feature, EIO: read error). */
int mnd_qcow2_probe(const char *path, mnd_qcow2_info *info);

/* Convert src (qcow2) to dst (raw, created/truncated, sparse). Supports
 * versions 2 and 3, zlib-compressed clusters and zero clusters. Rejects
 * backing files, encryption, external data files, extended L2 entries and
 * non-zlib compression. Returns 0 or an errno-style code (ECANCELED when the
 * callback cancels). On failure dst is removed. */
int mnd_qcow2_to_raw(const char *src, const char *dst, mnd_qcow2_progress progress, void *ctx);

/* Human-readable description of the last error on this thread. */
const char *mnd_qcow2_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
