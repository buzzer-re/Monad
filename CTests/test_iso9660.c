/* Tests for mnd_iso9660: re-parse the image with an independent reader. */
#include "../Monad/Backend/mnd_iso9660.h"
#include "test_util.h"

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>

static const char *g_dir = ".";

static uint32_t rd_le32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint32_t rd_be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }

/* Find a file by (ASCII) name in the root of the volume descriptor at sector
 * vd. Returns a pointer into img and its length, or NULL. */
static const uint8_t *find(const uint8_t *img, size_t n, int vd, const char *name, uint32_t *len) {
    const uint8_t *d = img + vd * 2048;
    bool joliet = d[0] == 2;
    const uint8_t *root = d + 156;
    uint32_t lba = rd_le32(root + 2), size = rd_le32(root + 10);
    CHECK(rd_be32(root + 6) == lba);
    if ((size_t)lba * 2048 + size > n) return NULL;
    const uint8_t *p = img + lba * 2048;
    uint32_t off = 0;
    while (off < size) {
        uint8_t rl = p[off];
        if (rl == 0) {
            off = (off / 2048 + 1) * 2048;
            continue;
        }
        uint8_t idl = p[off + 32];
        char id[80] = {0};
        if (joliet) {
            for (int i = 0; i + 1 < idl && i / 2 < 79; i += 2) id[i / 2] = (char)p[off + 33 + i + 1];
        } else {
            memcpy(id, p + off + 33, idl < 79 ? idl : 79);
        }
        if (strcmp(id, name) == 0) {
            uint32_t flba = rd_le32(p + off + 2);
            *len = rd_le32(p + off + 10);
            CHECK(rd_be32(p + off + 14) == *len);
            if ((size_t)flba * 2048 + *len > n) return NULL;
            return img + flba * 2048;
        }
        off += rl;
    }
    return NULL;
}

static void test_roundtrip(void) {
    char path[512];
    snprintf(path, sizeof path, "%s/seed.iso", g_dir);
    char big[5000];
    for (size_t i = 0; i < sizeof big; i++) big[i] = (char)('a' + i % 26);
    const char *ud = "#cloud-config\nhostname: test\n";
    const char *md = "instance-id: i-1\n";
    mnd_iso_file files[] = {
        {"user-data", ud, strlen(ud)},
        {"meta-data", md, strlen(md)},
        {"network-config", big, sizeof big},
        {"empty", "", 0},
    };
    CHECK(mnd_iso9660_write(path, "cidata", files, 4) == 0);

    FILE *f = fopen(path, "rb");
    CHECK(f != NULL);
    if (!f) return;
    uint8_t *img = malloc(1 << 20);
    size_t n = fread(img, 1, 1 << 20, f);
    fclose(f);
    CHECK(n % 2048 == 0);
    CHECK(memcmp(img + 16 * 2048 + 1, "CD001", 5) == 0 && img[16 * 2048] == 1);
    CHECK(img[17 * 2048] == 2 && img[18 * 2048] == 255);
    CHECK(memcmp(img + 16 * 2048 + 40, "CIDATA ", 7) == 0);
    CHECK(rd_le32(img + 16 * 2048 + 80) * 2048u == n);

    uint32_t len = 0;
    const uint8_t *p = find(img, n, 17, "user-data", &len);
    CHECK(p && len == strlen(ud) && memcmp(p, ud, len) == 0);
    p = find(img, n, 17, "meta-data", &len);
    CHECK(p && len == strlen(md) && memcmp(p, md, len) == 0);
    p = find(img, n, 17, "network-config", &len);
    CHECK(p && len == sizeof big && memcmp(p, big, len) == 0);
    p = find(img, n, 16, "USER_DATA.;1", &len);
    CHECK(p && len == strlen(ud));
    p = find(img, n, 16, "EMPTY.;1", &len);
    CHECK(p && len == 0);
    free(img);

    /* Cross-check with blkid when available (Linux). */
    if (access("/usr/sbin/blkid", X_OK) == 0 || access("/sbin/blkid", X_OK) == 0) {
        char cmd[640];
        snprintf(cmd, sizeof cmd, "blkid -p -s LABEL -s TYPE -o value '%s'", path);
        FILE *pp = popen(cmd, "r");
        char out[256] = {0};
        size_t got = pp ? fread(out, 1, sizeof out - 1, pp) : 0;
        if (pp) pclose(pp);
        out[got] = 0;
        CHECK(strstr(out, "cidata") != NULL || strstr(out, "CIDATA") != NULL);
        CHECK(strstr(out, "iso9660") != NULL);
    }
    unlink(path);
}

static void test_invalid(void) {
    char path[512];
    snprintf(path, sizeof path, "%s/bad.iso", g_dir);
    mnd_iso_file bad[] = {{"a/b", "x", 1}};
    CHECK(mnd_iso9660_write(path, "cidata", bad, 1) == EINVAL);
    mnd_iso_file dup[] = {{"a-b", "x", 1}, {"a_b", "y", 1}};
    CHECK(mnd_iso9660_write(path, "cidata", dup, 2) == EINVAL);
    CHECK(mnd_iso9660_write(path, "bad label!", NULL, 0) == EINVAL);
    CHECK(access(path, F_OK) != 0);
}

int main(int argc, char **argv) {
    if (argc > 1) g_dir = argv[1];
    fprintf(stderr, "mnd_iso9660 tests\n");
    RUN(test_roundtrip);
    RUN(test_invalid);
    TEST_MAIN_END();
}
