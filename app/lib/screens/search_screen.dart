import 'dart:async';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';

import '../app_services.dart';
import '../widgets/common.dart';
import 'customer_detail_screen.dart';
import 'rental_detail_screen.dart';
import 'vehicle_detail_screen.dart';

/// One search box. No category selector: the query is classified by the
/// data layer's [UniversalSearchService] and every applicable lookup runs
/// against local SQLite.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<SearchResult> _results = const [];
  bool _searching = false;
  String _lastQuery = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () => _run(value));
  }

  Future<void> _run(String query) async {
    final services = AppScope.of(context);
    setState(() => _searching = true);
    final results = await services.search.search(services.db, query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
      _lastQuery = query.trim();
    });
  }

  /// On submit (not on every keystroke, which would hijack typing), a query
  /// that matches exactly one unique identifier opens that record directly.
  Future<void> _onSubmitted(String query) async {
    _debounce?.cancel();
    await _run(query);
    if (!mounted) return;
    final services = AppScope.of(context);
    final sole = services.search.soleExactMatch(_results);
    if (sole != null) _open(sole);
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
    if (mounted && _lastQuery.isNotEmpty) _run(_lastQuery);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Search')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextField(
              controller: _controller,
              autofocus: false,
              textInputAction: TextInputAction.search,
              onChanged: _onChanged,
              onSubmitted: _onSubmitted,
              decoration: InputDecoration(
                hintText: 'Search anything…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _controller.clear();
                          setState(() {
                            _results = const [];
                            _lastQuery = '';
                          });
                        },
                      ),
              ),
            ),
          ),
          if (_searching) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: _body(theme)),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_lastQuery.isEmpty) {
      return const EmptyState(
        icon: Icons.search,
        message: 'Search by rental number, customer name, phone,\n'
            'CNIC, or vehicle registration.\n\n'
            'One box — no need to pick a category.',
      );
    }
    if (_results.isEmpty && !_searching) {
      return EmptyState(
        icon: Icons.search_off,
        message: 'Nothing matched "$_lastQuery".',
      );
    }

    final exact = _results.where((r) => r.isExactMatch).toList();
    final partial = _results.where((r) => !r.isExactMatch).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
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
            label: exact.isEmpty ? 'RESULTS' : 'OTHER MATCHES',
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
      trailing: Text(
        result.matchedOn,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
