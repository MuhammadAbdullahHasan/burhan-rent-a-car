import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';

/// A labelled field. Always renders [displayOrNA], so a missing value shows
/// "N/A" rather than an empty gap -- the data-integrity rule, applied in
/// exactly one place.
class DetailField extends StatelessWidget {
  final String label;
  final Object? value;

  const DetailField({super.key, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = displayOrNA(value);
    final isMissing = text == 'N/A';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: isMissing ? FontWeight.w400 : FontWeight.w500,
                color: isMissing
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  final String? title;
  final Widget child;
  final Widget? action;

  const SectionCard({
    super.key,
    this.title,
    required this.child,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title!,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  if (action != null) action!,
                ],
              ),
              const SizedBox(height: 12),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// The rental-number badge. Shows "#23" for a numbered rental and
/// "Pending #abc123" for one created offline that the backend hasn't
/// numbered yet.
class RentalNumberBadge extends StatelessWidget {
  final Map<String, Object?> rental;

  const RentalNumberBadge({super.key, required this.rental});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = isPendingRental(rental);
    final placeholder = isPlaceholderRental(rental);
    final color = pending
        ? theme.colorScheme.tertiary
        : placeholder
            ? theme.colorScheme.outline
            : theme.colorScheme.primary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        rentalDisplayNumber(rental),
        style: theme.textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final String? status;

  const StatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = displayOrNA(status);
    final isClosed = label.toLowerCase() == 'closed';
    final color = isClosed ? theme.colorScheme.outline : const Color(0xFF1E7A46);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  const EmptyState({super.key, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Wraps a query in the standard loading/empty/content states so every
/// screen behaves the same way.
class AsyncList<T> extends StatelessWidget {
  final Future<List<T>> future;
  final Widget Function(BuildContext, List<T>) builder;
  final String emptyMessage;
  final IconData emptyIcon;

  const AsyncList({
    super.key,
    required this.future,
    required this.builder,
    required this.emptyMessage,
    this.emptyIcon = Icons.inbox_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<T>>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return EmptyState(
            icon: Icons.error_outline,
            message: 'Could not load data:\n${snapshot.error}',
          );
        }
        final items = snapshot.data ?? const [];
        if (items.isEmpty) {
          return EmptyState(icon: emptyIcon, message: emptyMessage);
        }
        return builder(context, items);
      },
    );
  }
}
