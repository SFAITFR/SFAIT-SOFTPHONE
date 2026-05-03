#ifndef RUNNER_SFAIT_WINDOWS_INTEGRATION_H_
#define RUNNER_SFAIT_WINDOWS_INTEGRATION_H_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <flutter/binary_messenger.h>
#include <windows.h>

namespace sfait {

constexpr UINT kTrayIconMessage = WM_APP + 43;

void ConfigureWindowsIntegration(flutter::BinaryMessenger* messenger, HWND window);
void HandleTrayIconMessage(HWND window, WPARAM wparam, LPARAM lparam);
bool ShouldHideWindowOnClose();
void DestroyWindowsIntegration();

}  // namespace sfait

#endif  // RUNNER_SFAIT_WINDOWS_INTEGRATION_H_
