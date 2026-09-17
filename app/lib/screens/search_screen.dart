import 'dart:async';
import 'dart:convert';

import 'package:burhan_rent_a_car_data/burhan_rent_a_car_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_services.dart';
import '../widgets/common.dart';
import '../widgets/showroom_scaffold.dart';
import 'customer_detail_screen.dart';
import 'rental_detail_screen.dart';
import 'vehicle_detail_screen.dart';

/// One search bar, one category at a time. The selected chip decides what
/// the text means -- a rental number, a customer name, a mobile number, a
/// CNIC or a vehicle registration -- so "23" in Rental # is never mistaken
/// for part of a phone number. Recent searches are kept on the device.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class SearchCategory {
  final SearchScope scope;
  final String chip;
  final String noun;
  final TextInputType keyboard;
  final bool digitsOnly;

  const SearchCategory({
    required this.scope,
    required this.chip,
    required this.noun,
    required this.keyboard,
    this.digitsOnly = false,
  });

  List<TextInputFormatter> get formatters =>
      digitsOnly ? [FilteringTextInputFormatter.digitsOnly] : const [];

  static const all = [
    SearchCategory(
      scope: SearchScope.rentalNo,
      chip: 'Rental #',
      noun: 'rental number',
      keyboard: TextInputType.number,
      digitsOnly: true,
    ),
    SearchCategory(
      scope: SearchScope.customerName,
      chip: 'Customer',
      noun: 'customer name',
      keyboard: TextInputType.name,
    ),
    SearchCategory(
      scope: SearchScope.phone,
      chip: 'Mobile',
      noun: 'mobile number',
      keyboard: TextInputType.phone,
    ),
    SearchCategory(
      scope: SearchScope.cnic,
      chip: 'CNIC',
      noun: 'CNIC',
      keyboard: TextInputType.number,
    ),
    SearchCategory(
      scope: SearchScope.vehicle,
      chip: 'Vehicle Reg',
      noun: 'vehicle registration',
      keyboard: TextInputType.text,
    ),
  ];

  static SearchCategory byScope(String name) => all.firstWhere(
        (c) => c.scope.name == name,
        orElse: () => all.first,
      );
}

const _recentKey = 'recent_searches';
const _recentLimit = 8;

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  SearchCategory _category = SearchCategory.all.first;

  Timer? _debounce;
  List<SearchResult> _results = const [];
  bool _searching = false;
  String _lastQuery = '';
  List<_Recent> _recent = const [];
  bool _recentLoaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_recentLoaded) {
      _recentLoaded = true;
      _loadRecent();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---- recent searches -----------------------------------------------------

  Future<void> _loadRecent() async {
    final rows = await AppScope.of(context).db.query(
      'app_meta',
      where: 'key = ?',
      whereArgs: [_recentKey],
    );
    if (!mounted || rows.isEmpty) return;
    final decoded = jsonDecode(rows.first['value'] as String) as List;
    setState(() {
      _recent = [
        for (final e in decoded.cast<Map>())
          _Recent(
            SearchCategory.byScope(e['scope'] as String),
            e['query'] as String,
          ),
      ];
    });
  }

  Future<void> _saveRecent() async {
    await AppScope.of(context).db.insert(
          'app_meta',
          {
            'key': _recentKey,
            'value': jsonEncode([
              for (final r in _recent)
                {'scope': r.category.scope.name, 'query': r.query},
            ]),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
  }

  void _remember(SearchCategory category, String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final entry = _Recent(category, trimmed);
    final next = [entry, ..._recent.where((r) => r != entry)];
    setState(() => _recent = next.take(_recentLimit).toList());
    _saveRecent();
  }

  void _clearRecent() {
    setState(() => _recent = const []);
    _saveRecent();
  }

  // ---- searching -------------------------------------------------------------

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _results = const [];
        _lastQuery = '';
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 220), () => _run(value));
  }

  void _selectCategory(SearchCategory category) {
    if (category == _category) return;
    setState(() => _category = category);
    final text = _controller.text;
    if (category.digitsOnly) {
      // Digits-only category: keep only what it can search.
      final digits = text.replaceAll(RegExp(r'\D'), '');
      if (digits != text) _controller.text = digits;
    }
    _debounce?.cancel();
    if (_controller.text.trim().isEmpty) {
      setState(() {
        _results = const [];
        _lastQuery = '';
      });
    } else {
      _run(_controller.text);
    }
  }

  Future<void> _run(String query) async {
    final services = AppScope.of(context);
    final category = _category;
    setState(() => _searching = true);
    final results = await services.search.searchScoped(
      services.db,
      query,
      category.scope,
    );
    if (!mounted || category != _category) return;
    setState(() {
      _results = results;
      _searching = false;
      _lastQuery = query.trim();
    });
  }

  /// Submitting a query that matched exactly one unique identifier opens
  /// that record directly. Every submitted search is remembered.
  Future<void> _onSubmitted(String query) async {
    _debounce?.cancel();
    if (query.trim().isEmpty) return;
    await _run(query);
    if (!mounted) return;
    _remember(_category, query);
    final sole = AppScope.of(context).search.soleExactMatch(_results);
    if (sole != null) _open(sole);
  }

  void _useRecent(_Recent recent) {
    setState(() => _category = recent.category);
    _controller.text = recent.query;
    _focus.requestFocus();
    _run(recent.query);
  }

  void _clear() {
    _controller.clear();
    _debounce?.cancel();
    setState(() {
      _results = const [];
      _lastQuery = '';
    });
    _focus.requestFocus();
  }

  Future<void> _open(SearchResult result) async {
    _remember(_category, _lastQuery);
    final route = switch (result.type) {
      SearchResultType.rental => MaterialPageRoute<void>(
          builder: (_) => RentalDetailScreen(rentalId: result.id),
        ),
      SearchResultType.customer => MaterialPageRoute<void>(
          builder: (_) => CustomerDetailScreen(customerId: result.id),
        ),
      SearchResultType.vehicle => MaterialPageRoute<void>(
          builder: (_) => VehicleDetailScreen(vehicleId: result.id),
        ),
    };
    await Navigator.of(context).push(route);
    if (mounted && _lastQuery.isNotEmpty) _run(_lastQuery);
  }

  // ---- UI ----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ShowroomScaffold(
      title: 'Search Records',
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            16,
            12,
            16,
            ShowroomScaffold.bottomInset(context),
          ),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      TextField(
                        key: const Key('search_field'),
                        controller: _controller,
                        focusNode: _focus,
                        keyboardType: _category.keyboard,
                        inputFormatters: _category.formatters,
                        textInputAction: TextInputAction.search,
                        onChanged: _onChanged,
                        onSubmitted: _onSubmitted,
                        decoration: InputDecoration(
                          hintText: 'Search by Rental, Customer, Mobile, CNIC, '
                              'or Vehicle Reg…',
                          filled: true,
                          fillColor: theme.colorScheme.surfaceContainerHigh,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(28),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 16,
                          ),
                          suffixIcon: _controller.text.isEmpty
                              ? Icon(Icons.search,
                                  color: theme.colorScheme.primary)
                              : IconButton(
                                  tooltip: 'Clear',
                                  icon: const Icon(Icons.close),
                                  onPressed: _clear,
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          for (final category in SearchCategory.all)
                            ChoiceChip(
                              label: Text(category.chip),
                              selected: _category == category,
                              showCheckmark: false,
                              onSelected: (_) => _selectCategory(category),
                            ),
                        ],
                      ),
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
              if (_lastQuery.isEmpty)
                _recentSection(theme)
              else
                _resultsSection(theme),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _recentSection(ThemeData theme) {
    if (_recent.isEmpty) {
      return EmptyState(
        icon: Icons.history,
        message: 'No Recent Searches\n'
            'Enter a ${_category.noun} above',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
                child: _GroupLabel(label: 'RECENT SEARCHES', theme: theme)),
            TextButton(onPressed: _clearRecent, child: const Text('Clear')),
          ],
        ),
        Card(
          child: Column(
            children: [
              for (final r in _recent)
                ListTile(
                  leading: const Icon(Icons.history),
                  title: Text(r.query),
                  subtitle: Text(r.category.chip),
                  trailing: const Icon(Icons.north_west, size: 18),
                  onTap: () => _useRecent(r),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _resultsSection(ThemeData theme) {
    if (_results.isEmpty && !_searching) {
      return EmptyState(
        icon: Icons.search_off,
        message: 'No ${_category.noun} matched "$_lastQuery".',
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
                ? '${_category.noun.toUpperCase()} · ${partial.length} RESULT${partial.length == 1 ? '' : 'S'}'
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

class _Recent {
  final SearchCategory category;
  final String query;
  const _Recent(this.category, this.query);

  @override
  bool operator ==(Object other) =>
      other is _Recent &&
      other.category == category &&
      other.query.toLowerCase() == query.toLowerCase();

  @override
  int get hashCode => Object.hash(category, query.toLowerCase());
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
      SearchResultType.rental => (
          Icons.receipt_long,
          theme.colorScheme.primary
        ),
      SearchResultType.customer => (Icons.person, theme.colorScheme.secondary),
      SearchResultType.vehicle => (
          Icons.directions_car,
          theme.colorScheme.tertiary
        ),
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
