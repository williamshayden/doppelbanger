#include "Doppelbanger.h"

#include "IPlugConstants.h"
#include "pluginterfaces/vst/ivstaudioprocessor.h"
#include "pluginterfaces/vst/vstspeaker.h"
#include "public.sdk/source/common/memorystream.h"
#include "public.sdk/source/vst/hosting/parameterchanges.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string_view>
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

class HostedInstance {
 public:
  HostedInstance() : plugin(iplug::InstanceInfo{}) {}

  ~HostedInstance() {
    if (active) {
      plugin.setActive(false);
    }
    if (initialized) {
      plugin.terminate();
    }
  }

  bool Initialize(int maxBlockFrames = 512) {
    initialized = plugin.initialize(nullptr) == kResultOk;
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
    return active;
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

  void Reset() {
    Expect(plugin.setProcessing(false) == kResultOk, "processing can stop for reset");
    Expect(plugin.setProcessing(true) == kResultOk, "processing can restart after reset");
  }

  Doppelbanger plugin;
  bool initialized = false;
  bool active = false;
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

  HostedInstance restored;
  Expect(restored.Initialize(512), "replacement component activates");
  Expect(RestoreState(restored.plugin, state), "replacement component restores state");
  Expect(restored.plugin.GetParam(kLowEqParam)->Value() == 2.0 &&
             restored.plugin.GetParam(kMidEqParam)->Value() == -1.5 &&
             restored.plugin.GetParam(kHighEqParam)->Value() == 0.75 &&
             restored.plugin.GetParam(kOutputParam)->Value() == 6.0,
         "restore reproduces every parameter value");

  original.Reset();
  restored.Reset();
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

  {
    HostedInstance noEditor;
    Expect(noEditor.Initialize(64), "destruction fixture activates");
    Expect(noEditor.plugin.createView("editor") == nullptr,
           "destruction fixture never creates an editor");
  }
}

}  // namespace

int main() {
  ComponentIdentityAndFormatContract();
  SilenceImpulseAutomationAndBypass();
  StateRecreateCorruptionResetAndDestruction();

  if (gFailures != 0) {
    std::cerr << gFailures << " PluginLifecycle test assertion(s) failed\n";
    return 1;
  }
  std::cout << "PluginLifecycleTests: ok\n";
  return 0;
}
