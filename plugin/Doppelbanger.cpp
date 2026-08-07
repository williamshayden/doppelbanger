#include "Doppelbanger.h"

#include "IPlug_include_in_plug_src.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>

namespace {

db_runtime_plan_v1 DefaultPlan() noexcept {
  return db_runtime_plan_v1{
      sizeof(db_runtime_plan_v1), DB_ABI_VERSION, DB_PLAN_SCHEMA_VERSION,
      DB_PROCESSOR_VERSION,       0U,             0U,
      0.0,                        {0.0, 0.0, 0.0},
  };
}

bool IsSupportedSampleRate(double sampleRate) noexcept {
  return sampleRate == 44'100.0 || sampleRate == 48'000.0 ||
         sampleRate == 88'200.0 || sampleRate == 96'000.0 ||
         sampleRate == 192'000.0;
}

}  // namespace

Doppelbanger::Doppelbanger(const iplug::InstanceInfo& info)
    : iplug::Plugin(info, iplug::MakeConfig(kNumParams, kNumPresets)),
      mPlan(DefaultPlan()) {
  GetParam(kLowEqParam)->InitDouble("Low EQ", 0.0, -3.0, 3.0, 0.01, "dB");
  GetParam(kMidEqParam)->InitDouble("Mid EQ", 0.0, -3.0, 3.0, 0.01, "dB");
  GetParam(kHighEqParam)->InitDouble("High EQ", 0.0, -3.0, 3.0, 0.01, "dB");
  GetParam(kOutputParam)->InitDouble("Output", 0.0, -12.0, 12.0, 0.01, "dB");
}

Doppelbanger::~Doppelbanger() { DestroyProcessor(); }

bool Doppelbanger::SerializeState(iplug::IByteChunk& chunk) const {
  try {
    doppelbanger::state::EncodedStateV1 encoded{};
    const db_runtime_plan_v1 plan = PlanFromParameters();
    if (doppelbanger::state::EncodeStateV1(plan, encoded) !=
        doppelbanger::state::StateCodecStatus::kOk) {
      return false;
    }
    chunk.Clear();
    return chunk.PutBytes(encoded.data(), static_cast<int>(encoded.size())) ==
           static_cast<int>(encoded.size());
  } catch (...) {
    return false;
  }
}

int Doppelbanger::UnserializeState(const iplug::IByteChunk& chunk, int startPos) {
  try {
    if (startPos < 0) {
      return -1;
    }
    const int remaining = chunk.Size() - startPos;
    const int codecSize =
        static_cast<int>(doppelbanger::state::kEncodedStateV1Size);
    const int vst3StateSize = codecSize + static_cast<int>(sizeof(std::int32_t));
    if (remaining != codecSize && remaining != vst3StateSize) {
      return -1;
    }

    db_runtime_plan_v1 decoded{};
    if (doppelbanger::state::DecodeStateV1(chunk.GetData() + startPos,
                                           doppelbanger::state::kEncodedStateV1Size,
                                           decoded) !=
        doppelbanger::state::StateCodecStatus::kOk) {
      return -1;
    }
    if (mActive && !ReplaceProcessor(decoded)) {
      return -1;
    }

    mPlan = decoded;
    GetParam(kLowEqParam)->Set(decoded.eq_gains_db[0]);
    GetParam(kMidEqParam)->Set(decoded.eq_gains_db[1]);
    GetParam(kHighEqParam)->Set(decoded.eq_gains_db[2]);
    GetParam(kOutputParam)->Set(decoded.applied_gain_db);
    mParametersDirty = false;
    return startPos + codecSize;
  } catch (...) {
    return -1;
  }
}

void Doppelbanger::OnActivate(bool active) {
  try {
    if (!active) {
      mActive = false;
      DestroyProcessor();
      return;
    }
    mActive = true;
    if (!ReplaceProcessor(PlanFromParameters())) {
      DestroyProcessor();
    }
  } catch (...) {
    mActive = active;
    DestroyProcessor();
  }
}

void Doppelbanger::OnReset() {
  try {
    if (mProcessor == nullptr) {
      return;
    }
    const auto sampleRate = static_cast<std::uint32_t>(GetSampleRate());
    const auto maxBlockFrames = static_cast<std::uint32_t>(GetBlockSize());
    if (sampleRate != mProcessorSampleRate ||
        maxBlockFrames != mProcessorMaxBlockFrames) {
      if (!ReplaceProcessor(PlanFromParameters())) {
        DestroyProcessor();
      }
      return;
    }
    if (db_processor_reset(mProcessor) != DB_STATUS_OK) {
      DestroyProcessor();
    }
  } catch (...) {
    DestroyProcessor();
  }
}

void Doppelbanger::OnParamChange(int paramIdx) {
  if (paramIdx >= kLowEqParam && paramIdx <= kOutputParam) {
    mParametersDirty = true;
  }
}

void Doppelbanger::ProcessBlock(iplug::sample** inputs,
                                iplug::sample** outputs,
                                int nFrames) {
  static_assert(sizeof(iplug::sample) == sizeof(float));
  try {
    if (nFrames < 0 || nFrames > static_cast<int>(DB_MAX_BLOCK_FRAMES) ||
        nFrames > static_cast<int>(mProcessorMaxBlockFrames)) {
      Silence(outputs, nFrames);
      return;
    }
    if (!ApplyParameterPlan()) {
      Silence(outputs, nFrames);
      return;
    }
    if (nFrames == 0) {
      return;
    }
    if (mProcessor == nullptr || inputs == nullptr || outputs == nullptr ||
        inputs[0] == nullptr || inputs[1] == nullptr || outputs[0] == nullptr ||
        outputs[1] == nullptr) {
      Silence(outputs, nFrames);
      return;
    }

    if (inputs[0] != outputs[0]) {
      std::copy_n(inputs[0], nFrames, outputs[0]);
    }
    if (inputs[1] != outputs[1]) {
      std::copy_n(inputs[1], nFrames, outputs[1]);
    }
    if (db_processor_process_f32(mProcessor, outputs[0], outputs[1],
                                 static_cast<std::uint32_t>(nFrames)) != DB_STATUS_OK) {
      Silence(outputs, nFrames);
    }
  } catch (...) {
    Silence(outputs, nFrames);
  }
}

Steinberg::tresult PLUGIN_API
Doppelbanger::setupProcessing(Steinberg::Vst::ProcessSetup& setup) {
  try {
    if (setup.symbolicSampleSize != Steinberg::Vst::kSample32 ||
        setup.maxSamplesPerBlock < 1 ||
        setup.maxSamplesPerBlock > static_cast<Steinberg::int32>(DB_MAX_BLOCK_FRAMES) ||
        !IsSupportedSampleRate(setup.sampleRate)) {
      return Steinberg::kResultFalse;
    }
    return iplug::Plugin::setupProcessing(setup);
  } catch (...) {
    return Steinberg::kResultFalse;
  }
}

Steinberg::tresult PLUGIN_API
Doppelbanger::canProcessSampleSize(Steinberg::int32 sampleSize) {
  return sampleSize == Steinberg::Vst::kSample32 ? Steinberg::kResultTrue
                                                 : Steinberg::kResultFalse;
}

Steinberg::tresult PLUGIN_API Doppelbanger::process(Steinberg::Vst::ProcessData& data) {
  try {
    if (data.symbolicSampleSize != Steinberg::Vst::kSample32 || data.numSamples < 0 ||
        data.numSamples > static_cast<Steinberg::int32>(DB_MAX_BLOCK_FRAMES) ||
        data.numSamples > static_cast<Steinberg::int32>(mProcessorMaxBlockFrames)) {
      return Steinberg::kResultFalse;
    }
    if (data.numSamples == 0) {
      return iplug::Plugin::process(data);
    }
    if (data.numInputs != 1 || data.numOutputs != 1 || data.inputs == nullptr ||
        data.outputs == nullptr || data.inputs[0].numChannels != 2 ||
        data.outputs[0].numChannels != 2) {
      return Steinberg::kResultFalse;
    }
    return iplug::Plugin::process(data);
  } catch (...) {
    SilenceProcessData(data);
    return Steinberg::kResultFalse;
  }
}

Steinberg::tresult PLUGIN_API Doppelbanger::setState(Steinberg::IBStream* state) {
  try {
    if (state == nullptr) {
      return Steinberg::kResultFalse;
    }
    constexpr std::size_t kVst3StateSize =
        doppelbanger::state::kEncodedStateV1Size + sizeof(std::int32_t);
    std::array<std::uint8_t, kVst3StateSize> bytes{};
    std::size_t total = 0;
    while (total < bytes.size()) {
      Steinberg::int32 bytesRead = 0;
      const auto result = state->read(bytes.data() + total,
                                      static_cast<Steinberg::int32>(bytes.size() - total),
                                      &bytesRead);
      if (bytesRead <= 0 ||
          (result != Steinberg::kResultTrue &&
           total + static_cast<std::size_t>(bytesRead) < bytes.size())) {
        return Steinberg::kResultFalse;
      }
      total += static_cast<std::size_t>(bytesRead);
    }

    std::uint8_t trailing = 0;
    Steinberg::int32 trailingBytes = 0;
    state->read(&trailing, 1, &trailingBytes);
    if (trailingBytes != 0) {
      return Steinberg::kResultFalse;
    }

    db_runtime_plan_v1 decoded{};
    if (doppelbanger::state::DecodeStateV1(
            bytes.data(), doppelbanger::state::kEncodedStateV1Size, decoded) !=
        doppelbanger::state::StateCodecStatus::kOk) {
      return Steinberg::kResultFalse;
    }
    std::int32_t savedBypass = 0;
    std::memcpy(&savedBypass,
                bytes.data() + doppelbanger::state::kEncodedStateV1Size,
                sizeof(savedBypass));
    if (savedBypass != 0 && savedBypass != 1) {
      return Steinberg::kResultFalse;
    }
    if (mActive && !ReplaceProcessor(decoded)) {
      return Steinberg::kResultFalse;
    }

    mPlan = decoded;
    GetParam(kLowEqParam)->Set(decoded.eq_gains_db[0]);
    GetParam(kMidEqParam)->Set(decoded.eq_gains_db[1]);
    GetParam(kHighEqParam)->Set(decoded.eq_gains_db[2]);
    GetParam(kOutputParam)->Set(decoded.applied_gain_db);
    mParametersDirty = false;
    SetBypassed(savedBypass != 0);
    iplug::IPlugVST3ControllerBase::UpdateParams(this, savedBypass);
    OnRestoreState();
    return Steinberg::kResultOk;
  } catch (...) {
    return Steinberg::kResultFalse;
  }
}

db_runtime_plan_v1 Doppelbanger::PlanFromParameters() const noexcept {
  db_runtime_plan_v1 plan = mPlan;
  const std::array<double, 3> eq{
      GetParam(kLowEqParam)->Value(),
      GetParam(kMidEqParam)->Value(),
      GetParam(kHighEqParam)->Value(),
  };
  const double output = GetParam(kOutputParam)->Value();
  if (eq[0] != plan.eq_gains_db[0] || eq[1] != plan.eq_gains_db[1] ||
      eq[2] != plan.eq_gains_db[2] || output != plan.applied_gain_db) {
    plan.bypass = 0U;
  }
  plan.applied_gain_db = output;
  std::copy(eq.begin(), eq.end(), plan.eq_gains_db);
  return plan;
}

bool Doppelbanger::ReplaceProcessor(const db_runtime_plan_v1& plan) noexcept {
  const double sampleRate = GetSampleRate();
  const int blockSize = GetBlockSize();
  if (!IsSupportedSampleRate(sampleRate) || blockSize < 1 ||
      blockSize > static_cast<int>(DB_MAX_BLOCK_FRAMES) ||
      !doppelbanger::state::IsValidPlanV1(plan)) {
    return false;
  }

  db_processor* replacement = nullptr;
  if (db_processor_create(&plan, sampleRate, static_cast<std::uint32_t>(blockSize),
                          &replacement) != DB_STATUS_OK ||
      replacement == nullptr) {
    return false;
  }
  const std::uint32_t latency = db_processor_latency_samples(replacement);
  if (latency == std::numeric_limits<std::uint32_t>::max()) {
    db_processor_destroy(replacement);
    return false;
  }

  db_processor* previous = mProcessor;
  mProcessor = replacement;
  mProcessorSampleRate = static_cast<std::uint32_t>(sampleRate);
  mProcessorMaxBlockFrames = static_cast<std::uint32_t>(blockSize);
  mPlan = plan;
  mParametersDirty = false;
  SetLatency(static_cast<int>(latency));
  if (previous != nullptr) {
    db_processor_destroy(previous);
  }
  return true;
}

bool Doppelbanger::ApplyParameterPlan() noexcept {
  if (!mParametersDirty) {
    return mProcessor != nullptr;
  }
  const db_runtime_plan_v1 plan = PlanFromParameters();
  if (!doppelbanger::state::IsValidPlanV1(plan) || mProcessor == nullptr ||
      db_processor_set_plan_v1(mProcessor, &plan) != DB_STATUS_OK) {
    return false;
  }
  mPlan = plan;
  mParametersDirty = false;
  return true;
}

void Doppelbanger::DestroyProcessor() noexcept {
  db_processor* processor = mProcessor;
  mProcessor = nullptr;
  mProcessorSampleRate = 0;
  mProcessorMaxBlockFrames = 0;
  if (processor != nullptr) {
    db_processor_destroy(processor);
  }
}

void Doppelbanger::Silence(iplug::sample** outputs, int nFrames) noexcept {
  if (outputs == nullptr || nFrames <= 0 ||
      nFrames > static_cast<int>(DB_MAX_BLOCK_FRAMES)) {
    return;
  }
  for (int channel = 0; channel < 2; ++channel) {
    if (outputs[channel] != nullptr) {
      std::fill_n(outputs[channel], nFrames, 0.0F);
    }
  }
}

void Doppelbanger::SilenceProcessData(Steinberg::Vst::ProcessData& data) noexcept {
  if (data.symbolicSampleSize != Steinberg::Vst::kSample32 || data.numSamples <= 0 ||
      data.numSamples > static_cast<Steinberg::int32>(DB_MAX_BLOCK_FRAMES) ||
      data.numOutputs != 1 || data.outputs == nullptr ||
      data.outputs[0].numChannels != 2 || data.outputs[0].channelBuffers32 == nullptr) {
    return;
  }
  for (int channel = 0; channel < 2; ++channel) {
    if (data.outputs[0].channelBuffers32[channel] != nullptr) {
      std::fill_n(data.outputs[0].channelBuffers32[channel], data.numSamples, 0.0F);
    }
  }
}
