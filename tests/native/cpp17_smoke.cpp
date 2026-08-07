#include "doppelbanger_dsp.h"

#include "native_abi_smoke.h"

static_assert(sizeof(db_runtime_plan_v1) == 56,
              "old db_runtime_plan_v1 size changed");
static_assert(offsetof(db_runtime_plan_v1, eq_gains_db) == 32,
              "old db_runtime_plan_v1 layout changed");
static_assert(sizeof(db_meter_snapshot_v1) == 32,
              "db_meter_snapshot_v1 size changed");
static_assert(offsetof(db_meter_snapshot_v1, input_peak) == 16,
              "db_meter_snapshot_v1.input_peak offset changed");
static_assert(offsetof(db_meter_snapshot_v1, output_peak) == 24,
              "db_meter_snapshot_v1.output_peak offset changed");

static int db_run_cpp17_update_smoke() {
  db_runtime_plan_v1 plan = {
      static_cast<uint32_t>(sizeof(db_runtime_plan_v1)),
      DB_ABI_VERSION,
      DB_PLAN_SCHEMA_VERSION,
      DB_PROCESSOR_VERSION,
      0u,
      0u,
      0.0,
      {0.0, 0.0, 0.0},
  };
  db_meter_snapshot_v1 meter = {
      static_cast<uint32_t>(sizeof(db_meter_snapshot_v1)),
      DB_ABI_VERSION,
      DB_PROCESSOR_VERSION,
      0u,
      {0.0f, 0.0f},
      {0.0f, 0.0f},
  };
  db_processor *processor = nullptr;
  float left[DB_SMOKE_FRAMES];
  float right[DB_SMOKE_FRAMES];

  db_status status =
      db_processor_create(&plan, 48000.0, DB_SMOKE_FRAMES, &processor);
  if (db_smoke_expect_status("C++17", "update create", status,
                             DB_STATUS_OK) != 0) {
    return 1;
  }

  plan.eq_gains_db[1] = 3.5;
  status = db_processor_set_plan_v1(processor, &plan);
  if (db_smoke_expect_status("C++17", "invalid update", status,
                             DB_STATUS_INVALID_CONFIGURATION) != 0) {
    (void)db_processor_destroy(processor);
    return 1;
  }
  plan.applied_gain_db = -2.0;
  plan.eq_gains_db[0] = -1.0;
  plan.eq_gains_db[1] = 1.0;
  plan.eq_gains_db[2] = -0.5;
  status = db_processor_set_plan_v1(processor, &plan);
  if (db_smoke_expect_status("C++17", "valid update", status,
                             DB_STATUS_OK) != 0) {
    (void)db_processor_destroy(processor);
    return 1;
  }

  db_smoke_fill_input(left, right);
  status = db_processor_process_f32(processor, left, right, DB_SMOKE_FRAMES);
  if (db_smoke_expect_status("C++17", "updated process", status,
                             DB_STATUS_OK) != 0 ||
      !db_smoke_output_is_finite(left, right)) {
    (void)db_processor_destroy(processor);
    return 1;
  }

  status = db_processor_get_meter_v1(processor, &meter);
  if (db_smoke_expect_status("C++17", "meter", status, DB_STATUS_OK) != 0) {
    (void)db_processor_destroy(processor);
    return 1;
  }
  for (std::size_t channel = 0; channel < 2; ++channel) {
    if (!std::isfinite(meter.input_peak[channel]) ||
        !std::isfinite(meter.output_peak[channel])) {
      fprintf(stderr, "C++17: meter produced non-finite peaks\n");
      (void)db_processor_destroy(processor);
      return 1;
    }
  }

  return db_smoke_expect_status("C++17", "update destroy",
                                db_processor_destroy(processor), DB_STATUS_OK);
}

int main() {
  if (db_run_native_abi_smoke("C++17") != 0) {
    return 1;
  }
  return db_run_cpp17_update_smoke();
}
