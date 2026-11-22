import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/event_model.dart';
import '../services/vex_events_service.dart';
import '../../volunteering/state/volunteering_provider.dart';

const String kMyEventsFilter = 'My Events';
const String kConfirmedFilter = 'Confirmed';
const String kAvailableFilter = 'Available';

/// Group 1: Event type / program filter options
const List<String> kEventTypeFilterOptions = [
  'All',
  'VEX V5',
  'VEX IQ',
  'VEX U',
];

/// Group 2: User signup / status filter options
const List<String> kSignupStatusFilterOptions = [
  kMyEventsFilter,
  kConfirmedFilter,
  kAvailableFilter,
];

final vexEventsServiceProvider = Provider<VexEventsService>((ref) {
  return VexEventsService();
});

class SelectedProgramFilterNotifier extends Notifier<String> {
  @override
  String build() => 'All';

  void setProgram(String program) => state = program;
}

final selectedProgramFilterProvider =
    NotifierProvider<SelectedProgramFilterNotifier, String>(
  SelectedProgramFilterNotifier.new,
);

class SelectedSignupFilterNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void setFilter(String? filter) => state = filter;
}

final selectedSignupFilterProvider =
    NotifierProvider<SelectedSignupFilterNotifier, String?>(
  SelectedSignupFilterNotifier.new,
);

class EventSearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void setQuery(String query) => state = query;
}

final eventSearchQueryProvider =
    NotifierProvider<EventSearchQueryNotifier, String>(
  EventSearchQueryNotifier.new,
);

/// Reset all active event filters and search back to showing all events
void clearAllEventFilters(WidgetRef ref) {
  ref.read(selectedProgramFilterProvider.notifier).setProgram('All');
  ref.read(selectedSignupFilterProvider.notifier).setFilter(null);
  ref.read(eventSearchQueryProvider.notifier).setQuery('');
}

final ukEventsListProvider = FutureProvider<List<EventModel>>((ref) async {
  final service = ref.watch(vexEventsServiceProvider);
  final selectedProgram = ref.watch(selectedProgramFilterProvider);
  final selectedSignupFilter = ref.watch(selectedSignupFilterProvider);
  final query = ref.watch(eventSearchQueryProvider);
  final cleanQuery = query.isEmpty ? null : query;
  final cleanProgram = selectedProgram == 'All' ? null : selectedProgram;

  if (selectedSignupFilter != null) {
    final mySignups = await ref.watch(myVolunteerSignupsProvider.future);
    final matchingSignups = mySignups.where((s) {
      if (selectedSignupFilter == kConfirmedFilter) {
        return s.isConfirmed;
      }
      if (selectedSignupFilter == kAvailableFilter) {
        return s.isAvailable;
      }
      return true; // 'My Events' includes both Confirmed and Available
    });
    final signedUpSkus = matchingSignups.map((s) => s.sku).toSet();
    return service.searchEventsBySkus(
      skus: signedUpSkus,
      program: cleanProgram,
      query: cleanQuery,
    );
  }

  return service.searchUkEvents(
    program: cleanProgram,
    query: cleanQuery,
  );
});
