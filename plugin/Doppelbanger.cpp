#include "Doppelbanger.h"

#include "IPlug_include_in_plug_src.h"

#include <algorithm>
#include <array>
#include <cmath>
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

double QuantizeCentibel(double value, double minimum, double maximum) noexcept {
  return std::clamp(std::round(value / 0.01) * 0.01, minimum, maximum);
}

bool PlansEqual(const db_runtime_plan_v1& left,
                const db_runtime_plan_v1& right) noexcept {
  return left.struct_size == right.struct_size &&
         left.abi_version == right.abi_version &&
         left.plan_schema_version == right.plan_schema_version &&
         left.processor_version == right.processor_version &&
         left.bypass == right.bypass && left.reserved == right.reserved &&
         left.applied_gain_db == right.applied_gain_db &&
         left.eq_gains_db[0] == right.eq_gains_db[0] &&
         left.eq_gains_db[1] == right.eq_gains_db[1] &&
         left.eq_gains_db[2] == right.eq_gains_db[2];
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
  constexpr int kStepped = iplug::IParam::kFlagStepped;
  GetParam(kLowEqParam)->InitDouble("Low EQ", 0.0, -3.0, 3.0, 0.01, "dB",
                                    kStepped);
  GetParam(kMidEqParam)->InitDouble("Mid EQ", 0.0, -3.0, 3.0, 0.01, "dB",
                                    kStepped);
  GetParam(kHighEqParam)->InitDouble("High EQ", 0.0, -3.0, 3.0, 0.01, "dB",
                                     kStepped);
  GetParam(kOutputParam)->InitDouble("Output", 0.0, -12.0, 12.0, 0.01, "dB",
                                     kStepped);
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
        state.plan = PlanFromParameters(mPlan);
        state.hostBypass = GetBypassed() ? 1 : 0;
        state.generation = mAudioStateGeneration;
        if (PlansEqual(state.plan, mPlan) && mPreparedValid == 1U) {
          state.prepared = mPreparedTargets;
          state.preparedSampleRate = mPreparedSampleRate;
          state.preparedValid = 1U;
        } else {
          state.prepared = {};
          state.preparedSampleRate = 0U;
          state.preparedValid = 0U;
        }
      }
      const std::uint32_t sampleRate =
          mConfiguredSampleRate.load(std::memory_order_acquire);
      if (sampleRate != 0U &&
          (state.preparedValid != 1U ||
           state.preparedSampleRate != sampleRate) &&
          !PrepareStatePacket(state, sampleRate)) {
        state.prepared = {};
        state.preparedSampleRate = 0U;
        state.preparedValid = 0U;
      }
      mUiStateCache = state;
      DestroyProcessor();
      return;
    }
    StatePacket state = CurrentStateForUi();
    const auto sampleRate = static_cast<std::uint32_t>(GetSampleRate());
    if (!PrepareStatePacket(state, sampleRate) ||
        !PublishPendingState(state) || !ReplaceProcessor(state.plan)) {
      DestroyProcessor();
      return;
    }
    mUiStateCache = state;
    mPreparedTargets = state.prepared;
    mPreparedSampleRate = state.preparedSampleRate;
    mPreparedValid = state.preparedValid;
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
    const Steinberg::tresult result = iplug::Plugin::setupProcessing(setup);
    if (result != Steinberg::kResultOk) {
      return result;
    }
    const auto sampleRate = static_cast<std::uint32_t>(setup.sampleRate);
    mConfiguredSampleRate.store(sampleRate, std::memory_order_release);
    StatePacket state = CurrentStateForUi();
    if (!PrepareStatePacket(state, sampleRate) || !PublishPendingState(state)) {
      return Steinberg::kResultFalse;
    }
    mUiStateCache = state;
    return result;
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
      const auto requested =
          static_cast<Steinberg::int32>(bytes.size() - total);
      Steinberg::int32 bytesRead = 0;
      const auto result =
          state->read(bytes.data() + total, requested, &bytesRead);
      if (result != Steinberg::kResultTrue || bytesRead <= 0 ||
          bytesRead > requested) {
        return Steinberg::kResultFalse;
      }
      total += static_cast<std::size_t>(bytesRead);
    }

    std::uint8_t trailing = 0;
    Steinberg::int32 trailingBytes = 0;
    const Steinberg::tresult trailingResult =
        state->read(&trailing, 1, &trailingBytes);
    if (trailingResult != Steinberg::kResultTrue || trailingBytes != 0) {
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
  const std::array<double, 3> actualEq{
      GetParam(kLowEqParam)->Value(),
      GetParam(kMidEqParam)->Value(),
      GetParam(kHighEqParam)->Value(),
  };
  const std::array<double, 3> projectedEq{
      QuantizeCentibel(base.eq_gains_db[0], -3.0, 3.0),
      QuantizeCentibel(base.eq_gains_db[1], -3.0, 3.0),
      QuantizeCentibel(base.eq_gains_db[2], -3.0, 3.0),
  };
  const double actualOutput = GetParam(kOutputParam)->Value();
  const double projectedOutput =
      QuantizeCentibel(base.applied_gain_db, -12.0, 12.0);
  if (actualEq != projectedEq || actualOutput != projectedOutput) {
    plan.bypass = 0U;
    plan.applied_gain_db = actualOutput;
    std::copy(actualEq.begin(), actualEq.end(), plan.eq_gains_db);
  }
  return plan;
}

db_runtime_plan_v1 Doppelbanger::SteppedPlanFromParameters() const noexcept {
  db_runtime_plan_v1 plan = mPlan;
  plan.bypass = 0U;
  plan.applied_gain_db = GetParam(kOutputParam)->Value();
  plan.eq_gains_db[0] = GetParam(kLowEqParam)->Value();
  plan.eq_gains_db[1] = GetParam(kMidEqParam)->Value();
  plan.eq_gains_db[2] = GetParam(kHighEqParam)->Value();
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
  const db_runtime_plan_v1 current = PlanFromParameters(state.plan);
  if (!PlansEqual(current, state.plan)) {
    state.plan = current;
    state.prepared = {};
    state.preparedSampleRate = 0U;
    state.preparedValid = 0U;
  }
  mUiStateCache.plan = state.plan;
  mUiStateCache.prepared = state.prepared;
  mUiStateCache.preparedSampleRate = state.preparedSampleRate;
  mUiStateCache.preparedValid = state.preparedValid;
  return state;
}

bool Doppelbanger::PrepareStatePacket(StatePacket& packet,
                                      std::uint32_t sampleRate) const noexcept {
  packet.prepared = {};
  packet.preparedSampleRate = 0U;
  packet.preparedValid = 0U;
  if (!IsSupportedSampleRate(static_cast<double>(sampleRate)) ||
      db_prepare_runtime_plan_v1(&packet.plan, static_cast<double>(sampleRate),
                                 &packet.prepared) != DB_STATUS_OK) {
    return false;
  }
  packet.preparedSampleRate = sampleRate;
  packet.preparedValid = 1U;
  return true;
}

bool Doppelbanger::PublishPendingState(const StatePacket& packet) noexcept {
  // This runs only on non-realtime host/UI paths. A consumer can be preempted
  // while it owns Reading, so allow enough bounded retries for it to release
  // the larger prepared-target packet without weakening mailbox ownership.
  constexpr std::uint32_t kUiPublishAttempts = 4096;
  for (std::uint32_t attempt = 0; attempt < kUiPublishAttempts; ++attempt) {
    if (mPendingState.TryPublish(packet, 1)) {
      return true;
    }
    std::this_thread::yield();
  }
  return false;
}

bool Doppelbanger::QueueStateFromUi(const db_runtime_plan_v1& plan,
                                    std::int32_t hostBypass) noexcept {
  if (!doppelbanger::state::IsValidPlanV1(plan) ||
      (hostBypass != 0 && hostBypass != 1)) {
    return false;
  }

  StatePacket pending{};
  pending.plan = plan;
  pending.hostBypass = hostBypass;
  pending.generation = mNextStateGeneration;
  const std::uint32_t sampleRate =
      mConfiguredSampleRate.load(std::memory_order_acquire);
  if (sampleRate != 0U && !PrepareStatePacket(pending, sampleRate)) {
    return false;
  }
  if (!PublishPendingState(pending)) {
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
  if (mProcessor == nullptr || pending.preparedValid != 1U ||
      pending.preparedSampleRate != mProcessorSampleRate ||
      pending.prepared.sample_rate_hz != mProcessorSampleRate ||
      db_processor_apply_prepared_v1(mProcessor, &pending.prepared) !=
          DB_STATUS_OK ||
      db_processor_reset(mProcessor) != DB_STATUS_OK) {
    return false;
  }

  mPlan = pending.plan;
  mPreparedTargets = pending.prepared;
  mPreparedSampleRate = pending.preparedSampleRate;
  mPreparedValid = pending.preparedValid;
  mParametersDirty = false;
  mAudioStateGeneration = pending.generation;
  SetBypassed(pending.hostBypass != 0);
  return true;
}

void Doppelbanger::PublishAudioState() noexcept {
  StatePacket state{};
  state.plan = mPlan;
  state.prepared = mPreparedTargets;
  state.preparedSampleRate = mPreparedSampleRate;
  state.preparedValid = mPreparedValid;
  state.hostBypass = GetBypassed() ? 1 : 0;
  state.generation = mAudioStateGeneration;
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
  mPreparedTargets = {};
  mPreparedSampleRate = 0U;
  mPreparedValid = 0U;
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
  const db_runtime_plan_v1 plan = SteppedPlanFromParameters();
  if (!doppelbanger::state::IsValidPlanV1(plan) || mProcessor == nullptr ||
      db_processor_apply_stepped_plan_v1(mProcessor, &plan) != DB_STATUS_OK) {
    return false;
  }
  mPlan = plan;
  mPreparedTargets = {};
  mPreparedSampleRate = 0U;
  mPreparedValid = 0U;
  mParametersDirty = false;
  return true;
}

void Doppelbanger::DestroyProcessor() noexcept {
  db_processor* processor = mProcessor;
  mProcessor = nullptr;
  mPreparedTargets = {};
  mPreparedSampleRate = 0U;
  mPreparedValid = 0U;
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
