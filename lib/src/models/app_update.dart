class AppUpdateInfo {
  const AppUpdateInfo({
    required this.version,
    required this.tagName,
    required this.releaseUrl,
    required this.downloadUrl,
    required this.assetName,
    required this.releaseNotes,
  });

  final String version;
  final String tagName;
  final String releaseUrl;
  final String downloadUrl;
  final String assetName;
  final String releaseNotes;
}
