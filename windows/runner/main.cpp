#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kAppWindowTitle[] = L"SFAIT Softphone";
constexpr wchar_t kRunnerWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kSingleInstanceMutexName[] =
    L"Local\\SFAITSoftphoneSingleInstance";

class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle) : handle_(handle) {}
  ~ScopedHandle() {
    if (handle_ != nullptr) {
      CloseHandle(handle_);
    }
  }

  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;

  HANDLE get() const { return handle_; }

 private:
  HANDLE handle_ = nullptr;
};

HWND FindExistingSoftphoneWindow() {
  for (int attempt = 0; attempt < 50; ++attempt) {
    HWND window = FindWindowW(kRunnerWindowClassName, kAppWindowTitle);
    if (window != nullptr) {
      return window;
    }
    Sleep(100);
  }
  return nullptr;
}

void PositionWindowBottomRight(HWND window) {
  RECT window_rect{};
  if (!GetWindowRect(window, &window_rect)) {
    return;
  }

  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  HMONITOR monitor = MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST);
  if (!GetMonitorInfoW(monitor, &monitor_info)) {
    return;
  }

  const int width = window_rect.right - window_rect.left;
  const int height = window_rect.bottom - window_rect.top;
  const int margin = 8;
  const int x = monitor_info.rcWork.right - width - margin;
  const int y = monitor_info.rcWork.bottom - height - margin;

  SetWindowPos(window, HWND_TOPMOST, x, y, width, height, SWP_SHOWWINDOW);
  SetWindowPos(window, HWND_NOTOPMOST, x, y, width, height, SWP_SHOWWINDOW);
}

void ShowExistingSoftphoneWindow() {
  HWND window = FindExistingSoftphoneWindow();
  if (window == nullptr) {
    return;
  }

  if (IsIconic(window)) {
    ShowWindow(window, SW_RESTORE);
  } else {
    ShowWindow(window, SW_SHOWNORMAL);
  }
  PositionWindowBottomRight(window);
  SetForegroundWindow(window);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  ScopedHandle single_instance_mutex(
      CreateMutexW(nullptr, TRUE, kSingleInstanceMutexName));
  if (single_instance_mutex.get() != nullptr &&
      GetLastError() == ERROR_ALREADY_EXISTS) {
    ShowExistingSoftphoneWindow();
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(430, 760);
  if (!window.Create(kAppWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
