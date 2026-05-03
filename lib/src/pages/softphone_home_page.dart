import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/app_update.dart';
import '../models/audio_device_option.dart';
import '../models/call_log_entry.dart';
import '../models/codec_option.dart';
import '../models/general_settings.dart';
import '../models/privacy_permission_status.dart';
import '../models/sip_account.dart';
import '../models/softphone_status.dart';
import '../viewmodels/softphone_controller.dart';
import '../widgets/dialpad.dart';
import '../widgets/status_chip.dart';

class SoftphoneHomePage extends StatefulWidget {
  const SoftphoneHomePage({super.key});

  @override
  State<SoftphoneHomePage> createState() => _SoftphoneHomePageState();
}

class _SoftphoneHomePageState extends State<SoftphoneHomePage> {
  late final TextEditingController _domainController;
  late final TextEditingController _extensionController;
  late final TextEditingController _authController;
  late final TextEditingController _passwordController;
  late final TextEditingController _displayNameController;
  late final TextEditingController _destinationController;
  late final TextEditingController _transferController;

  int _tabIndex = 0;
  bool _showTransferPanel = false;
  String? _promptedUpdateTag;

  @override
  void initState() {
    super.initState();
    _domainController = TextEditingController();
    _extensionController = TextEditingController();
    _authController = TextEditingController();
    _passwordController = TextEditingController();
    _displayNameController = TextEditingController();
    _destinationController = TextEditingController();
    _transferController = TextEditingController();
  }

  @override
  void dispose() {
    _domainController.dispose();
    _extensionController.dispose();
    _authController.dispose();
    _passwordController.dispose();
    _displayNameController.dispose();
    _destinationController.dispose();
    _transferController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Consumer<SoftphoneController>(
      builder: (context, controller, _) {
        _hydrateFields(controller.account, controller.destination);
        _scheduleUpdatePrompt(controller);
        final showCallOverlay = controller.ringing;
        if (!controller.inCall && _showTransferPanel) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _showTransferPanel) {
              _cancelTransferPanel();
            }
          });
        }

        return Scaffold(
          body: SafeArea(
            bottom: false,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'SFAIT Softphone',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          StatusChip(status: controller.status),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          child: showCallOverlay
                              ? const SizedBox.expand(
                                  key: ValueKey('call-overlay-background'),
                                )
                              : switch (_tabIndex) {
                                  0 => _DialerTab(
                                      key: const ValueKey('dialer'),
                                      destinationController:
                                          _destinationController,
                                      status: controller.status,
                                      statusMessage: controller.statusMessage,
                                      account: controller.account,
                                      activeRemoteIdentity:
                                          controller.activeRemoteIdentity,
                                      canPlaceCall: controller.canPlaceCall,
                                      canHangup: controller.canHangup,
                                      canToggleMute: controller.canToggleMute,
                                      canToggleHold: controller.canToggleHold,
                                      canTransfer: controller.canTransfer,
                                      isMuted: controller.isMuted,
                                      isOnHold: controller.isOnHold,
                                      onDigit: controller.handleDigit,
                                      onDestinationChanged:
                                          controller.setDestination,
                                      onEraseLastDigit:
                                          controller.eraseLastDigit,
                                      onClearDestination:
                                          controller.clearDestination,
                                      onCall: controller.placeCall,
                                      onHangup: () async {
                                        _cancelTransferPanel();
                                        await controller.hangup();
                                      },
                                      onToggleMute: controller.toggleMute,
                                      onToggleHold: controller.toggleHold,
                                      transferController: _transferController,
                                      showTransferPanel: _showTransferPanel,
                                      onShowTransferPanel: _openTransferPanel,
                                      onCancelTransfer: _cancelTransferPanel,
                                      onSubmitTransfer: () =>
                                          _submitTransfer(controller),
                                    ),
                                  1 => _HistoryTab(
                                      key: const ValueKey('history'),
                                      history: controller.history,
                                      canRecall: controller.isRegistered &&
                                          !controller.calling &&
                                          !controller.ringing &&
                                          !controller.inCall,
                                      onRecall: (remoteIdentity) =>
                                          _recallFromHistory(
                                        controller,
                                        remoteIdentity,
                                      ),
                                      onClearHistory: controller.clearHistory,
                                    ),
                                  _ => _SettingsTab(
                                      key: const ValueKey('settings'),
                                      domainController: _domainController,
                                      extensionController: _extensionController,
                                      authController: _authController,
                                      passwordController: _passwordController,
                                      displayNameController:
                                          _displayNameController,
                                      account: controller.account,
                                      status: controller.status,
                                      settingsStatusMessage:
                                          controller.settingsStatusMessage,
                                      generalSettings:
                                          controller.generalSettings,
                                      audioInputs: controller.audioInputs,
                                      audioOutputs: controller.audioOutputs,
                                      ringtoneOutputs:
                                          controller.ringtoneOutputs,
                                      audioCodecs: controller.audioCodecs,
                                      privacyPermissions:
                                          controller.privacyPermissions,
                                      onThemeChanged:
                                          controller.updateThemePreference,
                                      onLaunchAtStartupChanged:
                                          controller.updateLaunchAtStartup,
                                      onMenuBarIconChanged: controller
                                          .updateMenuBarIconVisibility,
                                      onDockIconChanged:
                                          controller.updateDockIconVisibility,
                                      onAudioInputChanged:
                                          controller.updateAudioInput,
                                      onAudioOutputChanged:
                                          controller.updateAudioOutput,
                                      onRingtoneOutputChanged:
                                          controller.updateRingtoneOutput,
                                      onRingtoneVolumeChanged:
                                          controller.updateRingtoneVolume,
                                      onImportCustomRingtone:
                                          controller.importCustomRingtone,
                                      onRefreshPrivacyPermissions:
                                          controller.refreshPrivacyPermissions,
                                      onOpenPrivacyPermissionSettings:
                                          controller
                                              .openPrivacyPermissionSettings,
                                      onSaveAndConnect: (preferredCodecId) =>
                                          controller.saveAndConnect(
                                        _buildAccount(),
                                        preferredCodecId: preferredCodecId,
                                      ),
                                    ),
                                },
                        ),
                      ),
                    ],
                  ),
                ),
                if (showCallOverlay)
                  Positioned.fill(
                    bottom: 84,
                    child: _CallOverlay(
                      status: controller.status,
                      activeRemoteIdentity: controller.activeRemoteIdentity,
                      statusMessage: controller.statusMessage,
                      canToggleMute: controller.canToggleMute,
                      canToggleHold: controller.canToggleHold,
                      canTransfer: controller.canTransfer,
                      isMuted: controller.isMuted,
                      isOnHold: controller.isOnHold,
                      onDigit: controller.handleDigit,
                      onAnswer: () async {
                        setState(() => _tabIndex = 0);
                        await controller.answer();
                      },
                      onHangup: () async {
                        _cancelTransferPanel();
                        await controller.hangup();
                      },
                      onToggleMute: controller.toggleMute,
                      onToggleHold: controller.toggleHold,
                      transferController: _transferController,
                      showTransferPanel: _showTransferPanel,
                      onShowTransferPanel: _openTransferPanel,
                      onCancelTransfer: _cancelTransferPanel,
                      onSubmitTransfer: () => _submitTransfer(controller),
                    ),
                  ),
                if (controller.isInstallingUpdate)
                  Positioned.fill(
                    child: _UpdateInstallOverlay(
                      message: controller.updateStatusMessage,
                      progress: controller.updateDownloadProgress,
                    ),
                  ),
              ],
            ),
          ),
          bottomNavigationBar: _BottomGlassNav(
            currentIndex: _tabIndex,
            onSelected: (index) => setState(() => _tabIndex = index),
          ),
        );
      },
    );
  }

  void _scheduleUpdatePrompt(SoftphoneController controller) {
    final update = controller.availableUpdate;
    if (update == null ||
        controller.isInstallingUpdate ||
        _promptedUpdateTag == update.tagName) {
      return;
    }

    _promptedUpdateTag = update.tagName;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || controller.availableUpdate?.tagName != update.tagName) {
        return;
      }
      _showUpdateDialog(controller, update);
    });
  }

  Future<void> _showUpdateDialog(
    SoftphoneController controller,
    AppUpdateInfo update,
  ) async {
    final notes = update.releaseNotes.trim();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text('Mise à jour ${update.version} disponible'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SFAIT Softphone peut télécharger et installer cette version automatiquement.',
                style: theme.textTheme.bodyMedium,
              ),
              if (notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: SingleChildScrollView(
                    child: Text(
                      notes,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                controller.dismissAvailableUpdate();
                Navigator.of(context).pop();
              },
              child: const Text('Plus tard'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(context).pop();
                unawaited(controller.installAvailableUpdate());
              },
              child: const Text('Mettre à jour'),
            ),
          ],
        );
      },
    );
  }

  void _openTransferPanel() {
    if (_showTransferPanel) {
      return;
    }

    setState(() {
      _transferController.clear();
      _showTransferPanel = true;
    });
  }

  void _cancelTransferPanel() {
    if (!_showTransferPanel && _transferController.text.isEmpty) {
      return;
    }

    setState(() {
      _showTransferPanel = false;
      _transferController.clear();
    });
  }

  Future<void> _submitTransfer(SoftphoneController controller) async {
    final destination = _transferController.text.trim();
    if (destination.isEmpty) {
      return;
    }

    setState(() {
      _showTransferPanel = false;
      _transferController.clear();
    });
    await controller.transfer(destination);
  }

  Future<void> _recallFromHistory(
    SoftphoneController controller,
    String remoteIdentity,
  ) async {
    final destination = remoteIdentity.trim();
    if (destination.isEmpty) {
      return;
    }

    controller.setDestination(destination);
    setState(() => _tabIndex = 0);

    if (controller.isRegistered &&
        !controller.calling &&
        !controller.ringing &&
        !controller.inCall) {
      await controller.placeCall();
    }
  }

  void _hydrateFields(SipAccount account, String destination) {
    if (_domainController.text != account.domain) {
      _domainController.text = account.domain;
    }
    if (_extensionController.text != account.extension) {
      _extensionController.text = account.extension;
    }
    if (_authController.text != account.authorizationId) {
      _authController.text = account.authorizationId;
    }
    if (_passwordController.text != account.password) {
      _passwordController.text = account.password;
    }
    if (_displayNameController.text != account.displayName) {
      _displayNameController.text = account.displayName;
    }
    if (_destinationController.text != destination) {
      _destinationController.text = destination;
    }
  }

  SipAccount _buildAccount() {
    return SipAccount(
      label: 'Compte principal',
      domain: _domainController.text.trim(),
      extension: _extensionController.text.trim(),
      authorizationId: _authController.text.trim(),
      password: _passwordController.text,
      displayName: _displayNameController.text.trim(),
    );
  }
}

class _DialerTab extends StatelessWidget {
  const _DialerTab({
    super.key,
    required this.destinationController,
    required this.status,
    required this.statusMessage,
    required this.account,
    required this.activeRemoteIdentity,
    required this.canPlaceCall,
    required this.canHangup,
    required this.canToggleMute,
    required this.canToggleHold,
    required this.canTransfer,
    required this.isMuted,
    required this.isOnHold,
    required this.onDigit,
    required this.onDestinationChanged,
    required this.onEraseLastDigit,
    required this.onClearDestination,
    required this.onCall,
    required this.onHangup,
    required this.onToggleMute,
    required this.onToggleHold,
    required this.transferController,
    required this.showTransferPanel,
    required this.onShowTransferPanel,
    required this.onCancelTransfer,
    required this.onSubmitTransfer,
  });

  final TextEditingController destinationController;
  final SoftphoneConnectionStatus status;
  final String statusMessage;
  final SipAccount account;
  final String activeRemoteIdentity;
  final bool canPlaceCall;
  final bool canHangup;
  final bool canToggleMute;
  final bool canToggleHold;
  final bool canTransfer;
  final bool isMuted;
  final bool isOnHold;
  final ValueChanged<String> onDigit;
  final ValueChanged<String> onDestinationChanged;
  final VoidCallback onEraseLastDigit;
  final VoidCallback onClearDestination;
  final Future<void> Function() onCall;
  final Future<void> Function() onHangup;
  final Future<void> Function() onToggleMute;
  final Future<void> Function() onToggleHold;
  final TextEditingController transferController;
  final bool showTransferPanel;
  final VoidCallback onShowTransferPanel;
  final VoidCallback onCancelTransfer;
  final Future<void> Function() onSubmitTransfer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCalling = status == SoftphoneConnectionStatus.calling;
    final isRinging = status == SoftphoneConnectionStatus.ringing;
    final inCall = status == SoftphoneConnectionStatus.inCall;
    final hasLiveCall = isCalling || isRinging || inCall;
    final liveLabel = !hasLiveCall || activeRemoteIdentity.isEmpty
        ? 'Aucune session active'
        : activeRemoteIdentity;

    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.9),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withOpacity(0.45),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                liveLabel,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                account.extension.isEmpty
                    ? statusMessage
                    : 'Poste ${account.extension} • ${account.domain}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: destinationController,
          onChanged: onDestinationChanged,
          decoration: InputDecoration(
            isDense: true,
            labelText: 'Destination',
            hintText: '1000 ou sip:1000@pbx.sfait.fr',
            prefixIcon: const Icon(Icons.dialpad_outlined),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 0,
              minHeight: 0,
            ),
            suffixIcon: destinationController.text.isEmpty
                ? null
                : Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: onEraseLastDigit,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            child: Text(
                              'Effacer',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Text(
                            '|',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        InkWell(
                          borderRadius: BorderRadius.circular(999),
                          onTap: onClearDestination,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.close,
                              size: 18,
                              color: Theme.of(context)
                                  .colorScheme
                                  .onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final dialpadHeight = math.min(300.0, constraints.maxHeight);
              return Align(
                alignment: Alignment.topCenter,
                child: Dialpad(
                  onDigit: onDigit,
                  compact: true,
                  height: dialpadHeight,
                  digitFontSize: 34,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: hasLiveCall
                    ? (canHangup ? onHangup : null)
                    : (canPlaceCall ? onCall : null),
                icon: Icon(
                  hasLiveCall ? Icons.call_end : Icons.call,
                  size: 18,
                ),
                label: Text(hasLiveCall ? 'Raccrocher' : 'Appeler'),
                style: hasLiveCall
                    ? FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      )
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canTransfer ? onShowTransferPanel : null,
                icon: const Icon(Icons.swap_calls, size: 18),
                label: const Text('Transférer'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canToggleHold ? onToggleHold : null,
                icon: Icon(
                  isOnHold ? Icons.play_arrow : Icons.pause_circle_outline,
                  size: 18,
                ),
                label: Text(isOnHold ? 'Reprendre' : 'Attente'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: canToggleMute ? onToggleMute : null,
          icon: Icon(isMuted ? Icons.mic_off : Icons.mic, size: 18),
          label: Text(isMuted ? 'Réactiver le micro' : 'Couper le micro'),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: showTransferPanel && canTransfer
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _TransferInlinePanel(
                    controller: transferController,
                    onCancel: onCancelTransfer,
                    onSubmit: onSubmitTransfer,
                  ),
                )
              : const SizedBox.shrink(),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 18,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              isCalling
                  ? 'Mise en relation en cours...'
                  : inCall
                      ? isOnHold
                          ? 'Communication en attente.'
                          : isMuted
                              ? 'Communication active. Micro coupé.'
                              : 'Communication active.'
                      : isRinging
                          ? 'Appel entrant en plein écran.'
                          : statusMessage,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ),
      ],
    );
  }
}

class _CallOverlay extends StatelessWidget {
  const _CallOverlay({
    required this.status,
    required this.activeRemoteIdentity,
    required this.statusMessage,
    required this.canToggleMute,
    required this.canToggleHold,
    required this.canTransfer,
    required this.isMuted,
    required this.isOnHold,
    required this.onDigit,
    required this.onAnswer,
    required this.onHangup,
    required this.onToggleMute,
    required this.onToggleHold,
    required this.transferController,
    required this.showTransferPanel,
    required this.onShowTransferPanel,
    required this.onCancelTransfer,
    required this.onSubmitTransfer,
  });

  final SoftphoneConnectionStatus status;
  final String activeRemoteIdentity;
  final String statusMessage;
  final bool canToggleMute;
  final bool canToggleHold;
  final bool canTransfer;
  final bool isMuted;
  final bool isOnHold;
  final ValueChanged<String> onDigit;
  final Future<void> Function() onAnswer;
  final Future<void> Function() onHangup;
  final Future<void> Function() onToggleMute;
  final Future<void> Function() onToggleHold;
  final TextEditingController transferController;
  final bool showTransferPanel;
  final VoidCallback onShowTransferPanel;
  final VoidCallback onCancelTransfer;
  final Future<void> Function() onSubmitTransfer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final caller = activeRemoteIdentity.isEmpty
        ? 'Correspondant inconnu'
        : activeRemoteIdentity;
    final isRinging = status == SoftphoneConnectionStatus.ringing;
    final inCall = status == SoftphoneConnectionStatus.inCall;

    return ColoredBox(
      color: theme.colorScheme.surface.withOpacity(0.98),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final dialpadHeight =
                math.max(180.0, math.min(236.0, constraints.maxHeight - 312));

            return Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      color: theme.colorScheme.surfaceContainerHighest,
                      border: Border.all(
                        color:
                            theme.colorScheme.outlineVariant.withOpacity(0.35),
                      ),
                    ),
                    child: Column(
                      children: [
                        Icon(
                          isRinging ? Icons.call : Icons.phone_in_talk,
                          size: 30,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          isRinging
                              ? 'Appel entrant'
                              : 'Communication en cours',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          caller,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          statusMessage,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (isRinging) ...[
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.tonalIcon(
                            onPressed: onHangup,
                            icon: const Icon(Icons.call_end),
                            label: const Text('Décliner'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: onAnswer,
                            icon: const Icon(Icons.call),
                            label: const Text('Décrocher'),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                  ] else if (inCall) ...[
                    Dialpad(
                      onDigit: onDigit,
                      compact: true,
                      height: dialpadHeight,
                      digitFontSize: 34,
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: onHangup,
                      icon: const Icon(Icons.call_end),
                      label: const Text('Raccrocher'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(40),
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: canTransfer ? onShowTransferPanel : null,
                            icon: const Icon(Icons.swap_calls),
                            label: const Text('Transférer'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(36),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: canToggleHold ? onToggleHold : null,
                            icon: Icon(
                              isOnHold
                                  ? Icons.play_arrow_rounded
                                  : Icons.pause_circle_outline,
                            ),
                            label: Text(isOnHold ? 'Reprendre' : 'Attente'),
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(36),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    OutlinedButton.icon(
                      onPressed: canToggleMute ? onToggleMute : null,
                      icon: Icon(isMuted ? Icons.mic_off : Icons.mic),
                      label: Text(
                        isMuted ? 'Réactiver le micro' : 'Couper le micro',
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(36),
                      ),
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      child: showTransferPanel && canTransfer
                          ? Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: _TransferInlinePanel(
                                controller: transferController,
                                onCancel: onCancelTransfer,
                                onSubmit: onSubmitTransfer,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _UpdateInstallOverlay extends StatelessWidget {
  const _UpdateInstallOverlay({
    required this.message,
    required this.progress,
  });

  final String message;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
      ),
      child: Center(
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.system_update_alt,
                  color: scheme.primary,
                  size: 34,
                ),
                const SizedBox(height: 14),
                Text(
                  message.isEmpty ? 'Mise à jour en cours...' : message,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 16),
                LinearProgressIndicator(value: progress),
                const SizedBox(height: 10),
                Text(
                  progress == null
                      ? 'Préparation de l’installation automatique.'
                      : '${(progress!.clamp(0.0, 1.0) * 100).round()} %',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TransferInlinePanel extends StatelessWidget {
  const _TransferInlinePanel({
    required this.controller,
    required this.onCancel,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final VoidCallback onCancel;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.82),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withOpacity(0.45),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                onSubmit();
              },
              decoration: const InputDecoration(
                isDense: true,
                labelText: 'Transférer vers',
                hintText: '102 ou 0612345678',
                prefixIcon: Icon(Icons.swap_calls),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: 'Annuler',
            child: IconButton.outlined(
              onPressed: onCancel,
              icon: const Icon(Icons.close),
            ),
          ),
          const SizedBox(width: 6),
          Tooltip(
            message: 'Transférer',
            child: IconButton.filled(
              onPressed: () {
                onSubmit();
              },
              icon: const Icon(Icons.check),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryTab extends StatelessWidget {
  const _HistoryTab({
    super.key,
    required this.history,
    required this.canRecall,
    required this.onRecall,
    required this.onClearHistory,
  });

  final List<CallLogEntry> history;
  final bool canRecall;
  final Future<void> Function(String remoteIdentity) onRecall;
  final Future<void> Function() onClearHistory;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: Theme.of(context).colorScheme.surface.withOpacity(0.72),
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant.withOpacity(0.28),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Journal d’appel',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              TextButton.icon(
                onPressed: history.isEmpty ? null : onClearHistory,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Vider'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: history.isEmpty
                ? const Center(
                    child: Text('Aucun appel pour le moment.'),
                  )
                : ListView.separated(
                    itemCount: history.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final entry = history[index];
                      final icon = switch (entry.direction) {
                        CallDirection.incoming => Icons.call_received,
                        CallDirection.outgoing => Icons.call_made,
                        CallDirection.missed => Icons.call_missed,
                      };
                      final formattedDate =
                          '${entry.at.day.toString().padLeft(2, '0')}/${entry.at.month.toString().padLeft(2, '0')} ${entry.at.hour.toString().padLeft(2, '0')}:${entry.at.minute.toString().padLeft(2, '0')}';
                      return ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 4),
                        leading: Icon(icon, size: 18),
                        title: Text(
                          entry.remoteIdentity,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(_localizedCallSummary(entry.summary)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              formattedDate,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                            const SizedBox(width: 8),
                            Tooltip(
                              message: canRecall
                                  ? 'Rappeler'
                                  : 'Rappel indisponible',
                              child: IconButton(
                                visualDensity: VisualDensity.compact,
                                onPressed: canRecall
                                    ? () => onRecall(entry.remoteIdentity)
                                    : null,
                                icon: const Icon(Icons.call_outlined),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  String _localizedCallSummary(String summary) {
    return switch (summary.trim().toLowerCase()) {
      'appel termine' || 'appel termine.' => 'Appel terminé',
      'appel manque ou echoue' ||
      'appel manque ou echoue.' =>
        'Appel manqué ou échoué',
      _ => summary,
    };
  }
}

class _SettingsTab extends StatefulWidget {
  const _SettingsTab({
    super.key,
    required this.domainController,
    required this.extensionController,
    required this.authController,
    required this.passwordController,
    required this.displayNameController,
    required this.account,
    required this.status,
    required this.settingsStatusMessage,
    required this.generalSettings,
    required this.audioInputs,
    required this.audioOutputs,
    required this.ringtoneOutputs,
    required this.audioCodecs,
    required this.privacyPermissions,
    required this.onThemeChanged,
    required this.onLaunchAtStartupChanged,
    required this.onMenuBarIconChanged,
    required this.onDockIconChanged,
    required this.onAudioInputChanged,
    required this.onAudioOutputChanged,
    required this.onRingtoneOutputChanged,
    required this.onRingtoneVolumeChanged,
    required this.onImportCustomRingtone,
    required this.onRefreshPrivacyPermissions,
    required this.onOpenPrivacyPermissionSettings,
    required this.onSaveAndConnect,
  });

  final TextEditingController domainController;
  final TextEditingController extensionController;
  final TextEditingController authController;
  final TextEditingController passwordController;
  final TextEditingController displayNameController;
  final SipAccount account;
  final SoftphoneConnectionStatus status;
  final String settingsStatusMessage;
  final GeneralSettings generalSettings;
  final List<AudioDeviceOption> audioInputs;
  final List<AudioDeviceOption> audioOutputs;
  final List<AudioDeviceOption> ringtoneOutputs;
  final List<CodecOption> audioCodecs;
  final List<PrivacyPermissionStatus> privacyPermissions;
  final Future<void> Function(AppThemePreference preference) onThemeChanged;
  final Future<void> Function(bool enabled) onLaunchAtStartupChanged;
  final Future<void> Function(bool enabled) onMenuBarIconChanged;
  final Future<void> Function(bool enabled) onDockIconChanged;
  final Future<void> Function(String deviceId) onAudioInputChanged;
  final Future<void> Function(String deviceId) onAudioOutputChanged;
  final Future<void> Function(String deviceId) onRingtoneOutputChanged;
  final Future<void> Function(double volume) onRingtoneVolumeChanged;
  final Future<void> Function() onImportCustomRingtone;
  final Future<void> Function() onRefreshPrivacyPermissions;
  final Future<void> Function(PrivacyPermissionKind kind)
      onOpenPrivacyPermissionSettings;
  final Future<void> Function(String preferredCodecId) onSaveAndConnect;

  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  int _sectionIndex = 0;
  late String _pendingCodecId;

  List<TextEditingController> get _pbxControllers => [
        widget.domainController,
        widget.extensionController,
        widget.authController,
        widget.passwordController,
        widget.displayNameController,
      ];

  @override
  void initState() {
    super.initState();
    _pendingCodecId = widget.generalSettings.preferredCodecId;
    for (final controller in _pbxControllers) {
      controller.addListener(_handlePbxFormChanged);
    }
  }

  @override
  void didUpdateWidget(covariant _SettingsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldControllers = [
      oldWidget.domainController,
      oldWidget.extensionController,
      oldWidget.authController,
      oldWidget.passwordController,
      oldWidget.displayNameController,
    ];
    final nextControllers = _pbxControllers;
    for (var index = 0; index < nextControllers.length; index++) {
      if (oldControllers[index] != nextControllers[index]) {
        oldControllers[index].removeListener(_handlePbxFormChanged);
        nextControllers[index].addListener(_handlePbxFormChanged);
      }
    }

    if (oldWidget.generalSettings.preferredCodecId !=
        widget.generalSettings.preferredCodecId) {
      _pendingCodecId = widget.generalSettings.preferredCodecId;
    }
    if (_pendingCodecId.isNotEmpty &&
        !widget.audioCodecs.any((codec) => codec.id == _pendingCodecId)) {
      _pendingCodecId = '';
    }
  }

  @override
  void dispose() {
    for (final controller in _pbxControllers) {
      controller.removeListener(_handlePbxFormChanged);
    }
    super.dispose();
  }

  void _handlePbxFormChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isCallActive = widget.status == SoftphoneConnectionStatus.inCall ||
        widget.status == SoftphoneConnectionStatus.calling ||
        widget.status == SoftphoneConnectionStatus.ringing;
    final selectedInput = widget.audioInputs.any(
      (device) => device.id == widget.generalSettings.audioInputId,
    )
        ? widget.generalSettings.audioInputId
        : null;
    final selectedOutput = widget.audioOutputs.any(
      (device) => device.id == widget.generalSettings.audioOutputId,
    )
        ? widget.generalSettings.audioOutputId
        : null;
    final selectedRingtoneOutput = widget.ringtoneOutputs.any(
      (device) => device.id == widget.generalSettings.ringtoneOutputId,
    )
        ? widget.generalSettings.ringtoneOutputId
        : null;
    final selectedCodec = widget.audioCodecs.any(
      (codec) => codec.id == _pendingCodecId,
    )
        ? _pendingCodecId
        : '';
    final hasPbxChanges = _hasPbxChanges(selectedCodec);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: theme.colorScheme.surface.withOpacity(0.76),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withOpacity(0.26),
        ),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Réglages',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 10),
              _MacSettingsToolbar<int>(
                value: _sectionIndex,
                items: const [
                  (0, Icons.settings_outlined, 'Général'),
                  (1, Icons.alternate_email_rounded, 'PBX'),
                  (2, Icons.privacy_tip_outlined, 'Confidentialité'),
                ],
                onChanged: (value) {
                  setState(() => _sectionIndex = value);
                },
              ),
              const SizedBox(height: 12),
              if (isCallActive)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 12),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color:
                        theme.colorScheme.surfaceContainerHighest.withOpacity(
                      0.8,
                    ),
                  ),
                  child: Text(
                    'Vous ne pouvez pas modifier les paramètres pendant un appel.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              Expanded(
                child: AbsorbPointer(
                  absorbing: isCallActive,
                  child: Opacity(
                    opacity: isCallActive ? 0.48 : 1,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      layoutBuilder: (currentChild, previousChildren) {
                        return Stack(
                          alignment: Alignment.topCenter,
                          children: [
                            ...previousChildren,
                            if (currentChild != null) currentChild,
                          ],
                        );
                      },
                      child: switch (_sectionIndex) {
                        0 => _buildGeneralSection(
                            context,
                            selectedInput: selectedInput,
                            selectedOutput: selectedOutput,
                            selectedRingtoneOutput: selectedRingtoneOutput,
                          ),
                        1 => _buildPbxSection(
                            selectedCodec: selectedCodec,
                            isCallActive: isCallActive,
                          ),
                        _ => _PrivacySettingsSection(
                            key: const ValueKey('privacy-section'),
                            permissions: widget.privacyPermissions,
                            onRefresh: widget.onRefreshPrivacyPermissions,
                            onOpenSettings:
                                widget.onOpenPrivacyPermissionSettings,
                          ),
                      },
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_sectionIndex == 1)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: isCallActive ||
                            widget.status ==
                                SoftphoneConnectionStatus.connecting ||
                            !hasPbxChanges
                        ? null
                        : () => widget.onSaveAndConnect(selectedCodec),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Appliquer'),
                  ),
                ),
            ],
          ),
          if (!isCallActive && widget.settingsStatusMessage.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: _sectionIndex == 1 ? 54 : 0,
              child: _SettingsStatusToast(
                message: widget.settingsStatusMessage,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildGeneralSection(
    BuildContext context, {
    required String? selectedInput,
    required String? selectedOutput,
    required String? selectedRingtoneOutput,
  }) {
    final theme = Theme.of(context);
    final ringtoneVolume = widget.generalSettings.ringtoneVolume;

    return SingleChildScrollView(
      key: const ValueKey('general-section'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          _MacSettingsGroup(
            title: 'Application',
            children: [
              _MacSettingsRow(
                label: 'Barre de menus',
                child: _MacSwitch(
                  value: widget.generalSettings.showMenuBarIcon,
                  onChanged: widget.onMenuBarIconChanged,
                ),
              ),
              _MacSettingsRow(
                label: 'Dock',
                child: _MacSwitch(
                  value: widget.generalSettings.showDockIcon,
                  onChanged: widget.onDockIconChanged,
                ),
              ),
              _MacSettingsRow(
                label: 'Au démarrage',
                child: _MacSwitch(
                  value: widget.generalSettings.launchAtStartup,
                  onChanged: widget.onLaunchAtStartupChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _MacSettingsGroup(
            title: 'Apparence',
            children: [
              _MacSettingsRow(
                label: 'Thème',
                child: _MacSegmentedControl<AppThemePreference>(
                  value: widget.generalSettings.themePreference,
                  items: const [
                    (AppThemePreference.dark, 'Sombre'),
                    (AppThemePreference.light, 'Clair'),
                  ],
                  onChanged: widget.onThemeChanged,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _MacSettingsGroup(
            title: 'Audio',
            children: [
              _MacSettingsRow(
                label: 'Micro',
                child: _MacPopupButton<String>(
                  value: selectedInput,
                  placeholder: 'Sélectionner un micro',
                  items: widget.audioInputs
                      .map((device) => (device.id, device.label))
                      .toList(growable: false),
                  helperText: widget.audioInputs.isEmpty
                      ? 'Aucun micro détecté pour le moment.'
                      : null,
                  onChanged: widget.audioInputs.isEmpty
                      ? null
                      : widget.onAudioInputChanged,
                ),
              ),
              _MacSettingsRow(
                label: 'Sortie appel',
                child: _MacPopupButton<String>(
                  value: selectedOutput,
                  placeholder: 'Sélectionner une sortie',
                  items: widget.audioOutputs
                      .map((device) => (device.id, device.label))
                      .toList(growable: false),
                  helperText: widget.audioOutputs.isEmpty
                      ? 'Aucune sortie audio détectée pour le moment.'
                      : null,
                  onChanged: widget.audioOutputs.isEmpty
                      ? null
                      : widget.onAudioOutputChanged,
                ),
              ),
              _MacSettingsRow(
                label: 'Sortie sonnerie',
                child: _MacPopupButton<String>(
                  value: selectedRingtoneOutput,
                  placeholder: 'Sélectionner une sortie',
                  items: widget.ringtoneOutputs
                      .map((device) => (device.id, device.label))
                      .toList(growable: false),
                  helperText: widget.ringtoneOutputs.isEmpty
                      ? 'Aucune sortie audio détectée pour le moment.'
                      : null,
                  onChanged: widget.ringtoneOutputs.isEmpty
                      ? null
                      : widget.onRingtoneOutputChanged,
                ),
              ),
              _MacSettingsRow(
                label: 'Volume sonnerie',
                child: Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: ringtoneVolume,
                        min: 0,
                        max: 1,
                        divisions: 20,
                        label: '${(ringtoneVolume * 100).round()}%',
                        onChanged: widget.onRingtoneVolumeChanged,
                      ),
                    ),
                    SizedBox(
                      width: 42,
                      child: Text(
                        '${(ringtoneVolume * 100).round()}%',
                        textAlign: TextAlign.right,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _MacSettingsGroup(
            title: 'Sonnerie',
            children: [
              _MacSettingsRow(
                label: 'Fichier',
                child: Row(
                  children: [
                    Expanded(
                      child: _MacValuePill(
                        text: widget.generalSettings.ringtoneFileName.isEmpty
                            ? 'Sonnerie par défaut'
                            : widget.generalSettings.ringtoneFileName,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _MacSmallButton(
                      icon: Icons.library_music_outlined,
                      label: 'Importer',
                      onPressed: widget.onImportCustomRingtone,
                    ),
                  ],
                ),
              ),
              Builder(
                builder: (context) {
                  final theme = Theme.of(context);

                  return Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Formats acceptés : MP3, WAV, M4A, AIFF, CAF.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.15,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPbxSection({
    required String selectedCodec,
    required bool isCallActive,
  }) {
    return SingleChildScrollView(
      key: const ValueKey('pbx-section'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          _MacSettingsGroup(
            title: 'Compte SIP',
            children: [
              _MacSettingsRow(
                label: 'Domaine',
                child: _MacTextField(
                  controller: widget.domainController,
                  enabled: !isCallActive,
                ),
              ),
              _MacSettingsRow(
                label: 'Extension',
                child: _MacTextField(
                  controller: widget.extensionController,
                  enabled: !isCallActive,
                ),
              ),
              _MacSettingsRow(
                label: 'Auth ID',
                child: _MacTextField(
                  controller: widget.authController,
                  enabled: !isCallActive,
                ),
              ),
              _MacSettingsRow(
                label: 'Nom affiché',
                child: _MacTextField(
                  controller: widget.displayNameController,
                  enabled: !isCallActive,
                ),
              ),
              _MacSettingsRow(
                label: 'Mot de passe',
                child: _MacTextField(
                  controller: widget.passwordController,
                  enabled: !isCallActive,
                  obscureText: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _MacSettingsGroup(
            title: 'Média',
            children: [
              _MacSettingsRow(
                label: 'Codec audio',
                child: _MacPopupButton<String>(
                  value: selectedCodec,
                  placeholder: 'Automatique',
                  items: [
                    const ('', 'Automatique'),
                    ...widget.audioCodecs.map(
                      (codec) => (codec.id, codec.label),
                    ),
                  ],
                  helperText: widget.audioCodecs.isEmpty
                      ? 'Aucun codec détecté pour le moment.'
                      : 'Automatique utilise la négociation du PBX.',
                  onChanged: (value) {
                    setState(() => _pendingCodecId = value);
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  bool _hasPbxChanges(String selectedCodec) {
    return widget.domainController.text.trim() !=
            widget.account.domain.trim() ||
        widget.extensionController.text.trim() !=
            widget.account.extension.trim() ||
        widget.authController.text.trim() !=
            widget.account.authorizationId.trim() ||
        widget.passwordController.text != widget.account.password ||
        widget.displayNameController.text.trim() !=
            widget.account.displayName.trim() ||
        selectedCodec.trim() != widget.generalSettings.preferredCodecId.trim();
  }
}

class _MacSettingsToolbar<T> extends StatelessWidget {
  const _MacSettingsToolbar({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final List<(T, IconData, String)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 58,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.42),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withOpacity(0.32),
        ),
      ),
      child: Row(
        children: items.map((item) {
          final (itemValue, icon, label) = item;
          final selected = value == itemValue;

          return Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(11),
              onTap: () => onChanged(itemValue),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(11),
                  color: selected
                      ? theme.colorScheme.primary.withOpacity(0.16)
                      : Colors.transparent,
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      icon,
                      size: 18,
                      color: selected
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10,
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w600,
                        color: selected
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(growable: false),
      ),
    );
  }
}

class _MacSettingsGroup extends StatelessWidget {
  const _MacSettingsGroup({
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final separated = <Widget>[];
    for (var index = 0; index < children.length; index += 1) {
      if (index > 0) {
        separated.add(
          Divider(
            height: 1,
            indent: 12,
            endIndent: 12,
            color: theme.colorScheme.outlineVariant.withOpacity(0.28),
          ),
        );
      }
      separated.add(children[index]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 0, 6),
          child: Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: theme.colorScheme.surfaceContainerHighest.withOpacity(
              theme.brightness == Brightness.dark ? 0.28 : 0.54,
            ),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withOpacity(0.34),
            ),
          ),
          child: Column(children: separated),
        ),
      ],
    );
  }
}

class _MacSettingsRow extends StatelessWidget {
  const _MacSettingsRow({
    required this.label,
    required this.child,
  });

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 106,
            child: Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.05,
                color: theme.colorScheme.onSurface.withOpacity(0.92),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _MacSwitch extends StatelessWidget {
  const _MacSwitch({
    required this.value,
    required this.onChanged,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Transform.scale(
        scale: 0.82,
        child: Switch.adaptive(
          value: value,
          onChanged: onChanged,
        ),
      ),
    );
  }
}

class _MacSegmentedControl<T> extends StatelessWidget {
  const _MacSegmentedControl({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 190),
        child: Container(
          height: 30,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            color: theme.colorScheme.surface.withOpacity(0.75),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withOpacity(0.46),
            ),
          ),
          child: Row(
            children: items.map((item) {
              final (itemValue, label) = item;
              final selected = itemValue == value;

              return Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () => onChanged(itemValue),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(7),
                      color: selected
                          ? theme.colorScheme.primary.withOpacity(0.18)
                          : Colors.transparent,
                    ),
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(growable: false),
          ),
        ),
      ),
    );
  }
}

class _MacPopupButton<T> extends StatelessWidget {
  const _MacPopupButton({
    required this.value,
    required this.placeholder,
    required this.items,
    required this.onChanged,
    this.helperText,
  });

  final T? value;
  final String placeholder;
  final List<(T, String)> items;
  final ValueChanged<T>? onChanged;
  final String? helperText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onChanged != null && items.isNotEmpty;
    var selectedLabel = placeholder;
    for (final item in items) {
      if (item.$1 == value) {
        selectedLabel = item.$2;
        break;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PopupMenuButton<T>(
          enabled: enabled,
          tooltip: '',
          position: PopupMenuPosition.under,
          color: theme.colorScheme.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          onSelected: onChanged,
          itemBuilder: (context) {
            return items.map((item) {
              final selected = item.$1 == value;
              return PopupMenuItem<T>(
                value: item.$1,
                height: 34,
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      child: selected
                          ? Icon(
                              Icons.check_rounded,
                              size: 16,
                              color: theme.colorScheme.primary,
                            )
                          : null,
                    ),
                    Expanded(
                      child: Text(
                        item.$2,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(growable: false);
          },
          child: Opacity(
            opacity: enabled ? 1 : 0.52,
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: theme.colorScheme.surface.withOpacity(0.86),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withOpacity(0.58),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      selectedLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.unfold_more_rounded,
                    size: 17,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (helperText != null) ...[
          const SizedBox(height: 4),
          Text(
            helperText!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.1,
            ),
          ),
        ],
      ],
    );
  }
}

class _MacTextField extends StatelessWidget {
  const _MacTextField({
    required this.controller,
    required this.enabled,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      height: 38,
      child: TextField(
        controller: controller,
        enabled: enabled,
        obscureText: obscureText,
        textAlignVertical: TextAlignVertical.center,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        decoration: InputDecoration(
          isDense: true,
          filled: true,
          fillColor: theme.colorScheme.surface.withOpacity(0.86),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 10,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
              color: theme.colorScheme.outlineVariant.withOpacity(0.58),
            ),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
              color: theme.colorScheme.outlineVariant.withOpacity(0.58),
            ),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(
              color: theme.colorScheme.primary,
              width: 1.4,
            ),
          ),
        ),
      ),
    );
  }
}

class _MacValuePill extends StatelessWidget {
  const _MacValuePill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 38,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: theme.colorScheme.surface.withOpacity(0.86),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withOpacity(0.58),
        ),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _MacSmallButton extends StatelessWidget {
  const _MacSmallButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onPressed,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: theme.colorScheme.primary.withOpacity(0.12),
          border: Border.all(
            color: theme.colorScheme.primary.withOpacity(0.34),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SettingsStatusToast extends StatelessWidget {
  const _SettingsStatusToast({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withOpacity(0.95),
          border: Border.all(
            color:
                Theme.of(context).colorScheme.outlineVariant.withOpacity(0.35),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Text(
            message,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
    );
  }
}

class _PrivacySettingsSection extends StatelessWidget {
  const _PrivacySettingsSection({
    super.key,
    required this.permissions,
    required this.onRefresh,
    required this.onOpenSettings,
  });

  final List<PrivacyPermissionStatus> permissions;
  final Future<void> Function() onRefresh;
  final Future<void> Function(PrivacyPermissionKind kind) onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final displayedPermissions = permissions.isEmpty
        ? const <PrivacyPermissionStatus>[
            PrivacyPermissionStatus(
              kind: PrivacyPermissionKind.microphone,
              label: 'Microphone',
              description:
                  'Autorise la capture de votre voix pendant les appels.',
              isActive: false,
            ),
            PrivacyPermissionStatus(
              kind: PrivacyPermissionKind.launchAtStartup,
              label: 'Ouverture au démarrage',
              description: 'Permet de lancer le softphone automatiquement.',
              isActive: false,
            ),
          ]
        : permissions;

    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: _MacSmallButton(
              icon: Icons.refresh_rounded,
              label: 'Actualiser',
              onPressed: onRefresh,
            ),
          ),
          const SizedBox(height: 12),
          _MacSettingsGroup(
            title: 'Autorisations',
            children: displayedPermissions
                .map(
                  (permission) => _PrivacyPermissionTile(
                    permission: permission,
                    onOpenSettings: () => onOpenSettings(permission.kind),
                  ),
                )
                .toList(growable: false),
          ),
        ],
      ),
    );
  }
}

class _PrivacyPermissionTile extends StatelessWidget {
  const _PrivacyPermissionTile({
    required this.permission,
    required this.onOpenSettings,
  });

  final PrivacyPermissionStatus permission;
  final Future<void> Function() onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeColor = Colors.green.shade500;
    final inactiveColor = theme.colorScheme.error;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Row(
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: (permission.isActive ? activeColor : inactiveColor)
                  .withOpacity(0.14),
            ),
            child: Icon(
              permission.isActive
                  ? Icons.check_circle_outline
                  : Icons.error_outline,
              color: permission.isActive ? activeColor : inactiveColor,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        permission.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    _PermissionBadge(isActive: permission.isActive),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  permission.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontSize: 11,
                    height: 1.12,
                  ),
                ),
              ],
            ),
          ),
          if (!permission.isActive) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Ouvrir les réglages',
              onPressed: onOpenSettings,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.open_in_new_rounded, size: 17),
            ),
          ],
        ],
      ),
    );
  }
}

class _PermissionBadge extends StatelessWidget {
  const _PermissionBadge({required this.isActive});

  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final color =
        isActive ? Colors.green.shade500 : Theme.of(context).colorScheme.error;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withOpacity(0.12),
      ),
      child: Text(
        isActive ? 'Actif' : 'Inactif',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w800,
            ),
      ),
    );
  }
}

class _BottomGlassNav extends StatelessWidget {
  const _BottomGlassNav({
    required this.currentIndex,
    required this.onSelected,
  });

  final int currentIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    const items = <(IconData, String)>[
      (Icons.dialpad_outlined, 'Clavier'),
      (Icons.history_outlined, 'Journal'),
      (Icons.settings_outlined, 'Réglages'),
    ];

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              height: 50,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              color: Theme.of(context).colorScheme.surface.withOpacity(0.54),
              child: Row(
                children: List.generate(items.length, (index) {
                  final (icon, label) = items[index];
                  final selected = index == currentIndex;

                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => onSelected(index),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            color: selected
                                ? Theme.of(context)
                                    .colorScheme
                                    .primary
                                    .withOpacity(0.18)
                                : Colors.transparent,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                icon,
                                size: 17,
                                color: selected
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                              ),
                              Text(
                                label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .labelSmall
                                    ?.copyWith(
                                      fontWeight: selected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      fontSize: 10,
                                      height: 1.0,
                                      color: selected
                                          ? Theme.of(context)
                                              .colorScheme
                                              .onSurface
                                          : Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
