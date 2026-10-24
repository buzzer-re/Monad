/*
 * mnd_iso9660.h — write a small single-directory ISO 9660 image with Joliet
 * extensions (used for the cloud-init NoCloud "cidata" seed).
 */
#ifndef MND_ISO9660_H
#define MND_ISO9660_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char *name; /* [A-Za-z0-9._-], 1..64 chars, unique */
    const void *data;
    size_t len;
} mnd_iso_file;

/* Write the image atomically (temp file + rename). volume_id: 1..16 chars
 * of [A-Za-z0-9_]. Returns 0 or an errno value (EINVAL for bad names). */
int mnd_iso9660_write(const char *path, const char *volume_id, const mnd_iso_file *files, size_t nfiles);

#ifdef __cplusplus
}
#endif

#endif
