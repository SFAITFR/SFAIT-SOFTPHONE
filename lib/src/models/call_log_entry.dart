enum CallDirection { incoming, outgoing, missed }

class CallLogEntry {
  const CallLogEntry({
    required this.direction,
    required this.remoteIdentity,
    required this.at,
    required this.summary,
  });

  final CallDirection direction;
  final String remoteIdentity;
  final DateTime at;
  final String summary;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'direction': direction.name,
      'remoteIdentity': remoteIdentity,
      'at': at.toIso8601String(),
      'summary': summary,
    };
  }

  factory CallLogEntry.fromJson(Map<String, dynamic> json) {
    return CallLogEntry(
      direction: CallDirection.values.firstWhere(
        (value) => value.name == json['direction'],
        orElse: () => CallDirection.outgoing,
      ),
      remoteIdentity: json['remoteIdentity'] as String? ?? 'Inconnu',
      at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
      summary: json['summary'] as String? ?? '',
    );
  }
}
