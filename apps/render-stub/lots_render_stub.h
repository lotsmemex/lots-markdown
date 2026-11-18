#include <stddef.h>
#include <stdint.h>
// Temporary stub ABI (render-stub/); replaced by core/'s UniFFI bindings.
char *lm_render_html(const uint8_t *ptr, size_t len);
void lm_free(char *ptr);
