#include "doppelbanger_dsp.h"

#include "native_abi_smoke.h"

_Static_assert(sizeof(db_runtime_plan_v1) == 56,
               "old db_runtime_plan_v1 size changed");
_Static_assert(offsetof(db_runtime_plan_v1, eq_gains_db) == 32,
               "old db_runtime_plan_v1 layout changed");
_Static_assert(sizeof(db_meter_snapshot_v1) == 32,
               "db_meter_snapshot_v1 size changed");
_Static_assert(offsetof(db_meter_snapshot_v1, input_peak) == 16,
               "db_meter_snapshot_v1.input_peak offset changed");
_Static_assert(offsetof(db_meter_snapshot_v1, output_peak) == 24,
               "db_meter_snapshot_v1.output_peak offset changed");

static int db_run_c11_update_smoke(void) {
  db_runtime_plan_v1 plan = {
      (uint32_t)sizeof(db_runtime_plan_v1), DB_ABI_VERSION,
      DB_PLAN_SCHEMA_VERSION, DB_PROCESSOR_VERSION, 0u, 0u, 0.0,
      {0.0, 0.0, 0.0}};
  db_meter_snapshot_v1 meter;
  db_processor *processor = NULL;
  float left[DB_SMOKE_FRAMES];
  float right[DB_SMOKE_FRAMES];
  db_status status;
  size_t frame;

  meter.struct_size = (uint32_t)sizeof(db_meter_snapshot_v1);
  meter.abi_version = DB_ABI_VERSION;
  meter.processor_version = DB_PROCESSOR_VERSION;
  meter.reserved = 0u;

  status = db_processor_create(&plan, 48000.0, DB_SMOKE_FRAMES, &processor);
  if (db_smoke_expect_status("C11", "update create", status,
                             DB_STATUS_OK) != 0) {
    return 1;
  }

  plan.applied_gain_db = 12.5;
  status = db_processor_set_plan_v1(processor, &plan);
  if (db_smoke_expect_status("C11", "invalid update", status,
                             DB_STATUS_INVALID_CONFIGURATION) != 0) {
    (void)db_processor_destroy(processor);
    return 1;
  }
  plan.applied_gain_db = 2.0;
  plan.eq_gains_db[0] = 1.0;
  plan.eq_gains_db[1] = -1.0;
  plan.eq_gains_db[2] = 0.5;
  status = db_processor_set_plan_v1(processor, &plan);
  if (db_smoke_expect_status("C11", "valid update", status, DB_STATUS_OK) !=
      0) {
    (void)db_processor_destroy(processor);
    return 1;
  }

  db_smoke_fill_input(left, right);
  status = db_processor_process_f32(processor, left, right, DB_SMOKE_FRAMES);
  if (db_smoke_expect_status("C11", "updated process", status,
                             DB_STATUS_OK) != 0 ||
      !db_smoke_output_is_finite(left, right)) {
    (void)db_processor_destroy(processor);
    return 1;
  }

  status = db_processor_get_meter_v1(processor, &meter);
  if (db_smoke_expect_status("C11", "meter", status, DB_STATUS_OK) != 0) {
    (void)db_processor_destroy(processor);
    return 1;
  }
  for (frame = 0; frame < 2u; ++frame) {
    if (!isfinite(meter.input_peak[frame]) ||
        !isfinite(meter.output_peak[frame])) {
      fprintf(stderr, "C11: meter produced non-finite peaks\n");
      (void)db_processor_destroy(processor);
      return 1;
    }
  }

  return db_smoke_expect_status("C11", "update destroy",
                                db_processor_destroy(processor), DB_STATUS_OK);
}

int main(void) {
  if (db_run_native_abi_smoke("C11") != 0) {
    return 1;
  }
  return db_run_c11_update_smoke();
}
