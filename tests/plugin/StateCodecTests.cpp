#include "StateCodec.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>

namespace {

using doppelbanger::state::DecodeStateV1;
using doppelbanger::state::EncodeStateV1;
using doppelbanger::state::EncodedStateV1;
using doppelbanger::state::StateCodecStatus;

constexpr std::array<std::uint8_t, 72> kGoldenState{
    0x44, 0x42, 0x53, 0x54, 0x01, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00, 0x00,
    0x38, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x08, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xE0, 0x3F,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x08, 0x40, 0x3E, 0x3C, 0xB0, 0xD9,
};

constexpr std::size_t kStructSizeOffset = 12;
constexpr std::size_t kAbiVersionOffset = 16;
constexpr std::size_t kPlanVersionOffset = 20;
constexpr std::size_t kProcessorVersionOffset = 24;
constexpr std::size_t kBypassOffset = 28;
constexpr std::size_t kReservedOffset = 32;
constexpr std::size_t kAppliedGainOffset = 36;
constexpr std::size_t kEqGainOffset = 44;
constexpr std::size_t kCrcOffset = 68;

int gFailures = 0;

void Expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++gFailures;
  }
}

void WriteU32Le(EncodedStateV1& bytes, std::size_t offset, std::uint32_t value) {
  for (std::size_t index = 0; index < 4; ++index) {
    bytes[offset + index] = static_cast<std::uint8_t>(value >> (index * 8));
  }
}

void WriteF64Le(EncodedStateV1& bytes, std::size_t offset, double value) {
  std::uint64_t bits = 0;
  static_assert(sizeof(bits) == sizeof(value));
  std::memcpy(&bits, &value, sizeof(bits));
  for (std::size_t index = 0; index < 8; ++index) {
    bytes[offset + index] = static_cast<std::uint8_t>(bits >> (index * 8));
  }
}

std::uint32_t FixtureCrc32(const std::uint8_t* bytes, std::size_t size) {
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

void RefreshFixtureCrc(EncodedStateV1& bytes) {
  WriteU32Le(bytes, kCrcOffset, FixtureCrc32(bytes.data(), kCrcOffset));
}

db_runtime_plan_v1 GoldenPlan() {
  return db_runtime_plan_v1{
      sizeof(db_runtime_plan_v1), DB_ABI_VERSION, DB_PLAN_SCHEMA_VERSION,
      DB_PROCESSOR_VERSION,       0U,             0U,
      1.0,                        {-3.0, 0.5, 3.0},
  };
}

void ExpectPlanEquals(const db_runtime_plan_v1& actual,
                      const db_runtime_plan_v1& expected,
                      const char* message) {
  const bool matches =
      actual.struct_size == expected.struct_size &&
      actual.abi_version == expected.abi_version &&
      actual.plan_schema_version == expected.plan_schema_version &&
      actual.processor_version == expected.processor_version &&
      actual.bypass == expected.bypass && actual.reserved == expected.reserved &&
      actual.applied_gain_db == expected.applied_gain_db &&
      actual.eq_gains_db[0] == expected.eq_gains_db[0] &&
      actual.eq_gains_db[1] == expected.eq_gains_db[1] &&
      actual.eq_gains_db[2] == expected.eq_gains_db[2];
  Expect(matches, message);
}

void GoldenBytesRoundTripEveryPlanField() {
  const db_runtime_plan_v1 plan = GoldenPlan();
  EncodedStateV1 encoded{};

  Expect(EncodeStateV1(plan, encoded) == StateCodecStatus::kOk,
         "valid V1 plan encodes");
  Expect(encoded == kGoldenState, "encoding matches the fixed golden bytes");

  db_runtime_plan_v1 decoded{};
  Expect(DecodeStateV1(kGoldenState.data(), kGoldenState.size(), decoded) ==
             StateCodecStatus::kOk,
         "golden bytes decode");
  ExpectPlanEquals(decoded, plan, "round-trip preserves every effective plan field");
}

void MalformedFramingIsRejected() {
  db_runtime_plan_v1 output = GoldenPlan();

  auto wrongMagic = kGoldenState;
  wrongMagic[0] = 0x00;
  Expect(DecodeStateV1(wrongMagic.data(), wrongMagic.size(), output) ==
             StateCodecStatus::kWrongMagic,
         "wrong magic is rejected");

  auto wrongVersion = kGoldenState;
  WriteU32Le(wrongVersion, 4, 2U);
  Expect(DecodeStateV1(wrongVersion.data(), wrongVersion.size(), output) ==
             StateCodecStatus::kUnsupportedVersion,
         "wrong schema version is rejected");

  auto wrongPayloadLength = kGoldenState;
  WriteU32Le(wrongPayloadLength, 8, 55U);
  Expect(DecodeStateV1(wrongPayloadLength.data(), wrongPayloadLength.size(), output) ==
             StateCodecStatus::kWrongPayloadLength,
         "wrong payload length is rejected");

  auto wrongCrc = kGoldenState;
  wrongCrc[kCrcOffset] ^= 0x80U;
  Expect(DecodeStateV1(wrongCrc.data(), wrongCrc.size(), output) ==
             StateCodecStatus::kCrcMismatch,
         "wrong CRC is rejected");

  Expect(DecodeStateV1(kGoldenState.data(), kGoldenState.size() - 1, output) ==
             StateCodecStatus::kWrongSize,
         "truncated state is rejected");

  std::array<std::uint8_t, 73> trailing{};
  std::memcpy(trailing.data(), kGoldenState.data(), kGoldenState.size());
  trailing.back() = 0xA5U;
  Expect(DecodeStateV1(trailing.data(), trailing.size(), output) ==
             StateCodecStatus::kWrongSize,
         "trailing bytes are rejected");

  Expect(DecodeStateV1(nullptr, kGoldenState.size(), output) ==
             StateCodecStatus::kNullPointer,
         "null state bytes are rejected");
}

void InvalidPlanValuesAreRejectedBeforeOutputMutation() {
  struct InvalidFixture {
    const char* name;
    std::size_t offset;
    bool isDouble;
    std::uint32_t integer;
    double floating;
  };

  const std::array<InvalidFixture, 10> invalidFixtures{{
      {"wrong struct size", kStructSizeOffset, false, 48U, 0.0},
      {"wrong ABI version", kAbiVersionOffset, false, 2U, 0.0},
      {"wrong plan version", kPlanVersionOffset, false, 2U, 0.0},
      {"wrong processor version", kProcessorVersionOffset, false, 2U, 0.0},
      {"invalid bypass", kBypassOffset, false, 2U, 0.0},
      {"nonzero reserved", kReservedOffset, false, 1U, 0.0},
      {"non-finite gain", kAppliedGainOffset, true, 0U,
       std::numeric_limits<double>::infinity()},
      {"gain above range", kAppliedGainOffset, true, 0U, 13.0},
      {"EQ below range", kEqGainOffset, true, 0U, -4.0},
      {"EQ above range", kEqGainOffset + 16, true, 0U, 4.0},
  }};

  for (const auto& invalid : invalidFixtures) {
    EncodedStateV1 bytes = kGoldenState;
    if (invalid.isDouble) {
      WriteF64Le(bytes, invalid.offset, invalid.floating);
    } else {
      WriteU32Le(bytes, invalid.offset, invalid.integer);
    }
    RefreshFixtureCrc(bytes);

    db_runtime_plan_v1 output{
        999U, 998U, 997U, 996U, 995U, 994U, 993.0, {992.0, 991.0, 990.0},
    };
    const db_runtime_plan_v1 sentinel = output;
    Expect(DecodeStateV1(bytes.data(), bytes.size(), output) ==
               StateCodecStatus::kInvalidPlan,
           invalid.name);
    ExpectPlanEquals(output, sentinel, "invalid state cannot partially mutate output");
  }

  EncodedStateV1 bypassWithProcessing = kGoldenState;
  WriteU32Le(bypassWithProcessing, kBypassOffset, 1U);
  RefreshFixtureCrc(bypassWithProcessing);
  db_runtime_plan_v1 output = GoldenPlan();
  const db_runtime_plan_v1 sentinel = output;
  Expect(DecodeStateV1(bypassWithProcessing.data(), bypassWithProcessing.size(), output) ==
             StateCodecStatus::kInvalidPlan,
         "bypass with nonzero processing values is rejected");
  ExpectPlanEquals(output, sentinel, "invalid bypass state cannot mutate output");

  db_runtime_plan_v1 invalidEncode = GoldenPlan();
  invalidEncode.eq_gains_db[1] = std::numeric_limits<double>::quiet_NaN();
  EncodedStateV1 encoded{};
  encoded.fill(0xA5U);
  const EncodedStateV1 before = encoded;
  Expect(EncodeStateV1(invalidEncode, encoded) == StateCodecStatus::kInvalidPlan,
         "invalid plans cannot be encoded");
  Expect(encoded == before, "failed encoding cannot partially mutate output bytes");
}

}  // namespace

int main() {
  static_assert(EncodedStateV1{}.size() == kGoldenState.size());
  GoldenBytesRoundTripEveryPlanField();
  MalformedFramingIsRejected();
  InvalidPlanValuesAreRejectedBeforeOutputMutation();

  if (gFailures != 0) {
    std::cerr << gFailures << " StateCodec test assertion(s) failed\n";
    return 1;
  }
  std::cout << "StateCodecTests: ok\n";
  return 0;
}
