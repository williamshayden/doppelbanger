#include "Doppelbanger.h"
#include "EditorBridge.h"
#include "StateCodec.h"

#include <nlohmann/json.hpp>

#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <string>
#include <string_view>
#include <vector>

namespace {

using doppelbanger::editor::BuildCompatibilityErrorEnvelope;
using doppelbanger::editor::BuildJavaScriptDelivery;
using doppelbanger::editor::BuildParameterChangedEnvelope;
using doppelbanger::editor::BuildStateSnapshotEnvelope;
using doppelbanger::editor::EditorHost;
using doppelbanger::editor::EditorSession;
using doppelbanger::editor::EditorSnapshot;
using doppelbanger::editor::EditorSnapshotPublisher;
using doppelbanger::editor::ParseResult;
using doppelbanger::editor::PublicationKind;
using doppelbanger::editor::ResolveInstalledEditorResource;
using doppelbanger::editor::SnapshotParameter;
using doppelbanger::editor::kMaxMessageBytes;

using Json = nlohmann::json;

int gFailures = 0;

void Expect(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++gFailures;
  }
}

void ExpectSuccess(const char* value, const std::string& message) {
  Expect(value == nullptr, message);
}

bool IsAsciiControlled(std::string_view text) {
  for (const unsigned char character : text) {
    if (character < 0x20U || character > 0x7eU) {
      return false;
    }
  }
  return true;
}

EditorSnapshot ExampleSnapshot() {
  return EditorSnapshot{{{
      SnapshotParameter{0, 0.0, -3.0},
      SnapshotParameter{1, 0.5, 0.0},
      SnapshotParameter{2, 1.0, 3.0},
      SnapshotParameter{3, 0.25, -6.0},
  }}, true, true, 7U};
}

void ExactParameterAndSnapshotEnvelopeContract() {
  static_assert(kLowEqParam == 0);
  static_assert(kMidEqParam == 1);
  static_assert(kHighEqParam == 2);
  static_assert(kOutputParam == 3);
  static_assert(kNumParams == 4);

  Doppelbanger plugin(iplug::InstanceInfo{});
  const std::array<double, 4> minimum{-3.0, -3.0, -3.0, -12.0};
  const std::array<double, 4> maximum{3.0, 3.0, 3.0, 12.0};
  for (int parameterId = kLowEqParam; parameterId <= kOutputParam; ++parameterId) {
    const iplug::IParam* parameter = plugin.GetParam(parameterId);
    Expect(parameter != nullptr, "every snapshot parameter has an iPlug declaration");
    if (parameter != nullptr) {
      const std::size_t index = static_cast<std::size_t>(parameterId);
      Expect(parameter->GetMin() == minimum.at(index),
             "snapshot parameter preserves its exact display minimum");
      Expect(parameter->GetMax() == maximum.at(index),
             "snapshot parameter preserves its exact display maximum");
    }
  }

  const std::string envelope = BuildStateSnapshotEnvelope(ExampleSnapshot());
  Expect(!envelope.empty(), "a valid editor snapshot serializes");
  Expect(envelope.size() <= kMaxMessageBytes, "a snapshot stays within the bridge byte cap");
  Expect(IsAsciiControlled(envelope), "a snapshot contains only controlled ASCII");

  const Json message = Json::parse(envelope);
  Expect(message.at("version") == 1, "snapshot uses bridge version one");
  Expect(message.at("type") == "state.snapshot", "snapshot has the state message type");
  const Json& payload = message.at("payload");
  Expect(payload.size() == 5, "snapshot has exactly the version-one payload fields");
  Expect(payload.at("build") == PLUG_VERSION_STR, "snapshot carries the build version");
  Expect(payload.at("runtime_mode") == "LOCAL", "snapshot carries the local runtime mode");
  Expect(payload.at("dsp_ready") == true, "snapshot carries processor readiness");
  Expect(payload.at("bypass") == true, "snapshot carries authoritative bypass");

  const Json& parameters = payload.at("parameters");
  Expect(parameters.size() == 4, "snapshot has exactly four product parameters");
  const std::array<int, 4> ids{0, 1, 2, 3};
  const std::array<double, 4> normalized{0.0, 0.5, 1.0, 0.25};
  const std::array<double, 4> display{-3.0, 0.0, 3.0, -6.0};
  for (std::size_t index = 0; index < parameters.size(); ++index) {
    Expect(parameters.at(index).at("id") == ids.at(index), "snapshot preserves parameter IDs");
    Expect(parameters.at(index).at("normalized") == normalized.at(index),
           "snapshot preserves normalized parameter values");
    Expect(parameters.at(index).at("display") == display.at(index),
           "snapshot preserves signed centidecibel display values");
  }
}

void OutboundEnvelopesAreSchemaCompatibleAndQuotedForJavaScript() {
  const std::array<std::string, 3> envelopes{
      BuildParameterChangedEnvelope(SnapshotParameter{2, 0.294, -1.24}),
      doppelbanger::editor::BuildBypassChangedEnvelope(false),
      BuildCompatibilityErrorEnvelope("DBUI_BRIDGE_MALFORMED"),
  };
  const std::array<std::string, 3> types{
      "parameter.changed", "bypass.changed", "compatibility.error"};
  for (std::size_t index = 0; index < envelopes.size(); ++index) {
    const std::string& envelope = envelopes.at(index);
    Expect(!envelope.empty(), "each authoritative differential envelope serializes");
    Expect(envelope.size() <= kMaxMessageBytes, "each outbound envelope stays bounded");
    Expect(IsAsciiControlled(envelope), "each outbound envelope is controlled ASCII");
    const Json parsed = Json::parse(envelope);
    Expect(parsed.at("version") == 1, "differential envelope uses version one");
    Expect(parsed.at("type") == types.at(index), "differential envelope has the expected type");
  }

  const std::string parameter = envelopes.front();
  const std::string script = BuildJavaScriptDelivery(parameter);
  constexpr std::string_view prefix = "window.__doppelbangerReceive(";
  Expect(script.rfind(prefix, 0) == 0, "native delivery calls the dedicated receiver");
  Expect(script.size() > prefix.size() + 2U && script.back() == ';',
         "native delivery is a complete JavaScript statement");
  const std::string literal = script.substr(prefix.size(), script.size() - prefix.size() - 2U);
  const Json argument = Json::parse(literal);
  Expect(argument.is_string(), "native delivery passes a JSON string argument");
  Expect(argument.get<std::string>() == parameter, "native delivery preserves the envelope bytes");
  Expect(script.find("window.__doppelbangerReceive({") == std::string::npos,
         "native delivery never interpolates an executable JSON object");
}

void PublisherUsesSnapshotsForRecreationAndDifferentialsForChanges() {
  EditorSnapshotPublisher publisher;
  const EditorSnapshot snapshot = ExampleSnapshot();
  Expect(publisher.Publish(snapshot, false).kind == PublicationKind::kNone,
         "idle before ui.ready does not invent a snapshot");
  const auto initial = publisher.Publish(snapshot, true);
  Expect(initial.kind == PublicationKind::kSnapshot, "ui.ready produces a complete snapshot");
  Expect(initial.envelope == BuildStateSnapshotEnvelope(snapshot),
         "ui.ready snapshot has the authoritative envelope");
  const auto recreated = publisher.Publish(snapshot, true);
  Expect(recreated.kind == PublicationKind::kSnapshot,
         "editor recreation produces another complete snapshot");

  EditorSnapshot parameterChanged = snapshot;
  parameterChanged.parameters.at(1) = SnapshotParameter{1, 0.294, -1.24};
  const auto parameter = publisher.Publish(parameterChanged, false);
  Expect(parameter.kind == PublicationKind::kParameterChanged,
         "later parameter updates produce a differential envelope");
  Expect(Json::parse(parameter.envelope).at("payload").at("display") == -1.24,
         "parameter differentials retain two decimal display precision");

  EditorSnapshot bypassChanged = parameterChanged;
  bypassChanged.bypassed = false;
  const auto bypass = publisher.Publish(bypassChanged, false);
  Expect(bypass.kind == PublicationKind::kBypassChanged,
         "later bypass updates produce a differential envelope");
  Expect(publisher.Publish(bypassChanged, false).kind == PublicationKind::kNone,
         "unchanged authoritative state produces no duplicate delivery");
}

void ResourceResolutionAllowsOnlyTheInstalledIndex() {
  const std::string resources = "C:\\Program Files\\Doppelbanger.vst3\\Contents\\Resources";
  const auto valid = ResolveInstalledEditorResource(resources, "web/index.html");
  Expect(valid.has_value(), "the installed web index resolves from Contents Resources");
  if (valid.has_value()) {
    Expect(*valid == resources + "\\web\\index.html",
           "resource resolution yields only Contents Resources web index");
  }
  for (const std::string_view rejected : {
           "web/../secret.html", "../web/index.html", "web/index.htm", "web/app.js",
           "https://example.invalid/index.html", "web\\index.html"}) {
    Expect(!ResolveInstalledEditorResource(resources, rejected).has_value(),
           "resource resolver rejects traversal, outside, and wrong-file requests");
  }
  Expect(!ResolveInstalledEditorResource("C:\\Program Files\\Doppelbanger.vst3\\Resources",
                                         "web/index.html").has_value(),
         "resource resolver rejects a path outside the VST3 Contents Resources folder");
}

class FakeHost final : public EditorHost {
 public:
  bool BeginParameter(int id) noexcept override { calls.push_back("begin:" + std::to_string(id)); return begin; }
  bool SetParameter(int id, double value) noexcept override {
    calls.push_back("set:" + std::to_string(id) + ":" + std::to_string(value));
    return set;
  }
  bool EndParameter(int id) noexcept override { calls.push_back("end:" + std::to_string(id)); return end; }
  bool BeginBypass() noexcept override { calls.emplace_back("bypass-begin"); return beginBypass; }
  bool SetBypass(bool bypassed) noexcept override { calls.emplace_back(bypassed ? "bypass-set:true" : "bypass-set:false"); return setBypass; }
  bool EndBypass() noexcept override { calls.emplace_back("bypass-end"); return endBypass; }
  bool SendSnapshot() noexcept override { calls.emplace_back("snapshot"); return snapshot; }

  std::vector<std::string> calls;
  bool begin = true;
  bool set = true;
  bool end = true;
  bool beginBypass = true;
  bool setBypass = true;
  bool endBypass = true;
  bool snapshot = true;
};

ParseResult Parsed(doppelbanger::editor::Command command) {
  return ParseResult{true, command, nullptr};
}

void SessionPreservesHostOrderAndCloseCleanup() {
  FakeHost host;
  EditorSession session(host);
  doppelbanger::editor::Command ready{};
  ready.type = doppelbanger::editor::CommandType::kUiReady;
  ExpectSuccess(session.Dispatch(Parsed(ready)), "first ui.ready snapshots the editor");
  ExpectSuccess(session.Dispatch(Parsed(ready)), "recreated ui.ready snapshots again");

  doppelbanger::editor::Command begin{};
  begin.type = doppelbanger::editor::CommandType::kParameterBeginEdit;
  begin.parameterId = 3;
  doppelbanger::editor::Command set{};
  set.type = doppelbanger::editor::CommandType::kParameterSet;
  set.parameterId = 3;
  set.normalizedValue = 0.75;
  doppelbanger::editor::Command bypass{};
  bypass.type = doppelbanger::editor::CommandType::kBypassBeginEdit;
  ExpectSuccess(session.Dispatch(Parsed(begin)), "parameter gesture begins");
  ExpectSuccess(session.Dispatch(Parsed(set)), "parameter gesture performs edit");
  ExpectSuccess(session.Dispatch(Parsed(bypass)), "bypass gesture begins");
  ExpectSuccess(session.Close(), "close ends every open host gesture");
  const std::vector<std::string> expected{
      "snapshot", "snapshot", "begin:3", "set:3:0.750000", "bypass-begin", "end:3", "bypass-end"};
  Expect(host.calls == expected, "session preserves begin set end ordering and close cleanup");

  FakeHost failed;
  failed.begin = false;
  EditorSession failedSession(failed);
  Expect(std::string(failedSession.Dispatch(Parsed(begin))) == "DBUI_GESTURE_STATE",
         "failed host begin reports a compatibility-safe gesture error");
  Expect(std::string(failedSession.Dispatch(Parsed(set))) == "DBUI_GESTURE_STATE",
         "failed host begin does not falsely advance gesture state");
}

void StateCodecGoldenBytesRemainUnchanged() {
  const db_runtime_plan_v1 plan{
      sizeof(db_runtime_plan_v1), DB_ABI_VERSION, DB_PLAN_SCHEMA_VERSION,
      DB_PROCESSOR_VERSION, 0U, 0U, 1.0, {-3.0, 0.5, 3.0}};
  doppelbanger::state::EncodedStateV1 encoded{};
  Expect(doppelbanger::state::EncodeStateV1(plan, encoded) ==
             doppelbanger::state::StateCodecStatus::kOk,
         "golden state plan encodes");
  const std::array<std::uint8_t, 72> expected{
      0x44,0x42,0x53,0x54,0x01,0x00,0x00,0x00,0x38,0x00,0x00,0x00,
      0x38,0x00,0x00,0x00,0x01,0x00,0x00,0x00,0x01,0x00,0x00,0x00,
      0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
      0x00,0x00,0x00,0x00,0x00,0x00,0xF0,0x3F,0x00,0x00,0x00,0x00,
      0x00,0x00,0x08,0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0xE0,0x3F,
      0x00,0x00,0x00,0x00,0x00,0x00,0x08,0x40,0x3E,0x3C,0xB0,0xD9};
  Expect(encoded == expected, "editor work leaves version-one state bytes unchanged");
}

}  // namespace

int main() {
  ExactParameterAndSnapshotEnvelopeContract();
  OutboundEnvelopesAreSchemaCompatibleAndQuotedForJavaScript();
  PublisherUsesSnapshotsForRecreationAndDifferentialsForChanges();
  ResourceResolutionAllowsOnlyTheInstalledIndex();
  SessionPreservesHostOrderAndCloseCleanup();
  StateCodecGoldenBytesRemainUnchanged();

  if (gFailures != 0) {
    std::cerr << gFailures << " EditorSnapshot test assertion(s) failed\n";
    return 1;
  }
  std::cout << "EditorSnapshotTests: ok\n";
  return 0;
}
