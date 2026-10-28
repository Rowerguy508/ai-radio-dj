#include "AeroDJ-Bridging-Header.h"

#include <string.h>
#include <zlib.h>

int aerodj_inflate_raw(const uint8_t *src, uint32_t src_len, uint8_t *dst, uint32_t dst_len) {
    z_stream strm;
    int rc;
    if (src == NULL || dst == NULL || dst_len == 0) return 1;
    memset(&strm, 0, sizeof(strm));
    if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) return 1;
    strm.next_in = (Bytef *)src;
    strm.avail_in = src_len;
    strm.next_out = dst;
    strm.avail_out = dst_len;
    rc = inflate(&strm, Z_FINISH);
    unsigned long produced = strm.total_out;
    inflateEnd(&strm);
    if (rc != Z_STREAM_END || produced != dst_len) return 2;
    return 0;
}
