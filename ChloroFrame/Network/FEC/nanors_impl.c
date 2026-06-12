/*
 * nanors_impl.c
 * ChloroFrame
 *
 * Self-contained GF(2^8) Reed-Solomon over polynomial 285.
 * Scalar path, no SIMD — translates the OBLAS_TINY code path from nanors
 * by Joseph Calderon (https://github.com/sleepybishop/nanors).
 *
 * Build with OBLAS_TINY defined (no simde/NEON dependency).
 *
 * Derived from nanors, which is distributed under the MIT License:
 *
 *   Copyright (c) 2021 Joseph Calderon
 *
 *   Permission is hereby granted, free of charge, to any person obtaining a
 *   copy of this software and associated documentation files (the
 *   "Software"), to deal in the Software without restriction, including
 *   without limitation the rights to use, copy, modify, merge, publish,
 *   distribute, sublicense, and/or sell copies of the Software, and to
 *   permit persons to whom the Software is furnished to do so, subject to
 *   the following conditions:
 *
 *   The above copyright notice and this permission notice shall be included
 *   in all copies or substantial portions of the Software.
 *
 *   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 *   OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 *   MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 *   IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 *   CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 *   TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 *   SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#include "nanors_impl.h"
#include <stdlib.h>
#include <string.h>

/* ── GF(2^8) tables, polynomial 285 ─────────────────────────────────────── */

static const uint8_t GF_LOG[256] = {
    255,  0,  1, 25,  2, 50, 26,198,  3,223, 51,238, 27,104,199, 75,
      4,100,224, 14, 52,141,239,129, 28,193,105,248,200,  8, 76,113,
      5,138,101, 47,225, 36, 15, 33, 53,147,142,218,240, 18,130, 69,
     29,181,194,125,106, 39,249,185,201,154,  9,120, 77,228,114,166,
      6,191,139, 98,102,221, 48,253,226,152, 37,179, 16,145, 34,136,
     54,208,148,206,143,150,219,189,241,210, 19, 92,131, 56, 70, 64,
     30, 66,182,163,195, 72,126,110,107, 58, 40, 84,250,133,186, 61,
    202, 94,155,159, 10, 21,121, 43, 78,212,229,172,115,243,167, 87,
      7,112,192,247,140,128, 99, 13,103, 74,222,237, 49,197,254, 24,
    227,165,153,119, 38,184,180,124, 17, 68,146,217, 35, 32,137, 46,
     55, 63,209, 91,149,188,207,205,144,135,151,178,220,252,190, 97,
    242, 86,211,171, 20, 42, 93,158,132, 60, 57, 83, 71,109, 65,162,
     31, 45, 67,216,183,123,164,118,196, 23, 73,236,127, 12,111,246,
    108,161, 59, 82, 41,157, 85,170,251, 96,134,177,187,204, 62, 90,
    203, 89, 95,176,156,169,160, 81, 11,245, 22,235,122,117, 44,215,
     79,174,213,233,230,231,173,232,116,214,244,234,168, 80, 88,175,
};

/* 512 entries — allows LOG[a]+LOG[b] without modular reduction. */
static const uint8_t GF_EXP[512] = {
      1,  2,  4,  8, 16, 32, 64,128, 29, 58,116,232,205,135, 19, 38,
     76,152, 45, 90,180,117,234,201,143,  3,  6, 12, 24, 48, 96,192,
    157, 39, 78,156, 37, 74,148, 53,106,212,181,119,238,193,159, 35,
     70,140,  5, 10, 20, 40, 80,160, 93,186,105,210,185,111,222,161,
     95,190, 97,194,153, 47, 94,188,101,202,137, 15, 30, 60,120,240,
    253,231,211,187,107,214,177,127,254,225,223,163, 91,182,113,226,
    217,175, 67,134, 17, 34, 68,136, 13, 26, 52,104,208,189,103,206,
    129, 31, 62,124,248,237,199,147, 59,118,236,197,151, 51,102,204,
    133, 23, 46, 92,184,109,218,169, 79,158, 33, 66,132, 21, 42, 84,
    168, 77,154, 41, 82,164, 85,170, 73,146, 57,114,228,213,183,115,
    230,209,191, 99,198,145, 63,126,252,229,215,179,123,246,241,255,
    227,219,171, 75,150, 49, 98,196,149, 55,110,220,165, 87,174, 65,
    130, 25, 50,100,200,141,  7, 14, 28, 56,112,224,221,167, 83,166,
     81,162, 89,178,121,242,249,239,195,155, 43, 86,172, 69,138,  9,
     18, 36, 72,144, 61,122,244,245,247,243,251,235,203,139, 11, 22,
     44, 88,176,125,250,233,207,131, 27, 54,108,216,173, 71,142,  1,
      2,  4,  8, 16, 32, 64,128, 29, 58,116,232,205,135, 19, 38, 76,
    152, 45, 90,180,117,234,201,143,  3,  6, 12, 24, 48, 96,192,157,
     39, 78,156, 37, 74,148, 53,106,212,181,119,238,193,159, 35, 70,
    140,  5, 10, 20, 40, 80,160, 93,186,105,210,185,111,222,161, 95,
    190, 97,194,153, 47, 94,188,101,202,137, 15, 30, 60,120,240,253,
    231,211,187,107,214,177,127,254,225,223,163, 91,182,113,226,217,
    175, 67,134, 17, 34, 68,136, 13, 26, 52,104,208,189,103,206,129,
     31, 62,124,248,237,199,147, 59,118,236,197,151, 51,102,204,133,
     23, 46, 92,184,109,218,169, 79,158, 33, 66,132, 21, 42, 84,168,
     77,154, 41, 82,164, 85,170, 73,146, 57,114,228,213,183,115,230,
    209,191, 99,198,145, 63,126,252,229,215,179,123,246,241,255,227,
    219,171, 75,150, 49, 98,196,149, 55,110,220,165, 87,174, 65,130,
     25, 50,100,200,141,  7, 14, 28, 56,112,224,221,167, 83,166, 81,
    162, 89,178,121,242,249,239,195,155, 43, 86,172, 69,138,  9, 18,
     36, 72,144, 61,122,244,245,247,243,251,235,203,139, 11, 22, 44,
     88,176,125,250,233,207,131, 27, 54,108,216,173, 71,142,
};

static const uint8_t GF_INV[256] = {
      0,  1,142,244, 71,167,122,186,173,157,221,152, 61,170, 93,150,
    216,114,192, 88,224, 62, 76,102,144,222, 85,128,160,131, 75, 42,
    108,237, 57, 81, 96, 86, 44,138,112,208, 31, 74, 38,139, 51,110,
     72,137,111, 46,164,195, 64, 94, 80, 34,207,169,171, 12, 21,225,
     54, 95,248,213,146, 78,166,  4, 48,136, 43, 30, 22,103, 69,147,
     56, 35,104,140,129, 26, 37, 97, 19,193,203, 99,151, 14, 55, 65,
     36, 87,202, 91,185,196, 23, 77, 82,141,239,179, 32,236, 47, 50,
     40,209, 17,217,233,251,218,121,219,119,  6,187,132,205,254,252,
     27, 84,161, 29,124,204,228,176, 73, 49, 39, 45, 83,105,  2,245,
     24,223, 68, 79,155,188, 15, 92, 11,220,189,148,172,  9,199,162,
     28,130,159,198, 52,194, 70,  5,206, 59, 13, 60,156,  8,190,183,
    135,229,238,107,235,242,191,175,197,100,  7,123,149,154,174,182,
     18, 89,165, 53,101,184,163,158,210,247, 98, 90,133,125,168, 58,
     41,113,200,246,249, 67,215,214, 16,115,118,120,153, 10, 25,145,
     20, 63,230,240,134,177,226,241,250,116,243,180,109, 33,178,106,
    227,231,181,234,  3,143,211,201, 66,212,232,117,127,255,126,253,
};

/* ── GF helpers ──────────────────────────────────────────────────────────── */

#define GF_MUL(a, b) \
    ((uint8_t)(((a) == 0 || (b) == 0) ? 0 : GF_EXP[(int)GF_LOG[(a)] + (int)GF_LOG[(b)]]))

static inline void cf_axpy(uint8_t *a, const uint8_t *b, uint8_t u, int k)
{
    if (u == 0) return;
    if (u == 1) {
        for (int i = 0; i < k; i++) a[i] ^= b[i];
    } else {
        for (int i = 0; i < k; i++) a[i] ^= GF_MUL(u, b[i]);
    }
}

static inline void cf_scal(uint8_t *a, uint8_t u, int k)
{
    if (u < 2) return;
    for (int i = 0; i < k; i++) a[i] = GF_MUL(u, a[i]);
}

/* ── RS codec struct ─────────────────────────────────────────────────────── */

struct cf_rs {
    int ds, ps;
    uint8_t p[];  /* Cauchy parity matrix [ps*ds], row-major */
};

cf_rs *cf_rs_new(int ds, int ps)
{
    if (ds <= 0 || ps <= 0 || ds + ps > 255) return NULL;
    cf_rs *rs = calloc(1, sizeof(cf_rs) + (size_t)(ds * ps));
    if (!rs) return NULL;
    rs->ds = ds;
    rs->ps = ps;
    for (int j = 0; j < ps; j++)
        for (int i = 0; i < ds; i++)
            rs->p[j * ds + i] = GF_INV[(ps + i) ^ j];
    return rs;
}

void cf_rs_free(cf_rs *rs) { free(rs); }

/* ── invert_mat — Gaussian elimination on the W×W sub-matrix ────────────── */

static void invert_mat(const uint8_t *src, uint8_t *wrk,
                       uint8_t **dst,
                       int V0, int ds, int bs,
                       const uint8_t *colperm, const uint8_t *rowperm)
{
    int W = ds - V0;

    /* Step 1: extract W×W sub-matrix from the parity matrix. */
    for (int i = 0; i < W; i++) {
        int dr = (int)rowperm[i] * ds;
        for (int j = 0; j < W; j++)
            wrk[i * W + j] = src[dr + colperm[V0 + j]];
    }

    /* Step 2: subtract present-data contributions from the parity content
     * that was already copied into each erased slot. */
    for (int gap = 0; gap < W; gap++) {
        int dr = (int)rowperm[gap] * ds;
        for (int row = 0; row < V0; row++) {
            uint8_t u = src[dr + colperm[row]];
            cf_axpy(dst[colperm[V0 + gap]], dst[colperm[row]], u, bs);
        }
    }

    /* Step 3: forward (lower-triangular) Gaussian elimination.
     * cf_scal starts from the diagonal and scales W elements — mirrors the
     * `scal(wrk + x*W + x, u, W)` call in nanors rs.c.  The W-1 elements
     * that spill beyond the current row are harmless (all zero from prior
     * steps or initial calloc). wrk is allocated W*W+W bytes to hold them. */
    for (int x = 0; x < W; x++) {
        uint8_t u = GF_INV[wrk[x * W + x]];
        cf_scal(wrk + x * W + x, u, W);          /* may spill W-1 bytes past row end */
        cf_scal(dst[colperm[V0 + x]], u, bs);
        for (int row = x + 1; row < W; row++) {
            uint8_t u2 = wrk[row * W + x];
            if (u2 == 0) continue;
            cf_axpy(wrk + row * W, wrk + x * W, u2, W);
            cf_axpy(dst[colperm[V0 + row]], dst[colperm[V0 + x]], u2, bs);
        }
    }

    /* Step 4: back substitution. */
    for (int x = W - 1; x >= 0; x--) {
        uint8_t *from = dst[colperm[V0 + x]];
        for (int row = 0; row < x; row++) {
            uint8_t u = wrk[row * W + x];
            cf_axpy(dst[colperm[V0 + row]], from, u, bs);
        }
    }
}

/* ── Public decode ───────────────────────────────────────────────────────── */

int cf_rs_decode(cf_rs *rs,
                 uint8_t *buf,
                 const uint8_t *marks,
                 int totalShards,
                 int blockSize)
{
    if (!rs || !buf || !marks) return -1;
    if (totalShards < rs->ds + rs->ps) return -1;

    int ds = rs->ds, ps = rs->ps;

    /* Collect erased data shard indices. */
    uint8_t erasures[256], colperm[256], rowperm[256];
    int gaps = 0;
    for (int i = 0; i < ds; i++)
        if (marks[i]) erasures[gaps++] = (uint8_t)i;
    if (gaps == 0) return 0;
    if (gaps > ps)  return -1;

    int V0 = ds - gaps;

    /* Build column permutation. */
    for (int i = 0, j = 0; i < V0; i++, j++) {
        while (marks[j]) j++;
        colperm[i] = (uint8_t)j;
    }
    for (int i = 0; i < gaps; i++)
        colperm[V0 + i] = erasures[i];

    /* Build row permutation: pair each erased shard with an available parity
     * shard and copy its content into the erased slot's buffer. */
    int i = 0;
    for (int j = ds; i < gaps; i++, j++) {
        while (j < totalShards && marks[j]) j++;
        if (j >= totalShards) return -1;
        rowperm[i] = (uint8_t)(j - ds);
        memcpy(buf + (size_t)erasures[i] * (size_t)blockSize,
               buf + (size_t)j           * (size_t)blockSize,
               (size_t)blockSize);
        j++;
    }

    /* Build pointer array for invert_mat. */
    uint8_t *ptrs[256];
    for (int k = 0; k < totalShards && k < 256; k++)
        ptrs[k] = buf + (size_t)k * (size_t)blockSize;

    /* W×W work buffer + W extra bytes to absorb the scal spill. */
    int W = gaps;
    uint8_t *wrk = calloc(1, (size_t)(W * W + W));
    if (!wrk) return -1;

    invert_mat(rs->p, wrk, ptrs, V0, ds, blockSize, colperm, rowperm);

    free(wrk);
    return 0;
}
