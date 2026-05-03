import 'package:flutter/material.dart';

import '../models/softphone_status.dart';

class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.status,
  });

  final SoftphoneConnectionStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (status) {
      SoftphoneConnectionStatus.offline => ('Hors ligne', Colors.blueGrey),
      SoftphoneConnectionStatus.connecting => ('Connexion...', scheme.primary),
      SoftphoneConnectionStatus.registered => ('Enregistré', Colors.green),
      SoftphoneConnectionStatus.calling => (
          'Appel sortant',
          Colors.lightBlueAccent
        ),
      SoftphoneConnectionStatus.ringing => ('Appel entrant', Colors.orange),
      SoftphoneConnectionStatus.inCall => ('En ligne', Colors.greenAccent),
      SoftphoneConnectionStatus.error => ('Erreur', scheme.error),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: scheme.surface,
        border: Border.all(
          color: scheme.outlineVariant.withOpacity(0.7),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}
