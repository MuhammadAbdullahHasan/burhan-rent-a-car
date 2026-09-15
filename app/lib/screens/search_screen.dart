import 'dart:async';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../widgets/common.dart';
import 'customer_detail_screen.dart';
import 'rental_detail_screen.dart';
import 'vehicle_detail_screen.dart';

/// Categorised search: one field per identifier. Typing in a field runs
/// that category's lookup only, so a number typed into "Rental number" is
/// never mistaken for part of a phone number and vice versa. Whichever
/// field was edited last is the active one; the others are cleared so it's
/// always unambiguous which search the results belong to.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchField {
  final SearchScope scope;
  final String label;
  final String hint;
  final IconData icon;
  final TextInputType keyboard;
  final List<TextInputFormatter> formatters;
  final TextEditingController controller = TextEditingController();

  _SearchField({
    required this.scope,
    required this.label,
    required this.hint,
    required this.icon,
    required this.keyboard,
    this.formatters = const [],
  });
}

class _SearchScreenState extends State<SearchScreen> {
  late final List<_SearchField> _fields = [
    _SearchField(
      scope: SearchScope.rentalNo,
      label: 'Rental number',
      hint: 'e.g. 23',
      icon: Icons.receipt_long,
      keyboard: TextInputType.number,
      formatters: [FilteringTextInputFormatter.digitsOnly],
    ),
    _SearchField(
      scope: SearchScope.customerName,
      label: 'Customer name',
      hint: 'Full or partial name',
      icon: Icons.person,
      keyboard: TextInputType.name,
    ),
    _SearchField(
      scope: SearchScope.phone,
      label: 'Mobile number',
      hint: 'e.g. 0300 1234567',
      icon: Icons.phone,
      keyboard: TextInputType.phone,
    ),
    _SearchField(
      scope: SearchScope.cnic,
      label: 'CNIC',
      hint: 'e.g. 42201-1234567-1',
      icon: Icons.badge,
      keyboard: TextInputType.number,
    ),
    _SearchField(
      scope: SearchScope.vehicle,
      label: 'Vehicle registration',
      hint: 'e.g. KHI-123',
      icon: Icons.directions_car,
      keyboard: TextInputType.text,
    ),
  ];

  Timer? _debounce;
  List<SearchResult> _results = const [];
  bool _searching = false;
  _SearchField? _active;
  String _lastQuery = '';

  @override
  void dispose() {
    _debounce?.cancel();
    for (final f in _fields) {
      f.controller.dispose();
    }
    super.dispose();
  }

  void _onChanged(_SearchField field, String value) {
    if (_active != field) {
      for (final other in _fields) {
        if (other != field && other.controller.text.isNotEmpty) {
          other.controller.clear();
        }
      }
      _active = field;
    }
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 220),
      () => _run(field, value),
    );
  }

  Future<void> _run(_SearchField field, String query) async {
    final services = AppScope.of(context);
    setState(() {
      _searching = true;
      _active = field;
    });
    final results = await services.search.searchScoped(
      services.db,
      query,
      field.scope,
    );
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
      _lastQuery = query.trim();
    });
  }

  /// Submitting a field that matched exactly one unique identifier opens
  /// that record directly.
  Future<void> _onSubmitted(_SearchField field, String query) async {
    _debounce?.cancel();
    await _run(field, query);
    if (!mounted) return;
    final sole = AppScope.of(context).search.soleExactMatch(_results);
    if (sole != null) _open(sole);
  }

  void _clear(_SearchField field) {
    field.controller.clear();
    _debounce?.cancel();
    setState(() {
      _results = const [];
      _lastQuery = '';
      if (_active == field) _active = null;
    });
  }

  Future<void> _open(SearchResult result) async {
    final route = switch (result.type) {
      SearchResultType.rental =>
        MaterialPageRoute<void>(
          builder: (_) => RentalDetailScreen(rentalId: result.id),
        ),
      SearchResultType.customer =>
        MaterialPageRoute<void>(
          builder: (_) => CustomerDetailScreen(customerId: result.id),
        ),
      SearchResultType.vehicle =>
        MaterialPageRoute<void>(
          builder: (_) => VehicleDetailScreen(vehicleId: result.id),
        ),
    };
    await Navigator.of(context).push(route);
    if (mounted && _active != null && _lastQuery.isNotEmpty) {
      _run(_active!, _lastQuery);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Column(
                children: [
                  for (final field in _fields) _buildField(field, theme),
                ],
              ),
            ),
          ),
          if (_searching)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          const SizedBox(height: 16),
          _resultsSection(theme),
        ],
      ),
    );
  }

  Widget _buildField(_SearchField field, ThemeData theme) {
    final isActive = _active == field && field.controller.text.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: field.controller,
        keyboardType: field.keyboard,
        inputFormatters: field.formatters,
        textInputAction: TextInputAction.search,
        onChanged: (v) => _onChanged(field, v),
        onSubmitted: (v) => _onSubmitted(field, v),
        decoration: InputDecoration(
          labelText: field.label,
          hintText: field.hint,
          prefixIcon: Icon(
            field.icon,
            color: isActive ? theme.colorScheme.primary : null,
          ),
          suffixIcon: field.controller.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => _clear(field),
                ),
        ),
      ),
    );
  }

  Widget _resultsSection(ThemeData theme) {
    if (_active == null || _lastQuery.isEmpty) {
      return const EmptyState(
        icon: Icons.search,
        message: 'Type into any field above.\n'
            'Each field searches only its own category.',
      );
    }
    if (_results.isEmpty && !_searching) {
      return EmptyState(
        icon: Icons.search_off,
        message: 'No ${_active!.label.toLowerCase()} matched "$_lastQuery".',
      );
    }

    final exact = _results.where((r) => r.isExactMatch).toList();
    final partial = _results.where((r) => !r.isExactMatch).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (exact.isNotEmpty) ...[
          _GroupLabel(label: 'EXACT MATCH', theme: theme),
          Card(
            child: Column(
              children: [
                for (final r in exact) _ResultTile(result: r, onTap: _open),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (partial.isNotEmpty) ...[
          _GroupLabel(
            label: exact.isEmpty
                ? '${_active!.label.toUpperCase()} · ${partial.length} RESULT${partial.length == 1 ? '' : 'S'}'
                : 'OTHER MATCHES',
            theme: theme,
          ),
          Card(
            child: Column(
              children: [
                for (final r in partial) _ResultTile(result: r, onTap: _open),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _GroupLabel extends StatelessWidget {
  final String label;
  final ThemeData theme;

  const _GroupLabel({required this.label, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _ResultTile extends StatelessWidget {
  final SearchResult result;
  final void Function(SearchResult) onTap;

  const _ResultTile({required this.result, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, tint) = switch (result.type) {
      SearchResultType.rental => (Icons.receipt_long, theme.colorScheme.primary),
      SearchResultType.customer => (Icons.person, theme.colorScheme.secondary),
      SearchResultType.vehicle =>
        (Icons.directions_car, theme.colorScheme.tertiary),
    };

    return ListTile(
      onTap: () => onTap(result),
      leading: CircleAvatar(
        backgroundColor: tint.withValues(alpha: 0.12),
        foregroundColor: tint,
        child: Icon(icon, size: 20),
      ),
      title: Text(
        result.title,
        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: result.subtitle.isEmpty
          ? null
          : Text(result.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}
