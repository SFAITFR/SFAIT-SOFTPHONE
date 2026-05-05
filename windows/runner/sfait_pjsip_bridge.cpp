#include "sfait_pjsip_bridge.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cctype>
#include <map>
#include <memory>
#include <mutex>
#include <queue>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "pjsua2.hpp"

namespace sfait {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodChannel;
using flutter::MethodResult;
using pj::Account;
using pj::AccountConfig;
using pj::AccountInfo;
using pj::AudioDevInfo;
using pj::AudioDevInfoVector2;
using pj::AudioMedia;
using pj::AuthCredInfo;
using pj::Call;
using pj::CallInfo;
using pj::CallMediaInfo;
using pj::CallOpParam;
using pj::CodecInfo;
using pj::CodecInfoVector2;
using pj::Endpoint;
using pj::EpConfig;
using pj::Error;
using pj::OnCallMediaStateParam;
using pj::OnCallStateParam;
using pj::OnIncomingCallParam;
using pj::OnRegStateParam;
using pj::TransportConfig;

std::unique_ptr<MethodChannel<EncodableValue>> g_channel;
HWND g_window = nullptr;
std::mutex g_event_mutex;
std::queue<EncodableMap> g_pending_events;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return L"";
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
  std::wstring result(size > 0 ? size - 1 : 0, L'\0');
  if (size > 1) {
    MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), size);
  }
  return result;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return "";
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0, nullptr, nullptr);
  std::string result(size > 0 ? size - 1 : 0, '\0');
  if (size > 1) {
    WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), size, nullptr, nullptr);
  }
  return result;
}

std::string ValueString(const EncodableValue* value) {
  if (!value || !std::holds_alternative<std::string>(*value)) {
    return "";
  }
  return std::get<std::string>(*value);
}

std::string ArgString(const EncodableMap& arguments, const char* key) {
  auto iterator = arguments.find(EncodableValue(key));
  if (iterator == arguments.end()) {
    return "";
  }
  return ValueString(&iterator->second);
}

std::string CleanRemote(const std::string& remote_uri) {
  std::string remote = remote_uri;
  const std::string sip = "sip:";
  const auto sip_position = remote.find(sip);
  if (sip_position != std::string::npos) {
    remote = remote.substr(sip_position + sip.size());
  }
  const auto at_position = remote.find('@');
  if (at_position != std::string::npos) {
    remote = remote.substr(0, at_position);
  }
  remote.erase(std::remove(remote.begin(), remote.end(), '"'), remote.end());
  remote.erase(remote.begin(), std::find_if(remote.begin(), remote.end(), [](unsigned char c) {
    return !std::isspace(c);
  }));
  remote.erase(std::find_if(remote.rbegin(), remote.rend(), [](unsigned char c) {
    return !std::isspace(c);
  }).base(), remote.end());
  return remote.empty() ? "Inconnu" : remote;
}

std::string CleanDeviceLabel(const std::string& name) {
  std::string label = name;
  const std::vector<std::string> suffixes = {
      " - Windows WMME", " Windows WMME", " (Windows WMME)", " - WMME", " (WMME)"};
  for (const auto& suffix : suffixes) {
    if (label.size() >= suffix.size() &&
        label.compare(label.size() - suffix.size(), suffix.size(), suffix) == 0) {
      label.erase(label.size() - suffix.size());
    }
  }
  return label.empty() ? "Peripherique audio" : label;
}

bool IsAuxiliaryCodec(const std::string& codec_id) {
  std::string lower = codec_id;
  std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return lower.rfind("telephone-event", 0) == 0 || lower.rfind("cn/", 0) == 0;
}

std::string CanonicalVoiceCodec(const std::string& codec_id) {
  std::string lower = codec_id;
  std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  if (lower.rfind("opus/", 0) == 0 || lower == "opus") return "opus";
  if (lower.rfind("g722/", 0) == 0 || lower == "g722") return "g722";
  if (lower.rfind("pcma/", 0) == 0 || lower.rfind("g711a", 0) == 0) return "pcma";
  if (lower.rfind("pcmu/", 0) == 0 || lower.rfind("g711u", 0) == 0) return "pcmu";
  return "";
}

int PreferredCodecRank(const std::string& codec_id) {
  const std::string canonical = CanonicalVoiceCodec(codec_id);
  if (canonical == "opus") return 0;
  if (canonical == "g722") return 1;
  if (canonical == "pcma") return 2;
  if (canonical == "pcmu") return 3;
  return 99;
}

std::string CodecLabel(const CodecInfo& codec) {
  const std::string canonical = CanonicalVoiceCodec(codec.codecId);
  if (canonical == "opus") return "Opus";
  if (canonical == "g722") return "G.722 HD";
  if (canonical == "pcma") return "G.711 A-law (PCMA)";
  if (canonical == "pcmu") return "G.711 u-law (PCMU)";
  return codec.codecId;
}

int ParsePjsipDeviceId(const std::string& device_id) {
  const std::string prefix = "pjsip:";
  if (device_id.rfind(prefix, 0) == 0) {
    return std::stoi(device_id.substr(prefix.size()));
  }
  return std::stoi(device_id);
}

void Emit(EncodableMap event) {
  {
    std::lock_guard<std::mutex> lock(g_event_mutex);
    g_pending_events.push(std::move(event));
  }
  if (g_window) {
    PostMessage(g_window, kNativeSoftphoneEventMessage, 0, 0);
  }
}

class SfaitPjsipEngine;

class SfaitPjsipCall : public Call {
 public:
  SfaitPjsipCall(Account& account, int call_id, SfaitPjsipEngine* engine, bool incoming)
      : Call(account, call_id), engine_(engine), incoming_(incoming) {}

  void onCallState(OnCallStateParam& prm) override;
  void onCallMediaState(OnCallMediaStateParam& prm) override;

  bool incoming() const { return incoming_; }
  bool established() const { return established_; }
  void set_established(bool value) { established_ = value; }

 private:
  SfaitPjsipEngine* engine_;
  bool incoming_;
  bool established_ = false;
};

class SfaitPjsipAccount : public Account {
 public:
  explicit SfaitPjsipAccount(SfaitPjsipEngine* engine) : engine_(engine) {}

  void onRegState(OnRegStateParam& prm) override;
  void onIncomingCall(OnIncomingCallParam& prm) override;

 private:
  SfaitPjsipEngine* engine_;
};

class SfaitPjsipEngine {
 public:
  ~SfaitPjsipEngine() { shutdown(); }

  void ensureStarted() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (started_) return;

    endpoint_ = std::make_unique<Endpoint>();
    endpoint_->libCreate();

    EpConfig ep_config;
    ep_config.logConfig.level = 3;
    ep_config.logConfig.consoleLevel = 3;
    ep_config.uaConfig.threadCnt = 1;
    ep_config.medConfig.noVad = true;
    ep_config.medConfig.ecTailLen = 0;
    endpoint_->libInit(ep_config);

    TransportConfig transport_config;
    transport_config.port = 0;
    endpoint_->transportCreate(PJSIP_TRANSPORT_UDP, transport_config);

    endpoint_->libStart();
    started_ = true;
    captureDefaultCodecPriorities();
    applyPreferredCodecPriority();
  }

  EncodableList listDevices(bool input) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    ensureStarted();

    EncodableList items;
    const AudioDevInfoVector2 devices = endpoint_->audDevManager().enumDev2();
    for (const AudioDevInfo& device : devices) {
      if (input && device.inputCount == 0) continue;
      if (!input && device.outputCount == 0) continue;

      EncodableMap item;
      item[EncodableValue("id")] = EncodableValue("pjsip:" + std::to_string(device.id));
      item[EncodableValue("label")] = EncodableValue(CleanDeviceLabel(device.name));
      items.emplace_back(item);
    }
    return items;
  }

  EncodableList listCodecs() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    ensureStarted();

    std::vector<CodecInfo> preferred_codecs;
    std::map<std::string, bool> included_codecs;
    const CodecInfoVector2 codecs = endpoint_->codecEnum2();
    for (const CodecInfo& codec : codecs) {
      const std::string canonical = CanonicalVoiceCodec(codec.codecId);
      if (codec.codecId.empty() || canonical.empty() || included_codecs[canonical]) {
        continue;
      }
      included_codecs[canonical] = true;
      preferred_codecs.push_back(codec);
    }

    std::sort(preferred_codecs.begin(), preferred_codecs.end(),
              [](const CodecInfo& left, const CodecInfo& right) {
                return PreferredCodecRank(left.codecId) < PreferredCodecRank(right.codecId);
              });

    EncodableList items;
    for (const CodecInfo& codec : preferred_codecs) {
      EncodableMap item;
      item[EncodableValue("id")] = EncodableValue(codec.codecId);
      item[EncodableValue("label")] = EncodableValue(CodecLabel(codec));
      item[EncodableValue("priority")] = EncodableValue(static_cast<int>(codec.priority));
      items.emplace_back(item);
    }
    return items;
  }

  void setPreferredCodec(const std::string& codec_id) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    ensureStarted();
    preferred_codec_id_ = codec_id;
    applyPreferredCodecPriority();
  }

  void setCaptureDevice(const std::string& device_id) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (device_id.empty()) return;
    ensureStarted();
    capture_device_id_ = ParsePjsipDeviceId(device_id);
    endpoint_->audDevManager().setCaptureDev(capture_device_id_);
  }

  void setPlaybackDevice(const std::string& device_id) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (device_id.empty()) return;
    ensureStarted();
    playback_device_id_ = ParsePjsipDeviceId(device_id);
    endpoint_->audDevManager().setPlaybackDev(playback_device_id_);
  }

  void registerAccount(const EncodableMap& arguments) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    ensureStarted();

    if (active_call_) {
      hangup();
    }
    account_.reset();

    domain_ = ArgString(arguments, "domain");
    extension_ = ArgString(arguments, "extension");
    std::string authorization_id = ArgString(arguments, "authorizationId");
    std::string password = ArgString(arguments, "password");
    std::string display_name = ArgString(arguments, "displayName");

    if (domain_.empty() || extension_.empty() || password.empty()) {
      throw std::runtime_error("Configuration SIP incomplete.");
    }
    if (authorization_id.empty()) authorization_id = extension_;
    if (display_name.empty()) display_name = extension_;

    Emit({{EncodableValue("status"), EncodableValue("connecting")},
          {EncodableValue("message"), EncodableValue("Connexion SIP native en cours...")}});

    AccountConfig config;
    config.idUri = "sip:" + extension_ + "@" + domain_;
    config.regConfig.registrarUri = "sip:" + domain_;
    config.sipConfig.authCreds.push_back(AuthCredInfo("digest", "*", authorization_id, 0, password));
    config.natConfig.iceEnabled = false;

    account_ = std::make_unique<SfaitPjsipAccount>(this);
    account_->create(config);
  }

  void disconnect() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (active_call_) {
      try {
        active_call_->hangup(CallOpParam());
      } catch (...) {
      }
      active_call_.reset();
    }
    if (account_) {
      try {
        account_->setRegistration(false);
      } catch (...) {
      }
      account_.reset();
    }
    registered_ = false;
    muted_ = false;
    held_ = false;
    call_active_ = false;
    Emit({{EncodableValue("status"), EncodableValue("offline")},
          {EncodableValue("message"), EncodableValue("Softphone deconnecte.")},
          {EncodableValue("isMuted"), EncodableValue(false)},
          {EncodableValue("isOnHold"), EncodableValue(false)}});
  }

  void makeCall(const std::string& destination) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!account_ || !registered_) {
      throw std::runtime_error("Le compte SIP n'est pas encore enregistre.");
    }
    if (destination.empty()) {
      throw std::runtime_error("Destination vide.");
    }
    applySelectedDevices();
    call_active_ = true;
    active_call_ = std::make_unique<SfaitPjsipCall>(*account_, PJSUA_INVALID_ID, this, false);
    CallOpParam param(true);
    active_call_->makeCall(normalizeTarget(destination), param);
  }

  void answer() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!active_call_) throw std::runtime_error("Aucun appel entrant a accepter.");
    applySelectedDevices();
    CallOpParam param;
    param.statusCode = PJSIP_SC_OK;
    active_call_->answer(param);
  }

  void hangup() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!active_call_) throw std::runtime_error("Aucun appel actif a raccrocher.");
    active_call_->hangup(CallOpParam());
  }

  void toggleMute() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!active_call_) throw std::runtime_error("Aucun appel actif pour gerer le micro.");
    muted_ = !muted_;
    reconnectMedia();
    Emit({{EncodableValue("status"), EncodableValue("inCall")},
          {EncodableValue("message"), EncodableValue(muted_ ? "Micro coupe." : "Micro reactive.")},
          {EncodableValue("remoteIdentity"), EncodableValue(currentRemoteIdentity())},
          {EncodableValue("isMuted"), EncodableValue(muted_)},
          {EncodableValue("isOnHold"), EncodableValue(held_)}});
  }

  void toggleHold() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!active_call_) throw std::runtime_error("Aucun appel actif pour la mise en attente.");
    if (held_) {
      CallOpParam param(true);
      param.opt.flag |= PJSUA_CALL_UNHOLD;
      active_call_->reinvite(param);
      held_ = false;
    } else {
      active_call_->setHold(CallOpParam());
      held_ = true;
    }
    Emit({{EncodableValue("status"), EncodableValue("inCall")},
          {EncodableValue("message"), EncodableValue(held_ ? "Appel mis en attente." : "Communication reprise.")},
          {EncodableValue("remoteIdentity"), EncodableValue(currentRemoteIdentity())},
          {EncodableValue("isMuted"), EncodableValue(muted_)},
          {EncodableValue("isOnHold"), EncodableValue(held_)}});
  }

  void sendDtmf(const std::string& tone) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!active_call_) throw std::runtime_error("Aucun appel actif pour envoyer un DTMF.");
    active_call_->dialDtmf(tone);
  }

  void transfer(const std::string& destination) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!active_call_) throw std::runtime_error("Aucun appel actif a transferer.");
    active_call_->xfer(normalizeTarget(destination), CallOpParam());
  }

  void handleRegistration(int code, const std::string& reason) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    registered_ = code >= 200 && code < 300;
    if (call_active_) return;
    if (registered_) {
      Emit({{EncodableValue("status"), EncodableValue("registered")},
            {EncodableValue("message"),
             EncodableValue("Compte " + extension_ + " enregistre et pret a recevoir des appels.")},
            {EncodableValue("isMuted"), EncodableValue(false)},
            {EncodableValue("isOnHold"), EncodableValue(false)}});
    } else {
      Emit({{EncodableValue("status"), EncodableValue("error")},
            {EncodableValue("message"),
             EncodableValue("Enregistrement SIP refuse: " + reason + " (" + std::to_string(code) + ")")}});
    }
  }

  void handleIncomingCall(int call_id) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!account_) return;
    call_active_ = true;
    active_call_ = std::make_unique<SfaitPjsipCall>(*account_, call_id, this, true);
    const std::string remote = currentRemoteIdentity();
    Emit({{EncodableValue("status"), EncodableValue("ringing")},
          {EncodableValue("message"), EncodableValue("Appel entrant de " + remote)},
          {EncodableValue("remoteIdentity"), EncodableValue(remote)},
          {EncodableValue("isMuted"), EncodableValue(false)},
          {EncodableValue("isOnHold"), EncodableValue(false)}});
  }

  void handleCallState(SfaitPjsipCall* call) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    const CallInfo info = call->getInfo();
    const std::string remote = CleanRemote(info.remoteUri);

    switch (info.state) {
      case PJSIP_INV_STATE_CALLING:
      case PJSIP_INV_STATE_CONNECTING:
        Emit({{EncodableValue("status"), EncodableValue("calling")},
              {EncodableValue("message"), EncodableValue("Connexion de l'appel vers " + remote + "...")},
              {EncodableValue("remoteIdentity"), EncodableValue(remote)},
              {EncodableValue("isMuted"), EncodableValue(muted_)},
              {EncodableValue("isOnHold"), EncodableValue(held_)}});
        break;
      case PJSIP_INV_STATE_EARLY:
        Emit({{EncodableValue("status"), EncodableValue("calling")},
              {EncodableValue("message"), EncodableValue("Ca sonne chez " + remote + "...")},
              {EncodableValue("remoteIdentity"), EncodableValue(remote)},
              {EncodableValue("isMuted"), EncodableValue(muted_)},
              {EncodableValue("isOnHold"), EncodableValue(held_)}});
        break;
      case PJSIP_INV_STATE_CONFIRMED:
        call->set_established(true);
        Emit({{EncodableValue("status"), EncodableValue("inCall")},
              {EncodableValue("message"), EncodableValue("Communication active avec " + remote)},
              {EncodableValue("remoteIdentity"), EncodableValue(remote)},
              {EncodableValue("isMuted"), EncodableValue(muted_)},
              {EncodableValue("isOnHold"), EncodableValue(held_)}});
        break;
      case PJSIP_INV_STATE_DISCONNECTED: {
        const std::string summary = call->established() ? "Appel termine" : "Appel manque ou echoue";
        const std::string direction =
            call->incoming() ? (call->established() ? "incoming" : "missed") : "outgoing";
        muted_ = false;
        held_ = false;
        call_active_ = false;
        Emit({{EncodableValue("status"), EncodableValue(registered_ ? "registered" : "offline")},
              {EncodableValue("message"), EncodableValue("Appel termine.")},
              {EncodableValue("remoteIdentity"), EncodableValue(remote)},
              {EncodableValue("historyDirection"), EncodableValue(direction)},
              {EncodableValue("historySummary"), EncodableValue(summary)},
              {EncodableValue("isMuted"), EncodableValue(false)},
              {EncodableValue("isOnHold"), EncodableValue(false)}});
        break;
      }
      default:
        break;
    }
  }

  void handleCallMediaState(SfaitPjsipCall* call) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    const CallInfo info = call->getInfo();
    bool local_hold = false;
    for (const CallMediaInfo& media : info.media) {
      if (media.type == PJMEDIA_TYPE_AUDIO && media.status == PJSUA_CALL_MEDIA_LOCAL_HOLD) {
        local_hold = true;
        break;
      }
    }
    held_ = local_hold;
    applySelectedDevices();
    reconnectMedia();
    if (info.state == PJSIP_INV_STATE_CONFIRMED) {
      Emit({{EncodableValue("status"), EncodableValue("inCall")},
            {EncodableValue("message"), EncodableValue(held_ ? "Appel mis en attente." : "Communication active.")},
            {EncodableValue("remoteIdentity"), EncodableValue(currentRemoteIdentity())},
            {EncodableValue("isMuted"), EncodableValue(muted_)},
            {EncodableValue("isOnHold"), EncodableValue(held_)}});
    }
  }

  void shutdown() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    try {
      disconnect();
    } catch (...) {
    }
    if (endpoint_) {
      try {
        endpoint_->libDestroy();
      } catch (...) {
      }
      endpoint_.reset();
    }
    started_ = false;
  }

 private:
  std::string normalizeTarget(const std::string& destination) const {
    if (destination.rfind("sip:", 0) == 0) return destination;
    if (destination.find('@') != std::string::npos) return "sip:" + destination;
    return "sip:" + destination + "@" + domain_;
  }

  void applySelectedDevices() {
    if (capture_device_id_ >= 0) endpoint_->audDevManager().setCaptureDev(capture_device_id_);
    if (playback_device_id_ >= 0) endpoint_->audDevManager().setPlaybackDev(playback_device_id_);
  }

  void captureDefaultCodecPriorities() {
    if (!default_codec_priorities_.empty()) return;
    const CodecInfoVector2 codecs = endpoint_->codecEnum2();
    for (const CodecInfo& codec : codecs) {
      if (!codec.codecId.empty()) default_codec_priorities_[codec.codecId] = codec.priority;
    }
  }

  void applyPreferredCodecPriority() {
    captureDefaultCodecPriorities();
    if (preferred_codec_id_.empty()) {
      for (const auto& entry : default_codec_priorities_) {
        endpoint_->codecSetPriority(entry.first, entry.second);
      }
      return;
    }
    if (IsAuxiliaryCodec(preferred_codec_id_) || PreferredCodecRank(preferred_codec_id_) >= 99) {
      throw std::runtime_error("Codec audio invalide.");
    }

    bool found = false;
    for (const auto& entry : default_codec_priorities_) {
      if (IsAuxiliaryCodec(entry.first)) {
        endpoint_->codecSetPriority(entry.first, entry.second);
      } else if (entry.first == preferred_codec_id_) {
        endpoint_->codecSetPriority(entry.first, 255);
        found = true;
      } else {
        endpoint_->codecSetPriority(entry.first, 0);
      }
    }
    if (!found) throw std::runtime_error("Codec audio introuvable.");
  }

  void reconnectMedia() {
    if (!active_call_) return;
    const CallInfo info = active_call_->getInfo();
    for (unsigned i = 0; i < info.media.size(); ++i) {
      const CallMediaInfo& media = info.media[i];
      if (media.type != PJMEDIA_TYPE_AUDIO) continue;
      if (media.status != PJSUA_CALL_MEDIA_ACTIVE && media.status != PJSUA_CALL_MEDIA_REMOTE_HOLD) continue;

      AudioMedia call_media = active_call_->getAudioMedia(i);
      try {
        endpoint_->audDevManager().getCaptureDevMedia().stopTransmit(call_media);
      } catch (...) {
      }
      try {
        call_media.stopTransmit(endpoint_->audDevManager().getPlaybackDevMedia());
      } catch (...) {
      }
      if (!muted_) {
        endpoint_->audDevManager().getCaptureDevMedia().startTransmit(call_media);
      }
      call_media.startTransmit(endpoint_->audDevManager().getPlaybackDevMedia());
    }
  }

  std::string currentRemoteIdentity() {
    if (!active_call_) return "Inconnu";
    try {
      return CleanRemote(active_call_->getInfo().remoteUri);
    } catch (...) {
      return "Inconnu";
    }
  }

  std::recursive_mutex mutex_;
  std::unique_ptr<Endpoint> endpoint_;
  std::unique_ptr<SfaitPjsipAccount> account_;
  std::unique_ptr<SfaitPjsipCall> active_call_;
  std::string domain_;
  std::string extension_;
  bool started_ = false;
  bool registered_ = false;
  bool call_active_ = false;
  bool muted_ = false;
  bool held_ = false;
  int capture_device_id_ = -1;
  int playback_device_id_ = -1;
  std::string preferred_codec_id_;
  std::map<std::string, pj_uint8_t> default_codec_priorities_;
};

SfaitPjsipEngine g_engine;

void SfaitPjsipAccount::onRegState(OnRegStateParam& prm) {
  const AccountInfo info = getInfo();
  engine_->handleRegistration(prm.code, info.regStatusText);
}

void SfaitPjsipAccount::onIncomingCall(OnIncomingCallParam& prm) {
  engine_->handleIncomingCall(prm.callId);
}

void SfaitPjsipCall::onCallState(OnCallStateParam& prm) {
  engine_->handleCallState(this);
}

void SfaitPjsipCall::onCallMediaState(OnCallMediaStateParam& prm) {
  engine_->handleCallMediaState(this);
}

const EncodableMap EmptyArgs(const EncodableValue* arguments) {
  if (arguments && std::holds_alternative<EncodableMap>(*arguments)) {
    return std::get<EncodableMap>(*arguments);
  }
  return EncodableMap();
}

void HandleMethodCall(const MethodCall<EncodableValue>& call,
                      std::unique_ptr<MethodResult<EncodableValue>> result) {
  try {
    const EncodableMap arguments = EmptyArgs(call.arguments());
    const std::string& method = call.method_name();

    if (method == "listAudioInputs") {
      result->Success(EncodableValue(g_engine.listDevices(true)));
    } else if (method == "listAudioOutputs") {
      result->Success(EncodableValue(g_engine.listDevices(false)));
    } else if (method == "listCodecs") {
      result->Success(EncodableValue(g_engine.listCodecs()));
    } else if (method == "setAudioInput") {
      g_engine.setCaptureDevice(ArgString(arguments, "deviceId"));
      result->Success();
    } else if (method == "setAudioOutput") {
      g_engine.setPlaybackDevice(ArgString(arguments, "deviceId"));
      result->Success();
    } else if (method == "setPreferredCodec") {
      g_engine.setPreferredCodec(ArgString(arguments, "codecId"));
      result->Success();
    } else if (method == "register") {
      g_engine.registerAccount(arguments);
      result->Success();
    } else if (method == "disconnect") {
      g_engine.disconnect();
      result->Success();
    } else if (method == "makeCall") {
      g_engine.makeCall(ArgString(arguments, "destination"));
      result->Success();
    } else if (method == "answer") {
      g_engine.answer();
      result->Success();
    } else if (method == "hangup") {
      g_engine.hangup();
      result->Success();
    } else if (method == "toggleMute") {
      g_engine.toggleMute();
      result->Success();
    } else if (method == "toggleHold") {
      g_engine.toggleHold();
      result->Success();
    } else if (method == "sendDtmf") {
      g_engine.sendDtmf(ArgString(arguments, "tone"));
      result->Success();
    } else if (method == "transfer") {
      g_engine.transfer(ArgString(arguments, "destination"));
      result->Success();
    } else {
      result->NotImplemented();
    }
  } catch (const Error& error) {
    result->Error("native_softphone_error", error.reason);
  } catch (const std::exception& error) {
    result->Error("native_softphone_error", error.what());
  } catch (...) {
    result->Error("native_softphone_error", "Erreur native inconnue.");
  }
}

}  // namespace

void ConfigurePjsipBridge(flutter::BinaryMessenger* messenger, HWND window) {
  g_window = window;
  g_channel = std::make_unique<MethodChannel<EncodableValue>>(
      messenger, "sfait/native_softphone", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(HandleMethodCall);
}

void DrainPjsipBridgeEvents() {
  if (!g_channel) return;

  std::queue<EncodableMap> events;
  {
    std::lock_guard<std::mutex> lock(g_event_mutex);
    std::swap(events, g_pending_events);
  }

  while (!events.empty()) {
    g_channel->InvokeMethod("onNativeSoftphoneEvent",
                            std::make_unique<EncodableValue>(events.front()));
    events.pop();
  }
}

void ShutdownPjsipBridge() {
  g_engine.shutdown();
  g_channel.reset();
  g_window = nullptr;
}

}  // namespace sfait
