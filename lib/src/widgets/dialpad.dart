import 'package:flutter/material.dart';

class Dialpad extends StatelessWidget {
  const Dialpad({
    super.key,
    required this.onDigit,
    this.compact = false,
    this.height = 352,
    this.digitFontSize,
  });

  final ValueChanged<String> onDigit;
  final bool compact;
  final double height;
  final double? digitFontSize;

  static const _digits = <(String, String?)>[
    ('1', null),
    ('2', 'ABC'),
    ('3', 'DEF'),
    ('4', 'GHI'),
    ('5', 'JKL'),
    ('6', 'MNO'),
    ('7', 'PQRS'),
    ('8', 'TUV'),
    ('9', 'WXYZ'),
    ('*', null),
    ('0', '+'),
    ('#', null),
  ];

  @override
  Widget build(BuildContext context) {
    final spacing = compact ? 7.0 : 10.0;
    final radius = compact ? 10.0 : 16.0;
    final padding = compact ? 2.0 : 8.0;
    final digitStyle = compact
        ? Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: digitFontSize ?? 30,
              height: 1.0,
            )
        : Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontSize: digitFontSize,
            );

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableWidth = constraints.maxWidth;
          final availableHeight = constraints.maxHeight;
          const columns = 3;
          const rows = 4;
          final totalSpacing = (columns - 1) * spacing;
          final tileWidth = (availableWidth - totalSpacing) / columns;
          final tileHeight = (availableHeight - ((rows - 1) * spacing)) / rows;
          final ratio = tileWidth / tileHeight;

          return GridView.builder(
            shrinkWrap: true,
            itemCount: _digits.length,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              childAspectRatio: ratio,
            ),
            itemBuilder: (context, index) {
              final (digit, letters) = _digits[index];
              return FilledButton.tonal(
                onPressed: () => onDigit(digit),
                style: FilledButton.styleFrom(
                  padding: EdgeInsets.all(padding),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(radius),
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(digit, style: digitStyle),
                    if (letters != null)
                      Text(
                        letters,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontSize: 10.5,
                              height: 1.0,
                            ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
