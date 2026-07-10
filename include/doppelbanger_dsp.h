#ifndef DOPPELBANGER_DSP_H
#define DOPPELBANGER_DSP_H

#include <stddef.h>
#include <stdint.h>

#define DB_ABI_VERSION 1u
#define DB_PLAN_SCHEMA_VERSION 1u
#define DB_PROCESSOR_VERSION 1u
#define DB_MAX_BLOCK_FRAMES 8192u

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t db_status;

#define DB_STATUS_OK ((db_status)0)
#define DB_STATUS_NULL_POINTER ((db_status)1)
#define DB_STATUS_INCOMPATIBLE_VERSION ((db_status)2)
#define DB_STATUS_INVALID_CONFIGURATION ((db_status)3)
#define DB_STATUS_BLOCK_TOO_LARGE ((db_status)4)
#define DB_STATUS_ALIASED_CHANNELS ((db_status)5)
#define DB_STATUS_INVALID_BUFFER ((db_status)6)
#define DB_STATUS_PROCESS_FAULT ((db_status)7)
#define DB_STATUS_PANIC ((db_status)255)

typedef struct db_runtime_plan_v1 {
  uint32_t struct_size;
  uint32_t abi_version;
  uint32_t plan_schema_version;
  uint32_t processor_version;
  uint32_t bypass;
  uint32_t reserved;
  double applied_gain_db;
  double eq_gains_db[3];
} db_runtime_plan_v1;

typedef struct db_processor db_processor;

/*
 * On success, transfers one opaque handle to *output. The caller owns that
 * handle and must destroy it exactly once. On failure, *output is NULL.
 * plan->struct_size must exactly match the V1 structure before any later
 * field is read. The output pointer must be naturally aligned and writable.
 */
db_status db_processor_create(const db_runtime_plan_v1 *plan,
                              double sample_rate_hz,
                              uint32_t max_block_frames,
                              db_processor **output);

/*
 * Processes exactly frames writable samples in each planar channel. Nonzero
 * buffers must be aligned, non-overlapping, and valid for the call. Calls on
 * one handle must not overlap across threads.
 *
 * A new process fault or contained panic silences the valid block and latches
 * the handle until reset. An already-faulted handle and validation errors
 * leave buffers unchanged. Rust invokes the process-configured panic hook
 * before containment; any panic fails callback conformance even when this ABI
 * safely returns DB_STATUS_PANIC.
 */
db_status db_processor_process_f32(db_processor *processor,
                                   float *left,
                                   float *right,
                                   uint32_t frames);

/* Clears filter history and a latched fault. Must not overlap another call. */
db_status db_processor_reset(db_processor *processor);

/*
 * Returns UINT32_MAX for an invalid handle or contained panic. This read must
 * not overlap processing, reset, latency, or destroy on the same handle.
 */
uint32_t db_processor_latency_samples(const db_processor *processor);

/* Consumes one live handle. Must not overlap another call or be repeated. */
db_status db_processor_destroy(db_processor *processor);

#ifdef __cplusplus
}
static_assert(sizeof(db_status) == 4, "db_status layout changed");
static_assert(sizeof(db_runtime_plan_v1) == 56,
              "db_runtime_plan_v1 layout changed");
static_assert(alignof(db_runtime_plan_v1) == 8,
              "db_runtime_plan_v1 alignment changed");
static_assert(offsetof(db_runtime_plan_v1, struct_size) == 0,
              "db_runtime_plan_v1.struct_size offset changed");
static_assert(offsetof(db_runtime_plan_v1, applied_gain_db) == 24,
              "db_runtime_plan_v1.applied_gain_db offset changed");
static_assert(offsetof(db_runtime_plan_v1, eq_gains_db) == 32,
              "db_runtime_plan_v1.eq_gains_db offset changed");
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(db_status) == 4, "db_status layout changed");
_Static_assert(sizeof(db_runtime_plan_v1) == 56,
               "db_runtime_plan_v1 layout changed");
_Static_assert(_Alignof(db_runtime_plan_v1) == 8,
               "db_runtime_plan_v1 alignment changed");
_Static_assert(offsetof(db_runtime_plan_v1, struct_size) == 0,
               "db_runtime_plan_v1.struct_size offset changed");
_Static_assert(offsetof(db_runtime_plan_v1, applied_gain_db) == 24,
               "db_runtime_plan_v1.applied_gain_db offset changed");
_Static_assert(offsetof(db_runtime_plan_v1, eq_gains_db) == 32,
               "db_runtime_plan_v1.eq_gains_db offset changed");
#endif

#endif
