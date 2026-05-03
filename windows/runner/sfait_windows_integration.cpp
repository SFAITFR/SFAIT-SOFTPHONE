#include "sfait_windows_integration.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmsystem.h>
#include <shlobj.h>
#include <shellapi.h>

#include <algorithm>
#include <cmath>
#include <commdlg.h>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#include "resource.h"

namespace sfait {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodChannel;
using flutter::MethodResult;

constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"SFAIT Softphone";
constexpr wchar_t kRingtoneAlias[] = L"sfait_ringtone";
constexpr UINT kTrayIconId = 1001;

HWND g_window = nullptr;
std::unique_ptr<MethodChannel<EncodableValue>> g_launch_channel;
std::unique_ptr<MethodChannel<EncodableValue>> g_system_channel;
std::unique_ptr<MethodChannel<EncodableValue>> g_ringtone_channel;
bool g_tray_visible = false;
double g_ringtone_volume = 1.0;
HICON g_tray_icon = nullptr;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return L"";
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
  std::wstring result(size > 0 ? size - 1 : 0, L'\0');
  if (size > 1) MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), size);
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return "";
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
  std::string result(size > 0 ? size - 1 : 0, '\0');
  if (size > 1) WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), size, nullptr, nullptr);
  return result;
}

std::wstring ArgWide(const EncodableMap& arguments, const char* key) {
  const auto iterator = arguments.find(EncodableValue(key));
  if (iterator == arguments.end() || !std::holds_alternative<std::string>(iterator->second)) {
    return L"";
  }
  return Utf8ToWide(std::get<std::string>(iterator->second));
}

double ArgDouble(const EncodableMap& arguments, const char* key, double fallback) {
  const auto iterator = arguments.find(EncodableValue(key));
  if (iterator == arguments.end()) return fallback;
  if (std::holds_alternative<double>(iterator->second)) return std::get<double>(iterator->second);
  if (std::holds_alternative<int>(iterator->second)) return static_cast<double>(std::get<int>(iterator->second));
  return fallback;
}

int WaveOutDeviceId(const std::wstring& device_id) {
  const std::wstring prefix = L"waveout:";
  if (device_id.rfind(prefix, 0) != 0) return -1;
  try {
    return std::stoi(device_id.substr(prefix.size()));
  } catch (...) {
    return -1;
  }
}

bool ArgBool(const EncodableMap& arguments, const char* key, bool fallback) {
  const auto iterator = arguments.find(EncodableValue(key));
  if (iterator == arguments.end() || !std::holds_alternative<bool>(iterator->second)) return fallback;
  return std::get<bool>(iterator->second);
}

int ClampInt(int value, int minimum, int maximum) {
  return std::max(minimum, std::min(value, maximum));
}

EncodableMap EmptyArgs(const EncodableValue* arguments) {
  if (arguments && std::holds_alternative<EncodableMap>(*arguments)) {
    return std::get<EncodableMap>(*arguments);
  }
  return EncodableMap();
}

std::wstring ExecutablePath() {
  std::wstring path(MAX_PATH, L'\0');
  DWORD size = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  while (size == path.size()) {
    path.resize(path.size() * 2);
    size = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  }
  path.resize(size);
  return path;
}

bool LaunchAtStartupEnabled() {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_READ, &key) != ERROR_SUCCESS) {
    return false;
  }
  std::wstring value(4096, L'\0');
  DWORD type = REG_SZ;
  DWORD bytes = static_cast<DWORD>(value.size() * sizeof(wchar_t));
  const LSTATUS status = RegQueryValueExW(key, kRunValue, nullptr, &type,
                                          reinterpret_cast<LPBYTE>(value.data()), &bytes);
  RegCloseKey(key);
  return status == ERROR_SUCCESS && type == REG_SZ;
}

void SetLaunchAtStartupEnabled(bool enabled) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                      nullptr) != ERROR_SUCCESS) {
    throw std::runtime_error("Impossible d'ouvrir la cle de demarrage Windows.");
  }

  if (enabled) {
    const std::wstring value = L"\"" + ExecutablePath() + L"\"";
    RegSetValueExW(key, kRunValue, 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
                   static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  } else {
    RegDeleteValueW(key, kRunValue);
  }
  RegCloseKey(key);
}

HICON CreatePhoneTrayIcon() {
  const int size = std::max(16, GetSystemMetrics(SM_CXSMICON));
  HDC screen_dc = GetDC(nullptr);
  HDC color_dc = CreateCompatibleDC(screen_dc);
  HBITMAP color_bitmap = CreateCompatibleBitmap(screen_dc, size, size);
  HGDIOBJ old_color = SelectObject(color_dc, color_bitmap);

  HDC mask_dc = CreateCompatibleDC(screen_dc);
  HBITMAP mask_bitmap = CreateBitmap(size, size, 1, 1, nullptr);
  HGDIOBJ old_mask = SelectObject(mask_dc, mask_bitmap);

  RECT bounds{0, 0, size, size};
  HBRUSH black_brush = CreateSolidBrush(RGB(0, 0, 0));
  HBRUSH white_brush = CreateSolidBrush(RGB(255, 255, 255));
  FillRect(color_dc, &bounds, black_brush);
  FillRect(mask_dc, &bounds, white_brush);

  HFONT font = CreateFontW(
      -MulDiv(15, GetDeviceCaps(screen_dc, LOGPIXELSY), 72), 0, 0, 0,
      FW_SEMIBOLD, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
      CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI Symbol");

  HGDIOBJ old_color_font = SelectObject(color_dc, font);
  SetBkMode(color_dc, TRANSPARENT);
  SetTextColor(color_dc, RGB(170, 205, 255));
  DrawTextW(color_dc, L"\x260E", -1, &bounds,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE);

  HGDIOBJ old_mask_font = SelectObject(mask_dc, font);
  SetBkMode(mask_dc, TRANSPARENT);
  SetTextColor(mask_dc, RGB(0, 0, 0));
  DrawTextW(mask_dc, L"\x260E", -1, &bounds,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE);

  ICONINFO icon_info{};
  icon_info.fIcon = TRUE;
  icon_info.hbmColor = color_bitmap;
  icon_info.hbmMask = mask_bitmap;
  HICON icon = CreateIconIndirect(&icon_info);

  SelectObject(color_dc, old_color_font);
  SelectObject(mask_dc, old_mask_font);
  SelectObject(color_dc, old_color);
  SelectObject(mask_dc, old_mask);
  DeleteObject(font);
  DeleteObject(black_brush);
  DeleteObject(white_brush);
  DeleteObject(color_bitmap);
  DeleteObject(mask_bitmap);
  DeleteDC(color_dc);
  DeleteDC(mask_dc);
  ReleaseDC(nullptr, screen_dc);

  return icon != nullptr ? icon : LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
}

bool GetTrayIconAnchor(POINT* anchor) {
  NOTIFYICONIDENTIFIER identifier{};
  identifier.cbSize = sizeof(identifier);
  identifier.hWnd = g_window;
  identifier.uID = kTrayIconId;

  RECT icon_rect{};
  if (Shell_NotifyIconGetRect(&identifier, &icon_rect) == S_OK) {
    anchor->x = icon_rect.left + (icon_rect.right - icon_rect.left) / 2;
    anchor->y = icon_rect.top + (icon_rect.bottom - icon_rect.top) / 2;
    return true;
  }

  return GetCursorPos(anchor) == TRUE;
}

void PositionWindowBottomRight(HMONITOR monitor, bool show) {
  RECT window_rect{};
  GetWindowRect(g_window, &window_rect);
  const int width = window_rect.right - window_rect.left;
  const int height = window_rect.bottom - window_rect.top;

  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  GetMonitorInfoW(monitor, &monitor_info);

  const RECT work = monitor_info.rcWork;
  const int margin = 8;
  const int x = work.right - width - margin;
  const int y = work.bottom - height - margin;
  const UINT flags = show ? SWP_SHOWWINDOW : SWP_NOACTIVATE;

  SetWindowPos(g_window, HWND_TOPMOST, x, y, width, height, flags);
  SetWindowPos(g_window, HWND_NOTOPMOST, x, y, width, height, flags);
}

void ShowTrayWindow(bool flash) {
  POINT anchor{};
  GetTrayIconAnchor(&anchor);
  if (IsIconic(g_window)) {
    ShowWindow(g_window, SW_RESTORE);
  } else {
    ShowWindow(g_window, SW_SHOWNORMAL);
  }
  PositionWindowBottomRight(MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST),
                            true);
  SetForegroundWindow(g_window);
  if (flash) {
    FlashWindow(g_window, TRUE);
  }
}

void SetTrayVisible(bool visible) {
  if (visible == g_tray_visible) return;

  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = g_window;
  data.uID = kTrayIconId;
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayIconMessage;
  if (visible && g_tray_icon == nullptr) {
    g_tray_icon = CreatePhoneTrayIcon();
  }
  data.hIcon = g_tray_icon != nullptr ? g_tray_icon : LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(data.szTip, L"SFAIT Softphone");

  Shell_NotifyIconW(visible ? NIM_ADD : NIM_DELETE, &data);
  g_tray_visible = visible;
}

void ShowTrayMenu() {
  POINT cursor{};
  GetCursorPos(&cursor);
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, 1, L"Ouvrir");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, 2, L"Quitter");
  SetForegroundWindow(g_window);
  const int command = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, cursor.x, cursor.y, 0, g_window, nullptr);
  DestroyMenu(menu);
  if (command == 1) {
    ShowTrayWindow(false);
  } else if (command == 2) {
    DestroyWindow(g_window);
  }
}

EncodableList PrivacyPermissions() {
  EncodableList permissions;
  permissions.emplace_back(EncodableMap{
      {EncodableValue("kind"), EncodableValue("microphone")},
      {EncodableValue("label"), EncodableValue("Microphone")},
      {EncodableValue("description"), EncodableValue("Windows gere l'autorisation du microphone pour les applications desktop.")},
      {EncodableValue("isActive"), EncodableValue(true)},
  });
  permissions.emplace_back(EncodableMap{
      {EncodableValue("kind"), EncodableValue("launchAtStartup")},
      {EncodableValue("label"), EncodableValue("Ouverture au demarrage")},
      {EncodableValue("description"), EncodableValue("Lance le softphone automatiquement via la cle Run utilisateur.")},
      {EncodableValue("isActive"), EncodableValue(LaunchAtStartupEnabled())},
  });
  return permissions;
}

EncodableList WaveDevices(bool input) {
  EncodableList devices;
  const UINT count = input ? waveInGetNumDevs() : waveOutGetNumDevs();
  for (UINT id = 0; id < count; ++id) {
    std::wstring label;
    if (input) {
      WAVEINCAPSW caps{};
      if (waveInGetDevCapsW(id, &caps, sizeof(caps)) != MMSYSERR_NOERROR) continue;
      label = caps.szPname;
    } else {
      WAVEOUTCAPSW caps{};
      if (waveOutGetDevCapsW(id, &caps, sizeof(caps)) != MMSYSERR_NOERROR) continue;
      label = caps.szPname;
    }
    devices.emplace_back(EncodableMap{
        {EncodableValue("id"), EncodableValue(std::string(input ? "wavein:" : "waveout:") + std::to_string(id))},
        {EncodableValue("label"), EncodableValue(WideToUtf8(label))},
    });
  }
  return devices;
}

void OpenPrivacySettings(const std::wstring& kind) {
  const wchar_t* uri = kind == L"launchAtStartup"
                           ? L"ms-settings:startupapps"
                           : L"ms-settings:privacy-microphone";
  ShellExecuteW(nullptr, L"open", uri, nullptr, nullptr, SW_SHOWNORMAL);
}

std::filesystem::path AppSupportDirectory() {
  PWSTR raw_path = nullptr;
  SHGetKnownFolderPath(FOLDERID_RoamingAppData, KF_FLAG_CREATE, nullptr, &raw_path);
  std::filesystem::path path(raw_path ? raw_path : L"");
  CoTaskMemFree(raw_path);
  path /= L"SFAIT Softphone";
  path /= L"Ringtones";
  std::filesystem::create_directories(path);
  return path;
}

std::filesystem::path DefaultRingtonePath() {
  const auto path = std::filesystem::temp_directory_path() / L"sfait_ringtone.wav";
  if (std::filesystem::exists(path)) return path;

  constexpr int sample_rate = 16000;
  constexpr double total_duration = 1.2;
  const int total_samples = static_cast<int>(sample_rate * total_duration);
  std::vector<int16_t> samples;
  samples.reserve(total_samples);
  for (int i = 0; i < total_samples; ++i) {
    const double time = static_cast<double>(i) / sample_rate;
    const double window = std::fmod(time, 0.52);
    const bool tone = window < 0.18 || (window > 0.26 && window < 0.44);
    const double value = tone ? ((std::sin(2.0 * 3.141592653589793 * 880.0 * time) +
                                  std::sin(2.0 * 3.141592653589793 * 1320.0 * time)) /
                                 2.0 * 0.35)
                              : 0.0;
    samples.push_back(static_cast<int16_t>(std::clamp(value, -1.0, 1.0) * 32767.0));
  }

  std::ofstream out(path, std::ios::binary);
  const uint32_t data_size = static_cast<uint32_t>(samples.size() * sizeof(int16_t));
  const uint32_t riff_size = 36 + data_size;
  const uint32_t byte_rate = sample_rate * 2;
  const uint16_t audio_format = 1;
  const uint16_t channels = 1;
  const uint16_t block_align = 2;
  const uint16_t bits = 16;
  out.write("RIFF", 4);
  out.write(reinterpret_cast<const char*>(&riff_size), 4);
  out.write("WAVEfmt ", 8);
  const uint32_t fmt_size = 16;
  out.write(reinterpret_cast<const char*>(&fmt_size), 4);
  out.write(reinterpret_cast<const char*>(&audio_format), 2);
  out.write(reinterpret_cast<const char*>(&channels), 2);
  out.write(reinterpret_cast<const char*>(&sample_rate), 4);
  out.write(reinterpret_cast<const char*>(&byte_rate), 4);
  out.write(reinterpret_cast<const char*>(&block_align), 2);
  out.write(reinterpret_cast<const char*>(&bits), 2);
  out.write("data", 4);
  out.write(reinterpret_cast<const char*>(&data_size), 4);
  out.write(reinterpret_cast<const char*>(samples.data()), data_size);
  return path;
}

void StopRingtone() {
  mciSendStringW((std::wstring(L"stop ") + kRingtoneAlias).c_str(), nullptr, 0, nullptr);
  mciSendStringW((std::wstring(L"close ") + kRingtoneAlias).c_str(), nullptr, 0, nullptr);
}

void ApplyRingtoneVolume() {
  const int volume = static_cast<int>(std::clamp(g_ringtone_volume, 0.0, 1.0) * 1000.0);
  const std::wstring command = L"setaudio " + std::wstring(kRingtoneAlias) +
                               L" volume to " + std::to_wstring(volume);
  mciSendStringW(command.c_str(), nullptr, 0, nullptr);
}

void ApplyRingtoneOutputDevice(const std::wstring& output_device_id) {
  const int device_id = WaveOutDeviceId(output_device_id);
  if (device_id < 0) return;

  const MCIDEVICEID mci_device_id = mciGetDeviceIDW(kRingtoneAlias);
  if (mci_device_id == 0) return;

  MCI_WAVE_SET_PARMS params{};
  params.wOutput = static_cast<UINT>(device_id);
  mciSendCommandW(mci_device_id, MCI_SET, MCI_WAVE_OUTPUT,
                  reinterpret_cast<DWORD_PTR>(&params));
}

void PlayRingtone(const std::wstring& output_device_id,
                  const std::wstring& file_path,
                  double volume) {
  StopRingtone();
  g_ringtone_volume = volume;
  const std::filesystem::path path =
      !file_path.empty() && std::filesystem::exists(file_path) ? file_path : DefaultRingtonePath();
  const std::wstring open = L"open \"" + path.wstring() + L"\" alias " + kRingtoneAlias;
  mciSendStringW(open.c_str(), nullptr, 0, nullptr);
  ApplyRingtoneOutputDevice(output_device_id);
  ApplyRingtoneVolume();
  mciSendStringW((std::wstring(L"play ") + kRingtoneAlias + L" repeat").c_str(), nullptr, 0, nullptr);
}

EncodableValue ImportRingtone() {
  wchar_t file_name[MAX_PATH] = L"";
  OPENFILENAMEW dialog{};
  dialog.lStructSize = sizeof(dialog);
  dialog.hwndOwner = g_window;
  dialog.lpstrFilter = L"Audio\0*.wav;*.mp3;*.m4a;*.aiff;*.aif;*.caf\0Tous les fichiers\0*.*\0";
  dialog.lpstrFile = file_name;
  dialog.nMaxFile = MAX_PATH;
  dialog.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;
  dialog.lpstrTitle = L"Choisissez une sonnerie audio pour SFAIT Softphone";

  if (!GetOpenFileNameW(&dialog)) return EncodableValue();

  const std::filesystem::path source(file_name);
  std::filesystem::path destination = AppSupportDirectory() / source.filename();
  std::filesystem::copy_file(source, destination, std::filesystem::copy_options::overwrite_existing);
  return EncodableValue(EncodableMap{
      {EncodableValue("path"), EncodableValue(WideToUtf8(destination.wstring()))},
      {EncodableValue("name"), EncodableValue(WideToUtf8(destination.filename().wstring()))},
  });
}

void HandleLaunchMethod(const MethodCall<EncodableValue>& call,
                        std::unique_ptr<MethodResult<EncodableValue>> result) {
  try {
    if (call.method_name() == "launchAtStartupIsEnabled") {
      result->Success(EncodableValue(LaunchAtStartupEnabled()));
    } else if (call.method_name() == "launchAtStartupSetEnabled") {
      SetLaunchAtStartupEnabled(ArgBool(EmptyArgs(call.arguments()), "setEnabledValue", false));
      result->Success();
    } else {
      result->NotImplemented();
    }
  } catch (const std::exception& error) {
    result->Error("launch_at_startup_failed", error.what());
  }
}

void HandleSystemMethod(const MethodCall<EncodableValue>& call,
                        std::unique_ptr<MethodResult<EncodableValue>> result) {
  const EncodableMap arguments = EmptyArgs(call.arguments());
  if (call.method_name() == "listAudioInputs") {
    result->Success(EncodableValue(WaveDevices(true)));
  } else if (call.method_name() == "listAudioOutputs") {
    result->Success(EncodableValue(WaveDevices(false)));
  } else if (call.method_name() == "listPrivacyPermissions") {
    result->Success(EncodableValue(PrivacyPermissions()));
  } else if (call.method_name() == "showWindowForIncomingCall") {
    ShowTrayWindow(true);
    result->Success();
  } else if (call.method_name() == "openPrivacyPermissionSettings") {
    OpenPrivacySettings(ArgWide(arguments, "kind"));
    result->Success();
  } else if (call.method_name() == "setWindowPresentationOptions") {
    SetTrayVisible(true);
    result->Success();
  } else {
    result->NotImplemented();
  }
}

void HandleRingtoneMethod(const MethodCall<EncodableValue>& call,
                          std::unique_ptr<MethodResult<EncodableValue>> result) {
  try {
    const EncodableMap arguments = EmptyArgs(call.arguments());
    if (call.method_name() == "playRingtone") {
      PlayRingtone(ArgWide(arguments, "outputDeviceId"), ArgWide(arguments, "filePath"),
                   ArgDouble(arguments, "volume", 1.0));
      result->Success();
    } else if (call.method_name() == "stopRingtone") {
      StopRingtone();
      result->Success();
    } else if (call.method_name() == "setRingtoneVolume") {
      g_ringtone_volume = ArgDouble(arguments, "volume", 1.0);
      ApplyRingtoneVolume();
      result->Success();
    } else if (call.method_name() == "importRingtone") {
      result->Success(ImportRingtone());
    } else {
      result->NotImplemented();
    }
  } catch (const std::exception& error) {
    result->Error("ringtone_failed", error.what());
  }
}

}  // namespace

void ConfigureWindowsIntegration(flutter::BinaryMessenger* messenger, HWND window) {
  g_window = window;
  g_launch_channel = std::make_unique<MethodChannel<EncodableValue>>(
      messenger, "sfait/launch_at_startup", &flutter::StandardMethodCodec::GetInstance());
  g_system_channel = std::make_unique<MethodChannel<EncodableValue>>(
      messenger, "sfait/system_settings", &flutter::StandardMethodCodec::GetInstance());
  g_ringtone_channel = std::make_unique<MethodChannel<EncodableValue>>(
      messenger, "sfait/ringtone", &flutter::StandardMethodCodec::GetInstance());
  g_launch_channel->SetMethodCallHandler(HandleLaunchMethod);
  g_system_channel->SetMethodCallHandler(HandleSystemMethod);
  g_ringtone_channel->SetMethodCallHandler(HandleRingtoneMethod);
  SetTrayVisible(true);
  PositionWindowBottomRight(MonitorFromWindow(g_window, MONITOR_DEFAULTTONEAREST),
                            false);
}

void HandleTrayIconMessage(HWND window, WPARAM wparam, LPARAM lparam) {
  if (wparam != kTrayIconId) return;
  if (lparam == WM_LBUTTONUP || lparam == WM_LBUTTONDBLCLK) {
    if (IsWindowVisible(g_window)) {
      ShowWindow(g_window, SW_HIDE);
    } else {
      ShowTrayWindow(false);
    }
  } else if (lparam == WM_RBUTTONUP || lparam == WM_CONTEXTMENU) {
    ShowTrayMenu();
  }
}

bool ShouldHideWindowOnClose() {
  return g_tray_visible;
}

void DestroyWindowsIntegration() {
  StopRingtone();
  SetTrayVisible(false);
  if (g_tray_icon != nullptr) {
    DestroyIcon(g_tray_icon);
    g_tray_icon = nullptr;
  }
  g_launch_channel.reset();
  g_system_channel.reset();
  g_ringtone_channel.reset();
  g_window = nullptr;
}

}  // namespace sfait
