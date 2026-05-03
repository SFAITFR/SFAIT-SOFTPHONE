enum PrivacyPermissionKind { microphone, launchAtStartup }

class PrivacyPermissionStatus {
  const PrivacyPermissionStatus({
    required this.kind,
    required this.label,
    required this.description,
    required this.isActive,
  });

  final PrivacyPermissionKind kind;
  final String label;
  final String description;
  final bool isActive;
}
