#include "EditorBridge.h"

#include <nlohmann/json.hpp>

#include <cmath>
#include <cstdint>
#include <initializer_list>
#include <set>
#include <string>
#include <vector>

namespace doppelbanger::editor {
namespace {

using Json = nlohmann::json;

class DuplicateKeyDetector {
 public:
  bool operator()(int, Json::parse_event_t event, Json& parsed) {
    if (event == Json::parse_event_t::object_start) {
      objectKeys_.emplace_back();
    } else if (event == Json::parse_event_t::key) {
      if (objectKeys_.empty() ||
          !objectKeys_.back().insert(parsed.get<std::string>()).second) {
        hasDuplicate_ = true;
      }
    } else if (event == Json::parse_event_t::object_end && !objectKeys_.empty()) {
      objectKeys_.pop_back();
    }
    return true;
  }

  [[nodiscard]] bool hasDuplicate() const noexcept { return hasDuplicate_; }

 private:
  std::vector<std::set<std::string>> objectKeys_;
  bool hasDuplicate_ = false;
};

bool HasOnlyKeys(const Json& object, std::initializer_list<const char*> allowed) {
  if (!object.is_object()) {
    return false;
  }
  for (auto iterator = object.begin(); iterator != object.end(); ++iterator) {
    bool allowedKey = false;
    for (const char* key : allowed) {
      if (iterator.key() == key) {
        allowedKey = true;
        break;
      }
    }
    if (!allowedKey) {
      return false;
    }
  }
  return true;
}

bool HasExactKeys(const Json& object, std::initializer_list<const char*> required) {
  if (!HasOnlyKeys(object, required) || object.size() != required.size()) {
    return false;
  }
  for (const char* key : required) {
    if (!object.contains(key)) {
      return false;
    }
  }
  return true;
}

bool IsValidRequestId(const Json& requestId) {
  if (!requestId.is_string()) {
    return false;
  }
  const std::string value = requestId.get<std::string>();
  if (value.empty() || value.size() > 64) {
    return false;
  }
  for (const unsigned char character : value) {
    const bool alphaNumeric = (character >= 'A' && character <= 'Z') ||
                              (character >= 'a' && character <= 'z') ||
                              (character >= '0' && character <= '9');
    if (!alphaNumeric && character != '.' && character != '_' && character != '-') {
      return false;
    }
  }
  return true;
}

bool IsValidParameterId(const Json& value, int& parameterId) {
  if (value.is_number_integer()) {
    const std::int64_t candidate = value.get<std::int64_t>();
    if (candidate < 0 || candidate > 3) {
      return false;
    }
    parameterId = static_cast<int>(candidate);
    return true;
  }
  if (value.is_number_unsigned()) {
    const std::uint64_t candidate = value.get<std::uint64_t>();
    if (candidate > 3U) {
      return false;
    }
    parameterId = static_cast<int>(candidate);
    return true;
  }
  return false;
}

bool IsVersionOne(const Json& value) {
  if (value.is_number_integer()) {
    return value.get<std::int64_t>() == 1;
  }
  if (value.is_number_unsigned()) {
    return value.get<std::uint64_t>() == 1U;
  }
  if (value.is_number_float()) {
    const double version = value.get<double>();
    return std::isfinite(version) && version == 1.0;
  }
  return false;
}

bool IsValidNormalizedValue(const Json& value, double& normalizedValue) {
  if (!value.is_number()) {
    return false;
  }
  normalizedValue = value.get<double>();
  return std::isfinite(normalizedValue) && normalizedValue >= 0.0 &&
         normalizedValue <= 1.0;
}

bool IsValidParameterId(int parameterId) noexcept {
  return parameterId >= 0 && parameterId <= 3;
}

bool IsValidNormalizedValue(double normalizedValue) noexcept {
  return std::isfinite(normalizedValue) && normalizedValue >= 0.0 &&
         normalizedValue <= 1.0;
}

bool HasOpenParameterGesture(const bool (&gestures)[4]) noexcept {
  for (const bool open : gestures) {
    if (open) {
      return true;
    }
  }
  return false;
}

ParseResult Failure(const char* errorCode) noexcept {
  return ParseResult{false, Command{}, errorCode};
}

ParseResult Success(Command command) noexcept {
  return ParseResult{true, command, nullptr};
}

}  // namespace

ParseResult ParseEditorCommand(std::string_view json) noexcept {
  try {
    if (json.size() > kMaxMessageBytes) {
      return Failure(kBridgeTooLarge);
    }
    if (json.find('\0') != std::string_view::npos) {
      return Failure(kBridgeMalformed);
    }

    DuplicateKeyDetector duplicateKeyDetector;
    const Json envelope = Json::parse(std::string(json), std::ref(duplicateKeyDetector));
    if (duplicateKeyDetector.hasDuplicate() || !envelope.is_object() ||
        !HasOnlyKeys(envelope, {"version", "type", "request_id", "payload"}) ||
        !envelope.contains("version") || !envelope.contains("type") ||
        !envelope.contains("payload")) {
      return Failure(kBridgeMalformed);
    }
    if (envelope.contains("request_id") && !IsValidRequestId(envelope.at("request_id"))) {
      return Failure(kBridgeMalformed);
    }
    if (!IsVersionOne(envelope.at("version"))) {
      return Failure(kBridgeVersion);
    }
    if (!envelope.at("type").is_string()) {
      return Failure(kBridgeType);
    }
    if (!envelope.at("payload").is_object()) {
      return Failure(kBridgePayload);
    }

    const std::string type = envelope.at("type").get<std::string>();
    const Json& payload = envelope.at("payload");
    Command command{};
    if (type == "ui.ready") {
      if (!HasExactKeys(payload, {})) {
        return Failure(kBridgePayload);
      }
      return Success(command);
    }
    if (type == "parameter.begin_edit") {
      if (!HasExactKeys(payload, {"id"}) ||
          !IsValidParameterId(payload.at("id"), command.parameterId)) {
        return Failure(kBridgePayload);
      }
      command.type = CommandType::kParameterBeginEdit;
      return Success(command);
    }
    if (type == "parameter.set") {
      if (!HasExactKeys(payload, {"id", "value"}) ||
          !IsValidParameterId(payload.at("id"), command.parameterId) ||
          !IsValidNormalizedValue(payload.at("value"), command.normalizedValue)) {
        return Failure(kBridgePayload);
      }
      command.type = CommandType::kParameterSet;
      return Success(command);
    }
    if (type == "parameter.end_edit") {
      if (!HasExactKeys(payload, {"id"}) ||
          !IsValidParameterId(payload.at("id"), command.parameterId)) {
        return Failure(kBridgePayload);
      }
      command.type = CommandType::kParameterEndEdit;
      return Success(command);
    }
    if (type == "bypass.begin_edit") {
      if (!HasExactKeys(payload, {})) {
        return Failure(kBridgePayload);
      }
      command.type = CommandType::kBypassBeginEdit;
      return Success(command);
    }
    if (type == "bypass.set") {
      if (!HasExactKeys(payload, {"value"}) || !payload.at("value").is_boolean()) {
        return Failure(kBridgePayload);
      }
      command.type = CommandType::kBypassSet;
      command.bypassed = payload.at("value").get<bool>();
      return Success(command);
    }
    if (type == "bypass.end_edit") {
      if (!HasExactKeys(payload, {})) {
        return Failure(kBridgePayload);
      }
      command.type = CommandType::kBypassEndEdit;
      return Success(command);
    }
    return Failure(kBridgeType);
  } catch (...) {
    return Failure(kBridgeMalformed);
  }
}

EditorSession::EditorSession(EditorHost& host) noexcept : host_(host) {}

const char* EditorSession::Dispatch(const ParseResult& parsed) noexcept {
  if (!parsed.ok) {
    return parsed.errorCode != nullptr ? parsed.errorCode : kBridgeMalformed;
  }

  const Command& command = parsed.command;
  switch (command.type) {
    case CommandType::kUiReady:
      return host_.SendSnapshot() ? nullptr : kGestureState;
    case CommandType::kParameterBeginEdit:
      if (!IsValidParameterId(command.parameterId)) {
        return kBridgePayload;
      }
      if (HasOpenParameterGesture(parameterGestures_)) {
        return kGestureState;
      }
      if (!host_.BeginParameter(command.parameterId)) {
        return kGestureState;
      }
      parameterGestures_[command.parameterId] = true;
      return nullptr;
    case CommandType::kParameterSet:
      if (!IsValidParameterId(command.parameterId) ||
          !IsValidNormalizedValue(command.normalizedValue)) {
        return kBridgePayload;
      }
      if (!parameterGestures_[command.parameterId]) {
        return kGestureState;
      }
      return host_.SetParameter(command.parameterId, command.normalizedValue) ? nullptr
                                                                               : kGestureState;
    case CommandType::kParameterEndEdit:
      if (!IsValidParameterId(command.parameterId)) {
        return kBridgePayload;
      }
      if (!parameterGestures_[command.parameterId]) {
        return kGestureState;
      }
      if (!host_.EndParameter(command.parameterId)) {
        return kGestureState;
      }
      parameterGestures_[command.parameterId] = false;
      return nullptr;
    case CommandType::kBypassBeginEdit:
      if (bypassGestureOpen_ || !host_.BeginBypass()) {
        return kGestureState;
      }
      bypassGestureOpen_ = true;
      return nullptr;
    case CommandType::kBypassSet:
      if (!bypassGestureOpen_) {
        return kGestureState;
      }
      return host_.SetBypass(command.bypassed) ? nullptr : kGestureState;
    case CommandType::kBypassEndEdit:
      if (!bypassGestureOpen_) {
        return kGestureState;
      }
      if (!host_.EndBypass()) {
        return kGestureState;
      }
      bypassGestureOpen_ = false;
      return nullptr;
  }
  return kBridgePayload;
}

const char* EditorSession::Close() noexcept {
  bool failed = false;
  for (int parameterId = 0; parameterId < 4; ++parameterId) {
    if (parameterGestures_[parameterId]) {
      if (host_.EndParameter(parameterId)) {
        parameterGestures_[parameterId] = false;
      } else {
        failed = true;
      }
    }
  }
  if (bypassGestureOpen_) {
    if (host_.EndBypass()) {
      bypassGestureOpen_ = false;
    } else {
      failed = true;
    }
  }
  return failed ? kGestureState : nullptr;
}

}  // namespace doppelbanger::editor
