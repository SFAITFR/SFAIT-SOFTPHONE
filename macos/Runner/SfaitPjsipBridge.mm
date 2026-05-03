#import "SfaitPjsipBridge.h"

#include <algorithm>
#include <cctype>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

#include "pjsua2.hpp"

using namespace pj;

@interface SfaitPjsipBridge ()
@property(nonatomic, strong) FlutterMethodChannel *channel;
@end

static SfaitPjsipBridge *gBridge = nil;

static NSString *SfaitString(const std::string &value) {
  return [NSString stringWithUTF8String:value.c_str()];
}

static std::string SfaitStdString(id value) {
  if (![value isKindOfClass:[NSString class]]) {
    return "";
  }
  return std::string([(NSString *)value UTF8String]);
}

static NSString *SfaitCleanRemote(const std::string &remoteUri) {
  NSString *remote = SfaitString(remoteUri);
  NSRange sipRange = [remote rangeOfString:@"sip:"];
  if (sipRange.location != NSNotFound) {
    remote = [remote substringFromIndex:sipRange.location + sipRange.length];
  }
  NSRange atRange = [remote rangeOfString:@"@"];
  if (atRange.location != NSNotFound) {
    remote = [remote substringToIndex:atRange.location];
  }
  remote = [remote stringByReplacingOccurrencesOfString:@"\"" withString:@""];
  remote = [remote stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return remote.length > 0 ? remote : @"Inconnu";
}

static NSString *SfaitCleanDeviceLabel(const std::string &name) {
  NSString *label = SfaitString(name);
  NSArray<NSString *> *suffixes = @[
    @" · CoreAudio",
    @" · coreaudio",
    @" (CoreAudio)",
    @" (coreaudio)",
    @" CoreAudio",
    @" coreaudio"
  ];
  for (NSString *suffix in suffixes) {
    if ([label hasSuffix:suffix]) {
      label = [label substringToIndex:label.length - suffix.length];
    }
  }
  label = [label stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return label.length > 0 ? label : @"Périphérique audio";
}

static bool SfaitIsAuxiliaryCodec(const std::string &codecId) {
  std::string lower = codecId;
  std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  return lower.rfind("telephone-event", 0) == 0 || lower.rfind("cn/", 0) == 0;
}

static std::string SfaitCanonicalVoiceCodec(const std::string &codecId) {
  std::string lower = codecId;
  std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) {
    return static_cast<char>(std::tolower(c));
  });
  if (lower.rfind("opus/", 0) == 0 || lower == "opus") {
    return "opus";
  }
  if (lower.rfind("g722/", 0) == 0 || lower == "g722") {
    return "g722";
  }
  if (lower.rfind("pcma/", 0) == 0 || lower.rfind("g711a", 0) == 0) {
    return "pcma";
  }
  if (lower.rfind("pcmu/", 0) == 0 || lower.rfind("g711u", 0) == 0) {
    return "pcmu";
  }
  return "";
}

static int SfaitPreferredCodecRank(const std::string &codecId) {
  const std::string canonical = SfaitCanonicalVoiceCodec(codecId);
  if (canonical == "opus") {
    return 0;
  }
  if (canonical == "g722") {
    return 1;
  }
  if (canonical == "pcma") {
    return 2;
  }
  if (canonical == "pcmu") {
    return 3;
  }
  return -1;
}

static NSString *SfaitCodecLabel(const CodecInfo &codec) {
  const std::string canonical = SfaitCanonicalVoiceCodec(codec.codecId);
  if (canonical == "opus") {
    return @"Opus";
  }
  if (canonical == "g722") {
    return @"G.722 HD";
  }
  if (canonical == "pcma") {
    return @"G.711 A-law (PCMA)";
  }
  if (canonical == "pcmu") {
    return @"G.711 µ-law (PCMU)";
  }
  return SfaitString(codec.codecId);
}

static void SfaitEmit(NSDictionary<NSString *, id> *event) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [gBridge.channel invokeMethod:@"onNativeSoftphoneEvent" arguments:event];
  });
}

static int SfaitParsePjsipDeviceId(const std::string &deviceId) {
  const std::string prefix = "pjsip:";
  if (deviceId.rfind(prefix, 0) == 0) {
    return std::stoi(deviceId.substr(prefix.length()));
  }
  return std::stoi(deviceId);
}

class SfaitPjsipEngine;

class SfaitPjsipCall : public Call {
public:
  SfaitPjsipCall(Account &account, int callId, SfaitPjsipEngine *engine, bool incoming)
      : Call(account, callId), engine_(engine), incoming_(incoming) {}

  void onCallState(OnCallStateParam &prm) override;
  void onCallMediaState(OnCallMediaStateParam &prm) override;

  bool incoming() const { return incoming_; }
  bool established() const { return established_; }
  void setEstablished(bool value) { established_ = value; }

private:
  SfaitPjsipEngine *engine_;
  bool incoming_;
  bool established_ = false;
};

class SfaitPjsipAccount : public Account {
public:
  explicit SfaitPjsipAccount(SfaitPjsipEngine *engine) : engine_(engine) {}

  void onRegState(OnRegStateParam &prm) override;
  void onIncomingCall(OnIncomingCallParam &prm) override;

private:
  SfaitPjsipEngine *engine_;
};

class SfaitPjsipEngine {
public:
  void ensureStarted() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (started_) {
      return;
    }

    endpoint_ = std::make_unique<Endpoint>();
    endpoint_->libCreate();

    EpConfig epConfig;
    epConfig.logConfig.level = 3;
    epConfig.logConfig.consoleLevel = 3;
    epConfig.uaConfig.threadCnt = 1;
    epConfig.medConfig.noVad = true;
    epConfig.medConfig.ecTailLen = 0;
    endpoint_->libInit(epConfig);

    TransportConfig transportConfig;
    transportConfig.port = 0;
    endpoint_->transportCreate(PJSIP_TRANSPORT_UDP, transportConfig);

    endpoint_->libStart();
    started_ = true;
    captureDefaultCodecPriorities();
    applyPreferredCodecPriority();
  }

  NSArray<NSDictionary<NSString *, NSString *> *> *listDevices(bool input) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    ensureStarted();

    NSMutableArray *items = [NSMutableArray array];
    AudioDevInfoVector2 devices = endpoint_->audDevManager().enumDev2();
    for (const AudioDevInfo &device : devices) {
      if (input && device.inputCount == 0) {
        continue;
      }
      if (!input && device.outputCount == 0) {
        continue;
      }

      NSString *label = SfaitCleanDeviceLabel(device.name);
      [items addObject:@{
        @"id" : [NSString stringWithFormat:@"pjsip:%d", device.id],
        @"label" : label
      }];
    }
    return items;
  }

  NSArray<NSDictionary<NSString *, id> *> *listCodecs() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    ensureStarted();

    std::vector<CodecInfo> preferredCodecs;
    std::map<std::string, bool> includedCodecs;
    CodecInfoVector2 codecs = endpoint_->codecEnum2();
    for (const CodecInfo &codec : codecs) {
      const std::string canonical = SfaitCanonicalVoiceCodec(codec.codecId);
      if (codec.codecId.empty() || canonical.empty() ||
          includedCodecs[canonical]) {
        continue;
      }

      includedCodecs[canonical] = true;
      preferredCodecs.push_back(codec);
    }

    std::sort(preferredCodecs.begin(), preferredCodecs.end(),
              [](const CodecInfo &left, const CodecInfo &right) {
                return SfaitPreferredCodecRank(left.codecId) <
                       SfaitPreferredCodecRank(right.codecId);
              });

    NSMutableArray *items = [NSMutableArray array];
    for (const CodecInfo &codec : preferredCodecs) {
      [items addObject:@{
        @"id" : SfaitString(codec.codecId),
        @"label" : SfaitCodecLabel(codec),
        @"priority" : @((int)codec.priority)
      }];
    }
    return items;
  }

  void setPreferredCodec(const std::string &codecId) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    ensureStarted();
    preferredCodecId_ = codecId;
    applyPreferredCodecPriority();
  }

  void setCaptureDevice(const std::string &deviceId) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (deviceId.empty()) {
      return;
    }
    ensureStarted();
    captureDeviceId_ = SfaitParsePjsipDeviceId(deviceId);
    endpoint_->audDevManager().setCaptureDev(captureDeviceId_);
  }

  void setPlaybackDevice(const std::string &deviceId) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (deviceId.empty()) {
      return;
    }
    ensureStarted();
    playbackDeviceId_ = SfaitParsePjsipDeviceId(deviceId);
    endpoint_->audDevManager().setPlaybackDev(playbackDeviceId_);
  }

  void registerAccount(NSDictionary *arguments) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    ensureStarted();

    if (activeCall_) {
      hangup();
    }
    account_.reset();

    domain_ = SfaitStdString(arguments[@"domain"]);
    extension_ = SfaitStdString(arguments[@"extension"]);
    std::string authorizationId = SfaitStdString(arguments[@"authorizationId"]);
    std::string password = SfaitStdString(arguments[@"password"]);
    std::string displayName = SfaitStdString(arguments[@"displayName"]);

    if (domain_.empty() || extension_.empty() || password.empty()) {
      throw std::runtime_error("Configuration SIP incomplète.");
    }
    if (authorizationId.empty()) {
      authorizationId = extension_;
    }
    if (displayName.empty()) {
      displayName = extension_;
    }

    SfaitEmit(@{
      @"status" : @"connecting",
      @"message" : @"Connexion SIP native en cours..."
    });

    AccountConfig config;
    config.idUri = "sip:" + extension_ + "@" + domain_;
    config.regConfig.registrarUri = "sip:" + domain_;
    config.sipConfig.authCreds.push_back(
        AuthCredInfo("digest", "*", authorizationId, 0, password));
    config.natConfig.iceEnabled = false;

    account_ = std::make_unique<SfaitPjsipAccount>(this);
    account_->create(config);
  }

  void disconnect() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (activeCall_) {
      try {
        activeCall_->hangup(CallOpParam());
      } catch (...) {
      }
      activeCall_.reset();
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
    SfaitEmit(@{
      @"status" : @"offline",
      @"message" : @"Softphone déconnecté.",
      @"isMuted" : @NO,
      @"isOnHold" : @NO
    });
  }

  void makeCall(const std::string &destination) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!account_ || !registered_) {
      throw std::runtime_error("Le compte SIP n’est pas encore enregistré.");
    }
    if (destination.empty()) {
      throw std::runtime_error("Destination vide.");
    }

    applySelectedDevices();

    activeCall_ = std::make_unique<SfaitPjsipCall>(*account_, PJSUA_INVALID_ID, this, false);
    CallOpParam param(true);
    activeCall_->makeCall(normalizeTarget(destination), param);
  }

  void answer() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!activeCall_) {
      throw std::runtime_error("Aucun appel entrant à accepter.");
    }
    applySelectedDevices();
    CallOpParam param;
    param.statusCode = PJSIP_SC_OK;
    activeCall_->answer(param);
  }

  void hangup() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!activeCall_) {
      throw std::runtime_error("Aucun appel actif à raccrocher.");
    }
    CallOpParam param;
    activeCall_->hangup(param);
  }

  void toggleMute() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!activeCall_) {
      throw std::runtime_error("Aucun appel actif pour gérer le micro.");
    }
    muted_ = !muted_;
    reconnectMedia();
    SfaitEmit(@{
      @"status" : @"inCall",
      @"message" : muted_ ? @"Micro coupe." : @"Micro reactive.",
      @"remoteIdentity" : currentRemoteIdentity(),
      @"isMuted" : @(muted_),
      @"isOnHold" : @(held_)
    });
  }

  void toggleHold() {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!activeCall_) {
      throw std::runtime_error("Aucun appel actif pour la mise en attente.");
    }
    if (held_) {
      CallOpParam param(true);
      param.opt.flag |= PJSUA_CALL_UNHOLD;
      activeCall_->reinvite(param);
      held_ = false;
    } else {
      CallOpParam param;
      activeCall_->setHold(param);
      held_ = true;
    }
    SfaitEmit(@{
      @"status" : @"inCall",
      @"message" : held_ ? @"Appel mis en attente." : @"Communication reprise.",
      @"remoteIdentity" : currentRemoteIdentity(),
      @"isMuted" : @(muted_),
      @"isOnHold" : @(held_)
    });
  }

  void sendDtmf(const std::string &tone) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!activeCall_) {
      throw std::runtime_error("Aucun appel actif pour envoyer un DTMF.");
    }
    activeCall_->dialDtmf(tone);
  }

  void transfer(const std::string &destination) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!activeCall_) {
      throw std::runtime_error("Aucun appel actif à transférer.");
    }
    activeCall_->xfer(normalizeTarget(destination), CallOpParam());
  }

  void handleRegistration(int code, const std::string &reason) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    registered_ = code >= 200 && code < 300;
    if (registered_) {
      SfaitEmit(@{
        @"status" : @"registered",
        @"message" : [NSString stringWithFormat:@"Compte %@ enregistré et prêt à recevoir des appels.", SfaitString(extension_)],
        @"isMuted" : @NO,
        @"isOnHold" : @NO
      });
    } else {
      NSString *message = [NSString stringWithFormat:@"Enregistrement SIP refuse: %@ (%d)", SfaitString(reason), code];
      SfaitEmit(@{
        @"status" : @"error",
        @"message" : message
      });
    }
  }

  void handleIncomingCall(int callId) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    if (!account_) {
      return;
    }
    activeCall_ = std::make_unique<SfaitPjsipCall>(*account_, callId, this, true);
    NSString *remote = currentRemoteIdentity();
    SfaitEmit(@{
      @"status" : @"ringing",
      @"message" : [NSString stringWithFormat:@"Appel entrant de %@", remote],
      @"remoteIdentity" : remote,
      @"isMuted" : @NO,
      @"isOnHold" : @NO
    });
  }

  void handleCallState(SfaitPjsipCall *call) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    CallInfo info = call->getInfo();
    NSString *remote = SfaitCleanRemote(info.remoteUri);

    switch (info.state) {
      case PJSIP_INV_STATE_CALLING:
      case PJSIP_INV_STATE_CONNECTING:
        SfaitEmit(@{
          @"status" : @"calling",
          @"message" : [NSString stringWithFormat:@"Connexion de l appel vers %@...", remote],
          @"remoteIdentity" : remote,
          @"isMuted" : @(muted_),
          @"isOnHold" : @(held_)
        });
        break;
      case PJSIP_INV_STATE_EARLY:
        SfaitEmit(@{
          @"status" : @"calling",
          @"message" : [NSString stringWithFormat:@"Ca sonne chez %@...", remote],
          @"remoteIdentity" : remote,
          @"isMuted" : @(muted_),
          @"isOnHold" : @(held_)
        });
        break;
      case PJSIP_INV_STATE_CONFIRMED:
        call->setEstablished(true);
        SfaitEmit(@{
          @"status" : @"inCall",
          @"message" : [NSString stringWithFormat:@"Communication active avec %@", remote],
          @"remoteIdentity" : remote,
          @"isMuted" : @(muted_),
          @"isOnHold" : @(held_)
        });
        break;
      case PJSIP_INV_STATE_DISCONNECTED: {
        NSString *summary = call->established() ? @"Appel terminé" : @"Appel manqué ou échoué";
        NSString *direction = call->incoming()
            ? (call->established() ? @"incoming" : @"missed")
            : @"outgoing";
        muted_ = false;
        held_ = false;
        SfaitEmit(@{
          @"status" : registered_ ? @"registered" : @"offline",
          @"message" : @"Appel terminé.",
          @"remoteIdentity" : remote,
          @"historyDirection" : direction,
          @"historySummary" : summary,
          @"isMuted" : @NO,
          @"isOnHold" : @NO
        });
        break;
      }
      default:
        break;
    }
  }

  void handleCallMediaState(SfaitPjsipCall *call) {
    std::lock_guard<std::recursive_mutex> lock(mutex_);
    CallInfo info = call->getInfo();
    bool localHold = false;
    for (const CallMediaInfo &media : info.media) {
      if (media.type == PJMEDIA_TYPE_AUDIO &&
          media.status == PJSUA_CALL_MEDIA_LOCAL_HOLD) {
        localHold = true;
        break;
      }
    }
    held_ = localHold;
    applySelectedDevices();
    reconnectMedia();
    if (info.state == PJSIP_INV_STATE_CONFIRMED) {
      SfaitEmit(@{
        @"status" : @"inCall",
        @"message" : held_ ? @"Appel mis en attente." : @"Communication active.",
        @"remoteIdentity" : currentRemoteIdentity(),
        @"isMuted" : @(muted_),
        @"isOnHold" : @(held_)
      });
    }
  }

private:
  std::string normalizeTarget(const std::string &destination) const {
    if (destination.rfind("sip:", 0) == 0) {
      return destination;
    }
    if (destination.find("@") != std::string::npos) {
      return "sip:" + destination;
    }
    return "sip:" + destination + "@" + domain_;
  }

  void applySelectedDevices() {
    if (captureDeviceId_ >= 0) {
      endpoint_->audDevManager().setCaptureDev(captureDeviceId_);
    }
    if (playbackDeviceId_ >= 0) {
      endpoint_->audDevManager().setPlaybackDev(playbackDeviceId_);
    }
  }

  void captureDefaultCodecPriorities() {
    if (!defaultCodecPriorities_.empty()) {
      return;
    }

    CodecInfoVector2 codecs = endpoint_->codecEnum2();
    for (const CodecInfo &codec : codecs) {
      if (!codec.codecId.empty()) {
        defaultCodecPriorities_[codec.codecId] = codec.priority;
      }
    }
  }

  void applyPreferredCodecPriority() {
    captureDefaultCodecPriorities();
    if (preferredCodecId_.empty()) {
      for (const auto &entry : defaultCodecPriorities_) {
        endpoint_->codecSetPriority(entry.first, entry.second);
      }
      return;
    }

    if (SfaitIsAuxiliaryCodec(preferredCodecId_)) {
      throw std::runtime_error("Codec audio invalide.");
    }
    if (SfaitPreferredCodecRank(preferredCodecId_) < 0) {
      throw std::runtime_error("Codec audio non pris en charge par l'application.");
    }

    bool found = false;
    for (const auto &entry : defaultCodecPriorities_) {
      if (SfaitIsAuxiliaryCodec(entry.first)) {
        endpoint_->codecSetPriority(entry.first, entry.second);
      } else if (entry.first == preferredCodecId_) {
        endpoint_->codecSetPriority(entry.first, 255);
        found = true;
      } else {
        endpoint_->codecSetPriority(entry.first, 0);
      }
    }

    if (!found) {
      throw std::runtime_error("Codec audio introuvable.");
    }
  }

  void reconnectMedia() {
    if (!activeCall_) {
      return;
    }
    CallInfo info = activeCall_->getInfo();
    for (unsigned i = 0; i < info.media.size(); i++) {
      const CallMediaInfo &media = info.media[i];
      if (media.type != PJMEDIA_TYPE_AUDIO) {
        continue;
      }
      if (media.status != PJSUA_CALL_MEDIA_ACTIVE &&
          media.status != PJSUA_CALL_MEDIA_REMOTE_HOLD) {
        continue;
      }

      AudioMedia callMedia = activeCall_->getAudioMedia(i);
      try {
        endpoint_->audDevManager().getCaptureDevMedia().stopTransmit(callMedia);
      } catch (...) {
      }
      try {
        callMedia.stopTransmit(endpoint_->audDevManager().getPlaybackDevMedia());
      } catch (...) {
      }
      if (!muted_) {
        endpoint_->audDevManager().getCaptureDevMedia().startTransmit(callMedia);
      }
      callMedia.startTransmit(endpoint_->audDevManager().getPlaybackDevMedia());
    }
  }

  NSString *currentRemoteIdentity() {
    if (!activeCall_) {
      return @"Inconnu";
    }
    try {
      CallInfo info = activeCall_->getInfo();
      return SfaitCleanRemote(info.remoteUri);
    } catch (...) {
      return @"Inconnu";
    }
  }

  std::recursive_mutex mutex_;
  std::unique_ptr<Endpoint> endpoint_;
  std::unique_ptr<SfaitPjsipAccount> account_;
  std::unique_ptr<SfaitPjsipCall> activeCall_;
  std::string domain_;
  std::string extension_;
  bool started_ = false;
  bool registered_ = false;
  bool muted_ = false;
  bool held_ = false;
  int captureDeviceId_ = -1;
  int playbackDeviceId_ = -1;
  std::string preferredCodecId_;
  std::map<std::string, pj_uint8_t> defaultCodecPriorities_;
};

static SfaitPjsipEngine gEngine;

void SfaitPjsipAccount::onRegState(OnRegStateParam &prm) {
  AccountInfo info = getInfo();
  engine_->handleRegistration(prm.code, info.regStatusText);
}

void SfaitPjsipAccount::onIncomingCall(OnIncomingCallParam &prm) {
  engine_->handleIncomingCall(prm.callId);
}

void SfaitPjsipCall::onCallState(OnCallStateParam &prm) {
  engine_->handleCallState(this);
}

void SfaitPjsipCall::onCallMediaState(OnCallMediaStateParam &prm) {
  engine_->handleCallMediaState(this);
}

@implementation SfaitPjsipBridge

+ (instancetype)shared {
  static SfaitPjsipBridge *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[SfaitPjsipBridge alloc] init];
    gBridge = sharedInstance;
  });
  return sharedInstance;
}

- (void)configureWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger {
  self.channel = [FlutterMethodChannel methodChannelWithName:@"sfait/native_softphone"
                                             binaryMessenger:messenger];

  __weak typeof(self) weakSelf = self;
  [self.channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    __strong typeof(weakSelf) self = weakSelf;
    if (!self) {
      result([FlutterError errorWithCode:@"bridge_unavailable"
                                 message:@"Pont PJSIP indisponible."
                                 details:nil]);
      return;
    }

    try {
      NSDictionary *arguments = [call.arguments isKindOfClass:[NSDictionary class]]
          ? (NSDictionary *)call.arguments
          : @{};

      if ([call.method isEqualToString:@"listAudioInputs"]) {
        result(gEngine.listDevices(true));
      } else if ([call.method isEqualToString:@"listAudioOutputs"]) {
        result(gEngine.listDevices(false));
      } else if ([call.method isEqualToString:@"listCodecs"]) {
        result(gEngine.listCodecs());
      } else if ([call.method isEqualToString:@"setAudioInput"]) {
        gEngine.setCaptureDevice(SfaitStdString(arguments[@"deviceId"]));
        result(nil);
      } else if ([call.method isEqualToString:@"setAudioOutput"]) {
        gEngine.setPlaybackDevice(SfaitStdString(arguments[@"deviceId"]));
        result(nil);
      } else if ([call.method isEqualToString:@"setPreferredCodec"]) {
        gEngine.setPreferredCodec(SfaitStdString(arguments[@"codecId"]));
        result(nil);
      } else if ([call.method isEqualToString:@"register"]) {
        gEngine.registerAccount(arguments);
        result(nil);
      } else if ([call.method isEqualToString:@"disconnect"]) {
        gEngine.disconnect();
        result(nil);
      } else if ([call.method isEqualToString:@"makeCall"]) {
        gEngine.makeCall(SfaitStdString(arguments[@"destination"]));
        result(nil);
      } else if ([call.method isEqualToString:@"answer"]) {
        gEngine.answer();
        result(nil);
      } else if ([call.method isEqualToString:@"hangup"]) {
        gEngine.hangup();
        result(nil);
      } else if ([call.method isEqualToString:@"toggleMute"]) {
        gEngine.toggleMute();
        result(nil);
      } else if ([call.method isEqualToString:@"toggleHold"]) {
        gEngine.toggleHold();
        result(nil);
      } else if ([call.method isEqualToString:@"sendDtmf"]) {
        gEngine.sendDtmf(SfaitStdString(arguments[@"tone"]));
        result(nil);
      } else if ([call.method isEqualToString:@"transfer"]) {
        gEngine.transfer(SfaitStdString(arguments[@"destination"]));
        result(nil);
      } else {
        result(FlutterMethodNotImplemented);
      }
    } catch (const Error &error) {
      result([FlutterError errorWithCode:@"native_softphone_error"
                                 message:SfaitString(error.reason)
                                 details:nil]);
    } catch (const std::exception &error) {
      result([FlutterError errorWithCode:@"native_softphone_error"
                                 message:SfaitString(error.what())
                                 details:nil]);
    } catch (...) {
      result([FlutterError errorWithCode:@"native_softphone_error"
                                 message:@"Erreur native inconnue."
                                 details:nil]);
    }
  }];
}

@end
