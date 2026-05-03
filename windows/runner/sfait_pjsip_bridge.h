#ifndef RUNNER_SFAIT_PJSIP_BRIDGE_H_
#define RUNNER_SFAIT_PJSIP_BRIDGE_H_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <flutter/binary_messenger.h>
#include <windows.h>

namespace sfait {

constexpr UINT kNativeSoftphoneEventMessage = WM_APP + 42;

void ConfigurePjsipBridge(flutter::BinaryMessenger* messenger, HWND window);
void DrainPjsipBridgeEvents();
void ShutdownPjsipBridge();

}  // namespace sfait

#endif  // RUNNER_SFAIT_PJSIP_BRIDGE_H_
