import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/roles.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/sku_utils.dart';
import '../../../core/utils/url_utils.dart';
import '../../../core/widgets/role_details_link.dart';
import '../../events/models/event_model.dart';
import '../../auth_invites/state/auth_provider.dart';
import '../models/signup_model.dart';
import '../state/volunteering_provider.dart';
import '../widgets/event_signup_dialog.dart';

class EventRosterScreen extends ConsumerStatefulWidget {
  final EventModel event;

  const EventRosterScreen({super.key, required this.event});

  @override
  ConsumerState<EventRosterScreen> createState() => _EventRosterScreenState();
}

class _EventRosterScreenState extends ConsumerState<EventRosterScreen> {
  String _selectedFilter = 'All'; // 'All', 'Confirmed', 'Available', or roleId
  String? _selectedRoleFilter;

  void _openSignupDialog([EventSignupModel? existingSignup]) {
    showDialog(
      context: context,
      builder: (_) => EventSignupDialog(
        sku: widget.event.sku,
        eventName: widget.event.name,
        existingSignup: existingSignup,
      ),
    );
  }

  void _showRelayMessageDialog(EventSignupModel signup) {
    final relayAddress = signup.volunteer?.forwardingAddress ??
        'vol-${signup.volunteerId.substring(0, 8)}@volunteer.roboref.app';
    final subjectController =
        TextEditingController(text: 'VEX Tournament Inquiry - ${widget.event.name}');
    final bodyController = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.shield_outlined, color: Colors.blue),
            const SizedBox(width: 8),
            const Text('Contact via Privacy Relay', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'To protect this volunteer\'s privacy, your message will be forwarded through the RoboVolunteers relay:',
                style: TextStyle(fontSize: 12, color: Colors.grey[700]),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.blue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  relayAddress,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                    color: Colors.blue,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: subjectController,
                decoration: const InputDecoration(labelText: 'Subject'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: bodyController,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Message Body',
                  hintText: 'e.g. Hi, confirming arrival time for Saturday referee briefing...',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              await UrlUtils.openEmail(
                recipientEmail: relayAddress,
                subject: subjectController.text,
                body: bodyController.text,
              );
            },
            icon: const Icon(Icons.send, size: 16),
            label: const Text('Send Email via Relay'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final signupsAsync = ref.watch(eventSignupsProvider(widget.event.sku));
    final userSignupAsync = ref.watch(userEventSignupProvider(widget.event.sku));
    final currentUser =
        ref.watch(currentVolunteerProvider)?.withDisabledPrivacyAndEpSettings();
    final isEp = currentUser?.isEventPartner ?? false;
    final progColor = getProgramColor(widget.event.program);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Volunteer Roster'),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'View on VEX Events (events.vex.com)',
            onPressed: () => UrlUtils.openVexEventsPage(widget.event.sku),
          ),
        ],
      ),
      body: signupsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => Center(child: Text('Error loading roster: $err')),
        data: (signups) {
          final confirmedSignups = signups.where((s) => s.isConfirmed).toList();
          final availableSignups = signups.where((s) => s.isAvailable).toList();

          // Calculate role coverage
          final roleCounts = <String, int>{};
          for (final role in VolunteerRole.values) {
            roleCounts[role.id] = 0;
          }
          for (final s in signups) {
            for (final r in s.offeredRoles) {
              roleCounts[r] = (roleCounts[r] ?? 0) + 1;
            }
          }

          // Filter signups
          var filtered = signups;
          if (_selectedFilter == 'Confirmed') {
            filtered = confirmedSignups;
          } else if (_selectedFilter == 'Available') {
            filtered = availableSignups;
          }

          if (_selectedRoleFilter != null) {
            filtered = filtered.where((s) => s.offeredRoles.contains(_selectedRoleFilter)).toList();
          }

          return CustomScrollView(
            slivers: [
              // Event Info & VEX Events CTA Header
              SliverToBoxAdapter(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  color: Theme.of(context).cardColor,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: progColor.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              widget.event.program,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: progColor,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            widget.event.sku,
                            style: TextStyle(
                              fontSize: 12,
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[600],
                            ),
                          ),
                          const Spacer(),
                          // Official VEX Events link button
                          OutlinedButton.icon(
                            onPressed: () => UrlUtils.openVexEventsPage(widget.event.sku),
                            icon: const Icon(Icons.launch, size: 14),
                            label: const Text('VEX Events Page', style: TextStyle(fontSize: 12)),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        widget.event.name,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.calendar_month_outlined, size: 14, color: Colors.grey[600]),
                          const SizedBox(width: 6),
                          Text(
                            widget.event.startDate,
                            style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                          ),
                          const SizedBox(width: 16),
                          Icon(Icons.location_pin, size: 14, color: Colors.grey[600]),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              [widget.event.venue, widget.event.city].whereType<String>().join(', '),
                              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Current User's Signup Banner / Action
              SliverToBoxAdapter(
                child: userSignupAsync.when(
                  loading: () => const SizedBox(),
                  error: (_, __) => const SizedBox(),
                  data: (userSignup) {
                    return Container(
                      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: userSignup != null
                            ? (userSignup.isConfirmed
                                ? AppTheme.statusConfirmed.withValues(alpha: 0.1)
                                : AppTheme.statusAvailable.withValues(alpha: 0.1))
                            : AppTheme.brandGreen.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: userSignup != null
                              ? (userSignup.isConfirmed
                                  ? AppTheme.statusConfirmed.withValues(alpha: 0.3)
                                  : AppTheme.statusAvailable.withValues(alpha: 0.3))
                              : AppTheme.brandGreen.withValues(alpha: 0.2),
                        ),
                      ),
                      child: userSignup == null
                          ? Row(
                              children: [
                                const Icon(Icons.volunteer_activism, color: AppTheme.brandGreen, size: 28),
                                const SizedBox(width: 12),
                                const Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Interested in volunteering?',
                                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                      ),
                                      Text(
                                        'Mark your availability or confirm your roles for this event.',
                                        style: TextStyle(fontSize: 11, color: Colors.grey),
                                      ),
                                    ],
                                  ),
                                ),
                                ElevatedButton(
                                  onPressed: () => _openSignupDialog(),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                  ),
                                  child: const Text('Volunteer', style: TextStyle(fontSize: 13)),
                                ),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      userSignup.isConfirmed ? Icons.check_circle : Icons.event_available,
                                      color: userSignup.isConfirmed
                                          ? AppTheme.statusConfirmed
                                          : AppTheme.statusAvailable,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'You are registered as: ${userSignup.status.label.toUpperCase()}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                        color: userSignup.isConfirmed
                                            ? AppTheme.statusConfirmed
                                            : AppTheme.statusAvailable,
                                      ),
                                    ),
                                    if (userSignup.epVerified) ...[
                                      const SizedBox(width: 6),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: AppTheme.epVerifiedGold.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: const Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.verified, size: 13, color: AppTheme.epVerifiedGold),
                                            SizedBox(width: 3),
                                            Text(
                                              'EP Verified',
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: AppTheme.epVerifiedGold,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                    const Spacer(),
                                    TextButton.icon(
                                      onPressed: () => _openSignupDialog(userSignup),
                                      icon: const Icon(Icons.edit, size: 14),
                                      label: const Text('Edit', style: TextStyle(fontSize: 12)),
                                      style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: [
                                    ...userSignup.roleEnums.map((r) => Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: r.color.withValues(alpha: 0.12),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            r.label,
                                            style: TextStyle(
                                              fontSize: 11,
                                              fontWeight: FontWeight.w600,
                                              color: r.color,
                                            ),
                                          ),
                                        )),
                                    if (userSignup.otherRoleDescription != null)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          userSignup.otherRoleDescription!,
                                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                    );
                  },
                ),
              ),

              // Coverage KPI Summary Card
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceAround,
                            children: [
                              _buildMetricItem(
                                label: 'Total Signups',
                                value: '${signups.length}',
                                color: Colors.blueGrey,
                              ),
                              _buildMetricItem(
                                label: 'Confirmed',
                                value: '${confirmedSignups.length}',
                                color: AppTheme.statusConfirmed,
                              ),
                              _buildMetricItem(
                                label: 'Available',
                                value: '${availableSignups.length}',
                                color: AppTheme.statusAvailable,
                              ),
                            ],
                          ),
                          const Divider(height: 20),
                          const Text(
                            'Role Coverage Offered:',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 2),
                          const RoleDetailsLink(),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: VolunteerRole.values.map((role) {
                              final count = roleCounts[role.id] ?? 0;
                              final isSelected = _selectedRoleFilter == role.id;
                              return FilterChip(
                                label: Text('${role.label}: $count'),
                                selected: isSelected,
                                selectedColor: role.color.withValues(alpha: 0.15),
                                labelStyle: TextStyle(
                                  fontSize: 11,
                                  fontWeight: count > 0 ? FontWeight.bold : FontWeight.normal,
                                  color: isSelected ? role.color : (count > 0 ? null : Colors.grey),
                                ),
                                onSelected: (val) {
                                  setState(() {
                                    _selectedRoleFilter = val ? role.id : null;
                                  });
                                },
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // Status Filter Tabs
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: SegmentedButton<String>(
                    segments: [
                      ButtonSegment(
                        value: 'All',
                        label: Text('All (${signups.length})'),
                      ),
                      ButtonSegment(
                        value: 'Confirmed',
                        label: Text('Confirmed (${confirmedSignups.length})'),
                      ),
                      ButtonSegment(
                        value: 'Available',
                        label: Text('Available (${availableSignups.length})'),
                      ),
                    ],
                    selected: {_selectedFilter},
                    onSelectionChanged: (set) {
                      setState(() => _selectedFilter = set.first);
                    },
                  ),
                ),
              ),

              // Volunteer Roster List
              if (filtered.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: Text(
                        'No volunteers match the current status or role filter.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final item = filtered[index];
                        return _VolunteerCard(
                          signup: item,
                          isEpViewer: isEp,
                          onContactRelay: () => _showRelayMessageDialog(item),
                          onToggleEpVerification: () async {
                            final repo = ref.read(volunteerRepositoryProvider);
                            await repo.toggleEpVerification(signupId: item.id);
                            ref.invalidate(eventSignupsProvider(widget.event.sku));
                            ref.invalidate(userEventSignupProvider(widget.event.sku));
                            ref.invalidate(myVolunteerSignupsProvider);
                          },
                        );
                      },
                      childCount: filtered.length,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMetricItem({required String label, required String value, required Color color}) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: color),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: Colors.grey[600]),
        ),
      ],
    );
  }
}

class _VolunteerCard extends StatelessWidget {
  final EventSignupModel signup;
  final bool isEpViewer;
  final VoidCallback onContactRelay;
  final VoidCallback onToggleEpVerification;

  const _VolunteerCard({
    required this.signup,
    required this.isEpViewer,
    required this.onContactRelay,
    required this.onToggleEpVerification,
  });

  @override
  Widget build(BuildContext context) {
    final volunteer = signup.volunteer?.withDisabledPrivacyAndEpSettings();
    final isConfirmed = signup.isConfirmed;
    final statusColor = isConfirmed ? AppTheme.statusConfirmed : AppTheme.statusAvailable;
    final showPhone = volunteer != null &&
        volunteer.isPhonePublic &&
        volunteer.phone != null &&
        volunteer.phone!.isNotEmpty;
    final showEmail = volunteer != null && volunteer.isEmailPublic;
    final showRelay = volunteer != null &&
        !volunteer.isEmailPublic &&
        volunteer.forwardingEnabled;
    final hasVisibleContact = showPhone || showEmail || showRelay;

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top row: Avatar, Name, Status & EP Verified Badge
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: statusColor.withValues(alpha: 0.15),
                  child: Text(
                    signup.volunteerName.isNotEmpty ? signup.volunteerName[0].toUpperCase() : 'V',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: statusColor,
                      fontSize: 16,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              signup.volunteerName,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (signup.epVerified) ...[
                            const SizedBox(width: 6),
                            Tooltip(
                              message: 'Verified and locked in by Event Partner',
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppTheme.epVerifiedGold.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.verified, size: 12, color: AppTheme.epVerifiedGold),
                                    SizedBox(width: 3),
                                    Text(
                                      'EP Verified',
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: AppTheme.epVerifiedGold,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          signup.status.label.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: statusColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // EP Lock-in Toggle (for Event Partners)
                if (isEpViewer)
                  Tooltip(
                    message: signup.epVerified ? 'Unlock / Remove EP Verification' : 'Verify & Lock In Volunteer',
                    child: IconButton(
                      icon: Icon(
                        signup.epVerified ? Icons.verified : Icons.verified_outlined,
                        color: signup.epVerified ? AppTheme.epVerifiedGold : Colors.grey,
                      ),
                      onPressed: onToggleEpVerification,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // Offered Roles Badges
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                ...signup.roleEnums.map((r) => Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: r.color.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: r.color.withValues(alpha: 0.25)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(r.icon, size: 12, color: r.color),
                          const SizedBox(width: 4),
                          Text(
                            r.label,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: r.color,
                            ),
                          ),
                        ],
                      ),
                    )),
                if (signup.otherRoleDescription != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.grey.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
                    ),
                    child: Text(
                      'Other: ${signup.otherRoleDescription}',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),

            // Volunteer notes (if provided)
            if (signup.notes != null && signup.notes!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '“${signup.notes}”',
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: Colors.grey[800]),
                ),
              ),
            ],
            if (hasVisibleContact) ...[
              const SizedBox(height: 10),
              const Divider(height: 1),
              const SizedBox(height: 8),

              // Privacy & Contact Action Bar
              Row(
                children: [
                  // Phone contact (if public)
                  if (showPhone) ...[
                    OutlinedButton.icon(
                      onPressed: () => UrlUtils.openPhone(volunteer.phone!),
                      icon: const Icon(Icons.phone, size: 14),
                      label: Text(volunteer.phone!, style: const TextStyle(fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],

                  // Direct email contact (if public)
                  if (showEmail) ...[
                    OutlinedButton.icon(
                      onPressed: () => UrlUtils.openEmail(
                        recipientEmail: volunteer.email,
                        subject: 'VEX Tournament Inquiry',
                      ),
                      icon: const Icon(Icons.email, size: 14),
                      label: Text(volunteer.email, style: const TextStyle(fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ] else if (showRelay) ...[
                    // Privacy Forwarding Relay Action Button
                    OutlinedButton.icon(
                      onPressed: onContactRelay,
                      icon: const Icon(Icons.shield_outlined, size: 14, color: Colors.blue),
                      label: const Text(
                        'Email via Relay',
                        style: TextStyle(fontSize: 11, color: Colors.blue, fontWeight: FontWeight.bold),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Colors.blue),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Private Contact',
                      style: TextStyle(fontSize: 10, color: Colors.grey[600]),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
