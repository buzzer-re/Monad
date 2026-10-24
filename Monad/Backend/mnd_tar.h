/*
 * mnd_tar.h — extract one member of a tar stream into a sparse file (e.g. the
 * disk.raw inside a distro's tar.xz cloud image). The archive is read once,
 * front to back, through a reader callback, so it can come straight out of
 * the xz decoder.
 *
 * Formats: POSIX ustar, pax extended headers (path, size), GNU long names,
 * base-256 numeric fields, old GNU sparse members ('S', with extension
 * headers) and pax 1.0 sparse members. Runs of zeros are not written, so the
 * output keeps holes where the file system supports them.
 */
#ifndef MND_TAR_H
#define MND_TAR_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Up to n bytes: > 0 bytes read, 0 at the end, < 0 on error. */
typedef ssize_t (*mnd_tar_read_fn)(void *ctx, void *buf, size_t n);

/* Progress over the member's logical size; return false to cancel. */
typedef bool (*mnd_tar_progress)(void *ctx, uint64_t done, uint64_t total);

/* Extract the first member whose name matches `pattern` (fnmatch; a leading
 * "./" of member names is ignored) to `dst` (created with mode 0600,
 * replacing an existing file). Returns 0 and the member's size in *size, or
 * an errno code: ENOENT (no such member), EINVAL (malformed or truncated
 * archive), EIO (the reader failed), ECANCELED, or a file system error. On
 * failure dst does not exist. */
int mnd_tar_extract(mnd_tar_read_fn read, void *read_ctx, const char *pattern, const char *dst,
                    mnd_tar_progress progress, void *progress_ctx, uint64_t *size);

/* Description of the last error on this thread. */
const char *mnd_tar_last_error(void);

/* Reader over a plain file descriptor (ctx: pointer to the int). */
ssize_t mnd_tar_fd_reader(void *ctx, void *buf, size_t n);

#ifdef __cplusplus
}
#endif

#endif
