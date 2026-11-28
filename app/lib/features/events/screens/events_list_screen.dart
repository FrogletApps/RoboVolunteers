import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/routing/app_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/sku_utils.dart';
import '../../../core/utils/url_utils.dart';
import '../models/event_model.dart';
import '../state/events_provider.dart';
import '../../volunteering/state/volunteering_provider.dart';
import '../../auth_invites/state/auth_provider.dart';

class EventsListScreen extends ConsumerStatefulWidget {
  const EventsListScreen({super.key});

  /// Width threshold below which the three filter groups stack onto three separate lines
  static const double kCompactFilterBreakpoint = 780;

  static String formatDateRange(String start, String end) {
    try {
      final s = DateTime.parse(start);
      final e = DateTime.parse(end);
      final fmt = DateFormat('EEE, d MMM y');
      if (s.year == e.year && s.month == e.month && s.day == e.day) {
        return fmt.format(s);
      }
      return '${DateFormat('d MMM').format(s)} – ${fmt.format(e)}';
    } catch (_) {
      return start;
    }
  }

  @override
  ConsumerState<EventsListScreen> createState() => _EventsListScreenState();
}

class _EventsListScreenState extends ConsumerState<EventsListScreen> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController =
        TextEditingController(text: ref.read(eventSearchQueryProvider));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Color _getSignupFilterColor(String option) {
    if (option == kConfirmedFilter) return AppTheme.statusConfirmed;
    if (option == kAvailableFilter) return AppTheme.statusAvailable;
    return AppTheme.brandGreen;
  }

  List<Widget> _buildEventTypeChips(String selectedProgram) {
    return [
      for (var i = 0; i < kEventTypeFilterOptions.length; i++)
        Padding(
          padding: EdgeInsets.only(
            right: i < kEventTypeFilterOptions.length - 1 ? 8 : 0,
          ),
          child: Builder(
            builder: (context) {
              final prog = kEventTypeFilterOptions[i];
              final isSelected = selectedProgram == prog;
              return FilterChip(
                label: Text(prog),
                selected: isSelected,
                selectedColor: AppTheme.brandGreen.withValues(alpha: 0.15),
                checkmarkColor: AppTheme.brandGreen,
                labelStyle: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? AppTheme.brandGreen : null,
                ),
                onSelected: (val) {
                  ref
                      .read(selectedProgramFilterProvider.notifier)
                      .setProgram(val ? prog : 'All');
                },
              );
            },
          ),
        ),
    ];
  }

  List<Widget> _buildSignupStatusChips(String? selectedSignupFilter) {
    return [
      for (var i = 0; i < kSignupStatusFilterOptions.length; i++)
        Padding(
          padding: EdgeInsets.only(
            right: i < kSignupStatusFilterOptions.length - 1 ? 8 : 0,
          ),
          child: Builder(
            builder: (context) {
              final option = kSignupStatusFilterOptions[i];
              final isSelected = selectedSignupFilter == option;
              final accent = _getSignupFilterColor(option);
              return FilterChip(
                label: Text(option),
                selected: isSelected,
                selectedColor: accent.withValues(alpha: 0.15),
                checkmarkColor: accent,
                labelStyle: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected ? accent : null,
                ),
                onSelected: (val) {
                  ref
                      .read(selectedSignupFilterProvider.notifier)
                      .setFilter(val ? option : null);
                },
              );
            },
          ),
        ),
    ];
  }

  Widget _buildClearButton(bool hasActiveFilters) {
    final activeColor = Colors.red.shade700;
    final idleColor = Colors.grey[600];
    return TextButton.icon(
      key: const Key('clear_filters_button'),
      onPressed: () {
        clearAllEventFilters(ref);
      },
      icon: Icon(
        Icons.filter_alt_off_outlined,
        size: 16,
        color: hasActiveFilters ? activeColor : idleColor,
      ),
      label: Text(
        'Clear',
        style: TextStyle(
          fontSize: 12,
          fontWeight: hasActiveFilters ? FontWeight.bold : FontWeight.w500,
          color: hasActiveFilters ? activeColor : idleColor,
        ),
      ),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<String>(eventSearchQueryProvider, (_, next) {
      if (_searchController.text != next) {
        _searchController.text = next;
      }
    });

    final eventsAsync = ref.watch(ukEventsListProvider);
    final selectedProgram = ref.watch(selectedProgramFilterProvider);
    final selectedSignupFilter = ref.watch(selectedSignupFilterProvider);
    final searchQuery = ref.watch(eventSearchQueryProvider);
    final isAdmin = ref.watch(isAdminProvider);

    final hasActiveFilters = selectedProgram != 'All' ||
        selectedSignupFilter != null ||
        searchQuery.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Text('RoboVolunteers'),
        actions: [
          if (isAdmin)
            IconButton(
              key: const Key('admin_portal_button'),
              icon: const Icon(Icons.admin_panel_settings_outlined),
              tooltip: 'Admin Portal',
              onPressed: () {
                AppRouter.push(context, AppRoutes.admin);
              },
            ),
          IconButton(
            key: const Key('profile_button'),
            icon: const Icon(Icons.person_outline),
            tooltip: 'My Volunteer Profile',
            onPressed: () {
              AppRouter.push(context, AppRoutes.profile);
            },
          ),
          IconButton(
            key: const Key('logout_button'),
            icon: const Icon(Icons.logout),
            tooltip: 'Log Out',
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Log Out?'),
                  content: const Text(
                    'Are you sure you want to log out of RoboVolunteers?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Log Out'),
                    ),
                  ],
                ),
              );

              if (confirm == true && mounted) {
                clearAllEventFilters(ref);
                await ref.read(authControllerProvider.notifier).logout();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Search & Filters Header
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
            ),
            child: Column(
              children: [
                TextField(
                  controller: _searchController,
                  decoration: InputDecoration(
                    hintText: 'Search tournaments, cities, or SKUs...',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () => ref
                                .read(eventSearchQueryProvider.notifier)
                                .setQuery(''),
                          )
                        : null,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  onChanged: (val) {
                    ref.read(eventSearchQueryProvider.notifier).setQuery(val);
                  },
                ),
                const SizedBox(height: 10),
                // Responsive Event Filter Groups (1 horizontal row when wide; 3 separate lines when narrow)
                LayoutBuilder(
                  builder: (context, constraints) {
                    final eventTypeChips =
                        _buildEventTypeChips(selectedProgram);
                    final signupStatusChips =
                        _buildSignupStatusChips(selectedSignupFilter);
                    final clearButton = _buildClearButton(hasActiveFilters);

                    if (constraints.maxWidth <
                        EventsListScreen.kCompactFilterBreakpoint) {
                      return Column(
                        key: const Key('filters_three_line_layout'),
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Center(
                            key: const Key('filter_group_event_types'),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: eventTypeChips,
                              ),
                            ),
                          ),
                          Divider(
                            key: const Key(
                                'event_filters_horizontal_divider_1'),
                            height: 16,
                            thickness: 1,
                            color: Colors.grey.shade300,
                          ),
                          Center(
                            key: const Key('filter_group_signup_status'),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: signupStatusChips,
                              ),
                            ),
                          ),
                          Divider(
                            key: const Key(
                                'event_filters_horizontal_divider_2'),
                            height: 14,
                            thickness: 1,
                            color: Colors.grey.shade300,
                          ),
                          Center(
                            key: const Key('filter_group_clear'),
                            child: clearButton,
                          ),
                        ],
                      );
                    }

                    return Row(
                      key: const Key('filters_single_line_layout'),
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                Row(
                                  key: const Key('filter_group_event_types'),
                                  mainAxisSize: MainAxisSize.min,
                                  children: eventTypeChips,
                                ),
                                Container(
                                  key: const Key(
                                      'event_filters_vertical_divider'),
                                  width: 1,
                                  height: 24,
                                  margin: const EdgeInsets.symmetric(
                                      horizontal: 12),
                                  color: Colors.grey.shade300,
                                ),
                                Row(
                                  key: const Key('filter_group_signup_status'),
                                  mainAxisSize: MainAxisSize.min,
                                  children: signupStatusChips,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        KeyedSubtree(
                          key: const Key('filter_group_clear'),
                          child: clearButton,
                        ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),

          // Events List
          Expanded(
            child: eventsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline, size: 48, color: Colors.red),
                      const SizedBox(height: 12),
                      Text(
                        'Error loading events: $err',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: () {
                          if (selectedSignupFilter != null) {
                            ref.invalidate(myVolunteerSignupsProvider);
                          }
                          return ref.refresh(ukEventsListProvider);
                        },
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
              data: (events) {
                if (events.isEmpty) {
                  final hasSearchQuery = searchQuery.trim().isNotEmpty;
                  final isAllPrograms = selectedProgram == 'All';
                  String emptyTitle = 'No events match your filters.';
                  String emptySubtitle =
                      'Tap Clear to reset filters or search with another keyword.';

                  if (!hasSearchQuery &&
                      isAllPrograms &&
                      selectedSignupFilter != null) {
                    if (selectedSignupFilter == kConfirmedFilter) {
                      emptyTitle = 'You have no confirmed events yet.';
                      emptySubtitle =
                          'Confirm your attendance on an event or tap Clear to view all events.';
                    } else if (selectedSignupFilter == kAvailableFilter) {
                      emptyTitle = 'You have no events marked as Available.';
                      emptySubtitle =
                          'Mark yourself as Available on an event or tap Clear to view all events.';
                    } else {
                      emptyTitle = 'You are not signed up for any events yet.';
                      emptySubtitle =
                          'Select an event to register as Available or Confirmed, or tap Clear to view all events.';
                    }
                  }

                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.event_busy, size: 48, color: Colors.grey[400]),
                          const SizedBox(height: 12),
                          Text(
                            emptyTitle,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            emptySubtitle,
                            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async {
                    if (selectedSignupFilter != null) {
                      ref.invalidate(myVolunteerSignupsProvider);
                    }
                    return ref.refresh(ukEventsListProvider.future);
                  },
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    itemCount: events.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final event = events[index];
                      return _EventCard(event: event);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EventCard extends ConsumerWidget {
  final EventModel event;

  const _EventCard({required this.event});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final signupsAsync = ref.watch(eventSignupsProvider(event.sku));
    final progColor = getProgramColor(event.program);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          AppRouter.pushEvent(context, event);
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: Program chip, SKU, and VEX Events link
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: progColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      event.program,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: progColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    event.sku,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  // VEX Events External Link Button
                  IconButton(
                    icon: const Icon(Icons.open_in_new, size: 18),
                    tooltip: 'View on VEX Events (events.vex.com)',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => UrlUtils.openVexEventsPage(event.sku),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Event Name
              Text(
                event.name,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 6),

              // Date and Location
              Row(
                children: [
                  Icon(Icons.calendar_today_outlined, size: 14, color: Colors.grey[600]),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      EventsListScreen.formatDateRange(event.startDate, event.endDate),
                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.location_on_outlined, size: 14, color: Colors.grey[600]),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      [event.venue, event.city, event.region].whereType<String>().where((s) => s.isNotEmpty).join(', '),
                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 8),

              // Signups summary & Roster CTA
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: signupsAsync.when(
                      data: (signups) {
                        final confirmedCount =
                            signups.where((s) => s.isConfirmed).length;
                        final availableCount =
                            signups.where((s) => s.isAvailable).length;
                        return Row(
                          children: [
                            Icon(Icons.people_outline,
                                size: 16, color: Colors.grey[700]),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                '$confirmedCount Confirmed • $availableCount Available',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: confirmedCount > 0
                                      ? AppTheme.statusConfirmed
                                      : Colors.grey[700],
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        );
                      },
                      loading: () => const Text(
                        'Loading volunteers...',
                        style: TextStyle(fontSize: 11),
                        overflow: TextOverflow.ellipsis,
                      ),
                      error: (_, __) => const SizedBox(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'View Roster',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.brandGreen,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.arrow_forward_ios,
                          size: 12, color: AppTheme.brandGreen),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
