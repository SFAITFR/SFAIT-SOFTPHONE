class SipAccount {
  const SipAccount({
    required this.label,
    required this.domain,
    required this.extension,
    required this.authorizationId,
    required this.password,
    required this.displayName,
  });

  final String label;
  final String domain;
  final String extension;
  final String authorizationId;
  final String password;
  final String displayName;

  SipAccount copyWith({
    String? label,
    String? domain,
    String? extension,
    String? authorizationId,
    String? password,
    String? displayName,
  }) {
    return SipAccount(
      label: label ?? this.label,
      domain: domain ?? this.domain,
      extension: extension ?? this.extension,
      authorizationId: authorizationId ?? this.authorizationId,
      password: password ?? this.password,
      displayName: displayName ?? this.displayName,
    );
  }

  Map<String, String> toJson() {
    return {
      'label': label,
      'domain': domain,
      'extension': extension,
      'authorizationId': authorizationId,
      'password': password,
      'displayName': displayName,
    };
  }

  factory SipAccount.fromJson(Map<String, dynamic> json) {
    return SipAccount(
      label: json['label'] as String? ?? 'Compte principal',
      domain: json['domain'] as String? ?? '',
      extension: json['extension'] as String? ?? '',
      authorizationId: json['authorizationId'] as String? ?? '',
      password: json['password'] as String? ?? '',
      displayName: json['displayName'] as String? ?? '',
    );
  }

  static const empty = SipAccount(
    label: 'Compte principal',
    domain: '',
    extension: '',
    authorizationId: '',
    password: '',
    displayName: '',
  );
}
