/* Compiles the stb_truetype implementation as real C (clang), so Zig's translate-c
 * only ever sees the declarations. See src/backend/stb.zig. */
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
