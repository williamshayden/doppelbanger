#pragma once

#include "IPlug_include_in_plug_hdr.h"
#include "StateCodec.h"

#include <atomic>
#include <cstdint>

enum EParams {
  kLowEqParam = 0,
  kMidEqParam = 1,
  kHighEqParam = 2,
  kOutputParam = 3,
  kNumParams = 4,
};

inline constexpr int kNumPresets = 1;

class Doppelbanger final : public iplug::Plugin {
 public:
  explicit Doppelbanger(const iplug::InstanceInfo& info);
  ~Doppelbanger() override;

  bool SerializeState(iplug::IByteChunk& chunk) const override;
  int UnserializeState(const iplug::IByteChunk& chunk, int startPos) override;

  void OnActivate(bool active) override;
  void OnReset() override;
  void OnParamChange(int paramIdx) override;

  void ProcessBlock(iplug::sample** inputs, iplug::sample** outputs, int nFrames) override;

  Steinberg::tresult PLUGIN_API
  setupProcessing(Steinberg::Vst::ProcessSetup& setup) override;
  Steinberg::tresult PLUGIN_API canProcessSampleSize(Steinberg::int32 sampleSize) override;
  Steinberg::tresult PLUGIN_API process(Steinberg::Vst::ProcessData& data) override;
  Steinberg::tresult PLUGIN_API setState(Steinberg::IBStream* state) override;
  Steinberg::tresult PLUGIN_API getState(Steinberg::IBStream* state) override;

 private:
  struct StatePacket {
    db_runtime_plan_v1 plan{};
    db_prepared_runtime_targets_v1 prepared{};
    std::uint32_t preparedSampleRate = 0;
    std::uint32_t preparedValid = 0;
    std::int32_t hostBypass = 0;
    std::uint64_t generation = 0;
  };

  // The atomic state grants exclusive ownership of the plain fixed packet.
  // A producer may replace an unread Ready packet, but it can never write
  // while the consumer owns Reading (and vice versa).
  class StateMailbox {
   public:
    [[nodiscard]] bool TryPublish(const StatePacket& packet,
                                  std::uint32_t attempts) noexcept;
    [[nodiscard]] bool TryConsume(StatePacket& packet,
                                  std::uint32_t attempts) noexcept;

   private:
    enum State : std::uint32_t {
      kEmpty = 0,
      kWriting = 1,
      kReady = 2,
      kReading = 3,
    };

    static_assert(std::atomic<std::uint32_t>::is_always_lock_free);
    std::atomic<std::uint32_t> mState{kEmpty};
    StatePacket mPacket{};
  };

  [[nodiscard]] db_runtime_plan_v1 PlanFromParameters(
      const db_runtime_plan_v1& base) const noexcept;
  [[nodiscard]] StatePacket CurrentStateForUi() const;
  [[nodiscard]] bool PrepareStatePacket(StatePacket& packet,
                                        std::uint32_t sampleRate) const noexcept;
  [[nodiscard]] bool PublishPendingState(const StatePacket& packet) noexcept;
  [[nodiscard]] bool QueueStateFromUi(const db_runtime_plan_v1& plan,
                                      std::int32_t hostBypass) noexcept;
  [[nodiscard]] bool ApplyPendingState() noexcept;
  void PublishAudioState() noexcept;
  [[nodiscard]] bool ReplaceProcessor(const db_runtime_plan_v1& plan) noexcept;
  [[nodiscard]] bool ApplyParameterPlan() noexcept;
  void DestroyProcessor() noexcept;
  static void Silence(iplug::sample** outputs, int nFrames) noexcept;
  static void SilenceProcessData(Steinberg::Vst::ProcessData& data) noexcept;

  db_processor* mProcessor = nullptr;
  db_runtime_plan_v1 mPlan{};
  db_prepared_runtime_targets_v1 mPreparedTargets{};
  std::uint32_t mPreparedSampleRate = 0;
  std::uint32_t mPreparedValid = 0;
  std::uint32_t mProcessorSampleRate = 0;
  std::uint32_t mProcessorMaxBlockFrames = 0;
  bool mParametersDirty = false;
  // UI produces requests and audio consumes them. Audio produces snapshots
  // and UI consumes them. The remaining plain fields above are audio-owned
  // while processing; lifecycle callbacks access them only while processing
  // is stopped.
  StateMailbox mPendingState;
  mutable StateMailbox mPublishedState;
  mutable StatePacket mUiStateCache{};
  std::atomic<std::uint32_t> mConfiguredSampleRate{0};
  std::uint64_t mNextStateGeneration = 1;
  std::uint64_t mAudioStateGeneration = 0;
};
