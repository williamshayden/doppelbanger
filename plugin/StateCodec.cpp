#include "StateCodec.h"

#include <cmath>
#include <cstring>

namespace doppelbanger::state {
namespace {

constexpr std::array<std::uint8_t, 4> kMagic{'D', 'B', 'S', 'T'};
constexpr std::uint32_t kSchemaVersion = 1U;
constexpr std::size_t kHeaderSize = 12;
constexpr std::size_t kCrcOffset = kEncodedStateV1Size - sizeof(std::uint32_t);
static_assert(sizeof(db_runtime_plan_v1) == kStatePayloadV1Size);
static_assert(kHeaderSize + kStatePayloadV1Size + sizeof(std::uint32_t) ==
              kEncodedStateV1Size);

void WriteU32Le(EncodedStateV1& output, std::size_t& offset, std::uint32_t value) noexcept {
  for (std::size_t index = 0; index < sizeof(value); ++index) {
    output[offset++] = static_cast<std::uint8_t>(value >> (index * 8U));
  }
}

void WriteF64Le(EncodedStateV1& output, std::size_t& offset, double value) noexcept {
  std::uint64_t bits = 0;
  static_assert(sizeof(bits) == sizeof(value));
  std::memcpy(&bits, &value, sizeof(bits));
  for (std::size_t index = 0; index < sizeof(bits); ++index) {
    output[offset++] = static_cast<std::uint8_t>(bits >> (index * 8U));
  }
}

std::uint32_t ReadU32Le(const std::uint8_t* bytes, std::size_t& offset) noexcept {
  std::uint32_t value = 0;
  for (std::size_t index = 0; index < sizeof(value); ++index) {
    value |= static_cast<std::uint32_t>(bytes[offset++]) << (index * 8U);
  }
  return value;
}

double ReadF64Le(const std::uint8_t* bytes, std::size_t& offset) noexcept {
  std::uint64_t bits = 0;
  for (std::size_t index = 0; index < sizeof(bits); ++index) {
    bits |= static_cast<std::uint64_t>(bytes[offset++]) << (index * 8U);
  }
  double value = 0.0;
  std::memcpy(&value, &bits, sizeof(value));
  return value;
}

std::uint32_t Crc32(const std::uint8_t* bytes, std::size_t size) noexcept {
  std::uint32_t crc = 0xFFFFFFFFU;
  for (std::size_t index = 0; index < size; ++index) {
    crc ^= bytes[index];
    for (int bit = 0; bit < 8; ++bit) {
      const std::uint32_t mask = 0U - (crc & 1U);
      crc = (crc >> 1U) ^ (0xEDB88320U & mask);
    }
  }
  return crc ^ 0xFFFFFFFFU;
}

}  // namespace

bool IsValidPlanV1(const db_runtime_plan_v1& plan) noexcept {
  return plan.struct_size == sizeof(db_runtime_plan_v1) &&
         plan.abi_version == DB_ABI_VERSION &&
         plan.plan_schema_version == DB_PLAN_SCHEMA_VERSION &&
         plan.processor_version == DB_PROCESSOR_VERSION && plan.bypass <= 1U &&
         plan.reserved == 0U && std::isfinite(plan.applied_gain_db) &&
         plan.applied_gain_db >= -12.0 && plan.applied_gain_db <= 12.0 &&
         std::isfinite(plan.eq_gains_db[0]) && plan.eq_gains_db[0] >= -3.0 &&
         plan.eq_gains_db[0] <= 3.0 && std::isfinite(plan.eq_gains_db[1]) &&
         plan.eq_gains_db[1] >= -3.0 && plan.eq_gains_db[1] <= 3.0 &&
         std::isfinite(plan.eq_gains_db[2]) && plan.eq_gains_db[2] >= -3.0 &&
         plan.eq_gains_db[2] <= 3.0 &&
         (plan.bypass == 0U ||
          (plan.applied_gain_db == 0.0 && plan.eq_gains_db[0] == 0.0 &&
           plan.eq_gains_db[1] == 0.0 && plan.eq_gains_db[2] == 0.0));
}

StateCodecStatus EncodeStateV1(const db_runtime_plan_v1& plan,
                               EncodedStateV1& output) noexcept {
  if (!IsValidPlanV1(plan)) {
    return StateCodecStatus::kInvalidPlan;
  }

  EncodedStateV1 encoded{};
  std::size_t offset = 0;
  for (const std::uint8_t byte : kMagic) {
    encoded[offset++] = byte;
  }
  WriteU32Le(encoded, offset, kSchemaVersion);
  WriteU32Le(encoded, offset, static_cast<std::uint32_t>(kStatePayloadV1Size));
  WriteU32Le(encoded, offset, plan.struct_size);
  WriteU32Le(encoded, offset, plan.abi_version);
  WriteU32Le(encoded, offset, plan.plan_schema_version);
  WriteU32Le(encoded, offset, plan.processor_version);
  WriteU32Le(encoded, offset, plan.bypass);
  WriteU32Le(encoded, offset, plan.reserved);
  WriteF64Le(encoded, offset, plan.applied_gain_db);
  for (const double gain : plan.eq_gains_db) {
    WriteF64Le(encoded, offset, gain);
  }
  const std::uint32_t crc = Crc32(encoded.data(), offset);
  WriteU32Le(encoded, offset, crc);

  if (offset != encoded.size()) {
    return StateCodecStatus::kWrongSize;
  }
  output = encoded;
  return StateCodecStatus::kOk;
}

StateCodecStatus DecodeStateV1(const std::uint8_t* bytes,
                               std::size_t size,
                               db_runtime_plan_v1& output) noexcept {
  if (bytes == nullptr) {
    return StateCodecStatus::kNullPointer;
  }
  if (size != kEncodedStateV1Size) {
    return StateCodecStatus::kWrongSize;
  }
  if (std::memcmp(bytes, kMagic.data(), kMagic.size()) != 0) {
    return StateCodecStatus::kWrongMagic;
  }

  std::size_t offset = kMagic.size();
  if (ReadU32Le(bytes, offset) != kSchemaVersion) {
    return StateCodecStatus::kUnsupportedVersion;
  }
  if (ReadU32Le(bytes, offset) != kStatePayloadV1Size) {
    return StateCodecStatus::kWrongPayloadLength;
  }

  std::size_t crcOffset = kCrcOffset;
  const std::uint32_t storedCrc = ReadU32Le(bytes, crcOffset);
  if (storedCrc != Crc32(bytes, kCrcOffset)) {
    return StateCodecStatus::kCrcMismatch;
  }

  db_runtime_plan_v1 decoded{};
  decoded.struct_size = ReadU32Le(bytes, offset);
  decoded.abi_version = ReadU32Le(bytes, offset);
  decoded.plan_schema_version = ReadU32Le(bytes, offset);
  decoded.processor_version = ReadU32Le(bytes, offset);
  decoded.bypass = ReadU32Le(bytes, offset);
  decoded.reserved = ReadU32Le(bytes, offset);
  decoded.applied_gain_db = ReadF64Le(bytes, offset);
  for (double& gain : decoded.eq_gains_db) {
    gain = ReadF64Le(bytes, offset);
  }
  if (offset != kCrcOffset || !IsValidPlanV1(decoded)) {
    return StateCodecStatus::kInvalidPlan;
  }

  output = decoded;
  return StateCodecStatus::kOk;
}

}  // namespace doppelbanger::state
