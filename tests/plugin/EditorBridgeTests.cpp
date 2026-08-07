#include "EditorBridge.h"

#include <nlohmann/json.hpp>

#include <cmath>
#include <fstream>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace {

using doppelbanger::editor::Command;
using doppelbanger::editor::CommandType;
using doppelbanger::editor::EditorHost;
using doppelbanger::editor::EditorSession;
using doppelbanger::editor::ParseEditorCommand;
using doppelbanger::editor::ParseResult;
using doppelbanger::editor::kMaxMessageBytes;

int gFailures = 0;

void Expect(bool condition, const std::string& message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++gFailures;
  }
}

void ExpectError(const char* actual, const char* expected, const std::string& message) {
  Expect(actual != nullptr && std::string(actual) == expected, message);
}

void ExpectSuccess(const char* actual, const std::string& message) {
  Expect(actual == nullptr, message);
}

class FakeHost final : public EditorHost {
 public:
  bool BeginParameter(int parameterId) noexcept override {
    calls.push_back("begin:" + std::to_string(parameterId));
    return beginParameterResult;
  }

  bool SetParameter(int parameterId, double normalizedValue) noexcept override {
    std::ostringstream call;
    call << "set:" << parameterId << ':' << normalizedValue;
    calls.push_back(call.str());
    return setParameterResult;
  }

  bool EndParameter(int parameterId) noexcept override {
    calls.push_back("end:" + std::to_string(parameterId));
    return endParameterResult;
  }

  bool BeginBypass() noexcept override {
    calls.emplace_back("bypass-begin");
    return beginBypassResult;
  }

  bool SetBypass(bool bypassed) noexcept override {
    calls.emplace_back(bypassed ? "bypass-set:true" : "bypass-set:false");
    return setBypassResult;
  }

  bool EndBypass() noexcept override {
    calls.emplace_back("bypass-end");
    return endBypassResult;
  }

  bool SendSnapshot() noexcept override {
    calls.emplace_back("snapshot");
    return snapshotResult;
  }

  std::vector<std::string> calls;
  bool beginParameterResult = true;
  bool setParameterResult = true;
  bool endParameterResult = true;
  bool beginBypassResult = true;
  bool setBypassResult = true;
  bool endBypassResult = true;
  bool snapshotResult = true;
};

Command ParameterCommand(CommandType type, int parameterId = 0, double value = 0.5) {
  Command command{};
  command.type = type;
  command.parameterId = parameterId;
  command.normalizedValue = value;
  return command;
}

Command BypassCommand(CommandType type, bool bypassed = false) {
  Command command{};
  command.type = type;
  command.bypassed = bypassed;
  return command;
}

ParseResult Parsed(Command command) {
  return ParseResult{true, command, nullptr};
}

std::string ReadFixture() {
  std::ifstream input(EDITOR_BRIDGE_FIXTURE_PATH);
  std::stringstream buffer;
  buffer << input.rdbuf();
  return buffer.str();
}

const char* ExpectedFixtureParseError(const std::string& name) {
  if (name == "overlong") {
    return "DBUI_BRIDGE_TOO_LARGE";
  }
  if (name == "malformed-json" || name == "unknown-key") {
    return "DBUI_BRIDGE_MALFORMED";
  }
  if (name == "unsupported-version") {
    return "DBUI_BRIDGE_VERSION";
  }
  if (name == "unknown-type") {
    return "DBUI_BRIDGE_TYPE";
  }
  return "DBUI_BRIDGE_PAYLOAD";
}

bool IsOutboundFixtureType(const std::string& type) {
  return type == "state.snapshot" || type == "parameter.changed" ||
         type == "bypass.changed" || type == "compatibility.error";
}

Command CommandFromFixtureText(const std::string& text) {
  if (text.rfind("begin:", 0) == 0) {
    return ParameterCommand(CommandType::kParameterBeginEdit, std::stoi(text.substr(6)));
  }
  if (text.rfind("set:", 0) == 0) {
    const std::size_t separator = text.find(':', 4);
    return ParameterCommand(CommandType::kParameterSet, std::stoi(text.substr(4, separator - 4)),
                            std::stod(text.substr(separator + 1)));
  }
  if (text.rfind("end:", 0) == 0) {
    return ParameterCommand(CommandType::kParameterEndEdit, std::stoi(text.substr(4)));
  }
  return Command{};
}

void FixtureParseCasesUseTheDirectionSplit() {
  // The shared fixture is protocol-wide: native accepts only React-to-native commands.
  const nlohmann::json fixture = nlohmann::json::parse(ReadFixture());
  for (const auto& item : fixture.at("parse_cases")) {
    const std::string name = item.at("name").get<std::string>();
    const std::string text = item.at("json").get<std::string>();
    const ParseResult parsed = ParseEditorCommand(text);
    if (!item.at("ok").get<bool>()) {
      Expect(!parsed.ok, "fixture invalid case rejects: " + name);
      ExpectError(parsed.errorCode, ExpectedFixtureParseError(name),
                  "fixture invalid case has native error: " + name);
      continue;
    }

    const std::string type = nlohmann::json::parse(text).at("type").get<std::string>();
    if (IsOutboundFixtureType(type)) {
      Expect(!parsed.ok, "fixture outbound case rejects at native boundary: " + name);
      ExpectError(parsed.errorCode, "DBUI_BRIDGE_TYPE",
                  "fixture outbound case has direction error: " + name);
    } else {
      Expect(parsed.ok, "fixture inbound case parses: " + name);
    }
  }
}

void ParserHonorsExactByteAndSyntaxBoundaries() {
  const std::string envelope = "{\"version\":1,\"type\":\"ui.ready\",\"payload\":{}}";
  const std::string atLimit = envelope + std::string(kMaxMessageBytes - envelope.size(), ' ');
  const std::string overLimit = atLimit + ' ';
  Expect(atLimit.size() == kMaxMessageBytes, "test constructs a 4096-byte envelope");
  Expect(ParseEditorCommand(atLimit).ok, "a valid 4096-byte envelope parses");
  ExpectError(ParseEditorCommand(overLimit).errorCode, "DBUI_BRIDGE_TOO_LARGE",
              "a 4097-byte envelope is too large");

  std::string embeddedNul = envelope;
  embeddedNul.insert(4, 1, '\0');
  ExpectError(ParseEditorCommand(embeddedNul).errorCode, "DBUI_BRIDGE_MALFORMED",
              "embedded NUL is rejected before parsing");
  ExpectError(ParseEditorCommand("{\"version\":1,\"version\":1,\"type\":\"ui.ready\",\"payload\":{}}").errorCode,
              "DBUI_BRIDGE_MALFORMED", "duplicate envelope keys are rejected");
  ExpectError(ParseEditorCommand("{\"version\":1,\"type\":\"parameter.set\",\"payload\":{\"id\":0,\"id\":1,\"value\":0.5}}").errorCode,
              "DBUI_BRIDGE_MALFORMED", "duplicate payload keys are rejected");
}

void ParserClosesEnvelopeAndPayloadShapes() {
  ExpectError(ParseEditorCommand("[]").errorCode, "DBUI_BRIDGE_MALFORMED",
              "top-level arrays are malformed");
  Expect(ParseEditorCommand("{\"version\":1.0,\"type\":\"ui.ready\",\"payload\":{}}").ok,
         "numeric version one accepts the schema-equivalent representation");
  ExpectError(ParseEditorCommand("{\"version\":\"1\",\"type\":\"ui.ready\",\"payload\":{}}").errorCode,
              "DBUI_BRIDGE_VERSION", "version must equal numeric one");
  ExpectError(ParseEditorCommand("{\"version\":1,\"type\":true,\"payload\":{}}").errorCode,
              "DBUI_BRIDGE_TYPE", "type must be a string");
  ExpectError(ParseEditorCommand("{\"version\":1,\"type\":\"ui.ready\",\"payload\":[]}").errorCode,
              "DBUI_BRIDGE_PAYLOAD", "payload must be an object");
  ExpectError(ParseEditorCommand("{\"version\":1,\"type\":\"bypass.set\",\"payload\":{\"value\":1}}").errorCode,
              "DBUI_BRIDGE_PAYLOAD", "bypass payload requires a boolean");
}

void FixtureSessionCasesUseNativeGestureError() {
  // DBUI_GESTURE_ORDER is legacy fixture metadata; native canonicalizes it here.
  const nlohmann::json fixture = nlohmann::json::parse(ReadFixture());
  for (const auto& item : fixture.at("session_cases")) {
    FakeHost host;
    EditorSession session(host);
    const std::string name = item.at("name").get<std::string>();
    const auto& commands = item.at("commands");
    const char* result = nullptr;
    for (const auto& command : commands) {
      result = session.Dispatch(Parsed(CommandFromFixtureText(command.get<std::string>())));
      if (result != nullptr) {
        break;
      }
    }
    if (item.contains("error")) {
      ExpectError(result, "DBUI_GESTURE_STATE", "fixture session error normalizes: " + name);
    } else {
      ExpectSuccess(result, "fixture session succeeds: " + name);
      const auto expected = item.at("host_calls").get<std::vector<std::string>>();
      Expect(host.calls == expected, "fixture session host effects preserve order: " + name);
    }
  }
}

void RejectedCommandsNeverReachTheHost() {
  FakeHost host;
  EditorSession session(host);
  const ParseResult rejected{false, Command{}, "DBUI_BRIDGE_PAYLOAD"};
  ExpectError(session.Dispatch(rejected), "DBUI_BRIDGE_PAYLOAD", "parse error passes through");
  Expect(host.calls.empty(), "parse rejection invokes no host method");

  const Command invalidId = ParameterCommand(CommandType::kParameterBeginEdit, 4);
  ExpectError(session.Dispatch(Parsed(invalidId)), "DBUI_BRIDGE_PAYLOAD", "invalid programmatic id rejects");
  const Command nan = ParameterCommand(CommandType::kParameterSet, 0,
                                       std::numeric_limits<double>::quiet_NaN());
  ExpectError(session.Dispatch(Parsed(nan)), "DBUI_BRIDGE_PAYLOAD", "NaN programmatic value rejects");
  const Command infinity = ParameterCommand(CommandType::kParameterSet, 0,
                                            std::numeric_limits<double>::infinity());
  ExpectError(session.Dispatch(Parsed(infinity)), "DBUI_BRIDGE_PAYLOAD",
              "infinite programmatic value rejects");
  Expect(host.calls.empty(), "invalid programmatic commands invoke no host method");
}

void GestureTransitionsAndReadyAreBounded() {
  FakeHost host;
  EditorSession session(host);
  ExpectError(session.Dispatch(Parsed(ParameterCommand(CommandType::kParameterSet))), "DBUI_GESTURE_STATE",
              "parameter set before begin rejects");
  ExpectError(session.Dispatch(Parsed(ParameterCommand(CommandType::kParameterEndEdit))), "DBUI_GESTURE_STATE",
              "parameter end before begin rejects");
  ExpectSuccess(session.Dispatch(Parsed(ParameterCommand(CommandType::kParameterBeginEdit))),
                "parameter begin succeeds");
  ExpectError(session.Dispatch(Parsed(ParameterCommand(CommandType::kParameterBeginEdit))), "DBUI_GESTURE_STATE",
              "duplicate parameter begin rejects");
  ExpectError(session.Dispatch(Parsed(ParameterCommand(CommandType::kParameterBeginEdit, 1))), "DBUI_GESTURE_STATE",
              "different parameter begin while open rejects");
  ExpectSuccess(session.Dispatch(Parsed(BypassCommand(CommandType::kBypassBeginEdit))),
                "bypass begin remains separate from parameter gesture");
  ExpectSuccess(session.Dispatch(Parsed(Command{})), "ready is legal while gestures are open");
  ExpectSuccess(session.Dispatch(Parsed(BypassCommand(CommandType::kBypassSet, true))), "bypass set succeeds");
  ExpectSuccess(session.Dispatch(Parsed(BypassCommand(CommandType::kBypassEndEdit))), "bypass end succeeds");
  ExpectSuccess(session.Dispatch(Parsed(ParameterCommand(CommandType::kParameterSet))), "parameter set succeeds");
  ExpectSuccess(session.Dispatch(Parsed(ParameterCommand(CommandType::kParameterEndEdit))), "parameter end succeeds");
  ExpectError(session.Dispatch(Parsed(BypassCommand(CommandType::kBypassSet))), "DBUI_GESTURE_STATE",
              "bypass set after end rejects");
  const std::vector<std::string> expected{
      "begin:0", "bypass-begin", "snapshot", "bypass-set:true", "bypass-end", "set:0:0.5", "end:0"};
  Expect(host.calls == expected, "only accepted gesture actions reach host in order");
}

void HostFailuresPreserveGestureStateUntilSuccessfulClose() {
  FakeHost host;
  EditorSession session(host);
  host.beginParameterResult = false;
  ExpectError(session.Dispatch(Parsed(ParameterCommand(CommandType::kParameterBeginEdit))), "DBUI_GESTURE_STATE",
              "failed parameter begin reports gesture error");
  ExpectError(session.Dispatch(Parsed(ParameterCommand(CommandType::kParameterSet))), "DBUI_GESTURE_STATE",
              "failed begin leaves parameter closed");

  host.beginParameterResult = true;
  ExpectSuccess(session.Dispatch(Parsed(ParameterCommand(CommandType::kParameterBeginEdit, 2))),
                "parameter begin retries successfully");
  host.endParameterResult = false;
  ExpectError(session.Close(), "DBUI_GESTURE_STATE", "failed close reports gesture error");
  host.endParameterResult = true;
  ExpectSuccess(session.Close(), "successful close retries retained gesture");
  const std::size_t callsAfterClose = host.calls.size();
  ExpectSuccess(session.Close(), "successful close is idempotent");
  Expect(host.calls.size() == callsAfterClose, "idempotent close invokes no host method");
}

void CloseUnwindsParametersThenBypass() {
  FakeHost host;
  EditorSession session(host);
  ExpectSuccess(session.Dispatch(Parsed(ParameterCommand(CommandType::kParameterBeginEdit, 3))),
                "parameter three begins");
  ExpectSuccess(session.Dispatch(Parsed(BypassCommand(CommandType::kBypassBeginEdit))), "bypass begins");
  ExpectSuccess(session.Close(), "close ends every open gesture");
  const std::vector<std::string> expected{"begin:3", "bypass-begin", "end:3", "bypass-end"};
  Expect(host.calls == expected, "close orders parameter ends before bypass end");

  FakeHost failingHost;
  EditorSession failingSession(failingHost);
  ExpectSuccess(failingSession.Dispatch(Parsed(ParameterCommand(CommandType::kParameterBeginEdit, 0))),
                "failure fixture parameter begins");
  ExpectSuccess(failingSession.Dispatch(Parsed(BypassCommand(CommandType::kBypassBeginEdit))),
                "failure fixture bypass begins");
  failingHost.endParameterResult = false;
  ExpectError(failingSession.Close(), "DBUI_GESTURE_STATE", "failed parameter close is reported");
  const std::vector<std::string> failingExpected{"begin:0", "bypass-begin", "end:0", "bypass-end"};
  Expect(failingHost.calls == failingExpected, "close still attempts bypass after parameter failure");
}

}  // namespace

int main() {
  FixtureParseCasesUseTheDirectionSplit();
  ParserHonorsExactByteAndSyntaxBoundaries();
  ParserClosesEnvelopeAndPayloadShapes();
  FixtureSessionCasesUseNativeGestureError();
  RejectedCommandsNeverReachTheHost();
  GestureTransitionsAndReadyAreBounded();
  HostFailuresPreserveGestureStateUntilSuccessfulClose();
  CloseUnwindsParametersThenBypass();

  if (gFailures != 0) {
    std::cerr << gFailures << " EditorBridge test assertion(s) failed\n";
    return 1;
  }
  std::cout << "EditorBridgeTests: ok\n";
  return 0;
}
