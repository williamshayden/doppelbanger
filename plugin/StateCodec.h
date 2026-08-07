#pragma once

#include "doppelbanger_dsp.h"

#include <array>
#include <cstddef>
#include <cstdint>

namespace doppelbanger::state {

inline constexpr std::size_t kStatePayloadV1Size = 56;
inline constexpr std::size_t kEncodedStateV1Size = 72;

using EncodedStateV1 = std::array<std::uint8_t, kEncodedStateV1Size>;

enum class StateCodecStatus {
  kOk,
  kNullPointer,
  kWrongSize,
  kWrongMagic,
  kUnsupportedVersion,
  kWrongPayloadLength,
  kCrcMismatch,
  kInvalidPlan,
};

[[nodiscard]] StateCodecStatus EncodeStateV1(const db_runtime_plan_v1& plan,
                                             EncodedStateV1& output) noexcept;

[[nodiscard]] StateCodecStatus DecodeStateV1(const std::uint8_t* bytes,
                                             std::size_t size,
                                             db_runtime_plan_v1& output) noexcept;

[[nodiscard]] bool IsValidPlanV1(const db_runtime_plan_v1& plan) noexcept;

}  // namespace doppelbanger::state
