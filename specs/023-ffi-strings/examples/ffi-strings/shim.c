// A tiny C library exposed to Lumen across the C ABI. `shout` takes a
// NUL-terminated string and returns an uppercased copy. The returned buffer is
// reused on each call (static storage), so the Lumen side copies it at the call
// boundary and never frees it — matching the FFI string ownership convention.
#include <ctype.h>
#include <string.h>

const char* shout(const char* s) {
    static char buf[256];
    size_t i = 0;
    for (; s[i] != '\0' && i < sizeof(buf) - 1; i++) {
        buf[i] = (char)toupper((unsigned char)s[i]);
    }
    buf[i] = '\0';
    return buf;
}
