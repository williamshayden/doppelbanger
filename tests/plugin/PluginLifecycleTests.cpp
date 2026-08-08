#include "Doppelbanger.h"

#include "IPlugConstants.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <thread>
#include <vector>

namespace {

using Steinberg::MemoryStream;
using Steinberg::kResultFalse;
using Steinberg::kResultOk;
using Steinberg::kResultTrue;
using Steinberg::Vst::AudioBusBuffers;
using Steinberg::Vst::BusDirections;
using Steinberg::Vst::MediaTypes;
using Steinberg::Vst::ParameterChanges;
using Steinberg::Vst::ProcessData;
using Steinberg::Vst::ProcessSetup;
using Steinberg::Vst::Sample32;
using Steinberg::Vst::Sample64;
using Steinberg::Vst::SpeakerArrangement;
using Steinberg::Vst::SpeakerArr::kMono;
using Steinberg::Vst::SpeakerArr::kStereo;
using Steinberg::Vst::kRealtime;
using Steinberg::Vst::kSample32;
using Steinberg::Vst::kSample64;

int gFailures = 0;

void Expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++gFailures;
  }
}

bool Near(float actual, float expected, float tolerance = 1.0e-6F) {
  return std::abs(actual - expected) <= tolerance;
}

bool NearDouble(double actual, double expected, double tolerance = 1.0e-12) {
  return std::abs(actual - expected) <= tolerance;
}

bool IsSilent(const std::vector<Sample32>& samples) {
  return std::all_of(samples.begin(), samples.end(),
                     [](Sample32 sample) { return sample == 0.0F; });
}

struct AudioBlock {
  explicit AudioBlock(int frames)
      : inputLeft(static_cast<std::size_t>(frames)),
        inputRight(static_cast<std::size_t>(frames)),
        outputLeft(static_cast<std::size_t>(frames), 99.0F),
        outputRight(static_cast<std::size_t>(frames), 99.0F) {
    inputChannels = {inputLeft.data(), inputRight.data()};
    outputChannels = {outputLeft.data(), outputRight.data()};
    input.numChannels = 2;
    input.silenceFlags = 0;
    input.channelBuffers32 = inputChannels.data();
    output.numChannels = 2;
    output.silenceFlags = 0;
    output.channelBuffers32 = outputChannels.data();
  }

  std::vector<Sample32> inputLeft;
  std::vector<Sample32> inputRight;
  std::vector<Sample32> outputLeft;
  std::vector<Sample32> outputRight;
  std::array<Sample32*, 2> inputChannels{};
  std::array<Sample32*, 2> outputChannels{};
  AudioBusBuffers input{};
  AudioBusBuffers output{};
};

struct AudioBlock64 {
  explicit AudioBlock64(int frames)
      : inputLeft(static_cast<std::size_t>(frames) + 2U, 0.0),
        inputRight(static_cast<std::size_t>(frames) + 2U, 0.0),
        outputLeft(static_cast<std::size_t>(frames) + 2U, 99.0),
        outputRight(static_cast<std::size_t>(frames) + 2U, 99.0) {
    inputLeft.front() = inputRight.front() = kFrontGuard;
    inputLeft.back() = inputRight.back() = kBackGuard;
    outputLeft.front() = outputRight.front() = kFrontGuard;
    outputLeft.back() = outputRight.back() = kBackGuard;
    inputChannels = {inputLeft.data() + 1, inputRight.data() + 1};
    outputChannels = {outputLeft.data() + 1, outputRight.data() + 1};
    input.numChannels = 2;
    input.silenceFlags = 0;
    input.channelBuffers64 = inputChannels.data();
    output.numChannels = 2;
    output.silenceFlags = 0;
    output.channelBuffers64 = outputChannels.data();
  }

  [[nodiscard]] bool OutputIsSilent(int frames) const {
    return std::all_of(outputLeft.begin() + 1, outputLeft.begin() + 1 + frames,
                       [](Sample64 sample) { return sample == 0.0; }) &&
           std::all_of(outputRight.begin() + 1, outputRight.begin() + 1 + frames,
                       [](Sample64 sample) { return sample == 0.0; });
  }

  [[nodiscard]] bool GuardsAreIntact() const {
    return outputLeft.front() == kFrontGuard && outputRight.front() == kFrontGuard &&
           outputLeft.back() == kBackGuard && outputRight.back() == kBackGuard;
  }

  static constexpr Sample64 kFrontGuard = 12'345.0;
  static constexpr Sample64 kBackGuard = -54'321.0;
  std::vector<Sample64> inputLeft;
  std::vector<Sample64> inputRight;
  std::vector<Sample64> outputLeft;
  std::vector<Sample64> outputRight;
  std::array<Sample64*, 2> inputChannels{};
  std::array<Sample64*, 2> outputChannels{};
  AudioBusBuffers input{};
  AudioBusBuffers output{};
};

class ControlledWriteStream final : public MemoryStream {
 public:
  enum class Behavior {
    kShortWrite,
    kFailure,
    kThrow,
  };

  explicit ControlledWriteStream(Behavior behavior) : behavior(behavior) {}

  Steinberg::tresult PLUGIN_API write(void* buffer,
                                      Steinberg::int32 numBytes,
                                      Steinberg::int32* numBytesWritten) override {
    if (behavior == Behavior::kThrow) {
      throw std::runtime_error("simulated stream exception");
    }
    if (behavior == Behavior::kFailure) {
      if (numBytesWritten != nullptr) {
        *numBytesWritten = 0;
      }
      return kResultFalse;
    }

    const Steinberg::int32 shortCount = std::max<Steinberg::int32>(0, numBytes - 1);
    return MemoryStream::write(buffer, shortCount, numBytesWritten);
  }

 private:
  Behavior behavior;
};

class ControlledReadStream final : public MemoryStream {
 public:
  enum class Behavior {
    kFailureWithFullFinalChunk,
    kFailureAfterPartialChunk,
    kCountLargerThanRequested,
    kTrailingProbeFailure,
    kTrailingProbeOverReport,
    kValidShortReads,
  };

  ControlledReadStream(std::vector<char>& bytes, Behavior behavior)
      : MemoryStream(bytes.data(), static_cast<Steinberg::TSize>(bytes.size())),
        behavior(behavior) {}

  Steinberg::tresult PLUGIN_API read(void* buffer,
                                     Steinberg::int32 numBytes,
                                     Steinberg::int32* numBytesRead) override {
    if (numBytesRead == nullptr || numBytes < 0) {
      return kResultFalse;
    }

    if (behavior == Behavior::kFailureAfterPartialChunk) {
      if (readCalls++ == 0) {
        return MemoryStream::read(buffer, std::min<Steinberg::int32>(13, numBytes),
                                  numBytesRead);
      }
      *numBytesRead = 0;
      return kResultFalse;
    }

    if (cursor >= size) {
      if (behavior == Behavior::kTrailingProbeFailure) {
        *numBytesRead = 0;
        return kResultFalse;
      }
      if (behavior == Behavior::kTrailingProbeOverReport) {
        *numBytesRead = numBytes + 1;
        return kResultTrue;
      }
      *numBytesRead = 0;
      return kResultTrue;
    }

    if (behavior == Behavior::kFailureWithFullFinalChunk) {
      static_cast<void>(MemoryStream::read(buffer, numBytes, numBytesRead));
      return kResultFalse;
    }
    if (behavior == Behavior::kCountLargerThanRequested) {
      static_cast<void>(MemoryStream::read(buffer, numBytes, numBytesRead));
      *numBytesRead = numBytes + 1;
      return kResultTrue;
    }
    if (behavior == Behavior::kValidShortReads) {
      return MemoryStream::read(buffer, std::min<Steinberg::int32>(7, numBytes),
                                numBytesRead);
    }
    return MemoryStream::read(buffer, numBytes, numBytesRead);
  }

 private:
  Behavior behavior;
  int readCalls = 0;
};

class HostedInstance {
 public:
  HostedInstance() : plugin(iplug::InstanceInfo{}) {}

  ~HostedInstance() {
    if (processing) {
      Expect(plugin.setProcessing(false) == kResultOk,
             "fixture stops VST3 processing before deactivation");
      processing = false;
    }
    if (active) {
      plugin.setActive(false);
    }
    if (initialized) {
      plugin.terminate();
    }
  }

  bool InitializeComponent() {
    if (initialized) {
      return true;
    }
    initialized = plugin.initialize(nullptr) == kResultOk;
    return initialized;
  }

  bool ConfigureAndActivate(int maxBlockFrames = 512) {
    if (!initialized) {
      return false;
    }
    SpeakerArrangement inputs[]{kStereo};
    SpeakerArrangement outputs[]{kStereo};
    if (plugin.setBusArrangements(inputs, 1, outputs, 1) != kResultTrue) {
      return false;
    }
    ProcessSetup setup{kRealtime, kSample32, maxBlockFrames, 48'000.0};
    if (plugin.setupProcessing(setup) != kResultOk) {
      return false;
    }
    plugin.activateBus(MediaTypes::kAudio, BusDirections::kInput, 0, true);
    plugin.activateBus(MediaTypes::kAudio, BusDirections::kOutput, 0, true);
    active = plugin.setActive(true) == kResultOk;
    if (!active) {
      return false;
    }
    processing = plugin.setProcessing(true) == kResultOk;
    return processing;
  }

  bool Initialize(int maxBlockFrames = 512) {
    return InitializeComponent() && ConfigureAndActivate(maxBlockFrames);
  }

  Steinberg::tresult Process(AudioBlock& block,
                             ParameterChanges* changes = nullptr,
                             int frames = -1,
                             Steinberg::int32 sampleSize = kSample32) {
    if (frames < 0) {
      frames = static_cast<int>(block.inputLeft.size());
    }
    ProcessData data{};
    data.processMode = kRealtime;
    data.symbolicSampleSize = sampleSize;
    data.numSamples = frames;
    data.numInputs = 1;
    data.numOutputs = 1;
    data.inputs = &block.input;
    data.outputs = &block.output;
    data.inputParameterChanges = changes;
    return plugin.process(data);
  }

  Steinberg::tresult Flush(ParameterChanges& changes) {
    ProcessData data{};
    data.processMode = kRealtime;
    data.symbolicSampleSize = kSample32;
    data.numSamples = 0;
    data.inputParameterChanges = &changes;
    return plugin.process(data);
  }

  Steinberg::tresult Process64(AudioBlock64& block, int frames) {
    ProcessData data{};
    data.processMode = kRealtime;
    data.symbolicSampleSize = kSample64;
    data.numSamples = frames;
    data.numInputs = 1;
    data.numOutputs = 1;
    data.inputs = &block.input;
    data.outputs = &block.output;
    return plugin.process(data);
  }

  void Reset() {
    Expect(processing, "processing is active before reset");
    Expect(plugin.setProcessing(false) == kResultOk, "processing can stop for reset");
    processing = false;
    processing = plugin.setProcessing(true) == kResultOk;
    Expect(processing, "processing can restart after reset");
  }

  Doppelbanger plugin;
  bool initialized = false;
  bool active = false;
  bool processing = false;
};

void AddAutomationPoint(ParameterChanges& changes,
                        Steinberg::Vst::ParamID parameter,
                        double normalized) {
  Steinberg::int32 queueIndex = 0;
  auto* queue = changes.addParameterData(parameter, queueIndex);
  Expect(queue != nullptr, "host automation queue is available");
  if (queue != nullptr) {
    Steinberg::int32 pointIndex = 0;
    Expect(queue->addPoint(0, normalized, pointIndex) == kResultTrue,
           "host automation point is accepted");
  }
}

void ComponentIdentityAndFormatContract() {
  static_assert(kLowEqParam == 0);
  static_assert(kMidEqParam == 1);
  static_assert(kHighEqParam == 2);
  static_assert(kOutputParam == 3);
  static_assert(iplug::kBypassParam == 65'536);

  HostedInstance hosted;
  Expect(hosted.plugin.initialize(nullptr) == kResultOk, "component initializes");
  hosted.initialized = true;
  Expect(hosted.plugin.NParams() == 4, "component exposes exactly four product parameters");
  Expect(std::string_view(hosted.plugin.GetParam(kLowEqParam)->GetName()) == "Low EQ",
         "Low EQ has its stable label");
  Expect(std::string_view(hosted.plugin.GetParam(kMidEqParam)->GetName()) == "Mid EQ",
         "Mid EQ has its stable label");
  Expect(std::string_view(hosted.plugin.GetParam(kHighEqParam)->GetName()) == "High EQ",
         "High EQ has its stable label");
  Expect(std::string_view(hosted.plugin.GetParam(kOutputParam)->GetName()) == "Output",
         "Output has its stable label");
  for (int parameter = kLowEqParam; parameter <= kOutputParam; ++parameter) {
    Expect(hosted.plugin.GetParam(parameter)->GetStepped(),
           "every product parameter constrains host values to its advertised step");
    Expect(hosted.plugin.GetParam(parameter)->GetStep() == 0.01,
           "every product parameter retains the 0.01 dB step");
  }

  Expect(hosted.plugin.getBusCount(MediaTypes::kAudio, BusDirections::kInput) == 1,
         "component exposes one audio input bus");
  Expect(hosted.plugin.getBusCount(MediaTypes::kAudio, BusDirections::kOutput) == 1,
         "component exposes one audio output bus");
  Expect(hosted.plugin.getBusCount(MediaTypes::kEvent, BusDirections::kInput) == 0,
         "component exposes no MIDI input bus");
  Expect(hosted.plugin.getBusCount(MediaTypes::kEvent, BusDirections::kOutput) == 0,
         "component exposes no MIDI output bus");

  SpeakerArrangement stereoInputs[]{kStereo};
  SpeakerArrangement stereoOutputs[]{kStereo};
  Expect(hosted.plugin.setBusArrangements(stereoInputs, 1, stereoOutputs, 1) == kResultTrue,
         "one stereo input/output arrangement is accepted");
  SpeakerArrangement monoInputs[]{kMono};
  SpeakerArrangement monoOutputs[]{kMono};
  Expect(hosted.plugin.setBusArrangements(monoInputs, 1, monoOutputs, 1) == kResultFalse,
         "non-stereo arrangement is rejected");

  Expect(hosted.plugin.canProcessSampleSize(kSample32) == kResultTrue,
         "32-bit samples are supported");
  Expect(hosted.plugin.canProcessSampleSize(kSample64) == kResultFalse,
         "64-bit samples are rejected");
  ProcessSetup unsupported{kRealtime, kSample64, 64, 48'000.0};
  Expect(hosted.plugin.setupProcessing(unsupported) == kResultFalse,
         "64-bit processing setup is rejected");
  ProcessSetup oversized{kRealtime, kSample32,
                         static_cast<Steinberg::int32>(DB_MAX_BLOCK_FRAMES + 1U), 48'000.0};
  Expect(hosted.plugin.setupProcessing(oversized) == kResultFalse,
         "oversized processing setup is rejected");
  Expect(hosted.plugin.createView("editor") == nullptr, "headless component has no editor");
}

void ProcessorReadinessTracksLifecycleWithoutCreatingAnEditor() {
  Doppelbanger unconfigured(iplug::InstanceInfo{});
  Expect(!unconfigured.IsProcessorReadyForEditor(),
         "an unconfigured component reports an unavailable processor");
  unconfigured.OnActivate(true);
  Expect(unconfigured.IsProcessorReadyForEditor(),
         "processor creation publishes readiness without constructing an editor");
  unconfigured.OnActivate(false);
  Expect(!unconfigured.IsProcessorReadyForEditor(),
         "processor destruction clears readiness without constructing an editor");

  HostedInstance hosted;
  Expect(hosted.Initialize(64), "processor readiness fixture initializes");
  Expect(hosted.plugin.IsProcessorReadyForEditor(),
         "successful processor creation publishes readiness atomically");
  ProcessSetup rejected{kRealtime, kSample32, 64, 12'345.0};
  Expect(hosted.plugin.setupProcessing(rejected) == kResultFalse,
         "an unsupported processing configuration is rejected");
  Expect(hosted.plugin.IsProcessorReadyForEditor(),
         "a rejected reconfiguration leaves the existing processor readiness truthful");
  Expect(hosted.plugin.setProcessing(false) == kResultOk,
         "processor readiness fixture stops processing");
  hosted.processing = false;
  Expect(hosted.plugin.setActive(false) == kResultOk,
         "processor readiness fixture deactivates");
  hosted.active = false;
  Expect(!hosted.plugin.IsProcessorReadyForEditor(),
         "processor destruction clears readiness atomically");
}

void HostAutomationIsCentidecibelStepped() {
  HostedInstance hosted;
  Expect(hosted.Initialize(64), "stepped-automation component activates and processes");

  ParameterChanges automation(4);
  AddAutomationPoint(automation, kLowEqParam, (0.1234 + 3.0) / 6.0);
  AddAutomationPoint(automation, kMidEqParam, (-1.234 + 3.0) / 6.0);
  AddAutomationPoint(automation, kHighEqParam, (2.999 + 3.0) / 6.0);
  AddAutomationPoint(automation, kOutputParam, (6.789 + 12.0) / 24.0);
  AudioBlock block(64);
  block.inputLeft.assign(block.inputLeft.size(), 0.125F);
  block.inputRight.assign(block.inputRight.size(), -0.125F);
  Expect(hosted.Process(block, &automation) == kResultOk,
         "arbitrary normalized host automation processes");
  Expect(NearDouble(hosted.plugin.GetParam(kLowEqParam)->Value(), 0.12),
         "Low EQ automation is quantized before OnParamChange");
  Expect(NearDouble(hosted.plugin.GetParam(kMidEqParam)->Value(), -1.23),
         "Mid EQ automation is quantized before OnParamChange");
  Expect(NearDouble(hosted.plugin.GetParam(kHighEqParam)->Value(), 3.0),
         "High EQ automation is quantized before OnParamChange");
  Expect(NearDouble(hosted.plugin.GetParam(kOutputParam)->Value(), 6.79),
         "Output automation is quantized before OnParamChange");
}

void SilenceImpulseAutomationAndBypass() {
  HostedInstance hosted;
  Expect(hosted.Initialize(512), "hosted component activates");
  Expect(hosted.plugin.getLatencySamples() == 0U, "host reports Rust processor latency");

  ParameterChanges flush(1);
  AddAutomationPoint(flush, kLowEqParam, 2.0 / 3.0);  // +1 dB
  Expect(hosted.Flush(flush) == kResultOk,
         "zero-frame automation flush accepts absent audio buffers");
  Expect(hosted.plugin.GetParam(kLowEqParam)->Value() == 1.0,
         "zero-frame automation updates the next block target");

  AudioBlock silence(64);
  Expect(hosted.Process(silence) == kResultOk, "silence block processes");
  Expect(std::all_of(silence.outputLeft.begin(), silence.outputLeft.end(),
                     [](float sample) { return sample == 0.0F; }) &&
             std::all_of(silence.outputRight.begin(), silence.outputRight.end(),
                         [](float sample) { return sample == 0.0F; }),
         "silence stays silent");

  AudioBlock impulse(512);
  impulse.inputLeft[0] = 1.0F;
  impulse.inputRight[0] = -0.5F;
  Expect(hosted.Process(impulse) == kResultOk, "impulse block processes");
  Expect(std::all_of(impulse.outputLeft.begin(), impulse.outputLeft.end(),
                     [](float sample) { return std::isfinite(sample); }) &&
             std::all_of(impulse.outputRight.begin(), impulse.outputRight.end(),
                         [](float sample) { return std::isfinite(sample); }),
         "impulse output remains finite");

  ParameterChanges automation(4);
  AddAutomationPoint(automation, kLowEqParam, 5.0 / 6.0);   // +2 dB
  AddAutomationPoint(automation, kMidEqParam, 0.25);         // -1.5 dB
  AddAutomationPoint(automation, kHighEqParam, 0.625);       // +0.75 dB
  AddAutomationPoint(automation, kOutputParam, 0.75);        // +6 dB
  AudioBlock automated(512);
  automated.inputLeft.assign(automated.inputLeft.size(), 0.1F);
  automated.inputRight.assign(automated.inputRight.size(), -0.1F);
  Expect(hosted.Process(automated, &automation) == kResultOk,
         "all product parameter automation processes");
  Expect(hosted.plugin.GetParam(kLowEqParam)->Value() == 2.0,
         "Low EQ automation reaches +2 dB");
  Expect(hosted.plugin.GetParam(kMidEqParam)->Value() == -1.5,
         "Mid EQ automation reaches -1.5 dB");
  Expect(hosted.plugin.GetParam(kHighEqParam)->Value() == 0.75,
         "High EQ automation reaches +0.75 dB");
  Expect(hosted.plugin.GetParam(kOutputParam)->Value() == 6.0,
         "Output automation reaches +6 dB");
  Expect(!Near(automated.outputLeft.back(), automated.inputLeft.back(), 1.0e-3F),
         "automated plan changes output after the bounded ramp");

  ParameterChanges bypassOn(1);
  AddAutomationPoint(bypassOn, iplug::kBypassParam, 1.0);
  AudioBlock bypassed(32);
  bypassed.inputLeft[0] = 0.75F;
  bypassed.inputRight[0] = -0.25F;
  Expect(hosted.Process(bypassed, &bypassOn) == kResultOk, "host bypass automation processes");
  Expect(hosted.plugin.GetBypassed(), "host bypass automation updates component state");
  Expect(bypassed.outputLeft == bypassed.inputLeft && bypassed.outputRight == bypassed.inputRight,
         "host bypass is sample exact");

  ParameterChanges bypassOff(1);
  AddAutomationPoint(bypassOff, iplug::kBypassParam, 0.0);
  AudioBlock resumed(32);
  resumed.inputLeft.assign(resumed.inputLeft.size(), 0.1F);
  resumed.inputRight.assign(resumed.inputRight.size(), -0.1F);
  Expect(hosted.Process(resumed, &bypassOff) == kResultOk,
         "host bypass can be automated off");
  Expect(!hosted.plugin.GetBypassed(), "host bypass state clears");
}

std::vector<char> SaveState(Doppelbanger& plugin) {
  MemoryStream stream;
  Expect(plugin.getState(&stream) == kResultOk, "component state saves");
  return std::vector<char>(stream.getData(), stream.getData() + stream.getSize());
}

bool RestoreState(Doppelbanger& plugin, std::vector<char>& bytes) {
  MemoryStream stream(bytes.data(), static_cast<Steinberg::TSize>(bytes.size()));
  return plugin.setState(&stream) == kResultOk;
}

db_runtime_plan_v1 RuntimePlan(double output = 0.0,
                               std::array<double, 3> eq = {0.0, 0.0, 0.0}) {
  return db_runtime_plan_v1{
      sizeof(db_runtime_plan_v1), DB_ABI_VERSION, DB_PLAN_SCHEMA_VERSION,
      DB_PROCESSOR_VERSION,       0U,             0U,
      output,                     {eq[0], eq[1], eq[2]},
  };
}

std::vector<char> EncodeVst3State(const db_runtime_plan_v1& plan,
                                  std::int32_t hostBypass = 0) {
  doppelbanger::state::EncodedStateV1 encoded{};
  Expect(doppelbanger::state::EncodeStateV1(plan, encoded) ==
             doppelbanger::state::StateCodecStatus::kOk,
         "test fixture plan encodes");
  std::vector<char> bytes(encoded.begin(), encoded.end());
  const auto* bypassBytes = reinterpret_cast<const char*>(&hostBypass);
  bytes.insert(bytes.end(), bypassBytes, bypassBytes + sizeof(hostBypass));
  return bytes;
}

bool DecodeVst3Plan(const std::vector<char>& bytes, db_runtime_plan_v1& plan) {
  return bytes.size() ==
             doppelbanger::state::kEncodedStateV1Size + sizeof(std::int32_t) &&
         doppelbanger::state::DecodeStateV1(
             reinterpret_cast<const std::uint8_t*>(bytes.data()),
             doppelbanger::state::kEncodedStateV1Size, plan) ==
             doppelbanger::state::StateCodecStatus::kOk;
}

bool SamePlan(const db_runtime_plan_v1& left, const db_runtime_plan_v1& right) {
  return left.struct_size == right.struct_size && left.abi_version == right.abi_version &&
         left.plan_schema_version == right.plan_schema_version &&
         left.processor_version == right.processor_version && left.bypass == right.bypass &&
         left.reserved == right.reserved && left.applied_gain_db == right.applied_gain_db &&
         left.eq_gains_db[0] == right.eq_gains_db[0] &&
         left.eq_gains_db[1] == right.eq_gains_db[1] &&
         left.eq_gains_db[2] == right.eq_gains_db[2];
}

bool HasValidFixedState(const std::vector<char>& bytes) {
  constexpr std::size_t kVst3StateSize =
      doppelbanger::state::kEncodedStateV1Size + sizeof(std::int32_t);
  if (bytes.size() != kVst3StateSize) {
    return false;
  }

  db_runtime_plan_v1 decoded{};
  if (doppelbanger::state::DecodeStateV1(
          reinterpret_cast<const std::uint8_t*>(bytes.data()),
          doppelbanger::state::kEncodedStateV1Size, decoded) !=
      doppelbanger::state::StateCodecStatus::kOk) {
    return false;
  }

  std::int32_t bypass = -1;
  std::memcpy(&bypass, bytes.data() + doppelbanger::state::kEncodedStateV1Size,
              sizeof(bypass));
  return bypass == 0 || bypass == 1;
}

void SettlePlanAndReset(HostedInstance& hosted) {
  AudioBlock settling(512);
  Expect(hosted.Process(settling) == kResultOk, "restored plan settles for one bounded block");
  hosted.Reset();
}

void StateWriteFailuresAreContained() {
  HostedInstance hosted;
  Expect(hosted.Initialize(64), "state-write fixture activates");
  Expect(hosted.plugin.getState(nullptr) == kResultFalse,
         "null state output stream is rejected");

  for (const auto behavior : {ControlledWriteStream::Behavior::kShortWrite,
                              ControlledWriteStream::Behavior::kFailure}) {
    ControlledWriteStream stream(behavior);
    Expect(hosted.plugin.getState(&stream) == kResultFalse,
           "short or failed state writes propagate failure");
  }

  ControlledWriteStream throwing(ControlledWriteStream::Behavior::kThrow);
  bool escaped = false;
  Steinberg::tresult result = kResultTrue;
  try {
    result = hosted.plugin.getState(&throwing);
  } catch (...) {
    escaped = true;
  }
  Expect(!escaped, "state stream exceptions cannot cross the host boundary");
  Expect(result == kResultFalse, "state stream exceptions report failure");
}

void StateReadFailuresAreContainedAndAtomic() {
  const db_runtime_plan_v1 requestedPlan = RuntimePlan(6.0, {2.0, -1.5, 0.75});
  std::vector<char> requestedState = EncodeVst3State(requestedPlan);

  for (const auto behavior : {
           ControlledReadStream::Behavior::kFailureWithFullFinalChunk,
           ControlledReadStream::Behavior::kFailureAfterPartialChunk,
           ControlledReadStream::Behavior::kCountLargerThanRequested,
           ControlledReadStream::Behavior::kTrailingProbeFailure,
           ControlledReadStream::Behavior::kTrailingProbeOverReport,
       }) {
    HostedInstance hosted;
    Expect(hosted.Initialize(64), "state-read rejection fixture activates and processes");
    const std::array<double, 4> before{
        hosted.plugin.GetParam(kLowEqParam)->Value(),
        hosted.plugin.GetParam(kMidEqParam)->Value(),
        hosted.plugin.GetParam(kHighEqParam)->Value(),
        hosted.plugin.GetParam(kOutputParam)->Value(),
    };
    ControlledReadStream stream(requestedState, behavior);
    Expect(hosted.plugin.setState(&stream) == kResultFalse,
           "failed or over-reported state reads are rejected");
    Expect(hosted.plugin.GetParam(kLowEqParam)->Value() == before[0] &&
               hosted.plugin.GetParam(kMidEqParam)->Value() == before[1] &&
               hosted.plugin.GetParam(kHighEqParam)->Value() == before[2] &&
               hosted.plugin.GetParam(kOutputParam)->Value() == before[3],
           "failed or over-reported state reads cannot mutate parameters");
  }

  HostedInstance valid;
  Expect(valid.Initialize(64), "short-read success fixture activates and processes");
  ControlledReadStream shortReads(requestedState,
                                  ControlledReadStream::Behavior::kValidShortReads);
  Expect(valid.plugin.setState(&shortReads) == kResultOk,
         "successful short reads totaling exactly 76 bytes restore state");
  Expect(valid.plugin.GetParam(kLowEqParam)->Value() == 2.0 &&
             valid.plugin.GetParam(kMidEqParam)->Value() == -1.5 &&
             valid.plugin.GetParam(kHighEqParam)->Value() == 0.75 &&
             valid.plugin.GetParam(kOutputParam)->Value() == 6.0,
         "successful short reads restore every parameter");
}

void ExactArbitraryStateSurvivesPreActivationAndProcessingHandoffs() {
  const db_runtime_plan_v1 beforeActivation =
      RuntimePlan(1.234, {0.123, -2.345, 2.999});
  std::vector<char> beforeActivationBytes = EncodeVst3State(beforeActivation);

  HostedInstance hosted;
  Expect(hosted.InitializeComponent(), "pre-activation restore component initializes");
  Expect(RestoreState(hosted.plugin, beforeActivationBytes),
         "state restore succeeds before sample-rate configuration and activation");
  Expect(hosted.ConfigureAndActivate(512),
         "pre-activation restored component configures, activates, and enters processing");
  AudioBlock firstBlock(512);
  firstBlock.inputLeft.assign(firstBlock.inputLeft.size(), 0.125F);
  firstBlock.inputRight.assign(firstBlock.inputRight.size(), -0.125F);
  Expect(hosted.Process(firstBlock) == kResultOk,
         "pre-activation arbitrary state applies at the first block boundary");
  db_runtime_plan_v1 firstSaved{};
  Expect(DecodeVst3Plan(SaveState(hosted.plugin), firstSaved) &&
             SamePlan(firstSaved, beforeActivation),
         "pre-activation arbitrary state remains exact after processing");

  const db_runtime_plan_v1 whileProcessing =
      RuntimePlan(-3.217, {-2.221, 1.111, -0.333});
  std::vector<char> whileProcessingBytes = EncodeVst3State(whileProcessing);
  Expect(RestoreState(hosted.plugin, whileProcessingBytes),
         "arbitrary state restore succeeds while VST3 processing is active");
  AudioBlock secondBlock(512);
  secondBlock.inputLeft.assign(secondBlock.inputLeft.size(), 0.125F);
  secondBlock.inputRight.assign(secondBlock.inputRight.size(), -0.125F);
  Expect(hosted.Process(secondBlock) == kResultOk,
         "arbitrary processing-state handoff applies at a block boundary");
  db_runtime_plan_v1 secondSaved{};
  Expect(DecodeVst3Plan(SaveState(hosted.plugin), secondSaved) &&
             SamePlan(secondSaved, whileProcessing),
         "processing-time arbitrary state remains exact instead of quantizing to the host grid");
}

void NoOpHostParameterFlushPreservesExactArbitraryState() {
  const db_runtime_plan_v1 arbitraryPlan =
      RuntimePlan(-3.217, {-2.221, 1.111, -0.333});
  std::vector<char> arbitraryState = EncodeVst3State(arbitraryPlan);

  HostedInstance hosted;
  Expect(hosted.Initialize(64), "no-op parameter flush fixture activates and processes");
  Expect(RestoreState(hosted.plugin, arbitraryState),
         "no-op parameter flush fixture restores arbitrary state");
  AudioBlock restoredBlock(64);
  restoredBlock.inputLeft.assign(restoredBlock.inputLeft.size(), 0.125F);
  restoredBlock.inputRight.assign(restoredBlock.inputRight.size(), -0.125F);
  Expect(hosted.Process(restoredBlock) == kResultOk,
         "arbitrary state reaches the audio processor before the no-op flush");

  const std::vector<char> beforeFlush = SaveState(hosted.plugin);
  db_runtime_plan_v1 beforeFlushPlan{};
  Expect(beforeFlush == arbitraryState && DecodeVst3Plan(beforeFlush, beforeFlushPlan) &&
             SamePlan(beforeFlushPlan, arbitraryPlan),
         "arbitrary state is byte and value exact before the no-op flush");

  ParameterChanges noOpFlush(1);
  AddAutomationPoint(noOpFlush, kLowEqParam,
                     hosted.plugin.GetParam(kLowEqParam)->GetNormalized());
  AudioBlock noOpBlock(64);
  noOpBlock.inputLeft.assign(noOpBlock.inputLeft.size(), 0.125F);
  noOpBlock.inputRight.assign(noOpBlock.inputRight.size(), -0.125F);
  Expect(hosted.Process(noOpBlock, &noOpFlush) == kResultOk,
         "no-op host parameter flush processes");

  const std::vector<char> afterNoOp = SaveState(hosted.plugin);
  db_runtime_plan_v1 afterNoOpPlan{};
  Expect(afterNoOp == beforeFlush && DecodeVst3Plan(afterNoOp, afterNoOpPlan) &&
             SamePlan(afterNoOpPlan, arbitraryPlan),
         "no-op host parameter flush preserves the exact arbitrary plan");

  ParameterChanges realChange(1);
  AddAutomationPoint(realChange, kLowEqParam, 5.0 / 6.0);
  AudioBlock changedBlock(64);
  changedBlock.inputLeft.assign(changedBlock.inputLeft.size(), 0.125F);
  changedBlock.inputRight.assign(changedBlock.inputRight.size(), -0.125F);
  Expect(hosted.Process(changedBlock, &realChange) == kResultOk,
         "genuine host parameter change processes");

  const db_runtime_plan_v1 expectedStepped =
      RuntimePlan(-3.22, {2.0, 1.11, -0.33});
  db_runtime_plan_v1 afterChangePlan{};
  Expect(DecodeVst3Plan(SaveState(hosted.plugin), afterChangePlan) &&
             SamePlan(afterChangePlan, expectedStepped),
         "genuine host parameter change applies the complete stepped plan");
}

void StateRecreateCorruptionResetAndDestruction() {
  HostedInstance original;
  Expect(original.Initialize(512), "original component activates");

  ParameterChanges automation(4);
  AddAutomationPoint(automation, kLowEqParam, 5.0 / 6.0);
  AddAutomationPoint(automation, kMidEqParam, 0.25);
  AddAutomationPoint(automation, kHighEqParam, 0.625);
  AddAutomationPoint(automation, kOutputParam, 0.75);
  AudioBlock ramp(512);
  ramp.inputLeft.assign(ramp.inputLeft.size(), 0.1F);
  ramp.inputRight.assign(ramp.inputRight.size(), -0.1F);
  Expect(original.Process(ramp, &automation) == kResultOk, "original reaches saved plan");

  std::vector<char> state = SaveState(original.plugin);
  Expect(state.size() == doppelbanger::state::kEncodedStateV1Size + sizeof(std::int32_t),
         "VST3 state contains fixed codec bytes and iPlug2 host bypass");
  Expect(HasValidFixedState(state), "saved VST3 state has valid fixed framing");

  HostedInstance restored;
  Expect(restored.Initialize(512), "replacement component activates");
  Expect(RestoreState(restored.plugin, state), "replacement component restores state");
  Expect(restored.plugin.GetParam(kLowEqParam)->Value() == 2.0 &&
             restored.plugin.GetParam(kMidEqParam)->Value() == -1.5 &&
             restored.plugin.GetParam(kHighEqParam)->Value() == 0.75 &&
             restored.plugin.GetParam(kOutputParam)->Value() == 6.0,
         "restore reproduces every parameter value");

  SettlePlanAndReset(original);
  SettlePlanAndReset(restored);
  AudioBlock originalImpulse(512);
  AudioBlock restoredImpulse(512);
  originalImpulse.inputLeft[0] = restoredImpulse.inputLeft[0] = 0.75F;
  originalImpulse.inputRight[0] = restoredImpulse.inputRight[0] = -0.25F;
  Expect(original.Process(originalImpulse) == kResultOk, "original comparison block processes");
  Expect(restored.Process(restoredImpulse) == kResultOk, "restored comparison block processes");
  Expect(originalImpulse.outputLeft == restoredImpulse.outputLeft &&
             originalImpulse.outputRight == restoredImpulse.outputRight,
         "new instance plus restore reproduces output exactly");

  std::vector<char> corrupt = state;
  corrupt[doppelbanger::state::kEncodedStateV1Size - 1] ^= 0x40;
  const double before = restored.plugin.GetParam(kOutputParam)->Value();
  Expect(!RestoreState(restored.plugin, corrupt), "corrupt state is rejected");
  Expect(restored.plugin.GetParam(kOutputParam)->Value() == before,
         "corrupt state cannot mutate parameters");

  restored.Reset();
  AudioBlock afterReset(512);
  afterReset.inputLeft[0] = 0.75F;
  afterReset.inputRight[0] = -0.25F;
  Expect(restored.Process(afterReset) == kResultOk, "reset component processes again");
  Expect(afterReset.outputLeft == restoredImpulse.outputLeft &&
             afterReset.outputRight == restoredImpulse.outputRight,
         "reset clears filter history without changing the plan");

  HostedInstance bounded;
  Expect(bounded.Initialize(64), "small-block component activates");
  AudioBlock tooLarge(65);
  Expect(bounded.Process(tooLarge) == kResultFalse, "oversized process block is rejected");
  Expect(IsSilent(tooLarge.outputLeft) && IsSilent(tooLarge.outputRight),
         "rejected bounded process output is silenced");
  Expect(tooLarge.output.silenceFlags == 0x3ULL,
         "rejected stereo output reports both channels silent");

  AudioBlock64 tooLarge64(65);
  Expect(bounded.Process64(tooLarge64, 65) == kResultFalse,
         "oversized 64-bit process block is rejected");
  Expect(tooLarge64.OutputIsSilent(65),
         "rejected bounded 64-bit process output is silenced");
  Expect(tooLarge64.output.silenceFlags == 0x3ULL,
         "rejected 64-bit stereo output reports both channels silent");
  Expect(tooLarge64.GuardsAreIntact(),
         "rejected 64-bit output clearing stays inside valid buffers");

  {
    HostedInstance noEditor;
    Expect(noEditor.Initialize(64), "destruction fixture activates");
    Expect(noEditor.plugin.createView("editor") == nullptr,
           "destruction fixture never creates an editor");
  }
}

void BypassAndMalformedVst3StateAreHandledAtomically() {
  HostedInstance source;
  Expect(source.Initialize(64), "bypass state source activates");

  ParameterChanges bypassOn(1);
  AddAutomationPoint(bypassOn, iplug::kBypassParam, 1.0);
  AudioBlock bypassSource(32);
  bypassSource.inputLeft[0] = 0.625F;
  bypassSource.inputRight[0] = -0.375F;
  Expect(source.Process(bypassSource, &bypassOn) == kResultOk,
         "bypass state source processes");

  std::vector<char> bypassState = SaveState(source.plugin);
  Expect(HasValidFixedState(bypassState), "bypass-on state keeps fixed framing");
  std::int32_t savedBypass = 0;
  std::memcpy(&savedBypass,
              bypassState.data() + doppelbanger::state::kEncodedStateV1Size,
              sizeof(savedBypass));
  Expect(savedBypass == 1, "bypass-on state records the host bypass value");

  HostedInstance restored;
  Expect(restored.Initialize(64), "bypass state replacement activates");
  Expect(RestoreState(restored.plugin, bypassState), "bypass-on state restores");
  AudioBlock bypassed(32);
  bypassed.inputLeft[0] = 0.625F;
  bypassed.inputRight[0] = -0.375F;
  Expect(restored.Process(bypassed) == kResultOk, "restored bypass state processes");
  Expect(restored.plugin.GetBypassed(), "restored host bypass is active");
  Expect(bypassed.outputLeft == bypassed.inputLeft &&
             bypassed.outputRight == bypassed.inputRight,
         "restored host bypass remains sample exact");

  std::vector<std::vector<char>> malformed;
  malformed.push_back(bypassState);
  const std::int32_t invalidBypass = 2;
  std::memcpy(malformed.back().data() + doppelbanger::state::kEncodedStateV1Size,
              &invalidBypass, sizeof(invalidBypass));
  malformed.push_back(bypassState);
  malformed.back().pop_back();
  malformed.push_back(bypassState);
  malformed.back().push_back(static_cast<char>(0x5A));

  const double outputBefore = restored.plugin.GetParam(kOutputParam)->Value();
  const bool bypassBefore = restored.plugin.GetBypassed();
  for (auto& bytes : malformed) {
    Expect(!RestoreState(restored.plugin, bytes),
           "invalid bypass, truncation, and trailing bytes are rejected");
    Expect(restored.plugin.GetParam(kOutputParam)->Value() == outputBefore,
           "malformed VST3 state cannot mutate product parameters");
    Expect(restored.plugin.GetBypassed() == bypassBefore,
           "malformed VST3 state cannot mutate host bypass");
  }
}

void ConcurrentStateAndProcessingRemainSafe() {
  HostedInstance defaultSource;
  Expect(defaultSource.Initialize(512), "default concurrent-state source activates");
  std::vector<char> defaultState = SaveState(defaultSource.plugin);

  HostedInstance shapedSource;
  Expect(shapedSource.Initialize(512), "shaped concurrent-state source activates");
  ParameterChanges automation(4);
  AddAutomationPoint(automation, kLowEqParam, 5.0 / 6.0);
  AddAutomationPoint(automation, kMidEqParam, 0.25);
  AddAutomationPoint(automation, kHighEqParam, 0.625);
  AddAutomationPoint(automation, kOutputParam, 0.75);
  AudioBlock shapedRamp(512);
  shapedRamp.inputLeft.assign(shapedRamp.inputLeft.size(), 0.1F);
  shapedRamp.inputRight.assign(shapedRamp.inputRight.size(), -0.1F);
  Expect(shapedSource.Process(shapedRamp, &automation) == kResultOk,
         "shaped concurrent-state source reaches its plan");
  std::vector<char> shapedState = SaveState(shapedSource.plugin);

  HostedInstance hosted;
  Expect(hosted.Initialize(512), "concurrent state/process component activates");
  std::atomic<bool> start{false};
  std::atomic<bool> audioOk{true};
  std::atomic<bool> uiOk{true};

  std::thread audio([&]() {
    AudioBlock block(32);
    block.inputLeft.assign(block.inputLeft.size(), 0.125F);
    block.inputRight.assign(block.inputRight.size(), -0.125F);
    while (!start.load(std::memory_order_acquire)) {
      std::this_thread::yield();
    }
    for (int iteration = 0; iteration < 10'000; ++iteration) {
      std::fill(block.outputLeft.begin(), block.outputLeft.end(), 99.0F);
      std::fill(block.outputRight.begin(), block.outputRight.end(), 99.0F);
      if (hosted.Process(block) != kResultOk ||
          !std::all_of(block.outputLeft.begin(), block.outputLeft.end(),
                       [](float sample) { return std::isfinite(sample); }) ||
          !std::all_of(block.outputRight.begin(), block.outputRight.end(),
                       [](float sample) { return std::isfinite(sample); })) {
        audioOk.store(false, std::memory_order_release);
        return;
      }
      if ((iteration & 31) == 0) {
        std::this_thread::yield();
      }
    }
  });

  start.store(true, std::memory_order_release);
  for (int iteration = 0; iteration < 1'000; ++iteration) {
    std::vector<char> requested = (iteration & 1) == 0 ? defaultState : shapedState;
    if (!RestoreState(hosted.plugin, requested)) {
      uiOk.store(false, std::memory_order_release);
      break;
    }

    MemoryStream stream;
    if (hosted.plugin.getState(&stream) != kResultOk) {
      uiOk.store(false, std::memory_order_release);
      break;
    }
    const std::vector<char> saved(stream.getData(), stream.getData() + stream.getSize());
    if (!HasValidFixedState(saved)) {
      uiOk.store(false, std::memory_order_release);
      break;
    }
    if ((iteration & 15) == 0) {
      std::this_thread::yield();
    }
  }
  audio.join();

  Expect(audioOk.load(std::memory_order_acquire),
         "concurrent state calls cannot corrupt finite audio processing");
  Expect(uiOk.load(std::memory_order_acquire),
         "concurrent state calls retain valid fixed state framing");

  std::vector<char> finalState = shapedState;
  Expect(RestoreState(hosted.plugin, finalState), "final concurrent state restores");
  SettlePlanAndReset(hosted);

  HostedInstance reference;
  Expect(reference.Initialize(512), "final-state reference activates");
  Expect(RestoreState(reference.plugin, finalState), "final-state reference restores");
  SettlePlanAndReset(reference);

  AudioBlock actual(512);
  AudioBlock expected(512);
  actual.inputLeft[0] = expected.inputLeft[0] = 0.75F;
  actual.inputRight[0] = expected.inputRight[0] = -0.25F;
  Expect(hosted.Process(actual) == kResultOk, "final concurrent state processes");
  Expect(reference.Process(expected) == kResultOk, "final-state reference processes");
  Expect(actual.outputLeft == expected.outputLeft && actual.outputRight == expected.outputRight,
         "final concurrent restore is deterministic after quiescence");
}

}  // namespace

int main() {
  ComponentIdentityAndFormatContract();
  ProcessorReadinessTracksLifecycleWithoutCreatingAnEditor();
  HostAutomationIsCentidecibelStepped();
  SilenceImpulseAutomationAndBypass();
  StateWriteFailuresAreContained();
  StateReadFailuresAreContainedAndAtomic();
  ExactArbitraryStateSurvivesPreActivationAndProcessingHandoffs();
  NoOpHostParameterFlushPreservesExactArbitraryState();
  StateRecreateCorruptionResetAndDestruction();
  BypassAndMalformedVst3StateAreHandledAtomically();
  ConcurrentStateAndProcessingRemainSafe();

  if (gFailures != 0) {
    std::cerr << gFailures << " PluginLifecycle test assertion(s) failed\n";
    return 1;
  }
  std::cout << "PluginLifecycleTests: ok\n";
  return 0;
}
