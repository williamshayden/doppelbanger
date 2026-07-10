#ifndef DOPPELBANGER_NATIVE_ABI_SMOKE_H
#define DOPPELBANGER_NATIVE_ABI_SMOKE_H

#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#ifdef __cplusplus
#include <cmath>
#define DB_SMOKE_ALIGNOF(type) alignof(type)
#define DB_SMOKE_ISFINITE(value) std::isfinite(value)
#define DB_SMOKE_STATIC_ASSERT(condition, message) static_assert(condition, message)
#else
#include <math.h>
#define DB_SMOKE_ALIGNOF(type) _Alignof(type)
#define DB_SMOKE_ISFINITE(value) isfinite(value)
#define DB_SMOKE_STATIC_ASSERT(condition, message) _Static_assert(condition, message)
#endif

DB_SMOKE_STATIC_ASSERT(sizeof(db_status) * CHAR_BIT == 32,
                       "db_status must be exactly 32 bits");
DB_SMOKE_STATIC_ASSERT(sizeof(db_runtime_plan_v1) == 56,
                       "db_runtime_plan_v1 size changed");
DB_SMOKE_STATIC_ASSERT(DB_SMOKE_ALIGNOF(db_runtime_plan_v1) == 8,
                       "db_runtime_plan_v1 alignment changed");
DB_SMOKE_STATIC_ASSERT(offsetof(db_runtime_plan_v1, struct_size) == 0,
                       "db_runtime_plan_v1.struct_size offset changed");
DB_SMOKE_STATIC_ASSERT(offsetof(db_runtime_plan_v1, abi_version) == 4,
                       "db_runtime_plan_v1.abi_version offset changed");
DB_SMOKE_STATIC_ASSERT(offsetof(db_runtime_plan_v1, plan_schema_version) == 8,
                       "db_runtime_plan_v1.plan_schema_version offset changed");
DB_SMOKE_STATIC_ASSERT(offsetof(db_runtime_plan_v1, processor_version) == 12,
                       "db_runtime_plan_v1.processor_version offset changed");
DB_SMOKE_STATIC_ASSERT(offsetof(db_runtime_plan_v1, bypass) == 16,
                       "db_runtime_plan_v1.bypass offset changed");
DB_SMOKE_STATIC_ASSERT(offsetof(db_runtime_plan_v1, reserved) == 20,
                       "db_runtime_plan_v1.reserved offset changed");
DB_SMOKE_STATIC_ASSERT(offsetof(db_runtime_plan_v1, applied_gain_db) == 24,
                       "db_runtime_plan_v1.applied_gain_db offset changed");
DB_SMOKE_STATIC_ASSERT(offsetof(db_runtime_plan_v1, eq_gains_db) == 32,
                       "db_runtime_plan_v1.eq_gains_db offset changed");

enum { DB_SMOKE_FRAMES = 64 };

static int db_smoke_expect_status(const char *caller,
                                  const char *operation,
                                  db_status actual,
                                  db_status expected) {
  if (actual == expected) {
    return 0;
  }
  fprintf(stderr, "%s: %s returned %d, expected %d\n", caller, operation,
          (int)actual, (int)expected);
  return 1;
}

static void db_smoke_fill_input(float *left, float *right) {
  size_t frame;
  for (frame = 0; frame < DB_SMOKE_FRAMES; ++frame) {
    left[frame] = (float)((int)(frame % 17u) - 8) / 16.0f;
    right[frame] = (float)((int)(frame % 13u) - 6) / 12.0f;
  }
}

static int db_smoke_output_is_finite(const float *left, const float *right) {
  size_t frame;
  for (frame = 0; frame < DB_SMOKE_FRAMES; ++frame) {
    if (!DB_SMOKE_ISFINITE(left[frame]) || !DB_SMOKE_ISFINITE(right[frame])) {
      return 0;
    }
  }
  return 1;
}

static int db_run_native_abi_smoke(const char *caller) {
  const db_runtime_plan_v1 plan = {
      (uint32_t)sizeof(db_runtime_plan_v1),
      DB_ABI_VERSION,
      DB_PLAN_SCHEMA_VERSION,
      DB_PROCESSOR_VERSION,
      0u,
      0u,
      1.0,
      {0.75, -0.5, 0.25},
  };
  db_runtime_plan_v1 incompatible_plan = plan;
  db_processor *processor = NULL;
  float input_left[DB_SMOKE_FRAMES];
  float input_right[DB_SMOKE_FRAMES];
  float first_left[DB_SMOKE_FRAMES];
  float first_right[DB_SMOKE_FRAMES];
  float second_left[DB_SMOKE_FRAMES];
  float second_right[DB_SMOKE_FRAMES];
  db_status status;
  int result = 1;

  incompatible_plan.abi_version += 1u;
  status = db_processor_create(&incompatible_plan, 48000.0, DB_SMOKE_FRAMES,
                               &processor);
  if (db_smoke_expect_status(caller, "incompatible create", status,
                             DB_STATUS_INCOMPATIBLE_VERSION) != 0) {
    goto cleanup;
  }
  if (processor != NULL) {
    fprintf(stderr, "%s: incompatible create returned a non-null handle\n",
            caller);
    goto cleanup;
  }

  status = db_processor_create(&plan, 48000.0, DB_SMOKE_FRAMES, &processor);
  if (db_smoke_expect_status(caller, "create", status, DB_STATUS_OK) != 0) {
    goto cleanup;
  }
  if (processor == NULL) {
    fprintf(stderr, "%s: create returned a null handle\n", caller);
    goto cleanup;
  }

  if (db_processor_latency_samples(processor) != 0u) {
    fprintf(stderr, "%s: latency was not 0 samples\n", caller);
    goto cleanup;
  }
  if (db_processor_latency_samples(NULL) != UINT32_MAX) {
    fprintf(stderr, "%s: null-handle latency did not return UINT32_MAX\n",
            caller);
    goto cleanup;
  }

  db_smoke_fill_input(input_left, input_right);
  memcpy(first_left, input_left, sizeof(first_left));
  memcpy(first_right, input_right, sizeof(first_right));

  status = db_processor_process_f32(processor, first_left, first_right,
                                    DB_SMOKE_FRAMES + 1u);
  if (db_smoke_expect_status(caller, "oversized process", status,
                             DB_STATUS_BLOCK_TOO_LARGE) != 0) {
    goto cleanup;
  }
  status = db_processor_process_f32(processor, first_left, first_left, 1u);
  if (db_smoke_expect_status(caller, "aliased process", status,
                             DB_STATUS_ALIASED_CHANNELS) != 0) {
    goto cleanup;
  }

  status = db_processor_process_f32(processor, first_left, first_right,
                                    DB_SMOKE_FRAMES);
  if (db_smoke_expect_status(caller, "first process", status, DB_STATUS_OK) !=
      0) {
    goto cleanup;
  }
  if (!db_smoke_output_is_finite(first_left, first_right)) {
    fprintf(stderr, "%s: first process produced non-finite output\n", caller);
    goto cleanup;
  }
  if (memcmp(first_left, input_left, sizeof(first_left)) == 0 &&
      memcmp(first_right, input_right, sizeof(first_right)) == 0) {
    fprintf(stderr, "%s: active plan did not change either channel\n", caller);
    goto cleanup;
  }

  status = db_processor_reset(processor);
  if (db_smoke_expect_status(caller, "reset", status, DB_STATUS_OK) != 0) {
    goto cleanup;
  }
  memcpy(second_left, input_left, sizeof(second_left));
  memcpy(second_right, input_right, sizeof(second_right));
  status = db_processor_process_f32(processor, second_left, second_right,
                                    DB_SMOKE_FRAMES);
  if (db_smoke_expect_status(caller, "process after reset", status,
                             DB_STATUS_OK) != 0) {
    goto cleanup;
  }
  if (!db_smoke_output_is_finite(second_left, second_right)) {
    fprintf(stderr, "%s: process after reset produced non-finite output\n",
            caller);
    goto cleanup;
  }
  if (memcmp(first_left, second_left, sizeof(first_left)) != 0 ||
      memcmp(first_right, second_right, sizeof(first_right)) != 0) {
    fprintf(stderr, "%s: reset did not reproduce identical output\n", caller);
    goto cleanup;
  }

  status = db_processor_destroy(processor);
  processor = NULL;
  if (db_smoke_expect_status(caller, "destroy", status, DB_STATUS_OK) != 0) {
    goto cleanup;
  }

  printf("%s native ABI smoke: ok\n", caller);
  result = 0;

cleanup:
  if (processor != NULL) {
    (void)db_processor_destroy(processor);
  }
  return result;
}

#endif
