import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../../core/utils/sku_utils.dart';
import '../models/event_model.dart';

class VexEventsException implements Exception {
  final String message;
  final int? statusCode;

  const VexEventsException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

class VexEventsService {
  final http.Client _client;
  static const String vexBaseUrl = 'https://events.vex.com/api/v2';
  static const String proxyBaseUrl = 'https://robovolunteers.link/api/vexevents';
  static const String testProxyBaseUrl =
      'https://test.robovolunteers.link/api/vexevents';

  VexEventsService({http.Client? client}) : _client = client ?? http.Client();

  /// Map program names to VEX Events program IDs
  List<int> _getProgramIds(String? program) {
    if (program == null || program.isEmpty || program == 'All') {
      return [];
    }
    switch (program.toUpperCase()) {
      case 'VEX V5':
      case 'V5RC':
      case 'VRC':
      case 'VE-V5':
      case 'V5':
        return [1];
      case 'VEX IQ':
      case 'VIQRC':
      case 'VIQC':
      case 'VE-IQ':
      case 'IQ':
        return [41];
      case 'VEX U':
      case 'VURC':
      case 'VE-U':
      case 'U':
        return [4];
      case 'VEX AI':
      case 'VAIRC':
      case 'AI':
        return [57, 58];
      default:
        return [];
    }
  }

  /// Map program names to current season IDs
  List<int> _getProgramSeasonIds(String? program) {
    if (program == null || program.isEmpty || program == 'All') {
      return [204, 203, 205, 206];
    }
    switch (program.toUpperCase()) {
      case 'VEX V5':
      case 'V5RC':
      case 'VRC':
      case 'VE-V5':
      case 'V5':
        return [204];
      case 'VEX IQ':
      case 'VIQRC':
      case 'VIQC':
      case 'VE-IQ':
      case 'IQ':
        return [203];
      case 'VEX U':
      case 'VURC':
      case 'VE-U':
      case 'U':
        return [205];
      case 'VEX AI':
      case 'VAIRC':
      case 'AI':
        return [206];
      default:
        return [204, 203];
    }
  }

  bool _matchesProgram(EventModel event, String? program) {
    if (program == null || program.isEmpty || program == 'All') {
      return true;
    }
    final filterIds = _getProgramIds(program);
    final eventIds = _getProgramIds(event.program);
    if (filterIds.isNotEmpty && eventIds.isNotEmpty) {
      return filterIds.any(eventIds.contains);
    }
    return event.program.toUpperCase() == program.toUpperCase();
  }

  bool _matchesQuery(EventModel e, String? query) {
    if (query == null || query.trim().isEmpty) return true;
    final q = query.trim().toLowerCase();
    final matchesName = e.name.toLowerCase().contains(q);
    final matchesSku = e.sku.toLowerCase().contains(q);
    final matchesCity = e.city?.toLowerCase().contains(q) ?? false;
    final matchesVenue = e.venue?.toLowerCase().contains(q) ?? false;
    return matchesName || matchesSku || matchesCity || matchesVenue;
  }

  /// Fetch events matching a set of SKUs (used for signup/status filters)
  Future<List<EventModel>> searchEventsBySkus({
    required Set<String> skus,
    String? program,
    String? query,
  }) async {
    final normalizedSkus = skus
        .map((s) => s.trim().toUpperCase())
        .where((s) => s.isNotEmpty)
        .toSet();
    if (normalizedSkus.isEmpty) return [];

    final queryParams = <String, List<String>>{
      'per_page': [
        normalizedSkus.length < 40 ? '40' : normalizedSkus.length.toString(),
      ],
      'sku[]': normalizedSkus.toList(),
    };

    final candidateUrls = [
      Uri.parse('$proxyBaseUrl/events').replace(queryParameters: queryParams),
      Uri.parse('$testProxyBaseUrl/events').replace(queryParameters: queryParams),
      Uri.parse('$vexBaseUrl/events').replace(queryParameters: queryParams),
    ];

    final resultsBySku = <String, EventModel>{};
    var loadedFromApi = false;

    for (final uri in candidateUrls) {
      try {
        final response = await _client
            .get(
              uri,
              headers: const {'Accept': 'application/json'},
            )
            .timeout(const Duration(seconds: 8));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic> && data['data'] is List) {
            for (final raw in data['data'] as List) {
              final event = EventModel.fromJson(raw as Map<String, dynamic>);
              resultsBySku[event.sku.trim().toUpperCase()] = event;
            }
            loadedFromApi = true;
            break;
          }
        }
      } catch (e) {
        debugPrint('Failed to query $uri: $e');
      }
    }

    if (!loadedFromApi) {
      throw const VexEventsException(
        'Unable to load event data from VEX Events. Please check your connection and try again.',
      );
    }

    return resultsBySku.values
        .where((e) =>
            normalizedSkus.contains(e.sku.trim().toUpperCase()) &&
            _matchesProgram(e, program) &&
            _matchesQuery(e, query))
        .toList();
  }

  /// Search UK VEX events from official VEX Events API or RoboVolunteers proxy
  Future<List<EventModel>> searchUkEvents({
    String? query,
    String? program,
    int page = 1,
    int perPage = 250,
  }) async {
    final queryParams = <String, List<String>>{
      'page': [page.toString()],
      'per_page': [perPage.toString()],
      'region': ['United Kingdom'],
    };

    if (query != null && query.trim().isNotEmpty) {
      final cleanQuery = query.trim();
      if (isSkuQuery(cleanQuery)) {
        queryParams['sku[]'] = [cleanQuery.toUpperCase()];
      }
    }

    final seasonIds = _getProgramSeasonIds(program);
    if (seasonIds.isNotEmpty) {
      queryParams['season[]'] = seasonIds.map((id) => id.toString()).toList();
    }

    final programIds = _getProgramIds(program);
    if (programIds.isNotEmpty) {
      queryParams['program[]'] = programIds.map((id) => id.toString()).toList();
    }

    final candidateUrls = [
      Uri.parse('$proxyBaseUrl/events').replace(queryParameters: queryParams),
      Uri.parse('$testProxyBaseUrl/events').replace(queryParameters: queryParams),
      Uri.parse('$vexBaseUrl/events').replace(queryParameters: queryParams),
    ];

    for (final uri in candidateUrls) {
      try {
        final response = await _client
            .get(
              uri,
              headers: const {'Accept': 'application/json'},
            )
            .timeout(const Duration(seconds: 8));

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic> && data['data'] is List) {
            final events = (data['data'] as List)
                .map((e) => EventModel.fromJson(e as Map<String, dynamic>))
                .toList();
            return events
                .where(
                    (e) => _matchesProgram(e, program) && _matchesQuery(e, query))
                .toList();
          }
        }
      } catch (e) {
        debugPrint('Failed to query $uri: $e');
      }
    }

    throw const VexEventsException(
      'Unable to load event data from VEX Events. Please check your connection and try again.',
    );
  }
}
