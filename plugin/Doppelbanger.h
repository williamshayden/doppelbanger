#pragma once

#include "IPlug_include_in_plug_hdr.h"
#include "StateCodec.h"

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

 private:
  [[nodiscard]] db_runtime_plan_v1 PlanFromParameters() const noexcept;
  [[nodiscard]] bool ReplaceProcessor(const db_runtime_plan_v1& plan) noexcept;
  [[nodiscard]] bool ApplyParameterPlan() noexcept;
  void DestroyProcessor() noexcept;
  static void Silence(iplug::sample** outputs, int nFrames) noexcept;
  static void SilenceProcessData(Steinberg::Vst::ProcessData& data) noexcept;

  db_processor* mProcessor = nullptr;
  db_runtime_plan_v1 mPlan{};
  std::uint32_t mProcessorSampleRate = 0;
  std::uint32_t mProcessorMaxBlockFrames = 0;
  bool mActive = false;
  bool mParametersDirty = false;
};
