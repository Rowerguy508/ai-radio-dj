#include <stdint.h>

/// Raw DEFLATE (ZIP method 8) into a buffer of exactly `dst_len` bytes.
/// Returns 0 on success.
int aerodj_inflate_raw(const uint8_t *src, uint32_t src_len, uint8_t *dst, uint32_t dst_len);
