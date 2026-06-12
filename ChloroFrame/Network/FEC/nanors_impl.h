/*
 * nanors_impl.h
 * ChloroFrame
 *
 * Minimal self-contained GF(2^8) Reed-Solomon, polynomial 285.
 * Scalar path only (no SIMD). Used by NanorsDecoder.swift.
 */

#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cf_rs cf_rs;

/* Create a Reed-Solomon codec for dataShards/parityShards.
 * Returns NULL if parameters are invalid (ds+ps > 255, or either <= 0). */
cf_rs *cf_rs_new(int dataShards, int parityShards);

/* Release codec created by cf_rs_new. */
void cf_rs_free(cf_rs *rs);

/*
 * Decode in-place.
 *
 * buf          flat [totalShards * blockSize] buffer; caller lays out shards
 *              contiguously: buf[i*blockSize .. (i+1)*blockSize - 1] = shard i.
 *              Data shards: i in [0, dataShards). Parity: [dataShards, totalShards).
 * marks        marks[i] = 1 if shard i is missing, 0 if present.
 *              Length must be at least totalShards.
 * totalShards  must be >= dataShards + parityShards.
 * blockSize    bytes per shard.
 *
 * On success, missing data shards in buf are overwritten with recovered data.
 * Returns 0 on success, -1 if unrecoverable (too many erasures or bad params).
 */
int cf_rs_decode(cf_rs *rs,
                 uint8_t *buf,
                 const uint8_t *marks,
                 int totalShards,
                 int blockSize);

#ifdef __cplusplus
}
#endif
