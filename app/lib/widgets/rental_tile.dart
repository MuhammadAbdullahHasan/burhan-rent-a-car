import 'dart:typed_data';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';

import 'common.dart';

/// One rental in a list. Deliberately shows the rental number, the dates,
/// the amount and the status -- nothing invented beyond what the source
/// data actually carries.
class RentalTile extends StatelessWidget {
  final Map<String, Object?> rental;

  /// Optional context line, e.g. the customer or vehicle this rental
  /// belongs to, depending on which screen is showing it.
  final String? contextLabel;
  final VoidCallback? onTap;

  /// Thumbnail of the paper agreement, when one is attached -- so a
  /// customer's or vehicle's history shows at a glance which rentals have
  /// their agreement on file.
  final Uint8List? agreementThumbnail;

  const RentalTile({
    super.key,
    required this.rental,
    this.contextLabel,
    this.onTap,
    this.agreementThumbnail,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = isPlaceholderRental(rental);

    if (placeholder) {
      return ListTile(
        onTap: onTap,
        leading: Icon(
          Icons.remove_circle_outline,
          color: theme.colorScheme.outline,
        ),
        title: Row(
          children: [
            RentalNumberBadge(rental: rental),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                noPreviousRecordAvailable,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
      );
    }

    final dates = [
      displayOrNA(rental['start_date']),
      displayOrNA(rental['end_date']),
    ].join('  →  ');

    return ListTile(
      onTap: onTap,
      leading: agreementThumbnail == null
          ? null
          : ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(
                agreementThumbnail!,
                width: 44,
                height: 56,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
      title: Row(
        children: [
          RentalNumberBadge(rental: rental),
          const SizedBox(width: 8),
          StatusChip(status: rental['status'] as String?),
        ],
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (contextLabel != null)
              Text(
                contextLabel!,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface,
                ),
              ),
            Text(dates, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            displayOrNA(_formatAmount(rental['amount'])),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (rental['balance'] != null && (rental['balance'] as num) > 0)
            Text(
              'Bal ${_formatAmount(rental['balance'])}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }
}

String? _formatAmount(Object? value) {
  if (value == null) return null;
  final number = value is num ? value : num.tryParse(value.toString());
  if (number == null) return value.toString();
  return number
      .toStringAsFixed(0)
      .replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+$)'),
        (m) => '${m[1]},',
      );
}
