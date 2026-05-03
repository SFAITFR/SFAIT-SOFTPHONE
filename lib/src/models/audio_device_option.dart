class AudioDeviceOption {
  const AudioDeviceOption({
    required this.id,
    required this.label,
    this.callDeviceId,
    this.systemDeviceId,
  });

  final String id;
  final String label;
  final String? callDeviceId;
  final String? systemDeviceId;
}
