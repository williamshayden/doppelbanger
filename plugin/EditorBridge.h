#pragma once

#include <cstddef>
#include <string_view>

namespace doppelbanger::editor {

inline constexpr std::size_t kMaxMessageBytes = 4096;

inline constexpr const char kBridgeTooLarge[] = "DBUI_BRIDGE_TOO_LARGE";
inline constexpr const char kBridgeMalformed[] = "DBUI_BRIDGE_MALFORMED";
inline constexpr const char kBridgeVersion[] = "DBUI_BRIDGE_VERSION";
inline constexpr const char kBridgeType[] = "DBUI_BRIDGE_TYPE";
inline constexpr const char kBridgePayload[] = "DBUI_BRIDGE_PAYLOAD";
inline constexpr const char kGestureState[] = "DBUI_GESTURE_STATE";

enum class CommandType {
  kUiReady,
  kParameterBeginEdit,
  kParameterSet,
  kParameterEndEdit,
  kBypassBeginEdit,
  kBypassSet,
  kBypassEndEdit,
};

struct Command {
  CommandType type = CommandType::kUiReady;
  int parameterId = -1;
  double normalizedValue = 0.0;
  bool bypassed = false;
};

struct ParseResult {
  bool ok = false;
  Command command{};
  const char* errorCode = "DBUI_BRIDGE_MALFORMED";
};

[[nodiscard]] ParseResult ParseEditorCommand(std::string_view json) noexcept;

class EditorHost {
 public:
  virtual ~EditorHost() = default;
  virtual bool BeginParameter(int parameterId) noexcept = 0;
  virtual bool SetParameter(int parameterId, double normalizedValue) noexcept = 0;
  virtual bool EndParameter(int parameterId) noexcept = 0;
  virtual bool BeginBypass() noexcept = 0;
  virtual bool SetBypass(bool bypassed) noexcept = 0;
  virtual bool EndBypass() noexcept = 0;
  virtual bool SendSnapshot() noexcept = 0;
};

class EditorSession {
 public:
  explicit EditorSession(EditorHost& host) noexcept;
  [[nodiscard]] const char* Dispatch(const ParseResult& parsed) noexcept;
  [[nodiscard]] const char* Close() noexcept;

 private:
  EditorHost& host_;
  bool parameterGestures_[4]{};
  bool bypassGestureOpen_ = false;
};

}  // namespace doppelbanger::editor
