#include "Doppelbanger.h"

#include "IPlug_include_in_plug_src.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <thread>

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

bool Doppelbanger::StateMailbox::TryPublish(const StatePacket& packet,
                                            std::uint32_t attempts) noexcept {
  for (std::uint32_t attempt = 0; attempt < attempts; ++attempt) {
    std::uint32_t state = mState.load(std::memory_order_acquire);
    if (state != kEmpty && state != kReady) {
      continue;
    }
    if (!mState.compare_exchange_strong(state, kWriting, std::memory_order_acq_rel,
                                        std::memory_order_acquire)) {
      continue;
    }
    mPacket = packet;
    mState.store(kReady, std::memory_order_release);
    return true;
  }
  return false;
}

bool Doppelbanger::StateMailbox::TryConsume(StatePacket& packet,
                                            std::uint32_t attempts) noexcept {
  for (std::uint32_t attempt = 0; attempt < attempts; ++attempt) {
    std::uint32_t expected = kReady;
    if (!mState.compare_exchange_strong(expected, kReading, std::memory_order_acq_rel,
                                        std::memory_order_acquire)) {
      continue;
    }
    packet = mPacket;
    mState.store(kEmpty, std::memory_order_release);
    return true;
  }
  return false;
}

Doppelbanger::Doppelbanger(const iplug::InstanceInfo& info)
    : iplug::Plugin(info, iplug::MakeConfig(kNumParams, kNumPresets)),
      mPlan(DefaultPlan()) {
  GetParam(kLowEqParam)->InitDouble("Low EQ", 0.0, -3.0, 3.0, 0.01, "dB");
  GetParam(kMidEqParam)->InitDouble("Mid EQ", 0.0, -3.0, 3.0, 0.01, "dB");
  GetParam(kHighEqParam)->InitDouble("High EQ", 0.0, -3.0, 3.0, 0.01, "dB");
  GetParam(kOutputParam)->InitDouble("Output", 0.0, -12.0, 12.0, 0.01, "dB");
  mUiStateCache.plan = mPlan;
}

Doppelbanger::~Doppelbanger() { DestroyProcessor(); }

bool Doppelbanger::SerializeState(iplug::IByteChunk& chunk) const {
  try {
    doppelbanger::state::EncodedStateV1 encoded{};
    const StatePacket state = CurrentStateForUi();
    if (doppelbanger::state::EncodeStateV1(state.plan, encoded) !=
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

    std::int32_t savedBypass = CurrentStateForUi().hostBypass;
    if (remaining == vst3StateSize) {
      std::memcpy(&savedBypass, chunk.GetData() + startPos + codecSize,
                  sizeof(savedBypass));
      if (savedBypass != 0 && savedBypass != 1) {
        return -1;
      }
    }
    if (!QueueStateFromUi(decoded, savedBypass)) {
      return -1;
    }
    return startPos + codecSize;
  } catch (...) {
    return -1;
  }
}

void Doppelbanger::OnActivate(bool active) {
  try {
    if (!active) {
      StatePacket state = CurrentStateForUi();
      if (mAudioStateGeneration >= state.generation) {
        state = StatePacket{PlanFromParameters(mPlan), GetBypassed() ? 1 : 0,
                            mAudioStateGeneration};
      }
      mUiStateCache = state;
      DestroyProcessor();
      return;
    }
    const StatePacket state = CurrentStateForUi();
    if (!ReplaceProcessor(state.plan)) {
      DestroyProcessor();
      return;
    }
    mAudioStateGeneration = state.generation;
    SetBypassed(state.hostBypass != 0);
  } catch (...) {
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
      if (!ReplaceProcessor(PlanFromParameters(mPlan))) {
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
      SilenceProcessData(data);
      return Steinberg::kResultFalse;
    }
    if (data.numSamples > 0 &&
        (data.numInputs != 1 || data.numOutputs != 1 || data.inputs == nullptr ||
         data.outputs == nullptr || data.inputs[0].numChannels != 2 ||
         data.outputs[0].numChannels != 2)) {
      SilenceProcessData(data);
      return Steinberg::kResultFalse;
    }
    if (!ApplyPendingState()) {
      SilenceProcessData(data);
      return Steinberg::kResultFalse;
    }
    const Steinberg::tresult result = iplug::Plugin::process(data);
    PublishAudioState();
    return result;
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
    if (!QueueStateFromUi(decoded, savedBypass)) {
      return Steinberg::kResultFalse;
    }

    iplug::IPlugVST3ControllerBase::UpdateParams(this, savedBypass);
    OnRestoreState();
    return Steinberg::kResultOk;
  } catch (...) {
    return Steinberg::kResultFalse;
  }
}

Steinberg::tresult PLUGIN_API Doppelbanger::getState(Steinberg::IBStream* state) {
  try {
    if (state == nullptr) {
      return Steinberg::kResultFalse;
    }

    const StatePacket snapshot = CurrentStateForUi();
    doppelbanger::state::EncodedStateV1 encoded{};
    if (doppelbanger::state::EncodeStateV1(snapshot.plan, encoded) !=
            doppelbanger::state::StateCodecStatus::kOk ||
        (snapshot.hostBypass != 0 && snapshot.hostBypass != 1)) {
      return Steinberg::kResultFalse;
    }

    constexpr std::size_t kVst3StateSize =
        doppelbanger::state::kEncodedStateV1Size + sizeof(std::int32_t);
    std::array<std::uint8_t, kVst3StateSize> bytes{};
    std::copy(encoded.begin(), encoded.end(), bytes.begin());
    std::memcpy(bytes.data() + encoded.size(), &snapshot.hostBypass,
                sizeof(snapshot.hostBypass));

    Steinberg::int32 bytesWritten = 0;
    const Steinberg::tresult result =
        state->write(bytes.data(), static_cast<Steinberg::int32>(bytes.size()),
                     &bytesWritten);
    if (result != Steinberg::kResultOk ||
        bytesWritten != static_cast<Steinberg::int32>(bytes.size())) {
      return Steinberg::kResultFalse;
    }
    return Steinberg::kResultOk;
  } catch (...) {
    return Steinberg::kResultFalse;
  }
}

db_runtime_plan_v1 Doppelbanger::PlanFromParameters(
    const db_runtime_plan_v1& base) const noexcept {
  db_runtime_plan_v1 plan = base;
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

Doppelbanger::StatePacket Doppelbanger::CurrentStateForUi() const {
  StatePacket published{};
  for (std::uint32_t attempt = 0; attempt < 64; ++attempt) {
    if (!mPublishedState.TryConsume(published, 1)) {
      continue;
    }
    if (published.generation >= mUiStateCache.generation) {
      mUiStateCache = published;
    }
    break;
  }

  StatePacket state = mUiStateCache;
  state.plan = PlanFromParameters(state.plan);
  mUiStateCache.plan = state.plan;
  return state;
}

bool Doppelbanger::QueueStateFromUi(const db_runtime_plan_v1& plan,
                                    std::int32_t hostBypass) noexcept {
  if (!doppelbanger::state::IsValidPlanV1(plan) ||
      (hostBypass != 0 && hostBypass != 1)) {
    return false;
  }

  StatePacket pending{plan, hostBypass, mNextStateGeneration};
  bool published = false;
  for (std::uint32_t attempt = 0; attempt < 64 && !published; ++attempt) {
    published = mPendingState.TryPublish(pending, 1);
    if (!published) {
      std::this_thread::yield();
    }
  }
  if (!published) {
    return false;
  }

  GetParam(kLowEqParam)->Set(plan.eq_gains_db[0]);
  GetParam(kMidEqParam)->Set(plan.eq_gains_db[1]);
  GetParam(kHighEqParam)->Set(plan.eq_gains_db[2]);
  GetParam(kOutputParam)->Set(plan.applied_gain_db);
  mUiStateCache = pending;
  ++mNextStateGeneration;
  return true;
}

bool Doppelbanger::ApplyPendingState() noexcept {
  StatePacket pending{};
  if (!mPendingState.TryConsume(pending, 1)) {
    return true;
  }
  if (mProcessor == nullptr ||
      db_processor_set_plan_v1(mProcessor, &pending.plan) != DB_STATUS_OK ||
      db_processor_reset(mProcessor) != DB_STATUS_OK) {
    return false;
  }

  mPlan = pending.plan;
  mParametersDirty = false;
  mAudioStateGeneration = pending.generation;
  SetBypassed(pending.hostBypass != 0);
  return true;
}

void Doppelbanger::PublishAudioState() noexcept {
  const StatePacket state{PlanFromParameters(mPlan), GetBypassed() ? 1 : 0,
                          mAudioStateGeneration};
  static_cast<void>(mPublishedState.TryPublish(state, 1));
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
  const db_runtime_plan_v1 plan = PlanFromParameters(mPlan);
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
  if (data.numSamples <= 0 ||
      data.numSamples > static_cast<Steinberg::int32>(DB_MAX_BLOCK_FRAMES) ||
      data.numOutputs < 1 || data.outputs == nullptr) {
    return;
  }

  Steinberg::Vst::AudioBusBuffers& output = data.outputs[0];
  const int channels = std::clamp<Steinberg::int32>(output.numChannels, 0, 2);
  Steinberg::uint64 silenceFlags = 0;
  if (data.symbolicSampleSize == Steinberg::Vst::kSample32 &&
      output.channelBuffers32 != nullptr) {
    for (int channel = 0; channel < channels; ++channel) {
      if (output.channelBuffers32[channel] != nullptr) {
        std::fill_n(output.channelBuffers32[channel], data.numSamples, 0.0F);
        silenceFlags |= Steinberg::uint64{1} << channel;
      }
    }
  } else if (data.symbolicSampleSize == Steinberg::Vst::kSample64 &&
             output.channelBuffers64 != nullptr) {
    for (int channel = 0; channel < channels; ++channel) {
      if (output.channelBuffers64[channel] != nullptr) {
        std::fill_n(output.channelBuffers64[channel], data.numSamples, 0.0);
        silenceFlags |= Steinberg::uint64{1} << channel;
      }
    }
  }
  output.silenceFlags |= silenceFlags;
}
